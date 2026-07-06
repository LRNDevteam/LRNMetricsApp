using Azure.Core;
using Azure.Identity;
using LRN.SharePointClient.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

public sealed class SharePointDownloader
{
	private readonly HttpClient _http;
	private readonly ILogger<SharePointDownloader> _logger;
	private readonly ImportOptions _opt;

	private string? _siteId;
	private string? _driveId;
	private string? _rootFolderId;

	public SharePointDownloader(HttpClient http, IOptions<ImportOptions> opt, ILogger<SharePointDownloader> logger)
	{
		_http = http;
		_opt = opt.Value;
		_logger = logger;
	}

	public sealed record SelectedFile(
		int LabId,
		string DriveId,
		string ItemId,
		string Name,
		string ETagKey,
		DateTimeOffset? LastModifiedUtc,
		string SharePointPath);

	public async Task<string?> TryGetDriveIdAsync(CancellationToken ct)
	{
		if (!_opt.SharePoint.Enabled) return null;
		await EnsureDriveAsync(ct);
		return _driveId;
	}

	public async Task<LatestFileLookupResult> TryGetLatestFileForLabAsync(
		LabFileMap lab,
		int currentYear,
		CancellationToken ct)
	{
		if (!_opt.SharePoint.Enabled)
		{
			return new LatestFileLookupResult(
				File: null,
				Status: LatestFileLookupStatus.Disabled,
				YearFolderName: null,
				MonthFolderName: null,
				WeekFolderName: null,
				Message: "SharePoint is disabled.");
		}

		await EnsureDriveAsync(ct);

		var driveId = _driveId!;
		var labRootId = await GetLabRootFolderIdAsync(driveId, lab.SharePointRootPath, ct);

		var yearFolder = (await ListChildrenPagedAsync(driveId, labRootId, ct))
			.Where(x => x.IsFolder)
			.Select(x => new { Item = x, Year = TryParseYearFolder(x.Name) })
			.Where(x => x.Year.HasValue)
			.OrderByDescending(x => x.Year!.Value == currentYear)
			.ThenByDescending(x => x.Year!.Value)
			.Select(x => x.Item)
			.FirstOrDefault();

		if (yearFolder == null)
		{
			return new LatestFileLookupResult(
				File: null,
				Status: LatestFileLookupStatus.NoYearFolder,
				YearFolderName: null,
				MonthFolderName: null,
				WeekFolderName: null,
				Message: $"No year folder found under '{lab.SharePointRootPath}'.");
		}

		var monthFolders = (await ListChildrenPagedAsync(driveId, yearFolder.Id, ct))
			.Where(x => x.IsFolder)
			.Select(x => new { Item = x, Month = TryParseMonthFolder(x.Name) })
			.Where(x => x.Month.HasValue)
			.OrderByDescending(x => x.Month!.Value)
			.ThenByDescending(x => x.Item.LastModifiedUtc ?? DateTimeOffset.MinValue)
			.Select(x => x.Item)
			.ToList();

		if (monthFolders.Count == 0)
		{
			return new LatestFileLookupResult(
				File: null,
				Status: LatestFileLookupStatus.NoMonthFolder,
				YearFolderName: yearFolder.Name,
				MonthFolderName: null,
				WeekFolderName: null,
				Message: $"No month folder found under year folder '{yearFolder.Name}'.");
		}

		var latestMonthFolder = monthFolders[0];

		// Collect week folders from the most recent months (newest first) so the
		// fallback to the previous week can cross a month boundary.
		const int MaxMonthsToScan = 2;
		var weekFolders = new List<WeekFolderCandidate>();

		foreach (var mf in monthFolders.Take(MaxMonthsToScan))
		{
			var monthChildren = await ListChildrenPagedAsync(driveId, mf.Id, ct);
			weekFolders.AddRange(monthChildren
				.Where(x => x.IsFolder)
				.Select(x => new WeekFolderCandidate(
					mf.Name,
					x,
					TryParseDateRangeFolder(x.Name),
					TryParseFirstDateFromName(NormalizeFolderName(x.Name))))
				.Where(x => x.Range.HasValue || x.FirstDate.HasValue)
				.OrderByDescending(x => x.Range?.EndDate ?? x.FirstDate ?? DateTime.MinValue)
				.ThenByDescending(x => x.Range?.StartDate ?? x.FirstDate ?? DateTime.MinValue)
				.ThenByDescending(x => x.Item.LastModifiedUtc ?? DateTimeOffset.MinValue));
		}

		if (weekFolders.Count == 0)
		{
			return new LatestFileLookupResult(
				File: null,
				Status: LatestFileLookupStatus.NoWeekFolder,
				YearFolderName: yearFolder.Name,
				MonthFolderName: latestMonthFolder.Name,
				WeekFolderName: null,
				Message: $"No week folder found under month folder '{latestMonthFolder.Name}'.");
		}

		var today = DateTime.Today;

		var currentWeekFolder = weekFolders
			.FirstOrDefault(x =>
				x.Range.HasValue &&
				x.Range.Value.StartDate.Date <= today &&
				today <= x.Range.Value.EndDate.Date);

		// Scan order: the week folder covering today first (if any), then earlier
		// week folders newest-first, so an empty current week falls back to the
		// previous week's file (the already-processed check in SQL decides skip/run).
		var scanOrder = new List<WeekFolderCandidate>();
		if (currentWeekFolder != null)
			scanOrder.Add(currentWeekFolder);
		scanOrder.AddRange(weekFolders.Where(x => !ReferenceEquals(x, currentWeekFolder)));

		const int MaxWeekFoldersToScan = 6;
		var emptyFolderNames = new List<string>();

		foreach (var wf in scanOrder.Take(MaxWeekFoldersToScan))
		{
			var isCurrentWeek = ReferenceEquals(wf, currentWeekFolder);
			var fileChildren = await ListChildrenPagedAsync(driveId, wf.Item.Id, ct);

			var matchingFiles = fileChildren
				.Where(x => !x.IsFolder && WildcardMatch(x.Name, lab.SharePointFilePattern))
				.OrderByDescending(x => x.LastModifiedUtc ?? DateTimeOffset.MinValue)
				.ThenByDescending(x => x.Name)
				.ToList();

			_logger.LogInformation(
				"Lab {LabId}: Week folder '{WeekFolder}' ({Kind}). MatchingFiles={Count}, Pattern='{Pattern}', LimsPattern='{LimsPattern}'.",
				lab.LabId,
				wf.Item.Name,
				isCurrentWeek ? "current week" : "fallback",
				matchingFiles.Count,
				lab.SharePointFilePattern,
				lab.LimsMasterFilePattern);

			if (matchingFiles.Count == 0)
			{
				emptyFolderNames.Add(wf.Item.Name);
				continue;
			}

			var file = matchingFiles.First();
			var limsFile = FindRequiredLimsFile(fileChildren, file, lab.LimsMasterFilePattern);
			if (limsFile == null)
			{
				return new LatestFileLookupResult(
					File: null,
					Status: string.IsNullOrWhiteSpace(lab.LimsMasterFilePattern)
						? LatestFileLookupStatus.LimsMasterFilePatternMissing
						: isCurrentWeek
							? LatestFileLookupStatus.NoLimsMasterFileInCurrentWeekFolder
							: LatestFileLookupStatus.NoLimsMasterFileInLatestAvailableWeekFolder,
					YearFolderName: yearFolder.Name,
					MonthFolderName: wf.MonthFolderName,
					WeekFolderName: wf.Item.Name,
					Message: string.IsNullOrWhiteSpace(lab.LimsMasterFilePattern)
						? $"LIMS master file pattern is not configured for lab '{lab.LabName}'."
						: $"Production master file '{file.Name}' was found, but no LIMS master file matched pattern '{lab.LimsMasterFilePattern}' in week folder '{wf.Item.Name}'.");
			}

			var eTagKey = file.ETag ?? string.Empty;

			var spPath = BuildSpPath(
				lab.SharePointRootPath,
				yearFolder.Name,
				wf.MonthFolderName,
				wf.Item.Name,
				file.Name);

			return new LatestFileLookupResult(
				File: new SelectedFile(
					lab.LabId,
					driveId,
					file.Id,
					file.Name,
					eTagKey,
					file.LastModifiedUtc,
					spPath),
				Status: LatestFileLookupStatus.FileFound,
				YearFolderName: yearFolder.Name,
				MonthFolderName: wf.MonthFolderName,
				WeekFolderName: wf.Item.Name,
				Message: isCurrentWeek
					? null
					: $"Selected file from earlier week folder '{wf.Item.Name}' (no matching file in: {string.Join(", ", emptyFolderNames)}).");
		}

		// Nothing matched in the current week folder or in any earlier folder scanned.
		if (currentWeekFolder != null)
		{
			return new LatestFileLookupResult(
				File: null,
				Status: LatestFileLookupStatus.NoFileInCurrentWeekFolder,
				YearFolderName: yearFolder.Name,
				MonthFolderName: currentWeekFolder.MonthFolderName,
				WeekFolderName: currentWeekFolder.Item.Name,
				Message: $"No matching file found in current week folder '{currentWeekFolder.Item.Name}' or in earlier week folders checked ({string.Join(", ", emptyFolderNames)}).");
		}

		return new LatestFileLookupResult(
			File: null,
			Status: LatestFileLookupStatus.NoFileInLatestAvailableWeekFolder,
			YearFolderName: yearFolder.Name,
			MonthFolderName: scanOrder[0].MonthFolderName,
			WeekFolderName: scanOrder[0].Item.Name,
			Message: $"No matching file found in the latest week folders checked ({string.Join(", ", emptyFolderNames)}).");
	}

	private sealed record WeekFolderCandidate(
		string MonthFolderName,
		DriveChild Item,
		(DateTime StartDate, DateTime EndDate)? Range,
		DateTime? FirstDate);

	public async Task DownloadFileAsync(string driveId, string itemId, string localPath, CancellationToken ct)
	{
		var url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/items/{itemId}/content";

		using var resp = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
		resp.EnsureSuccessStatusCode();

		await using var remote = await resp.Content.ReadAsStreamAsync(ct);
		await using var local = new FileStream(localPath, FileMode.Create, FileAccess.Write, FileShare.None);
		await remote.CopyToAsync(local, ct);
	}

	public async Task<string?> TryResolveProcessedFolderIdAsync(CancellationToken ct)
	{
		var sp = _opt.SharePoint;
		if (!sp.MoveToProcessed || string.IsNullOrWhiteSpace(sp.ProcessedFolderPath))
			return null;

		await EnsureDriveAsync(ct);

		if (!string.IsNullOrWhiteSpace(_rootFolderId))
			return await GetItemIdByPathUnderItemAsync(_driveId!, _rootFolderId!, sp.ProcessedFolderPath!, ct);

		return await GetItemIdByPathAsync(_driveId!, sp.ProcessedFolderPath!, ct);
	}

	public async Task MoveItemAsync(string driveId, string itemId, string newParentFolderId, CancellationToken ct)
	{
		var url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/items/{itemId}";
		var body = "{\"parentReference\":{\"id\":\"" + newParentFolderId + "\"}}";

		using var req = new HttpRequestMessage(HttpMethod.Patch, url)
		{
			Content = new StringContent(body, Encoding.UTF8, "application/json")
		};

		using var resp = await _http.SendAsync(req, ct);
		resp.EnsureSuccessStatusCode();
	}

	public sealed record SharePointFileEntry(
		string DriveId,
		string ItemId,
		string Name,
		string FolderPath,
		DateTimeOffset? LastModifiedUtc,
		long? Size,
		string? ETag);

	public async Task<IReadOnlyList<SharePointFileEntry>> ListFilesInFolderPathAsync(string driveId, string folderPath, CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(driveId)) throw new ArgumentException("driveId is empty", nameof(driveId));
		if (string.IsNullOrWhiteSpace(folderPath)) throw new ArgumentException("folderPath is empty", nameof(folderPath));

		await EnsureGraphAuthAsync(ct);
		var folderId = await GetItemIdByPathAsync(driveId, folderPath, ct);
		var items = await ListChildrenPagedAsync(driveId, folderId, ct);

		return items
			.Where(x => !x.IsFolder)
			.Select(x => new SharePointFileEntry(
				driveId,
				x.Id,
				x.Name ?? string.Empty,
				folderPath,
				x.LastModifiedUtc,
				null,
				x.ETag))
			.OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
			.ToList();
	}

	public async Task<SharePointFileEntry?> FindLatestFileInFolderPathAsync(string driveId, string folderPath, string wildcardPattern, CancellationToken ct)
	{
		var files = await ListFilesInFolderPathAsync(driveId, folderPath, ct);
		return files
			.Where(x => WildcardMatch(x.Name, wildcardPattern))
			.OrderByDescending(x => x.LastModifiedUtc ?? DateTimeOffset.MinValue)
			.ThenByDescending(x => x.Name, StringComparer.OrdinalIgnoreCase)
			.FirstOrDefault();
	}

	private async Task EnsureDriveAsync(CancellationToken ct)
	{
		await EnsureGraphAuthAsync(ct);

		var sp = _opt.SharePoint;

		if (!string.IsNullOrWhiteSpace(sp.SharedFolderUrl))
		{
			if (!string.IsNullOrWhiteSpace(_driveId) && !string.IsNullOrWhiteSpace(_rootFolderId))
				return;

			var (driveId, folderItemId) = await ResolveSharedFolderAsync(sp.SharedFolderUrl!, ct);
			_driveId = driveId;
			_rootFolderId = folderItemId;
			return;
		}

		_siteId ??= await GetSiteIdAsync(ct);
		_driveId ??= await GetDriveIdAsync(_siteId!, ct);
		_rootFolderId = null;
	}

	public async Task UploadFileToFolderPathAsync(
		string driveId,
		string folderPath,
		string localFilePath,
		string? uploadFileName,
		CancellationToken ct)
	{
		_ = await UploadFileToFolderPathWithLinkAsync(
			driveId,
			folderPath,
			localFilePath,
			uploadFileName,
			ct);
	}

	public async Task<SharePointPublishedFile> UploadFileToFolderPathWithLinkAsync(
		string driveId,
		string folderPath,
		string localFilePath,
		string? uploadFileName,
		CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(driveId))
			throw new ArgumentException("driveId is empty", nameof(driveId));

		if (!File.Exists(localFilePath))
			throw new FileNotFoundException("Local file not found", localFilePath);

		await EnsureGraphAuthAsync(ct);

		var fileName = string.IsNullOrWhiteSpace(uploadFileName)
			? Path.GetFileName(localFilePath)
			: uploadFileName!;

		folderPath ??= string.Empty;

		if (!string.IsNullOrWhiteSpace(folderPath))
			await EnsureFolderPathExistsAsync(driveId, folderPath, ct);

		var combined = string.IsNullOrWhiteSpace(folderPath)
			? fileName
			: folderPath.Trim().Trim('/').Trim('\\') + "/" + fileName;

		var encodedPath = EncodeGraphPath(combined);

		var url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/root:/{encodedPath}:/content?$select=id,name,webUrl";

		await using var fs = new FileStream(localFilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
		using var req = new HttpRequestMessage(HttpMethod.Put, url)
		{
			Content = new StreamContent(fs)
		};

		req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");

		using var resp = await _http.SendAsync(req, ct);
		var body = await resp.Content.ReadAsStringAsync(ct);
		resp.EnsureSuccessStatusCode();

		using var doc = JsonDocument.Parse(body);
		var root = doc.RootElement;

		var itemId = root.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
		var returnedName = root.TryGetProperty("name", out var nameEl) ? nameEl.GetString() : fileName;
		var webUrl = root.TryGetProperty("webUrl", out var webUrlEl) ? webUrlEl.GetString() : null;

		string? shareLinkUrl = null;
		if (!string.IsNullOrWhiteSpace(itemId))
			shareLinkUrl = await TryCreateOrganizationViewLinkAsync(driveId, itemId!, ct);

		return new SharePointPublishedFile
		{
			FileName = returnedName ?? fileName,
			LocalPath = localFilePath,
			RelativeSharePointPath = combined,
			WebUrl = webUrl,
			ShareLinkUrl = shareLinkUrl
		};
	}

	private async Task<string?> TryCreateOrganizationViewLinkAsync(string driveId, string itemId, CancellationToken ct)
	{
		try
		{
			var url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/items/{itemId}/createLink";

			using var req = new HttpRequestMessage(HttpMethod.Post, url)
			{
				Content = new StringContent(
					"{\"type\":\"view\",\"scope\":\"organization\"}",
					Encoding.UTF8,
					"application/json")
			};

			using var resp = await _http.SendAsync(req, ct);
			var body = await resp.Content.ReadAsStringAsync(ct);

			if (!resp.IsSuccessStatusCode)
			{
				_logger.LogWarning(
					"CreateLink failed for driveId={DriveId}, itemId={ItemId}. Status={StatusCode}. Body={Body}",
					driveId,
					itemId,
					(int)resp.StatusCode,
					body);
				return null;
			}

			using var doc = JsonDocument.Parse(body);

			if (doc.RootElement.TryGetProperty("link", out var linkEl) &&
				linkEl.TryGetProperty("webUrl", out var linkUrlEl))
			{
				return linkUrlEl.GetString();
			}

			return null;
		}
		catch (Exception ex)
		{
			_logger.LogWarning(ex, "CreateLink failed for driveId={DriveId}, itemId={ItemId}", driveId, itemId);
			return null;
		}
	}

	public async Task<string> EnsureFolderPathExistsAsync(string driveId, string folderPath, CancellationToken ct)
	{
		await EnsureGraphAuthAsync(ct);

		var rootId = await GetDriveRootIdAsync(driveId, ct);
		var currentId = rootId;

		var segments = folderPath
			.Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
			.ToArray();

		foreach (var seg in segments)
		{
			var children = await ListChildrenPagedAsync(driveId, currentId, ct);
			var match = children.FirstOrDefault(c => c.IsFolder && string.Equals(c.Name, seg, StringComparison.OrdinalIgnoreCase));
			if (match != null)
			{
				currentId = match.Id;
				continue;
			}

			currentId = await CreateFolderAsync(driveId, currentId, seg, ct);
		}

		return currentId;
	}

	private async Task<string> GetDriveRootIdAsync(string driveId, CancellationToken ct)
	{
		var url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/root";
		var json = await _http.GetStringAsync(url, ct);
		using var doc = JsonDocument.Parse(json);
		return doc.RootElement.GetProperty("id").GetString()!;
	}

	private async Task<string> CreateFolderAsync(string driveId, string parentFolderId, string folderName, CancellationToken ct)
	{
		var url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/items/{parentFolderId}/children";

		var body = new Dictionary<string, object?>
		{
			["name"] = folderName,
			["folder"] = new Dictionary<string, object?>(),
			["@microsoft.graph.conflictBehavior"] = "replace"
		};

		var jsonBody = JsonSerializer.Serialize(body);
		using var req = new HttpRequestMessage(HttpMethod.Post, url)
		{
			Content = new StringContent(jsonBody, Encoding.UTF8, "application/json")
		};

		using var resp = await _http.SendAsync(req, ct);
		resp.EnsureSuccessStatusCode();

		var json = await resp.Content.ReadAsStringAsync(ct);
		using var doc = JsonDocument.Parse(json);
		return doc.RootElement.GetProperty("id").GetString()!;
	}

	private static string EncodeGraphPath(string path)
	{
		var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
		return string.Join("/", parts.Select(Uri.EscapeDataString));
	}

	private async Task EnsureGraphAuthAsync(CancellationToken ct)
	{
		var sp = _opt.SharePoint;

		if (string.IsNullOrWhiteSpace(sp.TenantId) ||
			string.IsNullOrWhiteSpace(sp.ClientId) ||
			string.IsNullOrWhiteSpace(sp.ClientSecret))
		{
			throw new InvalidOperationException("SharePoint auth config missing (TenantId/ClientId/ClientSecret).");
		}

		var credential = new ClientSecretCredential(sp.TenantId, sp.ClientId, sp.ClientSecret);

		var token = await credential.GetTokenAsync(
			new TokenRequestContext(new[] { "https://graph.microsoft.com/.default" }), ct);

		_http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
		_http.DefaultRequestHeaders.Accept.Clear();
		_http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
	}

	private async Task<string> GetSiteIdAsync(CancellationToken ct)
	{
		var sp = _opt.SharePoint;

		if (string.IsNullOrWhiteSpace(sp.Hostname) || string.IsNullOrWhiteSpace(sp.SitePath))
			throw new InvalidOperationException("SharePoint Hostname/SitePath missing (or configure SharedFolderUrl).");

		var url = $"https://graph.microsoft.com/v1.0/sites/{sp.Hostname}:{sp.SitePath}";
		var json = await _http.GetStringAsync(url, ct);

		using var doc = JsonDocument.Parse(json);
		return doc.RootElement.GetProperty("id").GetString()!;
	}

	private async Task<string> GetDriveIdAsync(string siteId, CancellationToken ct)
	{
		var url = $"https://graph.microsoft.com/v1.0/sites/{siteId}/drives";
		var json = await _http.GetStringAsync(url, ct);

		using var doc = JsonDocument.Parse(json);
		foreach (var d in doc.RootElement.GetProperty("value").EnumerateArray())
		{
			var name = d.GetProperty("name").GetString();
			if (string.Equals(name, _opt.SharePoint.DriveName, StringComparison.OrdinalIgnoreCase))
				return d.GetProperty("id").GetString()!;
		}

		throw new InvalidOperationException($"DriveName '{_opt.SharePoint.DriveName}' not found on site.");
	}

	private async Task<string> GetLabRootFolderIdAsync(string driveId, string labRootPath, CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(labRootPath))
			throw new InvalidOperationException("Lab.SharePointRootPath is empty.");

		if (!string.IsNullOrWhiteSpace(_rootFolderId))
			return await GetItemIdByPathUnderItemAsync(driveId, _rootFolderId!, labRootPath, ct);

		return await GetItemIdByPathAsync(driveId, labRootPath, ct);
	}

	private async Task<string> GetItemIdByPathAsync(string driveId, string path, CancellationToken ct)
	{
		var normalized = EncodeGraphPath(path);
		var url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/root:/{normalized}:";
		var json = await _http.GetStringAsync(url, ct);

		using var doc = JsonDocument.Parse(json);
		return doc.RootElement.GetProperty("id").GetString()!;
	}

	private async Task<string> GetItemIdByPathUnderItemAsync(string driveId, string parentItemId, string relativePath, CancellationToken ct)
	{
		var normalized = EncodeGraphPath(relativePath);
		var url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/items/{parentItemId}:/{normalized}:";
		var json = await _http.GetStringAsync(url, ct);

		using var doc = JsonDocument.Parse(json);
		return doc.RootElement.GetProperty("id").GetString()!;
	}

	private sealed record DriveChild(string Id, string Name, bool IsFolder, DateTimeOffset? LastModifiedUtc, string? ETag);

	private async Task<List<DriveChild>> ListChildrenPagedAsync(
	string driveId,
	string folderId,
	CancellationToken ct)
	{
		var results = new List<DriveChild>();
		string? url = $"https://graph.microsoft.com/v1.0/drives/{driveId}/items/{folderId}/children";

		while (!string.IsNullOrWhiteSpace(url))
		{
			using var resp = await _http.GetAsync(url, ct);
			resp.EnsureSuccessStatusCode();

			var json = await resp.Content.ReadAsStringAsync(ct);
			using var doc = JsonDocument.Parse(json);

			foreach (var item in doc.RootElement.GetProperty("value").EnumerateArray())
			{
				var id = item.GetProperty("id").GetString()!;
				var name = item.GetProperty("name").GetString()!;
				var isFolder = item.TryGetProperty("folder", out _);

				DateTimeOffset? lm = null;
				if (item.TryGetProperty("lastModifiedDateTime", out var lmEl) &&
					DateTimeOffset.TryParse(lmEl.GetString(), out var lmParsed))
				{
					lm = lmParsed;
				}

				string? eTag = item.TryGetProperty("eTag", out var etEl)
					? etEl.GetString()
					: null;

				results.Add(new DriveChild(id, name, isFolder, lm, eTag));
			}

			url = doc.RootElement.TryGetProperty("@odata.nextLink", out var next)
				? next.GetString()
				: null;
		}

		return results;
	}

	private static string NormalizeFolderName(string name)
	{
		if (string.IsNullOrWhiteSpace(name))
			return string.Empty;

		name = name.Trim();
		name = Regex.Replace(name, @"^\d+\s*\.\s*", "");
		name = Regex.Replace(name, @"\s+", " ");
		return name.Trim();
	}

	private static int? TryParseYearFolder(string name)
	{
		name = NormalizeFolderName(name);
		if (string.IsNullOrWhiteSpace(name))
			return null;

		var anyYear = Regex.Match(name, @"(?<!\d)(20\d{2})(?!\d)");
		if (anyYear.Success && int.TryParse(anyYear.Groups[1].Value, out var extractedYear))
			return extractedYear;

		return null;
	}

	private static int? TryParseMonthFolder(string name)
	{
		name = NormalizeFolderName(name);
		if (string.IsNullOrWhiteSpace(name))
			return null;

		var numeric = Regex.Match(name, @"^(?<month>0?[1-9]|1[0-2])\s*\.");
		if (numeric.Success && int.TryParse(numeric.Groups["month"].Value, out var month1))
			return month1;

		var months = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
		{
			["January"] = 1, ["Jan"] = 1,
			["February"] = 2, ["Feb"] = 2,
			["March"] = 3, ["Mar"] = 3,
			["April"] = 4, ["Apr"] = 4,
			["May"] = 5,
			["June"] = 6, ["Jun"] = 6,
			["July"] = 7, ["Jul"] = 7,
			["August"] = 8, ["Aug"] = 8,
			["September"] = 9, ["Sep"] = 9, ["Sept"] = 9,
			["October"] = 10, ["Oct"] = 10,
			["November"] = 11, ["Nov"] = 11,
			["December"] = 12, ["Dec"] = 12
		};

		foreach (var kv in months)
		{
			if (Regex.IsMatch(name, $@"\b{Regex.Escape(kv.Key)}\b", RegexOptions.IgnoreCase))
				return kv.Value;
		}

		return null;
	}

	private static (DateTime StartDate, DateTime EndDate)? TryParseDateRangeFolder(string name)
	{
		name = NormalizeFolderName(name);
		if (string.IsNullOrWhiteSpace(name))
			return null;

		var fullMatches = Regex.Matches(name, @"\d{1,2}\.\d{1,2}\.\d{4}");
		if (fullMatches.Count >= 2)
		{
			if (DateTime.TryParseExact(fullMatches[0].Value, "MM.dd.yyyy", CultureInfo.InvariantCulture, DateTimeStyles.None, out var startDate) &&
				DateTime.TryParseExact(fullMatches[1].Value, "MM.dd.yyyy", CultureInfo.InvariantCulture, DateTimeStyles.None, out var endDate))
			{
				return (startDate, endDate);
			}
		}

		var partial = Regex.Match(name, @"(?<sm>\d{1,2})\.(?<sd>\d{1,2})\.(?<sy>\d{4})\s*-\s*(?<em>\d{1,2})\.(?<ed>\d{1,2})(?:\.(?<ey>\d{4}))?");
		if (partial.Success)
		{
			var sy = int.Parse(partial.Groups["sy"].Value);
			var ey = partial.Groups["ey"].Success ? int.Parse(partial.Groups["ey"].Value) : sy;
			try
			{
				var startDate = new DateTime(sy, int.Parse(partial.Groups["sm"].Value), int.Parse(partial.Groups["sd"].Value));
				var endDate = new DateTime(ey, int.Parse(partial.Groups["em"].Value), int.Parse(partial.Groups["ed"].Value));
				return (startDate, endDate);
			}
			catch { }
		}

		return null;
	}

	private static DateTime? TryParseFirstDateFromName(string name)
	{
		var m = Regex.Match(name, @"(?<mm>\d{1,2})\.(?<dd>\d{1,2})\.(?<yyyy>\d{4})");
		if (!m.Success) return null;

		if (!int.TryParse(m.Groups["mm"].Value, out var mm)) return null;
		if (!int.TryParse(m.Groups["dd"].Value, out var dd)) return null;
		if (!int.TryParse(m.Groups["yyyy"].Value, out var yyyy)) return null;

		try { return new DateTime(yyyy, mm, dd); }
		catch { return null; }
	}

	private static bool WildcardMatch(string fileName, string pattern)
	{
		if (string.IsNullOrWhiteSpace(fileName) || string.IsNullOrWhiteSpace(pattern))
			return false;

		var normalizedFileName = NormalizeFileMatchText(fileName);

		var patterns = pattern
			.Split(':', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
			.Select(NormalizeFileMatchText)
			.Where(p => !string.IsNullOrWhiteSpace(p));

		foreach (var singlePattern in patterns)
		{
			var regexPattern = "^" + Regex.Escape(singlePattern)
				.Replace(@"\*", ".*")
				.Replace(@"\?", ".") + "$";

			if (Regex.IsMatch(
				normalizedFileName,
				regexPattern,
				RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
			{
				return true;
			}
		}

		return false;
	}

	private static string NormalizeFileMatchText(string value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return string.Empty;

		value = value.Trim();
		value = Regex.Replace(value, @"\s+", " ");
		return value;
	}

	private static string BuildSpPath(params string[] parts)
	{
		return string.Join('/', parts.Select(p => p.Trim().Trim('/')).Where(p => !string.IsNullOrWhiteSpace(p)));
	}

	private static DriveChild? FindRequiredLimsFile(
		IEnumerable<DriveChild> children,
		DriveChild masterFile,
		string? limsPattern)
	{
		if (string.IsNullOrWhiteSpace(limsPattern))
			return null;

		return children
			.Where(x => !x.IsFolder)
			.Where(x => !string.Equals(x.Name, masterFile.Name, StringComparison.OrdinalIgnoreCase))
			.Where(x => WildcardMatch(x.Name, limsPattern))
			.OrderByDescending(x => x.LastModifiedUtc ?? DateTimeOffset.MinValue)
			.ThenByDescending(x => x.Name)
			.FirstOrDefault();
	}

	public async Task<SelectedFile?> TryGetSiblingFileByPatternAsync(SelectedFile currentFile, string filePattern, CancellationToken ct)
	{
		if (currentFile == null || string.IsNullOrWhiteSpace(currentFile.SharePointPath) || string.IsNullOrWhiteSpace(filePattern))
			return null;

		var folderPath = GetFolderPath(currentFile.SharePointPath);
		if (string.IsNullOrWhiteSpace(folderPath))
			return null;

		var folderId = await GetItemIdByPathAsync(currentFile.DriveId, folderPath, ct);
		var children = await ListChildrenPagedAsync(currentFile.DriveId, folderId, ct);
		var match = children
			.Where(x => !x.IsFolder)
			.Where(x => !string.Equals(x.Name, currentFile.Name, StringComparison.OrdinalIgnoreCase))
			.Where(x => WildcardMatch(x.Name, filePattern))
			.OrderByDescending(x => x.LastModifiedUtc ?? DateTimeOffset.MinValue)
			.ThenByDescending(x => x.Name)
			.FirstOrDefault();

		if (match == null)
			return null;

		return new SelectedFile(currentFile.LabId, currentFile.DriveId, match.Id, match.Name, match.ETag ?? string.Empty, match.LastModifiedUtc, BuildSpPath(folderPath, match.Name));
	}

	private static string GetFolderPath(string sharePointPath)
	{
		if (string.IsNullOrWhiteSpace(sharePointPath))
			return string.Empty;

		var normalized = sharePointPath.Replace('\\', '/').Trim('/');
		var idx = normalized.LastIndexOf('/');
		return idx <= 0 ? string.Empty : normalized.Substring(0, idx);
	}

	private static string EncodeSharingUrlToShareId(string sharingUrl)
	{
		var bytes = Encoding.UTF8.GetBytes(sharingUrl);
		var base64 = Convert.ToBase64String(bytes);
		var base64Url = base64.TrimEnd('=').Replace('+', '-').Replace('/', '_');
		return "u!" + base64Url;
	}

	private async Task<(string driveId, string itemId)> ResolveSharedFolderAsync(string shareFolderUrl, CancellationToken ct)
	{
		var shareId = EncodeSharingUrlToShareId(shareFolderUrl);
		var url = $"https://graph.microsoft.com/v1.0/shares/{shareId}/driveItem";

		var json = await _http.GetStringAsync(url, ct);
		using var doc = JsonDocument.Parse(json);

		var root = doc.RootElement;
		var itemId = root.GetProperty("id").GetString()!;
		var driveId = root.GetProperty("parentReference").GetProperty("driveId").GetString()!;

		return (driveId, itemId);
	}

	public enum LatestFileLookupStatus
	{
		FileFound,
		Disabled,
		NoYearFolder,
		NoMonthFolder,
		NoWeekFolder,
		NoFileInCurrentWeekFolder,
		NoFileInLatestAvailableWeekFolder,
		LimsMasterFilePatternMissing,
		NoLimsMasterFileInCurrentWeekFolder,
		NoLimsMasterFileInLatestAvailableWeekFolder
	}

	public sealed record LatestFileLookupResult(
		SelectedFile? File,
		LatestFileLookupStatus Status,
		string? YearFolderName,
		string? MonthFolderName,
		string? WeekFolderName,
		string? Message);
}

using System.Linq;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Common.Logging;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

public sealed class ModeMedianReportPublisher
{
	private readonly IConfiguration _configuration;
	private readonly IHttpClientFactory _httpClientFactory;
	private readonly ILogger<ModeMedianReportPublisher> _logger;
	private readonly ILoggerService _fileLog;

	public ModeMedianReportPublisher(
		IConfiguration configuration,
		IHttpClientFactory httpClientFactory,
		ILogger<ModeMedianReportPublisher> logger,
		ILoggerService fileLog)
	{
		_configuration = configuration;
		_httpClientFactory = httpClientFactory;
		_logger = logger;
		_fileLog = fileLog;
	}

	public async Task<ModeMedianPublishResult> PublishAsync(
		string runId,
		string labName,
		string weekDate,
		string lineLevelStandardCsvPath,
		CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(lineLevelStandardCsvPath) || !File.Exists(lineLevelStandardCsvPath))
			throw new FileNotFoundException("Line level standard CSV not found.", lineLevelStandardCsvPath);

		var sharePointSection = GetSharePointSection();

		var uploadFilesToSharePoint = _configuration.GetValue<bool?>("MasterFileProcessor:UploadFilesToSharePoint")
			?? _configuration.GetValue<bool?>("MasterFileProcessor:SharePoint:UploadFilesToSharePoint")
			?? true;

		var sharePointEnabled = uploadFilesToSharePoint && ParseBool(sharePointSection["Enabled"]);
		var medianServerFolderPath = sharePointSection["MedianServerFolderPath"] ?? string.Empty;
		var modeServerFolderPath = sharePointSection["ModeServerFolderPath"] ?? string.Empty;
		var sharePointMedianFolder = sharePointSection["SharePointMedianFolder"] ?? string.Empty;
		var sharePointModeFolder = sharePointSection["SharePointModeFolder"] ?? string.Empty;

		var safeLabName = SanitizeFileName(labName);
		var safeWeekDate = SanitizeFileName(weekDate);

		var medianFileName = $"{runId}_{safeLabName}_Median_{safeWeekDate}.xlsx";
		var modeFileName = $"{runId}_{safeLabName}_Mode_{safeWeekDate}.xlsx";

		var result = new ModeMedianPublishResult();

		Directory.CreateDirectory(medianServerFolderPath);
		Directory.CreateDirectory(modeServerFolderPath);

		var tempMedianPath = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid():N}_Median.xlsx");
		var tempModePath = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid():N}_Mode.xlsx");

		try
		{
			ModeMedianPaymentReportWriter.GenerateSeparateFiles(
				lineLevelStandardCsvPath,
				tempMedianPath,
				tempModePath);

			ArchiveMatchingLocalFiles(medianServerFolderPath, safeLabName, "Median");
			ArchiveMatchingLocalFiles(modeServerFolderPath, safeLabName, "Mode");

			result.MedianLocalPath = Path.Combine(medianServerFolderPath, medianFileName);
			result.ModeLocalPath = Path.Combine(modeServerFolderPath, modeFileName);

			CopyReplace(tempMedianPath, result.MedianLocalPath);
			CopyReplace(tempModePath, result.ModeLocalPath);

			result.MedianLocalStatus = $"WRITTEN -> {result.MedianLocalPath}";
			result.ModeLocalStatus = $"WRITTEN -> {result.ModeLocalPath}";

			if (sharePointEnabled)
			{
				if (!string.IsNullOrWhiteSpace(sharePointMedianFolder))
				{
					result.MedianSharePointStatus = await ArchiveAndUploadToSharePointAsync(
						sharePointMedianFolder,
						result.MedianLocalPath,
						medianFileName,
						safeLabName,
						"Median",
						ct);
				}
				else
				{
					result.MedianSharePointStatus = "SKIPPED (SharePointMedianFolder empty)";
				}

				if (!string.IsNullOrWhiteSpace(sharePointModeFolder))
				{
					result.ModeSharePointStatus = await ArchiveAndUploadToSharePointAsync(
						sharePointModeFolder,
						result.ModeLocalPath,
						modeFileName,
						safeLabName,
						"Mode",
						ct);
				}
				else
				{
					result.ModeSharePointStatus = "SKIPPED (SharePointModeFolder empty)";
				}
			}
			else
			{
				result.MedianSharePointStatus = "SKIPPED";
				result.ModeSharePointStatus = "SKIPPED";
			}

			return result;
		}
		finally
		{
			TryDelete(tempMedianPath);
			TryDelete(tempModePath);
		}
	}

	private IConfigurationSection GetSharePointSection()
	{
		var root = _configuration.GetSection("SharePoint");
		if (root.Value != null || root.GetChildren().Any())
			return root;

		return _configuration.GetSection("MasterFileProcessor:SharePoint");
	}

	private async Task<string> ArchiveAndUploadToSharePointAsync(
		string configuredFolderValue,
		string localFilePath,
		string uploadFileName,
		string safeLabName,
		string reportType,
		CancellationToken ct)
	{
		try
		{
			var ctx = await CreateGraphContextAsync(ct);
			var folderPath = ResolveDriveRelativeFolderPath(configuredFolderValue, ctx.DriveName);

			if (string.IsNullOrWhiteSpace(folderPath))
				return "SKIPPED (folder path not resolved)";

			await EnsureFolderPathAsync(ctx, folderPath, ct);

			var archiveFolderPath = CombineSpPath(folderPath, "Archive");
			await EnsureFolderPathAsync(ctx, archiveFolderPath, ct);

			var files = await ListFilesAsync(ctx, folderPath, ct);
			foreach (var file in files)
			{
				if (!IsMatchingReportFile(file.Name, safeLabName, reportType))
					continue;

				var archivedName = BuildArchiveFileName(file.Name);
				await MoveFileAsync(ctx, file.Id, archiveFolderPath, archivedName, ct);
			}

			await UploadSmallFileAsync(ctx, folderPath, uploadFileName, localFilePath, ct);

			var publishedUrl = await TryGetPublishedFileUrlAsync(ctx, folderPath, uploadFileName, ct);

			_fileLog.Info($"{reportType} report uploaded to SharePoint as {uploadFileName}");

			if (!string.IsNullOrWhiteSpace(publishedUrl))
				return $"UPLOADED_URL -> {publishedUrl}";

			return $"UPLOADED -> {folderPath}/{uploadFileName}";
		}
		catch (Exception ex)
		{
			_logger.LogWarning(ex, "Failed SharePoint upload for {ReportType}", reportType);
			_fileLog.Error($"Failed SharePoint upload for {reportType}", ex);
			return "UPLOAD_FAILED";
		}
	}

	private async Task<string?> TryGetPublishedFileUrlAsync(
	GraphContext ctx,
	string folderPath,
	string fileName,
	CancellationToken ct)
	{
		try
		{
			using var response = await ctx.Http.GetAsync(
				$"https://graph.microsoft.com/v1.0/drives/{ctx.DriveId}/root:/{EncodePath(CombineSpPath(folderPath, fileName))}?$select=id,name,webUrl",
				ct);

			if (!response.IsSuccessStatusCode)
				return null;

			var json = await response.Content.ReadAsStringAsync(ct);
			using var doc = JsonDocument.Parse(json);

			var root = doc.RootElement;
			var itemId = root.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
			var webUrl = root.TryGetProperty("webUrl", out var webUrlEl) ? webUrlEl.GetString() : null;

			if (!string.IsNullOrWhiteSpace(itemId))
			{
				var shareLink = await TryCreateOrganizationViewLinkAsync(ctx, itemId!, ct);
				if (!string.IsNullOrWhiteSpace(shareLink))
					return shareLink;
			}

			return webUrl;
		}
		catch (Exception ex)
		{
			_logger.LogWarning(ex, "Failed to resolve published file URL for {FileName}", fileName);
			_fileLog.Error($"Failed to resolve published file URL for {fileName}", ex);
			return null;
		}
	}

	private async Task<string?> TryCreateOrganizationViewLinkAsync(
		GraphContext ctx,
		string itemId,
		CancellationToken ct)
	{
		try
		{
			using var request = new HttpRequestMessage(
				HttpMethod.Post,
				$"https://graph.microsoft.com/v1.0/drives/{ctx.DriveId}/items/{itemId}/createLink");

			request.Content = new StringContent(
				"{\"type\":\"view\",\"scope\":\"organization\"}",
				Encoding.UTF8,
				"application/json");

			using var response = await ctx.Http.SendAsync(request, ct);
			if (!response.IsSuccessStatusCode)
				return null;

			var json = await response.Content.ReadAsStringAsync(ct);
			using var doc = JsonDocument.Parse(json);

			if (doc.RootElement.TryGetProperty("link", out var linkEl) &&
				linkEl.TryGetProperty("webUrl", out var webUrlEl))
			{
				return webUrlEl.GetString();
			}

			return null;
		}
		catch (Exception ex)
		{
			_logger.LogWarning(ex, "Failed to create organization view link for item {ItemId}", itemId);
			_fileLog.Error($"Failed to create organization view link for item {itemId}", ex);
			return null;
		}
	}

	private void ArchiveMatchingLocalFiles(string rootFolder, string safeLabName, string reportType)
	{
		Directory.CreateDirectory(rootFolder);

		var archiveFolder = Path.Combine(rootFolder, "Archive");
		Directory.CreateDirectory(archiveFolder);

		foreach (var filePath in Directory.EnumerateFiles(rootFolder, "*.xlsx", SearchOption.TopDirectoryOnly))
		{
			var fileName = Path.GetFileName(filePath);
			if (!IsMatchingReportFile(fileName, safeLabName, reportType))
				continue;

			var destination = Path.Combine(archiveFolder, BuildArchiveFileName(fileName));
			if (File.Exists(destination))
			{
				destination = Path.Combine(
					archiveFolder,
					$"{Path.GetFileNameWithoutExtension(destination)}_{DateTime.Now:yyyyMMddHHmmssfff}{Path.GetExtension(destination)}");
			}

			File.Move(filePath, destination);
		}
	}

	private static bool IsMatchingReportFile(string fileName, string safeLabName, string reportType)
	{
		if (string.IsNullOrWhiteSpace(fileName))
			return false;

		var marker = "_" + safeLabName + "_" + reportType + "_";
		return fileName.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)
			   && fileName.Contains(marker, StringComparison.OrdinalIgnoreCase);
	}

	private static string BuildArchiveFileName(string fileName)
	{
		var baseName = Path.GetFileNameWithoutExtension(fileName);
		var ext = Path.GetExtension(fileName);
		return $"{baseName}_Archived_{DateTime.Now:yyyyMMddHHmmss}{ext}";
	}

	private async Task<GraphContext> CreateGraphContextAsync(CancellationToken ct)
	{
		var sharePointSection = GetSharePointSection();

		var tenantId = sharePointSection["TenantId"] ?? throw new InvalidOperationException("SharePoint TenantId missing.");
		var clientId = sharePointSection["ClientId"] ?? throw new InvalidOperationException("SharePoint ClientId missing.");
		var clientSecret = sharePointSection["ClientSecret"] ?? throw new InvalidOperationException("SharePoint ClientSecret missing.");
		var hostname = sharePointSection["Hostname"] ?? throw new InvalidOperationException("SharePoint Hostname missing.");
		var sitePath = sharePointSection["SitePath"] ?? throw new InvalidOperationException("SharePoint SitePath missing.");
		var driveName = sharePointSection["DriveName"] ?? "Documents";

		var http = _httpClientFactory.CreateClient();

		var token = await GetAccessTokenAsync(http, tenantId, clientId, clientSecret, ct);
		http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

		var siteId = await GetSiteIdAsync(http, hostname, sitePath, ct);
		var driveId = await GetDriveIdAsync(http, siteId, driveName, ct);

		return new GraphContext(http, siteId, driveId, driveName);
	}

	private static async Task<string> GetAccessTokenAsync(
		HttpClient http,
		string tenantId,
		string clientId,
		string clientSecret,
		CancellationToken ct)
	{
		using var content = new FormUrlEncodedContent(new Dictionary<string, string>
		{
			["grant_type"] = "client_credentials",
			["client_id"] = clientId,
			["client_secret"] = clientSecret,
			["scope"] = "https://graph.microsoft.com/.default"
		});

		using var response = await http.PostAsync(
			$"https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token",
			content,
			ct);

		response.EnsureSuccessStatusCode();

		var json = await response.Content.ReadAsStringAsync();
		using var doc = JsonDocument.Parse(json);

		return doc.RootElement.GetProperty("access_token").GetString()
			   ?? throw new InvalidOperationException("Graph token missing.");
	}

	private static async Task<string> GetSiteIdAsync(
		HttpClient http,
		string hostname,
		string sitePath,
		CancellationToken ct)
	{
		using var response = await http.GetAsync(
			$"https://graph.microsoft.com/v1.0/sites/{hostname}:{sitePath}",
			ct);

		response.EnsureSuccessStatusCode();

		var json = await response.Content.ReadAsStringAsync();
		using var doc = JsonDocument.Parse(json);

		return doc.RootElement.GetProperty("id").GetString()
			   ?? throw new InvalidOperationException("Site id missing.");
	}

	private static async Task<string> GetDriveIdAsync(
		HttpClient http,
		string siteId,
		string driveName,
		CancellationToken ct)
	{
		using var response = await http.GetAsync(
			$"https://graph.microsoft.com/v1.0/sites/{siteId}/drives",
			ct);

		response.EnsureSuccessStatusCode();

		var json = await response.Content.ReadAsStringAsync();
		using var doc = JsonDocument.Parse(json);

		foreach (var item in doc.RootElement.GetProperty("value").EnumerateArray())
		{
			var name = item.GetProperty("name").GetString();
			if (string.Equals(name, driveName, StringComparison.OrdinalIgnoreCase))
			{
				return item.GetProperty("id").GetString()
					   ?? throw new InvalidOperationException("Drive id missing.");
			}
		}

		throw new InvalidOperationException($"Drive '{driveName}' not found.");
	}

	private static async Task EnsureFolderPathAsync(GraphContext ctx, string folderPath, CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(folderPath))
			return;

		var segments = folderPath
			.Split('/', StringSplitOptions.RemoveEmptyEntries);

		var currentPath = string.Empty;

		foreach (var segment in segments)
		{
			currentPath = string.IsNullOrWhiteSpace(currentPath)
				? segment
				: currentPath + "/" + segment;

			var exists = await PathExistsAsync(ctx, currentPath, ct);
			if (exists)
				continue;

			var parentPath = string.Empty;
			var lastSlash = currentPath.LastIndexOf('/');
			if (lastSlash > 0)
				parentPath = currentPath.Substring(0, lastSlash);

			string endpoint;
			if (string.IsNullOrWhiteSpace(parentPath))
			{
				endpoint = $"https://graph.microsoft.com/v1.0/drives/{ctx.DriveId}/root/children";
			}
			else
			{
				endpoint = $"https://graph.microsoft.com/v1.0/drives/{ctx.DriveId}/root:/{EncodePath(parentPath)}:/children";
			}

			var payloadMap = new Dictionary<string, object>
			{
				["name"] = segment,
				["folder"] = new Dictionary<string, object>(),
				["@microsoft.graph.conflictBehavior"] = "replace"
			};

			var payload = JsonSerializer.Serialize(payloadMap);

			using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
			request.Content = new StringContent(payload, Encoding.UTF8, "application/json");

			using var response = await ctx.Http.SendAsync(request, ct);
			response.EnsureSuccessStatusCode();
		}
	}

	private static async Task<bool> PathExistsAsync(GraphContext ctx, string folderPath, CancellationToken ct)
	{
		using var response = await ctx.Http.GetAsync(
			$"https://graph.microsoft.com/v1.0/drives/{ctx.DriveId}/root:/{EncodePath(folderPath)}",
			ct);

		if (response.StatusCode == HttpStatusCode.NotFound)
			return false;

		response.EnsureSuccessStatusCode();
		return true;
	}

	private static async Task<List<GraphFileItem>> ListFilesAsync(GraphContext ctx, string folderPath, CancellationToken ct)
	{
		using var response = await ctx.Http.GetAsync(
			$"https://graph.microsoft.com/v1.0/drives/{ctx.DriveId}/root:/{EncodePath(folderPath)}:/children",
			ct);

		response.EnsureSuccessStatusCode();

		var json = await response.Content.ReadAsStringAsync();
		using var doc = JsonDocument.Parse(json);

		var list = new List<GraphFileItem>();

		foreach (var item in doc.RootElement.GetProperty("value").EnumerateArray())
		{
			if (!item.TryGetProperty("file", out _))
				continue;

			var id = item.GetProperty("id").GetString() ?? string.Empty;
			var name = item.GetProperty("name").GetString() ?? string.Empty;

			if (!string.IsNullOrWhiteSpace(id) && !string.IsNullOrWhiteSpace(name))
				list.Add(new GraphFileItem(id, name));
		}

		return list;
	}

	private static async Task MoveFileAsync(
		GraphContext ctx,
		string itemId,
		string destinationFolderPath,
		string destinationFileName,
		CancellationToken ct)
	{
		var payload = JsonSerializer.Serialize(new
		{
			parentReference = new
			{
				path = "/drives/" + ctx.DriveId + "/root:/" + destinationFolderPath
			},
			name = destinationFileName
		});

		using var request = new HttpRequestMessage(
			HttpMethod.Patch,
			$"https://graph.microsoft.com/v1.0/drives/{ctx.DriveId}/items/{itemId}");

		request.Content = new StringContent(payload, Encoding.UTF8, "application/json");

		using var response = await ctx.Http.SendAsync(request, ct);
		response.EnsureSuccessStatusCode();
	}

	private static async Task UploadSmallFileAsync(
		GraphContext ctx,
		string folderPath,
		string fileName,
		string localFilePath,
		CancellationToken ct)
	{
		await using var stream = File.OpenRead(localFilePath);

		using var request = new HttpRequestMessage(
			HttpMethod.Put,
			$"https://graph.microsoft.com/v1.0/drives/{ctx.DriveId}/root:/{EncodePath(CombineSpPath(folderPath, fileName))}:/content");

		request.Content = new StreamContent(stream);
		request.Content.Headers.ContentType =
			new MediaTypeHeaderValue("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");

		using var response = await ctx.Http.SendAsync(request, ct);
		response.EnsureSuccessStatusCode();
	}

	private static string ResolveDriveRelativeFolderPath(string configuredValue, string driveName)
	{
		if (string.IsNullOrWhiteSpace(configuredValue))
			return string.Empty;

		if (!configuredValue.StartsWith("http", StringComparison.OrdinalIgnoreCase))
			return configuredValue.Trim().Trim('/');

		var uri = new Uri(configuredValue);
		var query = uri.Query.TrimStart('?');
		var pairs = query.Split('&', StringSplitOptions.RemoveEmptyEntries);

		string decodedPath = string.Empty;

		foreach (var pair in pairs)
		{
			var split = pair.Split('=', 2);
			if (split.Length != 2)
				continue;

			if (string.Equals(split[0], "id", StringComparison.OrdinalIgnoreCase))
			{
				decodedPath = WebUtility.UrlDecode(split[1]);
				break;
			}
		}

		if (string.IsNullOrWhiteSpace(decodedPath))
			return string.Empty;

		var markers = new[]
		{
			"/Shared Documents/",
			"/" + driveName + "/"
		};

		foreach (var marker in markers)
		{
			var idx = decodedPath.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
			if (idx >= 0)
				return decodedPath.Substring(idx + marker.Length).Trim('/');
		}

		return decodedPath.Trim('/');
	}

	private static bool ParseBool(string? value)
		=> bool.TryParse(value, out var parsed) && parsed;

	private static string SanitizeFileName(string value)
	{
		if (string.IsNullOrWhiteSpace(value))
			return string.Empty;

		var invalid = Path.GetInvalidFileNameChars();
		var chars = value.Select(c => invalid.Contains(c) ? '_' : c).ToArray();
		return new string(chars).Replace(' ', '_').Trim();
	}

	private static void CopyReplace(string sourcePath, string destinationPath)
	{
		var folder = Path.GetDirectoryName(destinationPath);
		if (!string.IsNullOrWhiteSpace(folder))
			Directory.CreateDirectory(folder);

		File.Copy(sourcePath, destinationPath, true);
	}

	private static void TryDelete(string path)
	{
		try
		{
			if (!string.IsNullOrWhiteSpace(path) && File.Exists(path))
				File.Delete(path);
		}
		catch
		{
		}
	}

	private static string CombineSpPath(params string[] parts)
	{
		return string.Join(
			"/",
			parts.Where(p => !string.IsNullOrWhiteSpace(p))
				 .Select(p => p.Trim('/')));
	}

	private static string EncodePath(string path)
	{
		return string.Join(
			"/",
			path.Split('/', StringSplitOptions.RemoveEmptyEntries)
				.Select(Uri.EscapeDataString));
	}

	public sealed class ModeMedianPublishResult
	{
		public string MedianLocalPath { get; set; } = string.Empty;
		public string ModeLocalPath { get; set; } = string.Empty;
		public string MedianLocalStatus { get; set; } = string.Empty;
		public string ModeLocalStatus { get; set; } = string.Empty;
		public string MedianSharePointStatus { get; set; } = string.Empty;
		public string ModeSharePointStatus { get; set; } = string.Empty;

		public string Summary
		{
			get
			{
				return "MedianLocal=" + MedianLocalStatus
					 + "; ModeLocal=" + ModeLocalStatus
					 + "; MedianSP=" + MedianSharePointStatus
					 + "; ModeSP=" + ModeSharePointStatus;
			}
		}
	}

	private sealed class GraphContext
	{
		public GraphContext(HttpClient http, string siteId, string driveId, string driveName)
		{
			Http = http;
			SiteId = siteId;
			DriveId = driveId;
			DriveName = driveName;
		}

		public HttpClient Http { get; }
		public string SiteId { get; }
		public string DriveId { get; }
		public string DriveName { get; }
	}

	private sealed class GraphFileItem
	{
		public GraphFileItem(string id, string name)
		{
			Id = id;
			Name = name;
		}

		public string Id { get; }
		public string Name { get; }
	}
}
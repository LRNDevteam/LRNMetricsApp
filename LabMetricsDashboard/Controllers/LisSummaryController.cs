using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.ViewModels;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

public class LisSummaryController : Controller
{
	private const string PreferredInitialLabName = "PCRLabsofAmerica";

	private readonly ILisSummaryRepository _lisSummaryRepository;
	private readonly IDenialRecordRepository _labRepository;
	private readonly LabSettings _labSettings;
	private readonly ILogger<LisSummaryController> _logger;

	public LisSummaryController(
		ILisSummaryRepository lisSummaryRepository,
		IDenialRecordRepository labRepository,
		LabSettings labSettings,
		ILogger<LisSummaryController> logger)
	{
		_lisSummaryRepository = lisSummaryRepository;
		_labRepository = labRepository;
		_labSettings = labSettings;
		_logger = logger;
	}

	[HttpGet]
	public async Task<IActionResult> Index(
		[FromQuery] LisSummaryFilters filters,
		[FromQuery] string? lab,
		CancellationToken cancellationToken)
	{
		filters ??= new LisSummaryFilters();

		var availableLabs = GetAvailableLisLabs();
		var selectedLabName = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
		selectedLabName = ResolveConfiguredLabKey(selectedLabName, availableLabs);

		if (availableLabs.Count == 0 || string.IsNullOrWhiteSpace(selectedLabName))
		{
			return View(new LisSummaryPageViewModel
			{
				Filters = filters,
				LabOptions = [],
				CurrentLabName = string.Empty,
				ErrorMessage = "No LIS Summary enabled labs were found."
			});
		}

		var labOptions = await GetLabOptionsAsync(availableLabs, cancellationToken);
		var selectedLabOption = ResolveSelectedLabOption(labOptions, selectedLabName, filters.LabId);
		filters.LabId = selectedLabOption?.LabId;

		if (!_labSettings.Labs.TryGetValue(selectedLabName, out var config))
		{
			return View(new LisSummaryPageViewModel
			{
				Filters = filters,
				LabOptions = labOptions,
				CurrentLabName = selectedLabName,
				ErrorMessage = $"Configuration not found for {selectedLabName}."
			});
		}

		if (!config.LineClaimEnable || string.IsNullOrWhiteSpace(config.DbConnectionString))
		{
			return View(new LisSummaryPageViewModel
			{
				Filters = filters,
				LabOptions = labOptions,
				CurrentLabName = selectedLabName,
				ErrorMessage = $"LIS Summary is currently not available for {selectedLabName}."
			});
		}

		try
		{
			var result = await _lisSummaryRepository.GetLisSummaryAsync(
				config.DbConnectionString,
				selectedLabOption?.LabName ?? selectedLabName,
				selectedLabOption?.LabId ?? 0,
				filters.CollectedFrom,
				filters.CollectedTo,
				cancellationToken);

			ViewData["SelectedLab"] = selectedLabName;
			ViewData["PageLabel"] = "LIS Summary";

			return View(new LisSummaryPageViewModel
			{
				Filters = filters,
				LabOptions = labOptions,
				CurrentLabName = selectedLabOption?.LabName ?? selectedLabName,
				Result = result
			});
		}
		catch (Exception ex)
		{
			_logger.LogError(ex, "LIS Summary query failed for lab '{LabName}'.", selectedLabName);
			return View(new LisSummaryPageViewModel
			{
				Filters = filters,
				LabOptions = labOptions,
				CurrentLabName = selectedLabOption?.LabName ?? selectedLabName,
				ErrorMessage = $"Failed to load LIS Summary: {ex.Message}"
			});
		}
	}

	[HttpGet]
	public async Task<IActionResult> ExportToExcel(
		[FromQuery] LisSummaryFilters filters,
		[FromQuery] string? lab,
		CancellationToken cancellationToken)
	{
		filters ??= new LisSummaryFilters();

		var availableLabs = GetAvailableLisLabs();
		var selectedLabName = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
		selectedLabName = ResolveConfiguredLabKey(selectedLabName, availableLabs);

		if (availableLabs.Count == 0 || string.IsNullOrWhiteSpace(selectedLabName))
		{
			TempData["LisSummaryError"] = "No LIS Summary enabled labs were found for export.";
			return RedirectToAction(nameof(Index));
		}

		var labOptions = await GetLabOptionsAsync(availableLabs, cancellationToken);
		var selectedLabOption = ResolveSelectedLabOption(labOptions, selectedLabName, filters.LabId);
		filters.LabId = selectedLabOption?.LabId;

		if (!_labSettings.Labs.TryGetValue(selectedLabName, out var config)
			|| !config.LineClaimEnable
			|| string.IsNullOrWhiteSpace(config.DbConnectionString))
		{
			TempData["LisSummaryError"] = "LIS Summary export is not available for the selected lab.";
			return RedirectToAction(nameof(Index), new
			{
				lab = selectedLabName,
				LabId = filters.LabId,
				CollectedFrom = filters.CollectedFrom?.ToString("yyyy-MM-dd"),
				CollectedTo = filters.CollectedTo?.ToString("yyyy-MM-dd")
			});
		}

		try
		{
			var result = await _lisSummaryRepository.GetLisSummaryAsync(
				config.DbConnectionString,
				selectedLabOption?.LabName ?? selectedLabName,
				selectedLabOption?.LabId ?? 0,
				filters.CollectedFrom,
				filters.CollectedTo,
				cancellationToken);

			if (result.Rows.Count == 0)
			{
				TempData["LisSummaryError"] = $"No LIS Summary data found for export for {selectedLabOption?.LabName ?? selectedLabName}.";
				return RedirectToAction(nameof(Index), new
				{
					lab = selectedLabName,
					LabId = filters.LabId,
					CollectedFrom = filters.CollectedFrom?.ToString("yyyy-MM-dd"),
					CollectedTo = filters.CollectedTo?.ToString("yyyy-MM-dd")
				});
			}

			using var workbook = LisSummaryExcelExportBuilder.CreateWorkbook(
				result,
				selectedLabOption?.LabName ?? selectedLabName,
				filters.CollectedFrom,
				filters.CollectedTo);

			await using var stream = new MemoryStream();
			workbook.SaveAs(stream);
			stream.Position = 0;

			var safeLabName = MakeSafeFileName(selectedLabOption?.LabName ?? selectedLabName);
			var fileName = $"{safeLabName}_LIS_Summary_{DateTime.Now:yyyyMMddHHmmss}.xlsx";
			return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
		}
		catch (Exception ex)
		{
			_logger.LogError(ex, "LIS Summary Excel export failed for lab '{LabName}'.", selectedLabName);
			TempData["LisSummaryError"] = $"Failed to export LIS Summary: {ex.Message}";
			return RedirectToAction(nameof(Index), new
			{
				lab = selectedLabName,
				LabId = filters.LabId,
				CollectedFrom = filters.CollectedFrom?.ToString("yyyy-MM-dd"),
				CollectedTo = filters.CollectedTo?.ToString("yyyy-MM-dd")
			});
		}
	}

	private List<string> GetAvailableLisLabs()
	{
		// Same source and selection style as ProductionReport:
		// appsettings LabSettings drives the common header lab dropdown.
		return _labSettings.Labs
			.Where(x => x.Value.LineClaimEnable && !string.IsNullOrWhiteSpace(x.Value.DbConnectionString))
			.Select(x => x.Key)
			.OrderBy(x => x)
			.ToList();
	}

	private async Task<List<LabOption>> GetLabOptionsAsync(IReadOnlyCollection<string> availableLabs, CancellationToken cancellationToken)
	{
		var configuredTokens = availableLabs
			.Select(NormalizeLabToken)
			.ToHashSet(StringComparer.OrdinalIgnoreCase);

		var dbLabs = (await _labRepository.GetLabsAsync(cancellationToken))
			.Where(x => configuredTokens.Contains(NormalizeLabToken(x.LabName)))
			.OrderBy(x => x.LabName)
			.ThenBy(x => x.LabId)
			.ToList();

		return dbLabs;
	}

	private static LabOption? ResolveSelectedLabOption(
		IReadOnlyList<LabOption> labOptions,
		string selectedLabName,
		int? requestedLabId)
	{
		if (requestedLabId.HasValue)
		{
			var byId = labOptions.FirstOrDefault(x => x.LabId == requestedLabId.Value);
			if (byId is not null && SameLab(byId.LabName, selectedLabName))
				return byId;
		}

		var selectedToken = NormalizeLabToken(selectedLabName);
		return labOptions.FirstOrDefault(x => SameLab(x.LabName, selectedLabName))
			?? labOptions.FirstOrDefault(x => NormalizeLabToken(x.LabName).Equals(selectedToken, StringComparison.OrdinalIgnoreCase))
			?? labOptions.FirstOrDefault(x => SameLab(x.LabName, PreferredInitialLabName));
	}

	private static bool SameLab(string left, string right)
		=> left.Equals(right, StringComparison.OrdinalIgnoreCase)
		   || NormalizeLabToken(left).Equals(NormalizeLabToken(right), StringComparison.OrdinalIgnoreCase);

	private static string ResolveConfiguredLabKey(string selectedLabName, IReadOnlyList<string> availableLabs)
	{
		if (string.IsNullOrWhiteSpace(selectedLabName)) return string.Empty;

		var selectedToken = NormalizeLabToken(selectedLabName);
		return availableLabs.FirstOrDefault(x => NormalizeLabToken(x).Equals(selectedToken, StringComparison.OrdinalIgnoreCase))
			?? selectedLabName;
	}

	private static string NormalizeLabToken(string value)
		=> new string((value ?? string.Empty)
			.Where(char.IsLetterOrDigit)
			.Select(char.ToUpperInvariant)
			.ToArray());

	private static string MakeSafeFileName(string value)
	{
		var invalidChars = Path.GetInvalidFileNameChars();
		var safe = new string(value.Select(ch => invalidChars.Contains(ch) ? '_' : ch).ToArray()).Trim('_');
		return string.IsNullOrWhiteSpace(safe) ? "Lab" : safe;
	}
}

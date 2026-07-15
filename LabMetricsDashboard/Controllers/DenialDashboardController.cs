using System.Globalization;
using System.Security.Claims;
using CsvHelper;
using CsvHelper.Configuration;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.DenialDashboard;
using LabMetricsDashboard.ViewModels;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Routing;

namespace LabMetricsDashboard.Controllers;

public class DenialDashboardController : Controller
{
	private const string PreferredInitialLabName = "PCR Labs of America";

	private static readonly string[] DeadlineBuckets =
	[
		"Overdue",
		"Due in 3 Days",
		"Due This Week",
		"Due This Month"
	];

	private readonly IDenialDashboardApiClient _dashboardApi;
	private readonly IUserManagementRepository _userRepository;

	public DenialDashboardController(IDenialDashboardApiClient dashboardApi, IUserManagementRepository userRepository)
	{
		_dashboardApi = dashboardApi;
		_userRepository = userRepository;
	}

	[HttpGet]
	public async Task<IActionResult> Index(
		[FromQuery] DenialDashboardFilters filters,
		[FromQuery] string? lab,
		CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();

		var labs = (await _dashboardApi.GetLabsAsync(cancellationToken))
			.OrderBy(x => x.LabName)
			.ThenBy(x => x.LabId)
			.ToList();

		if (labs.Count == 0)
		{
			return View(new DashboardPageViewModel
			{
				Filters = Normalize(filters, null),
				LabOptions = new List<LabOption>(),
				CurrentLabName = string.Empty
			});
		}

		var currentLab = ResolveSelectedLab(HttpContext, labs, filters.LabId, lab);
		var selectedLabId = currentLab.LabId;
		filters.LabId = selectedLabId;
		var normalizedFilters = Normalize(filters, selectedLabId);
		var currentRunId = await _dashboardApi.GetCurrentRunIdAsync(selectedLabId, cancellationToken) ?? string.Empty;

		var isArManager = HasAnyRole("AR Manager", "ARManager");
		var isArReviewer = HasAnyRole("AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer");
		var currentUserName = User.Identity?.Name?.Trim() ?? string.Empty;
		if (isArReviewer && !isArManager && normalizedFilters.ActiveTab is not ("task-board" or "line-item"))
		{
			normalizedFilters.ActiveTab = "task-board";
		}
		else if (isArManager && normalizedFilters.ActiveTab is not ("denial-insight" or "task-board" or "line-item"))
		{
			normalizedFilters.ActiveTab = "denial-insight";
		}

		var allRecords = (await _dashboardApi.GetByLabAsync(selectedLabId, cancellationToken))
			.OrderBy(x => x.DueDate)
			.ThenBy(x => x.TaskId)
			.ToList();

		if (isArReviewer && !isArManager)
		{
			allRecords = allRecords
				.Where(x => string.Equals(x.AssignedTo?.Trim(), currentUserName, StringComparison.OrdinalIgnoreCase))
				.ToList();
		}

		var filteredRecords = ApplyFilters(allRecords, normalizedFilters)
			.OrderBy(x => x.DueDate)
			.ThenBy(x => x.TaskId)
			.ToList();

		var recordsPageSize = Math.Clamp(normalizedFilters.PageSize <= 0 ? 100 : normalizedFilters.PageSize, 50, 500);
		var filteredRecordCount = filteredRecords.Count;
		var recordsTotalPages = Math.Max(1, (int)Math.Ceiling(filteredRecordCount / (double)recordsPageSize));
		var recordsPage = Math.Clamp(normalizedFilters.Page <= 0 ? 1 : normalizedFilters.Page, 1, recordsTotalPages);
		var pagedRecords = filteredRecords.Skip((recordsPage - 1) * recordsPageSize).Take(recordsPageSize).ToList();

		var allInsights = (await _dashboardApi.GetInsightTableByLabAsync(selectedLabId, cancellationToken)).ToList();
		// Distinct code + description list drives the Denial Code filter dropdown (always shows every code,
		// regardless of the current selection).
		var insightDenialCodeOptions = allInsights
			.Where(x => !string.IsNullOrWhiteSpace(x.DenialCodes))
			.GroupBy(x => x.DenialCodes.Trim(), StringComparer.OrdinalIgnoreCase)
			.Select(g => new DenialCodeOption(g.Key, g.Select(x => x.Descriptions).FirstOrDefault(d => !string.IsNullOrWhiteSpace(d))?.Trim() ?? string.Empty))
			.OrderBy(x => x.Code, StringComparer.OrdinalIgnoreCase)
			.ToList();

		// Denial Code filter is applied in-memory (the insight table is a small pre-aggregated set),
		// so the table, totals, and summary strip all reflect the selected code.
		var insights = FilterInsights(allInsights, normalizedFilters);

		var insightPageSize = ClampInsightPageSize(normalizedFilters.InsightPageSize);
		var insightCount = insights.Count;
		var insightTotalPages = Math.Max(1, (int)Math.Ceiling(insightCount / (double)insightPageSize));
		var insightPage = Math.Clamp(normalizedFilters.InsightPage <= 0 ? 1 : normalizedFilters.InsightPage, 1, insightTotalPages);
		var pagedInsights = insights.Skip((insightPage - 1) * insightPageSize).Take(insightPageSize).ToList();

		var lineItemGrid = await BuildLineItemGridAsync(currentLab, normalizedFilters, currentRunId, cancellationToken);
		var lineItemPageSize = lineItemGrid.LineItemPageSize;
		var lineItemCount = lineItemGrid.LineItemCount;
		var lineItemTotalPages = lineItemGrid.LineItemTotalPages;
		var lineItemPage = lineItemGrid.LineItemPage;
		var pagedLineItems = lineItemGrid.PagedLineItems.ToList();

		var breakdownSource = (await _dashboardApi.GetBreakdownSourceByLabAsync(selectedLabId, normalizedFilters, cancellationToken)).ToList();
		var weeklyBreakdowns = BuildTrendBreakdowns(breakdownSource, monthly: false);
		var monthlyBreakdowns = BuildTrendBreakdowns(breakdownSource, monthly: true);
		var weeklyPivot = BuildBreakdownPivot(breakdownSource, monthly: false);
		var monthlyPivot = BuildBreakdownPivot(breakdownSource, monthly: true);

		var reviewerOptions = isArManager
			? (await _userRepository.GetUsersByRoleNamesAsync(new[] { "AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer" })).ToList()
			: new List<ReviewerOption>();

		var viewModel = new DashboardPageViewModel
		{
			Filters = normalizedFilters,
			CurrentLabName = currentLab.LabName,
			CurrentRunId = currentRunId,
			LabOptions = labs,
			AllRecordCount = allRecords.Count,
			FilteredRecordCount = filteredRecordCount,
			PagedRecords = pagedRecords,
			RecordsPage = recordsPage,
			RecordsPageSize = recordsPageSize,
			RecordsTotalPages = recordsTotalPages,
			Summary = BuildSummary(filteredRecords),
			StatusBreakdown = BuildBreakdown(filteredRecords, x => x.Status, ["Open", "In Progress", "Completed", "On Hold", "Escalated", "Closed"]),
			PriorityBreakdown = BuildBreakdown(filteredRecords, x => x.Priority, ["High", "Medium", "Low"]),
			ActionCategoryBreakdown = BuildBreakdown(filteredRecords, x => x.EffectiveActionCategory),
			ClassificationBreakdown = BuildBreakdown(filteredRecords, x => x.DenialClassification),
			DeadlineBreakdown = BuildDeadlineBreakdown(filteredRecords),
			StatusOptions = BuildOptions(allRecords.Select(x => x.Status)),
			PriorityOptions = BuildOptions(allRecords.Select(x => x.Priority)),
			ActionCategoryOptions = BuildOptions(allRecords.Select(x => x.EffectiveActionCategory)),
			ClassificationOptions = BuildOptions(allRecords.Select(x => x.DenialClassification)),
			DeadlineOptions = ["(All)", .. DeadlineBuckets],
			PagedInsights = pagedInsights,
			InsightDenialCodeOptions = insightDenialCodeOptions,
			InsightCount = insightCount,
			InsightPage = insightPage,
			InsightPageSize = insightPageSize,
			InsightTotalPages = insightTotalPages,
			InsightTotalDenials = insights.Sum(x => x.NoOfDenialCount),
			InsightTotalClaims = insights.Sum(x => x.NoOfClaimsCount),
			InsightTotalBalance = decimal.Round(insights.Sum(x => x.TotalBalance), 2),
			InsightTotalInsuranceBalance = decimal.Round(insights.Sum(x => x.InsuranceBalance), 2),
			PagedLineItems = pagedLineItems,
			LineItemCount = lineItemCount,
			LineItemPage = lineItemPage,
			LineItemPageSize = lineItemPageSize,
			LineItemTotalPages = lineItemTotalPages,
			WeeklyBreakdowns = weeklyBreakdowns,
			MonthlyBreakdowns = monthlyBreakdowns,
			WeeklyPivot = weeklyPivot,
			MonthlyPivot = monthlyPivot,
			IsArManager = isArManager,
			IsArReviewer = isArReviewer,
			ReviewerOptions = reviewerOptions
		};

		viewModel.Filters.Page = recordsPage;
		viewModel.Filters.PageSize = recordsPageSize;
		viewModel.Filters.InsightPage = insightPage;
		viewModel.Filters.InsightPageSize = insightPageSize;
		viewModel.Filters.LineItemPage = lineItemPage;
		viewModel.Filters.LineItemPageSize = lineItemPageSize;

		viewModel.LineItemGrid = lineItemGrid;
		viewModel.InsightGrid = BuildInsightGrid(pagedInsights, insights, insightPage, insightPageSize, insightTotalPages, insightCount, normalizedFilters, currentLab.LabName, currentRunId, isArManager, reviewerOptions);

		return View(viewModel);
	}

	// Excel-style grid page sizes (shared by both the Line Item and Denial Insight grids).
	public const int MinGridPageSize = 50;
	public const int MaxGridPageSize = 1000;
	public static readonly int[] GridPageSizes = { 50, 100, 250, 500, 1000 };

	private static int ClampInsightPageSize(int value) => Math.Clamp(value <= 0 ? MinGridPageSize : value, MinGridPageSize, MaxGridPageSize);
	private static int ClampLineItemPageSize(int value) => Math.Clamp(value <= 0 ? 100 : value, MinGridPageSize, MaxGridPageSize);

	// AJAX endpoint: renders just the Line Item grid partial for paging / per-column filtering
	// without a full page reload.
	[HttpGet]
	public async Task<IActionResult> LineItemGrid([FromQuery] DenialDashboardFilters filters, [FromQuery] string? lab, CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();
		var labs = (await _dashboardApi.GetLabsAsync(cancellationToken)).OrderBy(x => x.LabName).ThenBy(x => x.LabId).ToList();
		if (labs.Count == 0) return PartialView("_DenialLineItemGrid", new LineItemGridViewModel());

		var currentLab = ResolveSelectedLab(HttpContext, labs, filters.LabId, lab);
		filters.LabId = currentLab.LabId;
		var normalized = Normalize(filters, currentLab.LabId);
		var currentRunId = await _dashboardApi.GetCurrentRunIdAsync(currentLab.LabId, cancellationToken) ?? string.Empty;
		var grid = await BuildLineItemGridAsync(currentLab, normalized, currentRunId, cancellationToken);
		return PartialView("_DenialLineItemGrid", grid);
	}

	// AJAX endpoint: renders just the Denial Insight grid partial for paging / per-column filtering.
	[HttpGet]
	public async Task<IActionResult> InsightGrid([FromQuery] DenialDashboardFilters filters, [FromQuery] string? lab, CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();
		var labs = (await _dashboardApi.GetLabsAsync(cancellationToken)).OrderBy(x => x.LabName).ThenBy(x => x.LabId).ToList();
		if (labs.Count == 0) return PartialView("_DenialInsightGrid", new InsightGridViewModel());

		var currentLab = ResolveSelectedLab(HttpContext, labs, filters.LabId, lab);
		filters.LabId = currentLab.LabId;
		var normalized = Normalize(filters, currentLab.LabId);
		var currentRunId = await _dashboardApi.GetCurrentRunIdAsync(currentLab.LabId, cancellationToken) ?? string.Empty;

		var isArManager = HasAnyRole("AR Manager", "ARManager");
		var allInsights = (await _dashboardApi.GetInsightTableByLabAsync(currentLab.LabId, cancellationToken)).ToList();
		var insights = FilterInsights(allInsights, normalized);

		var pageSize = ClampInsightPageSize(normalized.InsightPageSize);
		var count = insights.Count;
		var totalPages = Math.Max(1, (int)Math.Ceiling(count / (double)pageSize));
		var page = Math.Clamp(normalized.InsightPage <= 0 ? 1 : normalized.InsightPage, 1, totalPages);
		var paged = insights.Skip((page - 1) * pageSize).Take(pageSize).ToList();

		var reviewerOptions = isArManager
			? (await _userRepository.GetUsersByRoleNamesAsync(new[] { "AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer" })).ToList()
			: new List<ReviewerOption>();

		var grid = BuildInsightGrid(paged, insights, page, pageSize, totalPages, count, normalized, currentLab.LabName, currentRunId, isArManager, reviewerOptions);
		return PartialView("_DenialInsightGrid", grid);
	}

	private async Task<LineItemGridViewModel> BuildLineItemGridAsync(LabOption currentLab, DenialDashboardFilters filters, string currentRunId, CancellationToken cancellationToken)
	{
		var pageSize = ClampLineItemPageSize(filters.LineItemPageSize);
		var count = await _dashboardApi.GetLineItemCountByLabAsync(currentLab.LabId, filters, cancellationToken);
		var totalPages = Math.Max(1, (int)Math.Ceiling(count / (double)pageSize));
		var page = Math.Clamp(filters.LineItemPage <= 0 ? 1 : filters.LineItemPage, 1, totalPages);
		var items = (await _dashboardApi.GetLineItemsByLabAsync(currentLab.LabId, page, pageSize, filters, cancellationToken)).ToList();

		filters.LineItemPage = page;
		filters.LineItemPageSize = pageSize;

		return new LineItemGridViewModel
		{
			PagedLineItems = items,
			LineItemPage = page,
			LineItemPageSize = pageSize,
			LineItemTotalPages = totalPages,
			LineItemCount = count,
			Filters = filters,
			CurrentLabName = currentLab.LabName,
			CurrentRunId = currentRunId
		};
	}

	private static InsightGridViewModel BuildInsightGrid(
		List<DenialInsightRecord> pagedInsights,
		List<DenialInsightRecord> filteredInsights,
		int page,
		int pageSize,
		int totalPages,
		int count,
		DenialDashboardFilters filters,
		string currentLabName,
		string currentRunId,
		bool isArManager,
		List<ReviewerOption> reviewerOptions)
	{
		filters.InsightPage = page;
		filters.InsightPageSize = pageSize;

		return new InsightGridViewModel
		{
			PagedInsights = pagedInsights,
			InsightPage = page,
			InsightPageSize = pageSize,
			InsightTotalPages = totalPages,
			InsightCount = count,
			InsightTotalDenials = filteredInsights.Sum(x => x.NoOfDenialCount),
			InsightTotalClaims = filteredInsights.Sum(x => x.NoOfClaimsCount),
			InsightTotalBalance = decimal.Round(filteredInsights.Sum(x => x.TotalBalance), 2),
			InsightTotalInsuranceBalance = decimal.Round(filteredInsights.Sum(x => x.InsuranceBalance), 2),
			Filters = filters,
			CurrentLabName = currentLabName,
			CurrentRunId = currentRunId,
			IsArManager = isArManager,
			ReviewerOptions = reviewerOptions
		};
	}

	// Applies the Denial Code filter plus any Excel-style per-column filters to the (small,
	// pre-aggregated) insight set in memory.
	private static List<DenialInsightRecord> FilterInsights(List<DenialInsightRecord> allInsights, DenialDashboardFilters filters)
	{
		IEnumerable<DenialInsightRecord> query = allInsights;

		if (!string.IsNullOrWhiteSpace(filters.DenialCode))
		{
			var selectedCode = filters.DenialCode.Trim();
			query = query.Where(x => string.Equals(x.DenialCodes?.Trim(), selectedCode, StringComparison.OrdinalIgnoreCase));
		}

		if (filters.ColumnFilters is { Count: > 0 })
		{
			foreach (var pair in filters.ColumnFilters)
			{
				if (!InsightColumnAccessors.TryGetValue(pair.Key, out var accessor)) continue;
				var term = pair.Value?.Trim();
				if (string.IsNullOrWhiteSpace(term)) continue;
				query = query.Where(x => (accessor(x) ?? string.Empty).Contains(term, StringComparison.OrdinalIgnoreCase));
			}
		}

		return query.ToList();
	}

	private static readonly Dictionary<string, Func<DenialInsightRecord, string>> InsightColumnAccessors = new(StringComparer.OrdinalIgnoreCase)
	{
		["DenialCodes"] = x => x.DenialCodes ?? string.Empty,
		["Descriptions"] = x => x.Descriptions ?? string.Empty,
		["NoOfDenialCount"] = x => x.NoOfDenialCount.ToString(CultureInfo.InvariantCulture),
		["NoOfClaimsCount"] = x => x.NoOfClaimsCount.ToString(CultureInfo.InvariantCulture),
		["TotalBalance"] = x => x.TotalBalance.ToString(CultureInfo.InvariantCulture),
		["HighImpactInsurance"] = x => x.HighImpactInsurance ?? string.Empty,
		["InsuranceBalance"] = x => x.InsuranceBalance.ToString(CultureInfo.InvariantCulture),
		["ImpactPercentage"] = x => x.ImpactPercentage.ToString(CultureInfo.InvariantCulture),
		["ActionCategory"] = x => x.ActionCategory ?? string.Empty,
		["ActionCode"] = x => x.ActionCode ?? string.Empty,
		["Action"] = x => x.Action ?? string.Empty,
		["Task"] = x => x.Task ?? string.Empty,
		["Feedback"] = x => x.Feedback ?? string.Empty,
		["Responsibility"] = x => x.Responsibility ?? string.Empty,
		["ResponsibilityReviewer"] = x => x.ResponsibilityReviewer ?? string.Empty,
		["ETA"] = x => x.ETA ?? string.Empty
	};

	[HttpGet]
	public async Task<IActionResult> GetFilterAutocompleteOptions(int labId, CancellationToken cancellationToken)
	{
		if (labId <= 0) return BadRequest("Lab is required.");

		var labs = await _dashboardApi.GetLabsAsync(cancellationToken);
		if (labs.All(x => x.LabId != labId)) return NotFound();

		var payload = await _dashboardApi.GetFilterAutocompleteOptionsAsync(labId, cancellationToken);
		return Json(payload);
	}

	[HttpGet]
	public async Task<IActionResult> ExportToExcel(
		[FromQuery] DenialDashboardFilters filters,
		[FromQuery] string? lab,
		CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();

		var labs = (await _dashboardApi.GetLabsAsync(cancellationToken))
			.OrderBy(x => x.LabName)
			.ThenBy(x => x.LabId)
			.ToList();

		if (labs.Count == 0)
		{
			TempData["DenialDashboardError"] = "No active labs were found.";
			return RedirectToAction(nameof(Index));
		}

		var selectedLab = ResolveSelectedLab(HttpContext, labs, filters.LabId, lab);
		filters.LabId = selectedLab.LabId;
		var normalizedFilters = Normalize(filters, selectedLab.LabId);

		// The workbook is always rebuilt from data fetched through the API. The previous
		// "serve the latest pre-built .xlsx off the report server's disk" shortcut was removed
		// when the Denial Dashboard data access moved into LRN.ReportsApi.
		var filteredRecords = ApplyFilters(await _dashboardApi.GetByLabAsync(selectedLab.LabId, cancellationToken), normalizedFilters)
			.OrderBy(x => x.DueDate)
			.ThenBy(x => x.TaskId)
			.ToList();
		var lineItems = (await _dashboardApi.GetLineItemsForExportByLabAsync(selectedLab.LabId, normalizedFilters, cancellationToken)).ToList();
		var breakdownSource = (await _dashboardApi.GetBreakdownSourceByLabAsync(selectedLab.LabId, normalizedFilters, cancellationToken)).ToList();
		var weeklyPivot = BuildBreakdownPivot(breakdownSource, monthly: false);
		var monthlyPivot = BuildBreakdownPivot(breakdownSource, monthly: true);
		var currentRunId = await _dashboardApi.GetCurrentRunIdAsync(selectedLab.LabId, cancellationToken) ?? string.Empty;

		using var workbook = DenialDashboardExcelExportBuilder.CreateWorkbook(lineItems, filteredRecords, weeklyPivot, monthlyPivot);

		await using var stream = new MemoryStream();
		workbook.SaveAs(stream);
		stream.Position = 0;

		var safeLabName = string.Join("_", selectedLab.LabName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
		var fileNameFiltered = $"{safeLabName}_DenialDashboard_Filtered_{(string.IsNullOrWhiteSpace(currentRunId) ? DateTime.Now : currentRunId)}_{DateTime.Now:yyyyMMddHHmmss}.xlsx";
		return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileNameFiltered);
	}

	[HttpPost]
	[ValidateAntiForgeryToken]
	public async Task<IActionResult> AssignInsightReviewersOverall(
		int labId,
		string? lab,
		string? runId,
		[FromForm] string[] denialCodes,
		[FromForm] string[] payerNames,
		[FromForm] string[] reviewerUserNames,
		[FromForm] DenialDashboardFilters filters,
		CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();
		filters.ActiveTab = "denial-insight";

		if (!HasAnyRole("AR Manager", "ARManager", "Admin"))
		{
			TempData["DenialDashboardError"] = "Only AR Manager can assign denial insight rows.";
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
		}

		if (denialCodes.Length == 0 || payerNames.Length == 0 || reviewerUserNames.Length == 0)
		{
			TempData["DenialDashboardError"] = "No denial insight rows were submitted for assignment.";
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
		}

		var rowCount = Math.Min(denialCodes.Length, Math.Min(payerNames.Length, reviewerUserNames.Length));
		var totalUpdated = 0;
		var selectedRows = 0;
		var assignedUsers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

		for (var i = 0; i < rowCount; i++)
		{
			var denialCode = denialCodes[i]?.Trim();
			var payerName = payerNames[i]?.Trim();
			var reviewerUserName = reviewerUserNames[i]?.Trim();

			if (string.IsNullOrWhiteSpace(denialCode) || string.IsNullOrWhiteSpace(payerName) || string.IsNullOrWhiteSpace(reviewerUserName))
			{
				continue;
			}

			selectedRows++;
			assignedUsers.Add(reviewerUserName);
			totalUpdated += await _dashboardApi.AssignReviewerByInsightAsync(labId, denialCode, payerName, reviewerUserName, runId, cancellationToken);
		}

		if (selectedRows == 0)
		{
			TempData["DenialDashboardError"] = "Please select at least one AR Reviewer before submitting.";
		}
		else if (totalUpdated > 0)
		{
			TempData["DenialDashboardSuccess"] = $"Submitted {selectedRows:N0} insight assignment row(s). Assigned {totalUpdated:N0} denial task(s) to {assignedUsers.Count:N0} reviewer(s).";
		}
		else
		{
			TempData["DenialDashboardError"] = "Assignments were submitted, but no matching denial tasks were found for the selected denial code and payer rows.";
		}

		return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
	}

	[HttpPost]
	[ValidateAntiForgeryToken]
	public async Task<IActionResult> UpdateReviewerTask(
		int labId,
		string? lab,
		string taskId,
		string status,
		string? reviewerComments,
		string? runId,
		[FromForm] DenialDashboardFilters filters,
		CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();
		filters.ActiveTab = "task-board";

		if (!HasAnyRole("AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer", "Admin"))
		{
			TempData["DenialDashboardError"] = "Only AR Reviewer can update task status and comments.";
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
		}

		var reviewerUserName = User.Identity?.Name?.Trim() ?? string.Empty;
		var updated = await _dashboardApi.UpdateReviewerTaskAsync(labId, taskId, status, reviewerComments ?? string.Empty, reviewerUserName, runId, cancellationToken);
		TempData[updated > 0 ? "DenialDashboardSuccess" : "DenialDashboardError"] =
			updated > 0 ? "Task updated successfully." : "Task update failed. Please confirm the task is assigned to you.";

		return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
	}

	[HttpPost]
	[ValidateAntiForgeryToken]
	public async Task<IActionResult> UpdateReviewerTasksOverall(
		int labId,
		string? lab,
		string? runId,
		[FromForm] string[] taskIds,
		[FromForm] string[] statuses,
		[FromForm] string[] reviewerComments,
		[FromForm] DenialDashboardFilters filters,
		CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();
		filters.ActiveTab = "task-board";

		if (!HasAnyRole("AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer", "Admin"))
		{
			TempData["DenialDashboardError"] = "Only AR Reviewer can update task status and comments.";
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
		}

		var reviewerUserName = User.Identity?.Name?.Trim() ?? string.Empty;
		var rowCount = Math.Min(taskIds?.Length ?? 0, Math.Max(statuses?.Length ?? 0, reviewerComments?.Length ?? 0));
		var updated = 0;
		var submitted = 0;

		for (var i = 0; i < rowCount; i++)
		{
			var taskId = taskIds[i]?.Trim();
			if (string.IsNullOrWhiteSpace(taskId)) continue;

			var status = i < statuses.Length ? statuses[i] : string.Empty;
			var comments = i < reviewerComments.Length ? reviewerComments[i] : string.Empty;
			submitted++;
			updated += await _dashboardApi.UpdateReviewerTaskAsync(labId, taskId, status, comments ?? string.Empty, reviewerUserName, runId, cancellationToken);
		}

		TempData[updated > 0 ? "DenialDashboardSuccess" : "DenialDashboardError"] =
			updated > 0
				? $"Saved {updated:N0} of {submitted:N0} assigned task update(s)."
				: "No task updates were saved. Please confirm the tasks are assigned to you.";

		return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
	}

	[HttpGet]
	public async Task<IActionResult> DownloadTaskBoardCsv(
		[FromQuery] DenialDashboardFilters filters,
		[FromQuery] string? lab,
		CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();
		var labs = (await _dashboardApi.GetLabsAsync(cancellationToken)).OrderBy(x => x.LabName).ThenBy(x => x.LabId).ToList();
		if (labs.Count == 0)
		{
			TempData["DenialDashboardError"] = "No labs were found for task-board export.";
			return RedirectToAction(nameof(Index));
		}

		var currentLab = ResolveSelectedLab(HttpContext, labs, filters.LabId, lab);
		var selectedLabId = currentLab.LabId;
		filters.LabId = selectedLabId;
		var normalizedFilters = Normalize(filters, selectedLabId);

		var records = ApplyFilters(await _dashboardApi.GetByLabAsync(selectedLabId, cancellationToken), normalizedFilters)
			.OrderBy(x => x.DueDate)
			.ThenBy(x => x.TaskId)
			.ToList();

		var isArManager = HasAnyRole("AR Manager", "ARManager");
		var isArReviewer = HasAnyRole("AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer");
		var currentUserName = User.Identity?.Name?.Trim() ?? string.Empty;
		if (isArReviewer && !isArManager)
		{
			records = records
				.Where(x => string.Equals(x.AssignedTo?.Trim(), currentUserName, StringComparison.OrdinalIgnoreCase))
				.ToList();
		}

		var rows = records.Select(x => new TaskBoardCsvRow
		{
			UniqueTrackId = x.UniqueTrackId,
			TaskId = x.TaskId,
			ClaimId = x.ClaimId,
			PatientAccountNumber = x.PatientAccountNumber,
			CptCode = x.CptCode,
			DenialCode = x.DenialCode,
			DenialDescription = x.DenialDescription,
			DenialClassification = x.DenialClassification,
			ActionCode = x.ActionCode,
			RecommendedAction = x.RecommendedAction,
			ActionCategory = x.EffectiveActionCategory,
			Task = x.Task,
			Priority = x.Priority,
			InsuranceBalance = x.InsuranceBalance,
			Status = x.Status,
			AssignedTo = x.AssignedTo,
			DateOpened = x.DateOpened,
			DueDate = x.DueDate,
			DateCompleted = x.DateCompleted,
			SlaDays = x.SlaDays,
			SlaStatus = x.SlaStatus,
			LabId = x.LabId,
			LabName = x.LabName,
			RunId = x.RunId
		}).ToList();

		await using var stream = new MemoryStream();
		await using (var writer = new StreamWriter(stream, leaveOpen: true))
		await using (var csv = new CsvWriter(writer, new CsvConfiguration(CultureInfo.InvariantCulture)))
		{
			await csv.WriteRecordsAsync(rows, cancellationToken);
			await writer.FlushAsync(cancellationToken);
		}

		stream.Position = 0;
		var safeLabName = string.Join("_", currentLab.LabName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
		var fileName = $"{safeLabName}_TaskBoard_{DateTime.Now:yyyyMMddHHmmss}.csv";
		return File(stream.ToArray(), "text/csv", fileName);
	}

	[HttpPost]
	[ValidateAntiForgeryToken]
	public async Task<IActionResult> UploadTaskBoardCsv(
		int? labId,
		string? lab,
		IFormFile? taskBoardCsv,
		[FromForm] DenialDashboardFilters filters,
		CancellationToken cancellationToken)
	{
		filters ??= new DenialDashboardFilters();
		filters.ActiveTab = "task-board";

		if (!labId.HasValue)
		{
			TempData["DenialDashboardError"] = "Please select a lab before uploading the task-board CSV.";
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, filters.LabId, lab));
		}

		if (taskBoardCsv is null || taskBoardCsv.Length == 0)
		{
			TempData["DenialDashboardError"] = "Please choose a CSV file to upload.";
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
		}

		if (!Path.GetExtension(taskBoardCsv.FileName).Equals(".csv", StringComparison.OrdinalIgnoreCase))
		{
			TempData["DenialDashboardError"] = "Only CSV files are supported for task-board upload.";
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
		}

		var uploadError = await FileUploadGuard.ValidateCsvAsync(taskBoardCsv, 25 * 1024 * 1024, cancellationToken);
		if (uploadError != null)
		{
			TempData["DenialDashboardError"] = uploadError;
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
		}

		List<TaskBoardCsvUpdate> updates;
		try
		{
			updates = await ReadTaskBoardCsvAsync(taskBoardCsv, cancellationToken);
		}
		catch (Exception ex)
		{
			TempData["DenialDashboardError"] = $"Task-board CSV upload failed: {ex.Message}";
			return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
		}

		var result = await _dashboardApi.UpdateTaskBoardAsync(labId.Value, updates, cancellationToken);
		var message = $"Task-board upload completed. Updated {result.UpdatedRows} row(s)";
		if (result.SkippedRows > 0) message += $", skipped {result.SkippedRows} row(s)";
		if (result.Errors.Count > 0)
		{
			message += ". " + string.Join(" ", result.Errors.Take(5));
			if (result.Errors.Count > 5) message += $" (+{result.Errors.Count - 5} more)";
		}

		TempData[result.Errors.Count > 0 ? "DenialDashboardError" : "DenialDashboardSuccess"] = message;
		return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId, lab));
	}

	private bool HasAnyRole(params string[] roleNames)
	{
		var wanted = roleNames
			.Where(x => !string.IsNullOrWhiteSpace(x))
			.Select(NormalizeRoleToken)
			.ToHashSet(StringComparer.OrdinalIgnoreCase);

		return User.Claims
			.Where(c => c.Type == ClaimTypes.Role || c.Type.Equals("role", StringComparison.OrdinalIgnoreCase))
			.Select(c => NormalizeRoleToken(c.Value))
			.Any(wanted.Contains);
	}

	private static string NormalizeRoleToken(string? value)
		=> new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

	private static RouteValueDictionary BuildIndexRouteValues(DenialDashboardFilters filters, int? labId, string? labName = null) => new(new Dictionary<string, object?>
	{
		["lab"] = labName,
		["LabId"] = labId ?? filters.LabId,
		["DenialCode"] = filters.DenialCode,
		["Status"] = filters.Status,
		["Priority"] = filters.Priority,
		["ActionCategory"] = filters.ActionCategory,
		["Deadline"] = filters.Deadline,
		["Classification"] = filters.Classification,
		["SalesRepname"] = filters.SalesRepname,
		["ClinicName"] = filters.ClinicName,
		["ReferringProvider"] = filters.ReferringProvider,
		["PayerName"] = filters.PayerName,
		["PayerType"] = filters.PayerType,
		["PanelName"] = filters.PanelName,
		["FirstBilledDateFrom"] = filters.FirstBilledDateFrom?.ToString("yyyy-MM-dd"),
		["FirstBilledDateTo"] = filters.FirstBilledDateTo?.ToString("yyyy-MM-dd"),
		["DateOfServiceFrom"] = filters.DateOfServiceFrom?.ToString("yyyy-MM-dd"),
		["DateOfServiceTo"] = filters.DateOfServiceTo?.ToString("yyyy-MM-dd"),
		["DenialDateFrom"] = filters.DenialDateFrom?.ToString("yyyy-MM-dd"),
		["DenialDateTo"] = filters.DenialDateTo?.ToString("yyyy-MM-dd"),
		["ActiveTab"] = string.IsNullOrWhiteSpace(filters.ActiveTab) ? "task-board" : filters.ActiveTab,
		["Page"] = filters.Page <= 0 ? 1 : filters.Page,
		["PageSize"] = filters.PageSize <= 0 ? 100 : filters.PageSize,
		["InsightPage"] = filters.InsightPage <= 0 ? 1 : filters.InsightPage,
		["InsightPageSize"] = filters.InsightPageSize <= 0 ? 25 : filters.InsightPageSize,
		["LineItemPage"] = filters.LineItemPage <= 0 ? 1 : filters.LineItemPage,
		["LineItemPageSize"] = filters.LineItemPageSize <= 0 ? 100 : filters.LineItemPageSize
	});

	private static LabOption ResolveSelectedLab(HttpContext httpContext, IReadOnlyList<LabOption> labs, int? requestedLabId, string? requestedLabName)
	{
		if (labs.Count == 0) throw new InvalidOperationException("No active labs were found.");

		var availableLabNames = labs.Select(x => x.LabName)
			.Where(x => !string.IsNullOrWhiteSpace(x))
			.Distinct(StringComparer.OrdinalIgnoreCase)
			.OrderBy(x => x)
			.ToList();

		if (!string.IsNullOrWhiteSpace(requestedLabName))
		{
			var resolvedName = LabSelectionHelper.Resolve(httpContext, requestedLabName, availableLabNames);
			var byName = FindLabByName(labs, resolvedName) ?? FindLabByName(labs, requestedLabName);
			if (byName is not null) return byName;
		}

		if (requestedLabId.HasValue)
		{
			var byId = labs.FirstOrDefault(x => x.LabId == requestedLabId.Value);
			if (byId is not null) return byId;
		}

		var sessionResolvedName = LabSelectionHelper.Resolve(httpContext, null, availableLabNames);
		var sessionLab = FindLabByName(labs, sessionResolvedName);
		if (sessionLab is not null) return sessionLab;

		return labs.FirstOrDefault(x => x.LabName.Equals(PreferredInitialLabName, StringComparison.OrdinalIgnoreCase)) ?? labs.First();
	}

	private static LabOption? FindLabByName(IReadOnlyList<LabOption> labs, string? labName)
	{
		if (string.IsNullOrWhiteSpace(labName)) return null;
		var token = NormalizeLabToken(labName);
		return labs.FirstOrDefault(x => x.LabName.Equals(labName, StringComparison.OrdinalIgnoreCase) || NormalizeLabToken(x.LabName).Equals(token, StringComparison.OrdinalIgnoreCase));
	}

	private static string NormalizeLabToken(string value)
		=> new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

	private static async Task<List<TaskBoardCsvUpdate>> ReadTaskBoardCsvAsync(IFormFile csvFile, CancellationToken cancellationToken)
	{
		using var stream = csvFile.OpenReadStream();
		using var reader = new StreamReader(stream);
		var configuration = new CsvConfiguration(CultureInfo.InvariantCulture)
		{
			MissingFieldFound = null,
			HeaderValidated = null,
			BadDataFound = null,
			TrimOptions = TrimOptions.Trim,
			PrepareHeaderForMatch = args => NormalizeCsvHeader(args.Header)
		};

		using var csv = new CsvReader(reader, configuration);
		var updates = new List<TaskBoardCsvUpdate>();
		if (!await csv.ReadAsync()) return updates;
		csv.ReadHeader();

		while (await csv.ReadAsync())
		{
			cancellationToken.ThrowIfCancellationRequested();
			var taskId = GetCsvField(csv, "taskid", "task_id", "task id");
			var uniqueTrackId = GetCsvField(csv, "uniquetrackid", "unique_track_id", "unique track id");
			var status = GetCsvField(csv, "status", "taskstatus", "task status");
			var assignedTo = GetCsvField(csv, "assignedto", "assigned_to", "assigned to");
			var runId = GetCsvField(csv, "runid", "run_id", "run id");
			var dateText = GetCsvField(csv, "datecompleted", "completeddate", "closeddate", "completed date", "closed date", "completeddatecloseddate", "completed date/closed date");
			if (string.IsNullOrWhiteSpace(taskId) && string.IsNullOrWhiteSpace(uniqueTrackId)) continue;
			updates.Add(new TaskBoardCsvUpdate
			{
				TaskId = taskId?.Trim() ?? string.Empty,
				UniqueTrackId = uniqueTrackId?.Trim() ?? string.Empty,
				Status = status?.Trim() ?? string.Empty,
				AssignedTo = assignedTo?.Trim() ?? string.Empty,
				RunId = runId?.Trim() ?? string.Empty,
				DateCompleted = ParseCsvDate(dateText)
			});
		}

		return updates;
	}

	private static string? GetCsvField(CsvReader csv, params string[] candidateHeaders)
	{
		foreach (var header in candidateHeaders)
		{
			try
			{
				var value = csv.GetField(header);
				if (value is not null) return value;
			}
			catch { }
		}
		return null;
	}

	private static DateTime? ParseCsvDate(string? value)
	{
		if (string.IsNullOrWhiteSpace(value)) return null;
		if (DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var parsed)
			|| DateTime.TryParse(value, CultureInfo.CurrentCulture, DateTimeStyles.AllowWhiteSpaces, out parsed))
		{
			return parsed;
		}
		return null;
	}

	private static string NormalizeCsvHeader(string? header)
		=> string.IsNullOrWhiteSpace(header) ? string.Empty : new string(header.Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();

	private static DenialDashboardFilters Normalize(DenialDashboardFilters filters, int? selectedLabId)
	{
		var activeTab = string.IsNullOrWhiteSpace(filters.ActiveTab) ? "dashboard" : filters.ActiveTab.Trim();
		if (activeTab.Equals("claim-view", StringComparison.OrdinalIgnoreCase)) activeTab = "line-item";
		// The Denial Input tab is hidden; its pane no longer renders, so send old links to the dashboard.
		if (activeTab.Equals("denial-input", StringComparison.OrdinalIgnoreCase)) activeTab = "dashboard";

		return new DenialDashboardFilters
		{
			LabId = selectedLabId,
			DenialCode = string.IsNullOrWhiteSpace(filters.DenialCode) ? string.Empty : filters.DenialCode.Trim(),
			Status = NormalizeMultiChoice(filters.Status, allowAll: true),
			Priority = NormalizeMultiChoice(filters.Priority, allowAll: true),
			ActionCategory = NormalizeMultiChoice(filters.ActionCategory, allowAll: true),
			Deadline = NormalizeMultiChoice(filters.Deadline, allowAll: true),
			Classification = NormalizeMultiChoice(filters.Classification, allowAll: true),
			SalesRepname = NormalizeMultiChoice(filters.SalesRepname),
			ClinicName = NormalizeMultiChoice(filters.ClinicName),
			ReferringProvider = NormalizeMultiChoice(filters.ReferringProvider),
			PayerName = NormalizeMultiChoice(filters.PayerName),
			PayerType = NormalizeMultiChoice(filters.PayerType),
			PanelName = NormalizeMultiChoice(filters.PanelName),
			FirstBilledDateFrom = filters.FirstBilledDateFrom?.Date,
			FirstBilledDateTo = filters.FirstBilledDateTo?.Date,
			DateOfServiceFrom = filters.DateOfServiceFrom?.Date,
			DateOfServiceTo = filters.DateOfServiceTo?.Date,
			DenialDateFrom = filters.DenialDateFrom?.Date,
			DenialDateTo = filters.DenialDateTo?.Date,
			ActiveTab = activeTab,
			Page = filters.Page <= 0 ? 1 : filters.Page,
			PageSize = filters.PageSize <= 0 ? 100 : filters.PageSize,
			InsightPage = filters.InsightPage <= 0 ? 1 : filters.InsightPage,
			InsightPageSize = filters.InsightPageSize <= 0 ? 25 : filters.InsightPageSize,
			LineItemPage = filters.LineItemPage <= 0 ? 1 : filters.LineItemPage,
			LineItemPageSize = filters.LineItemPageSize <= 0 ? 100 : filters.LineItemPageSize,
			ColumnFilters = NormalizeColumnFilters(filters.ColumnFilters)
		};
	}

	private static Dictionary<string, string> NormalizeColumnFilters(Dictionary<string, string>? columnFilters)
	{
		var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
		if (columnFilters is null) return result;
		foreach (var pair in columnFilters)
		{
			if (string.IsNullOrWhiteSpace(pair.Key) || string.IsNullOrWhiteSpace(pair.Value)) continue;
			result[pair.Key.Trim()] = pair.Value.Trim();
		}
		return result;
	}

	private static string NormalizeMultiChoice(string? value, bool allowAll = false)
	{
		if (string.IsNullOrWhiteSpace(value)) return allowAll ? "(All)" : string.Empty;
		var items = ParseSelectedValues(value, allowAll).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
		if (items.Count == 0) return allowAll ? "(All)" : string.Empty;
		return string.Join("|", items);
	}

	private static IEnumerable<DenialRecord> ApplyFilters(IEnumerable<DenialRecord> records, DenialDashboardFilters filters)
	{
		var statusSet = ParseSelectedValues(filters.Status, true).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var prioritySet = ParseSelectedValues(filters.Priority, true).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var actionSet = ParseSelectedValues(filters.ActionCategory, true).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var classSet = ParseSelectedValues(filters.Classification, true).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var deadlineSet = ParseSelectedValues(filters.Deadline, true).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var salesSet = ParseSelectedValues(filters.SalesRepname).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var clinicSet = ParseSelectedValues(filters.ClinicName).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var providerSet = ParseSelectedValues(filters.ReferringProvider).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var payerSet = ParseSelectedValues(filters.PayerName).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var payerTypeSet = ParseSelectedValues(filters.PayerType).ToHashSet(StringComparer.OrdinalIgnoreCase);
		var panelSet = ParseSelectedValues(filters.PanelName).ToHashSet(StringComparer.OrdinalIgnoreCase);

		var query = records;
		if (statusSet.Count > 0) query = query.Where(x => statusSet.Contains((x.Status ?? string.Empty).Trim()));
		if (prioritySet.Count > 0) query = query.Where(x => prioritySet.Contains((x.Priority ?? string.Empty).Trim()));
		if (actionSet.Count > 0) query = query.Where(x => actionSet.Contains((x.EffectiveActionCategory ?? string.Empty).Trim()));
		if (classSet.Count > 0) query = query.Where(x => classSet.Contains((x.DenialClassification ?? string.Empty).Trim()));
		if (deadlineSet.Count > 0) query = query.Where(x => deadlineSet.Any(bucket => IsInDeadlineBucket(x, bucket)));
		if (salesSet.Count > 0) query = query.Where(x => salesSet.Contains((x.SalesRepname ?? string.Empty).Trim()));
		if (clinicSet.Count > 0) query = query.Where(x => clinicSet.Contains((x.ClinicName ?? string.Empty).Trim()));
		if (providerSet.Count > 0) query = query.Where(x => providerSet.Contains((x.ReferringProvider ?? string.Empty).Trim()));
		if (payerSet.Count > 0) query = query.Where(x => payerSet.Contains((x.PayerName ?? string.Empty).Trim()));
		if (payerTypeSet.Count > 0) query = query.Where(x => payerTypeSet.Contains((x.PayerType ?? string.Empty).Trim()));
		if (panelSet.Count > 0) query = query.Where(x => panelSet.Contains((x.PanelName ?? string.Empty).Trim()));
		if (filters.FirstBilledDateFrom.HasValue) query = query.Where(x => x.FirstBilledDate.HasValue && x.FirstBilledDate.Value.Date >= filters.FirstBilledDateFrom.Value.Date);
		if (filters.FirstBilledDateTo.HasValue) query = query.Where(x => x.FirstBilledDate.HasValue && x.FirstBilledDate.Value.Date <= filters.FirstBilledDateTo.Value.Date);
		if (filters.DateOfServiceFrom.HasValue) query = query.Where(x => x.DateOfService.HasValue && x.DateOfService.Value.Date >= filters.DateOfServiceFrom.Value.Date);
		if (filters.DateOfServiceTo.HasValue) query = query.Where(x => x.DateOfService.HasValue && x.DateOfService.Value.Date <= filters.DateOfServiceTo.Value.Date);
		return query;
	}

	private static IReadOnlyList<string> ParseSelectedValues(string? raw, bool treatAllAsEmpty = false)
	{
		if (string.IsNullOrWhiteSpace(raw)) return Array.Empty<string>();
		var values = raw.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
		if (treatAllAsEmpty && values.Any(x => x.Equals("(All)", StringComparison.OrdinalIgnoreCase))) return Array.Empty<string>();
		return values;
	}

	private static bool EqualsIgnoreCase(string? left, string right) => string.Equals(left?.Trim(), right?.Trim(), StringComparison.OrdinalIgnoreCase);

	/// <summary>
	/// Statuses that take a task out of the open queue. Anything else - including the loader's
	/// default "New" and blank - counts as open, so the dashboard tiles never all read zero.
	/// </summary>
	private static readonly string[] NonOpenStatuses = ["In Progress", "On Hold", "Escalated", "Completed", "Closed"];

	private static bool IsOpenStatus(string? status) => !NonOpenStatuses.Any(x => EqualsIgnoreCase(status, x));

	private static bool IsCompletedStatus(string? status) => EqualsIgnoreCase(status, "Completed") || EqualsIgnoreCase(status, "Closed");

	private static bool IsInDeadlineBucket(DenialRecord record, string bucket)
	{
		if (record.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase)) return false;
		var today = DateTime.Today;
		return bucket switch
		{
			"Overdue" => record.DueDate.Date < today,
			"Due in 3 Days" => record.DueDate.Date >= today && record.DueDate.Date <= today.AddDays(3),
			"Due This Week" => record.DueDate.Date >= today && record.DueDate.Date <= today.AddDays(7),
			"Due This Month" => record.DueDate.Date >= today && record.DueDate.Date <= today.AddDays(30),
			_ => true
		};
	}

	private static DashboardSummary BuildSummary(List<DenialRecord> records)
	{
		var today = DateTime.Today;
		return new DashboardSummary
		{
			TotalTasks = records.Count,
			OpenTasks = records.Count(x => IsOpenStatus(x.Status)),
			InProgressTasks = records.Count(x => EqualsIgnoreCase(x.Status, "In Progress")),
			CompletedTasks = records.Count(x => IsCompletedStatus(x.Status)),
			OverdueTasks = records.Count(x => !x.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase) && x.DueDate.Date < today),
			DueInThreeDays = records.Count(x => !x.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase) && x.DueDate.Date >= today && x.DueDate.Date <= today.AddDays(3)),
			HighPriorityTasks = records.Count(x => EqualsIgnoreCase(x.Priority, "High")),
			EscalatedTasks = records.Count(x => EqualsIgnoreCase(x.Status, "Escalated")),
			TotalInsuranceBalance = records.Sum(x => x.InsuranceBalance)
		};
	}

	private static List<BreakdownItem> BuildBreakdown(List<DenialRecord> records, Func<DenialRecord, string> selector, IEnumerable<string>? preferredOrder = null)
	{
		var total = records.Count;
		var groups = records.GroupBy(x => selector(x) ?? string.Empty)
			.Select(group => new BreakdownItem
			{
				Label = string.IsNullOrWhiteSpace(group.Key) ? "(Blank)" : group.Key,
				Count = group.Count(),
				Percentage = total == 0 ? 0 : decimal.Round((decimal)group.Count() / total * 100m, 1),
				OpenCount = group.Count(x => IsOpenStatus(x.Status)),
				CompletedCount = group.Count(x => IsCompletedStatus(x.Status)),
				OverdueCount = group.Count(x => !x.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase) && x.DueDate.Date < DateTime.Today),
				HighPriorityCount = group.Count(x => EqualsIgnoreCase(x.Priority, "High")),
				InsuranceBalanceSum = decimal.Round(group.Sum(x => x.InsuranceBalance), 2),
				AverageSla = group.Any() ? Math.Round(group.Average(x => x.SlaDays), 1) : 0
			}).ToList();

		if (preferredOrder is null) return groups.OrderByDescending(x => x.Count).ThenBy(x => x.Label).ToList();
		var orderLookup = preferredOrder.Select((label, index) => new { label, index }).ToDictionary(x => x.label, x => x.index, StringComparer.OrdinalIgnoreCase);
		return groups.OrderBy(x => orderLookup.TryGetValue(x.Label, out var order) ? order : int.MaxValue).ThenByDescending(x => x.Count).ThenBy(x => x.Label).ToList();
	}

	private static List<BreakdownItem> BuildDeadlineBreakdown(List<DenialRecord> records)
	{
		return DeadlineBuckets.Select(bucket => new BreakdownItem
		{
			Label = bucket,
			Count = records.Count(x => IsInDeadlineBucket(x, bucket)),
			Percentage = records.Count == 0 ? 0 : decimal.Round((decimal)records.Count(x => IsInDeadlineBucket(x, bucket)) / records.Count * 100m, 1),
			OpenCount = records.Count(x => IsInDeadlineBucket(x, bucket) && IsOpenStatus(x.Status)),
			CompletedCount = records.Count(x => IsInDeadlineBucket(x, bucket) && IsCompletedStatus(x.Status)),
			OverdueCount = records.Count(x => IsInDeadlineBucket(x, bucket)),
			HighPriorityCount = records.Count(x => IsInDeadlineBucket(x, bucket) && EqualsIgnoreCase(x.Priority, "High")),
			InsuranceBalanceSum = decimal.Round(records.Where(x => IsInDeadlineBucket(x, bucket)).Sum(x => x.InsuranceBalance), 2),
			AverageSla = records.Where(x => IsInDeadlineBucket(x, bucket)).Select(x => (double)x.SlaDays).DefaultIfEmpty(0).Average()
		}).ToList();
	}

	private static List<string> BuildOptions(IEnumerable<string> values) => ["(All)", .. values.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x).ToList()];

	private static List<TrendBreakdownItem> BuildTrendBreakdowns(IEnumerable<DenialBreakdownSourceRecord> rows, bool monthly)
	{
		var datedRows = rows.Where(x => x.DenialDate.HasValue)
			.Select(x => new { DenialDate = x.DenialDate!.Value.Date, x.VisitNumber, x.InsuranceBalance, x.TotalBalance }).ToList();
		if (datedRows.Count == 0) return new List<TrendBreakdownItem>();

		if (monthly)
		{
			return datedRows.GroupBy(x => new { x.DenialDate.Year, x.DenialDate.Month })
				.OrderByDescending(x => x.Key.Year).ThenByDescending(x => x.Key.Month)
				.Select(group =>
				{
					var periodStart = new DateTime(group.Key.Year, group.Key.Month, 1);
					var periodEnd = periodStart.AddMonths(1).AddDays(-1);
					var totalBalance = decimal.Round(group.Sum(x => x.TotalBalance), 2);
					var insuranceBalance = decimal.Round(group.Sum(x => x.InsuranceBalance), 2);
					return new TrendBreakdownItem
					{
						Label = periodStart.ToString("MMM yyyy"),
						PeriodType = "Month",
						Year = group.Key.Year,
						PeriodNumber = group.Key.Month,
						PeriodName = periodStart.ToString("MMMM"),
						PeriodStart = periodStart,
						PeriodEnd = periodEnd,
						DenialCount = group.Count(),
						ClaimCount = group.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
						InsuranceBalance = insuranceBalance,
						TotalBalance = totalBalance,
						ImpactPercentage = totalBalance == 0 ? 0 : decimal.Round((insuranceBalance / totalBalance) * 100m, 2)
					};
				}).ToList();
		}

		return datedRows.GroupBy(x => { var weekStart = StartOfWeek(x.DenialDate); return new { IsoYear = ISOWeek.GetYear(weekStart), IsoWeek = ISOWeek.GetWeekOfYear(weekStart), WeekStart = weekStart }; })
			.OrderByDescending(x => x.Key.IsoYear).ThenByDescending(x => x.Key.IsoWeek)
			.Select(group =>
			{
				var periodStart = group.Key.WeekStart;
				var periodEnd = periodStart.AddDays(6);
				var totalBalance = decimal.Round(group.Sum(x => x.TotalBalance), 2);
				var insuranceBalance = decimal.Round(group.Sum(x => x.InsuranceBalance), 2);
				return new TrendBreakdownItem
				{
					Label = $"Week {group.Key.IsoWeek:00} ({periodStart:dd MMM yyyy} - {periodEnd:dd MMM yyyy})",
					PeriodType = "Week",
					Year = group.Key.IsoYear,
					PeriodNumber = group.Key.IsoWeek,
					PeriodName = $"Week {group.Key.IsoWeek:00}",
					PeriodStart = periodStart,
					PeriodEnd = periodEnd,
					DenialCount = group.Count(),
					ClaimCount = group.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
					InsuranceBalance = insuranceBalance,
					TotalBalance = totalBalance,
					ImpactPercentage = totalBalance == 0 ? 0 : decimal.Round((insuranceBalance / totalBalance) * 100m, 2)
				};
			}).ToList();
	}

	private static BreakdownPivotViewModel BuildBreakdownPivot(IEnumerable<DenialBreakdownSourceRecord> rows, bool monthly)
	{
		var prepared = rows.Where(x => x.DenialDate.HasValue)
			.Select(x => new PreparedBreakdownRow(x.DenialDate!.Value.Date, (x.VisitNumber ?? string.Empty).Trim(), x.InsuranceBalance, NormalizePivotText(x.PayerName, "(Blank Insurance)"), BuildDenialLabel(x.DenialCodeNormalized, x.DenialDescription)))
			.ToList();

		var periods = monthly
			? prepared.GroupBy(x => x.DenialDate.Year).OrderBy(g => g.Key).SelectMany(yearGroup =>
			{
				var year = yearGroup.Key;
				var monthPeriods = yearGroup.GroupBy(x => x.DenialDate.Month).OrderBy(g => g.Key).Select(g => new BreakdownPivotPeriod
				{
					Key = $"{year}-{g.Key:00}",
					Label = new DateTime(year, g.Key, 1).ToString("MMM"),
					StartDate = new DateTime(year, g.Key, 1),
					EndDate = new DateTime(year, g.Key, 1).AddMonths(1).AddDays(-1),
					Year = year,
					Month = g.Key,
					IsYearTotal = false
				}).ToList();
				monthPeriods.Add(new BreakdownPivotPeriod { Key = $"{year}-TOTAL", Label = $"{year} Total", StartDate = new DateTime(year, 12, 31), EndDate = new DateTime(year, 12, 31), Year = year, Month = null, IsYearTotal = true });
				return monthPeriods;
			}).ToList()
			: prepared.GroupBy(x => StartOfWeek(x.DenialDate)).Select(g => new BreakdownPivotPeriod { Key = g.Key.ToString("yyyy-MM-dd"), Label = $"{g.Key:MMM dd} - {g.Key.AddDays(6):MMM dd}", StartDate = g.Key, EndDate = g.Key.AddDays(6), Year = ISOWeek.GetYear(g.Key), Month = g.Key.Month, IsYearTotal = false }).OrderByDescending(x => x.StartDate).Take(4).OrderBy(x => x.StartDate).ToList();

		var model = new BreakdownPivotViewModel { HeaderTitle = monthly ? "All Months | Top 10 Payers | Denial Posted Date" : "Last 4 Weeks | Top 10 Payers | Denial Posted Date", SectionTitle = monthly ? "Monthly Breakdown" : "Weekly Breakdown", GrandTotalTitle = "Grand Total", Periods = periods };
		if (periods.Count == 0) return model;

		var selectedRows = monthly ? prepared : prepared.Where(x => periods.Any(period => PeriodContains(period, x.DenialDate, monthly))).ToList();
		if (selectedRows.Count == 0) return model;

		var rankedInsurerGroups = selectedRows.GroupBy(x => x.PayerName, StringComparer.OrdinalIgnoreCase)
			.Select(g => new PreparedInsurerGroup(g.Key, g.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(), decimal.Round(g.Sum(x => x.InsuranceBalance), 2), g.ToList()))
			.OrderByDescending(x => x.TotalClaimCount).ThenByDescending(x => x.TotalBalance).ThenBy(x => x.PayerName).Take(10).ToList();

		var allBalance = decimal.Round(selectedRows.Sum(x => x.InsuranceBalance), 2);
		var selectedBalance = rankedInsurerGroups.Sum(x => x.TotalBalance);
		model.TopPayerCount = rankedInsurerGroups.Count;
		model.CoveragePercentage = allBalance <= 0 ? 0 : decimal.Round((selectedBalance / allBalance) * 100m, 1);
		model.HeaderTitle = monthly ? $"All Months | Top {model.TopPayerCount} Payers | Covering {model.CoveragePercentage:N1}% of the AR | Denial Posted Date" : $"Last 4 Weeks | Top {model.TopPayerCount} Payers | Covering {model.CoveragePercentage:N1}% of the AR | Denial Posted Date";

		model.ColumnGroups = monthly
			? periods.GroupBy(x => x.Year).Select(g => new BreakdownPivotColumnGroup { Label = g.Key.ToString(CultureInfo.InvariantCulture), ColumnSpan = g.Count() * 2 }).Append(new BreakdownPivotColumnGroup { Label = model.GrandTotalTitle, ColumnSpan = 2 }).ToList()
			: periods.Select(p => new BreakdownPivotColumnGroup { Label = p.Label, ColumnSpan = 2 }).Append(new BreakdownPivotColumnGroup { Label = "Total", ColumnSpan = 2 }).ToList();

		var pivotRows = new List<BreakdownPivotRow>();
		for (var insurerIndex = 0; insurerIndex < rankedInsurerGroups.Count; insurerIndex++)
		{
			var insurer = rankedInsurerGroups[insurerIndex];
			pivotRows.Add(BuildBreakdownPivotRow(GetAlphaLabel(insurerIndex), insurer.PayerName, true, insurer.Rows, periods, monthly));
			var topDenials = insurer.Rows.GroupBy(x => x.DenialLabel, StringComparer.OrdinalIgnoreCase)
				.Select(g => new { DenialLabel = g.Key, ClaimCount = g.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(), TotalBalance = decimal.Round(g.Sum(x => x.InsuranceBalance), 2), Rows = g.ToList() })
				.OrderByDescending(x => x.ClaimCount).ThenByDescending(x => x.TotalBalance).ThenBy(x => x.DenialLabel).Take(3).ToList();
			for (var i = 0; i < topDenials.Count; i++)
			{
				pivotRows.Add(BuildBreakdownPivotRow((i + 1).ToString(CultureInfo.InvariantCulture), topDenials[i].DenialLabel, false, topDenials[i].Rows, periods, monthly));
			}
		}

		model.Rows = pivotRows;
		model.TotalsByPeriod = periods.Select(period =>
		{
			var periodRows = selectedRows.Where(x => PeriodContains(period, x.DenialDate, monthly)).ToList();
			return new BreakdownPivotCell { ClaimCount = periodRows.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(), DenialBalance = decimal.Round(periodRows.Sum(x => x.InsuranceBalance), 2) };
		}).ToList();
		model.GrandTotalClaimCount = selectedRows.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count();
		model.GrandTotalBalance = decimal.Round(selectedRows.Sum(x => x.InsuranceBalance), 2);
		return model;
	}

	private static BreakdownPivotRow BuildBreakdownPivotRow(string indexLabel, string label, bool isInsuranceRow, List<PreparedBreakdownRow> rows, List<BreakdownPivotPeriod> periods, bool monthly)
	{
		var cells = periods.Select(period =>
		{
			var periodRows = rows.Where(x => PeriodContains(period, x.DenialDate, monthly)).ToList();
			return new BreakdownPivotCell { ClaimCount = periodRows.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(), DenialBalance = decimal.Round(periodRows.Sum(x => x.InsuranceBalance), 2) };
		}).ToList();
		return new BreakdownPivotRow { IndexLabel = indexLabel, Label = label, IsInsuranceRow = isInsuranceRow, Cells = cells, TotalClaimCount = rows.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(), TotalBalance = decimal.Round(rows.Sum(x => x.InsuranceBalance), 2) };
	}

	private static string GetPeriodKey(DateTime value, bool monthly) => monthly ? value.ToString("yyyy-MM") : StartOfWeek(value).ToString("yyyy-MM-dd");

	private static bool PeriodContains(BreakdownPivotPeriod period, DateTime value, bool monthly)
	{
		if (monthly) return period.IsYearTotal ? value.Year == period.Year : value.Year == period.Year && value.Month == period.Month;
		return GetPeriodKey(value, monthly).Equals(period.Key, StringComparison.OrdinalIgnoreCase);
	}

	private static string BuildDenialLabel(string? code, string? description)
	{
		var cleanCode = NormalizePivotText(code, string.Empty);
		var cleanDescription = NormalizePivotText(description, string.Empty);
		if (string.IsNullOrWhiteSpace(cleanCode) && string.IsNullOrWhiteSpace(cleanDescription)) return "(Blank Denial)";
		if (string.IsNullOrWhiteSpace(cleanDescription)) return cleanCode;
		if (string.IsNullOrWhiteSpace(cleanCode)) return cleanDescription;
		return $"{cleanCode} - {cleanDescription}";
	}

	private static string NormalizePivotText(string? value, string fallback) => string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();

	private static string GetAlphaLabel(int index)
	{
		index = Math.Max(0, index);
		var label = string.Empty;
		do
		{
			label = (char)('A' + (index % 26)) + label;
			index = (index / 26) - 1;
		}
		while (index >= 0);
		return label;
	}

	private sealed record PreparedBreakdownRow(DateTime DenialDate, string VisitNumber, decimal InsuranceBalance, string PayerName, string DenialLabel);
	private sealed record PreparedInsurerGroup(string PayerName, int TotalClaimCount, decimal TotalBalance, List<PreparedBreakdownRow> Rows);

	private static DateTime StartOfWeek(DateTime value)
	{
		var diff = (7 + (value.DayOfWeek - DayOfWeek.Monday)) % 7;
		return value.AddDays(-diff).Date;
	}
}

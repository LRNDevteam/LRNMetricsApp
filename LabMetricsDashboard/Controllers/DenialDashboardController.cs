using System.Globalization;
using ClosedXML.Excel;
using CsvHelper;
using CsvHelper.Configuration;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
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

    private readonly IDenialRecordRepository _repository;

    public DenialDashboardController(IDenialRecordRepository repository)
    {
        _repository = repository;
    }

    [HttpGet]
    public async Task<IActionResult> Index([FromQuery] DenialDashboardFilters filters, CancellationToken cancellationToken)
    {
        filters ??= new DenialDashboardFilters();

        var labs = (await _repository.GetLabsAsync(cancellationToken))
            .OrderBy(x => x.LabName)
            .ThenBy(x => x.LabId)
            .ToList();

        if (labs.Count == 0)
        {
            return View(new DashboardPageViewModel { Filters = Normalize(filters, null), LabOptions = new List<LabOption>() });
        }

        var preferredLab = labs.FirstOrDefault(x => x.LabName.Equals(PreferredInitialLabName, StringComparison.OrdinalIgnoreCase))
            ?? labs.First();

        var selectedLabId = filters.LabId;
        if (!selectedLabId.HasValue || labs.All(x => x.LabId != selectedLabId.Value))
        {
            selectedLabId = preferredLab.LabId;
        }

        var currentLab = labs.First(x => x.LabId == selectedLabId.Value);
        var normalizedFilters = Normalize(filters, selectedLabId.Value);
        var currentRunId = await _repository.GetCurrentRunIdAsync(selectedLabId.Value, cancellationToken) ?? string.Empty;

        var allRecords = (await _repository.GetByLabAsync(selectedLabId.Value, cancellationToken))
            .OrderBy(x => x.DueDate)
            .ThenBy(x => x.TaskId)
            .ToList();

        var filteredRecords = ApplyFilters(allRecords, normalizedFilters)
            .OrderBy(x => x.DueDate)
            .ThenBy(x => x.TaskId)
            .ToList();

        var recordsPageSize = Math.Clamp(normalizedFilters.PageSize <= 0 ? 100 : normalizedFilters.PageSize, 50, 500);
        var filteredRecordCount = filteredRecords.Count;
        var recordsTotalPages = Math.Max(1, (int)Math.Ceiling(filteredRecordCount / (double)recordsPageSize));
        var recordsPage = Math.Clamp(normalizedFilters.Page <= 0 ? 1 : normalizedFilters.Page, 1, recordsTotalPages);
        var pagedRecords = filteredRecords.Skip((recordsPage - 1) * recordsPageSize).Take(recordsPageSize).ToList();

        var insights = BuildDerivedInsights(filteredRecords);
        var insightPageSize = Math.Clamp(normalizedFilters.InsightPageSize <= 0 ? 25 : normalizedFilters.InsightPageSize, 10, 100);
        var insightCount = insights.Count;
        var insightTotalPages = Math.Max(1, (int)Math.Ceiling(insightCount / (double)insightPageSize));
        var insightPage = Math.Clamp(normalizedFilters.InsightPage <= 0 ? 1 : normalizedFilters.InsightPage, 1, insightTotalPages);
        var pagedInsights = insights.Skip((insightPage - 1) * insightPageSize).Take(insightPageSize).ToList();

        var lineItemPageSize = Math.Clamp(normalizedFilters.LineItemPageSize <= 0 ? 100 : normalizedFilters.LineItemPageSize, 25, 250);
        var lineItemCount = await _repository.GetLineItemCountByLabAsync(selectedLabId.Value, normalizedFilters, cancellationToken);
        var lineItemTotalPages = Math.Max(1, (int)Math.Ceiling(lineItemCount / (double)lineItemPageSize));
        var lineItemPage = Math.Clamp(Math.Max(1, normalizedFilters.LineItemPage <= 0 ? 1 : normalizedFilters.LineItemPage), 1, lineItemTotalPages);
        var pagedLineItems = (await _repository.GetLineItemsByLabAsync(selectedLabId.Value, lineItemPage, lineItemPageSize, normalizedFilters, cancellationToken)).ToList();

        var breakdownSource = (await _repository.GetBreakdownSourceByLabAsync(selectedLabId.Value, normalizedFilters, cancellationToken)).ToList();
        var weeklyBreakdowns = BuildTrendBreakdowns(breakdownSource, monthly: false);
        var monthlyBreakdowns = BuildTrendBreakdowns(breakdownSource, monthly: true);
        var weeklyPivot = BuildBreakdownPivot(breakdownSource, monthly: false);
        var monthlyPivot = BuildBreakdownPivot(breakdownSource, monthly: true);

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
            MonthlyPivot = monthlyPivot
        };

        viewModel.Filters.Page = recordsPage;
        viewModel.Filters.PageSize = recordsPageSize;
        viewModel.Filters.InsightPage = insightPage;
        viewModel.Filters.InsightPageSize = insightPageSize;
        viewModel.Filters.LineItemPage = lineItemPage;
        viewModel.Filters.LineItemPageSize = lineItemPageSize;

        return View(viewModel);
    }

    [HttpGet]
    public async Task<IActionResult> GetFilterAutocompleteOptions(int labId, CancellationToken cancellationToken)
    {
        if (labId <= 0)
        {
            return BadRequest("Lab is required.");
        }

        var labs = await _repository.GetLabsAsync(cancellationToken);
        if (labs.All(x => x.LabId != labId))
        {
            return NotFound();
        }

        var payload = await _repository.GetFilterAutocompleteOptionsAsync(labId, cancellationToken);
        return Json(payload);
    }

    [HttpGet]
    public async Task<IActionResult> ExportToExcel([FromQuery] DenialDashboardFilters filters, CancellationToken cancellationToken)
    {
        filters ??= new DenialDashboardFilters();
        if (!filters.LabId.HasValue) return BadRequest("Lab is required.");

        var labs = await _repository.GetLabsAsync(cancellationToken);
        if (!labs.Any(x => x.LabId == filters.LabId.Value))
        {
            return BadRequest("Selected lab is not active.");
        }

        var normalizedFilters = Normalize(filters, filters.LabId.Value);
        if (HasNoAdditionalFilters(normalizedFilters))
        {
            var filePath = await _repository.GetLatestExportFilePathForLabAsync(filters.LabId.Value, cancellationToken);
            if (string.IsNullOrWhiteSpace(filePath) || !System.IO.File.Exists(filePath))
            {
                TempData["DenialDashboardError"] = "No exported workbook was found for the selected lab.";
                return RedirectToAction(nameof(Index), BuildIndexRouteValues(normalizedFilters, filters.LabId));
            }

            var fileName = Path.GetFileName(filePath);
            var extension = Path.GetExtension(filePath).ToLowerInvariant();
            var contentType = extension switch
            {
                ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                ".xls" => "application/vnd.ms-excel",
                ".csv" => "text/csv",
                _ => "application/octet-stream"
            };

            return PhysicalFile(filePath, contentType, fileName);
        }

        var lab = labs.First(x => x.LabId == filters.LabId.Value);
        var filteredRecords = ApplyFilters(await _repository.GetByLabAsync(filters.LabId.Value, cancellationToken), normalizedFilters)
            .OrderBy(x => x.DueDate)
            .ThenBy(x => x.TaskId)
            .ToList();
        var insights = BuildDerivedInsights(filteredRecords);
        var lineItems = (await _repository.GetLineItemsForExportByLabAsync(filters.LabId.Value, normalizedFilters, cancellationToken)).ToList();
        var breakdownSource = (await _repository.GetBreakdownSourceByLabAsync(filters.LabId.Value, normalizedFilters, cancellationToken)).ToList();
        var weeklyPivot = BuildBreakdownPivot(breakdownSource, monthly: false);
        var monthlyPivot = BuildBreakdownPivot(breakdownSource, monthly: true);
        var currentRunId = await _repository.GetCurrentRunIdAsync(filters.LabId.Value, cancellationToken) ?? string.Empty;

        using var workbook = DenialDashboardExcelExportBuilder.CreateWorkbook(lineItems, filteredRecords, weeklyPivot, monthlyPivot);

        await using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        stream.Position = 0;

        var safeLabName = string.Join("_", lab.LabName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
        var fileNameFiltered = $"{safeLabName}_DenialDashboard_Filtered_{(string.IsNullOrWhiteSpace(currentRunId) ? DateTime.Now : currentRunId)}_{DateTime.Now:yyyyMMddHHmmss}.xlsx";
        return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileNameFiltered);
    }

    [HttpGet]
    public async Task<IActionResult> DownloadTaskBoardCsv([FromQuery] DenialDashboardFilters filters, CancellationToken cancellationToken)
    {
        filters ??= new DenialDashboardFilters();
        var labs = (await _repository.GetLabsAsync(cancellationToken)).OrderBy(x => x.LabName).ThenBy(x => x.LabId).ToList();
        if (labs.Count == 0)
        {
            TempData["DenialDashboardError"] = "No labs were found for task-board export.";
            return RedirectToAction(nameof(Index));
        }

        var selectedLabId = filters.LabId;
        if (!selectedLabId.HasValue || labs.All(x => x.LabId != selectedLabId.Value)) selectedLabId = labs.First().LabId;
        var currentLab = labs.First(x => x.LabId == selectedLabId.Value);
        var normalizedFilters = Normalize(filters, selectedLabId.Value);

        var records = ApplyFilters(await _repository.GetByLabAsync(selectedLabId.Value, cancellationToken), normalizedFilters)
            .OrderBy(x => x.DueDate)
            .ThenBy(x => x.TaskId)
            .ToList();

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
    public async Task<IActionResult> UploadTaskBoardCsv(int? labId, IFormFile? taskBoardCsv, [FromForm] DenialDashboardFilters filters, CancellationToken cancellationToken)
    {
        filters ??= new DenialDashboardFilters();
        filters.ActiveTab = "task-board";

        if (!labId.HasValue)
        {
            TempData["DenialDashboardError"] = "Please select a lab before uploading the task-board CSV.";
            return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, filters.LabId));
        }

        if (taskBoardCsv is null || taskBoardCsv.Length == 0)
        {
            TempData["DenialDashboardError"] = "Please choose a CSV file to upload.";
            return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId));
        }

        if (!Path.GetExtension(taskBoardCsv.FileName).Equals(".csv", StringComparison.OrdinalIgnoreCase))
        {
            TempData["DenialDashboardError"] = "Only CSV files are supported for task-board upload.";
            return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId));
        }

        List<TaskBoardCsvUpdate> updates;
        try
        {
            updates = await ReadTaskBoardCsvAsync(taskBoardCsv, cancellationToken);
        }
        catch (Exception ex)
        {
            TempData["DenialDashboardError"] = $"Task-board CSV upload failed: {ex.Message}";
            return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId));
        }

        var result = await _repository.UpdateTaskBoardAsync(labId.Value, updates, cancellationToken);
        var message = $"Task-board upload completed. Updated {result.UpdatedRows} row(s)";
        if (result.SkippedRows > 0) message += $", skipped {result.SkippedRows} row(s)";
        if (result.Errors.Count > 0)
        {
            message += ". " + string.Join(" ", result.Errors.Take(5));
            if (result.Errors.Count > 5) message += $" (+{result.Errors.Count - 5} more)";
        }

        TempData[result.Errors.Count > 0 ? "DenialDashboardError" : "DenialDashboardSuccess"] = message;
        return RedirectToAction(nameof(Index), BuildIndexRouteValues(filters, labId));
    }

    private static RouteValueDictionary BuildIndexRouteValues(DenialDashboardFilters filters, int? labId) => new(new Dictionary<string, object?>
    {
        ["LabId"] = labId ?? filters.LabId,
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

        return new DenialDashboardFilters
        {
            LabId = selectedLabId,
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
            LineItemPageSize = filters.LineItemPageSize <= 0 ? 100 : filters.LineItemPageSize
        };
    }

    private static string NormalizeMultiChoice(string? value, bool allowAll = false)
    {
        if (string.IsNullOrWhiteSpace(value)) return allowAll ? "(All)" : string.Empty;

        var items = ParseSelectedValues(value, allowAll)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (items.Count == 0) return allowAll ? "(All)" : string.Empty;
        return string.Join("|", items);
    }

    private static IEnumerable<DenialRecord> ApplyFilters(IEnumerable<DenialRecord> records, DenialDashboardFilters filters)
    {
        var statusSet = ParseSelectedValues(filters.Status, treatAllAsEmpty: true).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var prioritySet = ParseSelectedValues(filters.Priority, treatAllAsEmpty: true).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var actionSet = ParseSelectedValues(filters.ActionCategory, treatAllAsEmpty: true).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var classSet = ParseSelectedValues(filters.Classification, treatAllAsEmpty: true).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var deadlineSet = ParseSelectedValues(filters.Deadline, treatAllAsEmpty: true).ToHashSet(StringComparer.OrdinalIgnoreCase);
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

        var values = raw.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (treatAllAsEmpty && values.Any(x => x.Equals("(All)", StringComparison.OrdinalIgnoreCase)))
        {
            return Array.Empty<string>();
        }

        return values;
    }

    private static bool EqualsIgnoreCase(string? left, string right)
        => string.Equals(left?.Trim(), right?.Trim(), StringComparison.OrdinalIgnoreCase);

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
            OpenTasks = records.Count(x => EqualsIgnoreCase(x.Status, "Open")),
            InProgressTasks = records.Count(x => EqualsIgnoreCase(x.Status, "In Progress")),
            CompletedTasks = records.Count(x => EqualsIgnoreCase(x.Status, "Completed")),
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
                OpenCount = group.Count(x => EqualsIgnoreCase(x.Status, "Open")),
                CompletedCount = group.Count(x => EqualsIgnoreCase(x.Status, "Completed") || EqualsIgnoreCase(x.Status, "Closed")),
                OverdueCount = group.Count(x => !x.Status.Equals("Completed", StringComparison.OrdinalIgnoreCase) && x.DueDate.Date < DateTime.Today),
                HighPriorityCount = group.Count(x => EqualsIgnoreCase(x.Priority, "High")),
                InsuranceBalanceSum = decimal.Round(group.Sum(x => x.InsuranceBalance), 2),
                AverageSla = group.Any() ? Math.Round(group.Average(x => x.SlaDays), 1) : 0
            })
            .ToList();

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
            OpenCount = records.Count(x => IsInDeadlineBucket(x, bucket) && EqualsIgnoreCase(x.Status, "Open")),
            CompletedCount = records.Count(x => IsInDeadlineBucket(x, bucket) && EqualsIgnoreCase(x.Status, "Completed")),
            OverdueCount = records.Count(x => IsInDeadlineBucket(x, bucket)),
            HighPriorityCount = records.Count(x => IsInDeadlineBucket(x, bucket) && EqualsIgnoreCase(x.Priority, "High")),
            InsuranceBalanceSum = decimal.Round(records.Where(x => IsInDeadlineBucket(x, bucket)).Sum(x => x.InsuranceBalance), 2),
            AverageSla = records.Where(x => IsInDeadlineBucket(x, bucket)).Select(x => (double)x.SlaDays).DefaultIfEmpty(0).Average()
        }).ToList();
    }

    private static List<string> BuildOptions(IEnumerable<string> values) => ["(All)", .. values.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x).ToList()];

    private static List<DenialInsightRecord> BuildDerivedInsights(IEnumerable<DenialRecord> records)
    {
        return records
            .Where(x => !string.IsNullOrWhiteSpace(x.DenialCode))
            .GroupBy(x => new
            {
                DenialCode = string.IsNullOrWhiteSpace(x.DenialCode) ? "(Blank)" : x.DenialCode.Trim(),
                Description = string.IsNullOrWhiteSpace(x.DenialDescription) ? string.Empty : x.DenialDescription.Trim(),
                ActionCategory = string.IsNullOrWhiteSpace(x.EffectiveActionCategory) ? string.Empty : x.EffectiveActionCategory.Trim(),
                ActionCode = string.IsNullOrWhiteSpace(x.ActionCode) ? string.Empty : x.ActionCode.Trim(),
                Action = string.IsNullOrWhiteSpace(x.RecommendedAction) ? string.Empty : x.RecommendedAction.Trim(),
                Task = string.IsNullOrWhiteSpace(x.Task) ? string.Empty : x.Task.Trim()
            })
            .Select(group =>
            {
                var totalBalance = decimal.Round(group.Sum(x => x.EffectiveTotalBalance), 2);
                var topPayer = group
                    .GroupBy(
                        x => !string.IsNullOrWhiteSpace(x.PayerNameNormalized) ? x.PayerNameNormalized.Trim() : (string.IsNullOrWhiteSpace(x.PayerName) ? "(Blank)" : x.PayerName.Trim()),
                        StringComparer.OrdinalIgnoreCase)
                    .Select(g => new { PayerName = g.Key, Balance = decimal.Round(g.Sum(r => r.InsuranceBalance), 2) })
                    .OrderByDescending(x => x.Balance)
                    .ThenBy(x => x.PayerName)
                    .FirstOrDefault();

                var highImpactInsuranceBalance = topPayer?.Balance ?? 0m;

                return new DenialInsightRecord
                {
                    DenialCodes = group.Key.DenialCode,
                    Descriptions = group.Key.Description,
                    NoOfDenialCount = group.Count(),
                    NoOfClaimsCount = group.Select(x => x.ClaimId).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                    TotalBalance = totalBalance,
                    HighImpactInsurance = topPayer?.PayerName ?? string.Empty,
                    InsuranceBalance = highImpactInsuranceBalance,
                    ImpactPercentage = totalBalance == 0 ? 0 : decimal.Round((highImpactInsuranceBalance / totalBalance) * 100m, 2),
                    ActionCategory = group.Key.ActionCategory,
                    ActionCode = group.Key.ActionCode,
                    Action = group.Key.Action,
                    Task = group.Key.Task,
                    Feedback = group.Select(x => x.Feedback).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty,
                    Responsibility = group.Select(x => x.Responsibility).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty,
                    DiscussionDate = group.Select(x => x.DiscussionDate).FirstOrDefault(x => x.HasValue),
                    ETA = group.Select(x => x.ETA).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty,
                    LabId = group.Select(x => x.LabId).FirstOrDefault(),
                    LabName = group.Select(x => x.LabName).FirstOrDefault() ?? string.Empty,
                    RunId = group.Select(x => x.RunId).FirstOrDefault() ?? string.Empty,
                    CreatedOn = group.Max(x => x.CreatedOn)
                };
            })
            .OrderByDescending(x => x.TotalBalance)
            .ThenByDescending(x => x.InsuranceBalance)
            .ThenBy(x => x.DenialCodes)
            .ToList();
    }

    private static bool HasNoAdditionalFilters(DenialDashboardFilters filters)
    {
        return ParseSelectedValues(filters.Status, true).Count == 0
            && ParseSelectedValues(filters.Priority, true).Count == 0
            && ParseSelectedValues(filters.ActionCategory, true).Count == 0
            && ParseSelectedValues(filters.Deadline, true).Count == 0
            && ParseSelectedValues(filters.Classification, true).Count == 0
            && ParseSelectedValues(filters.SalesRepname).Count == 0
            && ParseSelectedValues(filters.ClinicName).Count == 0
            && ParseSelectedValues(filters.ReferringProvider).Count == 0
            && ParseSelectedValues(filters.PayerName).Count == 0
            && ParseSelectedValues(filters.PayerType).Count == 0
            && ParseSelectedValues(filters.PanelName).Count == 0
            && !filters.FirstBilledDateFrom.HasValue
            && !filters.FirstBilledDateTo.HasValue
            && !filters.DateOfServiceFrom.HasValue
            && !filters.DateOfServiceTo.HasValue
            && !filters.DenialDateFrom.HasValue
            && !filters.DenialDateTo.HasValue;
    }

    private static List<TrendBreakdownItem> BuildTrendBreakdowns(IEnumerable<DenialBreakdownSourceRecord> rows, bool monthly)
    {
        var datedRows = rows
            .Where(x => x.DenialDate.HasValue)
            .Select(x => new
            {
                DenialDate = x.DenialDate!.Value.Date,
                x.VisitNumber,
                x.InsuranceBalance,
                x.TotalBalance
            })
            .ToList();

        if (datedRows.Count == 0) return new List<TrendBreakdownItem>();

        if (monthly)
        {
            return datedRows
                .GroupBy(x => new { x.DenialDate.Year, x.DenialDate.Month })
                .OrderByDescending(x => x.Key.Year)
                .ThenByDescending(x => x.Key.Month)
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
                })
                .ToList();
        }

        return datedRows
            .GroupBy(x =>
            {
                var weekStart = StartOfWeek(x.DenialDate);
                return new { IsoYear = ISOWeek.GetYear(weekStart), IsoWeek = ISOWeek.GetWeekOfYear(weekStart), WeekStart = weekStart };
            })
            .OrderByDescending(x => x.Key.IsoYear)
            .ThenByDescending(x => x.Key.IsoWeek)
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
            })
            .ToList();
    }

    private static BreakdownPivotViewModel BuildBreakdownPivot(IEnumerable<DenialBreakdownSourceRecord> rows, bool monthly)
    {
        var prepared = rows
            .Where(x => x.DenialDate.HasValue)
            .Select(x => new PreparedBreakdownRow(
                x.DenialDate!.Value.Date,
                (x.VisitNumber ?? string.Empty).Trim(),
                x.InsuranceBalance,
                NormalizePivotText(x.PayerName, "(Blank Insurance)"),
                BuildDenialLabel(x.DenialCodeNormalized, x.DenialDescription)))
            .ToList();

        var periods = monthly
            ? prepared
                .GroupBy(x => x.DenialDate.Year)
                .OrderBy(g => g.Key)
                .SelectMany(yearGroup =>
                {
                    var monthPeriods = yearGroup
                        .GroupBy(x => x.DenialDate.Month)
                        .OrderBy(g => g.Key)
                        .Select(g => new BreakdownPivotPeriod
                        {
                            Key = $"{yearGroup.Key}-{g.Key:00}",
                            Label = new DateTime(yearGroup.Key, g.Key, 1).ToString("MMM yyyy"),
                            StartDate = new DateTime(yearGroup.Key, g.Key, 1),
                            EndDate = new DateTime(yearGroup.Key, g.Key, 1).AddMonths(1).AddDays(-1),
                            Year = yearGroup.Key,
                            Month = g.Key,
                            IsYearTotal = false
                        })
                        .ToList();

                    monthPeriods.Add(new BreakdownPivotPeriod
                    {
                        Key = $"{yearGroup.Key}-TOTAL",
                        Label = $"{yearGroup.Key} Total",
                        StartDate = new DateTime(yearGroup.Key, 12, 31),
                        EndDate = new DateTime(yearGroup.Key, 12, 31),
                        Year = yearGroup.Key,
                        Month = null,
                        IsYearTotal = true
                    });

                    return monthPeriods;
                })
                .ToList()
            : prepared
                .GroupBy(x => StartOfWeek(x.DenialDate))
                .Select(g => new BreakdownPivotPeriod
                {
                    Key = g.Key.ToString("yyyy-MM-dd"),
                    Label = $"{g.Key:MMM dd} - {g.Key.AddDays(6):MMM dd}",
                    StartDate = g.Key,
                    EndDate = g.Key.AddDays(6),
                    Year = g.Key.Year,
                    Month = g.Key.Month,
                    IsYearTotal = false
                })
                .OrderByDescending(x => x.StartDate)
                .Take(4)
                .OrderBy(x => x.StartDate)
                .ToList();

        var model = new BreakdownPivotViewModel
        {
            HeaderTitle = monthly
                ? "All Months | Denials | Covering 80% of the AR | Denial Posted Date"
                : "Last 4 Weeks | Denials | Covering 80% of the AR | Denial Posted Date",
            SectionTitle = monthly ? "Monthly Breakdown" : "Weekly Breakdown",
            Periods = periods
        };

        if (periods.Count == 0)
        {
            return model;
        }

        var selectedRows = monthly
            ? prepared
            : prepared
                .Where(x => periods.Any(period => PeriodContains(period, x.DenialDate, monthly)))
                .ToList();

        if (selectedRows.Count == 0)
        {
            return model;
        }

        var rankedInsurerGroups = selectedRows
            .GroupBy(x => x.PayerName, StringComparer.OrdinalIgnoreCase)
            .Select(g => new PreparedInsurerGroup(g.Key, g.Sum(x => x.InsuranceBalance), g.ToList()))
            .OrderByDescending(x => x.TotalBalance)
            .ThenBy(x => x.PayerName)
            .ToList();

        var insurerGroups = new List<PreparedInsurerGroup>();
        var grandBalance = rankedInsurerGroups.Sum(x => x.TotalBalance);
        decimal runningBalance = 0m;
        foreach (var group in rankedInsurerGroups)
        {
            insurerGroups.Add(group);
            runningBalance += group.TotalBalance;
            if (insurerGroups.Count >= 10 || (grandBalance > 0 && runningBalance / grandBalance >= 0.80m))
            {
                break;
            }
        }

        var pivotRows = new List<BreakdownPivotRow>();
        var insurerIndex = 0;

        foreach (var insurer in insurerGroups)
        {
            pivotRows.Add(BuildBreakdownPivotRow(
                GetAlphaLabel(insurerIndex),
                insurer.PayerName,
                isInsuranceRow: true,
                insurer.Rows,
                periods,
                monthly));

            var topDenials = insurer.Rows
                .GroupBy(x => x.DenialLabel, StringComparer.OrdinalIgnoreCase)
                .Select(g => new
                {
                    DenialLabel = g.Key,
                    TotalBalance = g.Sum(x => x.InsuranceBalance),
                    Rows = g.ToList()
                })
                .OrderByDescending(x => x.TotalBalance)
                .ThenBy(x => x.DenialLabel)
                .Take(3)
                .ToList();

            for (var i = 0; i < topDenials.Count; i++)
            {
                pivotRows.Add(BuildBreakdownPivotRow(
                    (i + 1).ToString(CultureInfo.InvariantCulture),
                    topDenials[i].DenialLabel,
                    isInsuranceRow: false,
                    topDenials[i].Rows,
                    periods,
                    monthly));
            }

            insurerIndex++;
        }

        model.Rows = pivotRows;
        model.TotalsByPeriod = periods
            .Select(period =>
            {
                var periodRows = selectedRows.Where(x => PeriodContains(period, x.DenialDate, monthly)).ToList();
                return new BreakdownPivotCell
                {
                    ClaimCount = periodRows.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                    DenialBalance = decimal.Round(periodRows.Sum(x => x.InsuranceBalance), 2)
                };
            })
            .ToList();
        model.GrandTotalClaimCount = selectedRows.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        model.GrandTotalBalance = decimal.Round(selectedRows.Sum(x => x.InsuranceBalance), 2);

        return model;
    }

    private static BreakdownPivotRow BuildBreakdownPivotRow(string indexLabel, string label, bool isInsuranceRow, List<PreparedBreakdownRow> rows, List<BreakdownPivotPeriod> periods, bool monthly)
    {
        var cells = periods
            .Select(period =>
            {
                var periodRows = rows.Where(x => PeriodContains(period, x.DenialDate, monthly)).ToList();
                return new BreakdownPivotCell
                {
                    ClaimCount = periodRows.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
                    DenialBalance = decimal.Round(periodRows.Sum(x => x.InsuranceBalance), 2)
                };
            })
            .ToList();

        return new BreakdownPivotRow
        {
            IndexLabel = indexLabel,
            Label = label,
            IsInsuranceRow = isInsuranceRow,
            Cells = cells,
            TotalClaimCount = rows.Select(x => x.VisitNumber).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).Count(),
            TotalBalance = decimal.Round(rows.Sum(x => x.InsuranceBalance), 2)
        };
    }

    private static string GetPeriodKey(DateTime value, bool monthly)
        => monthly ? value.ToString("yyyy-MM") : StartOfWeek(value).ToString("yyyy-MM-dd");

    private static bool PeriodContains(BreakdownPivotPeriod period, DateTime value, bool monthly)
    {
        if (monthly)
        {
            if (period.IsYearTotal)
            {
                return value.Year == period.Year;
            }

            return value.Year == period.Year && value.Month == period.Month;
        }

        return GetPeriodKey(value, monthly).Equals(period.Key, StringComparison.OrdinalIgnoreCase);
    }

    private static string BuildDenialLabel(string? code, string? description)
    {
        var cleanCode = NormalizePivotText(code, string.Empty);
        var cleanDescription = NormalizePivotText(description, string.Empty);

        if (string.IsNullOrWhiteSpace(cleanCode) && string.IsNullOrWhiteSpace(cleanDescription))
        {
            return "(Blank Denial)";
        }

        if (string.IsNullOrWhiteSpace(cleanDescription)) return cleanCode;
        if (string.IsNullOrWhiteSpace(cleanCode)) return cleanDescription;
        return $"{cleanCode} - {cleanDescription}";
    }

    private static string NormalizePivotText(string? value, string fallback)
        => string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();

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
    private sealed record PreparedInsurerGroup(string PayerName, decimal TotalBalance, List<PreparedBreakdownRow> Rows);

    private static DateTime StartOfWeek(DateTime value)
    {
        var diff = (7 + (value.DayOfWeek - DayOfWeek.Monday)) % 7;
        return value.AddDays(-diff).Date;
    }

    private static void BuildInsightSheet(IXLWorksheet sheet, IReadOnlyList<DenialInsightRecord> rows)
    {
        var headers = new[] { "Denial Codes", "Descriptions", "# of Denial", "# of Claims", "Total Balance ($)", "Highest $ Impact - Insurance", "Ins. Balance ($)", "$ Impact (%)", "Action Category", "Action Code", "Action", "Task", "Feedback / Response", "Responsibility", "Discussion Date", "ETA" };
        for (var i = 0; i < headers.Length; i++) sheet.Cell(1, i + 1).Value = headers[i];
        StyleHeader(sheet.Range(1, 1, 1, headers.Length));

        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var r = i + 2;
            sheet.Cell(r, 1).Value = row.DenialCodes;
            sheet.Cell(r, 2).Value = row.Descriptions;
            sheet.Cell(r, 3).Value = row.NoOfDenialCount;
            sheet.Cell(r, 4).Value = row.NoOfClaimsCount;
            sheet.Cell(r, 5).Value = row.TotalBalance;
            sheet.Cell(r, 6).Value = row.HighImpactInsurance;
            sheet.Cell(r, 7).Value = row.InsuranceBalance;
            sheet.Cell(r, 8).Value = row.ImpactPercentage / 100m;
            sheet.Cell(r, 9).Value = row.ActionCategory;
            sheet.Cell(r, 10).Value = row.ActionCode;
            sheet.Cell(r, 11).Value = row.Action;
            sheet.Cell(r, 12).Value = row.Task;
            sheet.Cell(r, 13).Value = row.Feedback;
            sheet.Cell(r, 14).Value = row.Responsibility;
            sheet.Cell(r, 15).Value = row.DiscussionDate;
            sheet.Cell(r, 16).Value = row.ETA;
        }

        sheet.Column(5).Style.NumberFormat.Format = "$#,##0.00";
        sheet.Column(7).Style.NumberFormat.Format = "$#,##0.00";
        sheet.Column(8).Style.NumberFormat.Format = "0.00%";
        sheet.Column(15).Style.DateFormat.Format = "dd-mmm-yyyy";
        FinalizeSheet(sheet, rows.Count + 1, headers.Length);
    }

    private static void BuildTaskBoardSheet(IXLWorksheet sheet, IReadOnlyList<DenialRecord> rows)
    {
        var headers = new[] { "Task ID", "Claim ID", "Patient ID", "CPT", "Denial Code", "Description", "Classification", "Action Code", "Recommended Action", "Action Category", "Task", "Priority", "Insurance Balance", "Total Balance", "Status", "Assigned To", "Payer Name", "Payer Type", "Panel Name", "Referring Provider", "Clinic Name", "Sales Rep", "Date of Service", "First Billed Date", "Date Opened", "Due Date", "Completed Date", "Run ID" };
        for (var i = 0; i < headers.Length; i++) sheet.Cell(1, i + 1).Value = headers[i];
        StyleHeader(sheet.Range(1, 1, 1, headers.Length));

        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var r = i + 2;
            sheet.Cell(r, 1).Value = row.TaskId;
            sheet.Cell(r, 2).Value = row.ClaimId;
            sheet.Cell(r, 3).Value = row.PatientId;
            sheet.Cell(r, 4).Value = row.CptCode;
            sheet.Cell(r, 5).Value = row.DenialCode;
            sheet.Cell(r, 6).Value = row.DenialDescription;
            sheet.Cell(r, 7).Value = row.DenialClassification;
            sheet.Cell(r, 8).Value = row.ActionCode;
            sheet.Cell(r, 9).Value = row.RecommendedAction;
            sheet.Cell(r, 10).Value = row.EffectiveActionCategory;
            sheet.Cell(r, 11).Value = row.Task;
            sheet.Cell(r, 12).Value = row.Priority;
            sheet.Cell(r, 13).Value = row.InsuranceBalance;
            sheet.Cell(r, 14).Value = row.EffectiveTotalBalance;
            sheet.Cell(r, 15).Value = row.Status;
            sheet.Cell(r, 16).Value = row.AssignedTo;
            sheet.Cell(r, 17).Value = row.PayerName;
            sheet.Cell(r, 18).Value = row.PayerType;
            sheet.Cell(r, 19).Value = row.PanelName;
            sheet.Cell(r, 20).Value = row.ReferringProvider;
            sheet.Cell(r, 21).Value = row.ClinicName;
            sheet.Cell(r, 22).Value = row.SalesRepname;
            sheet.Cell(r, 23).Value = row.DateOfService;
            sheet.Cell(r, 24).Value = row.FirstBilledDate;
            sheet.Cell(r, 25).Value = row.DateOpened;
            sheet.Cell(r, 26).Value = row.DueDate;
            sheet.Cell(r, 27).Value = row.DateCompleted;
            sheet.Cell(r, 28).Value = row.RunId;
        }

        sheet.Column(13).Style.NumberFormat.Format = "$#,##0.00";
        sheet.Column(14).Style.NumberFormat.Format = "$#,##0.00";
        for (var c = 23; c <= 27; c++) sheet.Column(c).Style.DateFormat.Format = "dd-mmm-yyyy";
        FinalizeSheet(sheet, rows.Count + 1, headers.Length);
    }

    private static void BuildLineItemSheet(IXLWorksheet sheet, IReadOnlyList<DenialLineItemRecord> rows)
    {
        var headers = new[] { "Accession No", "Visit Number", "CPT", "DOS", "First Billed Date", "Panel Name", "Payer Name", "Payer Type", "Referring Provider", "Clinic Name", "Sales Rep", "Denial Code", "Description", "Billed", "Allowed", "Insurance Payment", "Insurance Adjustment", "Insurance Balance", "Total Balance", "Task Status", "Priority", "Action Category", "Action Code", "Recommended Action", "Task Guidance", "Run ID" };
        for (var i = 0; i < headers.Length; i++) sheet.Cell(1, i + 1).Value = headers[i];
        StyleHeader(sheet.Range(1, 1, 1, headers.Length));

        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var r = i + 2;
            sheet.Cell(r, 1).Value = row.AccessionNo;
            sheet.Cell(r, 2).Value = row.VisitNumber;
            sheet.Cell(r, 3).Value = row.CptCode;
            sheet.Cell(r, 4).Value = row.DateOfService;
            sheet.Cell(r, 5).Value = row.FirstBilledDate;
            sheet.Cell(r, 6).Value = row.PanelName;
            sheet.Cell(r, 7).Value = row.PayerName;
            sheet.Cell(r, 8).Value = row.PayerType;
            sheet.Cell(r, 9).Value = row.ReferringProvider;
            sheet.Cell(r, 10).Value = row.ClinicName;
            sheet.Cell(r, 11).Value = row.SalesRepname;
            sheet.Cell(r, 12).Value = string.IsNullOrWhiteSpace(row.DenialCodeNormalized) ? row.DenialCodeOriginal : row.DenialCodeNormalized;
            sheet.Cell(r, 13).Value = row.DenialDescription;
            sheet.Cell(r, 14).Value = row.BilledAmount;
            sheet.Cell(r, 15).Value = row.AllowedAmount;
            sheet.Cell(r, 16).Value = row.InsurancePayment;
            sheet.Cell(r, 17).Value = row.InsuranceAdjustment;
            sheet.Cell(r, 18).Value = row.InsuranceBalance;
            sheet.Cell(r, 19).Value = row.TotalBalance;
            sheet.Cell(r, 20).Value = row.TaskStatus;
            sheet.Cell(r, 21).Value = row.Priority;
            sheet.Cell(r, 22).Value = row.ActionCategory;
            sheet.Cell(r, 23).Value = row.ActionCode;
            sheet.Cell(r, 24).Value = row.RecommendedAction;
            sheet.Cell(r, 25).Value = row.TaskGuidance;
            sheet.Cell(r, 26).Value = row.RunId;
        }

        for (var c = 14; c <= 19; c++) sheet.Column(c).Style.NumberFormat.Format = "$#,##0.00";
        sheet.Column(4).Style.DateFormat.Format = "dd-mmm-yyyy";
        sheet.Column(5).Style.DateFormat.Format = "dd-mmm-yyyy";
        FinalizeSheet(sheet, rows.Count + 1, headers.Length);
    }

    private static void StyleHeader(IXLRange range)
    {
        range.Style.Font.Bold = true;
        range.Style.Fill.BackgroundColor = XLColor.FromHtml("#DCE8F6");
        range.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
        range.Style.Border.BottomBorderColor = XLColor.FromHtml("#AFC4DF");
    }

    private static void FinalizeSheet(IXLWorksheet sheet, int rowCount, int columnCount)
    {
        if (rowCount >= 2)
        {
            var tableRange = sheet.Range(1, 1, rowCount, columnCount);
            tableRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            tableRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
            tableRange.Style.Border.OutsideBorderColor = XLColor.FromHtml("#C9D7E6");
            tableRange.Style.Border.InsideBorderColor = XLColor.FromHtml("#DDE7F0");
        }
        sheet.Columns().AdjustToContents(8, 42);
        sheet.SheetView.FreezeRows(1);
    }
}

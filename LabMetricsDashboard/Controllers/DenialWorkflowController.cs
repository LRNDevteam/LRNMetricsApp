using ClosedXML.Excel;
using DocumentFormat.OpenXml.EMMA;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Models.DenialWorkflow;
using LabMetricsDashboard.Services;
using LabMetricsDashboard.Services.DenialWorkflow;
using LabMetricsDashboard.Services.Security;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

[Authorize]
public sealed class DenialWorkflowController : Controller
{
    private const int PageSize = 100;
    private const int ExportPageSize = 50000;
    private readonly IDenialWorkflowApiClient _workflowApi;
    private readonly IDenialRecordRepository _denialRepository;
    private readonly IUserManagementRepository _userRepository;
    private readonly WorkflowJwtIssuer _jwtIssuer;

    public DenialWorkflowController(IDenialWorkflowApiClient workflowApi, IDenialRecordRepository denialRepository, IUserManagementRepository userRepository, WorkflowJwtIssuer jwtIssuer)
    {
        _workflowApi = workflowApi;
        _denialRepository = denialRepository;
        _userRepository = userRepository;
        _jwtIssuer = jwtIssuer;
    }

    [AllowAnonymous]
    [HttpGet("/DenialWorkflow/AuthToken")]
    public async Task<IActionResult> AuthToken(CancellationToken cancellationToken = default)
    {
        if (!(User?.Identity?.IsAuthenticated ?? false)) return Unauthorized(new { message = "Login required." });
        return Json(await _jwtIssuer.CreateTokenAsync(User, cancellationToken));
    }

    [HttpGet]
    public async Task<IActionResult> Index(
        string? lab,
        int? labId,
        string tab = "dashboard",
        string? status = null,
        string? reviewer = null,
        string? assignedTo = null,
        string? denialCode = null,
        string? payerName = null,
        int page = 1,
        CancellationToken cancellationToken = default)
    {
        var labs = (await _denialRepository.GetLabsAsync(cancellationToken)).OrderBy(x => x.LabName).ToList();
        var selectedLab = ResolveSelectedLab(labs, labId, lab);
        if (selectedLab == null) return View(new DenialWorkflowPageViewModel());

        ViewData["SelectedLab"] = selectedLab.LabName;
        ViewData["PageLabel"] = "Denial Workflow";

        var role = CurrentWorkflowRole();
        var userName = User.Identity?.Name?.Trim() ?? string.Empty;
        var isManager = HasAnyRole("AR Manager", "ARManager");
        var isReviewer = HasAnyRole("AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer");
        var isAdmin = HasAnyRole("Admin");
        var active = string.IsNullOrWhiteSpace(tab) ? "dashboard" : tab.ToLowerInvariant();

        var filter = BuildFilter(selectedLab.LabId, role, userName, status, reviewer, assignedTo, denialCode, payerName, page, PageSize);

        var vm = new DenialWorkflowPageViewModel
        {
            LabId = selectedLab.LabId,
            LabName = selectedLab.LabName,
            ActiveTab = active,
            Filter = filter,
            LabOptions = labs.Select(x => new DenialWorkflowLabOption { LabId = x.LabId, LabName = x.LabName }).ToList(),
            IsAdmin = isAdmin,
            IsArManager = isManager,
            IsArReviewer = isReviewer,
            Summary = ToCounts(await _workflowApi.GetSummaryAsync(selectedLab.LabId, role, userName, cancellationToken)),
            ReviewerSummary = (await _workflowApi.GetReviewerSummaryAsync(filter, cancellationToken)).ToList()
        };

        if (active == "tasks")
        {
            vm.Tasks = await _workflowApi.GetTasksAsync(filter, cancellationToken);
        }
        else if (active == "verification")
        {
            vm.VerificationTasks = await _workflowApi.GetVerificationAsync(filter, cancellationToken);
        }
        else if (active == "insight" && (isAdmin || isManager))
        {
            vm.Insights = await GetPagedInsightsAsync(selectedLab.LabId, filter, cancellationToken);
        }

        if (isAdmin || isManager)
        {
            vm.ReviewerOptions = await GetReviewerOptionsAsync();
        }

        return View(vm);
    }


	[HttpGet]
    public async Task<IActionResult> ExportExcel(
        string? lab,
        int? labId,
        string tab = "dashboard",
        string? status = null,
        string? reviewer = null,
        string? assignedTo = null,
        string? denialCode = null,
        string? payerName = null,
        CancellationToken cancellationToken = default)
    {
        var labs = (await _denialRepository.GetLabsAsync(cancellationToken)).OrderBy(x => x.LabName).ToList();
        var selectedLab = ResolveSelectedLab(labs, labId, lab);
        if (selectedLab == null) return NotFound("No lab found.");

        var role = CurrentWorkflowRole();
        var userName = User.Identity?.Name?.Trim() ?? string.Empty;
        var filter = BuildFilter(selectedLab.LabId, role, userName, status, reviewer, assignedTo, denialCode, payerName, 1, ExportPageSize);
        var active = string.IsNullOrWhiteSpace(tab) ? "dashboard" : tab.ToLowerInvariant();

        using var workbook = new XLWorkbook();

        if (active == "dashboard")
        {
            var summary = ToCounts(await _workflowApi.GetSummaryAsync(selectedLab.LabId, role, userName, cancellationToken));
            var reviewerRows = (await _workflowApi.GetReviewerSummaryAsync(filter, cancellationToken)).ToList();
            AddDashboardSheet(workbook, summary, reviewerRows);
        }
        else if (active == "insight")
        {
            var insights = await GetPagedInsightsAsync(selectedLab.LabId, filter, cancellationToken);
            AddInsightSheet(workbook, insights.Items);
        }
        else if (active == "verification")
        {
            var verification = await _workflowApi.GetVerificationAsync(filter, cancellationToken);
            AddVerificationSheet(workbook, verification.Items);
        }
        else
        {
            var tasks = await _workflowApi.GetTasksAsync(filter, cancellationToken);
            AddTaskSheet(workbook, tasks.Items);
        }

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        stream.Position = 0;
        var fileName = $"DenialWorkflow_{selectedLab.LabName}_{active}_{DateTime.Now:yyyyMMddHHmmss}.xlsx".Replace(' ', '_');
        return File(stream.ToArray(), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AssignInsight(int labId, string denialCode, string payerName, string reviewerUserName, string? runId, CancellationToken cancellationToken)
    {
        if (!HasAnyRole("Admin", "AR Manager", "ARManager")) return Forbid();
        var updated = await AssignInsightRowAsync(labId, runId, denialCode, payerName, reviewerUserName, cancellationToken);
        TempData[updated > 0 ? "DenialWorkflowSuccess" : "DenialWorkflowError"] = updated > 0 ? $"Assigned {updated:N0} task(s)." : "No matching task was found.";
        return RedirectToAction(nameof(Index), new { labId, tab = "insight" });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> AssignInsightGrid(
        int labId,
        List<InsightAssignmentRow> rows,
        string? gridReviewerUserName,
        int? singleRowIndex,
        string? status,
        string? reviewer,
        string? assignedTo,
        string? denialCode,
        string? payerName,
        int page = 1,
        CancellationToken cancellationToken = default)
    {
        if (!HasAnyRole("Admin", "AR Manager", "ARManager")) return Forbid();

        var totalUpdated = 0;
        if (singleRowIndex.HasValue)
        {
            var row = rows.ElementAtOrDefault(singleRowIndex.Value);
            if (row == null || string.IsNullOrWhiteSpace(row.ReviewerUserName))
            {
                TempData["DenialWorkflowError"] = "Please select a reviewer for the row before assigning.";
            }
            else
            {
                totalUpdated = await AssignInsightRowAsync(labId, row.RunId, row.DenialCode, row.PayerName, row.ReviewerUserName, cancellationToken);
            }
        }
        else
        {
            var selectedRows = rows
                .Where(x => x.IsSelected && (!string.IsNullOrWhiteSpace(x.DenialCode) || !string.IsNullOrWhiteSpace(x.PayerName)))
                .ToList();

            if (string.IsNullOrWhiteSpace(gridReviewerUserName))
            {
                TempData["DenialWorkflowError"] = "Please select a reviewer for the selected rows assignment.";
            }
            else if (selectedRows.Count == 0)
            {
                TempData["DenialWorkflowError"] = "Please select at least one Denial Insight row using the checkbox.";
            }
            else
            {
                foreach (var row in selectedRows)
                {
                    totalUpdated += await AssignInsightRowAsync(labId, row.RunId, row.DenialCode, row.PayerName, gridReviewerUserName, cancellationToken);
                }
            }
        }

        if (totalUpdated > 0)
        {
            TempData["DenialWorkflowSuccess"] = $"Assigned {totalUpdated:N0} task(s).";
        }
        else if (TempData["DenialWorkflowError"] == null)
        {
            TempData["DenialWorkflowError"] = "No matching task was found.";
        }

        return RedirectToAction(nameof(Index), new { labId, tab = "insight", status, reviewer, assignedTo, denialCode, payerName, page });
    }

    private async Task<int> AssignInsightRowAsync(int labId, string? runId, string? denialCode, string? payerName, string reviewerUserName, CancellationToken cancellationToken)
    {
        return await _workflowApi.AssignByInsightAsync(new AssignInsightRequest
        {
            LabId = labId,
            DenialCode = denialCode ?? string.Empty,
            PayerName = payerName ?? string.Empty,
            ReviewerUserName = reviewerUserName,
            RunId = runId,
            ActionBy = User.Identity?.Name ?? "system"
        }, cancellationToken);
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> UpdateTask(int labId, string taskId, string status, string? comments, CancellationToken cancellationToken)
    {
        if (!HasAnyRole("Admin", "AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer")) return Forbid();
        var updated = await _workflowApi.UpdateTaskAsync(new UpdateTaskRequest
        {
            LabId = labId,
            TaskID = taskId,
            Status = status,
            Comments = comments ?? string.Empty,
            ActionBy = User.Identity?.Name ?? "system"
        }, cancellationToken);
        TempData[updated > 0 ? "DenialWorkflowSuccess" : "DenialWorkflowError"] = updated > 0 ? "Task updated." : "Task update failed.";
        return RedirectToAction(nameof(Index), new { labId, tab = "tasks" });
    }

    [HttpPost]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> DecideVerification(int labId, long verificationId, bool isValidDenial, string status, string? comments, CancellationToken cancellationToken)
    {
        if (!HasAnyRole("Admin", "AR Manager", "ARManager", "AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer")) return Forbid();
        var updated = await _workflowApi.DecideVerificationAsync(new VerificationDecisionRequest
        {
            LabId = labId,
            VerificationId = verificationId,
            IsValidDenial = isValidDenial,
            Status = status,
            Comments = comments ?? string.Empty,
            ActionBy = User.Identity?.Name ?? "system"
        }, cancellationToken);
        TempData[updated > 0 ? "DenialWorkflowSuccess" : "DenialWorkflowError"] = updated > 0 ? "Verification saved." : "Verification update failed.";
        return RedirectToAction(nameof(Index), new { labId, tab = "verification" });
    }

    private DenialWorkflowFilter BuildFilter(int labId, string role, string userName, string? status, string? reviewer, string? assignedTo, string? denialCode, string? payerName, int page, int pageSize)
    {
        var selectedReviewer = !string.IsNullOrWhiteSpace(assignedTo) ? assignedTo : reviewer;
        return new DenialWorkflowFilter
        {
            LabId = labId,
            Role = role,
            UserName = userName,
            Status = status,
            Reviewer = selectedReviewer,
            AssignedTo = selectedReviewer,
            DenialCode = denialCode,
            PayerName = payerName,
            Page = page < 1 ? 1 : page,
            PageSize = pageSize
        };
    }

    private LabOption? ResolveSelectedLab(IReadOnlyList<LabOption> labs, int? requestedLabId, string? requestedLabName)
    {
        if (labs.Count == 0) return null;
        if (requestedLabId.HasValue)
        {
            var byId = labs.FirstOrDefault(x => x.LabId == requestedLabId.Value);
            if (byId != null)
            {
                LabSelectionHelper.Resolve(HttpContext, byId.LabName, labs.Select(x => x.LabName).ToList());
                return byId;
            }
        }

        var availableLabNames = labs.Select(x => x.LabName).Where(x => !string.IsNullOrWhiteSpace(x)).ToList();
        var resolvedName = LabSelectionHelper.Resolve(HttpContext, requestedLabName, availableLabNames);
        return labs.FirstOrDefault(x => string.Equals(x.LabName, resolvedName, StringComparison.OrdinalIgnoreCase)) ?? labs.First();
    }

    private async Task<PagedResult<DenialWorkflowInsightRow>> GetPagedInsightsAsync(int labId, DenialWorkflowFilter filter, CancellationToken cancellationToken)
    {
        var insights = await _denialRepository.GetInsightsByLabAsync(labId, cancellationToken);
        var q = insights.AsEnumerable();
        if (!string.IsNullOrWhiteSpace(filter.DenialCode)) q = q.Where(x => string.Equals(x.DenialCodes, filter.DenialCode, StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(filter.PayerName)) q = q.Where(x => (x.HighImpactInsurance ?? string.Empty).Contains(filter.PayerName, StringComparison.OrdinalIgnoreCase));
        var filtered = q.OrderByDescending(x => x.InsuranceBalance).ToList();
        return new PagedResult<DenialWorkflowInsightRow>
        {
            Items = filtered.Skip((filter.Page - 1) * filter.PageSize).Take(filter.PageSize).Select(ToInsightRow).ToList(),
            TotalRecords = filtered.Count,
            Page = filter.Page,
            PageSize = filter.PageSize
        };
    }

    private static DenialWorkflowInsightRow ToInsightRow(DenialInsightRecord x) => new()
    {
        DenialCodes = x.DenialCodes,
        Descriptions = x.Descriptions,
        NoOfDenialCount = x.NoOfDenialCount,
        NoOfClaimsCount = x.NoOfClaimsCount,
        TotalBalance = x.TotalBalance,
        HighImpactInsurance = x.HighImpactInsurance,
        InsuranceBalance = x.InsuranceBalance,
        ImpactPercentage = x.ImpactPercentage,
        ActionCategory = x.ActionCategory,
        ActionCode = x.ActionCode,
        Action = x.Action,
        Task = x.Task,
        Feedback = x.Feedback,
        Responsibility = x.Responsibility,
        DiscussionDate = x.DiscussionDate,
        ETA = x.ETA,
        LabName = x.LabName,
        LabId = x.LabId,
        RunId = x.RunId,
        CreatedOn = x.CreatedOn,
        AssignedTo = x.AssignedTo,
        ResponsibilityReviewer = x.ResponsibilityReviewer
    };

    private async Task<List<DenialWorkflowReviewerOption>> GetReviewerOptionsAsync()
    {
        var reviewers = await _userRepository.GetUsersByRoleNamesAsync(new[] { "AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer" });
        return reviewers.Select(x => new DenialWorkflowReviewerOption { UserName = x.UserName, DisplayName = x.DisplayName }).ToList();
    }

    private static DenialWorkflowCounts ToCounts(DenialWorkflowSummary summary) => new()
    {
        Assigned = summary.Assigned,
        Pending = summary.Pending,
        Completed = summary.Completed,
        VerificationPending = summary.VerificationPending,
        Unassigned = summary.Unassigned
    };

    private static void AddDashboardSheet(XLWorkbook wb, DenialWorkflowCounts summary, List<ReviewerWorkflowSummaryRow> reviewers)
    {
        var ws = wb.Worksheets.Add("Dashboard");
        ws.Cell(1, 1).Value = "Metric"; ws.Cell(1, 2).Value = "Value";
        ws.Cell(2, 1).Value = "Assigned"; ws.Cell(2, 2).Value = summary.Assigned;
        ws.Cell(3, 1).Value = "Closed"; ws.Cell(3, 2).Value = summary.Completed;
        ws.Cell(4, 1).Value = "Pending"; ws.Cell(4, 2).Value = summary.Pending;
        ws.Cell(5, 1).Value = "Verification Pending"; ws.Cell(5, 2).Value = summary.VerificationPending;
        ws.Cell(6, 1).Value = "Unassigned"; ws.Cell(6, 2).Value = summary.Unassigned;
        ws.Cell(8, 1).Value = "AR Reviewer Name"; ws.Cell(8, 2).Value = "Total Assigned"; ws.Cell(8, 3).Value = "Closed"; ws.Cell(8, 4).Value = "Pending";
        var row = 9;
        foreach (var r in reviewers)
        {
            ws.Cell(row, 1).Value = r.ReviewerName;
            ws.Cell(row, 2).Value = r.TotalAssigned;
            ws.Cell(row, 3).Value = r.Closed;
            ws.Cell(row, 4).Value = r.Pending;
            row++;
        }
        FormatSheet(ws);
    }

    private static void AddInsightSheet(XLWorkbook wb, IEnumerable<DenialWorkflowInsightRow> rows)
    {
        var ws = wb.Worksheets.Add("Denial Insight");
        var headers = new[] { "Denial Code", "Description", "Denial Count", "Claims", "Total Balance", "High Impact Insurance", "Insurance Balance", "Impact %", "Action Category", "Action Code", "Action", "Task", "Feedback", "Responsibility", "Assigned To", "Run Id" };
        WriteHeader(ws, headers);
        var r = 2;
        foreach (var x in rows)
        {
            ws.Cell(r, 1).Value = x.DenialCodes; ws.Cell(r, 2).Value = x.Descriptions; ws.Cell(r, 3).Value = x.NoOfDenialCount; ws.Cell(r, 4).Value = x.NoOfClaimsCount; ws.Cell(r, 5).Value = x.TotalBalance; ws.Cell(r, 6).Value = x.HighImpactInsurance; ws.Cell(r, 7).Value = x.InsuranceBalance; ws.Cell(r, 8).Value = x.ImpactPercentage; ws.Cell(r, 9).Value = x.ActionCategory; ws.Cell(r, 10).Value = x.ActionCode; ws.Cell(r, 11).Value = x.Action; ws.Cell(r, 12).Value = x.Task; ws.Cell(r, 13).Value = x.Feedback; ws.Cell(r, 14).Value = x.Responsibility; ws.Cell(r, 15).Value = x.AssignedTo; ws.Cell(r, 16).Value = x.RunId;
            r++;
        }
        FormatSheet(ws);
    }

    private static void AddTaskSheet(XLWorkbook wb, IEnumerable<WorkflowTaskRow> rows)
    {
        var ws = wb.Worksheets.Add("Task Board");
        var headers = new[] { "Task ID", "Claim", "Patient", "CPT", "Denial", "Description", "Action Code", "Recommended Action", "Action Category", "Task", "Priority", "Status", "Assigned To", "Insurance Balance", "Date Opened", "Due", "Days Remaining", "SLA", "Payer", "Payer Type", "Clinic", "Sales Rep", "Referring Provider", "Panel", "DOS", "Comments" };
        WriteHeader(ws, headers);
        var r = 2;
        foreach (var x in rows)
        {
            ws.Cell(r, 1).Value = x.TaskID; ws.Cell(r, 2).Value = x.ClaimID; ws.Cell(r, 3).Value = x.PatientId; ws.Cell(r, 4).Value = x.CPTCode; ws.Cell(r, 5).Value = x.DenialCode; ws.Cell(r, 6).Value = x.DenialDescription; ws.Cell(r, 7).Value = x.ActionCode; ws.Cell(r, 8).Value = x.RecommendedAction; ws.Cell(r, 9).Value = x.ActionCategory; ws.Cell(r, 10).Value = x.Task; ws.Cell(r, 11).Value = x.Priority; ws.Cell(r, 12).Value = x.Status; ws.Cell(r, 13).Value = x.AssignedTo; ws.Cell(r, 14).Value = x.InsuranceBalance; ws.Cell(r, 15).Value = x.DateOpened; ws.Cell(r, 16).Value = x.DueDate; ws.Cell(r, 17).Value = x.DaysRemaining; ws.Cell(r, 18).Value = x.SLAStatus; ws.Cell(r, 19).Value = x.PayerName; ws.Cell(r, 20).Value = x.PayerType; ws.Cell(r, 21).Value = x.ClinicName; ws.Cell(r, 22).Value = x.SalesRepname; ws.Cell(r, 23).Value = x.ReferringProvider; ws.Cell(r, 24).Value = x.PanelName; ws.Cell(r, 25).Value = x.DateOfService; ws.Cell(r, 26).Value = x.ReviewerComments;
            r++;
        }
        FormatSheet(ws);
    }

    private static void AddVerificationSheet(XLWorkbook wb, IEnumerable<VerificationTaskRow> rows)
    {
        var ws = wb.Worksheets.Add("Verification");
        var headers = new[] { "Verification Id", "Task ID", "Claim", "Patient", "CPT", "Denial", "Description", "Action Category", "Status", "Verification Status", "Assigned To", "Payer", "Balance", "Missing Run", "Reason" };
        WriteHeader(ws, headers);
        var r = 2;
        foreach (var x in rows)
        {
            ws.Cell(r, 1).Value = x.VerificationId; ws.Cell(r, 2).Value = x.TaskID; ws.Cell(r, 3).Value = x.ClaimID; ws.Cell(r, 4).Value = x.PatientId; ws.Cell(r, 5).Value = x.CPTCode; ws.Cell(r, 6).Value = x.DenialCode; ws.Cell(r, 7).Value = x.DenialDescription; ws.Cell(r, 8).Value = x.ActionCategory; ws.Cell(r, 9).Value = x.Status; ws.Cell(r, 10).Value = x.VerificationStatus; ws.Cell(r, 11).Value = x.AssignedTo; ws.Cell(r, 12).Value = x.PayerName; ws.Cell(r, 13).Value = x.InsuranceBalance; ws.Cell(r, 14).Value = x.MissingDetectedRunId; ws.Cell(r, 15).Value = x.VerificationComments;
            r++;
        }
        FormatSheet(ws);
    }

    private static void WriteHeader(IXLWorksheet ws, IReadOnlyList<string> headers)
    {
        for (var i = 0; i < headers.Count; i++) ws.Cell(1, i + 1).Value = headers[i];
    }

    private static void FormatSheet(IXLWorksheet ws)
    {
        var used = ws.RangeUsed();
        if (used != null)
        {
            used.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
            used.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
            ws.Row(1).Style.Font.Bold = true;
            ws.Columns().AdjustToContents();
        }
    }

    private string CurrentWorkflowRole()
    {
        if (HasAnyRole("Admin")) return "Admin";
        if (HasAnyRole("AR Manager", "ARManager")) return "AR Manager";
        if (HasAnyRole("AR Reviewer", "ARReviewer", "AR Analyser", "ARAnalyser", "AR Analyzer", "ARAnalyzer")) return "AR Reviewer";
        return "User";
    }

    private bool HasAnyRole(params string[] roles) => roles.Any(role => User.IsInRole(role));
}

public sealed class InsightAssignmentRow
{
    public bool IsSelected { get; set; }
    public string? RunId { get; set; }
    public string? DenialCode { get; set; }
    public string? PayerName { get; set; }
    public string? ReviewerUserName { get; set; }
}

using ClosedXML.Excel;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// The Work Queue export: every claim that matches the current filters (or every claim in the
/// caller's scope), not just the page on screen. Same palette as the other LRN workbooks.
/// </summary>
internal static class ArWorkbenchClaimExcel
{
    public const int MaxRows = 100_000;

    private static readonly (string Header, Func<ArWorkbenchClaimRow, ArWorkbenchClaimExportDetail?, object?> Value, string? Format)[] Columns =
    [
        // Claim columns in the AR team's layout (QC 10.12.2026, sheet "Missing Columns")
        ("Claim ID", (r, x) => r.ClaimID, null),
        ("AccessionNumber", (r, x) => x?.AccessionNumber, null),
        ("Client", (r, x) => r.LabName, null),
        ("Patient Acct", (r, x) => r.PatientID, null),
        ("PatientName", (r, x) => r.PatientName, null),
        ("PatientDOB", (r, x) => x?.PatientDOB, "mm/dd/yyyy"),
        ("SubscriberID", (r, x) => x?.SubscriberId, null),
        ("DOS", (r, x) => r.DateOfService, "mm/dd/yyyy"),
        ("Payer", (r, x) => r.PayerName, null),
        ("Financial Class", (r, x) => r.PayerType, null),
        ("BillingProvider", (r, x) => x?.BillingProvider, null),
        ("Clinic", (r, x) => r.ClinicName, null),
        ("Referring Provider", (r, x) => r.ReferringProvider, null),
        ("Panel Type", (r, x) => r.PanelName, null),
        ("ChargeEnteredDate", (r, x) => x?.ChargeEnteredDate, "mm/dd/yyyy"),
        ("FirstBilledDate", (r, x) => x?.FirstBilledDate, "mm/dd/yyyy"),
        ("CPT", (r, x) => r.FirstCptCode is null ? null : r.LineCount > 1 ? $"{r.FirstCptCode} +{r.LineCount - 1}" : r.FirstCptCode, null),
        ("CPTCodeXUnitsXModifier", (r, x) => x?.CptSummary, null),
        ("Facility", (r, x) => x?.Facility, null),
        ("POS", (r, x) => x?.POS, null),
        ("TOS", (r, x) => x?.TOS, null),
        ("DenialCode", (r, x) => r.DenialCode, null),
        ("Denial Category", (r, x) => r.DenialCategory, null),
        ("Denial Reason", (r, x) => r.DenialReason, null),
        ("ICDCode", (r, x) => x?.ICDCode, null),
        ("Claim Status", (r, x) => r.SourceClaimStatus, null),
        ("Charge", (r, x) => r.ChargeAmount, DenialExcelTheme.AccountingNumberFormat2),
        ("AllowedAmount", (r, x) => x?.AllowedAmount, DenialExcelTheme.AccountingNumberFormat2),
        ("InsurancePayment", (r, x) => x?.InsurancePayment, DenialExcelTheme.AccountingNumberFormat2),
        ("PatientPayment", (r, x) => x?.PatientPayment, DenialExcelTheme.AccountingNumberFormat2),
        ("TotalPayments", (r, x) => x?.TotalPayments, DenialExcelTheme.AccountingNumberFormat2),
        ("InsuranceAdjustments", (r, x) => x?.InsuranceAdjustments, DenialExcelTheme.AccountingNumberFormat2),
        ("PatientAdjustments", (r, x) => x?.PatientAdjustments, DenialExcelTheme.AccountingNumberFormat2),
        ("TotalAdjustments", (r, x) => x?.TotalAdjustments, DenialExcelTheme.AccountingNumberFormat2),
        ("Ins. Balance", (r, x) => r.InsuranceBalance, DenialExcelTheme.AccountingNumberFormat2),
        ("Patient Balance", (r, x) => r.PatientBalance, DenialExcelTheme.AccountingNumberFormat2),
        ("TotalBalance", (r, x) => x?.TotalBalance, DenialExcelTheme.AccountingNumberFormat2),
        ("Revenue Expectation", (r, x) => r.RevenueExpectation, DenialExcelTheme.AccountingNumberFormat2),
        ("Initial Ins. AR", (r, x) => r.InitialInsuranceAR, DenialExcelTheme.AccountingNumberFormat2),
        ("Recovered", (r, x) => r.RecoveredAmount, DenialExcelTheme.AccountingNumberFormat2),
        ("Recovery Status", (r, x) => r.RecoveryStatus, null),
        ("Remaining AR", (r, x) => r.RemainingAR, DenialExcelTheme.AccountingNumberFormat2),
        ("Aging", (r, x) => r.AgingBucket, null),
        ("CheckDate", (r, x) => x?.CheckDate, "mm/dd/yyyy"),
        ("BillStatus", (r, x) => x?.BillStatus, null),
        ("Aging Days", (r, x) => r.AgingDays, "0"),
        ("TFL", (r, x) => r.IsTflRisk ? "At Risk" : "OK", null),
        ("Priority", (r, x) => r.Priority, null),
        ("Assigned Agent", (r, x) => r.AssignedAgentName ?? r.AssignedAgentUser, null),
        ("Workflow Status", (r, x) => r.WorkflowStatus, null),
        ("AR Queue", (r, x) => string.Join(" · ", new[] { r.ArQueueLabel, r.ArSubQueueLabel }.Where(s => !string.IsNullOrWhiteSpace(s))), null),
        ("Fix / Resolution", (r, x) => r.FixResolution, null),
        ("Last Follow-Up", (r, x) => r.LastFollowUpDate, "mm/dd/yyyy"),
        ("Next Follow-Up", (r, x) => r.NextFollowUpDate, "mm/dd/yyyy"),
        ("Days Untouched", (r, x) => r.DaysSinceLastTouch, "0"),

        // Every note entered on the claim, newest first (QC: Notes column)
        ("Notes", (r, x) => x?.Notes, null),

        // Assignment
        ("Assigned By", (r, x) => x?.AssignedBy, null),
        ("Assigned On", (r, x) => x?.AssignedOn, DateTimeFormat),

        // Latest follow-up note, as logged in the Log Follow-Up Note pop-up (agent or manager)
        ("Follow-Up Notes Logged", (r, x) => x?.FollowUpCount ?? 0, "0"),
        ("FU Claim Type", (r, x) => x?.ClaimType, null),
        ("FU Follow Up Type", (r, x) => x?.FollowUpType, null),
        ("FU Claim Status", (r, x) => x?.FollowUpClaimStatus, null),
        ("FU Denial Root Cause", (r, x) => x?.DenialRootCause, null),
        ("FU Fix / Resolution", (r, x) => x?.FixResolution, null),
        ("FU Comment", (r, x) => x?.FollowUpComment, null),
        ("FU Next Follow-Up Date", (r, x) => x?.NextFollowUpDate, "mm/dd/yyyy"),
        ("FU CIP Category", (r, x) => x?.CipCategory, null),
        ("FU CIP Required Info", (r, x) => x?.CipRequiredInfo, null),
        ("FU CIP Comment", (r, x) => x?.CipComment, null),
        ("FU Logged By", (r, x) => x?.FollowUpBy, null),
        ("FU Logged By Role", (r, x) => RoleLabel(x?.FollowUpByRole), null),
        ("FU Logged On", (r, x) => x?.FollowUpOn, DateTimeFormat),

        // QA review of that note (QA reviewer / team lead / RCM manager)
        ("QA Status", (r, x) => x?.QaStatus, null),
        ("QA Reviewed By", (r, x) => x?.QaReviewedBy, null),
        ("QA Reviewer Role", (r, x) => RoleLabel(x?.QaReviewedByRole), null),
        ("QA Reviewed On", (r, x) => x?.QaReviewedOn, DateTimeFormat),
        ("QA Error Type", (r, x) => x?.QaErrorType, null),
        ("QA / Manager Comment", (r, x) => x?.QaComment, null),

        // Latest status change verification (RCM Manager)
        ("Status Verification", (r, x) => x?.VerificationStatus, null),
        ("Source Status Change", (r, x) => x?.VerificationStatus is null ? null : x.VerificationChange, null),
        ("Verification Manager", (r, x) => x?.VerificationManager, null),
        ("Verification Decision", (r, x) => VerificationLabel(x?.VerificationAction), null),
        ("Verified By", (r, x) => x?.VerificationBy, null),
        ("Verified On", (r, x) => x?.VerificationOn, DateTimeFormat),
        ("Verification Comment", (r, x) => x?.VerificationComment, null)
    ];

    private const string DateTimeFormat = "mm/dd/yyyy hh:mm AM/PM";

    private static string? RoleLabel(string? code) => code switch
    {
        null or "" => null,
        "admin" => "System Administrator",
        "manager" => "RCM Manager",
        "lead" => "Team Lead",
        "qa" => "QA Reviewer",
        "agent" => "AR Agent",
        "viewer" => "Viewer",
        _ => code
    };

    private static string? VerificationLabel(string? action) => action switch
    {
        "ReturnToAgent" => "Returned to Agent",
        "Unassign" => "Released to Unassigned",
        "Complete" => "Completed",
        "Reassigned" => "Reassigned",
        _ => action
    };

    public static byte[] Build(IReadOnlyList<ArWorkbenchClaimRow> rows, string title, bool truncated)
        => Build(rows, new Dictionary<long, ArWorkbenchClaimExportDetail>(), title, truncated);

    public static byte[] Build(IReadOnlyList<ArWorkbenchClaimRow> rows, IReadOnlyDictionary<long, ArWorkbenchClaimExportDetail> details, string title, bool truncated)
    {
        using var workbook = new XLWorkbook();
        var sheet = workbook.Worksheets.Add("Claims");
        DenialExcelTheme.ApplyDefaults(sheet);
        sheet.TabColor = DenialExcelTheme.TabGreen;

        sheet.Cell(1, 1).Value = title + (truncated ? $" — first {MaxRows:N0} rows" : "");
        var titleRange = sheet.Range(1, 1, 1, Columns.Length).Merge();
        titleRange.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Font.SetFontSize(DenialExcelTheme.FontSizeTitle);
        titleRange.Style.Fill.SetBackgroundColor(DenialExcelTheme.TitleBg);

        for (var c = 0; c < Columns.Length; c++)
            DenialExcelTheme.StyleHeaderCell(sheet.Cell(2, c + 1).SetValue(Columns[c].Header));

        var row = 3;
        foreach (var r in rows)
        {
            details.TryGetValue(r.ClaimKey, out var x);
            for (var c = 0; c < Columns.Length; c++)
            {
                var cell = sheet.Cell(row, c + 1);
                cell.Value = Columns[c].Value(r, x) switch
                {
                    null => Blank.Value,
                    DateTime d => d,
                    decimal m => m,
                    int i => i,
                    // An Excel cell holds at most 32,767 characters (a long notes history can exceed it).
                    var o => o.ToString() is { Length: > 32_000 } s ? s[..32_000] + " …" : o.ToString()
                };
            }
            row++;
        }

        for (var c = 0; c < Columns.Length; c++)
            if (Columns[c].Format is { } fmt && rows.Count > 0)
                sheet.Range(3, c + 1, row - 1, c + 1).Style.NumberFormat.Format = fmt;

        sheet.SheetView.FreezeRows(2);
        if (rows.Count > 0) sheet.Range(2, 1, row - 1, Columns.Length).SetAutoFilter();
        sheet.Columns().AdjustToContents(2, Math.Min(row, 300));

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}

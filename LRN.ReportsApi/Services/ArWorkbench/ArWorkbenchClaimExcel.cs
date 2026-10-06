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

    private static readonly (string Header, Func<ArWorkbenchClaimRow, object?> Value, string? Format)[] Columns =
    [
        ("Claim ID", r => r.ClaimID, null),
        ("Client", r => r.LabName, null),
        ("Patient Acct", r => r.PatientID, null),
        ("DOS", r => r.DateOfService, "mm/dd/yyyy"),
        ("Payer", r => r.PayerName, null),
        ("Financial Class", r => r.PayerType, null),
        ("Clinic", r => r.ClinicName, null),
        ("Referring Provider", r => r.ReferringProvider, null),
        ("Panel Type", r => r.PanelName, null),
        ("CPT", r => r.FirstCptCode is null ? null : r.LineCount > 1 ? $"{r.FirstCptCode} +{r.LineCount - 1}" : r.FirstCptCode, null),
        ("Denial Code", r => r.DenialCode, null),
        ("Denial Category", r => r.DenialCategory, null),
        ("Denial Reason", r => r.DenialReason, null),
        ("Claim Status", r => r.SourceClaimStatus, null),
        ("Charge", r => r.ChargeAmount, DenialExcelTheme.AccountingNumberFormat2),
        ("Ins. Balance", r => r.InsuranceBalance, DenialExcelTheme.AccountingNumberFormat2),
        ("Patient Balance", r => r.PatientBalance, DenialExcelTheme.AccountingNumberFormat2),
        ("Expected Payment", r => r.RevenueExpectation, DenialExcelTheme.AccountingNumberFormat2),
        ("Initial Ins. AR", r => r.InitialInsuranceAR, DenialExcelTheme.AccountingNumberFormat2),
        ("Recovered", r => r.RecoveredAmount, DenialExcelTheme.AccountingNumberFormat2),
        ("Remaining AR", r => r.RemainingAR, DenialExcelTheme.AccountingNumberFormat2),
        ("Aging", r => r.AgingBucket, null),
        ("Aging Days", r => r.AgingDays, "0"),
        ("TFL", r => r.IsTflRisk ? "At Risk" : "OK", null),
        ("Priority", r => r.Priority, null),
        ("Assigned Agent", r => r.AssignedAgentName ?? r.AssignedAgentUser, null),
        ("Workflow Status", r => r.WorkflowStatus, null),
        ("AR Queue", r => string.Join(" · ", new[] { r.ArQueueLabel, r.ArSubQueueLabel }.Where(x => !string.IsNullOrWhiteSpace(x))), null),
        ("Fix / Resolution", r => r.FixResolution, null),
        ("Last Follow-Up", r => r.LastFollowUpDate, "mm/dd/yyyy"),
        ("Next Follow-Up", r => r.NextFollowUpDate, "mm/dd/yyyy"),
        ("Days Untouched", r => r.DaysSinceLastTouch, "0")
    ];

    public static byte[] Build(IReadOnlyList<ArWorkbenchClaimRow> rows, string title, bool truncated)
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
            for (var c = 0; c < Columns.Length; c++)
            {
                var cell = sheet.Cell(row, c + 1);
                cell.Value = Columns[c].Value(r) switch
                {
                    null => Blank.Value,
                    DateTime d => d,
                    decimal m => m,
                    int i => i,
                    var o => o.ToString()
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

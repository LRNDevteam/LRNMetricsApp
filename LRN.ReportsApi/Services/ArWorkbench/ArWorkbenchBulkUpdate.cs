using System.Globalization;
using ClosedXML.Excel;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// T030 Bulk Update (Excel) - the template, the parser and the per-row processing.
///
/// One workbook does both bulk actions: "Assign To" (bulk assignment, ARWorkbench.Assign) and the
/// Comments Framework follow-up columns (bulk status / follow-up note, ARWorkbench.EditClaim). A row
/// with neither is skipped. Each row runs on its own through the same code as the screens
/// (AssignClaimsAsync, LogFollowUpAsync), so one bad row never blocks the others and every rule -
/// scope, QA hold, Fix / Resolution by status, CIP fields - is the one the modals use.
///
/// Conflict check: the template stamps each claim's latest user-activity id ("Version"). A row
/// whose claim has been worked since (follow-up, assignment, QA, ...) fails instead of overwriting
/// someone else's work; the weekly data sync is not user activity and does not count.
/// </summary>
public static class ArWorkbenchBulkUpdate
{
    public const int MaxRows = 5000;
    public const string SheetName = "Bulk Update";
    private const string ListsSheetName = "Lists";
    private const int HeaderRow = 2;
    private const int FirstDataRow = 3;

    // Info columns (grey) then the editable ones (yellow). Import reads by header text.
    private static readonly string[] InfoHeaders =
        ["Claim ID", "Version", "Patient Acct", "Payer", "DOS", "Denial Code", "Ins. Balance", "Workflow Status", "AR Queue", "Assigned Agent", "Next Follow-Up (current)"];

    private static readonly (string Header, string? List)[] EditHeaders =
    [
        ("Assign To", "@agents"),
        ("Claim Type", "CLAIM_TYPE"),
        ("Follow-Up Type", "FOLLOW_UP_TYPE"),
        ("Claim Status", "CLAIM_STATUS"),
        ("Denial Root Cause", "DENIAL_ROOT_CAUSE"),
        ("Fix / Resolution", "FIX_RESOLUTION"),
        ("Follow-Up Comment", null),
        ("Next Follow-Up Date", "@date"),
        ("CIP Category", "CIP_CATEGORY"),
        ("CIP Required Info", "CIP_REQUIRED_INFO"),
        ("CIP Comment", null)
    ];

    /// <summary>"Display Name (username)" - what the Assign To dropdown shows.</summary>
    public static string AgentLabel(ArWorkbenchAgent a) =>
        string.IsNullOrWhiteSpace(a.DisplayName) || string.Equals(a.DisplayName, a.UserName, StringComparison.OrdinalIgnoreCase)
            ? a.UserName : $"{a.DisplayName} ({a.UserName})";

    // ---- template --------------------------------------------------------------------------

    public static byte[] BuildTemplate(IReadOnlyList<ArWorkbenchClaimRow> claims, IReadOnlyDictionary<long, long> versions,
        IReadOnlyDictionary<string, List<string>> lists, IReadOnlyList<ArWorkbenchAgent> agents, string title)
    {
        using var wb = new XLWorkbook();
        var sheet = wb.Worksheets.Add(SheetName);
        DenialExcelTheme.ApplyDefaults(sheet);
        sheet.TabColor = DenialExcelTheme.TabGreen;
        var totalCols = InfoHeaders.Length + EditHeaders.Length;

        sheet.Cell(1, 1).Value = title;
        var t = sheet.Range(1, 1, 1, totalCols).Merge();
        t.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Font.SetFontSize(DenialExcelTheme.FontSizeTitle);
        t.Style.Fill.SetBackgroundColor(DenialExcelTheme.TitleBg);

        for (var i = 0; i < InfoHeaders.Length; i++)
            DenialExcelTheme.StyleHeaderCell(sheet.Cell(HeaderRow, i + 1).SetValue(InfoHeaders[i]));
        for (var i = 0; i < EditHeaders.Length; i++)
        {
            var cell = sheet.Cell(HeaderRow, InfoHeaders.Length + i + 1).SetValue(EditHeaders[i].Header);
            DenialExcelTheme.StyleHeaderCell(cell);
            cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#B7791F");
        }

        var lastRow = Math.Max(FirstDataRow + claims.Count - 1, FirstDataRow + 499);
        sheet.Range(FirstDataRow, 1, lastRow, 1).Style.NumberFormat.Format = "@";     // claim ids stay text
        var r = FirstDataRow;
        foreach (var c in claims)
        {
            sheet.Cell(r, 1).Value = c.ClaimID;
            sheet.Cell(r, 2).Value = versions.TryGetValue(c.ClaimKey, out var v) ? v : 0;
            sheet.Cell(r, 3).Value = c.PatientID;
            sheet.Cell(r, 4).Value = c.PayerName;
            if (c.DateOfService is { } dos) sheet.Cell(r, 5).Value = dos;
            sheet.Cell(r, 6).Value = c.DenialCode;
            sheet.Cell(r, 7).Value = c.InsuranceBalance;
            sheet.Cell(r, 8).Value = c.WorkflowStatus;
            sheet.Cell(r, 9).Value = string.Join(" · ", new[] { c.ArQueueLabel, c.ArSubQueueLabel }.Where(x => !string.IsNullOrWhiteSpace(x)));
            sheet.Cell(r, 10).Value = c.AssignedAgentName ?? c.AssignedAgentUser;
            if (c.NextFollowUpDate is { } nf) sheet.Cell(r, 11).Value = nf;
            r++;
        }
        sheet.Range(FirstDataRow, 2, lastRow, InfoHeaders.Length).Style.Fill.BackgroundColor = XLColor.FromHtml("#F2F2F2");
        sheet.Column(5).Style.DateFormat.Format = "mm/dd/yyyy";
        sheet.Column(7).Style.NumberFormat.Format = "#,##0.00";
        sheet.Column(11).Style.DateFormat.Format = "mm/dd/yyyy";
        var nextCol = InfoHeaders.Length + Array.FindIndex(EditHeaders, h => h.List == "@date") + 1;
        sheet.Column(nextCol).Style.DateFormat.Format = "mm/dd/yyyy";

        AddDropdowns(wb, sheet, lists, agents, lastRow);

        sheet.SheetView.FreezeRows(HeaderRow);
        sheet.SheetView.FreezeColumns(1);
        sheet.Columns().AdjustToContents(HeaderRow, 60);
        foreach (var h in new[] { "Follow-Up Comment", "CIP Comment" })
            sheet.Column(InfoHeaders.Length + Array.FindIndex(EditHeaders, e => e.Header == h) + 1).Width = 45;
        sheet.Column(2).Hide();     // Version: needed for the conflict check, not for editing

        AddInstructions(wb);
        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return ms.ToArray();
    }

    private static void AddDropdowns(XLWorkbook wb, IXLWorksheet sheet, IReadOnlyDictionary<string, List<string>> lists,
        IReadOnlyList<ArWorkbenchAgent> agents, int lastRow)
    {
        var listSheet = wb.Worksheets.Add(ListsSheetName);
        DenialExcelTheme.ApplyDefaults(listSheet);
        listSheet.TabColor = DenialExcelTheme.TabGold;
        var col = 1;
        for (var i = 0; i < EditHeaders.Length; i++)
        {
            var (header, list) = EditHeaders[i];
            var target = InfoHeaders.Length + i + 1;
            if (list == "@date")
            {
                var dv = sheet.Range(FirstDataRow, target, lastRow, target).CreateDataValidation();
                dv.Date.GreaterThan(new DateTime(2000, 1, 1));
                dv.ErrorTitle = header;
                dv.ErrorMessage = "Enter a date (mm/dd/yyyy).";
                continue;
            }
            if (list is null) continue;
            var values = list == "@agents"
                ? agents.Where(a => a.IsAssignable).Select(AgentLabel).ToList()
                : lists.TryGetValue(list, out var l) ? l : [];
            DenialExcelTheme.StyleHeaderCell(listSheet.Cell(1, col).SetValue(header));
            for (var v = 0; v < values.Count; v++) listSheet.Cell(v + 2, col).Value = values[v];
            if (values.Count > 0)
            {
                var dv = sheet.Range(FirstDataRow, target, lastRow, target).CreateDataValidation();
                dv.List(listSheet.Range(2, col, values.Count + 1, col), true);
                dv.ErrorTitle = header;
                dv.ErrorMessage = $"Choose a {header} from the list.";
            }
            col++;
        }
        listSheet.Columns().AdjustToContents();
    }

    private static void AddInstructions(XLWorkbook wb)
    {
        var s = wb.Worksheets.Add("How To");
        DenialExcelTheme.ApplyDefaults(s);
        string[] lines =
        [
            "AR Workbench - Bulk Update",
            "",
            "1. Fill only the yellow columns. Grey columns are for reference and are not imported (Claim ID identifies the row).",
            "2. Assign To: pick an agent to assign or reassign the claim (System Administrator, RCM Manager, Team Lead).",
            "3. Follow-up note: Claim Type, Follow-Up Type, Claim Status, Fix / Resolution and Follow-Up Comment are required;",
            "   Denial Root Cause when Claim Status is Denied; CIP Category, CIP Required Info and CIP Comment when Fix / Resolution is",
            "   'CIP - Client Escalations'. Next Follow-Up Date is optional. A logged note sends the claim to the QA Verification Queue.",
            "4. A row may do both (assignment first, then the note). A row with neither is skipped. Leave rows you do not change empty.",
            "5. Conflict check: a claim that someone worked after you downloaded this file is not changed - download a fresh template.",
            "6. Each row succeeds or fails on its own; the result log lists every row with the reason.",
            $"7. Up to {MaxRows:N0} rows per file. Do not rename the column headers."
        ];
        for (var i = 0; i < lines.Length; i++) s.Cell(i + 1, 1).Value = lines[i];
        s.Cell(1, 1).Style.Font.SetBold().Font.SetFontSize(14);
        s.Column(1).Width = 130;
    }

    // ---- parse -----------------------------------------------------------------------------

    private static string Key(string? s) => new string((s ?? string.Empty).Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();

    public static (List<ArWorkbenchBulkRow>? Rows, string? Error) Parse(Stream stream)
    {
        XLWorkbook wb;
        try { wb = new XLWorkbook(stream); }
        catch (Exception) { return (null, "The file could not be read as an Excel workbook (.xlsx)."); }
        using (wb)
        {
            var sheet = wb.Worksheets.FirstOrDefault(w => string.Equals(w.Name, SheetName, StringComparison.OrdinalIgnoreCase)) ?? wb.Worksheets.First();
            int headerRow = 0;
            var cols = new Dictionary<string, int>();
            var lastCol = Math.Min(sheet.LastColumnUsed()?.ColumnNumber() ?? 0, 80);
            for (var row = 1; row <= 5 && headerRow == 0; row++)
            {
                for (var c = 1; c <= lastCol; c++)
                {
                    var k = Key(sheet.Cell(row, c).GetFormattedString());
                    if (k.Length > 0 && !cols.ContainsKey(k)) cols[k] = c;
                }
                if (cols.ContainsKey("CLAIMID")) headerRow = row; else cols.Clear();
            }
            if (headerRow == 0) return (null, "No \"Claim ID\" column was found. Start from Download Template.");
            if (!EditHeaders.Any(h => cols.ContainsKey(Key(h.Header))))
                return (null, "None of the update columns (Assign To, Claim Status, Fix / Resolution ...) were found. Start from Download Template.");

            string? Text(int row, string header)
            {
                if (!cols.TryGetValue(Key(header), out var c)) return null;
                var v = sheet.Cell(row, c).GetFormattedString().Trim();
                return v.Length == 0 ? null : v;
            }

            var rows = new List<ArWorkbenchBulkRow>();
            var lastRow = sheet.LastRowUsed()?.RowNumber() ?? 0;
            for (var row = headerRow + 1; row <= lastRow; row++)
            {
                var claimId = Text(row, "Claim ID");
                var r = new ArWorkbenchBulkRow
                {
                    RowNumber = row,
                    ClaimId = claimId,
                    Version = long.TryParse(Text(row, "Version"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var ver) ? ver : null,
                    AssignTo = Text(row, "Assign To"),
                    ClaimType = Text(row, "Claim Type"),
                    FollowUpType = Text(row, "Follow-Up Type"),
                    ClaimStatus = Text(row, "Claim Status"),
                    DenialRootCause = Text(row, "Denial Root Cause"),
                    FixResolution = Text(row, "Fix / Resolution"),
                    Comment = Text(row, "Follow-Up Comment"),
                    CipCategory = Text(row, "CIP Category"),
                    CipRequiredInfo = Text(row, "CIP Required Info"),
                    CipComment = Text(row, "CIP Comment")
                };
                if (cols.TryGetValue(Key("Next Follow-Up Date"), out var dc))
                {
                    var cell = sheet.Cell(row, dc);
                    if (cell.DataType == XLDataType.DateTime) r.NextFollowUpDate = cell.GetDateTime().Date;
                    else if (cell.DataType == XLDataType.Number) r.NextFollowUpDate = DateTime.FromOADate(cell.GetDouble()).Date;
                    else if (cell.GetFormattedString().Trim() is { Length: > 0 } text)
                    {
                        if (DateTime.TryParseExact(text, ["M/d/yyyy", "MM/dd/yyyy", "yyyy-MM-dd", "M/d/yy"], CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
                            r.NextFollowUpDate = d.Date;
                        else r.NextFollowUpDateError = text;
                    }
                }
                if (r.ClaimId is null && r.AssignTo is null && !r.HasFollowUp) continue;     // empty row
                rows.Add(r);
                if (rows.Count > MaxRows) return (null, $"The file has more than {MaxRows:N0} rows. Split it and upload each part.");
            }
            return (rows, null);
        }
    }

    // ---- rules -----------------------------------------------------------------------------

    /// <summary>Assign To text -> agent: "Name (username)", the username, or the display name.</summary>
    public static ArWorkbenchAgent? ResolveAgent(string? text, IReadOnlyList<ArWorkbenchAgent> agents)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var t = text.Trim();
        var open = t.LastIndexOf('(');
        if (open >= 0 && t.EndsWith(')'))
        {
            var user = t[(open + 1)..^1].Trim();
            var byUser = agents.FirstOrDefault(a => string.Equals(a.UserName, user, StringComparison.OrdinalIgnoreCase));
            if (byUser is not null) return byUser;
        }
        return agents.FirstOrDefault(a => string.Equals(a.UserName, t, StringComparison.OrdinalIgnoreCase))
               ?? agents.FirstOrDefault(a => string.Equals(a.DisplayName, t, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// What a row may do, before anything is written: the claim, the conflict check and the
    /// permissions. Null error = go ahead (assign when Agent is set, then log the note when HasFollowUp).
    /// </summary>
    public static (string? Error, string? Skip, ArWorkbenchAgent? Agent) Check(ArWorkbenchBulkRow row, ArWorkbenchBulkClaimState? claim,
        bool canAssign, bool canEditClaim, IReadOnlyList<ArWorkbenchAgent> agents)
    {
        if (string.IsNullOrWhiteSpace(row.ClaimId)) return ("Claim ID is empty.", null, null);
        if (claim is null) return ($"Claim {row.ClaimId} was not found in this lab or is outside your access.", null, null);
        if (row.AssignTo is null && !row.HasFollowUp) return (null, "Nothing to update (Assign To and the follow-up columns are empty).", null);

        if (row.Version is { } fileVersion && claim.Version > fileVersion)
            return ($"Changed after this file was downloaded ({(claim.LastActivityBy ?? "another user")}" +
                    $"{(claim.LastActivityOn is { } on ? $" on {on:MM/dd/yyyy HH:mm} UTC" : "")}). Download a fresh template.", null, null);

        ArWorkbenchAgent? agent = null;
        if (row.AssignTo is not null)
        {
            if (!canAssign) return ("Your role cannot assign claims (Assign To).", null, null);
            agent = ResolveAgent(row.AssignTo, agents);
            if (agent is null) return ($"\"{row.AssignTo}\" is not an AR Agent or Team Lead for this lab.", null, null);
            if (!agent.IsAssignable) return ($"{agent.DisplayName} can no longer be assigned claims.", null, null);
        }
        if (row.HasFollowUp)
        {
            if (!canEditClaim) return ("Your role cannot log follow-up notes.", null, null);
            if (row.NextFollowUpDateError is not null) return ($"Next Follow-Up Date \"{row.NextFollowUpDateError}\" is not a date (use mm/dd/yyyy).", null, null);
        }
        return (null, null, agent);
    }

    public static ArWorkbenchFollowUpRequest ToFollowUp(ArWorkbenchBulkRow r) => new()
    {
        ClaimType = r.ClaimType, FollowUpType = r.FollowUpType, ClaimStatus = r.ClaimStatus, DenialRootCause = r.DenialRootCause,
        FixResolution = r.FixResolution, Comment = r.Comment, NextFollowUpDate = r.NextFollowUpDate,
        CipCategory = r.CipCategory, CipRequiredInfo = r.CipRequiredInfo, CipComment = r.CipComment
    };

    // ---- run -------------------------------------------------------------------------------

    /// <summary>Processes the rows one by one (the upload job's work). Never throws for a bad row.</summary>
    public static async Task<ClaimCsvUploadResult> ProcessAsync(IArWorkbenchRepository repo, int labId, IReadOnlyList<ArWorkbenchBulkRow> rows,
        ArWorkbenchUserContext user, CancellationToken ct)
    {
        var agents = user.Permissions.Assign ? await repo.GetAgentsAsync(labId, ct) : [];
        var ids = rows.Select(r => r.ClaimId).Where(id => !string.IsNullOrWhiteSpace(id)).Select(id => id!).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var claims = await repo.GetBulkClaimStatesAsync(labId, ids, user, ct);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var results = new List<ClaimCsvRowResult>();
        int assigned = 0, notes = 0, failed = 0, skipped = 0;
        foreach (var row in rows)
        {
            ct.ThrowIfCancellationRequested();
            var res = new ClaimCsvRowResult { RowNumber = row.RowNumber, ClaimId = row.ClaimId ?? string.Empty };
            results.Add(res);
            claims.TryGetValue(row.ClaimId ?? string.Empty, out var claim);
            res.OldStatus = claim?.WorkflowStatus ?? string.Empty;

            if (row.ClaimId is not null && !seen.Add(row.ClaimId))
            {
                Fail(res, $"Claim {row.ClaimId} is on more than one row; only the first is used.");
                failed++;
                continue;
            }

            var (error, skip, agent) = Check(row, claim, user.Permissions.Assign, user.Permissions.EditClaim, agents);
            if (skip is not null) { res.Status = "Skipped"; res.Action = "None"; res.Note = skip; skipped++; continue; }
            if (error is not null) { Fail(res, error); failed++; continue; }

            var actions = new List<string>();
            var notesText = new List<string>();
            try
            {
                if (agent is not null)
                {
                    if (string.Equals(claim!.AssignedAgentUser, agent.UserName, StringComparison.OrdinalIgnoreCase))
                        notesText.Add($"Already assigned to {agent.DisplayName}.");
                    else
                    {
                        var a = await repo.AssignClaimsAsync(labId, new ArWorkbenchAssignRequest { ClaimKeys = [claim.ClaimKey], AgentUser = agent.UserName, Note = "Bulk update (Excel)" }, agent, user, ct);
                        if (a.AssignedCount + a.ReassignedCount == 0)
                        {
                            Fail(res, a.SkippedCount > 0 ? "The claim could not be assigned (not found or outside your access)." : (a.Message ?? "The claim was not assigned."));
                            failed++;
                            continue;
                        }
                        actions.Add(a.ReassignedCount > 0 ? "Reassigned" : "Assigned");
                        notesText.Add($"{(a.ReassignedCount > 0 ? "Reassigned" : "Assigned")} to {agent.DisplayName}.");
                        res.ChangedValues.Add(new ClaimCsvChangedValue { Field = "Assigned Agent", OldValue = claim.AssignedAgentUser ?? "", NewValue = agent.UserName });
                        assigned++;
                    }
                }

                if (row.HasFollowUp)
                {
                    var (status, message, fu) = await repo.LogFollowUpAsync(labId, claim!.ClaimKey, ToFollowUp(row), user, ct);
                    if (status != ArWorkbenchSaveStatus.Ok)
                    {
                        // An assignment on the same row stays done; say so.
                        Fail(res, actions.Count > 0 ? $"{string.Join(", ", notesText)} Follow-up not logged: {message}" : message);
                        res.Action = actions.Count > 0 ? string.Join(" + ", actions) : "Follow-Up";
                        failed++;
                        continue;
                    }
                    actions.Add("Follow-Up");
                    notesText.Add($"Follow-up logged ({row.ClaimStatus} · {row.FixResolution}); sent to QA.");
                    res.NewStatus = fu?.WorkflowStatus ?? "Submitted for QA";
                    notes++;
                }

                res.Status = "Success";
                res.Action = actions.Count > 0 ? string.Join(" + ", actions) : "None";
                res.Note = string.Join(" ", notesText);
                if (string.IsNullOrEmpty(res.NewStatus)) res.NewStatus = res.OldStatus;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                Fail(res, $"Could not update this claim: {ex.Message}");
                failed++;
            }
        }

        var success = results.Count(r => r.Status == "Success");
        return new ClaimCsvUploadResult
        {
            Success = failed == 0,
            TotalRows = rows.Count,
            ProcessedRows = rows.Count - skipped,
            SkippedRows = skipped,
            UpdatedTasks = assigned,
            AddedComments = notes,
            SuccessCount = success,
            FailureCount = failed,
            Results = results,
            Message = $"{success:N0} row(s) updated ({assigned:N0} assigned, {notes:N0} follow-up notes), {failed:N0} failed, {skipped:N0} skipped."
        };
    }

    private static void Fail(ClaimCsvRowResult res, string reason)
    {
        res.Status = "Failed";
        if (string.IsNullOrEmpty(res.Action)) res.Action = "None";
        res.FailureReason = reason;
    }
}

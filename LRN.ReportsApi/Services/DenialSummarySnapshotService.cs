using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using Microsoft.Extensions.Options;

namespace LRN.ReportsApi.Services;

public interface IDenialSummarySnapshotService
{
    /// <summary>Null when a weekly/monthly snapshot for the period already exists.</summary>
    Task<DenialSummarySnapshotInfo?> CreateSnapshotAsync(int labId, string periodType, DateTime periodStart, DateTime periodEnd, string createdBy, CancellationToken ct);

    /// <summary>Captures every lab's last completed week and month that is not captured yet. Returns the number taken.</summary>
    Task<int> RunScheduledAsync(DateTime now, CancellationToken ct);

    DateTime Today();
}

/// <summary>
/// Weekly / monthly / on-demand Excel snapshots of the Denial Summary (spec 4g), with retention by
/// archiving (4h, 4i).
///
/// A snapshot is the WHOLE lab, not the viewer's current filters or role scope: it is a record of
/// the lab's position at a point in time, so it runs the page's own summary query with an
/// unrestricted filter. That keeps the workbook's numbers identical to an unfiltered Denial Summary.
/// </summary>
public sealed class DenialSummarySnapshotService : IDenialSummarySnapshotService
{
    private readonly IDenialSummaryRepository _repo;
    private readonly IDenialWorkflowRepository _workflowRepo;
    private readonly DenialSummarySnapshotOptions _options;
    private readonly ILogger<DenialSummarySnapshotService> _logger;

    public DenialSummarySnapshotService(
        IDenialSummaryRepository repo,
        IDenialWorkflowRepository workflowRepo,
        IOptions<DenialSummarySnapshotOptions> options,
        ILogger<DenialSummarySnapshotService> logger)
    {
        _repo = repo;
        _workflowRepo = workflowRepo;
        _options = options.Value;
        _logger = logger;
    }

    public DateTime Today() => LocalNow(DateTime.UtcNow).Date;

    public async Task<DenialSummarySnapshotInfo?> CreateSnapshotAsync(int labId, string periodType, DateTime periodStart, DateTime periodEnd, string createdBy, CancellationToken ct)
    {
        var configured = _repo.GetConfiguredLabs().Where(l => l.LabId == labId).Select(l => l.LabName).FirstOrDefault();
        var labName = string.IsNullOrWhiteSpace(configured) ? $"Lab {labId}" : configured;

        if (periodType != DenialSummarySnapshotPeriodTypes.OnDemand
            && await _repo.PeriodSnapshotExistsAsync(labId, periodType, periodStart, ct))
            return null;

        var summary = await _workflowRepo.GetDashboardSummaryAsync(new DenialWorkflowFilter
        {
            LabId = labId,
            Role = "Admin",
            UserName = "DenialSummarySnapshot",
            Page = 1,
            PageSize = 50
        }, ct);
        var observations = await _repo.GetObservationsAsync(labId, ct);
        var takenOn = LocalNow(DateTime.UtcNow);

        var content = DenialSummaryWorkbook.Build(labName, periodType, periodStart, periodEnd, takenOn, createdBy, summary, observations);
        var info = new DenialSummarySnapshotInfo
        {
            LabId = labId,
            PeriodType = periodType,
            PeriodStart = periodStart.Date,
            PeriodEnd = periodEnd.Date,
            FileName = DenialSummaryWorkbook.FileName(labName, periodType, periodStart, periodEnd, takenOn),
            SizeBytes = content.LongLength,
            TotalClaims = summary.DenialClassifications.Sum(r => r.Count),
            TotalInsuranceBalance = summary.DenialClassifications.Sum(r => r.InsuranceBalance),
            CreatedBy = createdBy,
            CreatedOn = DateTime.UtcNow
        };

        var id = await _repo.InsertSnapshotAsync(labId, info, content, ct);
        if (id is null) return null;
        info.SnapshotId = id.Value;

        await ApplyRetentionAsync(labId, ct);
        return info;
    }

    public async Task<int> RunScheduledAsync(DateTime now, CancellationToken ct)
    {
        var today = LocalNow(now).Date;
        var week = DenialSummarySchedule.LastCompletedWeek(today);
        var month = DenialSummarySchedule.LastCompletedMonth(today);
        var taken = 0;

        foreach (var (labId, labName) in _repo.GetConfiguredLabs())
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                if (await CreateSnapshotAsync(labId, DenialSummarySnapshotPeriodTypes.Weekly, week.Start, week.End, "Scheduler", ct) is not null) taken++;
                if (await CreateSnapshotAsync(labId, DenialSummarySnapshotPeriodTypes.Monthly, month.Start, month.End, "Scheduler", ct) is not null) taken++;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // One lab's unreachable database must not stop the others being captured.
                _logger.LogError(ex, "Denial Summary snapshot failed for lab {LabId} ({LabName}).", labId, labName);
            }
        }

        return taken;
    }

    private async Task ApplyRetentionAsync(int labId, CancellationToken ct)
    {
        var active = await _repo.GetSnapshotsAsync(labId, includeArchived: false, ct);
        var toArchive = DenialSummarySchedule.SelectForArchive(active, _options);
        var archived = await _repo.ArchiveSnapshotsAsync(labId, toArchive, ct);
        if (archived > 0)
            _logger.LogInformation("Archived {Count} Denial Summary snapshot(s) for lab {LabId} past retention.", archived, labId);
    }

    private DateTime LocalNow(DateTime utcNow)
    {
        if (string.IsNullOrWhiteSpace(_options.TimeZoneId))
            return utcNow.ToLocalTime();

        try
        {
            return TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utcNow, DateTimeKind.Utc), TimeZoneInfo.FindSystemTimeZoneById(_options.TimeZoneId.Trim()));
        }
        catch (Exception ex) when (ex is TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            _logger.LogWarning("DenialSummarySnapshots:TimeZoneId '{TimeZoneId}' is not a known time zone; using server local time.", _options.TimeZoneId);
            return utcNow.ToLocalTime();
        }
    }
}

/// <summary>The snapshot workbook: both summary tables with every row's observation beside it.</summary>
internal static class DenialSummaryWorkbook
{
    private static readonly string[] Headers =
    [
        "Claims", "Billed", "Ins. Balance", "% of Total", "Status", "Responsible Person",
        "Observation Date", "Target Date", "Follow-up Date", "Completed Date", "Observation"
    ];

    public static string FileName(string labName, string periodType, DateTime start, DateTime end, DateTime takenOn)
    {
        var safeLab = new string(labName.Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray()).Trim('_');
        return periodType switch
        {
            DenialSummarySnapshotPeriodTypes.Weekly => $"{safeLab}_DenialSummary_Weekly_{start:yyyyMMdd}-{end:yyyyMMdd}.xlsx",
            DenialSummarySnapshotPeriodTypes.Monthly => $"{safeLab}_DenialSummary_Monthly_{start:yyyy-MM}.xlsx",
            _ => $"{safeLab}_DenialSummary_{takenOn:yyyyMMdd_HHmm}.xlsx"
        };
    }

    public static string PeriodLabel(string periodType, DateTime start, DateTime end) => periodType switch
    {
        DenialSummarySnapshotPeriodTypes.Weekly => $"Week {start:MM/dd/yyyy} - {end:MM/dd/yyyy}",
        DenialSummarySnapshotPeriodTypes.Monthly => start.ToString("MMMM yyyy"),
        _ => $"On demand, {start:MM/dd/yyyy}"
    };

    public static byte[] Build(
        string labName,
        string periodType,
        DateTime periodStart,
        DateTime periodEnd,
        DateTime takenOn,
        string createdBy,
        DenialWorkflowDashboardSummary summary,
        IReadOnlyList<DenialSummaryObservation> observations)
    {
        var byKey = observations
            .GroupBy(o => (o.SummaryType, o.SummaryKey.Trim().ToUpperInvariant()))
            .ToDictionary(g => g.Key, g => g.First());

        using var workbook = new XLWorkbook();
        var ws = workbook.Worksheets.Add("Denial Summary");
        DenialExcelTheme.ApplyDefaults(ws);
        ws.TabColor = DenialExcelTheme.TabGreen;

        var lastColumn = Headers.Length + 1;
        var title = ws.Range(1, 1, 1, lastColumn).Merge();
        title.Value = $"{labName} - Denial Summary";
        title.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Font.SetFontSize(DenialExcelTheme.FontSizeTitle);
        title.Style.Fill.SetBackgroundColor(DenialExcelTheme.TitleBg);

        ws.Cell(2, 1).Value = "Period";
        ws.Cell(2, 2).Value = PeriodLabel(periodType, periodStart, periodEnd);
        ws.Cell(3, 1).Value = "Captured";
        ws.Cell(3, 2).Value = $"{takenOn:MM/dd/yyyy HH:mm} by {createdBy}";
        ws.Range(2, 1, 3, 1).Style.Font.SetBold();

        var today = takenOn.Date;
        var row = 5;
        row = WriteSection(ws, row, "Denial Classification Summary", "Classification",
            summary.DenialClassifications.Select(r => (Key(r.Classification), r.Count, r.BilledAmount, r.InsuranceBalance, r.PercentageOfTotal)).ToList(),
            DenialSummaryTypes.Classification, byKey, today);
        row += 2;
        WriteSection(ws, row, "Action / Task Summary", "Action / Task",
            summary.ActionCategories.Select(r => (Key(r.ActionCategory), r.Count, r.BilledAmount, r.InsuranceBalance, r.PercentageOfTotal)).ToList(),
            DenialSummaryTypes.ActionCategory, byKey, today);

        ws.Column(1).Width = 34;
        for (var c = 2; c <= 11; c++) ws.Column(c).Width = 15;
        ws.Column(7).Width = 22;
        ws.Column(lastColumn).Width = 70;
        ws.SheetView.FreezeRows(3);

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }

    private static string Key(string? value) => string.IsNullOrWhiteSpace(value) ? "Unclassified" : value.Trim();

    private static int WriteSection(
        IXLWorksheet ws,
        int row,
        string sectionTitle,
        string firstHeader,
        IReadOnlyList<(string Name, int Count, decimal Billed, decimal InsBalance, decimal Percent)> rows,
        string summaryType,
        IReadOnlyDictionary<(string, string), DenialSummaryObservation> observations,
        DateTime today)
    {
        var lastColumn = Headers.Length + 1;
        var header = ws.Range(row, 1, row, lastColumn).Merge();
        header.Value = sectionTitle;
        header.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
        header.Style.Fill.SetBackgroundColor(DenialExcelTheme.SubHeaderBg);
        row++;

        DenialExcelTheme.StyleHeaderCell(ws.Cell(row, 1).SetValue(firstHeader));
        for (var i = 0; i < Headers.Length; i++)
            DenialExcelTheme.StyleHeaderCell(ws.Cell(row, i + 2).SetValue(Headers[i]));
        row++;

        var firstDataRow = row;
        foreach (var r in rows)
        {
            observations.TryGetValue((summaryType, r.Name.ToUpperInvariant()), out var obs);

            ws.Cell(row, 1).Value = r.Name;
            ws.Cell(row, 2).Value = r.Count;
            ws.Cell(row, 3).Value = r.Billed;
            ws.Cell(row, 4).Value = r.InsBalance;
            ws.Cell(row, 5).Value = r.Percent / 100m;
            ws.Cell(row, 6).Value = DenialSummarySchedule.ObservationStatus(obs, today);
            ws.Cell(row, 7).Value = obs?.ResponsiblePerson ?? string.Empty;
            SetDate(ws.Cell(row, 8), obs?.ObservationDate);
            SetDate(ws.Cell(row, 9), obs?.TargetDate);
            SetDate(ws.Cell(row, 10), obs?.FollowUpDate);
            SetDate(ws.Cell(row, 11), obs?.CompletedDate);
            ws.Cell(row, 12).Value = DenialSummaryHtml.ToPlainText(obs?.ObservationHtml);
            ws.Cell(row, 12).Style.Alignment.WrapText = true;

            if ((row - firstDataRow) % 2 == 1)
                ws.Range(row, 1, row, lastColumn).Style.Fill.BackgroundColor = DenialExcelTheme.BandedRowBg;
            row++;
        }

        if (rows.Count == 0)
        {
            ws.Cell(row, 1).Value = "No rows.";
            row++;
        }
        else
        {
            ws.Cell(row, 1).Value = "Total";
            ws.Cell(row, 2).Value = rows.Sum(r => r.Count);
            ws.Cell(row, 3).Value = rows.Sum(r => r.Billed);
            ws.Cell(row, 4).Value = rows.Sum(r => r.InsBalance);
            var total = ws.Range(row, 1, row, lastColumn);
            total.Style.Font.SetBold();
            total.Style.Fill.BackgroundColor = DenialExcelTheme.TotalRowBg;
            row++;
        }

        var body = ws.Range(firstDataRow, 1, row - 1, lastColumn);
        body.Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
        ws.Range(firstDataRow, 2, row - 1, 2).Style.NumberFormat.Format = "#,##0";
        ws.Range(firstDataRow, 3, row - 1, 4).Style.NumberFormat.Format = DenialExcelTheme.AccountingNumberFormat2;
        ws.Range(firstDataRow, 5, row - 1, 5).Style.NumberFormat.Format = "0.00%";
        return row;
    }

    private static void SetDate(IXLCell cell, DateTime? value)
    {
        if (!value.HasValue) return;
        cell.Value = value.Value.Date;
        cell.Style.NumberFormat.Format = "mm/dd/yyyy";
    }
}

/// <summary>Hourly pass that captures each lab's completed week and month once (spec 4g).</summary>
public sealed class DenialSummarySnapshotScheduler : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly DenialSummarySnapshotOptions _options;
    private readonly ILogger<DenialSummarySnapshotScheduler> _logger;

    public DenialSummarySnapshotScheduler(IServiceScopeFactory scopeFactory, IOptions<DenialSummarySnapshotOptions> options, ILogger<DenialSummarySnapshotScheduler> logger)
    {
        _scopeFactory = scopeFactory;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_options.ScheduleEnabled)
        {
            _logger.LogInformation("Denial Summary snapshot schedule is disabled (DenialSummarySnapshots:ScheduleEnabled).");
            return;
        }

        // Let the API finish starting before the first pass touches every lab database.
        try { await Task.Delay(TimeSpan.FromMinutes(2), stoppingToken); }
        catch (OperationCanceledException) { return; }

        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(Math.Max(5, _options.CheckIntervalMinutes)));
        try
        {
            do
            {
                try
                {
                    using var scope = _scopeFactory.CreateScope();
                    var taken = await scope.ServiceProvider.GetRequiredService<IDenialSummarySnapshotService>()
                        .RunScheduledAsync(DateTime.UtcNow, stoppingToken);
                    if (taken > 0)
                        _logger.LogInformation("Denial Summary scheduler captured {Count} snapshot(s).", taken);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _logger.LogError(ex, "Denial Summary snapshot pass failed.");
                }
            }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException)
        {
            // shutdown
        }
    }
}

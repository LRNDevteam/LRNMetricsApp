using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services.RevenuePipeline;
using Microsoft.Data.SqlClient;
using System.Diagnostics;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Beech Tree Revenue Pipeline LIS screen — live LIMSMaster, mockup calculators.
/// Does not call or replace usp_GetBeechTree_ThreePillarLisDiagnostic.
/// </summary>
public sealed class BeechTreeRevenuePipelineLisService
{
    private readonly ILogger<BeechTreeRevenuePipelineLisService> _logger;

    public BeechTreeRevenuePipelineLisService(ILogger<BeechTreeRevenuePipelineLisService> logger)
        => _logger = logger;

    public async Task<RevenuePipelineLisViewModel> GetAsync(
        string connectionString,
        string labName,
        DateTime asOfDate,
        CancellationToken ct = default)
    {
        var asOf = asOfDate.Date;
        var vm = new RevenuePipelineLisViewModel { LabName = labName, AsOfDate = asOf };
        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            var cols = await LoadColumnsAsync(conn, ct);
            if (cols.Count == 0)
            {
                vm.ErrorMessage = "dbo.LIMSMaster was not found in this lab database.";
                return vm;
            }

            static string Q(string n) => "[" + n.Replace("]", "]]") + "]";
            string? First(params string[] names) => names.FirstOrDefault(n => cols.Contains(n));

            var sampleCol = First("Accession", "SampleID", "SampleId", "Sample ID", "UniqueSampleID");
            var collectCol = First("RequestCollectDate", "ReqCollectDate", "CollectionDate",
                "DateOfCollection", "CollectedDate", "Collected");
            if (sampleCol is null || collectCol is null)
            {
                vm.ErrorMessage =
                    "LIMSMaster is missing Accession/Sample ID or Collected date — cannot build VOL-01 / VOL-02.";
                return vm;
            }

            var panelCol = First("PanelCategory", "PanelType", "PanelName", "Panelname",
                "Panel", "TestPanel", "TestPanelName", "Tests");
            var clinicCol = First("ClinicName", "Clinic", "Facility", "FacilityName",
                "ReqLocationName", "REQ_LOCATION_NAME", "Location", "LocationName", "ClientName");
            var reportedCol = First("ReqReportedDate", "ResultDate", "ReportedDate",
                "ReqResultedDate", "SampleResultedDate", "Reported", "ReportDate");

            var firstMonthStart = new DateTime(asOf.Year, asOf.Month, 1).AddMonths(-12);
            var rollingStart = asOf.AddDays(-55);
            var dailyStart = rollingStart < firstMonthStart ? rollingStart : firstMonthStart;

            var daily = await LoadDailyCountsAsync(conn, Q(sampleCol), Q(collectCol), dailyStart, asOf, ct);
            vm.Vol01 = Vol01Rolling28DayCalculator.Calculate(asOf, daily);
            vm.Vol02 = Vol02MatchedMtdCalculator.Calculate(asOf, daily);
            vm.Vol02b = Vol02bCalculator.Calculate(asOf, daily);

            var distClinic = await LoadDimensionWindowsAsync(
                conn, Q(sampleCol), Q(collectCol), clinicCol is null ? null : Q(clinicCol),
                asOf, ct);
            var distPanel = await LoadDimensionWindowsAsync(
                conn, Q(sampleCol), Q(collectCol), panelCol is null ? null : Q(panelCol),
                asOf, ct);
            vm.Vol01Clinic = Vol01DistributionCalculator.Calculate(asOf, "clinic", distClinic);
            vm.Vol01Panel = Vol01DistributionCalculator.Calculate(asOf, "panel", distPanel);

            var monthlyCats = await LoadMonthlyCategoriesAsync(
                conn, Q(sampleCol), Q(collectCol),
                clinicCol is null ? null : Q(clinicCol),
                panelCol is null ? null : Q(panelCol),
                firstMonthStart, asOf, ct);
            vm.Vol02a = Vol02aCalculator.Calculate(asOf, monthlyCats);

            if (reportedCol is null)
            {
                vm.WarningMessage =
                    "Reported date column was not found on LIMSMaster, so Resulting Timeliness (RES-01) is omitted.";
            }
            else
            {
                var resStart = asOf.AddDays(-10);
                var daysSinceSunday = ((int)resStart.DayOfWeek + 7) % 7;
                var currentEnd = resStart.AddDays(-daysSinceSunday);
                var previousStart = currentEnd.AddDays(-55);
                var samples = await LoadRes01SamplesAsync(
                    conn, Q(sampleCol), Q(collectCol), Q(reportedCol), previousStart, asOf, ct);
                var openOlder = await CountOpenOlderThan10Async(
                    conn, Q(sampleCol), Q(collectCol), Q(reportedCol), asOf, ct);
                vm.Res01 = Res01ResultingTimelinessCalculator.Calculate(asOf, samples, openOlder);
                var agingSource = await LoadUnresolvedAgingAsync(
                    conn, Q(sampleCol), Q(collectCol), Q(reportedCol), asOf, ct);
                vm.Res01Aging = Res01ResultingTimelinessCalculator.Aging(asOf, agingSource);
            }

            _logger.LogInformation(
                "RevenuePipeline LIS loaded lab='{Lab}' asOf={AsOf:yyyy-MM-dd} daily={Daily} clinics={C} panels={P} in {Ms}ms",
                labName, asOf, daily.Count, vm.Vol01Clinic?.Rows.Count ?? 0, vm.Vol01Panel?.Rows.Count ?? 0, sw.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "RevenuePipeline LIS failed for lab='{Lab}'", labName);
            vm.ErrorMessage = $"Failed to load Revenue Pipeline LIS: {ex.Message}";
        }

        return vm;
    }

    private static async Task<HashSet<string>> LoadColumnsAsync(SqlConnection conn, CancellationToken ct)
    {
        var cols = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using var cmd = new SqlCommand(
            "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')", conn);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            cols.Add(r.GetString(0));
        return cols;
    }

    private static string NameExpr(string? quotedCol) => quotedCol is null
        ? "N'Unknown / Unassigned'"
        : $"ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), {quotedCol}), N''))), N''), N'Unknown / Unassigned')";

    private static async Task<List<DailySampleCount>> LoadDailyCountsAsync(
        SqlConnection conn, string sampleCol, string collectCol, DateTime start, DateTime asOf, CancellationToken ct)
    {
        var sql = $"""
            SELECT CAST({collectCol} AS date) AS CollectDate,
                   COUNT(DISTINCT LTRIM(RTRIM(CONVERT(NVARCHAR(100), {sampleCol})))) AS SampleCount
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {collectCol} IS NOT NULL
              AND CAST({collectCol} AS date) >= @StartDate
              AND CAST({collectCol} AS date) <= @AsOf
            GROUP BY CAST({collectCol} AS date)
            """;
        var rows = new List<DailySampleCount>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@StartDate", start);
        cmd.Parameters.AddWithValue("@AsOf", asOf);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DailySampleCount(r.GetDateTime(0), Convert.ToInt32(r.GetValue(1))));
        return rows;
    }

    private static async Task<List<DimensionWindowCount>> LoadDimensionWindowsAsync(
        SqlConnection conn, string sampleCol, string collectCol, string? nameCol,
        DateTime asOf, CancellationToken ct)
    {
        var currentStart = asOf.AddDays(-27);
        var previousStart = asOf.AddDays(-55);
        var sql = $"""
            SELECT
                {NameExpr(nameCol)} AS Name,
                CASE WHEN CAST({collectCol} AS date) >= @CurrentStart THEN 1 ELSE 0 END AS IsCurrent,
                COUNT(DISTINCT LTRIM(RTRIM(CONVERT(NVARCHAR(100), {sampleCol})))) AS SampleCount
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {collectCol} IS NOT NULL
              AND CAST({collectCol} AS date) >= @PreviousStart
              AND CAST({collectCol} AS date) <= @AsOf
            GROUP BY {NameExpr(nameCol)},
                     CASE WHEN CAST({collectCol} AS date) >= @CurrentStart THEN 1 ELSE 0 END
            """;
        var rows = new List<DimensionWindowCount>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@PreviousStart", previousStart);
        cmd.Parameters.AddWithValue("@CurrentStart", currentStart);
        cmd.Parameters.AddWithValue("@AsOf", asOf);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new DimensionWindowCount(
                Convert.ToString(r["Name"]) ?? "Unknown / Unassigned",
                Convert.ToInt32(r["IsCurrent"]) == 1,
                Convert.ToInt32(r["SampleCount"])));
        return rows;
    }

    private static async Task<List<MonthlyCategoryCount>> LoadMonthlyCategoriesAsync(
        SqlConnection conn, string sampleCol, string collectCol,
        string? clinicCol, string? panelCol,
        DateTime firstMonthStart, DateTime asOf, CancellationToken ct)
    {
        var cutoff = asOf.Day;
        var sql = $"""
            SELECT
                CONVERT(char(7), DATEFROMPARTS(YEAR({collectCol}), MONTH({collectCol}), 1), 126) AS MonthKey,
                x.Kind,
                x.Name,
                COUNT(DISTINCT LTRIM(RTRIM(CONVERT(NVARCHAR(100), {sampleCol})))) AS SampleCount
            FROM dbo.LIMSMaster WITH (NOLOCK)
            CROSS APPLY (VALUES
                (N'clinic', {NameExpr(clinicCol)}),
                (N'panel',  {NameExpr(panelCol)})
            ) x (Kind, Name)
            WHERE {collectCol} IS NOT NULL
              AND CAST({collectCol} AS date) >= @StartDate
              AND CAST({collectCol} AS date) <= @AsOf
              AND DAY({collectCol}) BETWEEN 1 AND @CutoffDay
            GROUP BY YEAR({collectCol}), MONTH({collectCol}), x.Kind, x.Name
            """;
        var rows = new List<MonthlyCategoryCount>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 180 };
        cmd.Parameters.AddWithValue("@StartDate", firstMonthStart);
        cmd.Parameters.AddWithValue("@AsOf", asOf);
        cmd.Parameters.AddWithValue("@CutoffDay", cutoff);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new MonthlyCategoryCount(
                Convert.ToString(r["MonthKey"]) ?? "",
                Convert.ToString(r["Kind"]) ?? "",
                Convert.ToString(r["Name"]) ?? "Unknown / Unassigned",
                Convert.ToInt32(r["SampleCount"])));
        return rows;
    }

    private static async Task<List<Res01SampleRecord>> LoadRes01SamplesAsync(
        SqlConnection conn, string sampleCol, string collectCol, string reportedCol,
        DateTime start, DateTime asOf, CancellationToken ct)
    {
        var sql = $"""
            SELECT
                MIN(CAST({collectCol} AS date)) AS Collected,
                MIN(CAST({reportedCol} AS date)) AS Reported
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {collectCol} IS NOT NULL
              AND CAST({collectCol} AS date) >= @StartDate
              AND CAST({collectCol} AS date) <= @AsOf
            GROUP BY LTRIM(RTRIM(CONVERT(NVARCHAR(100), {sampleCol})))
            """;
        var rows = new List<Res01SampleRecord>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 180 };
        cmd.Parameters.AddWithValue("@StartDate", start);
        cmd.Parameters.AddWithValue("@AsOf", asOf);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            var collected = r.GetDateTime(0);
            DateTime? reported = r.IsDBNull(1) ? null : r.GetDateTime(1);
            rows.Add(new Res01SampleRecord(collected, reported));
        }
        return rows;
    }

    private static async Task<int> CountOpenOlderThan10Async(
        SqlConnection conn, string sampleCol, string collectCol, string reportedCol,
        DateTime asOf, CancellationToken ct)
    {
        var sql = $"""
            SELECT COUNT(*) FROM (
                SELECT LTRIM(RTRIM(CONVERT(NVARCHAR(100), {sampleCol}))) AS SampleKey
                FROM dbo.LIMSMaster WITH (NOLOCK)
                WHERE {collectCol} IS NOT NULL
                  AND CAST({collectCol} AS date) < DATEADD(DAY, -10, @AsOf)
                GROUP BY LTRIM(RTRIM(CONVERT(NVARCHAR(100), {sampleCol})))
                HAVING MIN(CAST({reportedCol} AS date)) IS NULL
                    OR MIN(CAST({reportedCol} AS date)) > @AsOf
            ) x
            """;
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@AsOf", asOf);
        var result = await cmd.ExecuteScalarAsync(ct);
        return result is null or DBNull ? 0 : Convert.ToInt32(result);
    }

    private static async Task<List<Res01SampleRecord>> LoadUnresolvedAgingAsync(
        SqlConnection conn, string sampleCol, string collectCol, string reportedCol,
        DateTime asOf, CancellationToken ct)
    {
        var sql = $"""
            SELECT MIN(CAST({collectCol} AS date)) AS Collected
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {collectCol} IS NOT NULL
              AND CAST({collectCol} AS date) <= @AsOf
            GROUP BY LTRIM(RTRIM(CONVERT(NVARCHAR(100), {sampleCol})))
            HAVING MIN(CAST({reportedCol} AS date)) IS NULL
                OR MIN(CAST({reportedCol} AS date)) > @AsOf
            """;
        var rows = new List<Res01SampleRecord>();
        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 180 };
        cmd.Parameters.AddWithValue("@AsOf", asOf);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
            rows.Add(new Res01SampleRecord(r.GetDateTime(0), null));
        return rows;
    }
}

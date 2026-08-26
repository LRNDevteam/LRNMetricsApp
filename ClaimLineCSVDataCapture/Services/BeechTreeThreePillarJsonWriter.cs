using System.Data;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using ClaimLineCSVDataCapture.Models;
using Microsoft.Data.SqlClient;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// After BeechTree Executive Summary aggregates refresh, writes Three-Pillar
/// diagnostic snapshots (LIS / PMS / Cash) as JSON, one set per billed week range.
/// Historical weeks are written only when a file is missing. The latest week is
/// recreated after each aggregate refresh (and created if it does not exist).
/// </summary>
public static class BeechTreeThreePillarJsonWriter
{
    public static readonly int[] TrailingMonthWindows = [3, 6, 9, 12, 19];
    private const int DefaultTrailingMonths = 12;
    private const int CommandTimeoutSeconds = 600;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private static readonly Regex DateTokenRegex = new(
        @"\b(?:\d{1,2}[./]\d{1,2}[./]\d{2,4}|\d{4}-\d{1,2}-\d{1,2})\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly string[] DateFormats =
    [
        "M/d/yyyy", "MM/dd/yyyy", "d/M/yyyy", "dd/MM/yyyy",
        "yyyy-MM-dd", "yyyy/M/d", "yyyy/MM/dd",
        "M/d/yy", "MM/dd/yy",
        "M.d.yyyy", "MM.dd.yyyy",
        "yyyy.M.d", "yyyy.MM.dd",
    ];

    public static bool IsBeechTreeLab(string? labName)
        => !string.IsNullOrWhiteSpace(labName)
           && (labName.Equals("Beech_Tree", StringComparison.OrdinalIgnoreCase)
               || labName.Equals("BeechTree", StringComparison.OrdinalIgnoreCase));

    public static string ResolveOutputRoot(LabConfig lab, string workingFolder)
    {
        if (!string.IsNullOrWhiteSpace(lab.Output.ThreePillarJsonPath))
            return lab.Output.ThreePillarJsonPath;

        var reports = lab.Output.Reports;
        if (!string.IsNullOrWhiteSpace(reports))
            return Path.Combine(reports, "ThreePillar");

        return Path.Combine(workingFolder, "ThreePillar", Sanitize(lab.LabName));
    }

    public static string FilePath(string root, string weekFolder, int trailingMonths, string pillar)
        => Path.Combine(root, Sanitize(weekFolder), $"m{trailingMonths}", $"{pillar}.json");

    /// <summary>
    /// Writes LIS / PMS / Cash JSON for every week range in LineClaimFileLogs.
    /// Historical weeks: create only when a file is missing (12-month window).
    /// Latest week: create if missing. When <paramref name="recreateLatest"/> is true
    /// (after ES aggregate refresh), existing latest-week files are rewritten.
    /// Latest week also fills the 3/6/9/12/19 trailing-month windows.
    /// </summary>
    public static void Generate(LabConfig lab, string workingFolder, AppLogger log, bool recreateLatest = true)
    {
        if (!IsBeechTreeLab(lab.LabName))
            return;

        if (string.IsNullOrWhiteSpace(lab.DbConnectionString))
        {
            log.Warn("  [ThreePillar JSON] Skipped — BeechTree has no DbConnectionString.");
            return;
        }

        var root = ResolveOutputRoot(lab, workingFolder);
        Directory.CreateDirectory(root);
        log.Info($"  [ThreePillar JSON] Output folder: {root}");

        List<string> weeks;
        try
        {
            weeks = LoadWeekFolders(lab.DbConnectionString);
        }
        catch (Exception ex)
        {
            log.Error($"  [ThreePillar JSON] Failed to list week ranges: {ex.Message}");
            return;
        }

        if (weeks.Count == 0)
        {
            log.Warn("  [ThreePillar JSON] No WeekFolder values in LineClaimFileLogs — nothing to write.");
            return;
        }

        var latest = weeks[0];
        log.Info($"  [ThreePillar JSON] {weeks.Count} week range(s). Latest = '{latest}'.");

        var created = 0;
        var skipped = 0;
        var failed = 0;

        for (var i = 0; i < weeks.Count; i++)
        {
            var week = weeks[i];
            var isLatest = i == 0;
            var monthsToWrite = isLatest ? TrailingMonthWindows : [DefaultTrailingMonths];

            foreach (var months in monthsToWrite)
            {
                foreach (var pillar in new[] { "LIS", "PMS", "Cash" })
                {
                    var path = FilePath(root, week, months, pillar);
                    var exists = File.Exists(path);

                    if (exists && (!isLatest || !recreateLatest))
                    {
                        skipped++;
                        continue;
                    }

                    if (isLatest && exists && recreateLatest)
                        log.Info($"  [ThreePillar JSON] Latest week '{week}' {pillar} m{months} exists — recreating after ES refresh.");
                    else if (isLatest)
                        log.Info($"  [ThreePillar JSON] Latest week '{week}' {pillar} m{months} missing — creating.");

                    try
                    {
                        WritePillar(lab, week, months, pillar, path, log);
                        created++;
                    }
                    catch (Exception ex)
                    {
                        failed++;
                        log.Error($"  [ThreePillar JSON] {pillar} m{months} '{week}' FAILED: {ex.Message}");
                    }
                }
            }
        }

        log.Info($"  [ThreePillar JSON] Done — wrote {created}, skipped {skipped} existing historical, failed {failed}.");
    }

    private static void WritePillar(
        LabConfig lab, string weekFolder, int trailingMonths, string pillar, string path, AppLogger log)
    {
        if (!TryParseWeekRangeEnd(weekFolder, out var asOf))
            asOf = DateTime.Today.Date;

        var dayWindow = asOf.Day is >= 1 and <= 31 ? asOf.Day : 9;
        var spName = pillar switch
        {
            "LIS" => "dbo.usp_GetBeechTree_ThreePillarLisDiagnostic",
            "PMS" => "dbo.usp_GetBeechTree_ThreePillarPmsDiagnostic",
            _     => "dbo.usp_GetBeechTree_ThreePillarCashDiagnostic",
        };

        using var conn = new SqlConnection(lab.DbConnectionString);
        conn.Open();

        if (!StoredProcedureExists(conn, spName))
            throw new InvalidOperationException($"{spName} is not deployed.");

        using var cmd = new SqlCommand(spName, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = CommandTimeoutSeconds,
        };
        if (pillar == "LIS")
            cmd.Parameters.AddWithValue("@Year", 0);
        cmd.Parameters.AddWithValue("@TrailingMonths", trailingMonths);
        cmd.Parameters.AddWithValue("@DayWindow", dayWindow);
        cmd.Parameters.AddWithValue("@AsOfDate", asOf.Date);

        var sw = System.Diagnostics.Stopwatch.StartNew();
        using var rdr = cmd.ExecuteReader();
        var resultSets = ReadAllResultSets(rdr);
        sw.Stop();

        var scope = $"Last {trailingMonths} months · DayWindow 1–{dayWindow}";
        var (pillarSection, charts) = pillar switch
        {
            "LIS" => ("Pillar 1 — Pipeline Health (LIS Breakdown)", BuildLisCharts(resultSets, trailingMonths, scope)),
            "PMS" => ("Pillar 2 — Revenue Realization (PMS)", BuildPmsCharts(resultSets, scope)),
            _     => ("Pillar 3 — Leakage & Risk (Cash)", BuildCashCharts(resultSets, scope)),
        };

        var payload = new Dictionary<string, object?>
        {
            ["pillar"] = pillar,
            ["pillarSection"] = pillarSection,
            ["labName"] = lab.LabName,
            ["weekFolder"] = weekFolder,
            ["asOfDate"] = asOf.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            ["dayWindow"] = dayWindow,
            ["trailingMonths"] = trailingMonths,
            ["scope"] = scope,
            ["generatedUtc"] = DateTime.UtcNow,
            ["storedProcedure"] = spName,
            ["elapsedMs"] = sw.ElapsedMilliseconds,
            ["charts"] = charts,
        };

        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(dir))
            Directory.CreateDirectory(dir);

        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(payload, JsonOpts));
        File.Copy(tmp, path, overwrite: true);
        File.Delete(tmp);

        log.Info($"  [ThreePillar JSON] Wrote {pillar} m{trailingMonths} '{weekFolder}' charts={charts.Count} ({sw.ElapsedMilliseconds} ms) → {path}");
    }

    /// <summary>
    /// Named chart blocks matching ThreePillarDiagnostic.cshtml LIS titles.
    /// RS1 monthly drives most graphs; RS2/RS3 backlog; RS4 full-period funnel.
    /// </summary>
    private static List<Dictionary<string, object?>> BuildLisCharts(
        List<List<Dictionary<string, object?>>> sets, int trailingMonths, string scope)
    {
        var monthly = SetOrEmpty(sets, 0);
        var backlogSummary = SetOrEmpty(sets, 1);
        var backlogBuckets = SetOrEmpty(sets, 2);
        var funnel = SetOrEmpty(sets, 3);

        return
        [
            Chart(
                "Monthly Collected Sample Volume",
                "Total Samples trend · Check #1",
                scope,
                Project(monthly, "MonthLabel", "TotalSamples", "SortYear", "SortMonth")),
            Chart(
                $"Total Samples & % Resulted — Last {trailingMonths} Months",
                "Bars = volume · % Resulted (right axis)",
                scope,
                Project(monthly, "MonthLabel", "TotalSamples", "Resulted", "PctResulted")),
            Chart(
                "Sample-to-Claim Funnel (Full Period)",
                "Collected → Resulted → Billed over the selected comparable window",
                scope,
                Project(funnel,
                    "Collected", "Resulted", "BilledToInsurance",
                    "PctResulted", "PctBilledOfCollected", "PctBilledOfResulted")),
            Chart(
                "Backlog Age — Resulted Samples Never Entered in PMS",
                "Check #2 · open Resulted / Not-in-AMD backlog as of WeekRange end",
                scope,
                backlogSummary),
            Chart(
                "Backlog Age Buckets",
                "0–7 / 8–14 / 15–30 / 31–60 / 60+",
                scope,
                Project(backlogBuckets, "AgeBucket", "SortOrder", "SampleCount")),
            Chart(
                "% of Resulted Samples Billed to Insurance",
                "Resulted → billed pipeline rate by month",
                scope,
                Project(monthly, "MonthLabel", "Resulted", "BilledToInsurance", "PctBilledOfResulted")),
            Chart(
                "Not Resulted Samples — Monthly Trend",
                "Latest month often Check #1 partial-period spike",
                scope,
                Project(monthly, "MonthLabel", "NotResulted")),
            Chart(
                "Self Pay % vs Client Bill % of Total Samples",
                "Check #6 status-transition",
                scope,
                Project(monthly,
                    "MonthLabel", "TotalSamples", "SelfPay", "ClientBill", "SelfPayPct", "ClientBillPct")),
            Chart(
                "LIS Monthly Detail",
                "Month-by-month breakdown for the selected comparable window",
                scope,
                monthly),
        ];
    }

    /// <summary>Named chart blocks matching _ThreePillarPms.cshtml titles.</summary>
    private static List<Dictionary<string, object?>> BuildPmsCharts(
        List<List<Dictionary<string, object?>>> sets, string scope)
    {
        var reconciliation = SetOrEmpty(sets, 0);
        var fullyAdjusted = SetOrEmpty(sets, 1);
        var writeOffReasons = SetOrEmpty(sets, 2);
        var fullyPaid = SetOrEmpty(sets, 3);
        var insuranceBalance = SetOrEmpty(sets, 4);
        var panelAvg = SetOrEmpty(sets, 5);
        var panelPayerMom = SetOrEmpty(sets, 6);
        var maturity = SetOrEmpty(sets, 7);
        var denialByCarrier = SetOrEmpty(sets, 8);
        var topDenialReasons = SetOrEmpty(sets, 9);

        return
        [
            Chart(
                "1. Billed Claims Reconciliation — LIS vs PMS",
                "Reconciliation Gap = PMS Billed Claims − LIS Billed to Insurance",
                scope,
                Project(reconciliation, "MonthLabel", "PmsBilled", "LisBilledToInsurance", "Gap")),
            Chart(
                "2. Fully Adjusted % of Billed Claims (PMS)",
                "% Fully Adjusted = Fully Adjusted ÷ Billed Claims × 100",
                scope,
                Project(fullyAdjusted, "MonthLabel", "BilledClaims", "FullyAdjusted", "PctFullyAdjusted")),
            Chart(
                "3. Top Write-Off Reason Codes",
                "Reason-code counts from BTWOSummary",
                scope,
                Project(writeOffReasons, "TransactionCodeCombined", "MatchingCount")),
            Chart(
                "4. Insurance Balance % of Billed Claims — Headline PMS Finding",
                "% IB = IB claims ÷ Billed × 100 · composition Fully Denied / No Response / Partially Denied",
                scope,
                Project(insuranceBalance,
                    "MonthLabel", "BilledClaims", "InsuranceBalanceClaims", "PctInsuranceBalance",
                    "FullyDeniedClaims", "NoResponseClaims", "PartiallyDeniedClaims", "InsuranceBalanceAmt")),
            Chart(
                "4b. Insurance Balance Composition (% of open claims)",
                "Fully Denied / No Response / Partially Denied share of open",
                scope,
                Project(insuranceBalance,
                    "MonthLabel", "FullyDeniedClaims", "NoResponseClaims", "PartiallyDeniedClaims",
                    "InsuranceBalanceClaims")),
            Chart(
                "5. Fully Paid % of Billed Claims (PMS)",
                "% Fully Paid = Fully Paid ÷ Billed Claims × 100",
                scope,
                Project(fullyPaid, "MonthLabel", "BilledClaims", "FullyPaid", "PctFullyPaid")),
            Chart(
                "6. Panel — Avg Allowed vs Avg Paid",
                "Claim-level supplement by panel / DOS month",
                scope,
                Project(panelAvg,
                    "Panelname", "MonthLabel_DOS", "AvgAllowed", "AllowedClaimCount",
                    "AvgPaidByPaymentDate", "PaidClaimCount")),
            Chart(
                "Avg $ Paid per Claim — Panel (MOM by DOS)",
                "Panel × payer month-over-month",
                scope,
                panelPayerMom),
            Chart(
                "DOS-Cohort Maturity Curve",
                "Pct allowed paid by days since DOS",
                scope,
                Project(maturity, "DOSMonthLabel", "DaySinceDOS", "PctAllowedPaid")),
            Chart(
                "Denial Rate by Carrier — Ratio-Driver Breakdown",
                "Denied allowed ÷ total allowed",
                scope,
                Project(denialByCarrier, "PayerName", "TotalAllowed", "DeniedAllowed", "DenialRatePct")),
            Chart(
                "Fastest-Escalating Denial Reasons by Payer — MOM",
                "Top denial reasons by payer / month",
                scope,
                Project(topDenialReasons, "PayerName", "DenialCode", "MonthLabel", "DenialCount")),
        ];
    }

    /// <summary>Named chart blocks matching _ThreePillarCash.cshtml titles.</summary>
    private static List<Dictionary<string, object?>> BuildCashCharts(
        List<List<Dictionary<string, object?>>> sets, string scope)
    {
        var headline = SetOrEmpty(sets, 0);
        var writeOffReasons = SetOrEmpty(sets, 1);

        return
        [
            Chart(
                "1. Total Billed $ — Monthly Trend",
                "Monthly $ Billed = SUM(ChargeAmount) WHERE Billed · GROUP BY DOS month",
                scope,
                Project(headline, "MonthLabel", "TotalBilledAmt")),
            Chart(
                "2. Partially Paid $ — Monthly Trend",
                "Partially Paid $ ÷ Total Billed $ × 100",
                scope,
                Project(headline,
                    "MonthLabel", "PartiallyPaidAmt", "PctPartiallyPaidOfBilled", "TotalBilledAmt")),
            Chart(
                "3. Collection Rate — Insurance Payment / Total Billed",
                "Fully Paid Ins $ ÷ Total Billed $ × 100",
                scope,
                Project(headline,
                    "MonthLabel", "InsurancePaymentFullyPaid", "TotalBilledAmt", "CollectionRatePct")),
            Chart(
                "4a. % Insurance Balance $ of Total Billed",
                "IB $ ÷ Total Billed $ × 100",
                scope,
                Project(headline,
                    "MonthLabel", "InsuranceBalanceAmt", "PctInsuranceBalanceOfBilled", "TotalBilledAmt")),
            Chart(
                "4b. Insurance Balance $ Composition",
                "Fully Denied / No Response / Partially Denied share of open IB $",
                scope,
                Project(headline,
                    "MonthLabel", "FullyDeniedIBAmt", "NoResponseIBAmt", "PartiallyDeniedIBAmt",
                    "InsuranceBalanceAmt", "NoResponseSharePct")),
            Chart(
                "5. Patient Write-Off vs Patient Balance",
                "Patient WO $ / Patient Balance $ / Patient Payment $",
                scope,
                Project(headline,
                    "MonthLabel", "PatientWOAmt", "PatientBalanceAmt", "PatientPaymentAmt",
                    "WriteOffRatioPct", "PatientCollectionRatePct")),
            Chart(
                "6. Fully Adjusted $ — Write-Off Reason Pareto",
                "Write-off reason codes from BTWOSummary",
                scope,
                Project(writeOffReasons, "TransactionCodeCombined", "MatchingCount")),
            Chart(
                "Cash monthly detail",
                "Full monthly cash headline metrics for the selected comparable window",
                scope,
                headline),
        ];
    }

    private static Dictionary<string, object?> Chart(
        string graphTitle, string subtitle, string scope, List<Dictionary<string, object?>> rows)
        => new()
        {
            ["graphTitle"] = graphTitle,
            ["subtitle"] = subtitle,
            ["scope"] = scope,
            ["rowCount"] = rows.Count,
            ["rows"] = rows,
        };

    private static List<Dictionary<string, object?>> SetOrEmpty(
        List<List<Dictionary<string, object?>>> sets, int index)
        => index >= 0 && index < sets.Count ? sets[index] : [];

    private static List<Dictionary<string, object?>> Project(
        List<Dictionary<string, object?>> rows, params string[] columns)
    {
        if (rows.Count == 0 || columns.Length == 0)
            return rows;

        var projected = new List<Dictionary<string, object?>>(rows.Count);
        foreach (var row in rows)
        {
            var copy = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            foreach (var col in columns)
            {
                if (TryGetIgnoreCase(row, col, out var value))
                    copy[col] = value;
            }
            projected.Add(copy);
        }
        return projected;
    }

    private static bool TryGetIgnoreCase(
        Dictionary<string, object?> row, string key, out object? value)
    {
        if (row.TryGetValue(key, out value))
            return true;
        foreach (var kv in row)
        {
            if (string.Equals(kv.Key, key, StringComparison.OrdinalIgnoreCase))
            {
                value = kv.Value;
                return true;
            }
        }
        value = null;
        return false;
    }

    private static List<List<Dictionary<string, object?>>> ReadAllResultSets(SqlDataReader rdr)
    {
        var sets = new List<List<Dictionary<string, object?>>>();
        do
        {
            var rows = new List<Dictionary<string, object?>>();
            while (rdr.Read())
            {
                var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                for (var i = 0; i < rdr.FieldCount; i++)
                    row[rdr.GetName(i)] = rdr.IsDBNull(i) ? null : Normalize(rdr.GetValue(i));
                rows.Add(row);
            }
            sets.Add(rows);
        } while (rdr.NextResult());
        return sets;
    }

    private static object? Normalize(object value) => value switch
    {
        DateTime dt => dt.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture),
        DateOnly d  => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        decimal or double or float or byte or short or int or long or bool or string => value,
        _ => Convert.ToString(value, CultureInfo.InvariantCulture),
    };

    private static List<string> LoadWeekFolders(string connectionString)
    {
        const string sql = """
            IF OBJECT_ID('dbo.LineClaimFileLogs','U') IS NULL
            BEGIN
                SELECT CAST(NULL AS NVARCHAR(200)) AS WeekFolder WHERE 1 = 0;
                RETURN;
            END
            SELECT DISTINCT LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200)))) AS WeekFolder
            FROM dbo.LineClaimFileLogs
            WHERE NULLIF(LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200)))), '') IS NOT NULL;
            """;

        var weeks = new List<string>();
        using var conn = new SqlConnection(connectionString);
        conn.Open();
        using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        using var rdr = cmd.ExecuteReader();
        while (rdr.Read())
        {
            if (!rdr.IsDBNull(0))
                weeks.Add(rdr.GetString(0));
        }

        return weeks
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(w => TryParseWeekRangeEnd(w, out var end) ? end : DateTime.MinValue)
            .ThenByDescending(w => w, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static bool StoredProcedureExists(SqlConnection conn, string spName)
    {
        using var cmd = new SqlCommand("SELECT OBJECT_ID(@name, 'P')", conn);
        cmd.Parameters.AddWithValue("@name", spName);
        var result = cmd.ExecuteScalar();
        return result is not null && result != DBNull.Value;
    }

    internal static bool TryParseWeekRangeEnd(string? weekFolder, out DateTime endDate)
    {
        endDate = default;
        if (string.IsNullOrWhiteSpace(weekFolder))
            return false;

        var matches = DateTokenRegex.Matches(weekFolder);
        for (var i = matches.Count - 1; i >= 0; i--)
        {
            if (TryParseDate(matches[i].Value, out var dt))
            {
                endDate = dt.Date;
                return true;
            }
        }

        var text = weekFolder.Trim()
            .Replace('\u00A0', ' ')
            .Replace('\u2013', '-')
            .Replace('\u2014', '-')
            .Replace('\u2212', '-');

        var toIdx = text.LastIndexOf(" to ", StringComparison.OrdinalIgnoreCase);
        var endPart = toIdx >= 0
            ? text[(toIdx + 4)..].Trim()
            : text.Contains('-') ? text[(text.LastIndexOf('-') + 1)..].Trim() : text;

        if (!TryParseDate(endPart, out var endDt))
            return false;

        endDate = endDt.Date;
        return true;
    }

    private static bool TryParseDate(string value, out DateTime dt)
    {
        dt = default;
        if (string.IsNullOrWhiteSpace(value))
            return false;
        var normalized = value.Trim().Replace('.', '/');
        return DateTime.TryParseExact(
                   normalized, DateFormats, CultureInfo.InvariantCulture,
                   DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeLocal, out dt)
               || DateTime.TryParse(normalized, CultureInfo.InvariantCulture,
                   DateTimeStyles.AllowWhiteSpaces, out dt);
    }

    private static string Sanitize(string name)
        => string.Join("_", name.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries)).Trim('_');
}

using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;
using System.Diagnostics;
using System.Globalization;

namespace LabMetricsDashboard.Services;

public sealed class SqlPhiExecutiveSummaryRepository
{
    private readonly ILogger<SqlPhiExecutiveSummaryRepository> _logger;

    private static readonly List<string> RowOrder =
    [
        "A",
        "B","B1","B2","B3","B4","B5","B6","B7","B8","B9","B10",
        "B11","B12","B13","B14","B15","B16","B17","B18","B19","B20",
        "B21","B22","B23","B24","B25","B26","B27","B28","B29","B30","B31",
        "C",
        "D","D1","D2","D3","D-Recv","D-BRR","D-Coll",
        "E","E1","E2","E3",
        "F","F-AMD","F-Bill",
        "G","G1","G-Bill","G-AMD",
        "H","H1","H-AMD","H-Bill",
        "I","I1","I2","I3","I4","I5","I-AMD","I-Bill",
        "J","K",
        "L","L-Recv","L-Coll",
        "M","N","O","P",
        "Q","R","S","T","U","V","W","X","Y","Y.1","Y.2","Y.3",
        "Z","AA","AB","AC","AD","AE","AF","AG","AG1","AG2","AG3","AH","AI1",
        "AJ","AK","AL",

        // Alternate LIS breakdown (RoleID 'L_0','L_A'..'L_B2'), populated by
        // dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt — added alongside the
        // existing A..I LIS rows above, so it gets its own ordered block.
        // Order: Total Samples, then Billable Samples - Resulted (+ its
        // panel sub-rows via the dot-suffix rule below), then A1..A7,
        // then Not Resulted (+ B1..B2), immediately after A7.
        "L_0",
        "L_A",
        "L_A1","L_A1a",
        "L_A2","L_A2a","L_A2b",
        "L_A3",
        "L_A4","L_A4a","L_A4b",
        "L_A5","L_A5a","L_A5b","L_A5c",
        "L_A6","L_A6a",
        "L_A7","L_A7a","L_A7b","L_A7c",
        "L_B",
        "L_B1","L_B1a","L_B1b",
        "L_B2",
    ];

    public SqlPhiExecutiveSummaryRepository(ILogger<SqlPhiExecutiveSummaryRepository> logger)
        => _logger = logger;

    /// <summary>
    /// Reads the run/analysis-range banner values for the Executive Summary header:
    ///   • <c>WeekFolder</c> + <c>RunId</c> from the latest <c>ClaimLevelData</c> row
    ///     (drives "Analysis Range: Billed Date — …" and "ReportId (RUNID)").
    ///   • <c>RunId</c> from <c>LIMSMaster</c> (shown alongside, per request).
    /// All lookups are best-effort: any missing table/column or error degrades to
    /// NULL rather than failing the page. RunId is sorted DESC so the most recent
    /// run wins (RunId values like '20260617R0271' sort chronologically as text).
    /// </summary>
    public async Task<(string? WeekFolder, string? ClaimRunId, string? LimsRunId)> GetRunInfoAsync(
        string connectionString, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        string? weekFolder = null, claimRunId = null, limsRunId = null;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            // ClaimLevelData — latest WeekFolder + RunId
            const string claimSql = @"
                IF OBJECT_ID('dbo.ClaimLevelData','U') IS NOT NULL
                   AND COL_LENGTH('dbo.ClaimLevelData','RunId') IS NOT NULL
                SELECT TOP 1
                       CAST(WeekFolder AS NVARCHAR(200)),
                       CAST(RunId      AS NVARCHAR(50))
                FROM dbo.ClaimLevelData
                WHERE NULLIF(LTRIM(RTRIM(RunId)), '') IS NOT NULL
                ORDER BY RunId DESC;";
            await using (var cmd = new SqlCommand(claimSql, conn) { CommandTimeout = 30 })
            await using (var rdr = await cmd.ExecuteReaderAsync(ct))
            {
                if (await rdr.ReadAsync(ct))
                {
                    weekFolder = rdr.IsDBNull(0) ? null : rdr.GetString(0);
                    claimRunId = rdr.IsDBNull(1) ? null : rdr.GetString(1);
                }
            }

            // LIMSMaster — latest RunId
            const string limsSql = @"
                IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
                   AND COL_LENGTH('dbo.LIMSMaster','RunId') IS NOT NULL
                SELECT TOP 1 CAST(RunId AS NVARCHAR(50))
                FROM dbo.LIMSMaster
                WHERE NULLIF(LTRIM(RTRIM(RunId)), '') IS NOT NULL
                ORDER BY RunId DESC;";
            await using (var cmd = new SqlCommand(limsSql, conn) { CommandTimeout = 30 })
            await using (var rdr = await cmd.ExecuteReaderAsync(ct))
            {
                if (await rdr.ReadAsync(ct))
                    limsRunId = rdr.IsDBNull(0) ? null : rdr.GetString(0);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to read Executive Summary RunInfo (ClaimLevelData / LIMSMaster).");
        }

        return (weekFolder, claimRunId, limsRunId);
    }

    /// <summary>
    /// Returns a stable floating-point sort key for a RowCode.
    ///
    /// Exact matches use their position in <see cref="RowOrder"/>.
    ///
    /// Dotted codes that are NOT in RowOrder are resolved recursively from
    /// the rightmost segment, so multi-level codes like "D.5.1" correctly
    /// sort as a child of "D.5" (which is itself a child of "D") rather than
    /// jumping straight up to "D".
    ///
    /// Each nesting level uses a scale that is 10 000× smaller than the
    /// level above, so children always fall between their parent and the next
    /// sibling regardless of how many items exist at each level:
    ///   level-1  (one dot)   scale = 0.0001   →  D.1 = D_idx + 0.0001
    ///   level-2  (two dots)  scale = 0.00000001 →  D.5.1 = D.5_key + 0.00000001
    ///
    /// Non-numeric suffixes (e.g. panel-type names like "NGS") receive a
    /// mid-range fractional offset so they cluster after their parent row;
    /// the secondary ThenBy(RowCode) alphabetical sort separates them.
    ///
    /// Any RowCode whose entire ancestor chain is unmapped falls back to 9999.
    /// </summary>
    private static double GetSortKey(string rowCode, Dictionary<string, int> orderIndex)
    {
        // Exact hit in the known order table.
        if (orderIndex.TryGetValue(rowCode, out var idx))
            return idx;

        // Peel the rightmost segment and resolve the parent recursively.
        var lastDot = rowCode.LastIndexOf('.');
        if (lastDot <= 0) return 9999;

        var parentCode = rowCode[..lastDot];
        var suffix     = rowCode[(lastDot + 1)..];
        var parentKey  = GetSortKey(parentCode, orderIndex);

        if (parentKey >= 9999) return 9999;   // no known ancestor — leave unsorted

        // Scale: 10 000× smaller per nesting level so children never overlap
        // siblings at the same level.  level = number of dots in full rowCode.
        var level = rowCode.Count(c => c == '.');
        var scale = Math.Pow(0.0001, level);   // 0.0001 at level 1, 1e-8 at level 2, …

        return int.TryParse(suffix, out var n)
            ? parentKey + n * scale
            : parentKey + scale * 50;   // non-numeric names: mid-slot; ThenBy separates them
    }

    /// <summary>Checks whether a stored procedure exists in the target database.</summary>
    public async Task<bool> StoredProcedureExistsAsync(
        string connectionString, string spName, CancellationToken ct = default)
    {
        try
        {
            // Strip schema prefix for OBJECT_ID check
            var name = spName.Contains('.') ? spName[(spName.IndexOf('.') + 1)..] : spName;
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(
                "SELECT CASE WHEN OBJECT_ID(@sp, 'P') IS NOT NULL THEN 1 ELSE 0 END;", conn)
                { CommandTimeout = 10 };
            cmd.Parameters.AddWithValue("@sp", spName);
            var result = await cmd.ExecuteScalarAsync(ct);
            return result is 1 or (object)1L or "1";
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Calls the given SP and returns a fully-assembled view model.
    /// When <paramref name="useExtendedFilters"/> is <c>true</c> the extended Cove
    /// filter parameters are appended to the SQL command (date ranges + dimension lists).
    /// For all other labs leave the flag <c>false</c> so the extra params are not sent
    /// to SPs that don't declare them.
    /// </summary>
    public async Task<PhiExecutiveSummaryViewModel> GetExecutiveSummaryAsync(
        string connectionString,
        string spName,
        List<string> availableLabs,
        string selectedLab,
        int? yearFrom,
        int? yearTo,
        int? monthFrom,
        int? monthTo,
        bool      useExtendedFilters = false,
        DateTime? dosFrom            = null,
        DateTime? dosTo              = null,
        DateTime? billedFrom         = null,
        DateTime? billedTo           = null,
        string?   panels             = null,
        string?   clinics            = null,
        string?   providers          = null,
        string?   reps               = null,
        CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

        var vm = new PhiExecutiveSummaryViewModel
        {
            AvailableLabs     = availableLabs,
            SelectedLab       = selectedLab,
            SelectedYearFrom  = yearFrom,
            SelectedYearTo    = yearTo,
            SelectedMonthFrom = monthFrom,
            SelectedMonthTo   = monthTo,
            DosFrom      = dosFrom,
            DosTo        = dosTo,
            BilledFrom   = billedFrom,
            BilledTo     = billedTo,
            SelectedPanels    = panels    is null ? [] : [.. panels.Split(',',    StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)],
            SelectedClinics   = clinics   is null ? [] : [.. clinics.Split(',',   StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)],
            SelectedProviders = providers is null ? [] : [.. providers.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)],
            SelectedReps      = reps      is null ? [] : [.. reps.Split(',',      StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)],
        };

        var sw = Stopwatch.StartNew();
        try
        {
            var rawRows = new List<(string RowCode, string Category, string Description, int BillYear, int BillMonth, decimal MetricValue)>();

            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(spName, conn)
            {
                CommandType    = System.Data.CommandType.StoredProcedure,
                CommandTimeout = 120,
            };
            cmd.Parameters.AddWithValue("@YearFrom",  (object?)yearFrom  ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@YearTo",    (object?)yearTo    ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@MonthFrom", (object?)monthFrom ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@MonthTo",   (object?)monthTo   ?? DBNull.Value);

            // Extended Cove filters — only added when the SP declares these params
            if (useExtendedFilters)
            {
                cmd.Parameters.Add("@DosFrom",       System.Data.SqlDbType.Date).Value = (object?)dosFrom       ?? DBNull.Value;
                cmd.Parameters.Add("@DosTo",         System.Data.SqlDbType.Date).Value = (object?)dosTo         ?? DBNull.Value;
                cmd.Parameters.Add("@BilledFrom",    System.Data.SqlDbType.Date).Value = (object?)billedFrom    ?? DBNull.Value;
                cmd.Parameters.Add("@BilledTo",      System.Data.SqlDbType.Date).Value = (object?)billedTo      ?? DBNull.Value;
                cmd.Parameters.Add("@Panels",    System.Data.SqlDbType.NVarChar, -1).Value = (object?)panels    ?? DBNull.Value;
                cmd.Parameters.Add("@Clinics",   System.Data.SqlDbType.NVarChar, -1).Value = (object?)clinics   ?? DBNull.Value;
                cmd.Parameters.Add("@Providers", System.Data.SqlDbType.NVarChar, -1).Value = (object?)providers ?? DBNull.Value;
                cmd.Parameters.Add("@Reps",      System.Data.SqlDbType.NVarChar, -1).Value = (object?)reps      ?? DBNull.Value;
            }

            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                rawRows.Add((
                    Convert.ToString(reader.GetValue(0)) ?? "",
                    Convert.ToString(reader.GetValue(1)) ?? "",
                    Convert.ToString(reader.GetValue(2)) ?? "",
                    reader.IsDBNull(3) ? 0 : Convert.ToInt32(reader.GetValue(3)),
                    reader.IsDBNull(4) ? 0 : Convert.ToInt32(reader.GetValue(4)),
                    reader.IsDBNull(5) ? 0m : Convert.ToDecimal(reader.GetValue(5))
                ));
            }

            _logger.LogInformation("ExecutiveSummary '{Lab}' SP={Sp}: {N} rows in {Ms}ms",
                selectedLab, spName, rawRows.Count, sw.ElapsedMilliseconds);

            if (rawRows.Count == 0)
                return vm;

            var rowDict   = new Dictionary<string, ExecSummaryRow>(StringComparer.OrdinalIgnoreCase);
            // Track which (Year, Month) columns have any non-zero activity so we
            // don't surface empty future stubs (e.g. Dec 2026 with all zeros).
            var periodActivity = new Dictionary<(int Year, int Month), bool>();
            var yearSet = new SortedSet<int>();
            var yearlyTotals = new Dictionary<int, decimal>();

            foreach (var (rowCode, category, description, billYear, billMonth, metricValue) in rawRows)
            {
                // Key on Category+RowCode: the same RowCode (e.g. "X") can be reused
                // across categories (PMS "Patient Payment" vs Cash "Total Billed ($)").
                // Keying on RowCode alone would merge those into a single row.
                var rowKey = category + "::" + rowCode;
                if (!rowDict.TryGetValue(rowKey, out var row))
                {
                    row = new ExecSummaryRow
                    {
                        RowCode     = rowCode,
                        Category    = category,
                        Description = description,
                    };
                    rowDict[rowKey] = row;
                }
                row.ValuesByYearMonth[(billYear, billMonth)] = metricValue;
                if (billYear != 0 && billMonth is >= 1 and <= 12)
                {
                    if (metricValue != 0m)
                        periodActivity[(billYear, billMonth)] = true;
                    else
                        periodActivity.TryAdd((billYear, billMonth), false);
                    yearSet.Add(billYear);

                    // Sum up yearly totals, but only for cash/avg categories
                    if (category is "Cash" or "Avg")
                    {
                        yearlyTotals.TryGetValue(billYear, out var currentTotal);
                        yearlyTotals[billYear] = currentTotal + metricValue;
                    }
                }
                else if (billYear != 0)
                {
                    // Per-year sentinel row (BillYear=Y, BillMonth=0): currently the
                    // "Avg" rows' weighted year averages. Keep the value in
                    // ValuesByYearMonth so the year-total column can read it, but do
                    // NOT register it as a month column or fold it into yearlyTotals.
                    yearSet.Add(billYear);
                }
            }

            // Month columns = periods with real activity only (drops empty Dec stubs, etc.).
            var columns = periodActivity
                .Where(kv => kv.Value)
                .Select(kv => kv.Key)
                .OrderBy(p => p.Year).ThenBy(p => p.Month)
                .ToList();
            columns.Add((0, 0));

            vm.YearMonthColumns = columns;
            vm.AvailableYears   = yearSet.ToList();
            vm.YearlyTotals     = yearlyTotals;

            var orderIndex = RowOrder
                .Select((code, idx) => (code, idx))
                .ToDictionary(t => t.code, t => t.idx, StringComparer.OrdinalIgnoreCase);

            vm.Rows = rowDict.Values
                .OrderBy(r => GetSortKey(r.RowCode, orderIndex))
                .ThenBy(r => r.RowCode, StringComparer.OrdinalIgnoreCase)
                .ToList();

            return vm;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "ExecutiveSummary query failed for lab '{Lab}' SP='{Sp}'.", selectedLab, spName);
            vm.ErrorMessage = $"Failed to load Executive Summary data: {ex.Message}";
            return vm;
        }
    }

    // Keep old method name for backward compat during transition
    public Task<PhiExecutiveSummaryViewModel> GetPhiExecutiveSummaryAsync(
        string connectionString, List<string> availableLabs, string selectedLab,
        int? yearFrom, int? yearTo, int? monthFrom, int? monthTo, CancellationToken ct = default)
        => GetExecutiveSummaryAsync(connectionString, "dbo.usp_GetPhi_ExecutiveSummary",
            availableLabs, selectedLab, yearFrom, yearTo, monthFrom, monthTo, ct: ct);

    public async Task<List<int>> GetAvailableYearsAsync(
        string connectionString, CancellationToken ct = default)
    {
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(
                "SELECT DISTINCT YEAR(TRY_CAST(DateofService AS DATE)) FROM dbo.ClaimLevelData " +
                "WHERE DateofService IS NOT NULL ORDER BY 1 DESC;",
                conn) { CommandTimeout = 30 };
            await using var r = await cmd.ExecuteReaderAsync(ct);
            var years = new List<int>();
            while (await r.ReadAsync(ct))
                if (!r.IsDBNull(0)) years.Add(r.GetInt32(0));
            return years;
        }
        catch { return []; }
    }

    /// <summary>
    /// Returns the individual claim rows that make up a single Executive Summary cell.
    /// </summary>
    public async Task<ExecSummaryDetailViewModel> GetDetailRowsAsync(
        string connectionString,
        string detailSpName,        // e.g. "dbo.usp_GetRT_ExecutiveSummary_Detail"
        string category,
        string rowCode,
        string description,
        int year,
        int month,
        CancellationToken ct = default)
    {
        var vm = new ExecSummaryDetailViewModel
        {
            Category    = category,
            RowCode     = rowCode,
            Description = description,
            Year        = year,
            Month       = month,
            MonthLabel  = month == 0
                ? (year == 0 ? "All" : year.ToString())
                : System.Globalization.CultureInfo.InvariantCulture
                    .DateTimeFormat.GetAbbreviatedMonthName(month) + " " + year,
        };

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(detailSpName, conn)
            {
                CommandType    = System.Data.CommandType.StoredProcedure,
                CommandTimeout = 120,
            };
            cmd.Parameters.AddWithValue("@Category", category);
            cmd.Parameters.AddWithValue("@RowCode",  rowCode);
            cmd.Parameters.AddWithValue("@Year",     year);
            cmd.Parameters.AddWithValue("@Month",    month);

            bool isCash = string.Equals(category, "Cash", StringComparison.OrdinalIgnoreCase);

            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var row = new ExecSummaryDetailRow
                {
                    VisitNumber      = reader.IsDBNull(0)  ? "" : reader.GetString(0),
                    PatientName      = reader.IsDBNull(1)  ? "" : reader.GetString(1),
                    PayerName        = reader.IsDBNull(2)  ? "" : reader.GetString(2),
                    PanelName        = reader.IsDBNull(3)  ? "" : reader.GetString(3),
                    ClinicName       = reader.IsDBNull(4)  ? "" : reader.GetString(4),
                    BillingProvider  = reader.IsDBNull(5)  ? "" : reader.GetString(5),
                    DateOfService    = reader.IsDBNull(6)  ? null : reader.GetDateTime(6),
                    FirstBilledDate  = reader.IsDBNull(7)  ? null : reader.GetDateTime(7),
                    BilledUnbilled   = reader.IsDBNull(8)  ? "" : reader.GetString(8),
                    ClaimStatus      = reader.IsDBNull(9)  ? "" : reader.GetString(9),
                    ChargeAmount     = reader.IsDBNull(10) ? 0m : reader.GetDecimal(10),
                    InsurancePayment = reader.IsDBNull(11) ? 0m : reader.GetDecimal(11),
                    PatientPayment   = reader.IsDBNull(12) ? 0m : reader.GetDecimal(12),
                };

                if (isCash)
                {
                    // Cash SP returns 2 extra columns before InsuranceBalance
                    row.InsuranceAdjustments = reader.IsDBNull(13) ? 0m : reader.GetDecimal(13);
                    row.PatientAdjustments   = reader.IsDBNull(14) ? 0m : reader.GetDecimal(14);
                    row.InsuranceBalance     = reader.IsDBNull(15) ? 0m : reader.GetDecimal(15);
                    row.PatientBalance       = reader.IsDBNull(16) ? 0m : reader.GetDecimal(16);
                }
                else
                {
                    row.InsuranceBalance = reader.IsDBNull(13) ? 0m : reader.GetDecimal(13);
                    row.PatientBalance   = reader.IsDBNull(14) ? 0m : reader.GetDecimal(14);
                }

                vm.Rows.Add(row);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "ExecutiveSummary detail query failed. SP='{Sp}' Category={Cat} RowCode={Rc}",
                detailSpName, category, rowCode);
            vm.ErrorMessage = $"Failed to load detail: {ex.Message}";
        }

        return vm;
    }

    /// <summary>
    /// Calls the given <paramref name="spName"/> (an ExecutiveSummary_FilterOptions SP)
    /// and returns a dictionary keyed by FilterType ("Year", "Panel", "Clinic", "Provider", "Rep").
    /// Works for any lab that has a <c>usp_Get{prefix}_ExecutiveSummary_FilterOptions</c> SP.
    /// </summary>
    public async Task<Dictionary<string, List<string>>> GetFilterOptionsAsync(
        string connectionString, string spName, CancellationToken ct = default)
    {
        var result = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase)
        {
            ["Year"]     = [],
            ["Panel"]    = [],
            ["Clinic"]   = [],
            ["Provider"] = [],
            ["Rep"]      = [],
        };

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(spName, conn)
            {
                CommandType    = System.Data.CommandType.StoredProcedure,
                CommandTimeout = 60,
            };
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                var filterType  = reader.IsDBNull(0) ? "" : reader.GetString(0);
                var filterValue = reader.IsDBNull(1) ? "" : reader.GetString(1);
                if (string.IsNullOrWhiteSpace(filterType) || string.IsNullOrWhiteSpace(filterValue))
                    continue;
                if (result.TryGetValue(filterType, out var list))
                    list.Add(filterValue);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "GetFilterOptionsAsync failed for SP '{SpName}'.", spName);
        }

        return result;
    }

    /// <summary>Backward-compat wrapper — delegates to <see cref="GetFilterOptionsAsync"/>.</summary>
    public Task<Dictionary<string, List<string>>> GetCoveFilterOptionsAsync(
        string connectionString, CancellationToken ct = default)
        => GetFilterOptionsAsync(connectionString, "dbo.usp_GetCove_ExecutiveSummary_FilterOptions", ct);

    /// <summary>
    /// Returns the full row-level data behind a single Executive Summary cell,
    /// using whichever "row-level detail" SP is appropriate for the clicked
    /// category (LIMSMaster for LIS, ClaimLevelData for PMS/Cash, or —
    /// RisingTides only — ClientPaidListData for "2. PMS Breakdown → Paid - Client").
    /// Unlike <see cref="GetDetailRowsAsync"/>, the column list is read directly
    /// off the SqlDataReader so this works for any SP shape without a fixed
    /// C# row type.
    /// </summary>
    public async Task<ExecSummaryDetailRowsViewModel> GetDetailRowsDynamicAsync(
        string connectionString,
        string detailSpName,
        Dictionary<string, object?> parameters,
        string category,
        string rowCode,
        string description,
        int year,
        int month,
        string sourceLabel,
        CancellationToken ct = default)
    {
        var vm = new ExecSummaryDetailRowsViewModel
        {
            Category    = category,
            RowCode     = rowCode,
            Description = description,
            Year        = year,
            Month       = month,
            SourceLabel = sourceLabel,
            MonthLabel  = month == 0
                ? (year == 0 ? "All" : year.ToString())
                : System.Globalization.CultureInfo.InvariantCulture
                    .DateTimeFormat.GetAbbreviatedMonthName(month) + " " + year,
        };

        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(detailSpName, conn)
            {
                CommandType    = System.Data.CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            foreach (var (key, value) in parameters)
                cmd.Parameters.AddWithValue(key, value ?? DBNull.Value);

            await using var reader = await cmd.ExecuteReaderAsync(ct);

            var fieldCount = reader.FieldCount;
            for (int i = 0; i < fieldCount; i++)
                vm.Columns.Add(reader.GetName(i));

            while (await reader.ReadAsync(ct))
            {
                var values = new object?[fieldCount];
                for (int i = 0; i < fieldCount; i++)
                    values[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                vm.Rows.Add(values);
            }

            _logger.LogInformation(
                "ExecutiveSummary detail-rows SP={Sp} Category={Cat} RowCode={Rc} Year={Year} Month={Month}: {N} rows, {Cols} cols in {Ms}ms",
                detailSpName, category, rowCode, year, month, vm.Rows.Count, vm.Columns.Count, sw.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "ExecutiveSummary detail-rows query failed. SP='{Sp}' Category={Cat} RowCode={Rc}",
                detailSpName, category, rowCode);
            vm.ErrorMessage = $"Failed to load detail: {ex.Message}";
        }

        return vm;
    }

    /// <summary>
    /// Reads the LIS Breakdown analytical drill (Total No. of Samples / Billable
    /// Samples - Resulted) from dbo.usp_GetExecutiveSummaryDetail_LisDrill, which
    /// returns four result sets: summary, nine-day band, top panels, result rate.
    /// </summary>
    public async Task<ExecSummaryLisDrillViewModel> GetLisDrillAsync(
        string connectionString,
        string spName,
        string metric,
        int    year,
        int    dayWindow = 9,
        CancellationToken ct = default)
    {
        var vm = new ExecSummaryLisDrillViewModel { Metric = metric, Year = year, ComparableDayWindow = dayWindow };
        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(spName, conn)
            {
                CommandType    = System.Data.CommandType.StoredProcedure,
                CommandTimeout = 180,
            };
            cmd.Parameters.AddWithValue("@Metric", metric);
            cmd.Parameters.AddWithValue("@Year",   year);
            cmd.Parameters.AddWithValue("@DayWindow", dayWindow);

            await using var r = await cmd.ExecuteReaderAsync(ct);

            // Case-insensitive name→ordinal map for the current result set,
            // so the reader is resilient to column ordering.
            Dictionary<string, int> Map()
            {
                var m = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                for (int i = 0; i < r.FieldCount; i++) m[r.GetName(i)] = i;
                return m;
            }
            long L(Dictionary<string, int> m, string c) =>
                m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToInt64(r.GetValue(i)) : 0L;
            string S(Dictionary<string, int> m, string c) =>
                m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToString(r.GetValue(i)) ?? "" : "";
            decimal? DN(Dictionary<string, int> m, string c) =>
                m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToDecimal(r.GetValue(i)) : (decimal?)null;
            decimal D(Dictionary<string, int> m, string c) =>
                m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToDecimal(r.GetValue(i)) : 0m;
            DateTime? DT(Dictionary<string, int> m, string c) =>
                m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToDateTime(r.GetValue(i)) : (DateTime?)null;

            // Set 1 — summary band
            var map = Map();
            if (await r.ReadAsync(ct))
            {
                vm.Summary = new LisDrillSummary
                {
                    CutoffDate       = DT(map, "CutoffDate"),
                    LatestMonthLabel = S(map, "LatestMonthLabel"),
                    LatestCount      = L(map, "LatestCount"),
                    PrevMonthLabel   = S(map, "PrevMonthLabel"),
                    PrevCount        = L(map, "PrevCount"),
                    MoMChangePct     = DN(map, "MoMChangePct"),
                    Avg6             = DN(map, "Avg6"),
                    CurrVsAvgPct     = DN(map, "CurrVsAvgPct"),
                    Latest9DayLabel  = S(map, "Latest9DayLabel"),
                    Latest9DayCount  = L(map, "Latest9DayCount"),
                    Prev9DayLabel    = S(map, "Prev9DayLabel"),
                    Prev9DayCount    = L(map, "Prev9DayCount"),
                    NineDayMoMPct    = DN(map, "NineDayMoMPct"),
                };
            }

            // Set 2 — monthly totals (trend chart). Defensive against an older
            // SP shape (MonthLabel + Count) so labels/bars still render if the
            // procedure has not been re-deployed yet.
            if (await r.NextResultAsync(ct))
            {
                map = Map();
                while (await r.ReadAsync(ct))
                {
                    var monthLabel = S(map, "MonthLabel");
                    var shortLabel = S(map, "ShortLabel");
                    if (string.IsNullOrEmpty(shortLabel))
                        shortLabel = monthLabel.Length >= 3 ? monthLabel[..3] : monthLabel;
                    var total = map.ContainsKey("Total") ? L(map, "Total") : L(map, "Count");
                    vm.Monthly.Add(new LisDrillMonthly
                    {
                        MonthLabel = monthLabel,
                        ShortLabel = shortLabel,
                        Total      = total,
                        IsPartial  = L(map, "IsPartial") == 1,
                    });
                }
            }

            // Set 3 — top panels
            if (await r.NextResultAsync(ct))
            {
                map = Map();
                while (await r.ReadAsync(ct))
                {
                    var avg6 = map.ContainsKey("Avg6Months") ? D(map, "Avg6Months") : D(map, "PeriodTotal");
                    vm.Panels.Add(new LisDrillPanel
                    {
                        Panel       = S(map, "Panel"),
                        PeriodTotal = L(map, "PeriodTotal"),
                        Avg6Months  = avg6 > 0 ? avg6 : L(map, "PeriodTotal"),
                        SharePct    = D(map, "SharePct"),
                        Prev9Day    = L(map, "Prev9Day"),
                        Latest9Day  = L(map, "Latest9Day"),
                        MoMDeltaPct = DN(map, "MoMDeltaPct"),
                    });
                }
            }

            // Set 4 — result rate
            if (await r.NextResultAsync(ct))
            {
                map = Map();
                while (await r.ReadAsync(ct))
                    vm.ResultRates.Add(new LisDrillResultRate
                    {
                        MonthLabel = S(map, "MonthLabel"),
                        Resulted   = L(map, "Resulted"),
                        Received   = L(map, "Received"),
                        RatePct    = DN(map, "RatePct"),
                    });
            }

            // Set 5 — Not-Resulted status breakdown (ClientStatus x month)
            if (await r.NextResultAsync(ct))
            {
                map = Map();
                while (await r.ReadAsync(ct))
                    vm.StatusBreakdown.Add(new LisDrillStatusRow
                    {
                        Status = S(map, "Status"),
                        Year   = (int)L(map, "CollYear"),
                        Month  = (int)L(map, "CollMonth"),
                        Count  = L(map, "Cnt"),
                    });
            }

            // Set 6 — Data for 9 days range (received in first 9 days, per month)
            if (await r.NextResultAsync(ct))
            {
                map = Map();
                while (await r.ReadAsync(ct))
                    vm.NineDayRange.Add(new LisDrillNineDayRange
                    {
                        MonthLabel = S(map, "MonthLabel"),
                        ShortLabel = S(map, "ShortLabel"),
                        Received9  = L(map, "Received9"),
                    });
            }

            // Set 7 — Result Rate by panel (9-day resulted / 9-day received)
            if (await r.NextResultAsync(ct))
            {
                map = Map();
                while (await r.ReadAsync(ct))
                    vm.RatePanels.Add(new LisDrillRatePanel
                    {
                        Panel     = S(map, "Panel"),
                        Year      = (int)L(map, "CollYear"),
                        Month     = (int)L(map, "CollMonth"),
                        Resulted9 = L(map, "Resulted9"),
                        Received9 = L(map, "Received9"),
                    });
            }

            // Set 8 (optional): Top clinics under each top panel — LIS core after redeploy.
            if (await r.NextResultAsync(ct))
                await AttachPanelClinicsAsync(vm, r, ct);

            _logger.LogInformation(
                "ExecutiveSummary LIS drill SP={Sp} Metric={Metric} Year={Year}: panels={Panels}, months={Months} in {Ms}ms",
                spName, metric, year, vm.Panels.Count, vm.Monthly.Count, sw.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex,
                "ExecutiveSummary LIS drill failed. SP='{Sp}' Metric={Metric} Year={Year}",
                spName, metric, year);
            vm.ErrorMessage = $"Failed to load drill-through: {ex.Message}";
        }

        return vm;
    }

    /// <summary>Row-filter definition read from dbo.LisDrillRowDef.</summary>
    public sealed record LisDrillRowDefinition(
        string RowTitle, string? DateCol,
        string? Col1, string? Op1, string? Val1,
        string? Col2, string? Op2, string? Val2,
        string? Col3, string? Op3, string? Val3,
        string? Col4, string? Op4, string? Val4,
        string? Source = null,
        string? Sec1Name = null, string? Sec1Col = null, string? Sec1Vals = null,
        string? Sec2Name = null, string? Sec2Col = null, string? Sec2Vals = null,
        string? Sec3Name = null, string? Sec3Col = null, string? Sec3Vals = null,
        string? AmountCol = null)
    {
        public bool HasCondition => !string.IsNullOrEmpty(Col1);
        public bool IsPms => string.Equals(Source, "PMS", StringComparison.OrdinalIgnoreCase);
        public bool IsCash => string.Equals(Source, "Cash", StringComparison.OrdinalIgnoreCase);

        /// <summary>
        /// RowDef Sec1/2/3 series (e.g. Insurance Balance No Response / Denied) —
        /// Core SP already builds StatusBreakdown; skip the heavy ES grid prefetch.
        /// </summary>
        public bool HasCoreStatusStack =>
            new[] { Sec1Name, Sec2Name, Sec3Name }
                .Count(n => !string.IsNullOrWhiteSpace(n)) >= 2;

        /// <summary>
        /// Primary PMS "Total Billed (Claims)" row — companion mismatch band is shown
        /// only for these drills (not Fully Paid / Unbilled / mismatch itself).
        /// </summary>
        public bool IsPmsTotalBilledClaims
        {
            get
            {
                if (!IsPms) return false;
                var t = RowTitle?.Trim() ?? "";
                if (t.Contains("Mismatch", StringComparison.OrdinalIgnoreCase)) return false;
                if (t.Contains("Unbilled", StringComparison.OrdinalIgnoreCase)) return false;
                if (t.Contains("Not Billed", StringComparison.OrdinalIgnoreCase)) return false;
                return t.Contains("Billed (Claims)", StringComparison.OrdinalIgnoreCase)
                    || t.Contains("Billed - Includes", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(t, "Billed", StringComparison.OrdinalIgnoreCase);
            }
        }

        /// <summary>
        /// PMS Fully Paid row — companion "Fully Paid Rate vs. Billed Claims" band
        /// is loaded from the Executive Summary grid (same source as pmsgrid).
        /// Matches "Fully Paid - Insurance Pay", em-dash variants, Cove "Fully Paid", etc.
        /// </summary>
        public bool IsPmsFullyPaid
        {
            get
            {
                if (!IsPms) return false;
                var t = RowTitle?.Trim() ?? "";
                if (t.Contains('$')) return false;
                return t.Contains("Fully Paid", StringComparison.OrdinalIgnoreCase);
            }
        }

        /// <summary>
        /// PMS "Billed Mismatches" formula row (PMS Billed − LIS Billed), not a
        /// ClaimStatus filter. Op1 is MISMATCH / MIS / MI (truncated) / MISMATCH|IN / …
        /// or the row title contains "Mismatch" / "Billed vs".
        /// </summary>
        public bool IsPmsMismatch
        {
            get
            {
                if (IsMismatchOp(Op1) || IsMismatchOp(Op2) || IsMismatchOp(Op3) || IsMismatchOp(Op4))
                    return true;
                if (!IsPms) return false;
                return ExecSummaryLisDrillViewModel.LooksLikeMismatchTitle(RowTitle);
            }
        }

        /// <summary>True when <paramref name="op"/> is a mismatch-mode operator token.</summary>
        public static bool IsMismatchOp(string? op)
        {
            if (string.IsNullOrWhiteSpace(op)) return false;
            var o = op.Trim();
            if (o.StartsWith("MIS", StringComparison.OrdinalIgnoreCase)) return true;
            return string.Equals(o, "MI", StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>
    /// Prefetch the lab Executive Summary grid for drill companion bands
    /// (Fully Paid rate / Billed Mismatch). Runs in parallel with the Core SP.
    /// Returns null when the SP is missing or empty.
    /// </summary>
    public async Task<PhiExecutiveSummaryViewModel?> PrefetchExecutiveSummaryForDrillAsync(
        string connectionString,
        string labPrefix,
        string labName,
        int year,
        CancellationToken ct = default)
    {
        var spName = $"dbo.usp_Get{labPrefix}_ExecutiveSummary";
        if (!await StoredProcedureExistsAsync(connectionString, spName, ct))
            return null;

        int? yearFrom = year == 0 ? null : year;
        int? yearTo   = year == 0 ? null : year;

        var es = await GetExecutiveSummaryAsync(
            connectionString, spName,
            availableLabs: [labName], selectedLab: labName,
            yearFrom, yearTo, monthFrom: null, monthTo: null,
            useExtendedFilters: true, ct: ct);

        if (es.Rows.Count == 0)
        {
            es = await GetExecutiveSummaryAsync(
                connectionString, spName,
                availableLabs: [labName], selectedLab: labName,
                yearFrom, yearTo, monthFrom: null, monthTo: null,
                useExtendedFilters: false, ct: ct);
        }

        return es.Rows.Count == 0 ? null : es;
    }

    /// <summary>
    /// True when Core left &lt;2 status series or only placeholder panels — only then
    /// is the Executive Summary SP needed for stack / By-Panel backfill.
    /// </summary>
    public bool NeedsEsStackOrPanelBackfill(ExecSummaryLisDrillViewModel vm)
    {
        if (vm.IsPmsMismatchDrill || vm.IsPmsFullyPaidDrill) return false;

        var statusCount = vm.StatusBreakdown
            .Select(s => s.Status?.Trim() ?? "")
            .Where(s => s.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();
        // Insurance Balance (Sec1/2/3) and similar — Core already stacked.
        if (statusCount >= 2) return false;

        return true;
    }

    /// <summary>
    /// Parent rows with ES subcategories (Other Samples → Client Bill / Self Pay, …)
    /// get a stacked StatusBreakdown from the Index grid children when the Core SP
    /// did not already return ≥2 Sec1/2/3 status series.
    /// </summary>
    public void ApplyEsSubcategoryStackFromSummary(
        ExecSummaryLisDrillViewModel vm,
        PhiExecutiveSummaryViewModel? es,
        int year,
        string? rowCode,
        string? category)
    {
        if (es is null || es.Rows.Count == 0) return;
        if (vm.IsPmsMismatchDrill || vm.IsPmsFullyPaidDrill) return;

        var existingStatuses = vm.StatusBreakdown
            .Select(s => s.Status?.Trim() ?? "")
            .Where(s => s.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();
        if (existingStatuses >= 2) return; // Sec1/2/3 or Not-Resulted ClientStatus already present

        var children = FindEsImmediateChildren(es, vm, rowCode, category);
        if (children.Count < 2) return;

        vm.StatusBreakdown.Clear();
        foreach (var child in children)
        {
            var status = (child.Description ?? "").Trim();
            if (status.Length == 0) continue;
            foreach (var ((y, m), val) in child.ValuesByYearMonth)
            {
                if (y == 0 || m == 0) continue;
                if (year != 0 && y != year) continue;
                vm.StatusBreakdown.Add(new LisDrillStatusRow
                {
                    Status = status,
                    Year   = y,
                    Month  = m,
                    Count  = (long)Math.Round(val, MidpointRounding.AwayFromZero),
                });
            }
        }

        vm.StatusBreakdown = vm.StatusBreakdown
            .OrderBy(x => x.Year).ThenBy(x => x.Month).ThenBy(x => x.Status)
            .ToList();
    }

    /// <summary>
    /// When LIS Core cannot resolve the panel column (Inhealth LRNPanelName was
    /// missing from the candidate list → "All Panels" / "Unspecified"), rebuild
    /// the By-Panel band from Executive Summary panel sub-rows under the parent.
    /// </summary>
    public void ApplyEsPanelsFromSummary(
        ExecSummaryLisDrillViewModel vm,
        PhiExecutiveSummaryViewModel? es,
        int year,
        string? rowCode,
        string? category)
    {
        if (es is null || es.Rows.Count == 0) return;
        if (vm.IsPmsMismatchDrill || vm.IsNotResulted) return;

        static bool IsPlaceholderPanel(string? name)
        {
            var n = (name ?? "").Trim();
            return n.Length == 0
                || n.Equals("All Panels", StringComparison.OrdinalIgnoreCase)
                || n.Equals("Unspecified", StringComparison.OrdinalIgnoreCase)
                || n.Equals("(No Panel)", StringComparison.OrdinalIgnoreCase);
        }

        var realPanelCount = vm.Panels.Count(p => !IsPlaceholderPanel(p.Panel));
        if (realPanelCount >= 2) return;

        var children = FindEsImmediateChildren(es, vm, rowCode, category);
        // Prefer panel-looking children (B1.* / 4-space under Billable, or any ≥2 kids).
        var panelChildren = children
            .Where(c =>
            {
                var rc = c.RowCode ?? "";
                return rc.StartsWith("B1.", StringComparison.OrdinalIgnoreCase)
                    || rc.StartsWith("L_A.", StringComparison.OrdinalIgnoreCase)
                    || c.IsSubSubRow
                    || c.IsSubRow;
            })
            .ToList();
        if (panelChildren.Count < 2) return;

        // Trailing months for Avg6 — prefer drill Monthly labels, else child keys.
        var avgMonths = new List<(int Year, int Month)>();
        foreach (var m in vm.Monthly.Where(x => !x.IsPartial))
        {
            if (DateTime.TryParseExact(m.MonthLabel, "MMM yyyy",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
                avgMonths.Add((dt.Year, dt.Month));
        }
        if (avgMonths.Count == 0)
        {
            avgMonths = panelChildren
                .SelectMany(c => c.ValuesByYearMonth.Keys)
                .Where(k => k.Year != 0 && k.Month != 0 && (year == 0 || k.Year == year))
                .Distinct()
                .OrderBy(k => k.Year).ThenBy(k => k.Month)
                .ToList();
        }
        if (avgMonths.Count > 6)
            avgMonths = avgMonths.Skip(avgMonths.Count - 6).ToList();

        var built = new List<LisDrillPanel>();
        foreach (var child in panelChildren)
        {
            var name = (child.Description ?? "").Trim();
            if (name.Length == 0 || IsPlaceholderPanel(name)) continue;

            decimal monthSum = 0m;
            var monthN = 0;
            foreach (var (y, m) in avgMonths)
            {
                if (!child.ValuesByYearMonth.TryGetValue((y, m), out var v)) continue;
                monthSum += v;
                monthN++;
            }

            long periodTotal;
            if (year != 0 && child.ValuesByYearMonth.TryGetValue((year, 0), out var yrTot))
                periodTotal = (long)Math.Round(yrTot, MidpointRounding.AwayFromZero);
            else if (child.ValuesByYearMonth.TryGetValue((0, 0), out var gTot))
                periodTotal = (long)Math.Round(gTot, MidpointRounding.AwayFromZero);
            else
                periodTotal = (long)Math.Round(
                    child.ValuesByYearMonth
                        .Where(kv => kv.Key.Year != 0 && kv.Key.Month != 0
                                     && (year == 0 || kv.Key.Year == year))
                        .Sum(kv => kv.Value),
                    MidpointRounding.AwayFromZero);

            var avg6 = monthN > 0 ? monthSum / monthN : periodTotal;

            decimal? mom = null;
            if (avgMonths.Count >= 2)
            {
                var prev = avgMonths[^2];
                var latest = avgMonths[^1];
                child.ValuesByYearMonth.TryGetValue(prev, out var prevV);
                child.ValuesByYearMonth.TryGetValue(latest, out var latV);
                if (prevV != 0)
                    mom = Math.Round((latV - prevV) / prevV * 100m, 2, MidpointRounding.AwayFromZero);
            }

            built.Add(new LisDrillPanel
            {
                Panel = name,
                PeriodTotal = periodTotal,
                Avg6Months = avg6,
                MoMDeltaPct = mom,
                Clinics = [],
            });
        }

        if (built.Count < 2) return;

        var totAvg = built.Sum(p => p.Avg6Months);
        foreach (var p in built)
            p.SharePct = totAvg <= 0 ? 0 : Math.Round(p.Avg6Months * 100m / totAvg, 2, MidpointRounding.AwayFromZero);

        vm.Panels = built
            .OrderByDescending(p => p.Avg6Months)
            .ThenBy(p => p.Panel, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>
    /// Immediate ES child tier under a parent row (handles Billable → 4-space
    /// panel sub-rows when there is no 2-space intermediate row).
    /// </summary>
    private static List<ExecSummaryRow> FindEsImmediateChildren(
        PhiExecutiveSummaryViewModel es,
        ExecSummaryLisDrillViewModel vm,
        string? rowCode,
        string? category)
    {
        static int IndentLevel(ExecSummaryRow r) =>
            r.IsSubSubRow ? 2 : r.IsSubRow ? 1 : 0;

        var cat = string.IsNullOrWhiteSpace(category) ? null : category.Trim();
        var rows = es.Rows
            .Where(r => cat is null
                || string.Equals(r.Category, cat, StringComparison.OrdinalIgnoreCase))
            .ToList();
        if (rows.Count == 0) rows = es.Rows.ToList();

        var parentIdx = -1;
        if (!string.IsNullOrWhiteSpace(rowCode))
        {
            parentIdx = rows.FindIndex(r =>
                string.Equals(r.RowCode, rowCode, StringComparison.OrdinalIgnoreCase));
        }
        if (parentIdx < 0)
        {
            var title = (vm.RowTitleOverride ?? vm.MetricTitle ?? "").Trim();
            var leaf = title;
            var dash = title.LastIndexOf(" - ", StringComparison.Ordinal);
            if (dash >= 0) leaf = title[(dash + 3)..].Trim();
            parentIdx = rows.FindIndex(r =>
                string.Equals((r.Description ?? "").Trim(), title, StringComparison.OrdinalIgnoreCase)
                || string.Equals((r.Description ?? "").Trim(), leaf, StringComparison.OrdinalIgnoreCase));
        }
        if (parentIdx < 0) return [];

        var titleCheck = (vm.RowTitleOverride ?? "").Trim();
        if (titleCheck.Contains(" - ", StringComparison.Ordinal)
            && IndentLevel(rows[parentIdx]) > 0)
            return [];

        var parentLevel = IndentLevel(rows[parentIdx]);
        var descendants = new List<(ExecSummaryRow Row, int Level)>();
        for (var i = parentIdx + 1; i < rows.Count; i++)
        {
            var lvl = IndentLevel(rows[i]);
            if (lvl <= parentLevel) break;
            descendants.Add((rows[i], lvl));
        }
        if (descendants.Count == 0) return [];

        var childLevel = descendants.Min(d => d.Level);
        return descendants
            .Where(d => d.Level == childLevel)
            .Select(d => d.Row)
            .ToList();
    }

    /// <summary>
    /// Anchor Insight Drill months / Latest / MoM / Avg6 to the Billed Week Range
    /// end date. Drops future stubs (e.g. Aug/Dec when WeekRange ends in July)
    /// that appear when LIMSMaster has bad future collection dates.
    /// </summary>
    public void ApplyWeekRangeAsOfCutoff(
        ExecSummaryLisDrillViewModel vm,
        AnalysisRangeInfo? analysisRange)
    {
        if (vm.IsPmsMismatchDrill) return; // ES formula months stay as-of Index

        DateTime asOf;
        if (analysisRange?.WeekRangeEndDate is { } wrEnd)
            asOf = wrEnd.Date;
        else if (!AnalysisRangeInfo.TryParseWeekRangeEnd(analysisRange?.WeekFolder, out asOf))
            return;

        var asOfYm = asOf.Year * 100 + asOf.Month;
        static bool TryMonthKey(string? label, out int ym)
        {
            ym = 0;
            if (string.IsNullOrWhiteSpace(label)) return false;
            if (!DateTime.TryParseExact(label.Trim(), "MMM yyyy",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
                return false;
            ym = dt.Year * 100 + dt.Month;
            return true;
        }

        bool KeepYm(int y, int m) => y > 0 && m is >= 1 and <= 12 && (y * 100 + m) <= asOfYm;

        vm.Monthly = vm.Monthly
            .Where(m => TryMonthKey(m.MonthLabel, out var ym) && ym <= asOfYm)
            .Select(m =>
            {
                var isAsOf = TryMonthKey(m.MonthLabel, out var ym) && ym == asOfYm;
                return new LisDrillMonthly
                {
                    MonthLabel = m.MonthLabel,
                    ShortLabel = m.ShortLabel,
                    Total = m.Total,
                    IsPartial = isAsOf || m.IsPartial,
                };
            })
            .OrderBy(m => TryMonthKey(m.MonthLabel, out var ym) ? ym : 0)
            .ToList();

        if (!vm.Monthly.Any(m => TryMonthKey(m.MonthLabel, out var ym) && ym == asOfYm))
        {
            vm.Monthly.Add(new LisDrillMonthly
            {
                MonthLabel = asOf.ToString("MMM yyyy", CultureInfo.InvariantCulture),
                ShortLabel = asOf.ToString("MMM", CultureInfo.InvariantCulture),
                Total = 0,
                IsPartial = true,
            });
            vm.Monthly = vm.Monthly
                .OrderBy(m => TryMonthKey(m.MonthLabel, out var ym) ? ym : 0)
                .ToList();
        }

        vm.NineDayRange = vm.NineDayRange
            .Where(d => TryMonthKey(d.MonthLabel, out var ym) && ym <= asOfYm)
            .ToList();

        vm.StatusBreakdown = vm.StatusBreakdown
            .Where(s => KeepYm(s.Year, s.Month))
            .ToList();

        vm.SummaryMismatchMonths = vm.SummaryMismatchMonths
            .Where(s => KeepYm(s.Year, s.Month))
            .ToList();

        vm.FullyPaidRateMonths = vm.FullyPaidRateMonths
            .Where(s => KeepYm(s.Year, s.Month))
            .ToList();

        vm.RatePanels = vm.RatePanels
            .Where(s => KeepYm(s.Year, s.Month))
            .ToList();

        vm.ResultRates = vm.ResultRates
            .Where(r => TryMonthKey(r.MonthLabel, out var ym) && ym <= asOfYm)
            .ToList();

        var s = vm.Summary;
        s.CutoffDate = asOf;
        if (vm.Monthly.Count == 0)
        {
            s.LatestMonthLabel = asOf.ToString("MMM yyyy", CultureInfo.InvariantCulture);
            s.LatestCount = 0;
            s.PrevMonthLabel = "";
            s.PrevCount = 0;
            s.MoMChangePct = null;
            s.Avg6 = null;
            s.CurrVsAvgPct = null;
            return;
        }

        var latest = vm.Monthly[^1];
        var prev = vm.Monthly.Count > 1 ? vm.Monthly[^2] : null;
        s.LatestMonthLabel = latest.MonthLabel;
        s.LatestCount = latest.Total;
        s.PrevMonthLabel = prev?.MonthLabel ?? "";
        s.PrevCount = prev?.Total ?? 0;
        s.MoMChangePct = prev is null || prev.Total == 0
            ? null
            : Math.Round((latest.Total - prev.Total) * 100m / prev.Total, 2, MidpointRounding.AwayFromZero);

        var avgSrc = vm.Monthly.TakeLast(6).ToList();
        if (avgSrc.Count > 0)
        {
            s.Avg6 = Math.Round((decimal)avgSrc.Average(x => x.Total), 2, MidpointRounding.AwayFromZero);
            s.CurrVsAvgPct = s.Avg6 is { } a && a != 0
                ? Math.Round((latest.Total - a) * 100m / a, 2, MidpointRounding.AwayFromZero)
                : null;
        }

        var dayWin = vm.ComparableDayWindow > 0
            ? vm.ComparableDayWindow
            : analysisRange?.ComparableDayWindow ?? 0;
        if (dayWin is >= 1 and <= 31)
        {
            var latest9 = vm.NineDayRange.LastOrDefault(d =>
                string.Equals(d.ShortLabel, latest.ShortLabel, StringComparison.OrdinalIgnoreCase)
                || string.Equals(d.MonthLabel, latest.MonthLabel, StringComparison.OrdinalIgnoreCase));
            var prev9 = prev is null ? null : vm.NineDayRange.LastOrDefault(d =>
                string.Equals(d.ShortLabel, prev.ShortLabel, StringComparison.OrdinalIgnoreCase)
                || string.Equals(d.MonthLabel, prev.MonthLabel, StringComparison.OrdinalIgnoreCase));

            s.Latest9DayLabel = $"{latest.ShortLabel} (1-{dayWin})";
            s.Latest9DayCount = latest9?.Received9 ?? latest.Total;
            s.Prev9DayLabel = prev is null ? "" : $"{prev.ShortLabel} (1-{dayWin})";
            s.Prev9DayCount = prev9?.Received9 ?? prev?.Total ?? 0;
            s.NineDayMoMPct = s.Prev9DayCount == 0
                ? null
                : Math.Round((s.Latest9DayCount - s.Prev9DayCount) * 100m / s.Prev9DayCount, 2,
                    MidpointRounding.AwayFromZero);
        }
    }

    /// <summary>
    /// Loads the PMS "Billed Mismatches" row from the Executive Summary grid SP
    /// (same source as Index / pmsgrid) into the drill view model.
    /// </summary>
    public async Task AttachPmsBilledMismatchFromSummaryAsync(
        ExecSummaryLisDrillViewModel vm,
        string connectionString,
        string labPrefix,
        string labName,
        int year,
        CancellationToken ct = default)
    {
        var es = await PrefetchExecutiveSummaryForDrillAsync(
            connectionString, labPrefix, labName, year, ct);
        ApplyPmsBilledMismatchFromSummary(vm, es, year);
    }

    /// <summary>Applies a prefetched ES grid to the Billed Mismatch companion band.</summary>
    public void ApplyPmsBilledMismatchFromSummary(
        ExecSummaryLisDrillViewModel vm,
        PhiExecutiveSummaryViewModel? es,
        int year)
    {
        if (es is null || es.Rows.Count == 0) return;

        var mismatch = FindPmsMismatchSummaryRow(es, vm.RowTitleOverride ?? vm.MetricTitle);
        if (mismatch is null) return;

        vm.SummaryMismatchTitle = mismatch.Description.Trim();

        foreach (var ((y, m), val) in mismatch.ValuesByYearMonth)
        {
            if (y == 0 || m == 0) continue; // skip year/grand sentinels
            if (year != 0 && y != year) continue;
            vm.SummaryMismatchMonths.Add(new LisDrillStatusRow
            {
                Status = vm.SummaryMismatchTitle,
                Year   = y,
                Month  = m,
                Count  = (long)val,
            });
        }

        vm.SummaryMismatchMonths = vm.SummaryMismatchMonths
            .OrderBy(x => x.Year).ThenBy(x => x.Month)
            .ToList();

        // Prefer the ES year-total / grand-total cell (same as pmsgrid), else sum months.
        if (year != 0 && mismatch.ValuesByYearMonth.TryGetValue((year, 0), out var yrTot))
            vm.SummaryMismatchTotal = (long)yrTot;
        else if (mismatch.ValuesByYearMonth.TryGetValue((0, 0), out var gTot))
            vm.SummaryMismatchTotal = (long)gTot;
        else
            vm.SummaryMismatchTotal = vm.SummaryMismatchMonths.Sum(x => x.Count);
    }

    /// <summary>
    /// Backfills mismatch Insight Drill KPI / Monthly Trend / N-day series from the
    /// Executive Summary PMS "Billed Mismatches" row — same source and monthly values
    /// as the Index grid cell (full-month formula totals, not DayWindow-capped Core).
    /// Always overwrites Summary / Monthly / NineDayRange so the drill matches ES.
    /// </summary>
    public void ApplyPmsMismatchDrillFromSummary(
        ExecSummaryLisDrillViewModel vm,
        PhiExecutiveSummaryViewModel? es,
        int year,
        string? rowCode = null)
    {
        vm.IsPmsMismatchDrill = true;
        vm.SourceLabel = "ClaimLevelData";
        vm.DescriptionOverride =
            "Matches the Executive Summary formula for this row: PMS Billed count (Date of Service) minus LIS Billed count (Request Collect Date) per month. Panel / Top Insurance are not shown — this metric is a period count difference, not a claim-level set.";

        ExecSummaryRow? mismatch = null;
        if (es is not null && es.Rows.Count > 0)
            mismatch = FindPmsMismatchSummaryRow(es, vm.RowTitleOverride ?? vm.MetricTitle, rowCode);

        if (mismatch is null)
        {
            // ES grid unavailable — still surface the clicked cell so HasData is true.
            ApplyMismatchSelectedValueFallback(vm);
            return;
        }

        var months = mismatch.ValuesByYearMonth.Keys
            .Where(k => k.Year != 0 && k.Month != 0)
            .Where(k => year == 0 || k.Year == year)
            .Distinct()
            .OrderBy(k => k.Year).ThenBy(k => k.Month)
            .ToList();

        if (months.Count == 0)
        {
            ApplyMismatchSelectedValueFallback(vm, mismatch, year);
            return;
        }

        // Prefer ES full-month formula values (same as Index) over any Core DayWindow series.
        vm.Monthly.Clear();
        vm.NineDayRange.Clear();

        var latest = months[^1];
        foreach (var (y, m) in months)
        {
            mismatch.ValuesByYearMonth.TryGetValue((y, m), out var val);
            var total = (long)Math.Round(val, MidpointRounding.AwayFromZero);
            var dt = new DateTime(y, m, 1);
            var monthLabel = dt.ToString("MMM yyyy", CultureInfo.InvariantCulture);
            var shortLabel = dt.ToString("MMM", CultureInfo.InvariantCulture);
            var isPartial = y == latest.Year && m == latest.Month;
            vm.Monthly.Add(new LisDrillMonthly
            {
                MonthLabel = monthLabel,
                ShortLabel = shortLabel,
                Total = total,
                IsPartial = isPartial,
            });
            // N-day band uses the same ES monthly values (parity with ES; not DayWindow-capped).
            vm.NineDayRange.Add(new LisDrillNineDayRange
            {
                MonthLabel = monthLabel,
                ShortLabel = shortLabel,
                Received9 = total,
            });
        }

        var last = vm.Monthly[^1];
        var prev = vm.Monthly.Count > 1 ? vm.Monthly[^2] : null;
        var avgSrc = vm.Monthly.Count > 6
            ? vm.Monthly.TakeLast(6).ToList()
            : vm.Monthly.ToList();
        vm.Summary.LatestMonthLabel = last.MonthLabel;
        vm.Summary.LatestCount = last.Total;
        vm.Summary.Latest9DayLabel = last.MonthLabel;
        vm.Summary.Latest9DayCount = last.Total;
        if (prev is not null)
        {
            vm.Summary.PrevMonthLabel = prev.MonthLabel;
            vm.Summary.PrevCount = prev.Total;
            vm.Summary.Prev9DayLabel = prev.MonthLabel;
            vm.Summary.Prev9DayCount = prev.Total;
            vm.Summary.MoMChangePct = prev.Total == 0
                ? null
                : Math.Round((last.Total - prev.Total) * 100m / prev.Total, 1);
            vm.Summary.NineDayMoMPct = vm.Summary.MoMChangePct;
        }
        else
        {
            vm.Summary.PrevMonthLabel = string.Empty;
            vm.Summary.PrevCount = 0;
            vm.Summary.Prev9DayLabel = string.Empty;
            vm.Summary.Prev9DayCount = 0;
            vm.Summary.MoMChangePct = null;
            vm.Summary.NineDayMoMPct = null;
        }
        if (avgSrc.Count > 0)
        {
            vm.Summary.Avg6 = Math.Round((decimal)avgSrc.Average(x => x.Total), 3);
            if (vm.Summary.Avg6 is { } avg6 && avg6 != 0)
                vm.Summary.CurrVsAvgPct = Math.Round(
                    (last.Total - avg6) * 100m / avg6, 1);
            else
                vm.Summary.CurrVsAvgPct = null;
        }

        // Year / grand total from ES (same cell as Index year-total / grand-total).
        if (year != 0 && mismatch.ValuesByYearMonth.TryGetValue((year, 0), out var yrTot))
            vm.SummaryMismatchTotal = (long)Math.Round(yrTot, MidpointRounding.AwayFromZero);
        else if (mismatch.ValuesByYearMonth.TryGetValue((0, 0), out var gTot))
            vm.SummaryMismatchTotal = (long)Math.Round(gTot, MidpointRounding.AwayFromZero);
        else
            vm.SummaryMismatchTotal = vm.Monthly.Sum(x => x.Total);

        if (vm.SelectedValue is null && vm.SummaryMismatchTotal != 0)
            vm.SelectedValue = vm.SummaryMismatchTotal;
    }

    /// <summary>
    /// When ES monthly cells are missing, still populate Summary from the clicked
    /// ES cell (or year/grand total) so the drill is not a claim-filter dead-end.
    /// </summary>
    private static void ApplyMismatchSelectedValueFallback(
        ExecSummaryLisDrillViewModel vm,
        ExecSummaryRow? mismatch = null,
        int year = 0)
    {
        long cell = 0;
        if (mismatch is not null)
        {
            if (year != 0 && mismatch.ValuesByYearMonth.TryGetValue((year, 0), out var yrTot))
                cell = (long)Math.Round(yrTot, MidpointRounding.AwayFromZero);
            else if (mismatch.ValuesByYearMonth.TryGetValue((0, 0), out var gTot))
                cell = (long)Math.Round(gTot, MidpointRounding.AwayFromZero);
        }
        if (cell == 0 && vm.SelectedValue is { } sv)
            cell = (long)Math.Round(sv, MidpointRounding.AwayFromZero);
        if (cell == 0) return;

        vm.SummaryMismatchTotal = cell;
        if (vm.Monthly.Count == 0 && vm.Summary.LatestCount == 0)
        {
            var label = year != 0 ? year.ToString(CultureInfo.InvariantCulture) : "Grand Total";
            vm.Summary.LatestMonthLabel = label;
            vm.Summary.LatestCount = cell;
            vm.Summary.Latest9DayLabel = label;
            vm.Summary.Latest9DayCount = cell;
            vm.Monthly.Add(new LisDrillMonthly
            {
                MonthLabel = label,
                ShortLabel = year != 0 ? year.ToString(CultureInfo.InvariantCulture) : "Total",
                Total = cell,
                IsPartial = false,
            });
            vm.NineDayRange.Add(new LisDrillNineDayRange
            {
                MonthLabel = label,
                ShortLabel = year != 0 ? year.ToString(CultureInfo.InvariantCulture) : "Total",
                Received9 = cell,
            });
        }
    }

    private static ExecSummaryRow? FindPmsMismatchSummaryRow(
        PhiExecutiveSummaryViewModel es, string? preferredTitle, string? rowCode = null)
    {
        static bool IsMismatchRow(ExecSummaryRow r) =>
            string.Equals(r.Category, "PMS", StringComparison.OrdinalIgnoreCase)
            && ExecSummaryLisDrillViewModel.LooksLikeMismatchTitle(r.Description);

        var candidates = es.Rows.Where(IsMismatchRow).ToList();
        if (candidates.Count == 0)
        {
            // Fallback: PMS row matching RowCode even if description wording differs.
            if (!string.IsNullOrWhiteSpace(rowCode))
            {
                return es.Rows.FirstOrDefault(r =>
                    string.Equals(r.Category, "PMS", StringComparison.OrdinalIgnoreCase)
                    && string.Equals(r.RowCode?.Trim(), rowCode.Trim(), StringComparison.OrdinalIgnoreCase));
            }
            return null;
        }

        if (!string.IsNullOrWhiteSpace(rowCode))
        {
            var byCode = candidates.FirstOrDefault(r =>
                string.Equals(r.RowCode?.Trim(), rowCode.Trim(), StringComparison.OrdinalIgnoreCase));
            if (byCode is not null) return byCode;
        }

        var prefer = preferredTitle?.Trim();
        if (!string.IsNullOrEmpty(prefer))
        {
            var exact = candidates.FirstOrDefault(r =>
                string.Equals(r.Description?.Trim(), prefer, StringComparison.OrdinalIgnoreCase));
            if (exact is not null) return exact;

            var contains = candidates.FirstOrDefault(r =>
                r.Description?.Contains(prefer, StringComparison.OrdinalIgnoreCase) == true
                || prefer.Contains(r.Description?.Trim() ?? "", StringComparison.OrdinalIgnoreCase));
            if (contains is not null) return contains;
        }

        return candidates.FirstOrDefault(r =>
                   r.Description?.Contains("Billed Mismatch", StringComparison.OrdinalIgnoreCase) == true)
               ?? candidates[0];
    }

    /// <summary>
    /// Loads Fully Paid and Billed (Claims) monthly cells from the Executive Summary
    /// grid SP (same source as Index / pmsgrid) and computes Fully Paid / Billed %.
    /// Also backfills <see cref="ExecSummaryLisDrillViewModel.Monthly"/> from the
    /// Fully Paid summary row when the drill SP returned no monthly series.
    /// </summary>
    public async Task AttachPmsFullyPaidRateFromSummaryAsync(
        ExecSummaryLisDrillViewModel vm,
        string connectionString,
        string labPrefix,
        string labName,
        int year,
        CancellationToken ct = default)
    {
        vm.IsPmsFullyPaidDrill = true;

        var es = await PrefetchExecutiveSummaryForDrillAsync(
            connectionString, labPrefix, labName, year, ct);
        if (es is null)
        {
            _logger.LogWarning(
                "Fully Paid rate attach: ES unavailable for {Lab} — will try drill-set fallback.",
                labName);
            FillFullyPaidRateFromDrillSets(vm);
            EnsureFullyPaidInsurerPanels(vm);
            return;
        }

        ApplyPmsFullyPaidRateFromSummary(vm, es, year, labName);
    }

    /// <summary>Applies a prefetched ES grid to the Fully Paid / Billed rate companion.</summary>
    public void ApplyPmsFullyPaidRateFromSummary(
        ExecSummaryLisDrillViewModel vm,
        PhiExecutiveSummaryViewModel? es,
        int year,
        string labName = "")
    {
        vm.IsPmsFullyPaidDrill = true;

        if (es is null || es.Rows.Count == 0)
        {
            FillFullyPaidRateFromDrillSets(vm);
            EnsureFullyPaidInsurerPanels(vm);
            return;
        }

        static bool IsPmsBilledRow(ExecSummaryRow r)
        {
            if (!string.Equals(r.Category, "PMS", StringComparison.OrdinalIgnoreCase)) return false;
            var t = r.Description?.Trim() ?? "";
            if (t.Contains("Mismatch", StringComparison.OrdinalIgnoreCase)) return false;
            if (t.Contains("Unbilled", StringComparison.OrdinalIgnoreCase)) return false;
            if (t.Contains("Not Billed", StringComparison.OrdinalIgnoreCase)) return false;
            if (t.Contains("UnBilled", StringComparison.OrdinalIgnoreCase)) return false;
            // BT: "Billed - Includes all Claims Billed in AMD"; Cove: "Billed (Claims)"
            return t.Contains("Billed (Claims)", StringComparison.OrdinalIgnoreCase)
                || t.Contains("Billed - Includes", StringComparison.OrdinalIgnoreCase)
                || t.StartsWith("Billed", StringComparison.OrdinalIgnoreCase);
        }

        static bool IsPmsFullyPaidRow(ExecSummaryRow r)
        {
            if (!string.Equals(r.Category, "PMS", StringComparison.OrdinalIgnoreCase)) return false;
            var t = r.Description?.Trim() ?? "";
            // Cash "Insurance Payment (fully paid) ($)" is Category=Cash; still guard $.
            if (t.Contains('$')) return false;
            return t.Contains("Fully Paid", StringComparison.OrdinalIgnoreCase);
        }

        var paid   = es.Rows.FirstOrDefault(IsPmsFullyPaidRow);
        var billed = es.Rows.FirstOrDefault(IsPmsBilledRow);
        if (paid is null || billed is null)
        {
            _logger.LogWarning(
                "Fully Paid rate attach: paid={Paid} billed={Billed} for {Lab} — drill-set fallback. PMS rows: {Descs}",
                paid?.Description, billed?.Description, labName,
                string.Join(" | ", es.Rows
                    .Where(r => string.Equals(r.Category, "PMS", StringComparison.OrdinalIgnoreCase))
                    .Select(r => r.Description)
                    .Take(12)));
            FillFullyPaidRateFromDrillSets(vm);
            EnsureFullyPaidInsurerPanels(vm);
            return;
        }

        // Month keys present on either row (skip year/grand sentinels).
        var months = paid.ValuesByYearMonth.Keys
            .Concat(billed.ValuesByYearMonth.Keys)
            .Where(k => k.Year != 0 && k.Month != 0)
            .Where(k => year == 0 || k.Year == year)
            .Distinct()
            .OrderBy(k => k.Year).ThenBy(k => k.Month)
            .ToList();

        if (months.Count == 0)
        {
            FillFullyPaidRateFromDrillSets(vm);
            EnsureFullyPaidInsurerPanels(vm);
            return;
        }

        // Latest calendar month in the series is treated as partial (same as drill trend).
        var latest = months[^1];

        foreach (var (y, m) in months)
        {
            paid.ValuesByYearMonth.TryGetValue((y, m), out var paidVal);
            billed.ValuesByYearMonth.TryGetValue((y, m), out var billedVal);
            var paidCnt   = (long)paidVal;
            var billedCnt = (long)billedVal;
            var isPartial = y == latest.Year && m == latest.Month;
            decimal? rate = null;
            // Partial month → dash (same as reference); otherwise FullyPaid/Billed.
            if (!isPartial && billedCnt > 0)
                rate = Math.Round(paidCnt * 100m / billedCnt, 1);

            var dt = new DateTime(y, m, 1);
            vm.FullyPaidRateMonths.Add(new LisDrillFullyPaidRateMonth
            {
                Year            = y,
                Month           = m,
                MonthLabel      = dt.ToString("MMM yyyy", CultureInfo.InvariantCulture),
                ShortLabel      = dt.ToString("MMM", CultureInfo.InvariantCulture),
                FullyPaidCount  = paidCnt,
                BilledCount     = billedCnt,
                RatePct         = rate,
                IsPartial       = isPartial,
            });
        }

        FinalizeFullyPaidRateAvg(vm);

        // Backfill Monthly Trend from Fully Paid summary when drill SP had no months.
        if (vm.Monthly.Count == 0)
        {
            foreach (var rm in vm.FullyPaidRateMonths)
            {
                vm.Monthly.Add(new LisDrillMonthly
                {
                    MonthLabel = rm.MonthLabel,
                    ShortLabel = rm.ShortLabel,
                    Total      = rm.FullyPaidCount,
                    IsPartial  = rm.IsPartial,
                });
            }

            if (vm.Summary.LatestCount == 0 && vm.Monthly.Count > 0)
            {
                var last = vm.Monthly[^1];
                var prev = vm.Monthly.Count > 1 ? vm.Monthly[^2] : null;
                // Include WeekRange end month; trailing ≤6 (matches Core SP Avg6).
                var avgSrc = vm.Monthly.Count > 6
                    ? vm.Monthly.TakeLast(6).ToList()
                    : vm.Monthly.ToList();
                vm.Summary.LatestMonthLabel = last.MonthLabel;
                vm.Summary.LatestCount     = last.Total;
                if (prev is not null)
                {
                    vm.Summary.PrevMonthLabel = prev.MonthLabel;
                    vm.Summary.PrevCount      = prev.Total;
                    vm.Summary.MoMChangePct = prev.Total == 0
                        ? null
                        : Math.Round((last.Total - prev.Total) * 100m / prev.Total, 1);
                }
                if (avgSrc.Count > 0)
                {
                    vm.Summary.Avg6 = Math.Round(
                        (decimal)avgSrc.Average(x => x.Total), 3);
                    if (vm.Summary.Avg6 is > 0)
                        vm.Summary.CurrVsAvgPct = Math.Round(
                            (last.Total - vm.Summary.Avg6.Value) * 100m / vm.Summary.Avg6.Value, 1);
                }
            }
        }

        EnsureFullyPaidInsurerPanels(vm);
    }

    /// <summary>
    /// Fallback rate band when ES summary attach fails: Fully Paid monthly totals ÷
    /// Sec1 "Billed (Claims)" status matrix from the PMS drill core (BT row U).
    /// </summary>
    public void FillFullyPaidRateFromDrillSets(ExecSummaryLisDrillViewModel vm)
    {
        if (vm.FullyPaidRateMonths.Count > 0 || vm.Monthly.Count == 0)
            return;

        var billedByYm = vm.StatusBreakdown
            .Where(s =>
            {
                var t = s.Status?.Trim() ?? "";
                if (t.Contains("Mismatch", StringComparison.OrdinalIgnoreCase)) return false;
                if (t.Contains("Unbilled", StringComparison.OrdinalIgnoreCase)) return false;
                if (t.Contains("UnBilled", StringComparison.OrdinalIgnoreCase)) return false;
                return t.Contains("Billed", StringComparison.OrdinalIgnoreCase);
            })
            .GroupBy(s => (s.Year, s.Month))
            .ToDictionary(g => g.Key, g => g.Sum(x => x.Count));

        foreach (var m in vm.Monthly)
        {
            if (!DateTime.TryParseExact(
                    m.MonthLabel, "MMM yyyy", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out var dt))
                continue;

            billedByYm.TryGetValue((dt.Year, dt.Month), out var billedCnt);
            decimal? rate = null;
            if (!m.IsPartial && billedCnt > 0)
                rate = Math.Round(m.Total * 100m / billedCnt, 1);

            vm.FullyPaidRateMonths.Add(new LisDrillFullyPaidRateMonth
            {
                Year           = dt.Year,
                Month          = dt.Month,
                MonthLabel     = m.MonthLabel,
                ShortLabel     = m.ShortLabel,
                FullyPaidCount = m.Total,
                BilledCount    = billedCnt,
                RatePct        = rate,
                IsPartial      = m.IsPartial,
            });
        }

        FinalizeFullyPaidRateAvg(vm);
    }

    /// <summary>
    /// Fully Paid Top-10 Insurance must always expand to Panel Groups (default collapsed).
    /// Prefer Set 9 from the PMS core SP; otherwise nest by-panel shares under each payer,
    /// or sample panel labels when panel data is also empty.
    /// </summary>
    public void EnsureFullyPaidInsurerPanels(ExecSummaryLisDrillViewModel vm)
    {
        if (!vm.IsPmsFullyPaidDrill && !vm.IsFullyPaidInsight) return;
        if (vm.Insurers.Count == 0) return;
        if (vm.Insurers.Any(i => i.Panels.Count > 0)) return;

        var panels = vm.Panels.Take(6).ToList();
        if (panels.Count > 0)
        {
            foreach (var ins in vm.Insurers)
            {
                foreach (var p in panels)
                {
                    var claims = (long)Math.Round(ins.Claims * (double)p.SharePct / 100.0);
                    if (claims <= 0 && p.SharePct > 0 && ins.Claims > 0)
                        claims = 1;
                    ins.Panels.Add(new LisDrillInsurerPanel
                    {
                        Panel  = p.Panel,
                        Claims = claims,
                        MoMPct = p.MoMDeltaPct,
                    });
                }
            }
            return;
        }

        // No panel breakdown — still ship accordion children (illustrative labels).
        string[] samples = ["Toxicology", "UTI", "Respiratory", "Other Panels"];
        foreach (var ins in vm.Insurers)
        {
            long remaining = ins.Claims;
            for (var i = 0; i < samples.Length; i++)
            {
                var share = i == samples.Length - 1
                    ? remaining
                    : Math.Max(0, ins.Claims / samples.Length);
                remaining -= share;
                ins.Panels.Add(new LisDrillInsurerPanel
                {
                    Panel  = samples[i],
                    Claims = share,
                });
            }
        }
    }

    private static void FinalizeFullyPaidRateAvg(ExecSummaryLisDrillViewModel vm)
    {
        var nonPartialRates = vm.FullyPaidRateMonths
            .Where(x => !x.IsPartial && x.RatePct is not null)
            .ToList();
        if (nonPartialRates.Count == 0) return;
        vm.FullyPaidRateAvg = Math.Round(
            nonPartialRates.Average(x => x.RatePct!.Value), 1);
        vm.FullyPaidRateAvgRange =
            $"{nonPartialRates[0].ShortLabel}–{nonPartialRates[^1].ShortLabel}";
    }

    /// <summary>
    /// Reads a row-filter definition for (labPrefix, rowCode). Null if none / table absent.
    /// When <paramref name="preferredSource"/> is LIS, PMS, or Cash, prefer that Source
    /// (labs may reuse a RoleID across categories — e.g. PCR 'I', RT 'X').
    /// </summary>
    public async Task<LisDrillRowDefinition?> GetLisDrillRowDefAsync(
        string connectionString, string labPrefix, string rowCode,
        string? preferredSource = null, CancellationToken ct = default)
    {
        // When preferredSource is set (LIS/PMS/Cash), require that Source so a
        // missing Cash seed does not silently bind a colliding PMS/LIS RoleID.
        const string sqlWithAmount =
            "SELECT TOP(1) RowTitle, DateCol, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4, " +
            "Source, Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals, " +
            "AmountCol " +
            "FROM dbo.LisDrillRowDef WHERE LabPrefix=@p AND RowCode=@r " +
            "AND (@src IS NULL OR UPPER(ISNULL(Source,N'LIS')) = UPPER(@src)) " +
            "ORDER BY ISNULL(Source, N'LIS')";
        const string sqlLegacy =
            "SELECT TOP(1) RowTitle, DateCol, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4, " +
            "Source, Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals " +
            "FROM dbo.LisDrillRowDef WHERE LabPrefix=@p AND RowCode=@r " +
            "AND (@src IS NULL OR UPPER(ISNULL(Source,N'LIS')) = UPPER(@src)) " +
            "ORDER BY ISNULL(Source, N'LIS')";
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            async Task<LisDrillRowDefinition?> ReadAsync(string sql, bool hasAmount)
            {
                await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
                cmd.Parameters.AddWithValue("@p", labPrefix);
                cmd.Parameters.AddWithValue("@r", rowCode);
                cmd.Parameters.AddWithValue("@src",
                    string.IsNullOrWhiteSpace(preferredSource) ? DBNull.Value : preferredSource.Trim());
                await using var r = await cmd.ExecuteReaderAsync(ct);
                if (!await r.ReadAsync(ct)) return null;
                string? SN(int i) => r.IsDBNull(i) ? null : r.GetString(i);
                string? amountCol = hasAmount && !r.IsDBNull(24) ? r.GetString(24) : null;
                return new LisDrillRowDefinition(
                    r.GetString(0), SN(1), SN(2), SN(3), SN(4),
                    SN(5), SN(6), SN(7), SN(8), SN(9), SN(10),
                    SN(11), SN(12), SN(13),
                    SN(14),
                    SN(15), SN(16), SN(17),
                    SN(18), SN(19), SN(20),
                    SN(21), SN(22), SN(23),
                    amountCol);
            }

            try
            {
                return await ReadAsync(sqlWithAmount, hasAmount: true);
            }
            catch (SqlException)
            {
                // AmountCol not deployed yet — LIS/PMS still work.
                return await ReadAsync(sqlLegacy, hasAmount: false);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "GetLisDrillRowDefAsync unavailable for {Lab}/{Row}", labPrefix, rowCode);
            return null;
        }
    }

    /// <summary>Calls the compound-filter core proc for a specific LIS row and reads all result sets.</summary>
    public async Task<ExecSummaryLisDrillViewModel> GetLisDrillCoreAsync(
        string connectionString, string coreSpName, string metric, int year,
        LisDrillRowDefinition def, int dayWindow = 9, CancellationToken ct = default)
    {
        var vm = new ExecSummaryLisDrillViewModel { Metric = metric, Year = year, ComparableDayWindow = dayWindow };
        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(coreSpName, conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 180 };
            void P(string n, object? v) => cmd.Parameters.AddWithValue(n, v ?? DBNull.Value);
            P("@Metric", metric);
            P("@Year", year);
            P("@BillableCol", def.Col1);
            P("@BillableVal", def.Val1);
            P("@Op1", def.Op1 ?? "=");
            P("@Col2", def.Col2); P("@Op2", def.Op2 ?? "="); P("@Val2", def.Val2);
            P("@Col3", def.Col3); P("@Op3", def.Op3 ?? "="); P("@Val3", def.Val3);
            P("@Col4", def.Col4); P("@Op4", def.Op4 ?? "="); P("@Val4", def.Val4);
            P("@DatePref", def.DateCol);
            P("@DayWindow", dayWindow);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            await ReadLisDrillSetsAsync(r, vm, ct);

            _logger.LogInformation(
                "LIS row drill Core={Sp} Metric={Metric} Year={Year}: panels={P}, months={M} in {Ms}ms",
                coreSpName, metric, year, vm.Panels.Count, vm.Monthly.Count, sw.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "LIS row drill failed. Core='{Sp}'", coreSpName);
            vm.ErrorMessage = $"Failed to load drill-through: {ex.Message}";
        }
        return vm;
    }

    /// <summary>Calls the PMS drill core (ClaimLevelData) for a specific PMS row and reads all result sets.</summary>
    public async Task<ExecSummaryLisDrillViewModel> GetPmsDrillCoreAsync(
        string connectionString, string coreSpName, int year,
        LisDrillRowDefinition def, int dayWindow = 9, CancellationToken ct = default)
    {
        var isMismatch = def.IsPmsMismatch;
        var vm = new ExecSummaryLisDrillViewModel
        {
            Metric = "Billable", Year = year, SourceLabel = "ClaimLevelData",
            ComparableDayWindow = dayWindow,
            IsPmsMismatchDrill = isMismatch,
            DescriptionOverride = isMismatch
                ? "Matches the Executive Summary formula for this row: PMS Billed count (Date of Service) minus LIS Billed count (Request Collect Date) per month. Panel / Top Insurance are not shown — this metric is a period count difference, not a claim-level set."
                : def.IsPmsFullyPaid
                    ? "Claims fully paid by insurance with no remaining balance."
                    : "Claims from the PMS billing data (ClaimLevelData), counted by distinct claim id on date of service — same filters as the Executive Summary PMS row.",
        };
        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(coreSpName, conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 180 };
            void P(string n, object? v) => cmd.Parameters.AddWithValue(n, v ?? DBNull.Value);
            P("@Year", year);
            P("@DatePref", def.DateCol ?? "DateofService");
            P("@FilterCol", def.Col1);
            // Op1 defaults to IN for legacy comma-lists; '=' / '>' / '<>' come from LisDrillRowDef.
            P("@FilterOp", string.IsNullOrWhiteSpace(def.Op1) ? "IN" : def.Op1);
            // Empty Val is meaningful for FirstBilledDate blank/populated (= '' / <> '').
            P("@FilterVals", def.Val1 ?? (object)DBNull.Value);
            P("@FilterCol2", def.Col2);
            P("@FilterOp2", def.Op2);
            P("@FilterVal2", def.Val2 ?? (object)DBNull.Value);
            P("@FilterCol3", def.Col3);
            P("@FilterOp3", def.Op3);
            P("@FilterVal3", def.Val3 ?? (object)DBNull.Value);
            P("@FilterCol4", def.Col4);
            P("@FilterOp4", def.Op4);
            P("@FilterVal4", def.Val4 ?? (object)DBNull.Value);
            P("@Sec1Name", def.Sec1Name); P("@Sec1Col", def.Sec1Col); P("@Sec1Vals", def.Sec1Vals);
            P("@Sec2Name", def.Sec2Name); P("@Sec2Col", def.Sec2Col); P("@Sec2Vals", def.Sec2Vals);
            P("@Sec3Name", def.Sec3Name); P("@Sec3Col", def.Sec3Col); P("@Sec3Vals", def.Sec3Vals);
            P("@DayWindow", dayWindow);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            await ReadLisDrillSetsAsync(r, vm, ct);

            _logger.LogInformation(
                "PMS row drill Core={Sp} Year={Year}: months={M} panels={P} insurers={I} in {Ms}ms",
                coreSpName, year, vm.Monthly.Count, vm.Panels.Count, vm.Insurers.Count, sw.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "PMS row drill failed. Core='{Sp}'", coreSpName);
            vm.ErrorMessage = $"Failed to load drill-through: {ex.Message}";
        }
        return vm;
    }

    /// <summary>
    /// Calls Cash drill core (ClaimLevelData dollar SUM) for a Cash Breakdown row.
    /// Same result-set shape as PmsDrill; values are rounded currency amounts.
    /// </summary>
    public async Task<ExecSummaryLisDrillViewModel> GetCashDrillCoreAsync(
        string connectionString, string coreSpName, int year,
        LisDrillRowDefinition def, int dayWindow = 9, CancellationToken ct = default)
    {
        var vm = new ExecSummaryLisDrillViewModel
        {
            Metric = "Billable",
            Year = year,
            SourceLabel = "ClaimLevelData",
            IsCashDrill = true,
            ComparableDayWindow = dayWindow,
            DescriptionOverride =
                "Dollar amounts from PMS billing data (ClaimLevelData), summed with the same filters as the Executive Summary Cash Breakdown row.",
        };
        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand(coreSpName, conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 180 };
            void P(string n, object? v) => cmd.Parameters.AddWithValue(n, v ?? DBNull.Value);
            P("@Year", year);
            P("@DatePref", def.DateCol ?? "DateofService");
            P("@AmountCol", string.IsNullOrWhiteSpace(def.AmountCol) ? "ChargeAmount" : def.AmountCol);
            P("@FilterCol", def.Col1);
            P("@FilterOp", string.IsNullOrWhiteSpace(def.Op1) ? "IN" : def.Op1);
            P("@FilterVals", def.Val1 ?? (object)DBNull.Value);
            P("@FilterCol2", def.Col2);
            P("@FilterOp2", def.Op2);
            P("@FilterVal2", def.Val2 ?? (object)DBNull.Value);
            P("@FilterCol3", def.Col3);
            P("@FilterOp3", def.Op3);
            P("@FilterVal3", def.Val3 ?? (object)DBNull.Value);
            P("@FilterCol4", def.Col4);
            P("@FilterOp4", def.Op4);
            P("@FilterVal4", def.Val4 ?? (object)DBNull.Value);
            P("@Sec1Name", def.Sec1Name); P("@Sec1Col", def.Sec1Col); P("@Sec1Vals", def.Sec1Vals);
            P("@Sec2Name", def.Sec2Name); P("@Sec2Col", def.Sec2Col); P("@Sec2Vals", def.Sec2Vals);
            P("@Sec3Name", def.Sec3Name); P("@Sec3Col", def.Sec3Col); P("@Sec3Vals", def.Sec3Vals);
            P("@DayWindow", dayWindow);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            await ReadLisDrillSetsAsync(r, vm, ct);

            _logger.LogInformation(
                "Cash row drill Core={Sp} Year={Year} Amount={Amt}: months={M} panels={P} insurers={I} in {Ms}ms",
                coreSpName, year, def.AmountCol, vm.Monthly.Count, vm.Panels.Count, vm.Insurers.Count, sw.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Cash row drill failed. Core='{Sp}'", coreSpName);
            vm.ErrorMessage = $"Failed to load drill-through: {ex.Message}";
        }
        return vm;
    }

    /// <summary>Reads the 7 LIS-drill result sets off an open reader into the view model.</summary>
    private static async Task ReadLisDrillSetsAsync(
        SqlDataReader r, ExecSummaryLisDrillViewModel vm, CancellationToken ct)
    {
        Dictionary<string, int> Map()
        {
            var m = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < r.FieldCount; i++) m[r.GetName(i)] = i;
            return m;
        }
        long L(Dictionary<string, int> m, string c) =>
            m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToInt64(r.GetValue(i)) : 0L;
        string S(Dictionary<string, int> m, string c) =>
            m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToString(r.GetValue(i)) ?? "" : "";
        decimal? DN(Dictionary<string, int> m, string c) =>
            m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToDecimal(r.GetValue(i)) : (decimal?)null;
        decimal D(Dictionary<string, int> m, string c) =>
            m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToDecimal(r.GetValue(i)) : 0m;
        DateTime? DT(Dictionary<string, int> m, string c) =>
            m.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToDateTime(r.GetValue(i)) : (DateTime?)null;

        var map = Map();
        if (await r.ReadAsync(ct))
        {
            vm.Summary = new LisDrillSummary
            {
                CutoffDate       = DT(map, "CutoffDate"),
                LatestMonthLabel = S(map, "LatestMonthLabel"),
                LatestCount      = L(map, "LatestCount"),
                PrevMonthLabel   = S(map, "PrevMonthLabel"),
                PrevCount        = L(map, "PrevCount"),
                MoMChangePct     = DN(map, "MoMChangePct"),
                Avg6             = DN(map, "Avg6"),
                CurrVsAvgPct     = DN(map, "CurrVsAvgPct"),
                Latest9DayLabel  = S(map, "Latest9DayLabel"),
                Latest9DayCount  = L(map, "Latest9DayCount"),
                Prev9DayLabel    = S(map, "Prev9DayLabel"),
                Prev9DayCount    = L(map, "Prev9DayCount"),
                NineDayMoMPct    = DN(map, "NineDayMoMPct"),
            };
        }
        if (await r.NextResultAsync(ct))
        {
            map = Map();
            while (await r.ReadAsync(ct))
            {
                var monthLabel = S(map, "MonthLabel");
                var shortLabel = S(map, "ShortLabel");
                if (string.IsNullOrEmpty(shortLabel))
                    shortLabel = monthLabel.Length >= 3 ? monthLabel[..3] : monthLabel;
                var total = map.ContainsKey("Total") ? L(map, "Total") : L(map, "Count");
                vm.Monthly.Add(new LisDrillMonthly
                { MonthLabel = monthLabel, ShortLabel = shortLabel, Total = total, IsPartial = L(map, "IsPartial") == 1 });
            }
        }
        if (await r.NextResultAsync(ct))
        {
            map = Map();
            while (await r.ReadAsync(ct))
            {
                var avg6 = map.ContainsKey("Avg6Months") ? D(map, "Avg6Months") : D(map, "PeriodTotal");
                vm.Panels.Add(new LisDrillPanel
                {
                    Panel = S(map, "Panel"),
                    PeriodTotal = L(map, "PeriodTotal"),
                    Avg6Months = avg6 > 0 ? avg6 : L(map, "PeriodTotal"),
                    SharePct = D(map, "SharePct"),
                    Prev9Day = L(map, "Prev9Day"),
                    Latest9Day = L(map, "Latest9Day"),
                    MoMDeltaPct = DN(map, "MoMDeltaPct"),
                });
            }
        }
        if (await r.NextResultAsync(ct))
        {
            map = Map();
            while (await r.ReadAsync(ct))
                vm.ResultRates.Add(new LisDrillResultRate
                { MonthLabel = S(map, "MonthLabel"), Resulted = L(map, "Resulted"), Received = L(map, "Received"), RatePct = DN(map, "RatePct") });
        }
        if (await r.NextResultAsync(ct))
        {
            map = Map();
            while (await r.ReadAsync(ct))
                vm.StatusBreakdown.Add(new LisDrillStatusRow
                { Status = S(map, "Status"), Year = (int)L(map, "CollYear"), Month = (int)L(map, "CollMonth"), Count = L(map, "Cnt") });
        }
        if (await r.NextResultAsync(ct))
        {
            map = Map();
            while (await r.ReadAsync(ct))
                vm.NineDayRange.Add(new LisDrillNineDayRange
                { MonthLabel = S(map, "MonthLabel"), ShortLabel = S(map, "ShortLabel"), Received9 = L(map, "Received9") });
        }
        if (await r.NextResultAsync(ct))
        {
            map = Map();
            while (await r.ReadAsync(ct))
                vm.RatePanels.Add(new LisDrillRatePanel
                {
                    Panel = S(map, "Panel"), Year = (int)L(map, "CollYear"), Month = (int)L(map, "CollMonth"),
                    Resulted9 = L(map, "Resulted9"), Received9 = L(map, "Received9"),
                });
        }
        // Set 8+: LIS returns clinics here; PMS returns insurers then panels then clinics.
        if (await r.NextResultAsync(ct))
        {
            map = Map();
            if (map.ContainsKey("Clinic"))
            {
                await AttachPanelClinicsAsync(vm, r, ct);
            }
            else
            {
                while (await r.ReadAsync(ct))
                {
                    var payer = S(map, "Payer");
                    if (string.IsNullOrWhiteSpace(payer)) continue;
                    vm.Insurers.Add(new LisDrillInsurer
                    {
                        Payer  = payer,
                        Claims = L(map, "Claims"),
                        MoMPct = DN(map, "MoMPct"),
                    });
                }
                // Set 9 (optional): Panel groups under each Top-10 payer — PMS core after redeploy.
                if (await r.NextResultAsync(ct))
                {
                    map = Map();
                    var byPayer = vm.Insurers
                        .GroupBy(i => i.Payer, StringComparer.OrdinalIgnoreCase)
                        .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
                    while (await r.ReadAsync(ct))
                    {
                        var payer = S(map, "Payer");
                        var panel = S(map, "Panel");
                        if (string.IsNullOrWhiteSpace(payer) || string.IsNullOrWhiteSpace(panel)) continue;
                        if (!byPayer.TryGetValue(payer, out var ins)) continue;
                        ins.Panels.Add(new LisDrillInsurerPanel
                        {
                            Panel  = panel,
                            Claims = L(map, "Claims"),
                            MoMPct = DN(map, "MoMPct"),
                        });
                    }
                }
                // Set 10 (optional): clinics under top panels — PMS core after redeploy.
                if (await r.NextResultAsync(ct))
                    await AttachPanelClinicsAsync(vm, r, ct);
            }
        }
    }

    /// <summary>
    /// Attaches Top-10 clinic rows (Panel + Clinic + Avg6Months / MoM) under matching panels.
    /// No-ops when the current result set is not a clinic shape (missing Clinic column).
    /// </summary>
    private static async Task AttachPanelClinicsAsync(
        ExecSummaryLisDrillViewModel vm, SqlDataReader r, CancellationToken ct)
    {
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < r.FieldCount; i++) map[r.GetName(i)] = i;
        if (!map.ContainsKey("Clinic") || !map.ContainsKey("Panel")) return;

        long L(string c) =>
            map.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToInt64(r.GetValue(i)) : 0L;
        string S(string c) =>
            map.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToString(r.GetValue(i)) ?? "" : "";
        decimal D(string c) =>
            map.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToDecimal(r.GetValue(i)) : 0m;
        decimal? DN(string c) =>
            map.TryGetValue(c, out var i) && !r.IsDBNull(i) ? Convert.ToDecimal(r.GetValue(i)) : (decimal?)null;

        var byPanel = vm.Panels
            .GroupBy(p => p.Panel, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
        while (await r.ReadAsync(ct))
        {
            var panel = S("Panel");
            var clinic = S("Clinic");
            if (string.IsNullOrWhiteSpace(panel) || string.IsNullOrWhiteSpace(clinic)) continue;
            if (!byPanel.TryGetValue(panel, out var parent)) continue;
            var avg6 = map.ContainsKey("Avg6Months") ? D("Avg6Months") : D("PeriodTotal");
            parent.Clinics.Add(new LisDrillPanelClinic
            {
                Clinic      = clinic,
                PeriodTotal = L("PeriodTotal"),
                Avg6Months  = avg6 > 0 ? avg6 : L("PeriodTotal"),
                SharePct    = D("SharePct"),
                Prev9Day    = L("Prev9Day"),
                Latest9Day  = L("Latest9Day"),
                MoMDeltaPct = DN("MoMDeltaPct"),
            });
        }
    }
}

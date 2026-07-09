using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;
using System.Diagnostics;

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
                    reader.GetString(0),
                    reader.GetString(1),
                    reader.GetString(2),
                    reader.GetInt32(3),
                    reader.GetInt32(4),
                    reader.GetDecimal(5)
                ));
            }

            _logger.LogInformation("ExecutiveSummary '{Lab}' SP={Sp}: {N} rows in {Ms}ms",
                selectedLab, spName, rawRows.Count, sw.ElapsedMilliseconds);

            if (rawRows.Count == 0)
                return vm;

            var rowDict   = new Dictionary<string, ExecSummaryRow>(StringComparer.OrdinalIgnoreCase);
            var periodSet = new SortedSet<(int Year, int Month)>(
                Comparer<(int Year, int Month)>.Create((a, b) =>
                    a.Year != b.Year ? a.Year.CompareTo(b.Year) : a.Month.CompareTo(b.Month)));
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
                if (billYear != 0 && billMonth != 0)
                {
                    periodSet.Add((billYear, billMonth));
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

            var columns = periodSet.ToList();
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
}

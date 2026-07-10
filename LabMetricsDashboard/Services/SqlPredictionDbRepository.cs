using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads <see cref="PredictionRecord"/> rows from dbo.PayerValidationReport
/// via dbo.usp_GetPayerValidationReport.
/// The per-lab connection string is passed in at call time so each lab can
/// target a different database/server.
/// </summary>
public sealed class SqlPredictionDbRepository : IPredictionDbRepository
{
    private readonly ILogger<SqlPredictionDbRepository> _logger;

    public SqlPredictionDbRepository(ILogger<SqlPredictionDbRepository> logger)
        => _logger = logger;

    public async Task<List<PredictionRecord>> GetRecordsAsync(
        string  connectionString,
        string? runId                     = null,
        string? filterPayerName           = null,
        string? filterPayerType           = null,
        string? filterPanelName           = null,
        string? filterFinalCoverageStatus = null,
        string? filterPayability          = null,
        string? filterCPTCode             = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            _logger.LogWarning("DbConnectionString is empty � returning empty dataset.");
            return [];
        }

        var records = new List<PredictionRecord>();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand("dbo.usp_GetPayerValidationReport", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 120
        };

        cmd.Parameters.AddWithValue("@RunId",                     (object?)runId                    ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPayerName",           (object?)filterPayerName          ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPayerType",           (object?)filterPayerType          ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPanelName",           (object?)filterPanelName          ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterFinalCoverageStatus", (object?)filterFinalCoverageStatus ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPayability",          (object?)filterPayability         ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterCPTCode",             (object?)filterCPTCode            ?? DBNull.Value);

        // NOTE: exceptions are intentionally NOT swallowed here. The caller (controller)
        // catches them and surfaces an actionable error message via the view-model �
        // hiding errors here was the root cause of the silent "all fields empty" bug.
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            records.Add(MapRow(reader));

        _logger.LogInformation("usp_GetPayerValidationReport returned {Count} rows.", records.Count);
        return records;
    }

    /// <inheritdoc/>
    public async Task<List<PredictionRecord>> GetForecastRecordsAsync(
        string  connectionString,
        string? runId = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            _logger.LogWarning("DbConnectionString is empty — returning empty forecast dataset.");
            return [];
        }

        var records = new List<PredictionRecord>();

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        await using var cmd = new SqlCommand("dbo.usp_GetForecastingRecords", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 600
        };
        cmd.Parameters.AddWithValue("@RunId", (object?)runId ?? DBNull.Value);

        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            records.Add(MapForecastRow(reader));

        _logger.LogInformation("usp_GetForecastingRecords returned {Count} rows.", records.Count);
        return records;
    }

    /// <inheritdoc/>
    public async Task<ForecastingSummaryFromDb?> TryGetForecastingSummaryAsync(
        string  connectionString,
        string? runId = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
            return null;

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(cancellationToken);

            await using var cmd = new SqlCommand("dbo.usp_GetForecastingSummaryByWeekRange", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 600
            };
            cmd.Parameters.AddWithValue("@RunId", (object?)runId ?? DBNull.Value);

            await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

            var buckets = new List<ForecastingBucketSpRow>();
            while (await reader.ReadAsync(cancellationToken))
            {
                buckets.Add(new ForecastingBucketSpRow(
                    SortOrder:   reader.GetInt32(reader.GetOrdinal("SortOrder")),
                    BucketKey:   reader.GetString(reader.GetOrdinal("BucketKey")),
                    WeekStart:   ReadDateOnly(reader, "WeekStart"),
                    WeekEnd:     ReadDateOnly(reader, "WeekEnd"),
                    BucketLabel: reader.GetString(reader.GetOrdinal("BucketLabel"))));
            }

            if (!await reader.NextResultAsync(cancellationToken))
                return null;

            var payerRows = new List<ForecastingPayerBucketSpRow>();
            while (await reader.ReadAsync(cancellationToken))
                payerRows.Add(MapForecastingPayerBucketRow(reader));

            if (!await reader.NextResultAsync(cancellationToken))
                return null;

            var totalRows = new List<ForecastingPayerBucketSpRow>();
            while (await reader.ReadAsync(cancellationToken))
                totalRows.Add(MapForecastingPayerBucketRow(reader));

            var summary = MapForecastingSummaryFromSp(buckets, payerRows, totalRows);
            _logger.LogInformation(
                "usp_GetForecastingSummaryByWeekRange returned {Payers} payers across {Weeks} buckets.",
                summary.MedianSummary.PayerRows.Count,
                summary.MedianSummary.Weeks.Count);
            return summary;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "usp_GetForecastingSummaryByWeekRange unavailable — falling back to in-memory summary.");
            return null;
        }
    }

    private static ForecastingPayerBucketSpRow MapForecastingPayerBucketRow(SqlDataReader reader) =>
        new(
            PayerName:          reader.GetString(reader.GetOrdinal("PayerName")),
            SortOrder:          reader.GetInt32(reader.GetOrdinal("SortOrder")),
            BucketKey:          reader.GetString(reader.GetOrdinal("BucketKey")),
            BucketLabel:        reader.GetString(reader.GetOrdinal("BucketLabel")),
            WeekStart:          ReadDateOnly(reader, "WeekStart"),
            WeekEnd:            ReadDateOnly(reader, "WeekEnd"),
            ClaimLineCount:     ReadInt64(reader, "ClaimLineCount"),
            MedianAllowedTotal: reader.GetDecimal(reader.GetOrdinal("MedianAllowedTotal")),
            MedianPaidTotal:    reader.GetDecimal(reader.GetOrdinal("MedianPaidTotal")),
            ModeAllowedTotal:   reader.GetDecimal(reader.GetOrdinal("ModeAllowedTotal")),
            ModePaidTotal:      reader.GetDecimal(reader.GetOrdinal("ModePaidTotal")));

    private static DateOnly? ReadDateOnly(SqlDataReader reader, string column)
    {
        var ord = reader.GetOrdinal(column);
        if (reader.IsDBNull(ord)) return null;
        return DateOnly.FromDateTime(reader.GetDateTime(ord));
    }

    /// <summary>COUNT(*) and similar aggregates return INT in SQL Server — use Convert for safety.</summary>
    private static long ReadInt64(SqlDataReader reader, string column)
    {
        var ord = reader.GetOrdinal(column);
        if (reader.IsDBNull(ord)) return 0L;
        return Convert.ToInt64(reader.GetValue(ord), System.Globalization.CultureInfo.InvariantCulture);
    }

    private static ForecastingSummaryFromDb MapForecastingSummaryFromSp(
        IReadOnlyList<ForecastingBucketSpRow> buckets,
        IReadOnlyList<ForecastingPayerBucketSpRow> payerRows,
        IReadOnlyList<ForecastingPayerBucketSpRow> totalRows)
    {
        // Match the dashboard date window: YTD + Weeks 1–5 only (exclude BEYOND).
        const int maxBucket = 5;

        var weeks = buckets
            .Where(b => b.SortOrder <= maxBucket)
            .OrderBy(b => b.SortOrder)
            .Select(b => b.SortOrder == 0
                ? new WeekRange(
                    DateOnly.MinValue,
                    b.WeekEnd ?? DateOnly.MinValue,
                    b.BucketLabel,
                    IncludeBeforeStart: true)
                : new WeekRange(
                    b.WeekStart ?? DateOnly.MinValue,
                    b.WeekEnd ?? DateOnly.MinValue,
                    b.BucketLabel))
            .ToList();

        static DateOnly WeekKey(ForecastingPayerBucketSpRow row) =>
            row.WeekStart ?? DateOnly.MinValue;

        var filteredPayerRows = payerRows.Where(r => r.SortOrder <= maxBucket).ToList();
        var filteredTotalRows = totalRows.Where(r => r.SortOrder <= maxBucket).ToList();

        var medianPayers = filteredPayerRows
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .OrderBy(g => g.Key)
            .Select(g => new WeeklyPayerRow(g.Key)
            {
                WeekAmounts = g.ToDictionary(
                    WeekKey,
                    r => new WeeklyAmounts(r.MedianAllowedTotal, r.MedianPaidTotal)),
                TotalAllowed = g.Sum(r => r.MedianAllowedTotal),
                TotalPaid    = g.Sum(r => r.MedianPaidTotal),
            })
            .ToList();

        var modePayers = filteredPayerRows
            .GroupBy(r => r.PayerName, StringComparer.OrdinalIgnoreCase)
            .OrderBy(g => g.Key)
            .Select(g => new WeeklyPayerRow(g.Key)
            {
                WeekAmounts = g.ToDictionary(
                    WeekKey,
                    r => new WeeklyAmounts(r.ModeAllowedTotal, r.ModePaidTotal)),
                TotalAllowed = g.Sum(r => r.ModeAllowedTotal),
                TotalPaid    = g.Sum(r => r.ModePaidTotal),
            })
            .ToList();

        var medianTotals = new WeeklyPayerRow("Total")
        {
            WeekAmounts = filteredTotalRows.ToDictionary(
                WeekKey,
                r => new WeeklyAmounts(r.MedianAllowedTotal, r.MedianPaidTotal)),
            TotalAllowed = filteredTotalRows.Sum(r => r.MedianAllowedTotal),
            TotalPaid    = filteredTotalRows.Sum(r => r.MedianPaidTotal),
        };

        var modeTotals = new WeeklyPayerRow("Total")
        {
            WeekAmounts = filteredTotalRows.ToDictionary(
                WeekKey,
                r => new WeeklyAmounts(r.ModeAllowedTotal, r.ModePaidTotal)),
            TotalAllowed = filteredTotalRows.Sum(r => r.ModeAllowedTotal),
            TotalPaid    = filteredTotalRows.Sum(r => r.ModePaidTotal),
        };

        return new ForecastingSummaryFromDb(
            new WeeklyForecastSummary { Weeks = weeks, PayerRows = medianPayers, Totals = medianTotals },
            new WeeklyForecastSummary { Weeks = weeks, PayerRows = modePayers, Totals = modeTotals });
    }

    // Maps the slim column set returned by usp_GetForecastingRecords.
    // All other PredictionRecord fields keep their defaults — the Forecasting
    // Summary page and its Excel export never read them.
    private static PredictionRecord MapForecastRow(SqlDataReader r) => new()
    {
        AccessionNo                = Str(r, "AccessionNo"),
        VisitNumber                = Str(r, "VisitNumber"),
        CPTCode                    = Str(r, "CPTCode"),
        PayerName                  = Str(r, "PayerName"),
        PayerNameNormalized        = Str(r, "PayerNameNormalized"),
        PayerType                  = Str(r, "PayerType"),
        PayStatus                  = Str(r, "PayStatus"),
        PanelName                  = Str(r, "PanelName"),
        DateOfService              = DateStr(r, "DateOfService"),
        FirstBilledDate            = DateStr(r, "FirstBilledDate"),
        DenialCode                 = Str(r, "DenialCode"),
        DenialDescription          = Str(r, "DenialDescription"),
        BilledAmount               = Dec(r, "BilledAmount"),
        AllowedAmount              = Dec(r, "AllowedAmount"),
        InsurancePayment           = Dec(r, "InsurancePayment"),
        Payability                 = Str(r, "Payability"),
        ForecastingPayability      = Str(r, "ForecastingPayability"),
        FinalCoverageStatus        = Str(r, "FinalCoverageStatus"),
        ExpectedPaymentDate        = DateStr(r, "ExpectedPaymentDate"),
        MedianAllowedAmountSameLab = Dec(r, "MedianAllowedAmountSameLab"),
        MedianInsurancePaidSameLab = Dec(r, "MedianInsurancePaidSameLab"),
        ModeAllowedAmountSameLab   = Dec(r, "ModeAllowedAmountSameLab"),
        ModeInsurancePaidSameLab   = Dec(r, "ModeInsurancePaidSameLab"),
    };

    /// <inheritdoc/>
    public async Task<PredictionDbDiagnostic> ProbeAsync(
        string connectionString,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
            return new PredictionDbDiagnostic(false, false, 0, null, null,
                "DbConnectionString is empty in the lab configuration.");

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(cancellationToken);

            // SP 4: usp_ProbePredictionDb � checks table + SP existence
            bool tableExists, procExists;
            await using (var cmd = new SqlCommand("dbo.usp_ProbePredictionDb", conn)
                         {
                             CommandType    = CommandType.StoredProcedure,
                             CommandTimeout = 30
                         })
            await using (var r = await cmd.ExecuteReaderAsync(cancellationToken))
            {
                if (!await r.ReadAsync(cancellationToken))
                    return new PredictionDbDiagnostic(false, false, 0, null, null,
                        "Database probe returned no rows (unexpected).");
                tableExists = r.GetBoolean(0);
                procExists  = r.GetBoolean(1);
            }

            if (!tableExists)
                return new PredictionDbDiagnostic(false, procExists, 0, null, null,
                    "Table dbo.PayerValidationReport does not exist in this lab's database. " +
                    "Run PredictionAnalysisApp/Database/01_CreateTables.sql against this lab's database.");

            if (!procExists)
                return new PredictionDbDiagnostic(true, false, 0, null, null,
                    "Stored procedure dbo.usp_GetPayerValidationReport is missing. " +
                    "Run PredictionAnalysisApp/Database/02_CreateStoredProcedures.sql against this lab's database.");

            // SP 5: usp_GetPayerValidationRunStats � latest RunId + total row count
            await using (var cmd = new SqlCommand("dbo.usp_GetPayerValidationRunStats", conn)
                         {
                             CommandType    = CommandType.StoredProcedure,
                             CommandTimeout = 60
                         })
            await using (var r = await cmd.ExecuteReaderAsync(cancellationToken))
            {
                if (!await r.ReadAsync(cancellationToken))
                {
                    return new PredictionDbDiagnostic(true, true, 0, null, null,
                        "dbo.PayerValidationReport exists but is empty. " +
                        "Run the PredictionAnalysisApp pipeline against this lab's source files to populate it.");
                }

                var runId    = r.IsDBNull(0) ? null : r.GetString(0);
                var inserted = r.IsDBNull(1) ? (DateTime?)null : r.GetDateTime(1);
                var rows     = r.IsDBNull(2) ? 0L : r.GetInt64(2);

                // WeekFolder + FileName were appended to the SP later — read them
                // defensively so labs still on the old SP version keep working.
                string? weekFolder = null, fileName = null;
                if (r.FieldCount > 3 && !r.IsDBNull(3)) weekFolder = r.GetString(3);
                if (r.FieldCount > 4 && !r.IsDBNull(4)) fileName   = r.GetString(4);

                return new PredictionDbDiagnostic(true, true, rows, runId, inserted, null,
                    weekFolder, fileName);
            }
        }
        catch (SqlException ex)
        {
            _logger.LogError(ex, "Prediction DB probe failed.");
            return new PredictionDbDiagnostic(false, false, 0, null, null,
                $"SQL error while probing Prediction database: {ex.Message}");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Prediction DB probe failed.");
            return new PredictionDbDiagnostic(false, false, 0, null, null,
                $"Failed to probe Prediction database: {ex.Message}");
        }
    }

    // ?? Row mapper ????????????????????????????????????????????????????????????
    // Reads every column returned by usp_GetPayerValidationReport.
    // If a column is added/removed from the SP, only this method needs updating.

    private static PredictionRecord MapRow(SqlDataReader r) => new()
    {
        AccessionNo                          = Str(r, "AccessionNo"),
        VisitNumber                          = Str(r, "VisitNumber"),
        CPTCode                              = Str(r, "CPTCode"),
        PatientDOB                           = Str(r, "PatientDOB"),
        PayerCode                            = Str(r, "PayerCode"),
        PayerName                            = Str(r, "PayerName"),
        PayerNameNormalized                  = Str(r, "PayerNameNormalized"),
        PayStatus                            = Str(r, "PayStatus"),
        HistoricalPayment                    = Str(r, "HistoricalPayment"),
        HistoricalPaidLineItemCount          = Str(r, "HistoricalPaidLineItemCount"),
        HistoricalPaymentConfidenceScore     = Str(r, "HistoricalPaymentConfidenceScore"),
        TotalLineItemCount                   = Int(r,  "TotalLineItemCount"),
        PaidLineItemCount                    = Int(r,  "PaidLineItemCount"),
        PctPaidLineItemCount                 = Str(r, "PctPaidLineItemCount"),
        PayerType                            = Str(r, "PayerType"),
        PayerFoundInPolicy                   = Str(r, "PayerFoundInPolicy"),
        DateOfService                        = DateStr(r, "DateOfService"),
        FirstBilledDate                      = DateStr(r, "FirstBilledDate"),
        PanelName                            = Str(r, "PanelName"),
        LISIcd10Codes                        = Str(r, "LISIcd10Codes"),
        CCWIcd10Code                         = Str(r, "CCWIcd10Code"),
        Units                                = Str(r, "Units"),
        Modifier                             = Str(r, "Modifier"),
        DenialCode                           = Str(r, "DenialCode"),
        DenialDescription                    = Str(r, "DenialDescription"),
        BilledAmount                         = Dec(r, "BilledAmount"),
        AllowedAmount                        = Dec(r, "AllowedAmount"),
        InsurancePayment                     = Dec(r, "InsurancePayment"),
        InsuranceAdjustment                  = Dec(r, "InsuranceAdjustment"),
        PatientPaidAmount                    = Dec(r, "PatientPaidAmount"),
        PatientAdjustment                    = Dec(r, "PatientAdjustment"),
        InsuranceBalance                     = Dec(r, "InsuranceBalance"),
        PatientBalance                       = Dec(r, "PatientBalance"),
        TotalBalance                         = Dec(r, "TotalBalance"),
        MedicareFee                          = Dec(r, "MedicareFee"),
        FinalClaimStatus                     = Str(r, "FinalClaimStatus"),
        CoveredIcd10CodesBilled              = Str(r, "CoveredIcd10CodesBilled"),
        NonCoveredIcd10CodesBilled           = Str(r, "NonCoveredIcd10CodesBilled"),
        BilledIcdCodesNotAvailableInPayerPolicy = Str(r, "BilledIcdCodesNotAvailableInPolicy"),
        CoverageStatus                       = Str(r, "CoverageStatus"),
        FinalCoverageStatus                  = Str(r, "FinalCoverageStatus"),
        CoveredIcd10CodesAsPerPayerPolicy    = Str(r, "CoveredIcd10CodesAsPerPayerPolicy"),
        NonCoveredIcd10CodesAsPerPayerPolicy = Str(r, "NonCoveredIcd10CodesAsPerPayerPolicy"),
        ActionComment                        = Str(r, "ActionComment"),
        Resolution                           = Str(r, "Resolution"),
        LabName                              = Str(r, "LabName2"),
        CodingValidation                     = Str(r, "CodingValidation"),
        CodingValidationSubStatus            = Str(r, "CodingValidationSubStatus"),
        ICDComplianceStatus                  = Str(r, "ICDComplianceStatus"),
        ICDComplianceSubstatus               = Str(r, "ICDComplianceSubstatus"),
        ICDPrimaryIndicatorAvailable         = Str(r, "ICDPrimaryIndicatorAvailable"),
        CoveredICDPresence                   = Str(r, "CoveredICDPresence"),
        ICDValidationConfidence              = Str(r, "ICDValidationConfidence"),
        FrequencyConditionMet                = Str(r, "FrequencyConditionMet"),
        GenderConditionMet                   = Str(r, "GenderConditionMet"),
        Payability                           = Str(r, "Payability"),
        ForecastingPayability                = Str(r, "ForecastingPayability"),
        PolicyCoverageExpectation            = Str(r, "PolicyCoverageExpectation"),
        DenialValidity                       = Str(r, "DenialValidity"),
        CoverageExpectationRemarks           = Str(r, "CoverageExpectationRemarks"),
        ExpectedAverageAllowedAmount         = Dec(r, "ExpectedAverageAllowedAmount"),
        ExpectedAverageInsurancePayment      = Dec(r, "ExpectedAverageInsurancePayment"),
        ExpectedAllowedAmountSameLab         = Dec(r, "ExpectedAllowedAmountSameLab"),
        ExpectedInsurancePaymentSameLab      = Dec(r, "ExpectedInsurancePaymentSameLab"),
        ModeAllowedAmountSameLab             = Dec(r, "ModeAllowedAmountSameLab"),
        ModeInsurancePaidSameLab             = Dec(r, "ModeInsurancePaidSameLab"),
        ModeAllowedAmountPeer                = Dec(r, "ModeAllowedAmountPeer"),
        ModeInsurancePaidPeer                = Dec(r, "ModeInsurancePaidPeer"),
        MedianAllowedAmountSameLab           = Dec(r, "MedianAllowedAmountSameLab"),
        MedianInsurancePaidSameLab           = Dec(r, "MedianInsurancePaidSameLab"),
        MedianAllowedAmountPeer              = Dec(r, "MedianAllowedAmountPeer"),
        MedianInsurancePaidPeer              = Dec(r, "MedianInsurancePaidPeer"),
        ModeAllowedAmountDifference          = Dec(r, "ModeAllowedAmountDifference"),
        ModeInsurancePaidDifference          = Dec(r, "ModeInsurancePaidDifference"),
        MedianAllowedAmountDifference        = Dec(r, "MedianAllowedAmountDifference"),
        MedianInsurancePaidDifference        = Dec(r, "MedianInsurancePaidDifference"),
        DenialRate                           = Str(r, "DenialRate"),
        AdjustmentRate                       = Str(r, "AdjustmentRate"),
        PaymentDays                          = Str(r, "PaymentDays"),
        ExpectedPaymentDate                  = DateStr(r, "ExpectedPaymentDate"),
        ExpectedPaymentMonth                 = Str(r, "ExpectedPaymentMonth"),
    };

    // ?? Safe reader helpers ???????????????????????????????????????????????????

    private static string  Str(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? string.Empty : r.GetString(r.GetOrdinal(col));

    private static string DateStr(SqlDataReader r, string col) => OADateOrRaw(Str(r, col));

    /// <summary>
    /// Normalizes DB date strings that may be stored as Excel OA serial numbers
    /// (for example, "46477") or as normal date text. This mirrors the Excel parser
    /// so DB-sourced records pass the same date filters as file-sourced records.
    /// </summary>
    private static string OADateOrRaw(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return string.Empty;

        if (double.TryParse(raw, System.Globalization.NumberStyles.Any,
                System.Globalization.CultureInfo.InvariantCulture, out var serial)
            && serial > 1 && serial < 2958466)
        {
            try
            {
                return DateTime.FromOADate(serial)
                    .ToString("MM/dd/yyyy", System.Globalization.CultureInfo.InvariantCulture);
            }
            catch
            {
                // fall through to normal date parsing
            }
        }

        if (DateTime.TryParse(raw, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out var dt))
        {
            return dt.ToString("MM/dd/yyyy", System.Globalization.CultureInfo.InvariantCulture);
        }

        return raw;
    }

    private static int     Int(SqlDataReader r, string col)
    {
        var ord = r.GetOrdinal(col);
        if (r.IsDBNull(ord)) return 0;
        // Column is NVARCHAR(MAX) in DB � parse string to int
        return int.TryParse(r.GetString(ord), out var v) ? v : 0;
    }

    private static decimal Dec(SqlDataReader r, string col)
    {
        var ord = r.GetOrdinal(col);
        if (r.IsDBNull(ord)) return 0m;
        // Column is NVARCHAR(MAX) in DB � parse string to decimal
        return decimal.TryParse(r.GetString(ord),
            System.Globalization.NumberStyles.Any,
            System.Globalization.CultureInfo.InvariantCulture,
            out var v) ? v : 0m;
    }

    // ?? Aggregated SP helpers ????????????????????????????????????????????????

    /// <summary>Adds the common filter parameters shared by all 6 aggregated SPs.</summary>
    private static void AddAggregateParams(
        SqlCommand cmd,
        DateOnly   weekStartDate,
        string?    runId,
        string?    filterPayerName,
        string?    filterPayerType,
        string?    filterPanelName,
        string?    filterFinalCoverageStatus,
        string?    filterPayability,
        string?    filterCPTCode)
    {
        cmd.Parameters.AddWithValue("@WeekStartDate",             (object?)weekStartDate.ToDateTime(TimeOnly.MinValue).Date ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RunId",                     (object?)runId                     ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPayerName",           (object?)filterPayerName           ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPayerType",           (object?)filterPayerType           ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPanelName",           (object?)filterPanelName           ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterFinalCoverageStatus", (object?)filterFinalCoverageStatus ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterPayability",          (object?)filterPayability          ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilterCPTCode",             (object?)filterCPTCode             ?? DBNull.Value);
    }

    private static SqlConnection OpenConnection(string connectionString)
    {
        var conn = new SqlConnection(connectionString);
        return conn; // caller must open
    }

    /// <summary>
    /// True when none of the dimension filters are active, so we are reading the
    /// totals as the PredictionAnalysisApp pre-computed them into the PV_* snapshot
    /// tables. When any filter is set we must fall through to the live SP path.
    /// </summary>
    private static bool NoDimensionFilters(
        string? filterPayerName, string? filterPayerType, string? filterPanelName,
        string? filterFinalCoverageStatus, string? filterPayability, string? filterCPTCode)
        => string.IsNullOrWhiteSpace(filterPayerName)
        && string.IsNullOrWhiteSpace(filterPayerType)
        && string.IsNullOrWhiteSpace(filterPanelName)
        && string.IsNullOrWhiteSpace(filterFinalCoverageStatus)
        && string.IsNullOrWhiteSpace(filterPayability)
        && string.IsNullOrWhiteSpace(filterCPTCode);

    /// <summary>
    /// Adds @WeekStartDate to a snapshot read command. The read SPs auto-resolve
    /// the latest RunId from their source PV_* table by RefreshedAt; the dashboard
    /// never supplies a RunId from the UI.
    /// </summary>
    private static void AddSnapshotParams(SqlCommand cmd, DateOnly weekStartDate)
    {
        cmd.Parameters.AddWithValue("@WeekStartDate", weekStartDate.ToDateTime(TimeOnly.MinValue).Date);
    }

    /// <summary>Adds the optional @FilterPayerName parameter for SPs that support it.</summary>
    private static void AddPayerNameFilter(SqlCommand cmd, string? filterPayerName)
    {
        cmd.Parameters.AddWithValue("@FilterPayerName", (object?)filterPayerName ?? DBNull.Value);
    }


    // ?? SP 6 : usp_GetPredictionSummaryBuckets ???????????????????????????????

    public async Task<List<PredictionBucketSpRow>> GetSummaryBucketsAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return [];

        var rows = new List<PredictionBucketSpRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        // ?? Snapshot fast-path ? dbo.PV_SummaryBuckets is populated by
        //    PredictionAnalysisApp after every ingestion. The snapshot stores
        //    unfiltered totals so it is only safe when no dimension filter is active.
        var unfiltered = NoDimensionFilters(filterPayerName, filterPayerType, filterPanelName,
            filterFinalCoverageStatus, filterPayability, filterCPTCode);

        if (unfiltered
            && await TryReadSummaryBucketsSnapshotAsync(conn, weekStartDate, rows, cancellationToken))
        {
            _logger.LogInformation(
                "PV_SummaryBuckets snapshot hit ({Count} rows).", rows.Count);
            return rows;
        }

        await using var cmd = new SqlCommand("dbo.usp_GetPredictionSummaryBuckets", conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 };
        AddAggregateParams(cmd, weekStartDate, runId, filterPayerName, filterPayerType,
            filterPanelName, filterFinalCoverageStatus, filterPayability, filterCPTCode);

        await using var r = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
        {
            rows.Add(new PredictionBucketSpRow(
                BucketName:           r.GetString  (r.GetOrdinal("BucketName")),
                SortOrder:            r.GetInt32   (r.GetOrdinal("SortOrder")),
                LineItemCount:        r.GetInt32   (r.GetOrdinal("LineItemCount")),
                PredictedAllowed:     r.GetDecimal (r.GetOrdinal("PredictedAllowed")),
                PredictedInsurance:   r.GetDecimal (r.GetOrdinal("PredictedInsurance")),
                ActualAllowed:        r.IsDBNull   (r.GetOrdinal("ActualAllowed"))    ? null : r.GetDecimal(r.GetOrdinal("ActualAllowed")),
                ActualInsurance:      r.IsDBNull   (r.GetOrdinal("ActualInsurance"))  ? null : r.GetDecimal(r.GetOrdinal("ActualInsurance"))));
        }

        _logger.LogInformation("usp_GetPredictionSummaryBuckets returned {Count} rows.", rows.Count);
        return rows;
    }

    // ?? SP 7 : usp_GetPredictionValidationByPayer ????????????????????????????

    public async Task<List<PredictionPayerSpRow>> GetValidationByPayerAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return [];

        var rows = new List<PredictionPayerSpRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        // Snapshot fast-path: PV_ValidationByPayer supports @FilterPayerName,
        // so we keep using it even when only the payer dropdown is active.
        var onlyPayerFilter = string.IsNullOrWhiteSpace(filterPayerType)
            && string.IsNullOrWhiteSpace(filterPanelName)
            && string.IsNullOrWhiteSpace(filterFinalCoverageStatus)
            && string.IsNullOrWhiteSpace(filterPayability)
            && string.IsNullOrWhiteSpace(filterCPTCode);

        if (onlyPayerFilter
            && await TryReadValidationByPayerSnapshotAsync(
                   conn, weekStartDate, filterPayerName, rows, cancellationToken))
        {
            _logger.LogInformation(
                "PV_ValidationByPayer snapshot hit ({Count} rows, payer='{Payer}').",
                rows.Count, filterPayerName ?? "(all)");
            return rows;
        }

        await using var cmd = new SqlCommand("dbo.usp_GetPredictionValidationByPayer", conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 };
        AddAggregateParams(cmd, weekStartDate, runId, filterPayerName, filterPayerType,
            filterPanelName, filterFinalCoverageStatus, filterPayability, filterCPTCode);

        await using var r = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
        {
            rows.Add(new PredictionPayerSpRow(
                PayerName:          r.GetString (r.GetOrdinal("PayerName")),
                PayerType:          r.GetString (r.GetOrdinal("PayerType")),
                TotalLineItems:     r.GetInt32  (r.GetOrdinal("TotalLineItems")),
                PaidCount:          r.GetInt32  (r.GetOrdinal("PaidCount")),
                DeniedCount:        r.GetInt32  (r.GetOrdinal("DeniedCount")),
                NoResponseCount:    r.GetInt32  (r.GetOrdinal("NoResponseCount")),
                AdjustedCount:      r.GetInt32  (r.GetOrdinal("AdjustedCount")),
                UnpaidCount:        r.GetInt32  (r.GetOrdinal("UnpaidCount")),
                PredictedAllowed:   r.GetDecimal(r.GetOrdinal("PredictedAllowed")),
                PredictedInsurance: r.GetDecimal(r.GetOrdinal("PredictedInsurance")),
                ActualAllowed:      r.GetDecimal(r.GetOrdinal("ActualAllowed")),
                ActualInsurance:    r.GetDecimal(r.GetOrdinal("ActualInsurance"))));
        }

        _logger.LogInformation("usp_GetPredictionValidationByPayer returned {Count} rows.", rows.Count);
        return rows;
    }

    // ?? SP 8 : usp_GetPredictionValidationByPanel ????????????????????????????

    public async Task<List<PredictionPanelSpRow>> GetValidationByPanelAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return [];

        var rows = new List<PredictionPanelSpRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        var unfiltered = NoDimensionFilters(filterPayerName, filterPayerType, filterPanelName,
            filterFinalCoverageStatus, filterPayability, filterCPTCode);
        if (unfiltered
            && await TryReadValidationByPanelSnapshotAsync(conn, weekStartDate, rows, cancellationToken))
        {
            _logger.LogInformation(
                "PV_ValidationByPanel snapshot hit ({Count} rows).", rows.Count);
            return rows;
        }

        await using var cmd = new SqlCommand("dbo.usp_GetPredictionValidationByPanel", conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 };
        AddAggregateParams(cmd, weekStartDate, runId, filterPayerName, filterPayerType,
            filterPanelName, filterFinalCoverageStatus, filterPayability, filterCPTCode);

        await using var r = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
        {
            rows.Add(new PredictionPanelSpRow(
                PanelName:          r.GetString (r.GetOrdinal("PanelName")),
                TotalLineItems:     r.GetInt32  (r.GetOrdinal("TotalLineItems")),
                PaidCount:          r.GetInt32  (r.GetOrdinal("PaidCount")),
                DeniedCount:        r.GetInt32  (r.GetOrdinal("DeniedCount")),
                NoResponseCount:    r.GetInt32  (r.GetOrdinal("NoResponseCount")),
                AdjustedCount:      r.GetInt32  (r.GetOrdinal("AdjustedCount")),
                UnpaidCount:        r.GetInt32  (r.GetOrdinal("UnpaidCount")),
                PredictedAllowed:   r.GetDecimal(r.GetOrdinal("PredictedAllowed")),
                PredictedInsurance: r.GetDecimal(r.GetOrdinal("PredictedInsurance")),
                ActualAllowed:      r.GetDecimal(r.GetOrdinal("ActualAllowed")),
                ActualInsurance:    r.GetDecimal(r.GetOrdinal("ActualInsurance"))));
        }

        _logger.LogInformation("usp_GetPredictionValidationByPanel returned {Count} rows.", rows.Count);
        return rows;
    }

    // ?? SP 9 : usp_GetPredictionValidationByCPT ??????????????????????????????

    public async Task<List<PredictionCptSpRow>> GetValidationByCptAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return [];

        var rows = new List<PredictionCptSpRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        var unfiltered = NoDimensionFilters(filterPayerName, filterPayerType, filterPanelName,
            filterFinalCoverageStatus, filterPayability, filterCPTCode);
        if (unfiltered
            && await TryReadValidationByCptSnapshotAsync(conn, weekStartDate, rows, cancellationToken))
        {
            _logger.LogInformation(
                "PV_ValidationByCPT snapshot hit ({Count} rows).", rows.Count);
            return rows;
        }

        await using var cmd = new SqlCommand("dbo.usp_GetPredictionValidationByCPT", conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 };
        AddAggregateParams(cmd, weekStartDate, runId, filterPayerName, filterPayerType,
            filterPanelName, filterFinalCoverageStatus, filterPayability, filterCPTCode);

        await using var r = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
        {
            rows.Add(new PredictionCptSpRow(
                CPTCode:            r.GetString (r.GetOrdinal("CPTCode")),
                LineItemCount:      r.GetInt32  (r.GetOrdinal("LineItemCount")),
                BilledAmount:       r.GetDecimal(r.GetOrdinal("BilledAmount")),
                PredictedAllowed:   r.GetDecimal(r.GetOrdinal("PredictedAllowed")),
                PredictedInsurance: r.GetDecimal(r.GetOrdinal("PredictedInsurance"))));
        }

        _logger.LogInformation("usp_GetPredictionValidationByCPT returned {Count} rows.", rows.Count);
        return rows;
    }

    // ?? SP 10 : usp_GetPredictionDenialBreakdown ?????????????????????????????

    public async Task<List<DenialBreakdownSpRow>> GetDenialBreakdownAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return [];

        var rows = new List<DenialBreakdownSpRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        // PV_DenialBreakdown supports @FilterPayerName.
        var onlyPayerFilter = string.IsNullOrWhiteSpace(filterPayerType)
            && string.IsNullOrWhiteSpace(filterPanelName)
            && string.IsNullOrWhiteSpace(filterFinalCoverageStatus)
            && string.IsNullOrWhiteSpace(filterPayability)
            && string.IsNullOrWhiteSpace(filterCPTCode);

        if (onlyPayerFilter
            && await TryReadDenialBreakdownSnapshotAsync(
                   conn, weekStartDate, filterPayerName, rows, cancellationToken))
        {
            _logger.LogInformation(
                "PV_DenialBreakdown snapshot hit ({Count} rows, payer='{Payer}').",
                rows.Count, filterPayerName ?? "(all)");
            return rows;
        }

        await using var cmd = new SqlCommand("dbo.usp_GetPredictionDenialBreakdown", conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 };
        AddAggregateParams(cmd, weekStartDate, runId, filterPayerName, filterPayerType,
            filterPanelName, filterFinalCoverageStatus, filterPayability, filterCPTCode);

        await using var r = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
        {
            rows.Add(new DenialBreakdownSpRow(
                PayerName:            r.GetString (r.GetOrdinal("PayerName")),
                DenialCode:           r.GetString (r.GetOrdinal("DenialCode")),
                DenialDescription:    r.GetString (r.GetOrdinal("DenialDescription")),
                ExpectedPaymentMonth: r.GetString (r.GetOrdinal("ExpectedPaymentMonth")),
                LineItemCount:        r.GetInt32  (r.GetOrdinal("LineItemCount")),
                PredictedAllowed:     r.GetDecimal(r.GetOrdinal("PredictedAllowed")),
                PredictedInsurance:   r.GetDecimal(r.GetOrdinal("PredictedInsurance"))));
        }

        _logger.LogInformation("usp_GetPredictionDenialBreakdown returned {Count} rows.", rows.Count);
        return rows;
    }

    // ?? SP 11 : usp_GetPredictionNoResponseBreakdown ?????????????????????????

    public async Task<List<NoResponseBreakdownSpRow>> GetNoResponseBreakdownAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return [];

        var rows = new List<NoResponseBreakdownSpRow>();
        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        // PV_NoResponseBreakdown supports @FilterPayerName.
        var onlyPayerFilter = string.IsNullOrWhiteSpace(filterPayerType)
            && string.IsNullOrWhiteSpace(filterPanelName)
            && string.IsNullOrWhiteSpace(filterFinalCoverageStatus)
            && string.IsNullOrWhiteSpace(filterPayability)
            && string.IsNullOrWhiteSpace(filterCPTCode);

        if (onlyPayerFilter
            && await TryReadNoResponseBreakdownSnapshotAsync(
                   conn, weekStartDate, filterPayerName, rows, cancellationToken))
        {
            _logger.LogInformation(
                "PV_NoResponseBreakdown snapshot hit ({Count} rows, payer='{Payer}').",
                rows.Count, filterPayerName ?? "(all)");
            return rows;
        }

        await using var cmd = new SqlCommand("dbo.usp_GetPredictionNoResponseBreakdown", conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 };
        AddAggregateParams(cmd, weekStartDate, runId, filterPayerName, filterPayerType,
            filterPanelName, filterFinalCoverageStatus, filterPayability, filterCPTCode);

        await using var r = await cmd.ExecuteReaderAsync(cancellationToken);
        while (await r.ReadAsync(cancellationToken))
        {
            rows.Add(new NoResponseBreakdownSpRow(
                PayerName:          r.GetString (r.GetOrdinal("PayerName")),
                AgeBucket:          r.GetString (r.GetOrdinal("AgeBucket")),
                LineItemCount:      r.GetInt32  (r.GetOrdinal("LineItemCount")),
                PredictedAllowed:   r.GetDecimal(r.GetOrdinal("PredictedAllowed")),
                PredictedInsurance: r.GetDecimal(r.GetOrdinal("PredictedInsurance"))));
        }

        _logger.LogInformation("usp_GetPredictionNoResponseBreakdown returned {Count} rows.", rows.Count);
        return rows;
    }

    // ?? SP 12 : usp_GetPredictionSummaryMetrics ??????????????????????????????

    public async Task<PredictionSummaryMetricsSpRow?> GetSummaryMetricsAsync(
        string connectionString, DateOnly weekStartDate,
        string? runId = null, string? filterPayerName = null, string? filterPayerType = null,
        string? filterPanelName = null, string? filterFinalCoverageStatus = null,
        string? filterPayability = null, string? filterCPTCode = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return null;

        await using var conn = new SqlConnection(connectionString);
        await conn.OpenAsync(cancellationToken);

        var unfiltered = NoDimensionFilters(filterPayerName, filterPayerType, filterPanelName,
            filterFinalCoverageStatus, filterPayability, filterCPTCode);
        if (unfiltered)
        {
            var snap = await TryReadSummaryMetricsSnapshotAsync(
                conn, weekStartDate, cancellationToken);
            if (snap is not null)
            {
                _logger.LogInformation("PV_SummaryMetrics snapshot hit.");
                return snap;
            }
        }

        await using var cmd = new SqlCommand("dbo.usp_GetPredictionSummaryMetrics", conn)
            { CommandType = System.Data.CommandType.StoredProcedure, CommandTimeout = 120 };
        AddAggregateParams(cmd, weekStartDate, runId, filterPayerName, filterPayerType,
            filterPanelName, filterFinalCoverageStatus, filterPayability, filterCPTCode);

        await using var r = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await r.ReadAsync(cancellationToken))
        {
            _logger.LogWarning("usp_GetPredictionSummaryMetrics returned no rows.");
            return null;
        }

        // Null-safe helpers � defend against any NULL the SP might still return
        // (e.g. when a bucket has no matching rows and ISNULL was not applied in an
        // older SP version already deployed to a lab database).
        int     SafeInt(string col) { var o = r.GetOrdinal(col); return r.IsDBNull(o) ? 0    : r.GetInt32  (o); }
        decimal SafeDec(string col) { var o = r.GetOrdinal(col); return r.IsDBNull(o) ? 0m   : r.GetDecimal(o); }
        decimal? NullDec(string col) { var o = r.GetOrdinal(col); return r.IsDBNull(o) ? null : r.GetDecimal(o); }

        var result = new PredictionSummaryMetricsSpRow(
            // Section 1 � raw bucket values (never null after SP fix; SafeInt/SafeDec as belt-and-braces)
            ToPay_LineItems:     SafeInt("ToPay_LineItems"),
            ToPay_ModeAllowed:   SafeDec("ToPay_ModeAllowed"),
            ToPay_ModeIns:       SafeDec("ToPay_ModeIns"),
            Paid_LineItems:      SafeInt("Paid_LineItems"),
            Paid_ModeAllowed:    SafeDec("Paid_ModeAllowed"),
            Paid_ModeIns:        SafeDec("Paid_ModeIns"),
            Paid_ActAllowed:     SafeDec("Paid_ActAllowed"),
            Paid_ActIns:         SafeDec("Paid_ActIns"),
            Unpaid_LineItems:    SafeInt("Unpaid_LineItems"),
            Unpaid_ModeAllowed:  SafeDec("Unpaid_ModeAllowed"),
            Unpaid_ModeIns:      SafeDec("Unpaid_ModeIns"),
            Denied_LineItems:    SafeInt("Denied_LineItems"),
            Denied_ModeAllowed:  SafeDec("Denied_ModeAllowed"),
            Denied_ModeIns:      SafeDec("Denied_ModeIns"),
            NoResp_LineItems:    SafeInt("NoResp_LineItems"),
            NoResp_ModeAllowed:  SafeDec("NoResp_ModeAllowed"),
            NoResp_ModeIns:      SafeDec("NoResp_ModeIns"),
            Adj_LineItems:       SafeInt("Adj_LineItems"),
            Adj_ModeAllowed:     SafeDec("Adj_ModeAllowed"),
            Adj_ModeIns:         SafeDec("Adj_ModeIns"),

            // Section 2 � Ratios (legitimately nullable when denominator = 0)
            PaymentRatio_Claim:       NullDec("PaymentRatio_Claim"),
            PaymentRatio_Allowed:     NullDec("PaymentRatio_Allowed"),
            PaymentRatio_Insurance:   NullDec("PaymentRatio_Insurance"),
            NonPaymentRate_Claim:     NullDec("NonPaymentRate_Claim"),
            NonPaymentRate_Allowed:   NullDec("NonPaymentRate_Allowed"),
            NonPaymentRate_Insurance: NullDec("NonPaymentRate_Insurance"),
            DeniedPct_Claim:          NullDec("DeniedPct_Claim"),
            DeniedPct_Allowed:        NullDec("DeniedPct_Allowed"),
            DeniedPct_Insurance:      NullDec("DeniedPct_Insurance"),
            NoResponsePct_Claim:      NullDec("NoResponsePct_Claim"),
            NoResponsePct_Allowed:    NullDec("NoResponsePct_Allowed"),
            NoResponsePct_Insurance:  NullDec("NoResponsePct_Insurance"),
            AdjustedPct_Claim:        NullDec("AdjustedPct_Claim"),
            AdjustedPct_Allowed:      NullDec("AdjustedPct_Allowed"),
            AdjustedPct_Insurance:    NullDec("AdjustedPct_Insurance"),

            // Section 3 � Prediction Accuracy (legitimately nullable when denominator = 0)
            PredAccuracy_Claim:            NullDec("PredAccuracy_Claim"),
            PredAccuracy_AllowedAmount:    NullDec("PredAccuracy_AllowedAmount"),
            PredAccuracy_InsurancePayment: NullDec("PredAccuracy_InsurancePayment"));

        _logger.LogInformation(
            "usp_GetPredictionSummaryMetrics: ToPay={T}, Paid={P}, Unpaid={U} | " +
            "PaymentRatio={PR}%, NonPayment={NPR}% | PredAccuracy Claim={AC}%",
            result.ToPay_LineItems, result.Paid_LineItems, result.Unpaid_LineItems,
            result.PaymentRatio_Claim, result.NonPaymentRate_Claim, result.PredAccuracy_Claim);

        return result;
    }

    // ?? PV_* snapshot readers ???????????????????????????????????????????????
    // Each helper attempts to read from the snapshot table populated by
    // PredictionAnalysisApp (usp_RefreshAllPredictionAggregates). Returns true
    // when at least one row was loaded; on any SqlException (table missing,
    // permission, etc.) we swallow and return false so the caller falls
    // through to the live SP path.

    private async Task<bool> TryReadSummaryBucketsSnapshotAsync(
        SqlConnection conn, DateOnly weekStartDate,
        List<PredictionBucketSpRow> rows, CancellationToken ct)
    {
        try
        {
            await using var cmd = new SqlCommand("dbo.usp_PV_ReadSummaryBuckets", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 30
            };
            AddSnapshotParams(cmd, weekStartDate);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rows.Add(new PredictionBucketSpRow(
                    BucketName:         r.GetString(0),
                    SortOrder:          r.GetInt32(1),
                    LineItemCount:      r.GetInt32(2),
                    PredictedAllowed:   r.GetDecimal(3),
                    PredictedInsurance: r.GetDecimal(4),
                    ActualAllowed:      r.IsDBNull(5) ? null : r.GetDecimal(5),
                    ActualInsurance:    r.IsDBNull(6) ? null : r.GetDecimal(6)));
            }
            return rows.Count > 0;
        }
        catch (SqlException ex)
        {
            _logger.LogDebug(ex, "PV_SummaryBuckets snapshot unavailable; falling through to live SP.");
            return false;
        }
    }

    private async Task<bool> TryReadValidationByPayerSnapshotAsync(
        SqlConnection conn, DateOnly weekStartDate, string? filterPayerName,
        List<PredictionPayerSpRow> rows, CancellationToken ct)
    {
        try
        {
            await using var cmd = new SqlCommand("dbo.usp_PV_ReadValidationByPayer", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 30
            };
            AddSnapshotParams(cmd, weekStartDate);
            AddPayerNameFilter(cmd, filterPayerName);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rows.Add(new PredictionPayerSpRow(
                    PayerName:          r.GetString(0),
                    PayerType:          r.GetString(1),
                    TotalLineItems:     r.GetInt32(2),
                    PaidCount:          r.GetInt32(3),
                    DeniedCount:        r.GetInt32(4),
                    NoResponseCount:    r.GetInt32(5),
                    AdjustedCount:      r.GetInt32(6),
                    UnpaidCount:        r.GetInt32(7),
                    PredictedAllowed:   r.GetDecimal(8),
                    PredictedInsurance: r.GetDecimal(9),
                    ActualAllowed:      r.GetDecimal(10),
                    ActualInsurance:    r.GetDecimal(11)));
            }
            return rows.Count > 0;
        }
        catch (SqlException ex)
        {
            _logger.LogDebug(ex, "PV_ValidationByPayer snapshot unavailable; falling through to live SP.");
            return false;
        }
    }

    private async Task<bool> TryReadValidationByPanelSnapshotAsync(
        SqlConnection conn, DateOnly weekStartDate,
        List<PredictionPanelSpRow> rows, CancellationToken ct)
    {
        try
        {
            await using var cmd = new SqlCommand("dbo.usp_PV_ReadValidationByPanel", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 30
            };
            AddSnapshotParams(cmd, weekStartDate);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rows.Add(new PredictionPanelSpRow(
                    PanelName:          r.GetString(0),
                    TotalLineItems:     r.GetInt32(1),
                    PaidCount:          r.GetInt32(2),
                    DeniedCount:        r.GetInt32(3),
                    NoResponseCount:    r.GetInt32(4),
                    AdjustedCount:      r.GetInt32(5),
                    UnpaidCount:        r.GetInt32(6),
                    PredictedAllowed:   r.GetDecimal(7),
                    PredictedInsurance: r.GetDecimal(8),
                    ActualAllowed:      r.GetDecimal(9),
                    ActualInsurance:    r.GetDecimal(10)));
            }
            return rows.Count > 0;
        }
        catch (SqlException ex)
        {
            _logger.LogDebug(ex, "PV_ValidationByPanel snapshot unavailable; falling through to live SP.");
            return false;
        }
    }

    private async Task<bool> TryReadValidationByCptSnapshotAsync(
        SqlConnection conn, DateOnly weekStartDate,
        List<PredictionCptSpRow> rows, CancellationToken ct)
    {
        try
        {
            await using var cmd = new SqlCommand("dbo.usp_PV_ReadValidationByCPT", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 30
            };
            AddSnapshotParams(cmd, weekStartDate);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rows.Add(new PredictionCptSpRow(
                    CPTCode:            r.GetString(0),
                    LineItemCount:      r.GetInt32(1),
                    BilledAmount:       r.GetDecimal(2),
                    PredictedAllowed:   r.GetDecimal(3),
                    PredictedInsurance: r.GetDecimal(4)));
            }
            return rows.Count > 0;
        }
        catch (SqlException ex)
        {
            _logger.LogDebug(ex, "PV_ValidationByCPT snapshot unavailable; falling through to live SP.");
            return false;
        }
    }

    private async Task<bool> TryReadDenialBreakdownSnapshotAsync(
        SqlConnection conn, DateOnly weekStartDate, string? filterPayerName,
        List<DenialBreakdownSpRow> rows, CancellationToken ct)
    {
        try
        {
            await using var cmd = new SqlCommand("dbo.usp_PV_ReadDenialBreakdown", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 30
            };
            AddSnapshotParams(cmd, weekStartDate);
            AddPayerNameFilter(cmd, filterPayerName);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rows.Add(new DenialBreakdownSpRow(
                    PayerName:            r.GetString(0),
                    DenialCode:           r.GetString(1),
                    DenialDescription:    r.GetString(2),
                    ExpectedPaymentMonth: r.GetString(3),
                    LineItemCount:        r.GetInt32(4),
                    PredictedAllowed:     r.GetDecimal(5),
                    PredictedInsurance:   r.GetDecimal(6)));
            }
            return rows.Count > 0;
        }
        catch (SqlException ex)
        {
            _logger.LogDebug(ex, "PV_DenialBreakdown snapshot unavailable; falling through to live SP.");
            return false;
        }
    }

    private async Task<bool> TryReadNoResponseBreakdownSnapshotAsync(
        SqlConnection conn, DateOnly weekStartDate, string? filterPayerName,
        List<NoResponseBreakdownSpRow> rows, CancellationToken ct)
    {
        try
        {
            await using var cmd = new SqlCommand("dbo.usp_PV_ReadNoResponseBreakdown", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 30
            };
            AddSnapshotParams(cmd, weekStartDate);
            AddPayerNameFilter(cmd, filterPayerName);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                rows.Add(new NoResponseBreakdownSpRow(
                    PayerName:          r.GetString(0),
                    AgeBucket:          r.GetString(1),
                    LineItemCount:      r.GetInt32(2),
                    PredictedAllowed:   r.GetDecimal(3),
                    PredictedInsurance: r.GetDecimal(4)));
            }
            return rows.Count > 0;
        }
        catch (SqlException ex)
        {
            _logger.LogDebug(ex, "PV_NoResponseBreakdown snapshot unavailable; falling through to live SP.");
            return false;
        }
    }

    private async Task<PredictionSummaryMetricsSpRow?> TryReadSummaryMetricsSnapshotAsync(
        SqlConnection conn, DateOnly weekStartDate, CancellationToken ct)
    {
        try
        {
            await using var cmd = new SqlCommand("dbo.usp_PV_ReadSummaryMetrics", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 30
            };
            AddSnapshotParams(cmd, weekStartDate);

            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (!await r.ReadAsync(ct)) return null;

            int     I(int o) => r.IsDBNull(o) ? 0  : r.GetInt32(o);
            decimal D(int o) => r.IsDBNull(o) ? 0m : r.GetDecimal(o);
            decimal? N(int o) => r.IsDBNull(o) ? (decimal?)null : r.GetDecimal(o);

            return new PredictionSummaryMetricsSpRow(
                ToPay_LineItems:               I(0),
                ToPay_ModeAllowed:             D(1),
                ToPay_ModeIns:                 D(2),
                Paid_LineItems:                I(3),
                Paid_ModeAllowed:              D(4),
                Paid_ModeIns:                  D(5),
                Paid_ActAllowed:               D(6),
                Paid_ActIns:                   D(7),
                Unpaid_LineItems:              I(8),
                Unpaid_ModeAllowed:            D(9),
                Unpaid_ModeIns:                D(10),
                Denied_LineItems:              I(11),
                Denied_ModeAllowed:            D(12),
                Denied_ModeIns:                D(13),
                NoResp_LineItems:              I(14),
                NoResp_ModeAllowed:            D(15),
                NoResp_ModeIns:                D(16),
                Adj_LineItems:                 I(17),
                Adj_ModeAllowed:               D(18),
                Adj_ModeIns:                   D(19),
                PaymentRatio_Claim:            N(20),
                PaymentRatio_Allowed:          N(21),
                PaymentRatio_Insurance:        N(22),
                NonPaymentRate_Claim:          N(23),
                NonPaymentRate_Allowed:        N(24),
                NonPaymentRate_Insurance:      N(25),
                DeniedPct_Claim:               N(26),
                DeniedPct_Allowed:             N(27),
                DeniedPct_Insurance:           N(28),
                NoResponsePct_Claim:           N(29),
                NoResponsePct_Allowed:         N(30),
                NoResponsePct_Insurance:       N(31),
                AdjustedPct_Claim:             N(32),
                AdjustedPct_Allowed:           N(33),
                AdjustedPct_Insurance:         N(34),
                PredAccuracy_Claim:            N(35),
                PredAccuracy_AllowedAmount:    N(36),
                PredAccuracy_InsurancePayment: N(37));
        }
        catch (SqlException ex)
        {
            _logger.LogDebug(ex, "PV_SummaryMetrics snapshot unavailable; falling through to live SP.");
            return null;
        }
    }
}

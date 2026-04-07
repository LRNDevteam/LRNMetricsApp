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
            _logger.LogWarning("DbConnectionString is empty — returning empty dataset.");
            return [];
        }

        var records = new List<PredictionRecord>();

        try
        {
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

            await using var reader = await cmd.ExecuteReaderAsync(cancellationToken);

            while (await reader.ReadAsync(cancellationToken))
                records.Add(MapRow(reader));

            _logger.LogInformation("usp_GetPayerValidationReport returned {Count} rows.", records.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to read from usp_GetPayerValidationReport — returning empty dataset.");
        }

        return records;
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
        DateOfService                        = Str(r, "DateOfService"),
        FirstBilledDate                      = Str(r, "FirstBilledDate"),
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
        ExpectedPaymentDate                  = Str(r, "ExpectedPaymentDate"),
        ExpectedPaymentMonth                 = Str(r, "ExpectedPaymentMonth"),
    };

    // ?? Safe reader helpers ???????????????????????????????????????????????????

    private static string  Str(SqlDataReader r, string col)
        => r.IsDBNull(r.GetOrdinal(col)) ? string.Empty : r.GetString(r.GetOrdinal(col));

    private static int     Int(SqlDataReader r, string col)
    {
        var ord = r.GetOrdinal(col);
        if (r.IsDBNull(ord)) return 0;
        // Column is NVARCHAR(MAX) in DB — parse string to int
        return int.TryParse(r.GetString(ord), out var v) ? v : 0;
    }

    private static decimal Dec(SqlDataReader r, string col)
    {
        var ord = r.GetOrdinal(col);
        if (r.IsDBNull(ord)) return 0m;
        // Column is NVARCHAR(MAX) in DB — parse string to decimal
        return decimal.TryParse(r.GetString(ord),
            System.Globalization.NumberStyles.Any,
            System.Globalization.CultureInfo.InvariantCulture,
            out var v) ? v : 0m;
    }
}

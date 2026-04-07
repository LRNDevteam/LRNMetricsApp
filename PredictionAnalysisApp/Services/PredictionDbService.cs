using System.Data;
using Microsoft.Data.SqlClient;
using PredictionAnalysis.Models;

namespace PredictionAnalysis.Services;

/// <summary>
/// Persists PayerValidation source data to SQL Server before the
/// prediction analysis begins.  All exceptions are swallowed so that
/// a DB failure never blocks the existing prediction process.
/// </summary>
public class PredictionDbService
{
    private readonly string _connectionString;

    // Maps each source Excel header (exact text) to its TVP column name.
    // Keys are case-insensitive; unknown headers are silently ignored.
    private static readonly Dictionary<string, string> HeaderToColumn =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["Accession No"]                                    = "AccessionNo",
            ["Visit Number"]                                    = "VisitNumber",
            ["CPTCode"]                                         = "CPTCode",
            ["Patient DOB"]                                     = "PatientDOB",
            ["Payer Code"]                                      = "PayerCode",
            ["Payer Name"]                                      = "PayerName",
            ["PayerName Normalized"]                            = "PayerNameNormalized",
            ["Pay Status"]                                      = "PayStatus",
            ["Historical Payment"]                              = "HistoricalPayment",
            ["Historical Paid Line-Item Count"]                 = "HistoricalPaidLineItemCount",
            ["Historical Payment Confidence Score"]             = "HistoricalPaymentConfidenceScore",
            ["Total Line-Item Count"]                           = "TotalLineItemCount",
            ["Paid Line-Item Count"]                            = "PaidLineItemCount",
            ["% Paid Line-Item Count"]                         = "PctPaidLineItemCount",
            ["Payer Type"]                                      = "PayerType",
            ["PayerFound in Policy"]                            = "PayerFoundInPolicy",
            ["Date of Service"]                                 = "DateOfService",
            ["First Billed Date"]                               = "FirstBilledDate",
            ["Panel Name"]                                      = "PanelName",
            ["LIS ICD 10 Codes"]                                = "LISIcd10Codes",
            ["CCW ICD10Code"]                                   = "CCWIcd10Code",
            ["Units"]                                           = "Units",
            ["Modifier"]                                        = "Modifier",
            ["DenialCode"]                                      = "DenialCode",
            ["Denial Description"]                              = "DenialDescription",
            ["Billed Amount"]                                   = "BilledAmount",
            ["Allowed Amount"]                                  = "AllowedAmount",
            ["Insurance Payment"]                               = "InsurancePayment",
            ["Insurance Adjustment"]                            = "InsuranceAdjustment",
            ["Patient Paid Amount"]                             = "PatientPaidAmount",
            ["Patient Adjustment"]                              = "PatientAdjustment",
            ["Insurance Balance"]                               = "InsuranceBalance",
            ["Patient Balance"]                                 = "PatientBalance",
            ["Total Balance"]                                   = "TotalBalance",
            ["Medicare Fee"]                                    = "MedicareFee",
            ["Final Claim Status"]                              = "FinalClaimStatus",
            ["Covered ICD 10 Codes Billed"]                    = "CoveredIcd10CodesBilled",
            ["Non Covered ICD 10 Codes Billed"]                = "NonCoveredIcd10CodesBilled",
            ["Billed ICD codes not available in Payer Policy"] = "BilledIcdCodesNotAvailableInPolicy",
            ["Coverage Status"]                                 = "CoverageStatus",
            ["Final Coverage Status"]                           = "FinalCoverageStatus",
            ["Covered ICD 10 codes as per Payer Policy"]       = "CoveredIcd10CodesAsPerPayerPolicy",
            ["Non Covered ICD 10 Codes as per Payer Policy"]   = "NonCoveredIcd10CodesAsPerPayerPolicy",
            ["Action Comment"]                                  = "ActionComment",
            ["Resolution"]                                      = "Resolution",
            ["Lab Name"]                                        = "LabName2",
            ["Coding Validation"]                               = "CodingValidation",
            ["Coding Validation Sub-Status"]                    = "CodingValidationSubStatus",
            ["ICD Compliance Status"]                           = "ICDComplianceStatus",
            ["ICD Compliance Substatus"]                        = "ICDComplianceSubstatus",
            ["ICD Primary Indicator Available"]                 = "ICDPrimaryIndicatorAvailable",
            ["Covered ICD Presence"]                            = "CoveredICDPresence",
            ["ICD Validation Confidence"]                       = "ICDValidationConfidence",
            ["Frequency Condition Met"]                         = "FrequencyConditionMet",
            ["Gender Condition Met"]                            = "GenderConditionMet",
            ["Payability"]                                      = "Payability",
            ["Forecasting Payability"]                          = "ForecastingPayability",
            ["Policy Coverage Expectation"]                     = "PolicyCoverageExpectation",
            ["Denial Validity"]                                 = "DenialValidity",
            ["Coverage Expectation Remarks"]                    = "CoverageExpectationRemarks",
            ["Expected Average Allowed Amount"]                 = "ExpectedAverageAllowedAmount",
            ["Expected Average Insurance Payment"]              = "ExpectedAverageInsurancePayment",
            ["Expected Allowed Amount - Same Lab"]              = "ExpectedAllowedAmountSameLab",
            ["Expected Insurance Payment - Same Lab"]           = "ExpectedInsurancePaymentSameLab",
            ["Mode Allowed Amount - Same Lab"]                  = "ModeAllowedAmountSameLab",
            ["Mode Insurance Paid - Same Lab"]                  = "ModeInsurancePaidSameLab",
            ["Mode Allowed Amount- Peer"]                       = "ModeAllowedAmountPeer",
            ["Mode Insurance Paid - Peer"]                      = "ModeInsurancePaidPeer",
            ["Median Allowed Amount- Same Lab"]                 = "MedianAllowedAmountSameLab",
            ["Median Insurance Paid - Same Lab"]                = "MedianInsurancePaidSameLab",
            ["Median Allowed Amount- Peer"]                     = "MedianAllowedAmountPeer",
            ["Median Insurance Paid - Peer"]                    = "MedianInsurancePaidPeer",
            ["Mode Allowed Amount Difference"]                  = "ModeAllowedAmountDifference",
            ["Mode Insurance Paid Difference"]                  = "ModeInsurancePaidDifference",
            ["Median Allowed Amount Difference"]                = "MedianAllowedAmountDifference",
            ["Median Insurance Paid Difference"]                = "MedianInsurancePaidDifference",
            ["Denial Rate"]                                     = "DenialRate",
            ["Adjustment Rate"]                                 = "AdjustmentRate",
            ["Payment Days"]                                    = "PaymentDays",
            ["Expected Payment Date"]                           = "ExpectedPaymentDate",
            ["Expected Payment Month"]                          = "ExpectedPaymentMonth",
            ["BillingProvider"]                                 = "BillingProvider",
            ["ReferringProvider"]                               = "ReferringProvider",
            ["ClinicName"]                                      = "ClinicName",
            ["SalesRepname"]                                    = "SalesRepName",
            ["PatientID"]                                       = "PatientID",
            ["ChargeEnteredDate"]                               = "ChargeEnteredDate",
            ["POS"]                                             = "POS",
            ["TOS"]                                             = "TOS",
            ["CheckDate"]                                       = "CheckDate",
            ["DaystoDOS"]                                       = "DaysToDOS",
            ["RollingDays"]                                     = "RollingDays",
            ["DaystoBill"]                                      = "DaysToBill",
            ["DaystoPost"]                                      = "DaysToPost",
        };

    public PredictionDbService(string connectionString)
    {
        _connectionString = connectionString;
    }

    // ?? Public entry point ????????????????????????????????????????????????????

    /// <summary>
    /// Returns true when <paramref name="sourceFilePath"/> already has an entry
    /// in <c>dbo.PayerValidationFileLog</c> — used to skip re-insertion for a
    /// file that was already processed in a previous run.
    /// Returns false on any DB error so the caller falls through to insert.
    /// </summary>
    public bool FileAlreadyLogged(string sourceFilePath, string labName)
    {
        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();

            using var cmd = new SqlCommand(
                "SELECT COUNT(1) FROM dbo.PayerValidationFileLog WHERE SourceFullPath = @SourceFullPath",
                conn)
            {
                CommandTimeout = 30
            };
            cmd.Parameters.AddWithValue("@SourceFullPath", sourceFilePath);

            var count = (int)cmd.ExecuteScalar()!;
            if (count > 0)
            {
                AppLogger.LogDb($"[{labName}] File already in PayerValidationFileLog — skipping DB insert: {Path.GetFileName(sourceFilePath)}");
                return true;
            }
            return false;
        }
        catch (Exception ex)
        {
            AppLogger.LogDbWarn($"[{labName}] FileAlreadyLogged check failed — will proceed with insert. {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Saves file metadata then bulk-inserts all claim rows.
    /// Any exception is caught and logged to console; the prediction
    /// process is never interrupted.
    /// </summary>
    public void SavePayerValidationData(
        List<ClaimRecord> records,
        string            sourceFilePath,
        string            runId,
        string            weekFolder,
        string            labName)
    {
        try
        {
            // Treat blank runId / weekFolder as NULL — file may not follow standard naming.
            var effectiveRunId      = string.IsNullOrWhiteSpace(runId)      ? null : runId;
            var effectiveWeekFolder = string.IsNullOrWhiteSpace(weekFolder) ? null : weekFolder;

            if (effectiveRunId is null)
                AppLogger.LogDbWarn($"[{labName}] RunId is blank — will insert NULL in DB.");
            if (effectiveWeekFolder is null)
                AppLogger.LogDbWarn($"[{labName}] WeekFolder is blank — will insert NULL in DB.");

            AppLogger.LogDb($"[{labName}] Starting DB insert — {records.Count} records, RunId={effectiveRunId ?? "NULL"}");

            var fileInfo  = new FileInfo(sourceFilePath);
            int fileLogId = InsertFileLog(effectiveRunId, effectiveWeekFolder, labName,
                                          sourceFilePath, fileInfo.Name,
                                          fileInfo.Exists ? fileInfo.CreationTime : DateTime.UtcNow);

            AppLogger.LogDb($"[{labName}] FileLog inserted — FileLogId={fileLogId}");

            BulkInsertRows(records, fileLogId, effectiveRunId, effectiveWeekFolder, labName, sourceFilePath);

            AppLogger.LogDb($"[{labName}] Saved {records.Count} rows successfully");
        }
        catch (Exception ex)
        {
            AppLogger.LogDbError($"[{labName}] DB insert failed — prediction will continue", ex);
        }
    }

    // ?? Private helpers ???????????????????????????????????????????????????????

    private int InsertFileLog(
        string?  runId,
        string?  weekFolder,
        string   labName,
        string   sourceFullPath,
        string   fileName,
        DateTime fileCreatedDateTime)
    {
        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        using var cmd = new SqlCommand("dbo.usp_SavePayerValidationFileLog", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 60
        };

        cmd.Parameters.AddWithValue("@RunId",               (object?)runId      ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@WeekFolder",          (object?)weekFolder ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LabName",             labName);
        cmd.Parameters.AddWithValue("@SourceFullPath",      sourceFullPath);
        cmd.Parameters.AddWithValue("@FileName",            fileName);
        cmd.Parameters.AddWithValue("@FileCreatedDateTime", fileCreatedDateTime);

        var outParam = new SqlParameter("@FileLogId", SqlDbType.Int)
        {
            Direction = ParameterDirection.Output
        };
        cmd.Parameters.Add(outParam);

        cmd.ExecuteNonQuery();

        return (int)(outParam.Value ?? 0);
    }

    private void BulkInsertRows(
        List<ClaimRecord> records,
        int               fileLogId,
        string?           runId,
        string?           weekFolder,
        string            labName,
        string            sourceFullPath)
    {
        var tvp = BuildTvp(records, fileLogId, runId, weekFolder, labName, sourceFullPath);

        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        using var cmd = new SqlCommand("dbo.usp_BulkInsertPayerValidationReport", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 300
        };

        var tvpParam = cmd.Parameters.AddWithValue("@Rows", tvp);
        tvpParam.SqlDbType = SqlDbType.Structured;
        tvpParam.TypeName  = "dbo.TVP_PayerValidationReport";

        cmd.ExecuteNonQuery();
    }

    private static DataTable BuildTvp(
        List<ClaimRecord> records,
        int               fileLogId,
        string?           runId,
        string?           weekFolder,
        string            labName,
        string            sourceFullPath)
    {
        var dt = CreateTvpSchema();

        if (records.Count == 0)
            return dt;

        // ?? One-time header diagnostics ???????????????????????????????????????
        var firstRaw = records[0].RawColumns;

        var unmappedSourceHeaders = firstRaw.Keys
            .Where(h => !HeaderToColumn.ContainsKey(h))
            .OrderBy(h => h)
            .ToList();

        if (unmappedSourceHeaders.Count > 0)
        {
            AppLogger.LogDbWarn($"[{labName}] {unmappedSourceHeaders.Count} source column(s) have no DB mapping — skipped:");
            foreach (var h in unmappedSourceHeaders)
                AppLogger.LogDbWarn($"[{labName}]   (no mapping) \"{h}\"");
        }

        var missingMappedHeaders = HeaderToColumn.Keys
            .Where(h => !firstRaw.ContainsKey(h))
            .OrderBy(h => h)
            .ToList();

        if (missingMappedHeaders.Count > 0)
        {
            AppLogger.LogDbWarn($"[{labName}] {missingMappedHeaders.Count} expected column(s) not found in source file — will insert NULL:");
            foreach (var h in missingMappedHeaders)
                AppLogger.LogDbWarn($"[{labName}]   (not in file) \"{h}\" ? {HeaderToColumn[h]}");
        }

        AppLogger.LogDb($"[{labName}] Building {records.Count} TVP rows...");

        foreach (var rec in records)
        {
            var row = dt.NewRow();

            row["FileLogId"]      = fileLogId;
            row["RunId"]          = (object?)runId      ?? DBNull.Value;
            row["WeekFolder"]     = (object?)weekFolder ?? DBNull.Value;
            row["LabName"]        = labName;
            row["SourceFullPath"] = sourceFullPath;

            foreach (var kv in rec.RawColumns)
            {
                if (!HeaderToColumn.TryGetValue(kv.Key, out var colName))
                    continue;

                row[colName] = string.IsNullOrEmpty(kv.Value)
                    ? DBNull.Value
                    : (object)kv.Value;
            }

            dt.Rows.Add(row);
        }

        return dt;
    }

    private static DataTable CreateTvpSchema()
    {
        var dt = new DataTable();

        // IMPORTANT: column order must exactly match the TVP_PayerValidationReport
        // definition in SQL Server (ordinal 1-99). SqlClient maps DataTable columns
        // to TVP columns by position, not by name.
        dt.Columns.Add("FileLogId",                            typeof(int));
        dt.Columns.Add("RunId",                                typeof(string));
        dt.Columns.Add("WeekFolder",                           typeof(string));
        dt.Columns.Add("LabName",                              typeof(string));
        dt.Columns.Add("SourceFullPath",                       typeof(string));
        dt.Columns.Add("AccessionNo",                          typeof(string));
        dt.Columns.Add("VisitNumber",                          typeof(string));
        dt.Columns.Add("CPTCode",                              typeof(string));
        dt.Columns.Add("PatientDOB",                           typeof(string));
        dt.Columns.Add("PayerCode",                            typeof(string));
        dt.Columns.Add("PayerName",                            typeof(string));
        dt.Columns.Add("PayerNameNormalized",                  typeof(string));
        dt.Columns.Add("PayStatus",                            typeof(string));
        dt.Columns.Add("HistoricalPayment",                    typeof(string));
        dt.Columns.Add("HistoricalPaidLineItemCount",          typeof(string));
        dt.Columns.Add("HistoricalPaymentConfidenceScore",     typeof(string));
        dt.Columns.Add("TotalLineItemCount",                   typeof(string));
        dt.Columns.Add("PaidLineItemCount",                    typeof(string));
        dt.Columns.Add("PctPaidLineItemCount",                 typeof(string));
        dt.Columns.Add("PayerType",                            typeof(string));
        dt.Columns.Add("PayerFoundInPolicy",                   typeof(string));
        dt.Columns.Add("DateOfService",                        typeof(string));
        dt.Columns.Add("FirstBilledDate",                      typeof(string));
        dt.Columns.Add("PanelName",                            typeof(string));
        dt.Columns.Add("LISIcd10Codes",                        typeof(string));
        dt.Columns.Add("CCWIcd10Code",                         typeof(string));
        dt.Columns.Add("Units",                                typeof(string));
        dt.Columns.Add("Modifier",                             typeof(string));
        dt.Columns.Add("DenialCode",                           typeof(string));
        dt.Columns.Add("DenialDescription",                    typeof(string));
        dt.Columns.Add("BilledAmount",                         typeof(string));
        dt.Columns.Add("AllowedAmount",                        typeof(string));
        dt.Columns.Add("InsurancePayment",                     typeof(string));
        dt.Columns.Add("InsuranceAdjustment",                  typeof(string));
        dt.Columns.Add("PatientPaidAmount",                    typeof(string));
        dt.Columns.Add("PatientAdjustment",                    typeof(string));
        dt.Columns.Add("InsuranceBalance",                     typeof(string));
        dt.Columns.Add("PatientBalance",                       typeof(string));
        dt.Columns.Add("TotalBalance",                         typeof(string));
        dt.Columns.Add("MedicareFee",                          typeof(string));
        dt.Columns.Add("FinalClaimStatus",                     typeof(string));
        dt.Columns.Add("CoveredIcd10CodesBilled",              typeof(string));
        dt.Columns.Add("NonCoveredIcd10CodesBilled",           typeof(string));
        dt.Columns.Add("BilledIcdCodesNotAvailableInPolicy",   typeof(string));
        dt.Columns.Add("CoverageStatus",                       typeof(string));
        dt.Columns.Add("FinalCoverageStatus",                  typeof(string));
        dt.Columns.Add("CoveredIcd10CodesAsPerPayerPolicy",    typeof(string));
        dt.Columns.Add("NonCoveredIcd10CodesAsPerPayerPolicy", typeof(string));
        dt.Columns.Add("ActionComment",                        typeof(string));
        dt.Columns.Add("Resolution",                           typeof(string));
        dt.Columns.Add("LabName2",                             typeof(string));
        dt.Columns.Add("CodingValidation",                     typeof(string));
        dt.Columns.Add("CodingValidationSubStatus",            typeof(string));
        dt.Columns.Add("ICDComplianceStatus",                  typeof(string));
        dt.Columns.Add("ICDComplianceSubstatus",               typeof(string));
        dt.Columns.Add("ICDPrimaryIndicatorAvailable",         typeof(string));
        dt.Columns.Add("CoveredICDPresence",                   typeof(string));
        dt.Columns.Add("ICDValidationConfidence",              typeof(string));
        dt.Columns.Add("FrequencyConditionMet",                typeof(string));
        dt.Columns.Add("GenderConditionMet",                   typeof(string));
        dt.Columns.Add("Payability",                           typeof(string));
        dt.Columns.Add("ForecastingPayability",                typeof(string));
        dt.Columns.Add("PolicyCoverageExpectation",            typeof(string));
        dt.Columns.Add("DenialValidity",                       typeof(string));
        dt.Columns.Add("CoverageExpectationRemarks",           typeof(string));
        dt.Columns.Add("ExpectedAverageAllowedAmount",         typeof(string));
        dt.Columns.Add("ExpectedAverageInsurancePayment",      typeof(string));
        dt.Columns.Add("ExpectedAllowedAmountSameLab",         typeof(string));
        dt.Columns.Add("ExpectedInsurancePaymentSameLab",      typeof(string));
        dt.Columns.Add("ModeAllowedAmountSameLab",             typeof(string));
        dt.Columns.Add("ModeInsurancePaidSameLab",             typeof(string));
        dt.Columns.Add("ModeAllowedAmountPeer",                typeof(string));
        dt.Columns.Add("ModeInsurancePaidPeer",                typeof(string));
        dt.Columns.Add("MedianAllowedAmountSameLab",           typeof(string));
        dt.Columns.Add("MedianInsurancePaidSameLab",           typeof(string));
        dt.Columns.Add("MedianAllowedAmountPeer",              typeof(string));
        dt.Columns.Add("MedianInsurancePaidPeer",              typeof(string));
        dt.Columns.Add("ModeAllowedAmountDifference",          typeof(string));
        dt.Columns.Add("ModeInsurancePaidDifference",          typeof(string));
        dt.Columns.Add("MedianAllowedAmountDifference",        typeof(string));
        dt.Columns.Add("MedianInsurancePaidDifference",        typeof(string));
        dt.Columns.Add("DenialRate",                           typeof(string));
        dt.Columns.Add("AdjustmentRate",                       typeof(string));
        dt.Columns.Add("PaymentDays",                          typeof(string));
        dt.Columns.Add("ExpectedPaymentDate",                  typeof(string));
        dt.Columns.Add("ExpectedPaymentMonth",                 typeof(string));
        dt.Columns.Add("BillingProvider",                      typeof(string));
        dt.Columns.Add("ReferringProvider",                    typeof(string));
        dt.Columns.Add("ClinicName",                           typeof(string));
        dt.Columns.Add("SalesRepName",                         typeof(string));
        dt.Columns.Add("PatientID",                            typeof(string));
        dt.Columns.Add("ChargeEnteredDate",                    typeof(string));
        dt.Columns.Add("POS",                                  typeof(string));
        dt.Columns.Add("TOS",                                  typeof(string));
        dt.Columns.Add("CheckDate",                            typeof(string));
        dt.Columns.Add("DaysToDOS",                            typeof(string));
        dt.Columns.Add("RollingDays",                          typeof(string));
        dt.Columns.Add("DaysToBill",                           typeof(string));
        dt.Columns.Add("DaysToPost",                           typeof(string));

        return dt;
    }
}

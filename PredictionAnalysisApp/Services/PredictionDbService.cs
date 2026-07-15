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
    private readonly int    _chunkSize;
    /// <summary>0 = auto from row count / defaults.</summary>
    private readonly int    _configuredAggregateChunkSize;
    /// <summary>0 = auto from row count / defaults.</summary>
    private readonly int    _configuredAggregateRefreshTimeoutSeconds;
    private readonly int    _largeLabRowThreshold;

    /// <summary>Fallback chunk size when caller passes 0 / negative.</summary>
    public const int DefaultChunkSize = 25_000;

    /// <summary>Default SP CommandTimeout for aggregate refresh (seconds) on normal labs.</summary>
    public const int DefaultAggregateRefreshTimeoutSeconds = 600;

    /// <summary>Timeout for labs at/above large-lab row threshold.</summary>
    public const int LargeLabAggregateRefreshTimeoutSeconds = 3600;

    /// <summary>ReportId window used when chunking (any lab over threshold).</summary>
    public const int DefaultAggregateChunkSize = 100_000;

    /// <summary>7 lakh — auto-enable long timeout + explicit chunk size.</summary>
    public const int DefaultLargeLabRowThreshold = 700_000;

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

    public PredictionDbService(
        string connectionString,
        int chunkSize = DefaultChunkSize,
        int aggregateChunkSize = 0,
        int aggregateRefreshTimeoutSeconds = 0,
        int largeLabRowThreshold = 0)
    {
        _connectionString = connectionString;
        _chunkSize        = chunkSize > 0 ? chunkSize : DefaultChunkSize;
        _configuredAggregateChunkSize = aggregateChunkSize > 0 ? aggregateChunkSize : 0;
        _configuredAggregateRefreshTimeoutSeconds = aggregateRefreshTimeoutSeconds > 0
            ? aggregateRefreshTimeoutSeconds
            : 0;
        _largeLabRowThreshold = largeLabRowThreshold > 0
            ? largeLabRowThreshold
            : DefaultLargeLabRowThreshold;
    }

    // ?? Public entry point ????????????????????????????????????????????????????

    /// <summary>
    /// Returns true when <paramref name="sourceFilePath"/> already has an entry
    /// in <c>dbo.PayerValidationFileLog</c> � used to skip re-insertion for a
    /// file that was already processed in a previous run.
    /// Returns false on any DB error so the caller falls through to insert.
    /// </summary>
    public bool FileAlreadyLogged(string sourceFilePath, string labName)
    {
        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();

            using var cmd = new SqlCommand("dbo.usp_PV_IsFileLogged", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 30
            };
            cmd.Parameters.AddWithValue("@SourceFullPath", sourceFilePath);

            var result   = cmd.ExecuteScalar();
            var isLogged = result is bool b && b;
            if (isLogged)
            {
                AppLogger.LogDb($"[{labName}] File already in PayerValidationFileLog � skipping DB insert: {Path.GetFileName(sourceFilePath)}");
                return true;
            }
            return false;
        }
        catch (Exception ex)
        {
            AppLogger.LogDbWarn($"[{labName}] FileAlreadyLogged check failed � will proceed with insert. {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Removes the <c>dbo.PayerValidationFileLog</c> entry and all associated
    /// <c>dbo.PayerValidationReport</c> rows for the given file path so the
    /// file can be re-inserted from scratch on the same run.
    /// Called by <c>Program.cs</c> when <c>DataRefresh = true</c> in the lab JSON.
    /// Any exception is caught and logged; the caller then proceeds with the insert.
    /// </summary>
    public void DeleteFileLogEntry(string sourceFilePath, string labName)
    {
        try
        {
            AppLogger.LogDb($"[{labName}] DataRefresh=true � deleting existing FileLog + Report rows for: {Path.GetFileName(sourceFilePath)}");

            using var conn = new SqlConnection(_connectionString);
            conn.Open();

            // SP-only policy: deletes run inside dbo.usp_DeletePayerValidationFileEntry.
            using var cmd = new SqlCommand("dbo.usp_DeletePayerValidationFileEntry", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 300
            };
            cmd.Parameters.AddWithValue("@SourceFullPath", sourceFilePath);
            var reportRowsParam  = new SqlParameter("@DeletedReportRows",  SqlDbType.Int) { Direction = ParameterDirection.Output };
            var fileLogRowsParam = new SqlParameter("@DeletedFileLogRows", SqlDbType.Int) { Direction = ParameterDirection.Output };
            cmd.Parameters.Add(reportRowsParam);
            cmd.Parameters.Add(fileLogRowsParam);
            cmd.ExecuteNonQuery();

            AppLogger.LogDb($"[{labName}]   Deleted {(int)(reportRowsParam.Value  ?? 0):N0} rows from PayerValidationReport.");
            AppLogger.LogDb($"[{labName}]   Deleted {(int)(fileLogRowsParam.Value ?? 0):N0} row(s) from PayerValidationFileLog.");
        }
        catch (Exception ex)
        {
            AppLogger.LogDbError($"[{labName}] DeleteFileLogEntry failed � will still attempt re-insert", ex);
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
            // Treat blank runId / weekFolder as NULL � file may not follow standard naming.
            var effectiveRunId      = string.IsNullOrWhiteSpace(runId)      ? null : runId;
            var effectiveWeekFolder = string.IsNullOrWhiteSpace(weekFolder) ? null : weekFolder;

            if (effectiveRunId is null)
                AppLogger.LogDbWarn($"[{labName}] RunId is blank � will insert NULL in DB.");
            if (effectiveWeekFolder is null)
                AppLogger.LogDbWarn($"[{labName}] WeekFolder is blank � will insert NULL in DB.");

            AppLogger.LogDb($"[{labName}] Starting DB insert � {records.Count} records, RunId={effectiveRunId ?? "NULL"}");

            var fileInfo  = new FileInfo(sourceFilePath);
            int fileLogId = InsertFileLog(effectiveRunId, effectiveWeekFolder, labName,
                                          sourceFilePath, fileInfo.Name,
                                          fileInfo.Exists ? fileInfo.CreationTime : DateTime.UtcNow);

            AppLogger.LogDb($"[{labName}] FileLog inserted � FileLogId={fileLogId}");

            BulkInsertRows(records, fileLogId, effectiveRunId, effectiveWeekFolder, labName, sourceFilePath);

            UpdatePredictionFields(labName, effectiveRunId);

            AppLogger.LogDb($"[{labName}] Saved {records.Count} rows successfully");
        }
        catch (Exception ex)
        {
            AppLogger.LogDbError($"[{labName}] DB insert failed � prediction will continue", ex);
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
        if (records.Count == 0)
        {
            AppLogger.LogDb($"[{labName}] BulkInsertRows: 0 records ? nothing to insert.");
            return;
        }

        // One-time header diagnostics (use first record so we don't log per chunk).
        LogHeaderDiagnostics(records[0], labName);

        var totalChunks = (records.Count + _chunkSize - 1) / _chunkSize;
        AppLogger.LogDb(
            $"[{labName}] Inserting {records.Count:N0} rows in {totalChunks} chunk(s) of up to {_chunkSize:N0}...");

        var sw = System.Diagnostics.Stopwatch.StartNew();
        int chunkNo = 0;
        long rowsSent = 0;

        // Reuse one open connection across chunks; one SP call per chunk.
        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        // ── RETENTION: purge ALL previous rows for this lab ONCE, up-front ────
        // Must happen exactly once per file (not per chunk) — a per-chunk delete
        // would wipe rows inserted by earlier chunks of the same run.
        // The dashboard only reads the latest RunId, so old runs are dead weight.
        try
        {
            using var truncCmd = new SqlCommand("dbo.usp_TruncatePayerValidationLab", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 300
            };
            truncCmd.Parameters.AddWithValue("@LabName", labName);
            var deletedParam = new SqlParameter("@DeletedRows", SqlDbType.Int)
            {
                Direction = ParameterDirection.Output
            };
            truncCmd.Parameters.Add(deletedParam);
            truncCmd.ExecuteNonQuery();

            AppLogger.LogDb(
                $"[{labName}] Retention purge: {(int)(deletedParam.Value ?? 0):N0} previous rows deleted from PayerValidationReport.");
        }
        catch (SqlException ex) when (ex.Number == 2812) // SP not deployed yet
        {
            // SP-only policy: no inline SQL fallback. Old rows are also cleaned up by
            // the retention delete inside the deployed SPs on the next run.
            throw new InvalidOperationException(
                $"[{labName}] dbo.usp_TruncatePayerValidationLab is missing — " +
                "run the updated 02_CreateStoredProcedures.sql against this lab's database before inserting.", ex);
        }

        for (int offset = 0; offset < records.Count; offset += _chunkSize)
        {
            chunkNo++;
            var size  = Math.Min(_chunkSize, records.Count - offset);
            var slice = records.GetRange(offset, size);

            var chunkSw = System.Diagnostics.Stopwatch.StartNew();
            var tvp = BuildTvp(slice, fileLogId, runId, weekFolder, labName, sourceFullPath);

            using var cmd = new SqlCommand("dbo.usp_BulkInsertPayerValidationReport", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 300
            };

            var tvpParam = cmd.Parameters.AddWithValue("@Rows", tvp);
            tvpParam.SqlDbType = SqlDbType.Structured;
            tvpParam.TypeName  = "dbo.TVP_PayerValidationReport";

            cmd.ExecuteNonQuery();

            rowsSent += size;
            chunkSw.Stop();
            AppLogger.LogDb(
                $"[{labName}]   chunk {chunkNo}/{totalChunks}: {size:N0} rows in {chunkSw.Elapsed.TotalSeconds:F1}s " +
                $"(running total {rowsSent:N0}/{records.Count:N0})");
        }

        sw.Stop();
        AppLogger.LogDb(
            $"[{labName}] BulkInsertRows complete: {records.Count:N0} rows in {sw.Elapsed.TotalSeconds:F1}s " +
            $"({totalChunks} chunk(s), {_chunkSize:N0} rows/chunk).");
    }

    /// <summary>
    /// Updates ForecastingPayabilitySubstatus, PredictionStatus, and variance columns
    /// on all rows for the run. Called once after bulk insert completes.
    /// </summary>
    public void UpdatePredictionFields(string labName, string? runId)
    {
        if (string.IsNullOrWhiteSpace(runId)) return;

        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();
            var (chunkSize, timeoutSeconds, rowCount, isLarge) = ResolveAggregateSettings(conn, runId, labName);

            using var cmd = new SqlCommand("dbo.usp_UpdatePayerValidationPredictionFields", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = timeoutSeconds
            };
            cmd.Parameters.AddWithValue("@RunId",   runId);
            cmd.Parameters.AddWithValue("@LabName", labName);
            // Chunked UPDATE only when SP supports @ChunkSize (10_*). Pass for large labs /
            // when JSON override is set. Same formulas — counts unchanged.
            if (isLarge || _configuredAggregateChunkSize > 0)
                cmd.Parameters.AddWithValue("@ChunkSize", chunkSize);

            cmd.ExecuteNonQuery();
            AppLogger.LogDb(
                $"[{labName}] Prediction fields updated for RunId={runId} " +
                $"(rows≈{rowCount:N0}, largeLab={isLarge}, chunk={chunkSize}).");
        }
        catch (Exception ex)
        {
            AppLogger.LogDbError($"[{labName}] UpdatePredictionFields failed", ex);
        }
    }

    /// <summary>
    /// Runs <c>dbo.usp_RefreshAllPredictionAggregates</c> to populate the PV_* snapshot
    /// tables that the LabMetricsDashboard reads from. After refresh, automatically
    /// enriches blank DenialDescription from LRNMaster (SQL SP when same-server, then
    /// C# enricher when <paramref name="masterDbConnectionString"/> is set).
    /// <para>
    /// Any lab with PayerValidationReport rows &gt;= 7 lakh (or JSON override) uses
    /// ReportId chunking into PV_WorkingBase. Formulas match live Get SPs —
    /// COUNT(DISTINCT VisitNumber) / SUMs do not change.
    /// </para>
    /// </summary>
    public void RefreshAggregatesForRun(
        string labName,
        string? runId,
        DateTime? weekStartDate = null,
        string? masterDbConnectionString = null)
    {
        if (string.IsNullOrWhiteSpace(runId))
        {
            AppLogger.LogDbWarn($"[{labName}] Aggregate refresh skipped — RunId is blank.");
            return;
        }

        try
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            AppLogger.LogDb($"[{labName}] Refreshing PV_* aggregate snapshots for RunId={runId}...");

            using var conn = new SqlConnection(_connectionString);
            conn.Open();

            var (chunkSize, timeoutSeconds, rowCount, isLarge) = ResolveAggregateSettings(conn, runId, labName);

            using (var cmd = new SqlCommand("dbo.usp_RefreshAllPredictionAggregates", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = timeoutSeconds
            })
            {
                cmd.Parameters.AddWithValue("@RunId", runId);
                cmd.Parameters.AddWithValue("@WeekStartDate",
                    (object?)weekStartDate?.Date ?? DBNull.Value);
                cmd.Parameters.AddWithValue("@LabName", labName);
                cmd.Parameters.AddWithValue("@ChunkSize", chunkSize);
                AppLogger.LogDb(
                    $"[{labName}] Aggregate refresh rows≈{rowCount:N0}, largeLab={isLarge} " +
                    $"(threshold={_largeLabRowThreshold:N0}), ChunkSize={chunkSize}, Timeout={timeoutSeconds}s. " +
                    "Chunking loads WorkingBase only — aggregate counts/results identical to single-pass.");
                cmd.ExecuteNonQuery();
            }

            // Always attempt SP enrich after aggregates (idempotent; no-op if LRNMaster unreachable).
            try
            {
                using var enrichCmd = new SqlCommand("dbo.usp_EnrichPV_DenialDescriptionFromMaster", conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 300
                };
                enrichCmd.ExecuteNonQuery();
                AppLogger.LogDb($"[{labName}] usp_EnrichPV_DenialDescriptionFromMaster completed.");
            }
            catch (SqlException sqlEx) when (
                sqlEx.Number is 2812 or 208 or 229 or 4060) // missing SP / object / permission / DB
            {
                AppLogger.LogDbWarn(
                    $"[{labName}] usp_EnrichPV_DenialDescriptionFromMaster skipped: {sqlEx.Message}");
            }
            catch (Exception enrichSpEx)
            {
                AppLogger.LogDbWarn(
                    $"[{labName}] usp_EnrichPV_DenialDescriptionFromMaster failed (non-fatal): {enrichSpEx.Message}");
            }

            sw.Stop();
            AppLogger.LogDb(
                $"[{labName}] Aggregate snapshot refresh complete in {sw.Elapsed.TotalSeconds:F1}s.");
        }
        catch (Exception ex)
        {
            // Never block the prediction pipeline because aggregate refresh failed.
            AppLogger.LogDbError(
                $"[{labName}] Aggregate snapshot refresh failed (dashboard will fall back to live SPs)", ex);
        }

        // Cross-server enrich (lab DB + LRNMaster may differ) — requires MasterDbConnectionString.
        if (!string.IsNullOrWhiteSpace(masterDbConnectionString)
            && !string.IsNullOrWhiteSpace(_connectionString))
        {
            try
            {
                DenialDescriptionEnricher.EnrichLabAggregates(
                    _connectionString, masterDbConnectionString, labName);
            }
            catch (Exception enrichEx)
            {
                AppLogger.LogDbWarn(
                    $"[{labName}] DenialDescription C# enrich from LRNMaster failed: {enrichEx.Message}");
            }
        }
    }

    /// <summary>
    /// Resolves chunk size + timeout. Large labs (any name) with row count &gt;= threshold
    /// get ChunkSize 100k + 1h timeout unless JSON overrides. Math is unchanged either way.
    /// </summary>
    private (int ChunkSize, int TimeoutSeconds, long RowCount, bool IsLargeLab) ResolveAggregateSettings(
        SqlConnection conn,
        string runId,
        string labName)
    {
        long rowCount = 0;
        try
        {
            using var countCmd = new SqlCommand(
                """
                SELECT COUNT_BIG(1)
                FROM dbo.PayerValidationReport
                WHERE CONVERT(NVARCHAR(100), RunId) = @RunId
                  AND (@LabName IS NULL OR @LabName = N'' OR LabName = @LabName)
                """,
                conn)
            {
                CommandTimeout = 120
            };
            countCmd.Parameters.AddWithValue("@RunId", runId);
            countCmd.Parameters.AddWithValue("@LabName", (object?)labName ?? DBNull.Value);
            var scalar = countCmd.ExecuteScalar();
            if (scalar is not null and not DBNull)
                rowCount = Convert.ToInt64(scalar);
        }
        catch (Exception ex)
        {
            AppLogger.LogDbWarn($"[{labName}] Row-count probe failed (will use defaults): {ex.Message}");
        }

        var isLarge = rowCount >= _largeLabRowThreshold;
        var chunkSize = _configuredAggregateChunkSize > 0
            ? _configuredAggregateChunkSize
            : DefaultAggregateChunkSize; // same WorkingBase path for all labs once 10_* is deployed
        var timeout = _configuredAggregateRefreshTimeoutSeconds > 0
            ? _configuredAggregateRefreshTimeoutSeconds
            : (isLarge ? LargeLabAggregateRefreshTimeoutSeconds : DefaultAggregateRefreshTimeoutSeconds);

        return (chunkSize, timeout, rowCount, isLarge);
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

    /// <summary>
    /// One-time per-file diagnostic logging of unmapped / missing source headers.
    /// Called once before the chunk loop so we do not spam the log per chunk.
    /// </summary>
    private static void LogHeaderDiagnostics(ClaimRecord first, string labName)
    {
        var firstRaw = first.RawColumns;

        var unmappedSourceHeaders = firstRaw.Keys
            .Where(h => !HeaderToColumn.ContainsKey(h))
            .OrderBy(h => h)
            .ToList();

        if (unmappedSourceHeaders.Count > 0)
        {
            AppLogger.LogDbWarn($"[{labName}] {unmappedSourceHeaders.Count} source column(s) have no DB mapping � skipped:");
            foreach (var h in unmappedSourceHeaders)
                AppLogger.LogDbWarn($"[{labName}]   (no mapping) \"{h}\"");
        }

        var missingMappedHeaders = HeaderToColumn.Keys
            .Where(h => !firstRaw.ContainsKey(h))
            .OrderBy(h => h)
            .ToList();

        if (missingMappedHeaders.Count > 0)
        {
            AppLogger.LogDbWarn($"[{labName}] {missingMappedHeaders.Count} expected column(s) not found in source file � will insert NULL:");
            foreach (var h in missingMappedHeaders)
                AppLogger.LogDbWarn($"[{labName}]   (not in file) ? {HeaderToColumn[h]}: \"{h}\"");
        }
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

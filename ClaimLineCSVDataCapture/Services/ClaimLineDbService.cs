using System.Data;
using Microsoft.Data.SqlClient;
using ClaimLineCSVDataCapture.Models;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Persists CSV data to SQL Server using TVP bulk insert.
/// Fully driven by <see cref="FileTypeMapping"/> � no hardcoded column lists.
/// Adding/removing fields only requires a FieldMappings.json change
/// (plus matching SQL TVP/table/SP updates).
/// </summary>
public sealed class ClaimLineDbService
{
    private readonly string _connectionString;

    public ClaimLineDbService(string connectionString)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        _connectionString = connectionString;
    }

    /// <summary>
    /// A representative source file for a RunId, read from this lab database's
    /// <c>dbo.LineClaimFileLogs</c> and used for the LRNMaster report-run log
    /// parameter <c>@SourceFileName</c>.
    /// </summary>
    /// <param name="FileName">The logged CSV file name (may be null if the column is empty).</param>
    /// <param name="FileType">Either <c>claimlevel</c> or <c>linelevel</c>.</param>
    public readonly record struct RunSourceFileInfo(string? FileName, string FileType);

    /// <summary>
    /// Returns one representative source file logged for <paramref name="runId"/>.
    /// <para>
    /// Each report type is built from several tables — Production and Collection
    /// Summary from ClaimLevel, Executive Summary from LIMSMaster + ClaimLevel +
    /// LineLevel — so no single file is "the" source. Any one logged file is
    /// sufficient to identify the run, and a Claim Level file is preferred because it
    /// contributes to all three report types. Falls back to the most recently inserted
    /// row of any type.
    /// </para>
    /// No row count is returned: with multiple contributing tables a single count would
    /// be misleading, so callers send <c>@RowCount = 0</c>.
    /// <para>
    /// Returns <c>null</c> when no file-log row exists for the RunId (for example when
    /// the external ingestion app has not yet logged the run).
    /// </para>
    /// </summary>
    public RunSourceFileInfo? GetSourceFileForRun(string runId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(runId);

        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        using var cmd = new SqlCommand(
            """
            SELECT TOP 1 FileName, FileType
            FROM   dbo.LineClaimFileLogs
            WHERE  RunId = @RunId
            ORDER  BY CASE WHEN FileType = 'claimlevel' THEN 0 ELSE 1 END,
                      InsertedDateTime DESC,
                      FileLogId DESC
            """, conn)
        { CommandTimeout = 60 };

        cmd.Parameters.AddWithValue("@RunId", runId);

        using var reader = cmd.ExecuteReader();
        if (!reader.Read())
            return null;

        return new RunSourceFileInfo(
            reader.IsDBNull(0) ? null : reader.GetString(0),
            reader.IsDBNull(1) ? string.Empty : reader.GetString(1));
    }

    /// <summary>
    /// Returns the latest <c>SourceFullPath</c> from <c>LineClaimFileLogs</c>
    /// for the given lab and file type, or null if no rows exist.
    /// </summary>
    public string? GetLatestSourcePath(string labName, string fileType)
    {
        using var conn = new SqlConnection(_connectionString);
        conn.Open();
        using var cmd = new SqlCommand(
            """
            SELECT TOP 1 SourceFullPath
            FROM   dbo.LineClaimFileLogs
            WHERE  LabName = @LabName AND FileType = @FileType
            ORDER  BY InsertedDateTime DESC
            """, conn);
        cmd.Parameters.AddWithValue("@LabName", labName);
        cmd.Parameters.AddWithValue("@FileType", fileType);
        var result = cmd.ExecuteScalar();
        return result is DBNull or null ? null : (string)result;
    }

    /// <summary>
    /// Streams CSV batches directly into a single DataTable, then sends all rows
    /// to the stored procedure in one TVP call. The SP expects all rows at once
    /// because it logs the file in <c>LineClaimFileLogs</c> on entry and skips
    /// subsequent calls for the same RunId.
    /// Streaming avoids holding the intermediate <see cref="CsvDataRow"/> list;
    /// each batch is appended to the DataTable and then released.
    /// </summary>
    public int StreamingInsert(
        IEnumerable<List<CsvDataRow>> batches, string labName, string weekFolder,
        FileTypeMapping mapping, string sourceFilePath, Action<int, int>? onBatchLoaded = null)
    {
        ArgumentNullException.ThrowIfNull(batches);
        ArgumentNullException.ThrowIfNull(mapping);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceFilePath);

        var runId       = ExtractRunId(sourceFilePath);
        var fileName    = Path.GetFileName(sourceFilePath);
        var fileCreated = File.Exists(sourceFilePath)
                          ? (object)File.GetCreationTime(sourceFilePath)
                          : DBNull.Value;

        // Build DataTable schema once, then stream batches into it
        var dt = CreateTvpSchema(mapping);
        int totalRows = 0;
        int batchNumber = 0;

        foreach (var batch in batches)
        {
            if (batch.Count == 0) continue;
            batchNumber++;

            AppendBatchToTvp(dt, batch, mapping);
            totalRows += batch.Count;

            onBatchLoaded?.Invoke(batchNumber, batch.Count);
        }

        if (totalRows == 0) return 0;

        // Single SP call with all rows � the SP handles internal chunked inserts
        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        using var cmd = new SqlCommand(mapping.SprocName, conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 1200
        };

        cmd.Parameters.Add(new SqlParameter("@Rows", SqlDbType.Structured)
        {
            TypeName = mapping.TvpTypeName,
            Value    = dt,
        });
        cmd.Parameters.AddWithValue("@LabName",        labName);
        cmd.Parameters.AddWithValue("@WeekFolder",     weekFolder);
        cmd.Parameters.AddWithValue("@SourceFilePath", sourceFilePath);
        cmd.Parameters.AddWithValue("@RunId",          runId);
        cmd.Parameters.AddWithValue("@FileName",       fileName);
        cmd.Parameters.Add(new SqlParameter("@FileCreatedDateTime", SqlDbType.DateTime)
        {
            Value = fileCreated
        });

        var result = cmd.ExecuteScalar();
        int insertedCount = result is not null and not DBNull
            ? Convert.ToInt32(result)
            : 0;

        return insertedCount;
    }

    /// <summary>
    /// Bulk-inserts rows via the stored procedure specified in the mapping.
    /// Builds the TVP dynamically from the field mapping configuration.
    /// Returns the number of rows inserted (0 = skipped/already loaded).
    /// </summary>
    public int InsertRows(List<CsvDataRow> rows, string labName, string weekFolder, FileTypeMapping mapping)
    {
        if (rows.Count == 0) return 0;
        ArgumentNullException.ThrowIfNull(mapping);

        var sourceFilePath = rows[0].SourceFullPath;
        return StreamingInsert([rows], labName, weekFolder, mapping, sourceFilePath);
    }

    /// <summary>
    /// Creates an empty DataTable with the TVP column schema.
    /// </summary>
    private static DataTable CreateTvpSchema(FileTypeMapping mapping)
    {
        var dt = new DataTable();

        // System columns (always present in every TVP)
        dt.Columns.Add("FileLogId");
        dt.Columns.Add("RunId");
        dt.Columns.Add("WeekFolder");
        dt.Columns.Add("SourceFullPath");
        dt.Columns.Add("FileName");
        dt.Columns.Add("FileType");
        dt.Columns.Add("RowHash");

        // Dynamic columns from field mapping (order must match TVP definition)
        foreach (var fm in mapping.Fields)
        {
            dt.Columns.Add(fm.SqlColumn);
        }

        return dt;
    }

    /// <summary>
    /// Appends a batch of rows to an existing DataTable.
    /// The batch list can be released by the caller after this returns.
    /// </summary>
    private static void AppendBatchToTvp(DataTable dt, List<CsvDataRow> rows, FileTypeMapping mapping)
    {
        var colCount = 7 + mapping.Fields.Count;

        foreach (var r in rows)
        {
            var values = new object[colCount];
            values[0] = r.FileLogId;
            values[1] = r.RunId;
            values[2] = r.WeekFolder;
            values[3] = r.SourceFullPath;
            values[4] = r.FileName;
            values[5] = r.FileType;
            values[6] = r.RowHash;

            for (int i = 0; i < mapping.Fields.Count; i++)
            {
                values[7 + i] = r.Get(mapping.Fields[i].SqlColumn);
            }

            dt.Rows.Add(values);
        }
    }

    /// <summary>
    /// Strips '.00' decimal suffixes from ClaimID, AccessionNumber, and PatientID
    /// in the ClaimLevelData table. Returns the number of rows affected.
    /// </summary>
    public int CleanClaimLevelDecimalSuffixes()
    {
        const string sql = """
            UPDATE dbo.ClaimLevelData
            SET    ClaimID          = REPLACE(ClaimID, '.00', ''),
                   AccessionNumber  = REPLACE(AccessionNumber, '.00', ''),
                   PatientID        = REPLACE(PatientID, '.00', '')
            WHERE  ClaimID LIKE '%.00'
               OR  AccessionNumber LIKE '%.00'
               OR  PatientID LIKE '%.00'
            """;

        using var conn = new SqlConnection(_connectionString);
        conn.Open();
        using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 600 };
        return cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Strips '.00' decimal suffixes from ClaimID, AccessionNumber, PatientID,
    /// CPTCode, Units, and Modifier in the LineLevelData table.
    /// Returns the number of rows affected.
    /// </summary>
    public int CleanLineLevelDecimalSuffixes()
    {
        const string sql = """
            UPDATE dbo.LineLevelData
            SET    ClaimID          = REPLACE(ClaimID, '.00', ''),
                   AccessionNumber  = REPLACE(AccessionNumber, '.00', ''),
                   PatientID        = REPLACE(PatientID, '.00', ''),
                   CPTCode          = REPLACE(CPTCode, '.00', ''),
                   Units            = REPLACE(Units, '.00', ''),
                   Modifier         = REPLACE(Modifier, '.00', '')
            WHERE  ClaimID LIKE '%.00'
               OR  AccessionNumber LIKE '%.00'
               OR  PatientID LIKE '%.00'
               OR  CPTCode LIKE '%.00'
               OR  Units LIKE '%.00'
               OR  Modifier LIKE '%.00'
            """;

        using var conn = new SqlConnection(_connectionString);
        conn.Open();
        using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 600 };
        return cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Purges all data from <c>ClaimLevelData</c>, <c>LineLevelData</c>, and
    /// <c>LineClaimFileLogs</c> in the lab's own database (each lab has a dedicated DB,
    /// so no <c>LabName</c> filter is needed). Runs inside a single transaction so a
    /// mid-purge failure leaves the tables untouched.
    /// Used exclusively when <c>ClaimLineRefresh = true</c> in the lab config.
    /// </summary>
    /// <returns>A tuple of (claimRows, lineRows, logRows) deleted.</returns>
    public (int ClaimRows, int LineRows, int LogRows) PurgeLabClaimLineData()
    {
        using var conn = new SqlConnection(_connectionString);
        conn.Open();
        using var tx = conn.BeginTransaction();
        try
        {
            int claimRows, lineRows, logRows;

            using (var cmd = new SqlCommand("DELETE FROM dbo.ClaimLevelData", conn, tx)
                   { CommandTimeout = 600 })
                claimRows = cmd.ExecuteNonQuery();

            using (var cmd = new SqlCommand("DELETE FROM dbo.LineLevelData", conn, tx)
                   { CommandTimeout = 600 })
                lineRows = cmd.ExecuteNonQuery();

            using (var cmd = new SqlCommand("DELETE FROM dbo.LineClaimFileLogs", conn, tx)
                   { CommandTimeout = 120 })
                logRows = cmd.ExecuteNonQuery();

            tx.Commit();
            return (claimRows, lineRows, logRows);
        }
        catch
        {
            tx.Rollback();
            throw;
        }
    }

    /// <summary>
    /// Refreshes all Revenue Dashboard aggregate tables by calling
    /// <c>dbo.usp_RefreshDashboard</c>. The SP runs inside a single transaction,
    /// populates DashboardKPISummary, DashboardClaimStatusBreakdown,
    /// DashboardInsightBreakdown, DashboardMonthlyTrends, DashboardTopCPT,
    /// DashboardPayStatusBreakdown, DashboardPanelMonthlyAllowed, and
    /// DashboardPayerTypePayments, and logs execution to DashboardRefreshLog.
    /// Call this after both ClaimLevel and LineLevel ingestion are complete.
    /// </summary>
    public void RefreshDashboard()
    {
        using var conn = new SqlConnection(_connectionString);
        conn.Open();
        using var cmd = new SqlCommand("dbo.usp_RefreshDashboard", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 1800
        };
        cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// Runs all NorthWest-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshNorthWestProductionReports()
    {
        // All seven NorthWest production-report SPs in execution order.
        string[] procedures =
        [
            "dbo.usp_RefreshNW_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshNW_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshNW_PayerBreakdown",
            "dbo.usp_RefreshNW_PayerByPanel",
            "dbo.usp_RefreshNW_UnbilledAging",
            "dbo.usp_RefreshNW_CPTBreakdown",
            "dbo.usp_RefreshNW_CodingBreakdown_Unbilled",
            "dbo.usp_RefreshNW_PanelBreakdown",
            "dbo.usp_RefreshNW_InsightBreakdown",
            "dbo.usp_RefreshNW_HighestPayerBreakdown",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>
    /// Runs all Elixir Labs-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshElixirProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshElix_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshElix_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshElix_PayerBreakdown",
            "dbo.usp_RefreshElix_PayerByPanel",
            "dbo.usp_RefreshElix_UnbilledAging",
            "dbo.usp_RefreshElix_CPTBreakdown",
            "dbo.usp_RefreshElix_CodingBreakdown_Unbilled",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>
    /// Runs all PCRLabsofAmerica-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshPCRLabsProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshPCR_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshPCR_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshPCR_PayerBreakdown",
            "dbo.usp_RefreshPCR_PayerByPanel",
            "dbo.usp_RefreshPCR_CodingBreakdown_Billed",
            "dbo.usp_RefreshPCR_UnbilledAging",
            "dbo.usp_RefreshPCR_CPTBreakdown",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>
    /// Runs all BeechTree-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshBeechTreeProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshBT_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshBT_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshBT_PayerBreakdown",
            "dbo.usp_RefreshBT_PayerByPanel",
            "dbo.usp_RefreshBT_CodingBreakdown_Billed",
            "dbo.usp_RefreshBT_UnbilledAging",
            "dbo.usp_RefreshBT_CPTBreakdown",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>
    /// Runs all RisingTides-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshRisingTidesProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshRT_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshRT_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshRT_PayerBreakdown",
            "dbo.usp_RefreshRT_PayerByPanel",
            "dbo.usp_RefreshRT_CodingBreakdown_Billed",
            "dbo.usp_RefreshRT_UnbilledAging",
            "dbo.usp_RefreshRT_CPTBreakdown",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>
    /// Runs all RisingTides-specific Collection Summary aggregate stored procedures
    /// after ingestion. Pre-computes the data behind the 13 Collection Summary tabs
    /// (Top 5 Reimbursement %/$, Monthly/Weekly Volume, Panel Averages, AvgPayments,
    /// Insurance vs Aging, Panel vs Payment, Rep vs Payment, Insurance vs Payment %,
    /// CPT vs Payment %, Status Summary, Provider Summary).
    /// Each SP runs independently so a failure in one does not block the others.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshRisingTidesCollectionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshRT_CS_Top5ReimbursementPct",
            "dbo.usp_RefreshRT_CS_Top5ReimbursementPay",
            "dbo.usp_RefreshRT_CS_MonthlyClaimVolume",
            "dbo.usp_RefreshRT_CS_WeeklyClaimVolume",
            "dbo.usp_RefreshRT_CS_PanelAverages",
            "dbo.usp_RefreshRT_CS_AvgPayments",
            "dbo.usp_RefreshRT_CS_InsuranceVsAging",
            "dbo.usp_RefreshRT_CS_PanelVsPayment",
            "dbo.usp_RefreshRT_CS_RepVsPayment",
            "dbo.usp_RefreshRT_CS_InsuranceVsPaymentPct",
            "dbo.usp_RefreshRT_CS_CptVsPaymentPct",
            "dbo.usp_RefreshRT_CS_StatusSummary",
            "dbo.usp_RefreshRT_CS_ProviderSummary",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>
    /// Runs all Certus Labs-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshCertusProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshCert_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshCert_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshCert_PayerBreakdown",
            "dbo.usp_RefreshCert_PayerByPanel",
            "dbo.usp_RefreshCert_UnbilledAging",
            "dbo.usp_RefreshCert_CPTBreakdown",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>
    /// Runs all COVE Labs-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshCoveProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshCove_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshCove_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshCove_PayerBreakdown",
            "dbo.usp_RefreshCove_PayerByPanel",
            "dbo.usp_RefreshCove_UnbilledAging",
            "dbo.usp_RefreshCove_CPTBreakdown",
            "dbo.usp_RefreshCove_CodingBreakdown_Unbilled",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>
    /// Runs all Augustus Labs-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshAugustusProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshAug_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshAug_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshAug_PayerBreakdown",
            "dbo.usp_RefreshAug_PayerByPanel",
            "dbo.usp_RefreshAug_UnbilledAging",
            "dbo.usp_RefreshAug_CPTBreakdown",
            "dbo.usp_RefreshAug_CodingBreakdown_Unbilled",
        ];

        return RunProductionReportSPs(procedures);
    }

    // ??? Collection Summary aggregate refreshers (one set of 13 SPs per lab) ??
    // Each method runs the 13 RefreshXxx_CS_* SPs that pre-compute the data
    // behind the Collection Summary tabs in the LabMetricsDashboard web app.
    // SPs run independently � one failure does not block the others.

    /// <summary>
    /// Runs all PhiLife-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshPhiLifeProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshPhi_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshPhi_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshPhi_PayerBreakdown",
            "dbo.usp_RefreshPhi_PayerByPanel",
            "dbo.usp_RefreshPhi_CodingBreakdown_Billed",
            "dbo.usp_RefreshPhi_UnbilledAging",
            "dbo.usp_RefreshPhi_CPTBreakdown",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>Refreshes the PhiLife Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshPhiLifeCollectionReports()
        => RunProductionReportSPs(BuildCollectionSummarySpList("Phi"));

    /// <summary>
    /// Maps a LabSettings "LabName" key to the SP-name prefix used by
    /// <see cref="RefreshExecutiveSummaryByPrefix"/> to build
    /// "dbo.usp_Refresh{prefix}_ExecutiveSummary[_LIS_Alt]". Keep aligned with
    /// LabMetricsDashboard's ExecutiveSummaryController.LabPrefixMap /
    /// PhiExecutiveSummaryController.LabPrefixMap.
    /// </summary>
    public static readonly Dictionary<string, string> LabPrefixMap =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["RisingTides"]      = "RT",
            ["Rising_Tides"]     = "RT",
            ["Phi_Life"]         = "Phi",
            ["PhiLife"]          = "Phi",
            ["Augustus"]         = "Aug",
            ["Augustus_Labs"]    = "Aug",
            ["Augustus_LRN"]     = "Aug",
            ["Certus"]           = "Cert",
            ["Certus_LRN"]       = "Cert",
            ["CertusLabs"]       = "Cert",
            ["Certus_Labs"]      = "Cert",
            ["CERT"]             = "Cert",
            ["Cert"]             = "Cert",
            ["Cove"]             = "Cove",
            ["CoveLRN"]          = "Cove",
            ["Elixir"]           = "Elix",
            ["Elixir_LRN"]       = "Elix",
            ["NorthWest"]        = "NW",
            ["NWL"]              = "NW",
            ["PCRLabsofAmerica"] = "PCR",
            ["PCRLAPSOfAmerica"] = "PCR",
            ["PCRLOA"]           = "PCR",
            ["Beech_Tree"]       = "BT",
            ["BeechTree"]        = "BT",
            ["Inhealth_DTR"]     = "InH",
            ["InHealthDTR"]      = "InH",
            ["InHealthDTRLRN"]   = "InH",
        };

    /// <summary>
    /// Generic Executive Summary aggregate refresh, driven entirely by the SP
    /// naming convention "dbo.usp_Refresh{prefix}_ExecutiveSummary" and
    /// "dbo.usp_Refresh{prefix}_ExecutiveSummary_LIS_Alt" (the latter
    /// independently truncates/repopulates the LIS rows + B.&lt;PanelName&gt;
    /// sub-rows from dbo.LIMSMaster — the two SPs share no tables, so their
    /// relative order doesn't matter).
    ///
    /// Either SP is silently skipped (not run, not reported as an error) if it
    /// hasn't been deployed yet for this lab's prefix — onboarding a new lab's
    /// Executive Summary is then just: deploy the matching SQL scripts using
    /// this prefix (see <see cref="LabPrefixMap"/>), no code changes required.
    ///
    /// Called by ClaimLineCSVDataCapture after ClaimLevel ingestion completes.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging —
    /// empty if neither SP exists yet for this prefix.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshExecutiveSummaryByPrefix(string prefix)
    {
        string[] candidates =
        [
            $"dbo.usp_Refresh{prefix}_ExecutiveSummary",
            $"dbo.usp_Refresh{prefix}_ExecutiveSummary_LIS_Alt",
        ];

        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        var procedures = candidates.Where(sp => StoredProcedureExists(conn, sp)).ToArray();
        if (procedures.Length == 0)
            return [];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>Returns true if the given (optionally schema-qualified) stored procedure exists.</summary>
    private static bool StoredProcedureExists(SqlConnection conn, string spName)
    {
        using var cmd = new SqlCommand("SELECT OBJECT_ID(@name, 'P')", conn);
        cmd.Parameters.AddWithValue("@name", spName);
        var result = cmd.ExecuteScalar();
        return result is not null && result != DBNull.Value;
    }

    /// <summary>Refreshes the Augustus Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshAugustusCollectionReports()
        => RunProductionReportSPs(BuildCollectionSummarySpList("Aug"));

    /// <summary>
    /// Executes <c>dbo.usp_Create_CollectionClaimLevelData</c> to build (or rebuild)
    /// the <c>CollectionClaimLevelData</c> staging table from <c>LineLevelData</c>.
    /// <para>
    /// Must be called for the <b>Augustus</b> lab only, after both ClaimLevel and
    /// LineLevel ingestion are complete and <b>before</b> the Production Report and
    /// Collection Summary aggregate SPs run — this table is the source for the
    /// Augustus Collection Summary Report.
    /// </para>
    /// The SP takes no parameters and manages its own table lifecycle internally
    /// (drops and recreates <c>CollectionClaimLevelData</c> on every run).
    /// </summary>
    /// <returns>
    /// A tuple of (<c>ElapsedMs</c>, <c>Error</c>) where <c>Error</c> is <c>null</c>
    /// on success or contains the exception message on failure.
    /// </returns>
    public (long ElapsedMs, string? Error) CreateCollectionClaimLevelData()
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();
            using var cmd = new SqlCommand("dbo.usp_Create_CollectionClaimLevelData", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 1800
            };
            cmd.ExecuteNonQuery();
            sw.Stop();
            return (sw.ElapsedMilliseconds, null);
        }
        catch (Exception ex)
        {
            sw.Stop();
            return (sw.ElapsedMilliseconds, ex.Message);
        }
    }

    /// <summary>Refreshes the BeechTree Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshBeechTreeCollectionReports()
        => RunProductionReportSPs(BuildCollectionSummarySpList("BT"));

    /// <summary>
    /// Returns true if the given filename has already been logged in
    /// <c>dbo.BTTransactionDetailFileLogs</c>, meaning that file was
    /// already fully imported and should be skipped this run.
    /// </summary>
    public bool IsBTTransactionDetailFileAlreadyLoaded(string fileName)
    {
        using var conn = new SqlConnection(_connectionString);
        conn.Open();
        using var cmd = new SqlCommand(
            "SELECT TOP 1 1 FROM dbo.BTTransactionDetailFileLogs WHERE FileName = @FileName",
            conn);
        cmd.Parameters.AddWithValue("@FileName", fileName);
        var result = cmd.ExecuteScalar();
        return result is not null && result != DBNull.Value;
    }

    /// <summary>
    /// Rebuilds <c>dbo.BTWOSummary</c> by executing <c>dbo.usp_RefreshBT_WOSummary</c>.
    /// The SP joins <c>dbo.BTTransactionDetailData</c> (VisitNumber) with
    /// <c>dbo.ClaimLevelData</c> (ClaimID) on DateofService, groups by
    /// TransactionCode / TransactionCodeDesc / DateofService, and inserts the
    /// MatchingCount aggregates into <c>dbo.BTWOSummary</c>.
    /// Called after every new TransactionDetail Adjustment XLSX is imported.
    /// Returns (TotalRows, MatchedRows) from the SP's output row.
    /// </summary>
    public (int TotalRows, int MatchedRows, string? Error) RefreshBTWOSummary()
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();
            using var cmd = new SqlCommand("dbo.usp_RefreshBT_WOSummary", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 1800
            };
            using var reader = cmd.ExecuteReader();
            int totalRows   = 0;
            int matchedRows = 0;
            if (reader.Read())
            {
                totalRows   = reader.IsDBNull(0) ? 0 : reader.GetInt32(0);
                matchedRows = reader.IsDBNull(1) ? 0 : reader.GetInt32(1);
            }
            sw.Stop();
            return (totalRows, matchedRows, null);
        }
        catch (Exception ex)
        {
            sw.Stop();
            return (0, 0, ex.Message);
        }
    }

    /// <summary>
    /// Executes <c>dbo.usp_RefreshBT_ExecutiveSummary_OnNewFile</c>, which only
    /// rebuilds <c>BTWOSummary</c> and the Executive Summary when a NEW
    /// TransactionDetail Adjustment file (per <c>BTTransactionDetailFileLogs</c>)
    /// has not yet been refreshed. Used in the TransactionDetail-only path when
    /// the RunId gate skips Claim/Line processing.
    /// </summary>
    /// <param name="fileName">
    /// Optional file name to gate on. When null, the SP auto-detects the newest
    /// unprocessed TransactionDetail Adjustment file.
    /// </param>
    /// <returns>null on success; the error message on failure.</returns>
    public string? RefreshBTExecutiveSummaryOnNewFile(string? fileName = null)
    {
        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();
            using var cmd = new SqlCommand("dbo.usp_RefreshBT_ExecutiveSummary_OnNewFile", conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 1800
            };
            if (string.IsNullOrWhiteSpace(fileName))
                cmd.Parameters.AddWithValue("@FileName", DBNull.Value);
            else
                cmd.Parameters.AddWithValue("@FileName", fileName);

            cmd.ExecuteNonQuery();
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    /// <summary>
    /// Clears <c>dbo.BTTransactionDetailData</c> so a newly loaded TransactionDetail
    /// Adjustment file fully REPLACES prior rows (the file is a full snapshot, not a
    /// delta). Uses TRUNCATE for speed and falls back to DELETE if the login lacks
    /// ALTER/TRUNCATE rights. The file-dedup log (<c>BTTransactionDetailFileLogs</c>)
    /// is intentionally left intact so already-loaded files are still skipped.
    /// </summary>
    /// <returns>null on success; the error message on failure.</returns>
    public string? ClearBTTransactionDetailData()
    {
        try
        {
            using var conn = new SqlConnection(_connectionString);
            conn.Open();
            try
            {
                using var t = new SqlCommand("TRUNCATE TABLE dbo.BTTransactionDetailData", conn)
                {
                    CommandTimeout = 600
                };
                t.ExecuteNonQuery();
            }
            catch
            {
                // Fallback when the login lacks ALTER/TRUNCATE rights on the table.
                using var d = new SqlCommand("DELETE FROM dbo.BTTransactionDetailData", conn)
                {
                    CommandTimeout = 1200
                };
                d.ExecuteNonQuery();
            }
            return null;
        }
        catch (Exception ex)
        {
            return ex.Message;
        }
    }

    /// <summary>Refreshes the Certus Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshCertusCollectionReports()
        => RunProductionReportSPs(BuildCollectionSummarySpList("Cert"));

    /// <summary>Refreshes the COVE Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshCoveCollectionReports()
        => RunProductionReportSPs(BuildCollectionSummarySpList("Cove"));

    /// <summary>Refreshes the Elixir Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshElixirCollectionReports()
        => RunProductionReportSPs(BuildCollectionSummarySpList("Elix"));

    /// <summary>Refreshes the NorthWest Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshNorthWestCollectionReports()
        => RunProductionReportSPs([
            ..BuildCollectionSummarySpList("NW"),
            "dbo.usp_RefreshNW_CS_InsuranceVsPayment",
        ]);

    /// <summary>Refreshes the PCRLabsofAmerica Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshPCRLabsCollectionReports()
        => RunProductionReportSPs(BuildCollectionSummarySpList("PCR"));

    /// <summary>
    /// Runs all InHealthDTR-specific production report stored procedures after ingestion.
    /// Each SP is executed independently so a failure in one does not block the others.
    /// Returns a list of (SpName, ElapsedMs, ErrorMessage?) for caller logging.
    /// </summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshInHealthDTRProductionReports()
    {
        string[] procedures =
        [
            "dbo.usp_RefreshInH_MonthlyBilledProductionSummary",
            "dbo.usp_RefreshInH_WeeklyBilledProductionSummary",
            "dbo.usp_RefreshInH_PayerBreakdown",
            "dbo.usp_RefreshInH_PayerByPanel",
            "dbo.usp_RefreshInH_CodingBreakdown_Billed",
            "dbo.usp_RefreshInH_UnbilledAging",
            "dbo.usp_RefreshInH_CPTBreakdown",
        ];

        return RunProductionReportSPs(procedures);
    }

    /// <summary>Refreshes the InHealthDTR Collection Summary aggregates.</summary>
    public List<(string SpName, long ElapsedMs, string? Error)> RefreshInHealthDTRCollectionReports()
        => RunProductionReportSPs(BuildCollectionSummarySpList("IHD"));

    /// <summary>
    /// Builds the standard 13-element ordered list of Collection Summary SP names
    /// for a given lab prefix (e.g. "Aug", "BT", "Cert", ...). Keeps every lab's
    /// invocation in lockstep with the SQL files that ship under Sql\&lt;Lab&gt;.
    /// </summary>
    private static string[] BuildCollectionSummarySpList(string prefix) =>
    [
        $"dbo.usp_Refresh{prefix}_CS_Top5ReimbursementPct",
        $"dbo.usp_Refresh{prefix}_CS_Top5ReimbursementPay",
        $"dbo.usp_Refresh{prefix}_CS_MonthlyClaimVolume",
        $"dbo.usp_Refresh{prefix}_CS_WeeklyClaimVolume",
        $"dbo.usp_Refresh{prefix}_CS_PanelAverages",
        $"dbo.usp_Refresh{prefix}_CS_AvgPayments",
        $"dbo.usp_Refresh{prefix}_CS_InsuranceVsAging",
        $"dbo.usp_Refresh{prefix}_CS_PanelVsPayment",
        $"dbo.usp_Refresh{prefix}_CS_RepVsPayment",
        $"dbo.usp_Refresh{prefix}_CS_InsuranceVsPaymentPct",
        $"dbo.usp_Refresh{prefix}_CS_CptVsPaymentPct",
        $"dbo.usp_Refresh{prefix}_CS_StatusSummary",
        $"dbo.usp_Refresh{prefix}_CS_ProviderSummary",
    ];

    /// <summary>
    /// Executes a list of stored procedures sequentially on an open connection.
    /// Each SP runs independently � a failure in one does not stop the others.
    /// </summary>
    private List<(string SpName, long ElapsedMs, string? Error)> RunProductionReportSPs(
        string[] procedures)
    {
        var results = new List<(string, long, string?)>();

        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        foreach (var spName in procedures)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                using var cmd = new SqlCommand(spName, conn)
                {
                    CommandType    = CommandType.StoredProcedure,
                    CommandTimeout = 1800
                };
                cmd.ExecuteNonQuery();
                sw.Stop();
                results.Add((spName, sw.ElapsedMilliseconds, null));
            }
            catch (Exception ex)
            {
                sw.Stop();
                results.Add((spName, sw.ElapsedMilliseconds, ex.Message));
            }
        }

        return results;
    }

    /// <summary>
    /// Extracts RunId from a file path by taking the prefix before the first underscore
    /// in the filename (e.g., "20260226R0029_Cove_Claim Level_...csv" ? "20260226R0029").
    /// Falls back to the full filename without extension if no underscore is found or on error.
    /// </summary>
    internal static string ExtractRunId(string filePath)
    {
        var fileNameWithoutExt = Path.GetFileNameWithoutExtension(filePath);
        if (string.IsNullOrWhiteSpace(fileNameWithoutExt))
            return fileNameWithoutExt ?? string.Empty;

        var underscoreIndex = fileNameWithoutExt.IndexOf('_');
        return underscoreIndex > 0
            ? fileNameWithoutExt[..underscoreIndex]
            : fileNameWithoutExt;
    }

    /// <summary>
    /// Fetches the latest successfully completed RunId for a lab by executing
    /// <c>sp_GetRecentSuccessRunByLab</c> against the LRNMaster database.
    /// </summary>
    /// <param name="masterConnectionString">
    /// The LRNMaster connection string (appsettings <c>ConnectionStrings:DefaultConnection</c>).
    /// </param>
    /// <param name="labName">
    /// The lab name passed as the <c>@LabName</c> parameter — sourced from the lab config
    /// key <c>FetchLatestCompletedRunIDParameter</c> (e.g. "PCR Labs of America").
    /// </param>
    /// <returns>
    /// The latest completed RunId (e.g. "20260522R0118"), or <c>null</c> when the SP returns
    /// no row / a NULL value.
    /// </returns>
    public static string? GetRecentSuccessRunByLab(string masterConnectionString, string labName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(masterConnectionString);
        ArgumentException.ThrowIfNullOrWhiteSpace(labName);

        using var conn = new SqlConnection(masterConnectionString);
        conn.Open();

        using var cmd = new SqlCommand("dbo.sp_GetRecentSuccessRunByLab", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 60
        };
        cmd.Parameters.AddWithValue("@LabName", labName);

        var result = cmd.ExecuteScalar();
        return result is DBNull or null ? null : result.ToString();
    }
}

using System.Data;
using Microsoft.Data.SqlClient;
using ClaimLineCSVDataCapture.Models;

namespace ClaimLineCSVDataCapture.Services;

/// <summary>
/// Persists CSV data to SQL Server using TVP bulk insert.
/// Fully driven by <see cref="FileTypeMapping"/> — no hardcoded column lists.
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

        // Single SP call with all rows — the SP handles internal chunked inserts
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

    /// <summary>
    /// Executes a list of stored procedures sequentially on an open connection.
    /// Each SP runs independently — a failure in one does not stop the others.
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
}

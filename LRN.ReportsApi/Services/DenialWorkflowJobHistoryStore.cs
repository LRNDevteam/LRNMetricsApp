using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

/// <summary>
/// Durable per-user history of download (export) and upload jobs, stored in LRNMaster so it
/// survives app restarts. The export/upload job services keep their in-memory state for live
/// status, but persist every terminal state here so the Jobs Center (dropdown + Uploads &amp;
/// Downloads page) still shows a user's past jobs after they log out and back in. All writes are
/// best-effort: a DB hiccup must never break the in-memory upload/download flow.
/// </summary>
public sealed record JobHistoryRecord(
    string JobId, string JobType, string RequestedBy, int LabId, string FileName,
    string Status, string Message, int? RowCount, int? SuccessCount, int? FailureCount,
    string? FilePath, string? ContentType, DateTime CreatedOnUtc, DateTime? CompletedOnUtc);

public interface IDenialWorkflowJobHistoryStore
{
    void Save(JobHistoryRecord record);
    IReadOnlyList<JobHistoryRecord> List(string requestedBy, string jobType);
    JobHistoryRecord? Get(string jobId);
}

public sealed class DenialWorkflowJobHistoryStore : IDenialWorkflowJobHistoryStore
{
    private readonly string _connectionString;
    private readonly ILogger<DenialWorkflowJobHistoryStore> _logger;
    private int _ensured;

    public DenialWorkflowJobHistoryStore(IConfiguration configuration, ILogger<DenialWorkflowJobHistoryStore> logger)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection") ?? string.Empty;
        _logger = logger;
    }

    private const string EnsureSql = @"
IF OBJECT_ID('dbo.DenialWorkflowJobHistory','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialWorkflowJobHistory(
        JobId varchar(64) NOT NULL CONSTRAINT PK_DenialWorkflowJobHistory PRIMARY KEY,
        JobType varchar(20) NOT NULL,
        RequestedBy nvarchar(256) NOT NULL,
        LabId int NOT NULL,
        FileName nvarchar(400) NULL,
        Status varchar(40) NOT NULL,
        Message nvarchar(1000) NULL,
        [RowCount] int NULL,
        SuccessCount int NULL,
        FailureCount int NULL,
        FilePath nvarchar(1000) NULL,
        ContentType nvarchar(200) NULL,
        CreatedOnUtc datetime2 NOT NULL,
        CompletedOnUtc datetime2 NULL
    );
    CREATE INDEX IX_DWFJobHistory_User ON dbo.DenialWorkflowJobHistory(RequestedBy, JobType, CreatedOnUtc DESC);
END";

    private const string UpsertSql = @"
MERGE dbo.DenialWorkflowJobHistory AS t
USING (SELECT @JobId AS JobId) AS s ON t.JobId = s.JobId
WHEN MATCHED THEN UPDATE SET
    Status=@Status, Message=@Message, [RowCount]=@RowCount, SuccessCount=@SuccessCount,
    FailureCount=@FailureCount, FilePath=@FilePath, ContentType=@ContentType,
    CompletedOnUtc=@CompletedOnUtc, FileName=@FileName
WHEN NOT MATCHED THEN INSERT
    (JobId,JobType,RequestedBy,LabId,FileName,Status,Message,[RowCount],SuccessCount,FailureCount,FilePath,ContentType,CreatedOnUtc,CompletedOnUtc)
    VALUES (@JobId,@JobType,@RequestedBy,@LabId,@FileName,@Status,@Message,@RowCount,@SuccessCount,@FailureCount,@FilePath,@ContentType,@CreatedOnUtc,@CompletedOnUtc);";

    private const string ListSql = @"
SELECT TOP (100) JobId,JobType,RequestedBy,LabId,FileName,Status,Message,[RowCount],SuccessCount,FailureCount,FilePath,ContentType,CreatedOnUtc,CompletedOnUtc
FROM dbo.DenialWorkflowJobHistory WITH (NOLOCK)
WHERE JobType=@JobType AND (RequestedBy=@RequestedBy OR @RequestedBy='')
ORDER BY CreatedOnUtc DESC;";

    private const string GetSql = @"
SELECT TOP (1) JobId,JobType,RequestedBy,LabId,FileName,Status,Message,[RowCount],SuccessCount,FailureCount,FilePath,ContentType,CreatedOnUtc,CompletedOnUtc
FROM dbo.DenialWorkflowJobHistory WITH (NOLOCK)
WHERE JobId=@JobId;";

    private bool Available() => !string.IsNullOrWhiteSpace(_connectionString);

    private void EnsureTable(SqlConnection con)
    {
        if (Interlocked.CompareExchange(ref _ensured, 1, 0) == 1) return;
        try
        {
            using var cmd = new SqlCommand(EnsureSql, con) { CommandTimeout = 60 };
            cmd.ExecuteNonQuery();
        }
        catch (Exception ex)
        {
            _ensured = 0;
            _logger.LogWarning(ex, "Could not ensure DenialWorkflowJobHistory table.");
        }
    }

    public void Save(JobHistoryRecord r)
    {
        if (!Available()) return;
        try
        {
            using var con = new SqlConnection(_connectionString);
            con.Open();
            EnsureTable(con);
            using var cmd = new SqlCommand(UpsertSql, con) { CommandTimeout = 60 };
            cmd.Parameters.AddWithValue("@JobId", r.JobId);
            cmd.Parameters.AddWithValue("@JobType", r.JobType);
            cmd.Parameters.AddWithValue("@RequestedBy", (object?)r.RequestedBy ?? string.Empty);
            cmd.Parameters.AddWithValue("@LabId", r.LabId);
            cmd.Parameters.AddWithValue("@FileName", (object?)r.FileName ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@Status", r.Status ?? string.Empty);
            cmd.Parameters.AddWithValue("@Message", (object?)r.Message ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@RowCount", (object?)r.RowCount ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@SuccessCount", (object?)r.SuccessCount ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@FailureCount", (object?)r.FailureCount ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@FilePath", (object?)r.FilePath ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@ContentType", (object?)r.ContentType ?? DBNull.Value);
            cmd.Parameters.AddWithValue("@CreatedOnUtc", r.CreatedOnUtc);
            cmd.Parameters.AddWithValue("@CompletedOnUtc", (object?)r.CompletedOnUtc ?? DBNull.Value);
            cmd.ExecuteNonQuery();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not persist job history for {JobId}.", r.JobId);
        }
    }

    public IReadOnlyList<JobHistoryRecord> List(string requestedBy, string jobType)
    {
        var rows = new List<JobHistoryRecord>();
        if (!Available()) return rows;
        try
        {
            using var con = new SqlConnection(_connectionString);
            con.Open();
            EnsureTable(con);
            using var cmd = new SqlCommand(ListSql, con) { CommandTimeout = 60 };
            cmd.Parameters.AddWithValue("@RequestedBy", requestedBy ?? string.Empty);
            cmd.Parameters.AddWithValue("@JobType", jobType);
            using var rd = cmd.ExecuteReader();
            while (rd.Read()) rows.Add(ReadRecord(rd));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not read job history for {User}.", requestedBy);
        }
        return rows;
    }

    public JobHistoryRecord? Get(string jobId)
    {
        if (!Available() || string.IsNullOrWhiteSpace(jobId)) return null;
        try
        {
            using var con = new SqlConnection(_connectionString);
            con.Open();
            EnsureTable(con);
            using var cmd = new SqlCommand(GetSql, con) { CommandTimeout = 60 };
            cmd.Parameters.AddWithValue("@JobId", jobId);
            using var rd = cmd.ExecuteReader();
            return rd.Read() ? ReadRecord(rd) : null;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not read job history record {JobId}.", jobId);
            return null;
        }
    }

    private static JobHistoryRecord ReadRecord(SqlDataReader rd)
    {
        int? NullableInt(string name) => rd[name] == DBNull.Value ? null : Convert.ToInt32(rd[name]);
        string? NullableStr(string name) => rd[name] == DBNull.Value ? null : Convert.ToString(rd[name]);
        DateTime? NullableDate(string name) => rd[name] == DBNull.Value ? null : Convert.ToDateTime(rd[name]);
        return new JobHistoryRecord(
            Convert.ToString(rd["JobId"]) ?? string.Empty,
            Convert.ToString(rd["JobType"]) ?? string.Empty,
            Convert.ToString(rd["RequestedBy"]) ?? string.Empty,
            Convert.ToInt32(rd["LabId"]),
            NullableStr("FileName") ?? string.Empty,
            Convert.ToString(rd["Status"]) ?? string.Empty,
            NullableStr("Message") ?? string.Empty,
            NullableInt("RowCount"), NullableInt("SuccessCount"), NullableInt("FailureCount"),
            NullableStr("FilePath"), NullableStr("ContentType"),
            Convert.ToDateTime(rd["CreatedOnUtc"]),
            NullableDate("CompletedOnUtc"));
    }
}

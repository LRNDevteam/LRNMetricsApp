using LabMetricsDashboard.Models.DenialWorkflow;
using Microsoft.Data.SqlClient;
using System.Data;
using System.Text.Json;

namespace LabMetricsDashboard.Services.DenialWorkflow;

public sealed class SqlDenialWorkflowRepository : IDenialWorkflowRepository
{
    private const string AdminRole = "Admin";
    private const string ArManagerRole = "AR Manager";
    private const string ArReviewerRole = "AR Reviewer";

    private readonly IConfiguration _configuration;
    private readonly IDenialRecordRepository _denialRepository;

    public SqlDenialWorkflowRepository(IConfiguration configuration, IDenialRecordRepository denialRepository)
    {
        _configuration = configuration;
        _denialRepository = denialRepository;
    }

    public async Task<DenialWorkflowCounts> GetDashboardCountsAsync(int labId, string role, string userName, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
        var where = BuildRoleWhere(role, userName, "t");
        var verificationWhere = BuildVerificationRoleWhere(role, userName, "v");

        var sql = $@"
SELECT
    Assigned = SUM(CASE WHEN ISNULL(NULLIF(LTRIM(RTRIM(t.AssignedTo)), ''), '') <> '' AND ISNULL(t.Status, '') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END),
    Completed = SUM(CASE WHEN ISNULL(t.Status, '') IN ('Closed','Completed') THEN 1 ELSE 0 END),
    Pending = SUM(CASE WHEN ISNULL(t.Status, '') IN ('New','Pending Review','In-Progress') THEN 1 ELSE 0 END),
    Unassigned = SUM(CASE WHEN ISNULL(NULLIF(LTRIM(RTRIM(t.AssignedTo)), ''), '') = '' AND ISNULL(t.Status, '') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END)
FROM dbo.DenialTaskBoard t
WHERE ISNULL(t.LabId, @LabId) = @LabId {where};

SELECT VerificationPending = COUNT(1)
FROM dbo.DenialVerificationTask v
WHERE ISNULL(v.LabId, @LabId) = @LabId
  AND ISNULL(v.VerificationStatus, 'Verification Pending') IN ('Verification Pending','Duplicate','Pending Review') {verificationWhere};";

        await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 120 };
        command.Parameters.AddWithValue("@LabId", labId);
        AddRoleParameters(command, role, userName);

        var counts = new DenialWorkflowCounts();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (await reader.ReadAsync(cancellationToken))
        {
            counts.Assigned = GetInt(reader, "Assigned");
            counts.Completed = GetInt(reader, "Completed");
            counts.Pending = GetInt(reader, "Pending");
            counts.Unassigned = GetInt(reader, "Unassigned");
        }

        if (await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken))
        {
            counts.VerificationPending = GetInt(reader, "VerificationPending");
        }

        return counts;
    }

    public async Task<IReadOnlyList<WorkflowTaskRow>> GetTaskBoardAsync(int labId, string role, string userName, string? status, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
        var where = BuildRoleWhere(role, userName, "t");
        var statusWhere = string.IsNullOrWhiteSpace(status) ? string.Empty : " AND ISNULL(t.Status, '') = @Status";
        var sql = $@"
SELECT TOP (1000)
    t.TaskID, t.UniqueTrackId, t.ClaimID, t.PatientId, t.CPTCode, t.DenialCode, t.DenialDescription,
    t.ActionCategory, t.RecommendedAction, t.Task, t.Priority, t.InsuranceBalance, t.Status,
    t.DateOpened, t.DueDate, t.DateCompleted, t.SLAStatus, t.AssignedTo, t.PayerName,
    t.PayerNameNormalized, t.ReviewerComments, t.ReviewerUpdatedBy, t.ReviewerUpdatedOn,
    t.LabId, t.LabName, t.RunId
FROM dbo.DenialTaskBoard t
WHERE ISNULL(t.LabId, @LabId) = @LabId {where} {statusWhere}
ORDER BY CASE WHEN ISNULL(t.AssignedTo,'') = '' THEN 0 ELSE 1 END, t.DueDate, t.TaskID;";

        await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 120 };
        command.Parameters.AddWithValue("@LabId", labId);
        if (!string.IsNullOrWhiteSpace(status)) command.Parameters.AddWithValue("@Status", status.Trim());
        AddRoleParameters(command, role, userName);
        var rows = new List<WorkflowTaskRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) rows.Add(MapTask(reader));
        return rows;
    }

    public async Task<IReadOnlyList<VerificationTaskRow>> GetVerificationTasksAsync(int labId, string role, string userName, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenLabConnectionAsync(labId, cancellationToken);
        var where = BuildVerificationRoleWhere(role, userName, "v");
        var sql = $@"
SELECT TOP (1000)
    v.VerificationId, v.TaskID, v.UniqueTrackId, v.ClaimID, v.PatientId, v.CPTCode, v.DenialCode,
    v.DenialDescription, v.ActionCategory, v.RecommendedAction, v.Task, v.Priority, v.InsuranceBalance,
    v.Status, v.DateOpened, v.DueDate, v.DateCompleted, v.SLAStatus, v.AssignedTo, v.PayerName,
    v.PayerNameNormalized, v.ReviewerComments, v.ReviewerUpdatedBy, v.ReviewerUpdatedOn,
    v.LabId, v.LabName, v.RunId, v.VerificationStatus, v.VerificationComments,
    v.OriginalRunId, v.MissingDetectedRunId, v.MovedOn, v.VerifiedBy, v.VerifiedOn
FROM dbo.DenialVerificationTask v
WHERE ISNULL(v.LabId, @LabId) = @LabId {where}
ORDER BY v.MovedOn DESC, v.TaskID;";

        await using var command = new SqlCommand(sql, connection) { CommandType = CommandType.Text, CommandTimeout = 120 };
        command.Parameters.AddWithValue("@LabId", labId);
        AddRoleParameters(command, role, userName);
        var rows = new List<VerificationTaskRow>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) rows.Add(MapVerification(reader));
        return rows;
    }

    public async Task<DenialWorkflowResult> AssignTasksAsync(AssignInsightRequest request, string actionBy, CancellationToken cancellationToken = default)
    {
        if (request.TaskIds.Count == 0) return new DenialWorkflowResult { Success = false, Message = "No task selected." };
        await using var connection = await OpenLabConnectionAsync(request.LabId, cancellationToken);
        await using var tx = await connection.BeginTransactionAsync(cancellationToken);
        try
        {
            var affected = 0;
            foreach (var taskId in request.TaskIds.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var before = await ReadTaskSnapshotAsync(connection, (SqlTransaction)tx, taskId, request.LabId, cancellationToken);
                const string updateSql = @"
UPDATE dbo.DenialTaskBoard
SET AssignedTo = @AssignedTo,
    Status = CASE WHEN ISNULL(Status, '') IN ('', 'New') THEN 'Pending Review' ELSE Status END,
    ReviewerUpdatedBy = @ActionBy,
    ReviewerUpdatedOn = SYSUTCDATETIME()
WHERE LabId = @LabId AND TaskID = @TaskID;";
                await using var cmd = new SqlCommand(updateSql, connection, (SqlTransaction)tx) { CommandTimeout = 120 };
                cmd.Parameters.AddWithValue("@AssignedTo", request.ReviewerUserName.Trim());
                cmd.Parameters.AddWithValue("@ActionBy", actionBy);
                cmd.Parameters.AddWithValue("@LabId", request.LabId);
                cmd.Parameters.AddWithValue("@TaskID", taskId.Trim());
                affected += await cmd.ExecuteNonQueryAsync(cancellationToken);
                await InsertHistoryAsync(connection, (SqlTransaction)tx, request.LabId, taskId, "Assigned", before, request.ReviewerUserName, actionBy, request.RunId, cancellationToken);
            }
            await tx.CommitAsync(cancellationToken);
            return new DenialWorkflowResult { Success = true, RowsAffected = affected, Message = $"Assigned {affected} task(s)." };
        }
        catch
        {
            await tx.RollbackAsync(cancellationToken);
            throw;
        }
    }

    public async Task<DenialWorkflowResult> UpdateTaskStatusAsync(UpdateTaskRequest request, string actionBy, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenLabConnectionAsync(request.LabId, cancellationToken);
        await using var tx = await connection.BeginTransactionAsync(cancellationToken);
        try
        {
            var before = await ReadTaskSnapshotAsync(connection, (SqlTransaction)tx, request.TaskID, request.LabId, cancellationToken);
            var isDuplicate = request.Status.Equals("Duplicate", StringComparison.OrdinalIgnoreCase);
            if (isDuplicate)
            {
                await MoveTaskToVerificationAsync(connection, (SqlTransaction)tx, request.LabId, request.TaskID, "Duplicate", request.Comments, actionBy, request.RunId, cancellationToken);
                await tx.CommitAsync(cancellationToken);
                return new DenialWorkflowResult { Success = true, RowsAffected = 1, Message = "Task moved to verification as duplicate." };
            }

            const string updateSql = @"
UPDATE dbo.DenialTaskBoard
SET Status = @Status,
    ReviewerComments = NULLIF(@Comments, ''),
    ReviewerUpdatedBy = @ActionBy,
    ReviewerUpdatedOn = SYSUTCDATETIME(),
    DateCompleted = CASE WHEN @Status IN ('Closed','Completed') THEN CONVERT(date, GETDATE()) ELSE DateCompleted END
WHERE LabId = @LabId AND TaskID = @TaskID;";
            await using var cmd = new SqlCommand(updateSql, connection, (SqlTransaction)tx) { CommandTimeout = 120 };
            cmd.Parameters.AddWithValue("@Status", request.Status.Trim());
            cmd.Parameters.AddWithValue("@Comments", request.Comments?.Trim() ?? string.Empty);
            cmd.Parameters.AddWithValue("@ActionBy", actionBy);
            cmd.Parameters.AddWithValue("@LabId", request.LabId);
            cmd.Parameters.AddWithValue("@TaskID", request.TaskID.Trim());
            var affected = await cmd.ExecuteNonQueryAsync(cancellationToken);

            await ApplyClaimLevelActionIfNeededAsync(connection, (SqlTransaction)tx, request.LabId, request.TaskID, request.Status, request.Comments, actionBy, cancellationToken);
            await InsertHistoryAsync(connection, (SqlTransaction)tx, request.LabId, request.TaskID, "StatusChanged", before, request.Status, actionBy, request.RunId, cancellationToken);
            await tx.CommitAsync(cancellationToken);
            return new DenialWorkflowResult { Success = true, RowsAffected = affected, Message = "Task updated." };
        }
        catch
        {
            await tx.RollbackAsync(cancellationToken);
            throw;
        }
    }

    public async Task<DenialWorkflowResult> DecideVerificationAsync(VerificationDecisionRequest request, string actionBy, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenLabConnectionAsync(request.LabId, cancellationToken);
        await using var tx = await connection.BeginTransactionAsync(cancellationToken);
        try
        {
            var verification = await ReadVerificationSnapshotAsync(connection, (SqlTransaction)tx, request.VerificationId, request.LabId, cancellationToken);
            if (verification is null) return new DenialWorkflowResult { Success = false, Message = "Verification task not found." };

            if (request.IsValidDenial)
            {
                await InsertBackToTaskBoardAsync(connection, (SqlTransaction)tx, verification, request.Status, request.VerificationComments, actionBy, cancellationToken);
                await InsertHistoryAsync(connection, (SqlTransaction)tx, request.LabId, verification.TaskID, "VerifiedValid", JsonSerializer.Serialize(verification), request.Status, actionBy, verification.RunId, cancellationToken);
            }
            else
            {
                await InsertHistoryAsync(connection, (SqlTransaction)tx, request.LabId, verification.TaskID, "VerifiedInvalid", JsonSerializer.Serialize(verification), request.Status, actionBy, verification.RunId, cancellationToken);
            }

            const string closeSql = @"
UPDATE dbo.DenialVerificationTask
SET VerificationStatus = @Status,
    VerificationComments = @Comments,
    VerifiedBy = @ActionBy,
    VerifiedOn = SYSUTCDATETIME()
WHERE LabId = @LabId AND VerificationId = @VerificationId;
DELETE FROM dbo.DenialVerificationTask WHERE LabId = @LabId AND VerificationId = @VerificationId;";
            await using var cmd = new SqlCommand(closeSql, connection, (SqlTransaction)tx) { CommandTimeout = 120 };
            cmd.Parameters.AddWithValue("@Status", request.IsValidDenial ? "Valid Denial" : string.IsNullOrWhiteSpace(request.Status) ? "Closed" : request.Status.Trim());
            cmd.Parameters.AddWithValue("@Comments", request.VerificationComments?.Trim() ?? string.Empty);
            cmd.Parameters.AddWithValue("@ActionBy", actionBy);
            cmd.Parameters.AddWithValue("@LabId", request.LabId);
            cmd.Parameters.AddWithValue("@VerificationId", request.VerificationId);
            var affected = await cmd.ExecuteNonQueryAsync(cancellationToken);
            await tx.CommitAsync(cancellationToken);
            return new DenialWorkflowResult { Success = true, RowsAffected = affected, Message = request.IsValidDenial ? "Moved back to task board." : "Moved to history only." };
        }
        catch
        {
            await tx.RollbackAsync(cancellationToken);
            throw;
        }
    }

    private async Task<SqlConnection> OpenLabConnectionAsync(int labId, CancellationToken cancellationToken)
    {
        var lab = (await _denialRepository.GetLabsAsync(cancellationToken)).FirstOrDefault(x => x.LabId == labId)
            ?? throw new InvalidOperationException($"LabId {labId} was not found.");
        if (string.IsNullOrWhiteSpace(lab.ConnectionKey)) throw new InvalidOperationException($"Lab '{lab.LabName}' does not have ConnectionKey.");
        var cs = _configuration.GetConnectionString(lab.ConnectionKey);
        if (string.IsNullOrWhiteSpace(cs)) throw new InvalidOperationException($"Connection string '{lab.ConnectionKey}' not found.");
        var connection = new SqlConnection(cs);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }

    private static bool IsManagerRole(string role) => role.Equals(AdminRole, StringComparison.OrdinalIgnoreCase) || role.Equals(ArManagerRole, StringComparison.OrdinalIgnoreCase) || role.Equals("ARManager", StringComparison.OrdinalIgnoreCase);
    private static bool IsReviewerRole(string role) => role.Equals(ArReviewerRole, StringComparison.OrdinalIgnoreCase) || role.Equals("ARReviewer", StringComparison.OrdinalIgnoreCase) || role.Equals("AR Analyser", StringComparison.OrdinalIgnoreCase) || role.Equals("ARAnalyser", StringComparison.OrdinalIgnoreCase) || role.Equals("AR Analyzer", StringComparison.OrdinalIgnoreCase) || role.Equals("ARAnalyzer", StringComparison.OrdinalIgnoreCase);
    private static string BuildRoleWhere(string role, string userName, string alias) => IsManagerRole(role) ? string.Empty : IsReviewerRole(role) ? $" AND ISNULL({alias}.AssignedTo, '') = @UserName" : " AND 1 = 0";
    private static string BuildVerificationRoleWhere(string role, string userName, string alias) => BuildRoleWhere(role, userName, alias);
    private static void AddRoleParameters(SqlCommand cmd, string role, string userName) { if (!IsManagerRole(role)) cmd.Parameters.AddWithValue("@UserName", userName ?? string.Empty); }

    private static WorkflowTaskRow MapTask(SqlDataReader r) => new()
    {
        TaskID = GetString(r, "TaskID"), UniqueTrackId = GetString(r, "UniqueTrackId"), ClaimID = GetString(r, "ClaimID"), PatientId = GetString(r, "PatientId"), CPTCode = GetString(r, "CPTCode"), DenialCode = GetString(r, "DenialCode"), DenialDescription = GetString(r, "DenialDescription"), ActionCategory = GetString(r, "ActionCategory"), RecommendedAction = GetString(r, "RecommendedAction"), Task = GetString(r, "Task"), Priority = GetString(r, "Priority"), InsuranceBalance = GetDecimal(r, "InsuranceBalance"), Status = GetString(r, "Status"), DateOpened = GetDate(r, "DateOpened"), DueDate = GetDate(r, "DueDate"), DateCompleted = GetDate(r, "DateCompleted"), SLAStatus = GetString(r, "SLAStatus"), AssignedTo = GetString(r, "AssignedTo"), PayerName = GetString(r, "PayerName"), PayerNameNormalized = GetString(r, "PayerNameNormalized"), ReviewerComments = GetString(r, "ReviewerComments"), ReviewerUpdatedBy = GetString(r, "ReviewerUpdatedBy"), ReviewerUpdatedOn = GetDate(r, "ReviewerUpdatedOn"), LabId = GetInt(r, "LabId"), LabName = GetString(r, "LabName"), RunId = GetString(r, "RunId")
    };
    private static VerificationTaskRow MapVerification(SqlDataReader r) { var t = MapTask(r); return new VerificationTaskRow { VerificationId = GetLong(r, "VerificationId"), TaskID = t.TaskID, UniqueTrackId = t.UniqueTrackId, ClaimID = t.ClaimID, PatientId = t.PatientId, CPTCode = t.CPTCode, DenialCode = t.DenialCode, DenialDescription = t.DenialDescription, ActionCategory = t.ActionCategory, RecommendedAction = t.RecommendedAction, Task = t.Task, Priority = t.Priority, InsuranceBalance = t.InsuranceBalance, Status = t.Status, DateOpened = t.DateOpened, DueDate = t.DueDate, DateCompleted = t.DateCompleted, SLAStatus = t.SLAStatus, AssignedTo = t.AssignedTo, PayerName = t.PayerName, PayerNameNormalized = t.PayerNameNormalized, ReviewerComments = t.ReviewerComments, ReviewerUpdatedBy = t.ReviewerUpdatedBy, ReviewerUpdatedOn = t.ReviewerUpdatedOn, LabId = t.LabId, LabName = t.LabName, RunId = t.RunId, VerificationStatus = GetString(r, "VerificationStatus"), VerificationComments = GetString(r, "VerificationComments"), OriginalRunId = GetString(r, "OriginalRunId"), MissingDetectedRunId = GetString(r, "MissingDetectedRunId"), MovedOn = GetDate(r, "MovedOn"), VerifiedBy = GetString(r, "VerifiedBy"), VerifiedOn = GetDate(r, "VerifiedOn") }; }
    private static string GetString(IDataRecord r, string n) => r[n] == DBNull.Value ? string.Empty : Convert.ToString(r[n]) ?? string.Empty;
    private static int GetInt(IDataRecord r, string n) => r[n] == DBNull.Value ? 0 : Convert.ToInt32(r[n]);
    private static long GetLong(IDataRecord r, string n) => r[n] == DBNull.Value ? 0L : Convert.ToInt64(r[n]);
    private static decimal GetDecimal(IDataRecord r, string n) => r[n] == DBNull.Value ? 0m : Convert.ToDecimal(r[n]);
    private static DateTime? GetDate(IDataRecord r, string n) => r[n] == DBNull.Value ? null : Convert.ToDateTime(r[n]);

    private static async Task<string> ReadTaskSnapshotAsync(SqlConnection c, SqlTransaction tx, string taskId, int labId, CancellationToken ct)
    {
        const string sql = "SELECT TOP 1 * FROM dbo.DenialTaskBoard WHERE LabId=@LabId AND TaskID=@TaskID FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;";
        await using var cmd = new SqlCommand(sql, c, tx);
        cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@TaskID", taskId);
        return Convert.ToString(await cmd.ExecuteScalarAsync(ct)) ?? string.Empty;
    }

    private static async Task InsertHistoryAsync(SqlConnection c, SqlTransaction tx, int labId, string taskId, string actionType, string oldValue, string newValue, string actionBy, string? runId, CancellationToken ct)
    {
        const string sql = @"
INSERT INTO dbo.DenialTaskHistory (TaskID, UniqueTrackId, ActionType, OldStatus, NewStatus, Comments, ActionBy, ActionDate, RunId, SnapshotJson, LabId)
SELECT TOP 1 TaskID, UniqueTrackId, @ActionType, Status, @NewValue, @NewValue, @ActionBy, SYSUTCDATETIME(), COALESCE(@RunId, RunId), @SnapshotJson, @LabId
FROM dbo.DenialTaskBoard WHERE LabId=@LabId AND TaskID=@TaskID;";
        await using var cmd = new SqlCommand(sql, c, tx);
        cmd.Parameters.AddWithValue("@ActionType", actionType); cmd.Parameters.AddWithValue("@NewValue", newValue ?? string.Empty); cmd.Parameters.AddWithValue("@ActionBy", actionBy); cmd.Parameters.AddWithValue("@RunId", (object?)runId ?? DBNull.Value); cmd.Parameters.AddWithValue("@SnapshotJson", oldValue ?? string.Empty); cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@TaskID", taskId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task MoveTaskToVerificationAsync(SqlConnection c, SqlTransaction tx, int labId, string taskId, string reasonStatus, string comments, string actionBy, string? runId, CancellationToken ct)
    {
        const string sql = @"
INSERT INTO dbo.DenialVerificationTask
(TaskID, UniqueTrackId, ClaimID, PatientId, CPTCode, DenialCode, DenialDescription, ActionCategory, RecommendedAction, Task, Priority, InsuranceBalance, Status, DateOpened, DueDate, DateCompleted, SLAStatus, AssignedTo, PayerName, PayerNameNormalized, ReviewerComments, ReviewerUpdatedBy, ReviewerUpdatedOn, LabId, LabName, RunId, VerificationStatus, VerificationComments, OriginalRunId, MissingDetectedRunId, MovedOn)
SELECT TaskID, UniqueTrackId, ClaimID, PatientId, CPTCode, DenialCode, DenialDescription, ActionCategory, RecommendedAction, Task, Priority, InsuranceBalance, @Status, DateOpened, DueDate, DateCompleted, SLAStatus, AssignedTo, PayerName, PayerNameNormalized, ReviewerComments, @ActionBy, SYSUTCDATETIME(), LabId, LabName, RunId, @Status, @Comments, RunId, @RunId, SYSUTCDATETIME()
FROM dbo.DenialTaskBoard WHERE LabId=@LabId AND TaskID=@TaskID;
DELETE FROM dbo.DenialTaskBoard WHERE LabId=@LabId AND TaskID=@TaskID;";
        await using var cmd = new SqlCommand(sql, c, tx);
        cmd.Parameters.AddWithValue("@Status", reasonStatus); cmd.Parameters.AddWithValue("@Comments", comments ?? string.Empty); cmd.Parameters.AddWithValue("@ActionBy", actionBy); cmd.Parameters.AddWithValue("@RunId", (object?)runId ?? DBNull.Value); cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@TaskID", taskId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task ApplyClaimLevelActionIfNeededAsync(SqlConnection c, SqlTransaction tx, int labId, string taskId, string status, string comments, string actionBy, CancellationToken ct)
    {
        const string sql = @"
DECLARE @ClaimID nvarchar(100), @ActionCategory nvarchar(500);
SELECT @ClaimID = ClaimID, @ActionCategory = ActionCategory FROM dbo.DenialTaskBoard WHERE LabId=@LabId AND TaskID=@TaskID;
IF EXISTS (SELECT 1 FROM dbo.DenialActionCategoryMaster WHERE ActionCategory=@ActionCategory AND ActionScope='ClaimLevel' AND IsActive=1)
BEGIN
    UPDATE dbo.DenialTaskBoard
       SET Status=@Status, ReviewerComments=NULLIF(@Comments,''), ReviewerUpdatedBy=@ActionBy, ReviewerUpdatedOn=SYSUTCDATETIME(),
           DateCompleted = CASE WHEN @Status IN ('Closed','Completed') THEN CONVERT(date, GETDATE()) ELSE DateCompleted END
     WHERE LabId=@LabId AND ClaimID=@ClaimID AND TaskID<>@TaskID;
END";
        await using var cmd = new SqlCommand(sql, c, tx);
        cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@TaskID", taskId); cmd.Parameters.AddWithValue("@Status", status); cmd.Parameters.AddWithValue("@Comments", comments ?? string.Empty); cmd.Parameters.AddWithValue("@ActionBy", actionBy);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task<VerificationTaskRow?> ReadVerificationSnapshotAsync(SqlConnection c, SqlTransaction tx, long verificationId, int labId, CancellationToken ct)
    {
        const string sql = "SELECT TOP 1 * FROM dbo.DenialVerificationTask WHERE LabId=@LabId AND VerificationId=@VerificationId;";
        await using var cmd = new SqlCommand(sql, c, tx); cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@VerificationId", verificationId);
        await using var r = await cmd.ExecuteReaderAsync(ct); return await r.ReadAsync(ct) ? MapVerification(r) : null;
    }

    private static async Task InsertBackToTaskBoardAsync(SqlConnection c, SqlTransaction tx, VerificationTaskRow v, string status, string comments, string actionBy, CancellationToken ct)
    {
        const string sql = @"
INSERT INTO dbo.DenialTaskBoard
(TaskID, ClaimID, PatientId, CPTCode, DenialCode, DenialDescription, DenialClassification, ActionCode, RecommendedAction, ActionCategory, Task, Priority, InsuranceBalance, IsCurrentDenial, SLADays, Status, DateOpened, DueDate, DateCompleted, DaysRemaining, SLAStatus, AssignedTo, LabId, LabName, RunId, CreatedOn, UniqueTrackId, PayerName, PayerNameNormalized, ReviewerComments, ReviewerUpdatedOn, ReviewerUpdatedBy)
SELECT TaskID, ClaimID, PatientId, CPTCode, DenialCode, DenialDescription, NULL, NULL, RecommendedAction, ActionCategory, Task, Priority, InsuranceBalance, 1, NULL, @Status, COALESCE(DateOpened, CONVERT(date, GETDATE())), DueDate, NULL, NULL, SLAStatus, AssignedTo, LabId, LabName, RunId, SYSUTCDATETIME(), UniqueTrackId, PayerName, PayerNameNormalized, @Comments, SYSUTCDATETIME(), @ActionBy
FROM dbo.DenialVerificationTask WHERE LabId=@LabId AND VerificationId=@VerificationId;";
        await using var cmd = new SqlCommand(sql, c, tx); cmd.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(status) ? "Pending Review" : status); cmd.Parameters.AddWithValue("@Comments", comments ?? string.Empty); cmd.Parameters.AddWithValue("@ActionBy", actionBy); cmd.Parameters.AddWithValue("@LabId", v.LabId); cmd.Parameters.AddWithValue("@VerificationId", v.VerificationId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

	public Task<DenialWorkflowCounts> GetSummaryAsync(
	int labId,
	string role,
	string userName,
	CancellationToken cancellationToken = default)
	{
		return GetDashboardCountsAsync(labId, role, userName, cancellationToken);
	}

	public Task<IReadOnlyList<WorkflowTaskRow>> GetTasksAsync(
		int labId,
		string role,
		string userName,
		int page = 1,
		int pageSize = 100,
		CancellationToken cancellationToken = default)
	{
		return GetTaskBoardAsync(labId, role, userName, null, cancellationToken);
	}

	public Task<IReadOnlyList<VerificationTaskRow>> GetVerificationAsync(
		int labId,
		string role,
		string userName,
		int page = 1,
		int pageSize = 100,
		CancellationToken cancellationToken = default)
	{
		return GetVerificationTasksAsync(labId, role, userName, cancellationToken);
	}

	public Task<DenialWorkflowResult> AssignTasksAsync(
		AssignInsightRequest request,
		CancellationToken cancellationToken = default)
	{
		var actionBy = request.ActionBy
			?? request.AssignedBy
			?? "system";

		return AssignTasksAsync(request, actionBy, cancellationToken);
	}

	public Task<DenialWorkflowResult> UpdateTaskAsync(
		UpdateTaskRequest request,
		CancellationToken cancellationToken = default)
	{
		var actionBy = request.ActionBy
			?? request.UpdatedBy
			?? "system";

		return UpdateTaskStatusAsync(request, actionBy, cancellationToken);
	}

	public Task<DenialWorkflowResult> DecideVerificationAsync(
		VerificationDecisionRequest request,
		CancellationToken cancellationToken = default)
	{
		var actionBy = request.ActionBy
			?? request.UpdatedBy
			?? "system";

		return DecideVerificationAsync(request, actionBy, cancellationToken);
	}
}

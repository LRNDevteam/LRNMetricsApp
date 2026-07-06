using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;
using System;
using System.Data;
using System.Threading;
using System.Threading.Tasks;

public interface IProcessLogRepository
{
    Task<string> NextRunIdAsync(CancellationToken ct);
    Task InsertRunAsync(RunLogRow row, CancellationToken ct);
    Task UpdateRunAsync(RunLogRow row, CancellationToken ct);

    Task UpsertStepAsync(StepLogRow row, CancellationToken ct);
    Task InsertErrorAsync(ErrorLogRow row, CancellationToken ct);

    Task IncrementRunCountAsync(string runId, bool isWarning, CancellationToken ct);
}

public sealed class SqlProcessLogRepository : IProcessLogRepository
{
    private readonly string _connStr;
    private readonly ProcessLogOptions _opt;

    public SqlProcessLogRepository(IConfiguration config, IOptions<ProcessLogOptions> opt)
    {
        _connStr = config.GetConnectionString("DefaultConnection")
                  ?? throw new InvalidOperationException("Missing DefaultConnection connection string.");
        _opt = opt.Value ?? new ProcessLogOptions();
    }

    public async Task<string> NextRunIdAsync(CancellationToken ct)
    {
        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);

        using var cmd = new SqlCommand(_opt.NextRunIdStoredProc, conn)
        {
            CommandType = CommandType.StoredProcedure
        };

        var p = new SqlParameter("@RunId", SqlDbType.VarChar, 30)
        {
            Direction = ParameterDirection.Output
        };
        cmd.Parameters.Add(p);

        await cmd.ExecuteNonQueryAsync(ct);
        return Convert.ToString(p.Value) ?? string.Empty;
    }

    public async Task InsertRunAsync(RunLogRow r, CancellationToken ct)
    {
        if (!_opt.Enabled) return;

        string sql = $@"
INSERT INTO {_opt.RunLogTable}
(
  RunID, LabName, PipelineName, TriggerType, TriggeredBy,
  StartTimeIST, EndTimeIST, DurationSeconds, OverallStatus, LatestMasterFileFound,
  InputMasterSharePointPath, InputMasterFileName, InputMasterFileModifiedTime, InputMasterFileSizeMB,
  MandatoryColumnCheck, SplitOutputWrittenToSharePoint,
  PayerPolicyValidationStatus, CodingValidationStatus, AveragesProcessStatus,
  OutputsCopiedToSharePoint, MasterSyncPerformed, TotalErrors, TotalWarnings, Notes
)
VALUES
(
  @RunID, @LabName, @PipelineName, @TriggerType, @TriggeredBy,
  @StartTimeIST, @EndTimeIST, @DurationSeconds, @OverallStatus, @LatestMasterFileFound,
  @InputMasterSharePointPath, @InputMasterFileName, @InputMasterFileModifiedTime, @InputMasterFileSizeMB,
  @MandatoryColumnCheck, @SplitOutputWrittenToSharePoint,
  @PayerPolicyValidationStatus, @CodingValidationStatus, @AveragesProcessStatus,
  @OutputsCopiedToSharePoint, @MasterSyncPerformed, @TotalErrors, @TotalWarnings, @Notes
);";

        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);

        using var cmd = new SqlCommand(sql, conn);
        AddRunParams(cmd, r);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task UpdateRunAsync(RunLogRow r, CancellationToken ct)
    {
        if (!_opt.Enabled) return;

        string sql = $@"
UPDATE {_opt.RunLogTable}
   SET LabName=@LabName,
       PipelineName=@PipelineName,
       TriggerType=@TriggerType,
       TriggeredBy=@TriggeredBy,
       StartTimeIST=@StartTimeIST,
       EndTimeIST=@EndTimeIST,
       DurationSeconds=@DurationSeconds,
       OverallStatus=@OverallStatus,
       LatestMasterFileFound=@LatestMasterFileFound,
       InputMasterSharePointPath=@InputMasterSharePointPath,
       InputMasterFileName=@InputMasterFileName,
       InputMasterFileModifiedTime=@InputMasterFileModifiedTime,
       InputMasterFileSizeMB=@InputMasterFileSizeMB,
       MandatoryColumnCheck=@MandatoryColumnCheck,
       SplitOutputWrittenToSharePoint=@SplitOutputWrittenToSharePoint,
       PayerPolicyValidationStatus=@PayerPolicyValidationStatus,
       CodingValidationStatus=@CodingValidationStatus,
       AveragesProcessStatus=@AveragesProcessStatus,
       OutputsCopiedToSharePoint=@OutputsCopiedToSharePoint,
       MasterSyncPerformed=@MasterSyncPerformed,
       TotalErrors=@TotalErrors,
       TotalWarnings=@TotalWarnings,
       Notes=@Notes
 WHERE RunID=@RunID;";

        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);
        using var cmd = new SqlCommand(sql, conn);
        AddRunParams(cmd, r);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task UpsertStepAsync(StepLogRow s, CancellationToken ct)
    {
        if (!_opt.Enabled) return;

        string sql = $@"
IF EXISTS (SELECT 1 FROM {_opt.StepLogTable} WHERE RunID=@RunID AND StepSeq=@StepSeq)
BEGIN
    UPDATE {_opt.StepLogTable}
       SET [LabName]=@LabName,
           StepName=@StepName,
           StepCategory=@StepCategory,
           SourceSystem=@SourceSystem,
           StartTimeIST=@StartTimeIST,
           EndTimeIST=@EndTimeIST,
           DurationSeconds=@DurationSeconds,
           Status=@Status,
           RecordsIn=@RecordsIn,
           RecordsOut=@RecordsOut,
           FileNameIn=@FileNameIn,
           FileNameOut=@FileNameOut,
           PathIn=@PathIn,
           PathOut=@PathOut,
           ErrorCode=@ErrorCode,
           ErrorMessage=@ErrorMessage,
           ErrorDetail=@ErrorDetail,
           RetryCount=@RetryCount,
           ExecutedBy=@ExecutedBy,
           Host=@Host,
           ModuleVersion=@ModuleVersion
     WHERE RunID=@RunID AND StepSeq=@StepSeq;
END
ELSE
BEGIN
    INSERT INTO {_opt.StepLogTable}
    (
      RunID, [LabName], StepSeq, StepName, StepCategory, SourceSystem,
      StartTimeIST, EndTimeIST, DurationSeconds, Status,
      RecordsIn, RecordsOut,
      FileNameIn, FileNameOut, PathIn, PathOut,
      ErrorCode, ErrorMessage, ErrorDetail,
      RetryCount, ExecutedBy, Host, ModuleVersion
    )
    VALUES
    (
      @RunID, @LabName, @StepSeq, @StepName, @StepCategory, @SourceSystem,
      @StartTimeIST, @EndTimeIST, @DurationSeconds, @Status,
      @RecordsIn, @RecordsOut,
      @FileNameIn, @FileNameOut, @PathIn, @PathOut,
      @ErrorCode, @ErrorMessage, @ErrorDetail,
      @RetryCount, @ExecutedBy, @Host, @ModuleVersion
    );
END";

        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);
        using var cmd = new SqlCommand(sql, conn);
        AddStepParams(cmd, s);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task InsertErrorAsync(ErrorLogRow e, CancellationToken ct)
    {
        if (!_opt.Enabled) return;

        string sql = $@"
INSERT INTO {_opt.ErrorLogTable}
(
  RunID, LabName, ErrorTimeIST, Severity, StepName, ErrorCode, ErrorSummary,
  MissingColumns, SheetName, FileName, FilePath, RowExample,
  RecommendedAction, OwnerTeam, TicketID, Status
)
VALUES
(
  @RunID, @LabName, @ErrorTimeIST, @Severity, @StepName, @ErrorCode, @ErrorSummary,
  @MissingColumns, @SheetName, @FileName, @FilePath, @RowExample,
  @RecommendedAction, @OwnerTeam, @TicketID, @Status
);";

        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);
        using var cmd = new SqlCommand(sql, conn);
        AddErrorParams(cmd, e);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task IncrementRunCountAsync(string runId, bool isWarning, CancellationToken ct)
    {
        if (!_opt.Enabled) return;

        var col = isWarning ? "TotalWarnings" : "TotalErrors";
        string sql = $"UPDATE {_opt.RunLogTable} SET {col} = ISNULL({col}, 0) + 1 WHERE RunID=@RunID;";

        using var conn = new SqlConnection(_connStr);
        await conn.OpenAsync(ct);
        using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@RunID", runId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static void AddRunParams(SqlCommand cmd, RunLogRow r)
    {
        cmd.Parameters.AddWithValue("@RunID", r.RunID);
        cmd.Parameters.AddWithValue("@LabName", r.LabName);
        cmd.Parameters.AddWithValue("@PipelineName", (object?)r.PipelineName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@TriggerType", (object?)r.TriggerType ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@TriggeredBy", (object?)r.TriggeredBy ?? DBNull.Value);

        cmd.Parameters.AddWithValue("@StartTimeIST", (object?)r.StartTimeIST ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@EndTimeIST", (object?)r.EndTimeIST ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@DurationSeconds", (object?)r.DurationSeconds ?? DBNull.Value);

        cmd.Parameters.AddWithValue("@OverallStatus", (object?)r.OverallStatus ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@LatestMasterFileFound", (object?)r.LatestMasterFileFound ?? DBNull.Value);

        cmd.Parameters.AddWithValue("@InputMasterSharePointPath", (object?)r.InputMasterSharePointPath ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@InputMasterFileName", (object?)r.InputMasterFileName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@InputMasterFileModifiedTime", (object?)r.InputMasterFileModifiedTime ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@InputMasterFileSizeMB", (object?)r.InputMasterFileSizeMB ?? DBNull.Value);

        cmd.Parameters.AddWithValue("@MandatoryColumnCheck", (object?)r.MandatoryColumnCheck ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@SplitOutputWrittenToSharePoint", (object?)r.SplitOutputWrittenToSharePoint ?? DBNull.Value);

        cmd.Parameters.AddWithValue("@PayerPolicyValidationStatus", (object?)r.PayerPolicyValidationStatus ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@CodingValidationStatus", (object?)r.CodingValidationStatus ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@AveragesProcessStatus", (object?)r.AveragesProcessStatus ?? DBNull.Value);

        cmd.Parameters.AddWithValue("@OutputsCopiedToSharePoint", (object?)r.OutputsCopiedToSharePoint ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@MasterSyncPerformed", (object?)r.MasterSyncPerformed ?? DBNull.Value);

        cmd.Parameters.AddWithValue("@TotalErrors", r.TotalErrors);
        cmd.Parameters.AddWithValue("@TotalWarnings", r.TotalWarnings);
        cmd.Parameters.AddWithValue("@Notes", (object?)r.Notes ?? DBNull.Value);
    }

    private static void AddStepParams(SqlCommand cmd, StepLogRow s)
    {
        cmd.Parameters.AddWithValue("@RunID", s.RunID);
        cmd.Parameters.AddWithValue("@LabName", (object?)s.LabName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@StepSeq", s.StepSeq);
        cmd.Parameters.AddWithValue("@StepName", s.StepName);
        cmd.Parameters.AddWithValue("@StepCategory", (object?)s.StepCategory ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@SourceSystem", (object?)s.SourceSystem ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@StartTimeIST", (object?)s.StartTimeIST ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@EndTimeIST", (object?)s.EndTimeIST ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@DurationSeconds", (object?)s.DurationSeconds ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Status", (object?)s.Status ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RecordsIn", (object?)s.RecordsIn ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RecordsOut", (object?)s.RecordsOut ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FileNameIn", (object?)s.FileNameIn ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FileNameOut", (object?)s.FileNameOut ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@PathIn", (object?)s.PathIn ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@PathOut", (object?)s.PathOut ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ErrorCode", (object?)s.ErrorCode ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ErrorMessage", (object?)s.ErrorMessage ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ErrorDetail", (object?)s.ErrorDetail ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RetryCount", (object?)s.RetryCount ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ExecutedBy", (object?)s.ExecutedBy ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Host", (object?)s.Host ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ModuleVersion", (object?)s.ModuleVersion ?? DBNull.Value);
    }

    private static void AddErrorParams(SqlCommand cmd, ErrorLogRow e)
    {
        cmd.Parameters.AddWithValue("@RunID", e.RunID);
        cmd.Parameters.AddWithValue("@LabName", (object?)e.LabName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ErrorTimeIST", e.ErrorTimeIST);
        cmd.Parameters.AddWithValue("@Severity", e.Severity);
        cmd.Parameters.AddWithValue("@StepName", (object?)e.StepName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ErrorCode", (object?)e.ErrorCode ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ErrorSummary", e.ErrorSummary);
        cmd.Parameters.AddWithValue("@MissingColumns", (object?)e.MissingColumns ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@SheetName", (object?)e.SheetName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FileName", (object?)e.FileName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@FilePath", (object?)e.FilePath ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RowExample", (object?)e.RowExample ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RecommendedAction", (object?)e.RecommendedAction ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@OwnerTeam", (object?)e.OwnerTeam ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@TicketID", (object?)e.TicketID ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Status", (object?)e.Status ?? DBNull.Value);
    }
}

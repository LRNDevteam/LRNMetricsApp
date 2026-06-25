using System.Collections.Concurrent;
using System.Data;
using System.Text;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public sealed class SqlDenialWorkflowRepository : IDenialWorkflowRepository
{
    private static readonly ConcurrentDictionary<int, FilterOptionsCacheEntry> FilterOptionsCache = new();
    private static readonly TimeSpan FilterOptionsCacheDuration = TimeSpan.FromSeconds(30);

    // Dashboard cards and summary tables are expensive on large DenialTaskBoard tables.
    // Cache them briefly per lab/filter so navigating between pages does not rescan 300k+ rows each time.
    private static readonly ConcurrentDictionary<string, DashboardCacheEntry> DashboardCache = new();
    private static readonly TimeSpan DashboardCacheDuration = TimeSpan.FromSeconds(90);
    private static readonly ConcurrentDictionary<string, ClaimCountsCacheEntry> ClaimCountsCache = new();
    private static readonly TimeSpan ClaimCountsCacheDuration = TimeSpan.FromSeconds(60);

    private readonly IConfiguration _configuration;
    private readonly string _masterConnectionString;
    private readonly IReadOnlyDictionary<int, string> _labNamesById;
    private readonly IReadOnlyDictionary<int, string> _labConnectionsById;

    public SqlDenialWorkflowRepository(IConfiguration configuration)
    {
        _configuration = configuration;
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");

        var labItems = configuration.GetSection("LabConfig:LabsID").Get<List<LabConfigItem>>() ?? [];
        if (labItems.Count == 0) labItems = DefaultActiveLabs();

        _labNamesById = labItems
            .Where(x => x.Id > 0 && x.IsActive && !string.IsNullOrWhiteSpace(x.Name))
            .GroupBy(x => x.Id)
            .ToDictionary(g => g.Key, g => g.First().Name.Trim());

        _labConnectionsById = labItems
            .Where(x => x.Id > 0 && x.IsActive)
            .GroupBy(x => x.Id)
            .ToDictionary(g => g.Key, g => ResolveLabConnectionString(configuration, g.First().Id, g.First().Name, g.First().ConnectionKey));
    }

    private SqlConnection OpenMaster() => new(_masterConnectionString);

    private SqlConnection OpenLab(int labId)
    {
        if (labId <= 0) throw new InvalidOperationException("LabId is required.");
        if (_labConnectionsById.TryGetValue(labId, out var conn) && !string.IsNullOrWhiteSpace(conn))
            return new SqlConnection(conn);

        throw new InvalidOperationException($"No lab database connection string is configured for LabId {labId}. Add LabConfig:LabsID and a matching ConnectionStrings entry.");
    }


    private static async Task EnsureDenialTaskBoardNormalizedClaimIdAsync(SqlConnection con, CancellationToken ct)
    {
        // Keep this runtime schema helper idempotent. Some SQL Server databases can have
        // auto/user statistics with the same name as the index we want to create. Checking
        // only sys.indexes causes error 1913: "index or statistics with name already exists".
        // This script checks both sys.indexes and sys.stats, and ignores duplicate-object
        // races so dashboard/claim pages do not fail while opening.
        const string sql = @"
IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard','WorkFlowStatus') IS NULL
        ALTER TABLE dbo.DenialTaskBoard ADD WorkFlowStatus nvarchar(100) NULL;

    IF COL_LENGTH('dbo.DenialTaskBoard','ClaimIDNormalized') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialTaskBoard
        ADD ClaimIDNormalized AS CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL([ClaimID],''))), 'CLM-', '')) PERSISTED;
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_ClaimIDNormalized' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DenialTaskBoard_ClaimIDNormalized' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
                CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimIDNormalized ON dbo.DenialTaskBoard (ClaimIDNormalized);
            ELSE IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_ClaimIDNormalized_Auto' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
                CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimIDNormalized_Auto ON dbo.DenialTaskBoard (ClaimIDNormalized);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_TaskView_ClaimIDNormalized' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DenialTaskBoard_TaskView_ClaimIDNormalized' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
                CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_TaskView_ClaimIDNormalized
                ON dbo.DenialTaskBoard (Status, AssignedTo, ClaimIDNormalized)
                INCLUDE (TaskID, UniqueTrackId, CPTCode, SLAStatus, DueDate, InsuranceBalance, DenialCode, DenialClassification, ActionCategory);
            ELSE IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_TaskView_ClaimIDNormalized_Auto' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
                CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_TaskView_ClaimIDNormalized_Auto
                ON dbo.DenialTaskBoard (Status, AssignedTo, ClaimIDNormalized)
                INCLUDE (TaskID, UniqueTrackId, CPTCode, SLAStatus, DueDate, InsuranceBalance, DenialCode, DenialClassification, ActionCategory);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_ClaimAssignment_Status' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DenialTaskBoard_ClaimAssignment_Status' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
                CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimAssignment_Status
                ON dbo.DenialTaskBoard (ClaimIDNormalized)
                INCLUDE (TaskID, Status, AssignedTo, CreatedOn, SLAStatus, UniqueTrackId, RunId);
            ELSE IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_ClaimAssignment_Status_Auto' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
                CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimAssignment_Status_Auto
                ON dbo.DenialTaskBoard (ClaimIDNormalized)
                INCLUDE (TaskID, Status, AssignedTo, CreatedOn, SLAStatus, UniqueTrackId, RunId);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Status_Assigned_Created' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DWF_TaskBoard_Lab_Status_Assigned_Created' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
                CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Status_Assigned_Created
                ON dbo.DenialTaskBoard (LabId, Status, AssignedTo, CreatedOn, ClaimIDNormalized)
                INCLUDE (TaskID, ClaimID, CPTCode, SLAStatus, WorkFlowStatus, InsuranceBalance, DenialCode, DenialClassification, ActionCategory, Priority, PayerName, PanelName, DateOfService);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;

    IF COL_LENGTH('dbo.DenialTaskBoard','ClaimUID') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_ClaimUID_Status' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DWF_TaskBoard_Lab_ClaimUID_Status' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
                CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_ClaimUID_Status
                ON dbo.DenialTaskBoard (LabId, ClaimUID, Status, AssignedTo, CreatedOn)
                INCLUDE (TaskID, ClaimIDNormalized, CPTCode, SLAStatus, WorkFlowStatus, InsuranceBalance, DenialClassification, ActionCategory);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;
END;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialLineItem','AssignedTo') IS NULL
        ALTER TABLE dbo.DenialLineItem ADD AssignedTo nvarchar(255) NULL;

    IF COL_LENGTH('dbo.DenialLineItem','WorkFlowStatus') IS NULL
        ALTER TABLE dbo.DenialLineItem ADD WorkFlowStatus nvarchar(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_VisitNumber_ClaimView' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DenialLineItem_VisitNumber_ClaimView' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
                CREATE NONCLUSTERED INDEX IX_DenialLineItem_VisitNumber_ClaimView
                ON dbo.DenialLineItem (VisitNumber, DateOfService)
                INCLUDE (PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance);
            ELSE IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_VisitNumber_ClaimView_Auto' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
                CREATE NONCLUSTERED INDEX IX_DenialLineItem_VisitNumber_ClaimView_Auto
                ON dbo.DenialLineItem (VisitNumber, DateOfService)
                INCLUDE (PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_ClaimAssignment_Page' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DenialLineItem_ClaimAssignment_Page' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
                CREATE NONCLUSTERED INDEX IX_DenialLineItem_ClaimAssignment_Page
                ON dbo.DenialLineItem (DateOfService DESC, VisitNumber)
                INCLUDE (PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance, DenialCodeNormalized, ActionCategory, DenialClassification);
            ELSE IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_ClaimAssignment_Page_Auto' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
                CREATE NONCLUSTERED INDEX IX_DenialLineItem_ClaimAssignment_Page_Auto
                ON dbo.DenialLineItem (DateOfService DESC, VisitNumber)
                INCLUDE (PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance, DenialCodeNormalized, ActionCategory, DenialClassification);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_LineItem_Lab_DOS_Visit_Page' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DWF_LineItem_Lab_DOS_Visit_Page' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
                CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_DOS_Visit_Page
                ON dbo.DenialLineItem (LabId, DateOfService DESC, VisitNumber)
                INCLUDE (PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance, DenialCodeNormalized, ActionCategory, DenialClassification);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;

    IF COL_LENGTH('dbo.DenialLineItem','ClaimUID') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_LineItem_Lab_ClaimUID_DOS' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DWF_LineItem_Lab_ClaimUID_DOS' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
                CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_ClaimUID_DOS
                ON dbo.DenialLineItem (LabId, ClaimUID, DateOfService DESC)
                INCLUDE (VisitNumber, PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance, DenialCodeNormalized, ActionCategory, DenialClassification);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;
END;

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_Escalations_Lab_Claim_Active' AND object_id = OBJECT_ID('dbo.DenialClaimEscalations'))
    BEGIN
        BEGIN TRY
            IF NOT EXISTS (SELECT 1 FROM sys.stats WHERE name = 'IX_DWF_Escalations_Lab_Claim_Active' AND object_id = OBJECT_ID('dbo.DenialClaimEscalations'))
                CREATE NONCLUSTERED INDEX IX_DWF_Escalations_Lab_Claim_Active
                ON dbo.DenialClaimEscalations (LabId, ClaimId, IsDeleted)
                INCLUDE (Status, EscalatedToRole, EscalatedTo, Comments);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
        END CATCH
    END;
END;";
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        await cmd.ExecuteNonQueryAsync(ct);
    }


    public Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsAsync(CancellationToken ct)
    {
        IReadOnlyList<DenialWorkflowLabOption> rows = _labNamesById
            .OrderBy(x => x.Value)
            .ThenBy(x => x.Key)
            .Select(x => new DenialWorkflowLabOption { LabId = x.Key, LabName = x.Value })
            .ToList();
        return Task.FromResult(rows);
    }

    public async Task<IReadOnlyList<DenialWorkflowLabOption>> GetLabsForUserAsync(string userName, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(userName))
            return await GetLabsAsync(ct);

        const string sql = @"
IF OBJECT_ID('dbo.UserLabs') IS NOT NULL AND OBJECT_ID('dbo.LabUsers') IS NOT NULL
BEGIN
    SELECT DISTINCT CAST(ul.LabId AS int) AS LabId
    FROM dbo.UserLabs ul
    INNER JOIN dbo.LabUsers u ON u.LabUserID = ul.LabUserID
    WHERE ISNULL(u.IsActive,0)=1
      AND (ISNULL(u.UserName,'')=@UserName OR ISNULL(u.Email,'')=@UserName)
    ORDER BY LabId;
END";

        var allowedIds = new HashSet<int>();
        await using var con = OpenMaster();
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@UserName", userName.Trim());
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct))
        {
            var id = GetInt(rd, "LabId");
            if (id > 0) allowedIds.Add(id);
        }

        var allLabs = await GetLabsAsync(ct);
        if (allowedIds.Count == 0) return allLabs;
        return allLabs.Where(x => allowedIds.Contains(x.LabId)).ToList();
    }

    public async Task<DenialWorkflowRunReference?> GetLastRunReferenceAsync(int labId, CancellationToken ct)
    {
        var sql = $@"
SELECT TOP (1)
    RunId,
    OutputFileName
FROM LRNMaster.dbo.DenialAnalysisRunLog
WHERE {LabScopeSql("LabId")}
ORDER BY CreatedOn DESC;";

        await using var con = OpenMaster();
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        AddLabScopeParams(cmd, labId);

        await using var rdr = await cmd.ExecuteReaderAsync(ct);
        if (!await rdr.ReadAsync(ct)) return null;

        var outputFileName = rdr["OutputFileName"] as string ?? string.Empty;
        return new DenialWorkflowRunReference
        {
            RunId = rdr["RunId"] as string ?? string.Empty,
            OutputFileName = outputFileName,
            FileNameWithoutExtension = string.IsNullOrWhiteSpace(outputFileName)
                ? string.Empty
                : Path.GetFileNameWithoutExtension(outputFileName)
        };
    }

    public async Task<DenialWorkflowDashboardSummary> GetDashboardSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        var cacheKey = BuildFilterCacheKey("dashboard", filter);
        if (DashboardCache.TryGetValue(cacheKey, out var cachedDashboard)
            && DateTime.UtcNow - cachedDashboard.CachedOnUtc < DashboardCacheDuration)
        {
            return cachedDashboard.Summary;
        }

        var where = BuildCommonWhere(filter, "t", includeStatus: true, includeAssigned: true);
        await using var con = OpenLab(filter.LabId); await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        var lineColumns = await GetColumnSetAsync(con, "dbo.DenialLineItem", ct);
        static string MoneySql(string columnName) => $"ISNULL(TRY_CONVERT(decimal(18,2), REPLACE(REPLACE(CONVERT(nvarchar(100), d.{columnName}), '$', ''), ',', '')), 0)";
        var billedAmountColumn =
            lineColumns.Contains("BilledAmount") ? "BilledAmount" :
            lineColumns.Contains("BilledCharges") ? "BilledCharges" :
            lineColumns.Contains("TotalCharges") ? "TotalCharges" :
            lineColumns.Contains("InsuranceBalance") ? "InsuranceBalance" :
            string.Empty;
        var billedAmountExpression = string.IsNullOrWhiteSpace(billedAmountColumn) ? "CAST(0 AS decimal(18,2))" : MoneySql(billedAmountColumn);
        var insuranceBalanceExpression = lineColumns.Contains("InsuranceBalance") ? MoneySql("InsuranceBalance") : "CAST(0 AS decimal(18,2))";
        var lineServiceDateExpression = lineColumns.Contains("DateOfService")
            ? "TRY_CONVERT(date, d.DateOfService)"
            : "CAST(NULL AS date)";
        var taskClaimKeyExpression = taskColumns.Contains("ClaimUID")
            ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimUID,''))), ''), LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized, t.ClaimID))))"
            : "LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized, t.ClaimID)))";
        var taskWorkflowStatusExpression = taskColumns.Contains("WorkFlowStatus")
            ? "LTRIM(RTRIM(ISNULL(t.WorkFlowStatus, '')))"
            : "CAST('' AS nvarchar(100))";
        var lineClaimKeyExpression = lineColumns.Contains("ClaimUID")
            ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(d.ClaimUID,''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(d.VisitNumber,''))), 'CLM-', '')))"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(d.VisitNumber,''))), 'CLM-', ''))";
        var taskLabScope = LabScopeSql("t.LabId");
        var lineLabScope = LabScopeSql("d.LabId");
        var sql = $@"
IF OBJECT_ID('tempdb..#TaskBoardBase') IS NOT NULL DROP TABLE #TaskBoardBase;
IF OBJECT_ID('tempdb..#TaskClaims') IS NOT NULL DROP TABLE #TaskClaims;
IF OBJECT_ID('tempdb..#ClaimAmount') IS NOT NULL DROP TABLE #ClaimAmount;

DECLARE @HasTaskLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;
DECLARE @HasLineLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialLineItem WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;

SELECT
    ClaimId = {taskClaimKeyExpression},
    InsuranceBalance = ISNULL(t.InsuranceBalance, 0),
    StatusValue = LTRIM(RTRIM(ISNULL(t.Status, ''))),
    WorkFlowStatusValue = {taskWorkflowStatusExpression},
    DenialClassification = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.DenialClassification, ''))), ''), 'Unclassified'),
    AssignedTo = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo, ''))), ''), 'Unassigned'),
    ActionCategory = LTRIM(RTRIM(ISNULL(t.ActionCategory, ''))),
    DueDate = t.DueDate,
    NormalizedSlaDays = COALESCE(taskSla.NormalizedSlaDays, CASE WHEN t.DateOpened IS NOT NULL AND t.DueDate IS NOT NULL THEN DATEDIFF(day, CAST(t.DateOpened AS date), CAST(t.DueDate AS date)) END)
INTO #TaskBoardBase
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
OUTER APPLY
(
    SELECT RawSlaDays = CONVERT(nvarchar(200), t.SLADays)
) taskRaw
OUTER APPLY
(
    SELECT DigitsOnly = CASE
        WHEN NULLIF(LTRIM(RTRIM(taskRaw.RawSlaDays)), '') IS NULL THEN NULL
        WHEN CHARINDEX(':', taskRaw.RawSlaDays) > 0 THEN LTRIM(SUBSTRING(taskRaw.RawSlaDays, CHARINDEX(':', taskRaw.RawSlaDays) + 1, 32))
        ELSE LTRIM(RTRIM(taskRaw.RawSlaDays))
    END
) taskClean
OUTER APPLY
(
    SELECT NormalizedSlaDays = TRY_CONVERT(int, LEFT(taskClean.DigitsOnly, NULLIF(PATINDEX('%[^0-9]%', ISNULL(taskClean.DigitsOnly,'') + 'X') - 1, -1)))
) taskSla
WHERE (@HasTaskLab = 0 OR {taskLabScope}) {where.WhereClause};

CREATE NONCLUSTERED INDEX IX_TaskBoardBase_Claim ON #TaskBoardBase(ClaimId);

SELECT ClaimId
INTO #TaskClaims
FROM #TaskBoardBase
WHERE NULLIF(ClaimId, '') IS NOT NULL
GROUP BY ClaimId;

CREATE UNIQUE CLUSTERED INDEX IX_TaskClaims_Claim ON #TaskClaims(ClaimId);

SELECT
    ClaimId = {lineClaimKeyExpression},
    BilledAmount = CAST(SUM({billedAmountExpression}) AS decimal(18,2)),
    InsuranceBalance = CAST(SUM({insuranceBalanceExpression}) AS decimal(18,2)),
    AgeDays = MAX(CASE WHEN {lineServiceDateExpression} IS NULL THEN 0 ELSE DATEDIFF(day, {lineServiceDateExpression}, CAST(GETDATE() AS date)) END)
INTO #ClaimAmount
FROM dbo.DenialLineItem d WITH (NOLOCK)
INNER JOIN #TaskClaims tc
  ON tc.ClaimId = {lineClaimKeyExpression}
WHERE (@HasLineLab = 0 OR {lineLabScope})
  AND NULLIF(LTRIM(RTRIM(ISNULL(d.VisitNumber,''))),'') IS NOT NULL
GROUP BY {lineClaimKeyExpression};

CREATE UNIQUE CLUSTERED INDEX IX_ClaimAmount_Claim ON #ClaimAmount(ClaimId);

;WITH ClaimAgg AS
(
    SELECT
        ClaimId,
        OpenTaskCount = SUM(CASE WHEN LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END),
        AssignedActiveTaskCount = SUM(CASE WHEN AssignedTo <> 'Unassigned' AND LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END)
    FROM #TaskBoardBase
    WHERE NULLIF(ClaimId, '') IS NOT NULL
    GROUP BY ClaimId
)
SELECT
    TotalDenials = (SELECT COUNT(1) FROM #TaskBoardBase),
    TotalClaims = COUNT(1),
    OpenClaims = SUM(CASE WHEN OpenTaskCount > 0 THEN 1 ELSE 0 END),
    TotalTasks = (SELECT COUNT(1) FROM #TaskBoardBase),
    AssignedClaims = SUM(CASE WHEN AssignedActiveTaskCount > 0 THEN 1 ELSE 0 END),
    PendingClaims = SUM(CASE WHEN OpenTaskCount > 0 AND AssignedActiveTaskCount = 0 THEN 1 ELSE 0 END),
    ClosedClaims = SUM(CASE WHEN OpenTaskCount = 0 THEN 1 ELSE 0 END),
    EscalatedClaims = (SELECT COUNT(DISTINCT ClaimId) FROM #TaskBoardBase WHERE LOWER(StatusValue) LIKE '%escal%' OR LOWER(WorkFlowStatusValue) LIKE '%escal%'),
    VerificationPending = (SELECT COUNT(DISTINCT ClaimId) FROM #TaskBoardBase WHERE LOWER(StatusValue) LIKE '%verification%' OR LOWER(WorkFlowStatusValue) LIKE '%verification%'),
    OutstandingAmount = (SELECT ISNULL(SUM(InsuranceBalance), 0) FROM #ClaimAmount),
    OpenInProgressCount = (SELECT SUM(CASE WHEN LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END) FROM #TaskBoardBase),
    ClosedCount = (SELECT SUM(CASE WHEN LOWER(StatusValue) IN ('closed', 'completed') THEN 1 ELSE 0 END) FROM #TaskBoardBase)
FROM ClaimAgg;

;WITH ClassClaim AS
(
    SELECT
        ClaimId,
        DenialClassification,
        IsAssigned = MAX(CASE WHEN AssignedTo <> 'Unassigned' AND LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END),
        HasOpen = MAX(CASE WHEN LOWER(StatusValue) IN ('', 'new', 'open', 'pending review', 'verification pending') THEN 1 ELSE 0 END),
        HasInProgress = MAX(CASE WHEN LOWER(StatusValue) IN ('in-progress', 'in progress', 'progress') OR LOWER(StatusValue) LIKE '%progress%' THEN 1 ELSE 0 END),
        IsClosed = CASE WHEN SUM(CASE WHEN LOWER(StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END) = 0 THEN 1 ELSE 0 END
    FROM #TaskBoardBase
    WHERE NULLIF(ClaimId, '') IS NOT NULL
    GROUP BY ClaimId, DenialClassification
), ClassRaw AS
(
    SELECT
        Classification = cc.DenialClassification,
        [Count] = COUNT(1),
        BilledAmount = ISNULL(SUM(ISNULL(ca.BilledAmount, 0)), 0),
        InsuranceBalance = ISNULL(SUM(ISNULL(ca.InsuranceBalance, 0)), 0),
        Outstanding = ISNULL(SUM(ISNULL(ca.InsuranceBalance, 0)), 0),
        Assigned = SUM(cc.IsAssigned),
        [Open] = SUM(cc.HasOpen),
        InProgress = SUM(cc.HasInProgress),
        Closed = SUM(cc.IsClosed)
    FROM ClassClaim cc
    LEFT JOIN #ClaimAmount ca ON ca.ClaimId = cc.ClaimId
    GROUP BY cc.DenialClassification
), Tot AS
(
    SELECT TotalCount = NULLIF(SUM([Count]), 0) FROM ClassRaw
)
SELECT
    Classification,
    [Count],
    BilledAmount,
    InsuranceBalance,
    Outstanding,
    Assigned,
    [Open],
    InProgress,
    Closed,
    PercentageOfTotal = CAST(CASE WHEN Tot.TotalCount IS NULL THEN 0 ELSE ([Count] * 100.0 / Tot.TotalCount) END AS decimal(9,2))
FROM ClassRaw
CROSS JOIN Tot
ORDER BY [Count] DESC, Outstanding DESC;

;WITH ActionClaim AS
(
    SELECT
        ClaimId,
        ActionCategory = COALESCE(NULLIF(ActionCategory, ''), 'Unclassified')
    FROM #TaskBoardBase
    WHERE NULLIF(ClaimId, '') IS NOT NULL
    GROUP BY ClaimId, COALESCE(NULLIF(ActionCategory, ''), 'Unclassified')
), ActionRaw AS
(
    SELECT
        ac.ActionCategory,
        [Count] = COUNT(1),
        BilledAmount = ISNULL(SUM(ISNULL(ca.BilledAmount, 0)), 0),
        InsuranceBalance = ISNULL(SUM(ISNULL(ca.InsuranceBalance, 0)), 0),
        Outstanding = ISNULL(SUM(ISNULL(ca.InsuranceBalance, 0)), 0)
    FROM ActionClaim ac
    LEFT JOIN #ClaimAmount ca ON ca.ClaimId = ac.ClaimId
    GROUP BY ac.ActionCategory
), ActionTot AS
(
    SELECT TotalCount = NULLIF(SUM([Count]), 0) FROM ActionRaw
)
SELECT
    ActionCategory,
    [Count],
    BilledAmount,
    InsuranceBalance,
    Outstanding,
    PercentageOfTotal = CAST(CASE WHEN ActionTot.TotalCount IS NULL THEN 0 ELSE ([Count] * 100.0 / ActionTot.TotalCount) END AS decimal(9,2))
FROM ActionRaw
CROSS JOIN ActionTot
ORDER BY [Count] DESC, Outstanding DESC;

SELECT
    ReviewerName = tb.AssignedTo,
    TotalAssigned = COUNT(1),
    TotalTasks = COUNT(1),
    TotalClaims = COUNT(DISTINCT NULLIF(tb.ClaimId, '')),
    Assigned = COUNT(DISTINCT CASE WHEN tb.AssignedTo <> 'Unassigned' AND LOWER(tb.StatusValue) NOT IN ('closed', 'completed') THEN tb.ClaimId END),
    InProgress = COUNT(DISTINCT CASE WHEN LOWER(tb.StatusValue) IN ('in-progress', 'in progress', 'progress') OR LOWER(tb.StatusValue) LIKE '%progress%' THEN tb.ClaimId END),
    Closed = COUNT(DISTINCT CASE WHEN LOWER(tb.StatusValue) IN ('closed', 'completed') THEN tb.ClaimId END),
    ClosedTasks = SUM(CASE WHEN LOWER(tb.StatusValue) IN ('closed', 'completed') THEN 1 ELSE 0 END),
    Pending = COUNT(DISTINCT CASE WHEN LOWER(tb.StatusValue) NOT IN ('closed', 'completed') THEN tb.ClaimId END),
    PendingTasks = SUM(CASE WHEN LOWER(tb.StatusValue) NOT IN ('closed', 'completed') THEN 1 ELSE 0 END),
    Aging0To30 = COUNT(DISTINCT CASE WHEN ISNULL(ca.AgeDays, 0) BETWEEN 0 AND 30 THEN tb.ClaimId END),
    Aging31To60 = COUNT(DISTINCT CASE WHEN ISNULL(ca.AgeDays, 0) BETWEEN 31 AND 60 THEN tb.ClaimId END),
    Aging61To90 = COUNT(DISTINCT CASE WHEN ISNULL(ca.AgeDays, 0) BETWEEN 61 AND 90 THEN tb.ClaimId END),
    Aging91To120 = COUNT(DISTINCT CASE WHEN ISNULL(ca.AgeDays, 0) BETWEEN 91 AND 120 THEN tb.ClaimId END),
    AgingOver120 = COUNT(DISTINCT CASE WHEN ISNULL(ca.AgeDays, 0) > 120 THEN tb.ClaimId END)
FROM #TaskBoardBase tb
LEFT JOIN #ClaimAmount ca ON ca.ClaimId = tb.ClaimId
GROUP BY tb.AssignedTo
ORDER BY CASE WHEN tb.AssignedTo = 'Unassigned' THEN 0 ELSE 1 END, TotalTasks DESC;

;WITH Sla AS
(
    SELECT SortOrder = 1, Label = '0-30 days', [Count] = COUNT(DISTINCT CASE WHEN ISNULL(NormalizedSlaDays, 0) BETWEEN 0 AND 30 THEN NULLIF(ClaimId, '') END), [Status] = 'Normalized SLA'
    FROM #TaskBoardBase
    UNION ALL
    SELECT 2, '31-60 days', COUNT(DISTINCT CASE WHEN ISNULL(NormalizedSlaDays, 0) BETWEEN 31 AND 60 THEN NULLIF(ClaimId, '') END), 'Normalized SLA'
    FROM #TaskBoardBase
    UNION ALL
    SELECT 3, '61-90 days', COUNT(DISTINCT CASE WHEN ISNULL(NormalizedSlaDays, 0) BETWEEN 61 AND 90 THEN NULLIF(ClaimId, '') END), 'Normalized SLA'
    FROM #TaskBoardBase
    UNION ALL
    SELECT 4, '90+ days', COUNT(DISTINCT CASE WHEN ISNULL(NormalizedSlaDays, 0) > 90 THEN NULLIF(ClaimId, '') END), 'Normalized SLA'
    FROM #TaskBoardBase
)
SELECT Label, ISNULL([Count], 0) [Count], [Status]
FROM Sla
ORDER BY SortOrder;

DROP TABLE #ClaimAmount;
DROP TABLE #TaskClaims;
DROP TABLE #TaskBoardBase;";
        var result = new DenialWorkflowDashboardSummary();
        var cls = new List<DenialClassificationSummaryRow>();
        var reviewers = new List<ReviewerWorkflowSummaryRow>();
        var actions = new List<ActionCategorySummaryRow>();
        var sla = new List<SlaSummaryRow>();
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        AddFilterParams(cmd, filter); AddExtraParams(cmd, where.Parameters);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct))
        {
            result.TotalDenials = GetInt(rd, "TotalDenials");
            result.TotalClaims = GetInt(rd, "TotalClaims");
            result.OpenClaims = GetInt(rd, "OpenClaims");
            result.TotalTasks = GetInt(rd, "TotalTasks");
            result.AssignedClaims = GetInt(rd, "AssignedClaims");
            result.PendingClaims = GetInt(rd, "PendingClaims");
            result.ClosedClaims = GetInt(rd, "ClosedClaims");
            result.EscalatedClaims = GetInt(rd, "EscalatedClaims");
            result.VerificationPending = GetInt(rd, "VerificationPending");
            result.OutstandingAmount = GetDecimal(rd, "OutstandingAmount");
            result.OpenInProgressCount = GetInt(rd, "OpenInProgressCount");
            result.ClosedCount = GetInt(rd, "ClosedCount");
        }
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) cls.Add(new DenialClassificationSummaryRow { Classification = GetString(rd, "Classification"), Count = GetInt(rd, "Count"), BilledAmount = GetDecimal(rd, "BilledAmount"), InsuranceBalance = GetDecimal(rd, "InsuranceBalance"), Outstanding = GetDecimal(rd, "Outstanding"), Assigned = GetInt(rd, "Assigned"), Open = GetInt(rd, "Open"), InProgress = GetInt(rd, "InProgress"), Closed = GetInt(rd, "Closed"), PercentageOfTotal = GetDecimal(rd, "PercentageOfTotal") });
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) actions.Add(new ActionCategorySummaryRow { ActionCategory = GetString(rd, "ActionCategory"), Count = GetInt(rd, "Count"), BilledAmount = GetDecimal(rd, "BilledAmount"), InsuranceBalance = GetDecimal(rd, "InsuranceBalance"), Outstanding = GetDecimal(rd, "Outstanding"), PercentageOfTotal = GetDecimal(rd, "PercentageOfTotal") });
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) reviewers.Add(new ReviewerWorkflowSummaryRow { ReviewerName = GetString(rd, "ReviewerName"), TotalAssigned = GetInt(rd, "TotalAssigned"), TotalTasks = GetInt(rd, "TotalTasks"), TotalClaims = GetInt(rd, "TotalClaims"), Assigned = GetInt(rd, "Assigned"), InProgress = GetInt(rd, "InProgress"), Closed = GetInt(rd, "Closed"), ClosedTasks = GetInt(rd, "ClosedTasks"), Pending = GetInt(rd, "Pending"), PendingTasks = GetInt(rd, "PendingTasks"), Aging0To30 = GetInt(rd, "Aging0To30"), Aging31To60 = GetInt(rd, "Aging31To60"), Aging61To90 = GetInt(rd, "Aging61To90"), Aging91To120 = GetInt(rd, "Aging91To120"), AgingOver120 = GetInt(rd, "AgingOver120") });
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) sla.Add(new SlaSummaryRow { Label = GetString(rd, "Label"), Count = GetInt(rd, "Count"), Status = GetString(rd, "Status") });
        result.DenialClassifications = cls; result.ActionCategories = actions; result.AnalystWorkload = reviewers; result.SlaTiles = sla;
        DashboardCache[cacheKey] = new DashboardCacheEntry(DateTime.UtcNow, result);
        return result;
    }

    public async Task<AgingDashboardSummary> GetAgingDashboardAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        await using var con = OpenLab(filter.LabId);
        await con.OpenAsync(ct);
        if (!await TableExistsAsync(con, "dbo.DenialLineItem", ct)) return new AgingDashboardSummary();

        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        var cols = await GetColumnSetAsync(con, "dbo.DenialLineItem", ct);
        var taskCols = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        static string MoneySql(string columnName) => $"ISNULL(TRY_CONVERT(decimal(18,2), REPLACE(REPLACE(CONVERT(nvarchar(100), d.{columnName}), '$', ''), ',', '')), 0)";
        static string TaskMoneySql(string columnName) => $"ISNULL(TRY_CONVERT(decimal(18,2), REPLACE(REPLACE(CONVERT(nvarchar(100), t.{columnName}), '$', ''), ',', '')), 0)";
        static string TextSql(HashSet<string> cols, string columnName, string fallback) =>
            cols.Contains(columnName) ? $"LTRIM(RTRIM(ISNULL(d.{columnName},'')))" : $"CAST('{fallback}' AS nvarchar(500))";
        static string TaskTextSql(HashSet<string> cols, string columnName, string fallback) =>
            cols.Contains(columnName) ? $"LTRIM(RTRIM(ISNULL(t.{columnName},'')))" : $"CAST('{fallback}' AS nvarchar(500))";
        static string DateSql(HashSet<string> cols, string columnName) =>
            cols.Contains(columnName) ? $"TRY_CONVERT(date, d.{columnName})" : "CAST(NULL AS date)";
        static string TaskDateSql(HashSet<string> cols, string columnName) =>
            cols.Contains(columnName) ? $"TRY_CONVERT(date, t.{columnName})" : "CAST(NULL AS date)";

        var amountColumn =
            cols.Contains("BilledAmount") ? "BilledAmount" :
            cols.Contains("BilledCharges") ? "BilledCharges" :
            cols.Contains("TotalCharges") ? "TotalCharges" :
            cols.Contains("InsuranceBalance") ? "InsuranceBalance" :
            cols.Contains("TotalBalance") ? "TotalBalance" :
            string.Empty;
        var amountExpression = string.IsNullOrWhiteSpace(amountColumn) ? "CAST(0 AS decimal(18,2))" : MoneySql(amountColumn);
        var serviceDateExpression = cols.Contains("DateOfService") ? DateSql(cols, "DateOfService") : DateSql(cols, "FirstBilledDate");
        var claimUidExpression = cols.Contains("ClaimUID")
            ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(d.ClaimUID,''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(d.VisitNumber,''))), 'CLM-', '')))"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(d.VisitNumber,''))), 'CLM-', ''))";
        var payerExpression = TextSql(cols, "PayerName", "Unknown Payer");
        var classExpression = TextSql(cols, "DenialClassification", "Unclassified");
        var panelExpression = TextSql(cols, "PanelName", "Unknown Panel");
        var lineFilter = IsReviewerOnly(filter.Role)
            ? new DenialWorkflowFilter
            {
                LabId = filter.LabId,
                UserName = filter.UserName,
                Status = filter.Status,
                TaskView = filter.TaskView,
                Reviewer = filter.Reviewer,
                AssignedTo = filter.AssignedTo,
                DenialCode = filter.DenialCode,
                PayerName = filter.PayerName,
                PanelName = filter.PanelName,
                Clinic = filter.Clinic,
                SalesRepname = filter.SalesRepname,
                ReferringProvider = filter.ReferringProvider,
                DenialClassification = filter.DenialClassification,
                ActionCategory = filter.ActionCategory,
                Priority = filter.Priority,
                RunId = filter.RunId,
                SearchText = filter.SearchText,
                FromDate = filter.FromDate,
                ToDate = filter.ToDate,
                Page = filter.Page,
                PageSize = filter.PageSize
            }
            : filter;
        var where = BuildClaimWhere(lineFilter, "d");
        var taskWhere = BuildAgingTaskWhere(filter, "t", taskCols);
        var taskAmountExpression = taskCols.Contains("InsuranceBalance") ? TaskMoneySql("InsuranceBalance") : "CAST(0 AS decimal(18,2))";
        var taskServiceDateExpression = TaskDateSql(taskCols, "DateOfService");
        var taskClaimUidExpression = taskCols.Contains("ClaimUID")
            ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimUID,''))), ''), LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized, t.ClaimID))))"
            : "LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized, t.ClaimID)))";
        var taskCptExpression =
            taskCols.Contains("CPTCode") ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.CPTCode,''))), ''), LTRIM(RTRIM(ISNULL(t.UniqueTrackId, t.TaskID))))" :
            taskCols.Contains("UniqueTrackId") ? "LTRIM(RTRIM(ISNULL(t.UniqueTrackId,'')))" :
            "LTRIM(RTRIM(ISNULL(t.TaskID,'')))";
        var taskClassExpression = TaskTextSql(taskCols, "DenialClassification", "Unclassified");
        var taskActionExpression = TaskTextSql(taskCols, "ActionCategory", "Unclassified");
        var lineClaimRootExpression = $"CASE WHEN CHARINDEX('_', {claimUidExpression}) > 0 THEN LEFT({claimUidExpression}, CHARINDEX('_', {claimUidExpression}) - 1) ELSE {claimUidExpression} END";
        var taskClaimRootExpression = $"CASE WHEN CHARINDEX('_', {taskClaimUidExpression}) > 0 THEN LEFT({taskClaimUidExpression}, CHARINDEX('_', {taskClaimUidExpression}) - 1) ELSE {taskClaimUidExpression} END";
        var lineLabScope = LabScopeSql("d.LabId");
        var taskLabScope = LabScopeSql("t.LabId");

        var sql = $@"
IF OBJECT_ID('tempdb..#LineAging') IS NOT NULL DROP TABLE #LineAging;
IF OBJECT_ID('tempdb..#TaskAgingDedup') IS NOT NULL DROP TABLE #TaskAgingDedup;
IF OBJECT_ID('tempdb..#TaskAssignment') IS NOT NULL DROP TABLE #TaskAssignment;
IF OBJECT_ID('tempdb..#VisibleAgingClaims') IS NOT NULL DROP TABLE #VisibleAgingClaims;

DECLARE @HasLineLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialLineItem WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;
DECLARE @HasTaskLab bit = CASE WHEN OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;

SELECT
    ClaimRoot = {taskClaimRootExpression},
    ClaimId = MIN({taskClaimUidExpression})
INTO #VisibleAgingClaims
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE (@HasTaskLab=0 OR {taskLabScope})
  AND NULLIF({taskClaimUidExpression}, '') IS NOT NULL
  {taskWhere.WhereClause}
GROUP BY {taskClaimRootExpression};

CREATE UNIQUE CLUSTERED INDEX IX_VisibleAgingClaims_Root ON #VisibleAgingClaims(ClaimRoot);

SELECT
    ClaimRoot = {taskClaimRootExpression},
    AssignedTo = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))), ''), 'Unassigned')
INTO #TaskAssignment
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE (@HasTaskLab=0 OR {taskLabScope})
  AND NULLIF({taskClaimUidExpression}, '') IS NOT NULL
  {taskWhere.WhereClause}
GROUP BY {taskClaimRootExpression},
         COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))), ''), 'Unassigned');

CREATE NONCLUSTERED INDEX IX_TaskAssignment_Root ON #TaskAssignment(ClaimRoot) INCLUDE(AssignedTo);

;WITH LineSource AS
(
    SELECT
        ClaimId = {claimUidExpression},
        ClaimRoot = {lineClaimRootExpression},
        PayerName = COALESCE(NULLIF({payerExpression}, ''), 'Unknown Payer'),
        DenialClassification = COALESCE(NULLIF({classExpression}, ''), 'Unclassified'),
        PanelName = COALESCE(NULLIF({panelExpression}, ''), 'Unknown Panel'),
        ServiceDate = {serviceDateExpression},
        Amount = {amountExpression}
    FROM dbo.DenialLineItem d WITH (NOLOCK)
    INNER JOIN #VisibleAgingClaims vac
      ON vac.ClaimRoot = {lineClaimRootExpression}
    WHERE (@HasLineLab=0 OR {lineLabScope})
      AND NULLIF({claimUidExpression}, '') IS NOT NULL
      {where.WhereClause}
)
SELECT
    ClaimId,
    ClaimRoot,
    PayerName,
    DenialClassification,
    PanelName,
    Amount = CAST(ISNULL(Amount, 0) AS decimal(18,2)),
    AgeDays = CASE WHEN ServiceDate IS NULL THEN 0 ELSE DATEDIFF(day, ServiceDate, CAST(GETDATE() AS date)) END,
    AgeBucket = CASE
        WHEN ServiceDate IS NULL OR DATEDIFF(day, ServiceDate, CAST(GETDATE() AS date)) BETWEEN 0 AND 30 THEN 'd0'
        WHEN DATEDIFF(day, ServiceDate, CAST(GETDATE() AS date)) BETWEEN 31 AND 60 THEN 'd30'
        WHEN DATEDIFF(day, ServiceDate, CAST(GETDATE() AS date)) BETWEEN 61 AND 90 THEN 'd60'
        WHEN DATEDIFF(day, ServiceDate, CAST(GETDATE() AS date)) BETWEEN 91 AND 120 THEN 'd90'
        ELSE 'd120'
    END
INTO #LineAging
FROM LineSource;

CREATE NONCLUSTERED INDEX IX_AgingLineAging_Bucket ON #LineAging(AgeBucket) INCLUDE(Amount, ClaimId, PayerName, DenialClassification, PanelName, AgeDays);
CREATE NONCLUSTERED INDEX IX_AgingLineAging_Root ON #LineAging(ClaimRoot) INCLUDE(Amount, ClaimId, PayerName, AgeDays);

;WITH TaskSource AS
(
    SELECT
        ClaimId = {taskClaimUidExpression},
        ClaimRoot = {taskClaimRootExpression},
        CptCode = {taskCptExpression},
        DenialClassification = COALESCE(NULLIF({taskClassExpression}, ''), 'Unclassified'),
        ActionCategory = COALESCE(NULLIF({taskActionExpression}, ''), 'Unclassified'),
        Amount = CAST(ISNULL({taskAmountExpression}, 0) AS decimal(18,2)),
        AgeDays = CASE WHEN {taskServiceDateExpression} IS NULL THEN 0 ELSE DATEDIFF(day, {taskServiceDateExpression}, CAST(GETDATE() AS date)) END,
        AgeBucket = CASE
            WHEN {taskServiceDateExpression} IS NULL OR DATEDIFF(day, {taskServiceDateExpression}, CAST(GETDATE() AS date)) BETWEEN 0 AND 30 THEN 'd0'
            WHEN DATEDIFF(day, {taskServiceDateExpression}, CAST(GETDATE() AS date)) BETWEEN 31 AND 60 THEN 'd30'
            WHEN DATEDIFF(day, {taskServiceDateExpression}, CAST(GETDATE() AS date)) BETWEEN 61 AND 90 THEN 'd60'
            WHEN DATEDIFF(day, {taskServiceDateExpression}, CAST(GETDATE() AS date)) BETWEEN 91 AND 120 THEN 'd90'
            ELSE 'd120'
        END
    FROM dbo.DenialTaskBoard t WITH (NOLOCK)
    WHERE (@HasTaskLab=0 OR {taskLabScope})
      AND NULLIF({taskClaimUidExpression}, '') IS NOT NULL
      {taskWhere.WhereClause}
)
SELECT
    ClaimId,
    ClaimRoot,
    CptCode,
    DenialClassification,
    ActionCategory,
    AgeBucket,
    AgeDays = MAX(AgeDays),
    Amount = MAX(Amount)
INTO #TaskAgingDedup
FROM TaskSource
GROUP BY ClaimId, ClaimRoot, CptCode, DenialClassification, ActionCategory, AgeBucket;

CREATE NONCLUSTERED INDEX IX_AgingTaskAgingDedup_Bucket ON #TaskAgingDedup(AgeBucket) INCLUDE(Amount, ClaimId, DenialClassification, ActionCategory, AgeDays);

SELECT
    TotalAmount = ISNULL(SUM(Amount), 0),
    TotalClaims = COUNT(DISTINCT ClaimId),
    TotalPayers = COUNT(DISTINCT NULLIF(PayerName,'')),
    TotalSlaBreaches = COUNT(DISTINCT CASE WHEN AgeDays > 90 THEN ClaimId END)
FROM #LineAging;

SELECT
    [Key] = AgeBucket,
    Amount = ISNULL(SUM(Amount), 0),
    ClaimCount = COUNT(DISTINCT ClaimId),
    SlaBreaches = COUNT(DISTINCT CASE WHEN AgeDays > 90 THEN ClaimId END)
FROM #LineAging
GROUP BY AgeBucket;

SELECT
    Name = PayerName,
    SubTitle = PayerName,
    BucketKey = AgeBucket,
    Amount = ISNULL(SUM(Amount), 0),
    ClaimCount = COUNT(DISTINCT ClaimId),
    SlaBreaches = COUNT(DISTINCT CASE WHEN AgeDays > 90 THEN ClaimId END)
FROM #LineAging
GROUP BY PayerName, AgeBucket
ORDER BY SUM(Amount) DESC;

SELECT
    Name = DenialClassification,
    SubTitle = DenialClassification,
    BucketKey = AgeBucket,
    Amount = ISNULL(SUM(Amount), 0),
    ClaimCount = COUNT(DISTINCT ClaimId),
    SlaBreaches = COUNT(DISTINCT CASE WHEN AgeDays > 90 THEN ClaimId END)
FROM #TaskAgingDedup
GROUP BY DenialClassification, AgeBucket
ORDER BY SUM(Amount) DESC;

SELECT
    Name = ActionCategory,
    SubTitle = ActionCategory,
    BucketKey = AgeBucket,
    Amount = ISNULL(SUM(Amount), 0),
    ClaimCount = COUNT(DISTINCT ClaimId),
    SlaBreaches = COUNT(DISTINCT CASE WHEN AgeDays > 90 THEN ClaimId END)
FROM #TaskAgingDedup
GROUP BY ActionCategory, AgeBucket
ORDER BY SUM(Amount) DESC;

SELECT
    Name = PanelName,
    SubTitle = PanelName,
    BucketKey = AgeBucket,
    Amount = ISNULL(SUM(Amount), 0),
    ClaimCount = COUNT(DISTINCT ClaimId),
    SlaBreaches = COUNT(DISTINCT CASE WHEN AgeDays > 90 THEN ClaimId END)
FROM #LineAging
GROUP BY PanelName, AgeBucket
ORDER BY SUM(Amount) DESC;

SELECT
    Name = ta.AssignedTo,
    SubTitle = 'Assigned workload',
    BucketKey = la.AgeBucket,
    Amount = ISNULL(SUM(la.Amount), 0),
    ClaimCount = COUNT(DISTINCT la.ClaimId),
    SlaBreaches = COUNT(DISTINCT CASE WHEN la.AgeDays > 90 THEN la.ClaimId END)
FROM #LineAging la
INNER JOIN #TaskAssignment ta
  ON ta.ClaimRoot = la.ClaimRoot
WHERE NULLIF(LTRIM(RTRIM(ISNULL(ta.AssignedTo,''))), '') IS NOT NULL
GROUP BY ta.AssignedTo, la.AgeBucket
ORDER BY SUM(la.Amount) DESC;

SELECT TOP (5)
    Name = la.PayerName,
    SubTitle = 'SLA risk',
    Amount = ISNULL(SUM(la.Amount), 0),
    ClaimCount = COUNT(DISTINCT la.ClaimId),
    [Status] = CASE WHEN MAX(la.AgeDays) > 120 THEN 'Breached' ELSE 'At risk' END,
    DaysRemaining = CASE WHEN MAX(la.AgeDays) >= 90 THEN 0 ELSE 90 - MAX(la.AgeDays) END
FROM #LineAging la
WHERE la.AgeDays >= 60
GROUP BY la.PayerName
ORDER BY MAX(la.AgeDays) DESC, SUM(la.Amount) DESC;

SELECT TOP (6)
    Name = ISNULL(ta.AssignedTo, 'Unassigned'),
    SubTitle = 'Assigned workload',
    Amount = ISNULL(SUM(la.Amount), 0),
    ClaimCount = COUNT(DISTINCT la.ClaimId),
    [Status] = CASE WHEN ISNULL(ta.AssignedTo, 'Unassigned') = 'Unassigned' THEN 'Needs action' ELSE 'On track' END,
    DaysRemaining = 0
FROM #LineAging la
LEFT JOIN #TaskAssignment ta
  ON ta.ClaimRoot = la.ClaimRoot
GROUP BY ISNULL(ta.AssignedTo, 'Unassigned'),
         CASE WHEN ISNULL(ta.AssignedTo, 'Unassigned') = 'Unassigned' THEN 'Needs action' ELSE 'On track' END
ORDER BY CASE WHEN ISNULL(ta.AssignedTo, 'Unassigned')='Unassigned' THEN 0 ELSE 1 END, SUM(la.Amount) DESC;

DROP TABLE #TaskAgingDedup;
DROP TABLE #TaskAssignment;
DROP TABLE #VisibleAgingClaims;
DROP TABLE #LineAging;";

        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        AddFilterParams(cmd, filter);
        AddExtraParams(cmd, where.Parameters);
        AddExtraParams(cmd, taskWhere.Parameters);

        var result = new AgingDashboardSummary();
        var buckets = CreateEmptyAgingBuckets();
        var payerRows = new List<AgingFlatRow>();
        var classRows = new List<AgingFlatRow>();
        var actionRows = new List<AgingFlatRow>();
        var panelRows = new List<AgingFlatRow>();
        var reviewerRows = new List<AgingFlatRow>();
        var risks = new List<AgingListItem>();
        var workload = new List<AgingListItem>();

        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct))
        {
            result.TotalAmount = GetDecimal(rd, "TotalAmount");
            result.TotalClaims = GetInt(rd, "TotalClaims");
            result.TotalPayers = GetInt(rd, "TotalPayers");
            result.TotalSlaBreaches = GetInt(rd, "TotalSlaBreaches");
        }
        if (await rd.NextResultAsync(ct))
        {
            while (await rd.ReadAsync(ct))
            {
                var key = GetString(rd, "Key");
                if (!buckets.TryGetValue(key, out var bucket)) continue;
                bucket.Amount = GetDecimal(rd, "Amount");
                bucket.ClaimCount = GetInt(rd, "ClaimCount");
                bucket.SlaBreaches = GetInt(rd, "SlaBreaches");
            }
        }
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) payerRows.Add(ReadAgingFlatRow(rd));
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) classRows.Add(ReadAgingFlatRow(rd));
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) actionRows.Add(ReadAgingFlatRow(rd));
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) panelRows.Add(ReadAgingFlatRow(rd));
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) reviewerRows.Add(ReadAgingFlatRow(rd));
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) risks.Add(ReadAgingListItem(rd));
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) workload.Add(ReadAgingListItem(rd));

        result.Buckets = AgingBucketOrder.Select(k => buckets[k]).ToList();
        result.ByPayer = BuildAgingMatrixRows(payerRows);
        result.ByClassification = BuildAgingMatrixRows(classRows);
        result.ByAction = BuildAgingMatrixRows(actionRows);
        result.ByPanel = BuildAgingMatrixRows(panelRows);
        result.ByReviewer = BuildAgingMatrixRows(reviewerRows, priorityUsesBreaches: true);
        result.SlaRisks = risks;
        result.AnalystWorkload = workload;
        return result;
    }

    public async Task<DenialWorkflowFilterOptions> GetFilterOptionsAsync(int labId, CancellationToken ct)
    {
        if (FilterOptionsCache.TryGetValue(labId, out var cached) && DateTime.UtcNow - cached.CachedOnUtc < FilterOptionsCacheDuration)
            return cached.Options;

        var sql = $@"
DECLARE @HasTaskLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;
DECLARE @HasLineLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialLineItem WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;

SELECT TOP (50) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(Status,'')))
    FROM dbo.DenialTaskBoard WITH (NOLOCK)
    WHERE (@HasTaskLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(Status,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(Status,'')))
) x
ORDER BY Value;

SELECT TOP (100) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(ActionCategory,'')))
    FROM dbo.DenialTaskBoard WITH (NOLOCK)
    WHERE (@HasTaskLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(ActionCategory,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(ActionCategory,'')))
) x
ORDER BY Value;

SELECT TOP (30) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(Priority,'')))
    FROM dbo.DenialTaskBoard WITH (NOLOCK)
    WHERE (@HasTaskLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(Priority,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(Priority,'')))
) x
ORDER BY Value;

-- Denial code dropdown source: DenialTaskBoard.DenialCode, applied to DenialLineItem.DenialCodeNormalized in claim view.
SELECT TOP (250) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(DenialCode,'')))
    FROM dbo.DenialTaskBoard WITH (NOLOCK)
    WHERE (@HasTaskLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(DenialCode,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(DenialCode,'')))
) x
ORDER BY Value;

-- Payer filter source: DenialLineItem.PayerNameNormalized.
SELECT TOP (500) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(PayerName,'')))
    FROM dbo.DenialLineItem WITH (NOLOCK)
    WHERE (@HasLineLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(PayerName,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(PayerName,'')))
) x
ORDER BY Value;

SELECT TOP (500) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(PanelName,'')))
    FROM dbo.DenialLineItem WITH (NOLOCK)
    WHERE (@HasLineLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(PanelName,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(PanelName,'')))
) x
ORDER BY Value;

-- Denial classification dropdown source: DenialTaskBoard.DenialClassification, applied to DenialLineItem.DenialClassification in claim view.
SELECT TOP (250) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(DenialClassification,'')))
    FROM dbo.DenialTaskBoard WITH (NOLOCK)
    WHERE (@HasTaskLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(DenialClassification,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(DenialClassification,'')))
) x
ORDER BY Value;

-- Clinic/Sales Rep are autocomplete values from DenialLineItem.
SELECT TOP (500) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(ClinicName,'')))
    FROM dbo.DenialLineItem WITH (NOLOCK)
    WHERE (@HasLineLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(ClinicName,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(ClinicName,'')))
) x
ORDER BY Value;

SELECT TOP (500) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(SalesRepname,'')))
    FROM dbo.DenialLineItem WITH (NOLOCK)
    WHERE (@HasLineLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(SalesRepname,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(SalesRepname,'')))
) x
ORDER BY Value;

-- Referring Provider source includes DenialTaskBoard.ReferringProvider for Augustus task-board imports.
SELECT TOP (500) Value
FROM (
    SELECT Value = LTRIM(RTRIM(ISNULL(ReferringProvider,'')))
    FROM dbo.DenialTaskBoard WITH (NOLOCK)
    WHERE (@HasTaskLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(ReferringProvider,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(ReferringProvider,'')))

    UNION

    SELECT Value = LTRIM(RTRIM(ISNULL(ReferringProvider,'')))
    FROM dbo.DenialLineItem WITH (NOLOCK)
    WHERE (@HasLineLab=0 OR {LabScopeSql("LabId")})
      AND NULLIF(LTRIM(RTRIM(ISNULL(ReferringProvider,''))),'') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ISNULL(ReferringProvider,'')))
) x
ORDER BY Value;";
        var result = new DenialWorkflowFilterOptions();
        await using var con = OpenLab(labId); await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 90 };
        AddLabScopeParams(cmd, labId);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        result.Statuses = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.ActionCategories = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.Priorities = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.DenialCodes = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.PayerNames = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.PanelNames = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.DenialClassifications = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.Clinics = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.SalesReps = await ReadStringListAsync(rd, ct);
        await rd.NextResultAsync(ct); result.ReferringProviders = await ReadStringListAsync(rd, ct);

        FilterOptionsCache[labId] = new FilterOptionsCacheEntry(DateTime.UtcNow, result);
        return result;
    }

    public async Task<IReadOnlyList<ReviewerOption>> GetReviewerOptionsAsync(int labId, CancellationToken ct)
    {
        var rows = new List<ReviewerOption>();
        await using var con = OpenMaster();
        await con.OpenAsync(ct);

        var userRoleColumns = await GetColumnSetAsync(con, "dbo.UserRoles", ct);
        var labUsersColumns = await GetColumnSetAsync(con, "dbo.LabUsers", ct);
        var hasUserLabs = await TableExistsAsync(con, "dbo.UserLabs", ct);
        var userLabsColumns = hasUserLabs ? await GetColumnSetAsync(con, "dbo.UserLabs", ct) : new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var roleTable = await TableExistsAsync(con, "dbo.Roles", ct) ? "dbo.Roles" : await TableExistsAsync(con, "dbo.Role", ct) ? "dbo.Role" : string.Empty;
        var roleColumns = string.IsNullOrWhiteSpace(roleTable) ? new HashSet<string>(StringComparer.OrdinalIgnoreCase) : await GetColumnSetAsync(con, roleTable, ct);

        var labUserIdColumn = new[] { "LabUserID", "LabUserId", "UserID", "UserId", "Id" }.FirstOrDefault(labUsersColumns.Contains) ?? "LabUserID";
        var userRoleUserIdColumn = new[] { "LabUserID", "LabUserId", "UserID", "UserId" }.FirstOrDefault(userRoleColumns.Contains) ?? labUserIdColumn;
        var userLabUserIdColumn = new[] { "LabUserID", "LabUserId", "UserID", "UserId" }.FirstOrDefault(userLabsColumns.Contains) ?? labUserIdColumn;
        var roleIdColumn = new[] { "RoleID", "RoleId", "Id" }.FirstOrDefault(roleColumns.Contains);
        var userRoleIdColumn = new[] { "RoleID", "RoleId" }.FirstOrDefault(userRoleColumns.Contains);
        var roleNameColumn = new[] { "RoleName", "Name", "Role", "RoleDescription" }.FirstOrDefault(roleColumns.Contains);
        var userRoleNameColumn = new[] { "RoleName", "Role", "Name" }.FirstOrDefault(userRoleColumns.Contains);
        var emailColumn = new[] { "Email", "EmailAddress", "UserEmail" }.FirstOrDefault(labUsersColumns.Contains);
        var displayExpr = labUsersColumns.Contains("FirstName") || labUsersColumns.Contains("LastName")
            ? "NULLIF(LTRIM(RTRIM(CONCAT(ISNULL(lu.FirstName,''),' ',ISNULL(lu.LastName,'')))), '')"
            : "NULL";
        var emailExpr = string.IsNullOrWhiteSpace(emailColumn) ? "''" : $"ISNULL(lu.{emailColumn},'')";
        var roleExpr = "CASE WHEN ur.RoleID = 5 THEN 'AR Reviewer' ELSE '' END";
        var roleJoin = string.Empty;
        var roleFilter = "AND ur.RoleID = 5";

        if (!string.IsNullOrWhiteSpace(roleTable) && !string.IsNullOrWhiteSpace(roleNameColumn) && !string.IsNullOrWhiteSpace(roleIdColumn) && !string.IsNullOrWhiteSpace(userRoleIdColumn))
        {
            roleJoin = $"LEFT JOIN {roleTable} r ON ur.{userRoleIdColumn}=r.{roleIdColumn}";
            roleExpr = $"ISNULL(r.{roleNameColumn}, CASE WHEN ur.{userRoleIdColumn}=5 THEN 'AR Reviewer' ELSE '' END)";
            roleFilter = $"AND (UPPER(REPLACE(REPLACE(ISNULL(r.{roleNameColumn},''),' ',''),'-','')) IN ('ARREVIEWER','ARANALYST','ARANALYSER','CLIENTMANAGER','ACCOUNTMANAGER') OR ur.{userRoleIdColumn}=5)";
        }
        else if (!string.IsNullOrWhiteSpace(userRoleNameColumn))
        {
            roleExpr = $"ISNULL(ur.{userRoleNameColumn}, CASE WHEN ur.RoleID=5 THEN 'AR Reviewer' ELSE '' END)";
            roleFilter = $"AND (UPPER(REPLACE(REPLACE(ISNULL(ur.{userRoleNameColumn},''),' ',''),'-','')) IN ('ARREVIEWER','ARANALYST','ARANALYSER','CLIENTMANAGER','ACCOUNTMANAGER') OR ur.RoleID=5)";
        }

        var labJoin = hasUserLabs ? $"LEFT JOIN dbo.UserLabs ul ON lu.{labUserIdColumn}=ul.{userLabUserIdColumn}" : string.Empty;
        var labFilter = hasUserLabs ? $"AND (@LabId <= 0 OR {LabScopeSql("ul.LabId")})" : string.Empty;

        var sql = $@"
SELECT DISTINCT
    LabUserID = lu.{labUserIdColumn},
    UserName = ISNULL(lu.UserName, ''),
    DisplayName = COALESCE({displayExpr}, NULLIF(LTRIM(RTRIM(ISNULL(lu.UserName,''))), ''), {emailExpr}),
    Email = {emailExpr},
    [Role] = {roleExpr}
FROM dbo.LabUsers lu
INNER JOIN dbo.UserRoles ur ON lu.{labUserIdColumn}=ur.{userRoleUserIdColumn}
{roleJoin}
{labJoin}
WHERE 1=1
  {labFilter}
  {roleFilter}
ORDER BY DisplayName, UserName;";

        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        AddLabScopeParams(cmd, labId);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct))
        {
            var displayName = GetString(rd, "DisplayName");
            var userName = GetString(rd, "UserName");
            var role = NormalizeWorkflowRoleName(GetString(rd, "Role"));
            rows.Add(new ReviewerOption
            {
                LabUserId = GetInt(rd, "LabUserID"),
                UserName = userName,
                DisplayName = string.IsNullOrWhiteSpace(displayName) ? userName : displayName,
                Email = GetString(rd, "Email"),
                Role = role
            });
        }
        return rows;
    }

    public async Task<IReadOnlyList<WorkflowTaskRow>> GetActiveTasksAsync(int labId, CancellationToken ct)
    {
        var filter = new DenialWorkflowFilter { LabId = labId, Page = 1, PageSize = 500000 };
        return (await GetTasksAsync(filter, ct)).Items;
    }

    public async Task<IReadOnlyList<WorkflowTaskRow>> GetHistoryTasksByUidAsync(int labId, IEnumerable<string> uniqueTrackIds, CancellationToken ct)
    {
        var keys = uniqueTrackIds.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (keys.Count == 0) return [];
        var sql = $@"SELECT h.TaskID, h.UniqueTrackId, h.LabId, h.RunId, h.NewStatus Status, h.NewAssignedTo AssignedTo, h.Comments ReviewerComments,
               '' ClaimID, '' PatientId, '' CPTCode, '' DenialCode, '' DenialDescription, '' DenialClassification, '' ActionCode, '' RecommendedAction, '' ActionCategory, '' Task, '' Priority, CAST(0 AS decimal(18,2)) InsuranceBalance,
               CAST(NULL AS date) DateOpened, CAST(NULL AS date) DueDate, CAST(NULL AS date) DateCompleted, '' SLAStatus, '' LabName, CAST(NULL AS datetime2) CreatedOn,
               '' SalesRepname, '' ClinicName, '' ReferringProvider, '' PayerName, '' PayerName, NULL PayerCode, '' PayerType, NULL FirstBilledDate, NULL ChargeEnteredDate, '' BillingProvider, '' PanelName, NULL DateOfService, NULL ReviewerUpdatedOn, '' ReviewerUpdatedBy
FROM dbo.DenialTaskHistory h
JOIN (SELECT UniqueTrackId, MAX(HistoryId) HistoryId FROM dbo.DenialTaskHistory WHERE {LabScopeSql("LabId")} GROUP BY UniqueTrackId) latest ON latest.HistoryId=h.HistoryId
WHERE {LabScopeSql("h.LabId")} AND h.UniqueTrackId IN ({string.Join(',', keys.Select((_, i) => "@p" + i))})";
        var rows = new List<WorkflowTaskRow>();
        await using var con = OpenLab(labId); await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con); AddLabScopeParams(cmd, labId);
        for (var i = 0; i < keys.Count; i++) cmd.Parameters.AddWithValue("@p" + i, keys[i]);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct)) rows.Add(ReadTask(rd));
        return rows;
    }

    public async Task<DenialWorkflowSummary> GetSummaryAsync(int labId, string role, string userName, CancellationToken ct)
    {
        var reviewerWhere = IsReviewerOnly(role) ? " AND ISNULL(AssignedTo,'')=@UserName" : "";
        var verificationReviewerWhere = IsReviewerOnly(role) ? " AND ISNULL(AssignedTo,'')=@UserName" : "";
        var sql = $@"
SELECT
Assigned = SUM(CASE WHEN ISNULL(AssignedTo,'')<>'' AND ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END),
Completed = SUM(CASE WHEN ISNULL(Status,'') IN ('Closed','Completed') THEN 1 ELSE 0 END),
Pending = SUM(CASE WHEN ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END),
Unassigned = SUM(CASE WHEN ISNULL(AssignedTo,'')='' AND ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END)
FROM dbo.DenialTaskBoard WITH (NOLOCK)
WHERE ({LabScopeSql("LabId")} OR @LabId <= 0) {reviewerWhere};
SELECT VerificationPending = COUNT(1) FROM dbo.DenialVerificationTask WHERE {LabScopeSql("LabId")} {verificationReviewerWhere};";
        await using var con = OpenLab(labId); await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con); AddLabScopeParams(cmd, labId); cmd.Parameters.AddWithValue("@UserName", userName ?? string.Empty);
        var s = new DenialWorkflowSummary();
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct)) { s.Assigned = GetInt(rd, "Assigned"); s.Completed = GetInt(rd, "Completed"); s.Pending = GetInt(rd, "Pending"); s.Unassigned = GetInt(rd, "Unassigned"); }
        if (await rd.NextResultAsync(ct) && await rd.ReadAsync(ct)) s.VerificationPending = GetInt(rd, "VerificationPending");

        var counts = await GetClaimSubMenuCountsAsync(new DenialWorkflowFilter { LabId = labId, Role = role, UserName = userName }, ct);
        s.New = counts.New;
        s.Assigned = counts.Assigned;
        s.Closed = counts.Closed;
        s.Escalated = counts.Escalated;
        s.TotalClaims = counts.TotalClaims;
        return s;
    }

    private static string NormalizedTaskStatusSql(string alias)
    {
        var s = $"LOWER(LTRIM(RTRIM(ISNULL({alias}.Status,''))))";
        var wf = $"LOWER(LTRIM(RTRIM(ISNULL({alias}.WorkFlowStatus,''))))";
        return $@"CASE
        WHEN {s} = 'external escalation' OR {wf} = 'external escalation' THEN 'External Escalation'
        WHEN {s} IN ('internal escalation','escalated','escalated to ar manager') OR {wf} IN ('internal escalation','escalated','escalated to ar manager') THEN 'Internal Escalation'
        WHEN {s} IN ('pending documentation','documentation pending','document required') THEN 'Pending Documentation'
        WHEN {s} IN ('write off approval pending','write-off pending approval','write off pending approval','write-off approval pending') THEN 'Write Off Approval Pending'
        WHEN {s} IN ('payer followup required','payer follow-up required','followup required') THEN 'Payer Followup Required'
        WHEN {s} IN ('pending payer','pending payer response') THEN 'Pending Payer Response'
        WHEN {s} IN ('closed','completed') THEN 'Closed'
        WHEN {s} IN ('assigned','in progress','pending review','open','') THEN 'Assigned'
        WHEN {s} IN ('new','unassigned') THEN 'Unassigned'
        ELSE LTRIM(RTRIM(ISNULL({alias}.Status,'')))
    END";
    }

    private static string ClaimQueueCaseSql(string alias) => $@"CASE
        WHEN ISNULL({alias}.HasEscalationResponse,0) = 1 THEN 'Escalation Response'
        WHEN ISNULL({alias}.InternalEscalationCount,0) > 0 THEN 'Internal Escalation'
        WHEN ISNULL({alias}.ExternalEscalationCount,0) > 0 THEN 'External Escalation'
        WHEN ISNULL({alias}.WriteOffApprovalCount,0) > 0 THEN 'Write-Off Approval'
        WHEN ISNULL({alias}.PendingDocumentationCount,0) > 0 THEN 'Pending Documentation'
        WHEN ISNULL({alias}.PayerFollowupCount,0) > 0 THEN 'Payer Followup'
        WHEN ISNULL({alias}.PendingPayerResponseCount,0) > 0 THEN 'Pending Payer Response'
        WHEN ISNULL({alias}.TaskCount,0) > 0 AND ISNULL({alias}.ClosedCount,0) = ISNULL({alias}.TaskCount,0) THEN 'Closed'
        WHEN ISNULL({alias}.AssignedTaskCount,0) > 0 THEN 'Assigned'
        WHEN ISNULL({alias}.TaskCount,0) > 0 AND ISNULL({alias}.UnassignedTaskCount,0) = ISNULL({alias}.TaskCount,0)
             AND DATEDIFF(HOUR, ISNULL({alias}.MaxCreatedOn, SYSDATETIME()), SYSDATETIME()) > 48 THEN 'Unassigned'
        ELSE 'New'
    END";

    private static string ClaimStatusCaseSql(string alias) => $@"CASE ({ClaimQueueCaseSql(alias)})
        WHEN 'Internal Escalation' THEN 'Escalated to AR Manager'
        WHEN 'External Escalation' THEN 'External Escalation'
        WHEN 'Write-Off Approval' THEN 'Write Off Approval Pending'
        WHEN 'Pending Documentation' THEN 'Pending Documentation'
        WHEN 'Payer Followup' THEN 'Payer Followup Required'
        WHEN 'Pending Payer Response' THEN 'Pending Payer Response'
        WHEN 'Closed' THEN 'Closed'
        WHEN 'Assigned' THEN 'Assigned'
        WHEN 'Unassigned' THEN 'Unassigned'
        WHEN 'Escalation Response' THEN 'Escalation Response'
        ELSE 'New'
    END";

    private static string ClaimQueueWhereSql(string normalizedView) => normalizedView switch
    {
        "new" => "ISNULL(tca.QueueName, 'New') = 'New'",
        "unassigned" => "ISNULL(tca.QueueName, '') = 'Unassigned'",
        "assigned" => "ISNULL(tca.QueueName, '') = 'Assigned'",
        "payerfollowup" => "ISNULL(tca.QueueName, '') = 'Payer Followup'",
        "pendingdocumentation" => "ISNULL(tca.QueueName, '') = 'Pending Documentation'",
        "pendingpayerresponse" => "ISNULL(tca.QueueName, '') = 'Pending Payer Response'",
        "writeoffapproval" => "ISNULL(tca.QueueName, '') = 'Write-Off Approval'",
        "escalations" => "ISNULL(tca.QueueName, '') IN ('Internal Escalation','External Escalation','Escalation Response')",
        "internalescalation" => "ISNULL(tca.QueueName, '') = 'Internal Escalation'",
        "externalescalation" => "ISNULL(tca.QueueName, '') = 'External Escalation'",
        "escalationresponse" => "ISNULL(tca.QueueName, '') = 'Escalation Response'",
        "closed" => "ISNULL(tca.QueueName, '') = 'Closed'",
        "verification" => "ISNULL(tca.HasVerification, 0) = 1",
        "all" => "1=1",
        _ => "1=1"
    };

    public async Task<ClaimSubMenuCounts> GetClaimSubMenuCountsAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        var cacheKey = BuildFilterCacheKey("claim-counts", filter);
        if (ClaimCountsCache.TryGetValue(cacheKey, out var cachedCounts)
            && DateTime.UtcNow - cachedCounts.CachedOnUtc < ClaimCountsCacheDuration)
        {
            return cachedCounts.Counts;
        }

        await using var con = OpenLab(filter.LabId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        await EnsureClaimSupportTablesAsync(filter.LabId, ct);

        var hasLineClaimUid = await HasColumnAsync(con, "dbo.DenialLineItem", "ClaimUID", ct);
        var hasTaskClaimUid = await HasColumnAsync(con, "dbo.DenialTaskBoard", "ClaimUID", ct);
        var lineClaimUidExpr = hasLineClaimUid
            ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(l.ClaimUID,''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')))"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))";
        var linePageJoinSql = hasLineClaimUid
            ? "l.ClaimUID = p.ClaimUid"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')) = p.ClaimUid";
        var taskJoinSql = hasTaskClaimUid
            ? "t.ClaimUID = c.ClaimUid"
            : "t.ClaimIDNormalized = c.ClaimKey";
        var where = BuildClaimWhere(filter, "l");
        var lineLabScope = LabScopeSql("l.LabId");
        var taskLabScope = LabScopeSql("t.LabId");
        var escalationLabScope = LabScopeSql("e.LabId");
        var closedLabScope = LabScopeSql("dc.LabId");
        var normalizedStatusSql = NormalizedTaskStatusSql("t");
        var queueCaseSql = ClaimQueueCaseSql("r");
        var sql = $@"
IF OBJECT_ID('tempdb..#TaskClaimAgg') IS NOT NULL DROP TABLE #TaskClaimAgg;
IF OBJECT_ID('tempdb..#TaskClaimRaw') IS NOT NULL DROP TABLE #TaskClaimRaw;
IF OBJECT_ID('tempdb..#ClaimBase') IS NOT NULL DROP TABLE #ClaimBase;

SELECT
    ClaimUid = {lineClaimUidExpr},
    ClaimId = MAX(LTRIM(RTRIM(ISNULL(l.VisitNumber,'')))),
    ClaimKey = MAX(CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')))
INTO #ClaimBase
FROM dbo.DenialLineItem l WITH (NOLOCK)
WHERE {lineLabScope}
  AND NULLIF(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))),'') IS NOT NULL
  {where.WhereClause}
GROUP BY {lineClaimUidExpr};

CREATE NONCLUSTERED INDEX IX_ClaimBase_ClaimUid ON #ClaimBase(ClaimUid);

-- Claim status precedence is intentionally centralized here and mirrored in GetClaimsAsync.
-- The order follows ClaimStatusPrecedenceScenarios.xlsx: escalation wins, then write-off, documentation,
-- payer follow-up, payer response, all-closed, assigned, and finally age-based new/unassigned.
SELECT
    ClaimUid = c.ClaimUid,
    InternalEscalationCount = SUM(CASE WHEN {normalizedStatusSql} = 'Internal Escalation' THEN 1 ELSE 0 END),
    ExternalEscalationCount = SUM(CASE WHEN {normalizedStatusSql} = 'External Escalation' THEN 1 ELSE 0 END),
    PendingDocumentationCount = SUM(CASE WHEN {normalizedStatusSql} = 'Pending Documentation' THEN 1 ELSE 0 END),
    WriteOffApprovalCount = SUM(CASE WHEN {normalizedStatusSql} = 'Write Off Approval Pending' THEN 1 ELSE 0 END),
    PayerFollowupCount = SUM(CASE WHEN {normalizedStatusSql} = 'Payer Followup Required' THEN 1 ELSE 0 END),
    PendingPayerResponseCount = SUM(CASE WHEN {normalizedStatusSql} = 'Pending Payer Response' THEN 1 ELSE 0 END),
    ClosedCount = SUM(CASE WHEN {normalizedStatusSql} = 'Closed' THEN 1 ELSE 0 END),
    OpenCount = SUM(CASE WHEN {normalizedStatusSql} NOT IN ('Closed','Unassigned') THEN 1 ELSE 0 END),
    AssignedTaskCount = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NOT NULL AND {normalizedStatusSql} <> 'Closed' THEN 1 ELSE 0 END),
    UnassignedTaskCount = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NULL AND {normalizedStatusSql} <> 'Closed' THEN 1 ELSE 0 END),
    TaskCount = COUNT(t.TaskID),
    AssignedReviewerCount = COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'')),
    MaxCreatedOn = MAX(t.CreatedOn),
    HasVerification = MAX(CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) IN ('required review','verification pending') THEN 1 ELSE 0 END),
    HasEscalationResponse = CASE WHEN EXISTS (
            SELECT 1 FROM dbo.DenialClaimEscalations e WITH (NOLOCK)
            WHERE e.IsDeleted=0 AND {escalationLabScope} AND e.ClaimId IN (c.ClaimUid, c.ClaimId)
              AND (LOWER(LTRIM(RTRIM(ISNULL(e.Status,'')))) IN ('in review','responded','response submitted','manager response')
                   OR ISNULL(e.Comments,'') LIKE '%Manager Response:%'
                   OR ISNULL(e.Comments,'') LIKE '%Client Response:%'
                   OR ISNULL(e.Comments,'') LIKE '%Account Manager Response:%')
        ) THEN 1 ELSE 0 END,
    ExternalEscalationExists = CASE WHEN EXISTS (
            SELECT 1 FROM dbo.DenialClaimEscalations e WITH (NOLOCK)
            WHERE e.IsDeleted=0 AND {escalationLabScope} AND e.ClaimId IN (c.ClaimUid, c.ClaimId)
              AND (LOWER(LTRIM(RTRIM(ISNULL(e.EscalatedToRole,'')))) LIKE '%clientmanager%'
                   OR LOWER(LTRIM(RTRIM(ISNULL(e.EscalatedToRole,'')))) LIKE '%accountmanager%'
                   OR LOWER(LTRIM(RTRIM(ISNULL(e.EscalatedTo,'')))) LIKE '%client manager%'
                   OR LOWER(LTRIM(RTRIM(ISNULL(e.EscalatedTo,'')))) LIKE '%account manager%')
        ) THEN 1 ELSE 0 END
INTO #TaskClaimRaw
FROM #ClaimBase c
LEFT JOIN dbo.DenialTaskBoard t WITH (NOLOCK)
  ON {taskJoinSql}
 AND {taskLabScope}
GROUP BY c.ClaimUid, c.ClaimId, c.ClaimKey;

UPDATE #TaskClaimRaw SET ExternalEscalationCount = ExternalEscalationCount + ExternalEscalationExists;

SELECT r.*, [Status] = {queueCaseSql}, QueueName = {queueCaseSql}
INTO #TaskClaimAgg
FROM #TaskClaimRaw r;

SELECT
    TotalClaims = COUNT(1),
    [New] = SUM(CASE WHEN ISNULL(tca.[Status], 'New') = 'New' THEN 1 ELSE 0 END),
    Unassigned = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Unassigned' THEN 1 ELSE 0 END),
    Assigned = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Assigned' THEN 1 ELSE 0 END),
    PayerFollowup = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Payer Followup' THEN 1 ELSE 0 END),
    PendingDocumentation = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Pending Documentation' THEN 1 ELSE 0 END),
    PendingPayerResponse = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Pending Payer Response' THEN 1 ELSE 0 END),
    WriteOffApproval = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Write-Off Approval' THEN 1 ELSE 0 END),
    Closed = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Closed' THEN 1 ELSE 0 END),
    Escalated = SUM(CASE WHEN ISNULL(tca.[Status], '') IN ('Internal Escalation','External Escalation','Escalation Response') THEN 1 ELSE 0 END),
    InternalEscalation = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Internal Escalation' THEN 1 ELSE 0 END),
    ExternalEscalation = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'External Escalation' THEN 1 ELSE 0 END),
    EscalationResponse = SUM(CASE WHEN ISNULL(tca.[Status], '') = 'Escalation Response' THEN 1 ELSE 0 END),
    Verification = SUM(ISNULL(tca.HasVerification, 0))
FROM #ClaimBase c
LEFT JOIN #TaskClaimAgg tca ON tca.ClaimUid = c.ClaimUid;

DROP TABLE #ClaimBase;
DROP TABLE #TaskClaimRaw;
DROP TABLE #TaskClaimAgg;";

        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 300 };
        AddFilterParams(cmd, filter);
        AddExtraParams(cmd, where.Parameters);
        await using var rd = await cmd.ExecuteReaderAsync(ct);

        var result = new ClaimSubMenuCounts();
        if (await rd.ReadAsync(ct))
        {
            result.TotalClaims = GetInt(rd, "TotalClaims");
            result.New = GetInt(rd, "New");
            result.Unassigned = GetInt(rd, "Unassigned");
            result.Assigned = GetInt(rd, "Assigned");
            result.PayerFollowup = GetInt(rd, "PayerFollowup");
            result.PendingDocumentation = GetInt(rd, "PendingDocumentation");
            result.PendingPayerResponse = GetInt(rd, "PendingPayerResponse");
            result.WriteOffApproval = GetInt(rd, "WriteOffApproval");
            result.Closed = GetInt(rd, "Closed");
            result.Escalated = GetInt(rd, "Escalated");
            result.InternalEscalation = GetInt(rd, "InternalEscalation");
            result.ExternalEscalation = GetInt(rd, "ExternalEscalation");
            result.EscalationResponse = GetInt(rd, "EscalationResponse");
            result.Verification = GetInt(rd, "Verification");
        }

        ClaimCountsCache[cacheKey] = new ClaimCountsCacheEntry(DateTime.UtcNow, result);
        return result;
    }

    public async Task<IReadOnlyList<ReviewerWorkflowSummaryRow>> GetReviewerSummaryAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        var sql = $@"SELECT ReviewerName = COALESCE(NULLIF(AssignedTo,''), 'Unassigned'),
TotalAssigned = COUNT(1),
TotalTasks = COUNT(1),
TotalClaims = COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ISNULL(ClaimIDNormalized, ClaimID))),'')),
Assigned = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(AssignedTo,''))),'') IS NOT NULL AND LOWER(LTRIM(RTRIM(ISNULL(Status,'')))) NOT IN ('closed','completed') THEN 1 ELSE 0 END),
InProgress = SUM(CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(Status,'')))) IN ('in-progress','in progress','progress') OR LOWER(LTRIM(RTRIM(ISNULL(Status,'')))) LIKE '%progress%' THEN 1 ELSE 0 END),
Closed = SUM(CASE WHEN ISNULL(Status,'') IN ('Closed','Completed') THEN 1 ELSE 0 END),
ClosedTasks = SUM(CASE WHEN ISNULL(Status,'') IN ('Closed','Completed') THEN 1 ELSE 0 END),
Pending = SUM(CASE WHEN ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END),
PendingTasks = SUM(CASE WHEN ISNULL(Status,'') NOT IN ('Closed','Completed') THEN 1 ELSE 0 END)
FROM dbo.DenialTaskBoard WITH (NOLOCK)
WHERE {LabScopeSql("LabId")}
GROUP BY COALESCE(NULLIF(AssignedTo,''), 'Unassigned')
ORDER BY TotalTasks DESC;";
        var rows = new List<ReviewerWorkflowSummaryRow>();
        await using var con = OpenLab(filter.LabId); await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con); AddLabScopeParams(cmd, filter.LabId);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct)) rows.Add(new ReviewerWorkflowSummaryRow { ReviewerName = GetString(rd, "ReviewerName"), TotalAssigned = GetInt(rd, "TotalAssigned"), TotalTasks = GetInt(rd, "TotalTasks"), TotalClaims = GetInt(rd, "TotalClaims"), Assigned = GetInt(rd, "Assigned"), InProgress = GetInt(rd, "InProgress"), Closed = GetInt(rd, "Closed"), ClosedTasks = GetInt(rd, "ClosedTasks"), Pending = GetInt(rd, "Pending"), PendingTasks = GetInt(rd, "PendingTasks") });
        return rows;
    }

    public async Task<PagedResult<DenialWorkflowInsightRow>> GetInsightsAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        filter.PageSize = filter.PageSize <= 0 ? 50 : Math.Clamp(filter.PageSize, 25, 200); if (filter.Page <= 0) filter.Page = 1;
        var where = BuildCommonWhere(filter, "i", includeStatus: false, includeAssigned: true);
        var insightLabScope = NullableLabScopeSql("i.LabId");
        var sql = $@"
DECLARE @HasInsightLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialInsight WITH (NOLOCK) WHERE {NullableLabScopeSql("LabId")}) THEN 1 ELSE 0 END;

SELECT COUNT_BIG(1)
FROM dbo.DenialInsight i WITH (NOLOCK)
WHERE (@HasInsightLab=0 OR {insightLabScope}) {where.WhereClause};

SELECT i.DenialCodes,i.Descriptions,i.NoOfDenialCount,i.NoOfClaimsCount,i.TotalBalance,i.HighImpactInsurance,i.InsuranceBalance,i.ImpactPercentage,i.ActionCategory,i.ActionCode,i.Action,i.Task,i.Feedback,i.Responsibility,i.DiscussionDate,i.ETA,i.LabName,i.LabId,i.RunId,i.CreatedOn,i.AssignedTo,i.ResponsibilityReviewer
FROM dbo.DenialInsight i WITH (NOLOCK)
WHERE (@HasInsightLab=0 OR {insightLabScope}) {where.WhereClause}
ORDER BY i.InsuranceBalance DESC, i.DenialCodes
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";
        var result = new PagedResult<DenialWorkflowInsightRow> { Page = filter.Page, PageSize = filter.PageSize };
        await using var con = OpenLab(filter.LabId); await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 }; AddFilterParams(cmd, filter); AddExtraParams(cmd, where.Parameters); AddPagingParams(cmd, filter);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct)) result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) result.Items.Add(ReadInsight(rd));
        return result;
    }

    public async Task<PagedResult<ClaimLevelRow>> GetClaimsAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        filter.PageSize = 100;
        if (filter.Page <= 0) filter.Page = 1;

        await using var con = OpenLab(filter.LabId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        await EnsureClaimSupportTablesAsync(filter.LabId, ct);

        if (string.Equals(NormalizeTaskView(filter.TaskView), "closed", StringComparison.OrdinalIgnoreCase))
            return await GetClosedClaimsAsync(con, filter, ct);

        var lineColumns = await GetColumnSetAsync(con, "dbo.DenialLineItem", ct);
        var patientNameSelect = lineColumns.Contains("PatName")
            ? "LTRIM(RTRIM(ISNULL(l.PatName,'')))"
            : lineColumns.Contains("PatientName")
                ? "LTRIM(RTRIM(ISNULL(l.PatientName,'')))"
                : "CAST('' AS nvarchar(255))";
        var subscriberColumn = lineColumns.Contains("SubscriberID") ? "SubscriberID" : lineColumns.Contains("SubscriberId") ? "SubscriberId" : string.Empty;
        var subscriberIdSelect = !string.IsNullOrWhiteSpace(subscriberColumn)
            ? $"LTRIM(RTRIM(ISNULL(l.{subscriberColumn},'')))"
            : "CAST('' AS nvarchar(255))";
        var sourceSelect = lineColumns.Contains("Source")
            ? "LTRIM(RTRIM(ISNULL(l.Source,'')))"
            : "CAST('' AS nvarchar(255))";
        var hasLineClaimUid = await HasColumnAsync(con, "dbo.DenialLineItem", "ClaimUID", ct);
        var hasTaskClaimUid = await HasColumnAsync(con, "dbo.DenialTaskBoard", "ClaimUID", ct);
        var hasAccessionNo = await HasColumnAsync(con, "dbo.DenialLineItem", "AccessionNo", ct);
        var hasAccessionNumber = await HasColumnAsync(con, "dbo.DenialLineItem", "AccessionNumber", ct);
        var lineClaimUidExpr = hasLineClaimUid
            ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(l.ClaimUID,''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')))"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))";
        var linePageJoinSql = hasLineClaimUid
            ? "l.ClaimUID = p.ClaimUid"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')) = p.ClaimUid";
        var taskJoinSql = hasTaskClaimUid
            ? "t.ClaimUID = cb.ClaimUid"
            : "t.ClaimIDNormalized = cb.ClaimKey";
        var accessionNumberSelect = hasAccessionNo
            ? "LTRIM(RTRIM(ISNULL(l.AccessionNo,'')))"
            : hasAccessionNumber
            ? "LTRIM(RTRIM(ISNULL(l.AccessionNumber,'')))"
            : "CAST('' AS nvarchar(150))";
        var baseFilter = new DenialWorkflowFilter
        {
            LabId = filter.LabId,
            Role = filter.Role,
            UserName = filter.UserName,
            Status = filter.Status,
            Reviewer = filter.Reviewer,
            AssignedTo = filter.AssignedTo,
            DenialCode = filter.DenialCode,
            PayerName = filter.PayerName,
            PanelName = filter.PanelName,
            Clinic = filter.Clinic,
            SalesRepname = filter.SalesRepname,
            ReferringProvider = filter.ReferringProvider,
            DenialClassification = filter.DenialClassification,
            ActionCategory = filter.ActionCategory,
            Priority = filter.Priority,
            RunId = filter.RunId,
            SearchText = filter.SearchText,
            FromDate = filter.FromDate,
            ToDate = filter.ToDate,
            Page = filter.Page,
            PageSize = filter.PageSize
        };
        var where = BuildClaimWhere(baseFilter, "l");
        var lineLabScope = LabScopeSql("l.LabId");
        var taskLabScope = LabScopeSql("t.LabId");
        var escalationLabScope = LabScopeSql("e.LabId");
        var claimView = NormalizeTaskView(filter.TaskView);
        var normalizedStatusSql = NormalizedTaskStatusSql("t");
        var queueCaseSql = ClaimQueueCaseSql("r");
        var claimStatusCaseSql = ClaimStatusCaseSql("r");
        var claimStatusWhere = ClaimQueueWhereSql(claimView);

        var sql = $@"
IF OBJECT_ID('tempdb..#TaskClaimAgg') IS NOT NULL DROP TABLE #TaskClaimAgg;
IF OBJECT_ID('tempdb..#TaskClaimRaw') IS NOT NULL DROP TABLE #TaskClaimRaw;
IF OBJECT_ID('tempdb..#ClaimPage') IS NOT NULL DROP TABLE #ClaimPage;
IF OBJECT_ID('tempdb..#FilteredClaims') IS NOT NULL DROP TABLE #FilteredClaims;
IF OBJECT_ID('tempdb..#PageLineDetails') IS NOT NULL DROP TABLE #PageLineDetails;
IF OBJECT_ID('tempdb..#ClaimBase') IS NOT NULL DROP TABLE #ClaimBase;
IF OBJECT_ID('tempdb..#EscalationClaimAgg') IS NOT NULL DROP TABLE #EscalationClaimAgg;

SELECT
    ClaimUid = {lineClaimUidExpr},
    ClaimId = MAX(LTRIM(RTRIM(ISNULL(l.VisitNumber,'')))),
    VisitNumber = MAX(LTRIM(RTRIM(ISNULL(l.VisitNumber,'')))),
    ClaimKey = MAX(CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))),
    DateOfService = MAX(l.DateOfService)
INTO #ClaimBase
FROM dbo.DenialLineItem l WITH (NOLOCK)
WHERE {lineLabScope}
  AND NULLIF(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))),'') IS NOT NULL
  {where.WhereClause}
GROUP BY {lineClaimUidExpr};

CREATE CLUSTERED INDEX IX_ClaimBase_Page ON #ClaimBase(DateOfService DESC, ClaimId);
CREATE NONCLUSTERED INDEX IX_ClaimBase_ClaimUid ON #ClaimBase(ClaimUid);

SELECT
    ClaimUid = cb.ClaimUid,
    HasEscalationResponse = MAX(CASE
        WHEN e.EscalationId IS NOT NULL
         AND (LOWER(LTRIM(RTRIM(ISNULL(e.Status,'')))) IN ('in review','responded','response submitted','manager response')
              OR ISNULL(e.Comments,'') LIKE '%Manager Response:%'
              OR ISNULL(e.Comments,'') LIKE '%Client Response:%'
              OR ISNULL(e.Comments,'') LIKE '%Account Manager Response:%')
        THEN 1 ELSE 0 END),
    ExternalEscalationExists = MAX(CASE
        WHEN e.EscalationId IS NOT NULL
         AND (LOWER(LTRIM(RTRIM(ISNULL(e.EscalatedToRole,'')))) LIKE '%clientmanager%'
              OR LOWER(LTRIM(RTRIM(ISNULL(e.EscalatedToRole,'')))) LIKE '%accountmanager%'
              OR LOWER(LTRIM(RTRIM(ISNULL(e.EscalatedTo,'')))) LIKE '%client manager%'
              OR LOWER(LTRIM(RTRIM(ISNULL(e.EscalatedTo,'')))) LIKE '%account manager%')
        THEN 1 ELSE 0 END)
INTO #EscalationClaimAgg
FROM #ClaimBase cb
LEFT JOIN dbo.DenialClaimEscalations e WITH (NOLOCK)
  ON e.IsDeleted=0
 AND {escalationLabScope}
 AND (e.ClaimId = cb.ClaimUid OR e.ClaimId = cb.ClaimId)
GROUP BY cb.ClaimUid;

CREATE UNIQUE CLUSTERED INDEX IX_EscalationClaimAgg_ClaimUid ON #EscalationClaimAgg(ClaimUid);

SELECT
    ClaimUid = cb.ClaimUid,
    AssignedReviewerCount = COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'')),
    AssignedTo = CASE
        WHEN COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'')) = 0 THEN ''
        WHEN COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'')) = 1 THEN MAX(NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),''))
        ELSE CONCAT('Multiple (', COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'')), ')')
    END,
    InternalEscalationCount = SUM(CASE WHEN {normalizedStatusSql} = 'Internal Escalation' THEN 1 ELSE 0 END),
    ExternalEscalationCount = SUM(CASE WHEN {normalizedStatusSql} = 'External Escalation' THEN 1 ELSE 0 END),
    PendingDocumentationCount = SUM(CASE WHEN {normalizedStatusSql} = 'Pending Documentation' THEN 1 ELSE 0 END),
    WriteOffApprovalCount = SUM(CASE WHEN {normalizedStatusSql} = 'Write Off Approval Pending' THEN 1 ELSE 0 END),
    PayerFollowupCount = SUM(CASE WHEN {normalizedStatusSql} = 'Payer Followup Required' THEN 1 ELSE 0 END),
    PendingPayerResponseCount = SUM(CASE WHEN {normalizedStatusSql} = 'Pending Payer Response' THEN 1 ELSE 0 END),
    ClosedCount = SUM(CASE WHEN {normalizedStatusSql} = 'Closed' THEN 1 ELSE 0 END),
    OpenCount = SUM(CASE WHEN {normalizedStatusSql} NOT IN ('Closed','Unassigned') THEN 1 ELSE 0 END),
    AssignedTaskCount = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NOT NULL AND {normalizedStatusSql} <> 'Closed' THEN 1 ELSE 0 END),
    UnassignedTaskCount = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NULL AND {normalizedStatusSql} <> 'Closed' THEN 1 ELSE 0 END),
    TaskCount = COUNT(t.TaskID),
    MaxCreatedOn = MAX(t.CreatedOn),
    HasVerification = MAX(CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) IN ('required review','verification pending') THEN 1 ELSE 0 END),
    HasEscalationResponse = ISNULL(MAX(eca.HasEscalationResponse), 0),
    ExternalEscalationExists = ISNULL(MAX(eca.ExternalEscalationExists), 0),
    WorkFlowStatus = CASE
        WHEN MAX(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(t.WorkFlowStatus,''))),'') IS NOT NULL THEN 1 ELSE 0 END) = 1
            THEN MAX(NULLIF(LTRIM(RTRIM(ISNULL(t.WorkFlowStatus,''))),''))
        ELSE 'New'
    END,
    CreatedOn = MAX(t.CreatedOn)
INTO #TaskClaimRaw
FROM #ClaimBase cb
LEFT JOIN #EscalationClaimAgg eca ON eca.ClaimUid = cb.ClaimUid
LEFT JOIN dbo.DenialTaskBoard t WITH (NOLOCK)
  ON {taskJoinSql}
 AND {taskLabScope}
GROUP BY cb.ClaimUid, cb.ClaimId, cb.ClaimKey;

UPDATE #TaskClaimRaw SET ExternalEscalationCount = ExternalEscalationCount + ExternalEscalationExists;

SELECT
    r.*,
    [Status] = {queueCaseSql},
    QueueName = {queueCaseSql},
    ClaimQueue = {queueCaseSql},
    ClaimStatus = {claimStatusCaseSql},
    DerivedWorkFlowStatus = {claimStatusCaseSql}
INTO #TaskClaimAgg
FROM #TaskClaimRaw r;

SELECT
    c.ClaimUid,
    c.ClaimId,
    c.VisitNumber,
    c.DateOfService,
    AssignedTo = ISNULL(tca.AssignedTo, ''),
    [Status] = ISNULL(tca.[Status], ''),
    ClaimStatus = ISNULL(NULLIF(tca.ClaimStatus, ''), ISNULL(tca.[Status], '')),
    WorkflowStatus = ISNULL(NULLIF(tca.WorkFlowStatus, ''), ISNULL(tca.DerivedWorkFlowStatus, ISNULL(tca.[Status], ''))),
    QueueName = ISNULL(tca.QueueName, ''),
    ClaimQueue = ISNULL(tca.ClaimQueue, ''),
    TaskCount = ISNULL(CONVERT(int, tca.TaskCount), 0),
    CreatedOn = tca.CreatedOn
INTO #FilteredClaims
FROM #ClaimBase c
LEFT JOIN #TaskClaimAgg tca ON tca.ClaimUid = c.ClaimUid
WHERE {claimStatusWhere};

SELECT COUNT(1) FROM #FilteredClaims;

SELECT *
INTO #ClaimPage
FROM #FilteredClaims
ORDER BY DateOfService DESC, ClaimId
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

SELECT
    p.ClaimUid,
    AccessionNumber = MAX({accessionNumberSelect}),
    Source = MAX({sourceSelect}),
    PayerName = MAX(LTRIM(RTRIM(ISNULL(l.PayerName,'')))),
    PanelName = MAX(LTRIM(RTRIM(ISNULL(l.PanelName,'')))),
    PatientName = MAX({patientNameSelect}),
    PatientDOB = MAX(l.PatientDOB),
    ClinicName = MAX(LTRIM(RTRIM(ISNULL(l.ClinicName,'')))),
    ReferringProvider = MAX(LTRIM(RTRIM(ISNULL(l.ReferringProvider,'')))),
    PatientId = MAX(LTRIM(RTRIM(ISNULL(l.PatientID,'')))),
    SubscriberId = MAX({subscriberIdSelect}),
    SalesRepname = MAX(LTRIM(RTRIM(ISNULL(l.SalesRepname,'')))),
    InsuranceBalance = CAST(SUM(ISNULL(l.InsuranceBalance, 0)) AS decimal(18,2))
INTO #PageLineDetails
FROM #ClaimPage p
JOIN dbo.DenialLineItem l WITH (NOLOCK)
  ON {linePageJoinSql}
 AND {lineLabScope}
GROUP BY p.ClaimUid;

SELECT
    c.ClaimUid,
    c.ClaimId,
    c.VisitNumber,
    AccessionNumber = ISNULL(d.AccessionNumber, ''),
    Source = ISNULL(d.Source, ''),
    PayerName = ISNULL(d.PayerName, ''),
    PanelName = ISNULL(d.PanelName, ''),
    PatientName = ISNULL(d.PatientName, ''),
    d.PatientDOB,
    c.DateOfService,
    ClinicName = ISNULL(d.ClinicName, ''),
    ReferringProvider = ISNULL(d.ReferringProvider, ''),
    PatientId = ISNULL(d.PatientId, ''),
    SubscriberId = ISNULL(d.SubscriberId, ''),
    SalesRepname = ISNULL(d.SalesRepname, ''),
    c.AssignedTo,
    c.[Status],
    c.ClaimStatus,
    c.WorkflowStatus,
    c.QueueName,
    c.ClaimQueue,
    c.TaskCount,
    c.CreatedOn,
    InsuranceBalance = ISNULL(d.InsuranceBalance, 0)
FROM #ClaimPage c
LEFT JOIN #PageLineDetails d ON d.ClaimUid = c.ClaimUid
ORDER BY c.DateOfService DESC, c.ClaimId;

DROP TABLE #ClaimPage;
DROP TABLE #FilteredClaims;
DROP TABLE #PageLineDetails;
DROP TABLE #ClaimBase;
DROP TABLE #EscalationClaimAgg;
DROP TABLE #TaskClaimRaw;
DROP TABLE #TaskClaimAgg;";

        var result = new PagedResult<ClaimLevelRow>
        {
            Page = filter.Page,
            PageSize = filter.PageSize
        };

        await using var cmd = new SqlCommand(sql, con)
        {
            CommandTimeout = 300
        };

        AddFilterParams(cmd, filter);
        AddExtraParams(cmd, where.Parameters);
        AddPagingParams(cmd, filter);

        await using var rd = await cmd.ExecuteReaderAsync(ct);

        if (await rd.ReadAsync(ct))
            result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);

        if (await rd.NextResultAsync(ct))
        {
            while (await rd.ReadAsync(ct))
                result.Items.Add(ReadClaim(rd));
        }

        return result;
    }

    public async Task<int> WriteClaimsExportAsync(DenialWorkflowFilter filter, Stream output, CancellationToken ct)
    {
        await using var con = OpenLab(filter.LabId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        await EnsureClaimSupportTablesAsync(filter.LabId, ct);
        if (filter.UploadTemplate)
            return await WriteClaimUploadTemplateAsync(con, filter, output, ct);
        try
        {
            return await WriteTaskBoardClaimsExportAsync(con, filter, output, ct);
        }
        catch (SqlException)
        {
            ResetOutputStream(output);
            return await WriteTaskBoardClaimsBasicExportAsync(con, filter, output, ct);
        }
    }

    private async Task<int> WriteTaskBoardClaimsBasicExportAsync(SqlConnection con, DenialWorkflowFilter filter, Stream output, CancellationToken ct)
    {
        var where = BuildCommonWhere(filter, "t", includeStatus: true, includeAssigned: true);
        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);

        string TextExpr(string column)
            => taskColumns.Contains(column) ? $"LTRIM(RTRIM(ISNULL(t.[{column}],'')))" : "CAST('' AS nvarchar(max))";
        string DateExpr(string column)
            => taskColumns.Contains(column) ? $"TRY_CONVERT(datetime2, t.[{column}])" : "CAST(NULL AS datetime2)";
        string MoneyExpr(string column)
            => taskColumns.Contains(column) ? $"TRY_CONVERT(decimal(18,2), t.[{column}])" : "CAST(NULL AS decimal(18,2))";
        string IntTextExpr(string column)
            => taskColumns.Contains(column) ? $"LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(255), t.[{column}]),'')))" : "CAST('' AS nvarchar(max))";
        string CoalesceText(string alias, params string[] exprs)
            => $"COALESCE({string.Join(", ", exprs.Select(x => $"NULLIF({x}, '')").Concat(["CAST('' AS nvarchar(max))"]))}) AS [{alias}]";
        string CoalesceDate(string alias, params string[] exprs)
            => $"COALESCE({string.Join(", ", exprs.Concat(["CAST(NULL AS datetime2)"]))}) AS [{alias}]";
        string CoalesceMoney(string alias, params string[] exprs)
            => $"CAST(ISNULL(COALESCE({string.Join(", ", exprs.Concat(["CAST(NULL AS decimal(18,2))"]))}), 0) AS decimal(18,2)) AS [{alias}]";

        var taskClaimKeyExpr = taskColumns.Contains("ClaimIDNormalized")
            ? "LTRIM(RTRIM(ISNULL(t.[ClaimIDNormalized],'')))"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.[ClaimID],''))), 'CLM-', ''))";
        var taskClaimUidExpr = taskColumns.Contains("ClaimUID")
            ? $"COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.[ClaimUID],''))), ''), {taskClaimKeyExpr})"
            : taskClaimKeyExpr;
        var taskLabDeclaration = taskColumns.Contains("LabId")
            ? $"DECLARE @HasTaskLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;"
            : "DECLARE @HasTaskLab bit = 0;";
        var taskLabPredicate = taskColumns.Contains("LabId")
            ? $"(@HasTaskLab = 0 OR {LabScopeSql("t.[LabId]")})"
            : "1 = 1";
        var orderByCreated = taskColumns.Contains("CreatedOn") ? "TRY_CONVERT(datetime2, t.[CreatedOn]) DESC," : string.Empty;

        var sql = $@"
{taskLabDeclaration}

SELECT
    {CoalesceText("ClaimID", TextExpr("ClaimID"))},
    ClaimUID = {taskClaimUidExpr},
    {CoalesceText("TaskID", TextExpr("TaskID"))},
    {CoalesceText("UniqueTrackId", TextExpr("UniqueTrackId"))},
    {CoalesceText("PatientName", TextExpr("PatName"), TextExpr("PatientName"))},
    {CoalesceText("PatientID", TextExpr("PatientId"), TextExpr("PatientID"))},
    {CoalesceDate("PatientDOB", DateExpr("PatientDOB"))},
    {CoalesceText("SubscriberId", TextExpr("SubscriberId"), TextExpr("SubscriberID"))},
    {CoalesceText("Source", TextExpr("Source"))},
    {CoalesceText("PayerName", TextExpr("PayerName"))},
    {CoalesceDate("DateOfService", DateExpr("DateOfService"))},
    {CoalesceDate("FirstBilledDate", DateExpr("FirstBilledDate"))},
    {CoalesceDate("ChargeEnteredDate", DateExpr("ChargeEnteredDate"))},
    {CoalesceText("ClinicName", TextExpr("ClinicName"))},
    {CoalesceText("ReferringProvider", TextExpr("ReferringProvider"))},
    {CoalesceText("SalesRepname", TextExpr("SalesRepname"))},
    {CoalesceText("PanelName", TextExpr("PanelName"))},
    {CoalesceText("CPTCode", TextExpr("CPTCode"))},
    {CoalesceText("Units", IntTextExpr("Units"))},
    {CoalesceText("Modifier", TextExpr("Modifier"))},
    {CoalesceText("DenialCode", TextExpr("DenialCode"))},
    {CoalesceText("DenialDescription", TextExpr("DenialDescription"))},
    {CoalesceMoney("InsuranceBalance", MoneyExpr("InsuranceBalance"))},
    {CoalesceText("DenialClassification", TextExpr("DenialClassification"))},
    {CoalesceText("ActionCategory", TextExpr("ActionCategory"))},
    {CoalesceText("ActionCode", TextExpr("ActionCode"))},
    {CoalesceText("RecommendedAction", TextExpr("RecommendedAction"))},
    {CoalesceText("TaskStatus", TextExpr("Status"))},
    {CoalesceText("WorkflowStatus", TextExpr("WorkFlowStatus"))},
    {CoalesceText("Priority", TextExpr("Priority"))},
    {CoalesceText("SLADays", IntTextExpr("SLADays"))},
    {CoalesceText("SLAStatus", TextExpr("SLAStatus"))},
    {CoalesceText("AssignedTo", TextExpr("AssignedTo"))},
    {CoalesceDate("CreatedOn", DateExpr("CreatedOn"))}
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE {taskLabPredicate}
  AND NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimID,''))),'') IS NOT NULL
  {where.WhereClause}
ORDER BY {orderByCreated} t.ClaimID, t.TaskID;";

        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 900 };
        AddFilterParams(cmd, filter);
        AddExtraParams(cmd, where.Parameters);
        await using var rd = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);
        return await WriteCsvAsync(rd, output, ct);
    }

    private async Task<int> WriteTaskBoardClaimsExportAsync(SqlConnection con, DenialWorkflowFilter filter, Stream output, CancellationToken ct)
    {
        var where = BuildCommonWhere(filter, "t", includeStatus: true, includeAssigned: true);
        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        var lineTableExists = await TableExistsAsync(con, "dbo.DenialLineItem", ct);
        var lineColumns = lineTableExists
            ? await GetColumnSetAsync(con, "dbo.DenialLineItem", ct)
            : new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        string TextExpr(HashSet<string> cols, string alias, string column)
            => cols.Contains(column) ? $"LTRIM(RTRIM(ISNULL({alias}.[{column}],'')))" : "CAST('' AS nvarchar(max))";
        string DateExpr(HashSet<string> cols, string alias, string column)
            => cols.Contains(column) ? $"TRY_CONVERT(datetime2, {alias}.[{column}])" : "CAST(NULL AS datetime2)";
        string MoneyExpr(HashSet<string> cols, string alias, string column)
            => cols.Contains(column) ? $"TRY_CONVERT(decimal(18,2), {alias}.[{column}])" : "CAST(NULL AS decimal(18,2))";
        string IntTextExpr(HashSet<string> cols, string alias, string column)
            => cols.Contains(column) ? $"LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(255), {alias}.[{column}]),'')))" : "CAST('' AS nvarchar(max))";
        string CoalesceText(string alias, params string[] exprs)
            => $"COALESCE({string.Join(", ", exprs.Select(x => $"NULLIF({x}, '')").Concat(["CAST('' AS nvarchar(max))"]))}) AS [{alias}]";
        string CoalesceDate(string alias, params string[] exprs)
            => $"COALESCE({string.Join(", ", exprs.Concat(["CAST(NULL AS datetime2)"]))}) AS [{alias}]";
        string CoalesceMoney(string alias, params string[] exprs)
            => $"CAST(ISNULL(COALESCE({string.Join(", ", exprs.Concat(["CAST(NULL AS decimal(18,2))"]))}), 0) AS decimal(18,2)) AS [{alias}]";

        var taskClaimKeyExpr = taskColumns.Contains("ClaimIDNormalized")
            ? "LTRIM(RTRIM(ISNULL(t.[ClaimIDNormalized],'')))"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.[ClaimID],''))), 'CLM-', ''))";
        var taskClaimUidExpr = taskColumns.Contains("ClaimUID")
            ? $"COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.[ClaimUID],''))), ''), {taskClaimKeyExpr})"
            : taskClaimKeyExpr;
        var lineClaimKeyExpr = lineColumns.Contains("ClaimUID")
            ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(lx.[ClaimUID],''))), ''), CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(lx.[VisitNumber],''))), 'CLM-', '')))"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(lx.[VisitNumber],''))), 'CLM-', ''))";
        var lineMatch = lineTableExists
            ? $"{lineClaimKeyExpr} = {taskClaimUidExpr}"
            : "1 = 0";
        if (lineColumns.Contains("CPTCode") && taskColumns.Contains("CPTCode"))
        {
            lineMatch += " AND (NULLIF(LTRIM(RTRIM(ISNULL(t.[CPTCode],''))),'') IS NULL OR LTRIM(RTRIM(ISNULL(lx.[CPTCode],''))) = LTRIM(RTRIM(ISNULL(t.[CPTCode],''))))";
        }
        if (lineColumns.Contains("LabId") && taskColumns.Contains("LabId"))
        {
            lineMatch += $" AND (@HasLineLab = 0 OR {LabScopeSql("lx.[LabId]")})";
        }

        var lineDetailPrepSql = lineTableExists
            ? $@"
SELECT
    t.__ExportRowId,
    __LineRank = ROW_NUMBER() OVER (
        PARTITION BY t.__ExportRowId
        ORDER BY {(lineColumns.Contains("DateOfService") ? "TRY_CONVERT(datetime2, lx.[DateOfService]) DESC," : string.Empty)} {(lineColumns.Contains("AccessionNo") ? "lx.[AccessionNo]" : lineColumns.Contains("AccessionNumber") ? "lx.[AccessionNumber]" : "1")}
    ),
    lx.*
INTO #LineOne
FROM #ExportTasks t
JOIN dbo.DenialLineItem lx WITH (NOLOCK)
  ON {lineMatch};

CREATE CLUSTERED INDEX IX_LineOne_RowRank ON #LineOne(__ExportRowId, __LineRank);"
            : @"
SELECT CAST(NULL AS int) AS __ExportRowId, CAST(NULL AS int) AS __LineRank, CAST(NULL AS int) AS EmptyLine
INTO #LineOne
WHERE 1 = 0;";
        var taskLabDeclaration = taskColumns.Contains("LabId")
            ? $"DECLARE @HasTaskLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;"
            : "DECLARE @HasTaskLab bit = 0;";
        var lineLabDeclaration = lineColumns.Contains("LabId")
            ? $"DECLARE @HasLineLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialLineItem WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;"
            : "DECLARE @HasLineLab bit = 0;";
        var taskLabPredicate = taskColumns.Contains("LabId")
            ? $"(@HasTaskLab = 0 OR {LabScopeSql("t.[LabId]")})"
            : "1 = 1";
        var orderByCreated = taskColumns.Contains("CreatedOn") ? "TRY_CONVERT(datetime2, t.[CreatedOn]) DESC," : string.Empty;

        var sql = $@"
{taskLabDeclaration}
{lineLabDeclaration}

IF OBJECT_ID('tempdb..#ExportTasks') IS NOT NULL DROP TABLE #ExportTasks;
IF OBJECT_ID('tempdb..#LineOne') IS NOT NULL DROP TABLE #LineOne;
IF OBJECT_ID('tempdb..#ClaimNotes') IS NOT NULL DROP TABLE #ClaimNotes;
IF OBJECT_ID('tempdb..#EscalationNotes') IS NOT NULL DROP TABLE #EscalationNotes;
IF OBJECT_ID('tempdb..#DocumentComments') IS NOT NULL DROP TABLE #DocumentComments;

SELECT
    IDENTITY(int, 1, 1) AS __ExportRowId,
    t.*
INTO #ExportTasks
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE {taskLabPredicate}
  AND NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimID,''))),'') IS NOT NULL
  {where.WhereClause};

CREATE CLUSTERED INDEX IX_ExportTasks_Row ON #ExportTasks(__ExportRowId);
CREATE NONCLUSTERED INDEX IX_ExportTasks_Task ON #ExportTasks(TaskID) INCLUDE (ClaimID, AssignedTo, Status);

{lineDetailPrepSql}

SELECT
    t.__ExportRowId,
    ClaimNotes = STRING_AGG(CONVERT(nvarchar(max),
        CONCAT(CONVERT(varchar(19), n.CreatedOn, 120), ' | ', ISNULL(n.CreatedBy,''), ' | ', ISNULL(n.Status,''), ' | ', ISNULL(n.NoteText,''))), CHAR(10))
INTO #ClaimNotes
FROM #ExportTasks t
	JOIN dbo.DenialClaimNotes n WITH (NOLOCK)
	  ON n.IsDeleted = 0
	 AND {LabScopeSql("n.LabId")}
 AND n.ClaimId IN ({taskClaimUidExpr}, {taskClaimKeyExpr}, LTRIM(RTRIM(ISNULL(t.[ClaimID],''))))
 AND (NULLIF(ISNULL(n.TaskId,''),'') IS NULL OR n.TaskId = t.TaskID)
GROUP BY t.__ExportRowId;

CREATE CLUSTERED INDEX IX_ClaimNotes_Row ON #ClaimNotes(__ExportRowId);

SELECT
    t.__ExportRowId,
    EscalationNotes = STRING_AGG(CONVERT(nvarchar(max),
        CONCAT(CONVERT(varchar(19), e.CreatedOn, 120), ' | ', ISNULL(e.CreatedBy,''), ' | ', ISNULL(e.EscalationReason,''), ' | ', ISNULL(e.Status,''), ' | To: ', ISNULL(e.EscalatedTo,''), ' | ', ISNULL(e.Comments,''))), CHAR(10))
INTO #EscalationNotes
FROM #ExportTasks t
	JOIN dbo.DenialClaimEscalations e WITH (NOLOCK)
	  ON e.IsDeleted = 0
	 AND {LabScopeSql("e.LabId")}
 AND e.ClaimId IN ({taskClaimUidExpr}, {taskClaimKeyExpr}, LTRIM(RTRIM(ISNULL(t.[ClaimID],''))))
 AND (NULLIF(ISNULL(e.TaskId,''),'') IS NULL OR e.TaskId = t.TaskID)
GROUP BY t.__ExportRowId;

CREATE CLUSTERED INDEX IX_EscalationNotes_Row ON #EscalationNotes(__ExportRowId);

SELECT
    t.__ExportRowId,
    DocumentComments = STRING_AGG(CONVERT(nvarchar(max),
        CONCAT(CONVERT(varchar(19), d.UploadedOn, 120), ' | ', ISNULL(d.UploadedBy,''), ' | ', ISNULL(d.OriginalFileName,''), ' | ', ISNULL(d.Comment,''))), CHAR(10))
INTO #DocumentComments
FROM #ExportTasks t
	JOIN dbo.DenialClaimDocuments d WITH (NOLOCK)
	  ON d.IsDeleted = 0
	 AND {LabScopeSql("d.LabId")}
 AND d.ClaimId IN ({taskClaimUidExpr}, {taskClaimKeyExpr}, LTRIM(RTRIM(ISNULL(t.[ClaimID],''))))
GROUP BY t.__ExportRowId;

CREATE CLUSTERED INDEX IX_DocumentComments_Row ON #DocumentComments(__ExportRowId);

SELECT
    {CoalesceText("ClaimID", TextExpr(taskColumns, "t", "ClaimID"))},
    {CoalesceText("AccessionNo", TextExpr(lineColumns, "l", "AccessionNo"), TextExpr(lineColumns, "l", "AccessionNumber"))},
    ClaimUID = {taskClaimUidExpr},
    {CoalesceText("TaskID", TextExpr(taskColumns, "t", "TaskID"))},
    {CoalesceText("PatientName", TextExpr(taskColumns, "t", "PatName"), TextExpr(taskColumns, "t", "PatientName"), TextExpr(lineColumns, "l", "PatName"), TextExpr(lineColumns, "l", "PatientName"))},
    {CoalesceText("PatientID", TextExpr(taskColumns, "t", "PatientId"), TextExpr(taskColumns, "t", "PatientID"), TextExpr(lineColumns, "l", "PatientID"), TextExpr(lineColumns, "l", "PatientId"))},
    {CoalesceDate("PateintDOB", DateExpr(taskColumns, "t", "PatientDOB"), DateExpr(lineColumns, "l", "PatientDOB"))},
    {CoalesceText("SubscriberId", TextExpr(taskColumns, "t", "SubscriberId"), TextExpr(taskColumns, "t", "SubscriberID"), TextExpr(lineColumns, "l", "SubscriberId"), TextExpr(lineColumns, "l", "SubscriberID"))},
    {CoalesceText("Source", TextExpr(taskColumns, "t", "Source"), TextExpr(lineColumns, "l", "Source"))},
    {CoalesceText("PayerName", TextExpr(taskColumns, "t", "PayerName"), TextExpr(lineColumns, "l", "PayerName"))},
    {CoalesceText("PayStatus", TextExpr(lineColumns, "l", "PayStatus"))},
    {CoalesceDate("DateOfService", DateExpr(taskColumns, "t", "DateOfService"), DateExpr(lineColumns, "l", "DateOfService"))},
    {CoalesceDate("FirstBilledDate", DateExpr(taskColumns, "t", "FirstBilledDate"), DateExpr(lineColumns, "l", "FirstBilledDate"))},
    {CoalesceDate("ChargeEnteredDate", DateExpr(taskColumns, "t", "ChargeEnteredDate"), DateExpr(lineColumns, "l", "ChargeEnteredDate"))},
    {CoalesceText("ClinicName", TextExpr(taskColumns, "t", "ClinicName"), TextExpr(lineColumns, "l", "ClinicName"))},
    {CoalesceText("ReferringProvider", TextExpr(taskColumns, "t", "ReferringProvider"), TextExpr(lineColumns, "l", "ReferringProvider"))},
    {CoalesceText("SalesRepname", TextExpr(taskColumns, "t", "SalesRepname"), TextExpr(lineColumns, "l", "SalesRepname"))},
    {CoalesceText("DenialValidity", TextExpr(taskColumns, "t", "DenialValidity"), TextExpr(lineColumns, "l", "DenialValidity"))},
    {CoalesceText("ICDComplianceStatus", TextExpr(taskColumns, "t", "ICDComplianceStatus"), TextExpr(lineColumns, "l", "ICDComplianceStatus"))},
    {CoalesceText("FinalCoverageStatus", TextExpr(lineColumns, "l", "FinalCoverageStatus"))},
    {CoalesceText("PanelName", TextExpr(taskColumns, "t", "PanelName"), TextExpr(lineColumns, "l", "PanelName"))},
    {CoalesceText("CPTCode", TextExpr(taskColumns, "t", "CPTCode"), TextExpr(lineColumns, "l", "CPTCode"))},
    {CoalesceText("Units", IntTextExpr(taskColumns, "t", "Units"), IntTextExpr(lineColumns, "l", "Units"))},
    {CoalesceText("Modifier", TextExpr(taskColumns, "t", "Modifier"), TextExpr(lineColumns, "l", "Modifier"))},
    {CoalesceText("DenialCode", TextExpr(taskColumns, "t", "DenialCode"), TextExpr(lineColumns, "l", "DenialCodeNormalized"), TextExpr(lineColumns, "l", "DenialCodeOriginal"))},
    {CoalesceText("DenialDescription", TextExpr(taskColumns, "t", "DenialDescription"), TextExpr(lineColumns, "l", "DenialDescription"))},
    {CoalesceMoney("BilledAmount", MoneyExpr(lineColumns, "l", "BilledAmount"), MoneyExpr(lineColumns, "l", "BilledCharges"))},
    {CoalesceMoney("InsuranceBalance", MoneyExpr(taskColumns, "t", "InsuranceBalance"), MoneyExpr(lineColumns, "l", "InsuranceBalance"))},
    {CoalesceText("FinalClaimStatus", TextExpr(lineColumns, "l", "FinalClaimStatus"))},
    {CoalesceText("ActionComment", TextExpr(lineColumns, "l", "ActionComment"))},
    {CoalesceDate("DenialDate", DateExpr(lineColumns, "l", "DenialDate"))},
    {CoalesceText("DaystoDOS", IntTextExpr(lineColumns, "l", "DaystoDOS"))},
    {CoalesceText("DaystoBill", IntTextExpr(lineColumns, "l", "DaystoBill"))},
    {CoalesceText("DenialClassification", TextExpr(taskColumns, "t", "DenialClassification"), TextExpr(lineColumns, "l", "DenialClassification"))},
    {CoalesceText("DenialType", TextExpr(lineColumns, "l", "DenialType"))},
    {CoalesceText("ActionCategory", TextExpr(taskColumns, "t", "ActionCategory"), TextExpr(lineColumns, "l", "ActionCategory"))},
    {CoalesceText("ActionCode", TextExpr(taskColumns, "t", "ActionCode"), TextExpr(lineColumns, "l", "ActionCode"))},
    {CoalesceText("RecommendedAction", TextExpr(taskColumns, "t", "RecommendedAction"), TextExpr(lineColumns, "l", "RecommendedAction"))},
    {CoalesceText("TaskGuidance", TextExpr(lineColumns, "l", "TaskGuidance"))},
    {CoalesceText("TaskStatus", TextExpr(lineColumns, "l", "TaskStatus"), TextExpr(taskColumns, "t", "Status"))},
    {CoalesceText("ShortCategory", TextExpr(lineColumns, "l", "ShortCategory"))},
    {CoalesceText("Priority", TextExpr(taskColumns, "t", "Priority"), TextExpr(lineColumns, "l", "Priority"))},
    {CoalesceText("SLADays", IntTextExpr(taskColumns, "t", "SLADays"), TextExpr(lineColumns, "l", "SLADays"))},
    ClaimNotes = ISNULL(notes.ClaimNotes, ''),
    EscalationNotes = ISNULL(escalations.EscalationNotes, ''),
    CombinedNotes = CONCAT_WS(CHAR(10) + CHAR(10), NULLIF(notes.ClaimNotes, ''), NULLIF(escalations.EscalationNotes, '')),
    DocumentComments = ISNULL(documents.DocumentComments, ''),
    {CoalesceText("AssignedTo", TextExpr(taskColumns, "t", "AssignedTo"))}
FROM #ExportTasks t
LEFT JOIN #LineOne l ON l.__ExportRowId = t.__ExportRowId AND l.__LineRank = 1
LEFT JOIN #ClaimNotes notes ON notes.__ExportRowId = t.__ExportRowId
LEFT JOIN #EscalationNotes escalations ON escalations.__ExportRowId = t.__ExportRowId
LEFT JOIN #DocumentComments documents ON documents.__ExportRowId = t.__ExportRowId
ORDER BY {orderByCreated} t.ClaimID, t.TaskID;";

        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 1800 };
        AddFilterParams(cmd, filter);
        AddExtraParams(cmd, where.Parameters);
        await using var rd = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct);
        return await WriteCsvAsync(rd, output, ct);
    }

    private async Task<PagedResult<ClaimLevelRow>> GetClosedClaimsAsync(SqlConnection con, DenialWorkflowFilter filter, CancellationToken ct)
    {
        var whereParts = new List<string> { LabScopeSql("c.LabId") };
        var parameters = new Dictionary<string, object>();

        if (!string.IsNullOrWhiteSpace(filter.AssignedTo))
        {
            whereParts.Add(TextInSql("ISNULL(c.AssignedTo,'')", "@AssignedTo"));
            parameters["@AssignedTo"] = filter.AssignedTo.Trim();
        }

        if (!string.IsNullOrWhiteSpace(filter.Reviewer))
        {
            whereParts.Add(TextInSql("ISNULL(c.AssignedTo,'')", "@Reviewer"));
            parameters["@Reviewer"] = filter.Reviewer.Trim();
        }

        if (!string.IsNullOrWhiteSpace(filter.PayerName))
        {
            whereParts.Add(TextInSql("ISNULL(c.PayerName,'')", "@PayerName"));
            parameters["@PayerName"] = filter.PayerName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(filter.PanelName))
        {
            whereParts.Add(TextInSql("ISNULL(c.PanelName,'')", "@PanelName"));
            parameters["@PanelName"] = filter.PanelName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(filter.Clinic))
        {
            whereParts.Add(TextLikeAnySql("ISNULL(c.ClinicName,'')", "@Clinic"));
            parameters["@Clinic"] = filter.Clinic.Trim();
        }

        if (!string.IsNullOrWhiteSpace(filter.SalesRepname))
        {
            whereParts.Add(TextLikeAnySql("ISNULL(c.SalesRepname,'')", "@SalesRepname"));
            parameters["@SalesRepname"] = filter.SalesRepname.Trim();
        }

        if (!string.IsNullOrWhiteSpace(filter.ReferringProvider))
        {
            whereParts.Add(TextLikeAnySql("ISNULL(c.ReferringProvider,'')", "@ReferringProvider"));
            parameters["@ReferringProvider"] = filter.ReferringProvider.Trim();
        }

        if (filter.FromDate.HasValue)
        {
            whereParts.Add("CAST(c.DateOfService AS date)>=@FromDate");
            parameters["@FromDate"] = filter.FromDate.Value.Date;
        }

        if (filter.ToDate.HasValue)
        {
            whereParts.Add("CAST(c.DateOfService AS date)<=@ToDate");
            parameters["@ToDate"] = filter.ToDate.Value.Date;
        }

        if (!string.IsNullOrWhiteSpace(filter.SearchText))
        {
            whereParts.Add(@"(
                ISNULL(c.ClaimId,'') LIKE @Search OR
                ISNULL(c.PatientId,'') LIKE @Search OR
                ISNULL(c.ClinicName,'') LIKE @Search OR
                ISNULL(c.PayerName,'') LIKE @Search OR
                ISNULL(c.ReferringProvider,'') LIKE @Search
            )");
            parameters["@Search"] = "%" + filter.SearchText.Trim() + "%";
        }

        var sql = $@"
SELECT COUNT_BIG(1)
FROM dbo.DenialClosedClaims c WITH (NOLOCK)
WHERE {string.Join(" AND ", whereParts)};

SELECT
    ClaimId = ISNULL(c.ClaimId,''),
    Source = CAST('' AS nvarchar(255)),
    PayerName = ISNULL(c.PayerName,''),
    PanelName = ISNULL(c.PanelName,''),
    PatientName = ISNULL(c.PatientName,''),
    PatientDOB = c.PatientDOB,
    DateOfService = c.DateOfService,
    ClinicName = ISNULL(c.ClinicName,''),
    ReferringProvider = ISNULL(c.ReferringProvider,''),
    PatientId = ISNULL(c.PatientId,''),
    SubscriberId = ISNULL(c.SubscriberId,''),
    SalesRepname = ISNULL(c.SalesRepname,''),
    AssignedTo = ISNULL(c.AssignedTo,''),
    [Status] = ISNULL(c.Status,'Closed'),
    ClaimStatus = ISNULL(c.Status,'Closed'),
    WorkflowStatus = ISNULL(c.WorkFlowStatus,'Closed Claim'),
    TaskCount = c.TaskCount,
    CreatedOn = c.ClosedOn,
    InsuranceBalance = c.InsuranceBalance
FROM dbo.DenialClosedClaims c WITH (NOLOCK)
WHERE {string.Join(" AND ", whereParts)}
ORDER BY c.ClosedOn DESC, c.ClaimId
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";

        var result = new PagedResult<ClaimLevelRow> { Page = filter.Page, PageSize = filter.PageSize };
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        AddFilterParams(cmd, filter);
        AddExtraParams(cmd, parameters);
        AddPagingParams(cmd, filter);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct))
            result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);
        if (await rd.NextResultAsync(ct))
            while (await rd.ReadAsync(ct)) result.Items.Add(ReadClaim(rd));
        return result;
    }

    public async Task<IReadOnlyList<WorkflowTaskRow>> GetTasksByClaimAsync(int labId, string claimId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(claimId))
            return [];

        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);

        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        string TaskText(string column, string alias) => taskColumns.Contains(column)
            ? $"LTRIM(RTRIM(ISNULL(t.{column},''))) AS {alias}"
            : $"CAST('' AS nvarchar(255)) AS {alias}";
        var patientNameSelect = taskColumns.Contains("PatName")
            ? "LTRIM(RTRIM(ISNULL(t.PatName,''))) AS PatientName"
            : TaskText("PatientName", "PatientName");
        var subscriberColumn = taskColumns.Contains("SubscriberID") ? "SubscriberID" : taskColumns.Contains("SubscriberId") ? "SubscriberId" : string.Empty;
        var subscriberIdSelect = !string.IsNullOrWhiteSpace(subscriberColumn)
            ? $"LTRIM(RTRIM(ISNULL(t.{subscriberColumn},''))) AS SubscriberId"
            : "CAST('' AS nvarchar(255)) AS SubscriberId";
        var hasTaskClaimUid = await HasColumnAsync(con, "dbo.DenialTaskBoard", "ClaimUID", ct);
        var claimUidSelect = hasTaskClaimUid
            ? "ClaimUID = ISNULL(t.ClaimUID,'')"
            : "ClaimUID = CAST('' AS nvarchar(150))";
        var claimLookupWhere = hasTaskClaimUid
            ? @"(
				   LTRIM(RTRIM(ISNULL(t.ClaimUID,''))) = @ClaimUid
				   OR LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))) = @ClaimKey
				   OR CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.ClaimID,''))), 'CLM-', '')) = @ClaimKey
				   OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) = @ClaimId
				   OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) LIKE '%' + @ClaimId
			   )"
            : @"LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))) = @ClaimKey
				   OR CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.ClaimID,''))), 'CLM-', '')) = @ClaimKey
				   OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) = @ClaimId
				   OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) LIKE '%' + @ClaimId";
        var taskLabScope = LabScopeSql("t.LabId");

        var sql = $@"
				DECLARE @HasTaskLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;

				SELECT
					t.TaskID,
					t.UniqueTrackId,
					{claimUidSelect},
					t.ClaimID,
					{TaskText("Source", "Source")},
					{patientNameSelect},
					t.PatientId,
					{subscriberIdSelect},
					t.CPTCode,
					t.Units,
					t.Modifier,
					t.DenialCode,
					t.DenialDescription,
					t.DenialClassification,
					t.ActionCode,
					t.RecommendedAction,
					t.ActionCategory,
					t.Task,
					t.Priority,
					t.InsuranceBalance,
					t.IsCurrentDenial,
					t.SLADays,
					t.Status,
					t.DateOpened,
					t.DueDate,
					t.DateCompleted,
					t.DaysRemaining,
					t.SLAStatus,
					t.AssignedTo,
					t.LabId,
					t.LabName,
					t.RunId,
					t.CreatedOn,
					t.SalesRepname,
					t.ClinicName,
					t.ReferringProvider,
					t.PayerName,
					PayerNameNormalized = t.PayerName,
					t.PayerCode,
					t.PayerType,
					t.FirstBilledDate,
					t.ChargeEnteredDate,
					t.BillingProvider,
					t.PanelName,
					t.DateOfService,
					t.ReviewerComments,
					t.ReviewerUpdatedOn,
					t.ReviewerUpdatedBy,
					t.ICDCodes,
					t.CoverageStatus,
					t.ICDComplianceStatus,
					t.DenialValidity
				FROM dbo.DenialTaskBoard t WITH (NOLOCK)
				WHERE (@HasTaskLab=0 OR {taskLabScope})
				  AND ({claimLookupWhere})
				ORDER BY t.CPTCode, t.TaskID;";

        var rows = new List<WorkflowTaskRow>();

        await using var cmd = new SqlCommand(sql, con)
        {
            CommandTimeout = 180
        };

        var trimmedClaimId = claimId.Trim();
        AddLabScopeParams(cmd, labId);
        cmd.Parameters.AddWithValue("@ClaimId", trimmedClaimId);
        cmd.Parameters.AddWithValue("@ClaimUid", trimmedClaimId);
        cmd.Parameters.AddWithValue("@ClaimKey", trimmedClaimId.Replace("CLM-", string.Empty, StringComparison.OrdinalIgnoreCase));

        await using var rd = await cmd.ExecuteReaderAsync(ct);

        while (await rd.ReadAsync(ct))
            rows.Add(ReadTask(rd));

        return rows;
    }

    public async Task<ClaimAssignmentResult> AssignClaimsAsync(AssignClaimRequest request, CancellationToken ct)
    {
        var claimIds = (request.ClaimIds ?? new List<string>()).Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).Take(500).ToList();
        if (request.LabId <= 0 || claimIds.Count == 0 || string.IsNullOrWhiteSpace(request.ReviewerUserName))
            return new ClaimAssignmentResult { Success = false, Message = "Lab, claim(s), and reviewer are required." };

        await using var con = OpenLab(request.LabId); await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        var hasTaskClaimUid = await HasColumnAsync(con, "dbo.DenialTaskBoard", "ClaimUID", ct);
        var hasLineClaimUid = await HasColumnAsync(con, "dbo.DenialLineItem", "ClaimUID", ct);
        var taskClaimMatchSql = hasTaskClaimUid
            ? "t.ClaimUID=c.ClaimId"
            : "(t.ClaimIDNormalized=c.ClaimId OR t.ClaimID=c.ClaimId OR t.ClaimID LIKE '%' + c.ClaimId)";
        var lineClaimMatchSql = hasLineClaimUid
            ? "l.ClaimUID=c.ClaimId"
            : @"(
        LTRIM(RTRIM(ISNULL(l.VisitNumber,'')))=c.ClaimId
        OR CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))=c.ClaimId
    )";
        await using var tx = await con.BeginTransactionAsync(ct);
        try
        {
            await using (var temp = new SqlCommand("CREATE TABLE #ClaimIds(ClaimId nvarchar(150) NOT NULL PRIMARY KEY);", con, (SqlTransaction)tx)) await temp.ExecuteNonQueryAsync(ct);
            using (var bulk = new SqlBulkCopy(con, SqlBulkCopyOptions.Default, (SqlTransaction)tx))
            {
                var table = new DataTable(); table.Columns.Add("ClaimId", typeof(string));
                foreach (var id in claimIds) table.Rows.Add(id);
                bulk.DestinationTableName = "#ClaimIds";
                await bulk.WriteToServerAsync(table, ct);
            }

            var conflictSql = $@"
SELECT TOP (50)
    ClaimId = c.ClaimId,
    TaskID = ISNULL(t.TaskID,''),
    AssignedTo = ISNULL(t.AssignedTo,'')
FROM #ClaimIds c
JOIN dbo.DenialTaskBoard t WITH (UPDLOCK, HOLDLOCK)
  ON {taskClaimMatchSql}
WHERE 1=1
  AND NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NOT NULL
  AND ISNULL(t.AssignedTo,'') <> @ReviewerUserName
ORDER BY c.ClaimId, t.TaskID;";
            var conflicts = new List<ClaimAssignmentConflict>();
            await using (var cmd = new SqlCommand(conflictSql, con, (SqlTransaction)tx) { CommandTimeout = 180 })
            {
                cmd.Parameters.AddWithValue("@LabId", request.LabId);
                cmd.Parameters.AddWithValue("@ReviewerUserName", request.ReviewerUserName.Trim());
                await using var rd = await cmd.ExecuteReaderAsync(ct);
                while (await rd.ReadAsync(ct)) conflicts.Add(new ClaimAssignmentConflict { ClaimId = GetString(rd, "ClaimId"), TaskId = GetString(rd, "TaskID"), AssignedTo = GetString(rd, "AssignedTo") });
            }

            if (conflicts.Count > 0 && !request.OverwriteExisting)
            {
                await tx.RollbackAsync(ct);
                return new ClaimAssignmentResult { Success = false, HasConflicts = true, Conflicts = conflicts, Message = "Some selected claim task(s) are already assigned. Confirm overwrite to reassign them." };
            }

            var updateSql = $@"
UPDATE t
SET AssignedTo=@ReviewerUserName,
    Status=CASE WHEN ISNULL(t.Status,'') IN ('','New','Open') THEN 'Pending Review' ELSE t.Status END,
    WorkFlowStatus='Assigned To AR Reviewer',
    ReviewerUpdatedBy=@ActionBy,
    ReviewerUpdatedOn=SYSDATETIME()
FROM dbo.DenialTaskBoard t
JOIN #ClaimIds c ON {taskClaimMatchSql}
WHERE 1=1;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    UPDATE l
    SET AssignedTo=@ReviewerUserName,
        WorkFlowStatus='Assigned To AR Reviewer'
    FROM dbo.DenialLineItem l
    JOIN #ClaimIds c ON {lineClaimMatchSql};
END;";
            int rows;
            await using (var cmd = new SqlCommand(updateSql, con, (SqlTransaction)tx) { CommandTimeout = 180 })
            {
                cmd.Parameters.AddWithValue("@LabId", request.LabId);
                cmd.Parameters.AddWithValue("@ReviewerUserName", request.ReviewerUserName.Trim());
                cmd.Parameters.AddWithValue("@ActionBy", request.ActionBy ?? string.Empty);
                rows = await cmd.ExecuteNonQueryAsync(ct);
            }
            await tx.CommitAsync(ct);
            return new ClaimAssignmentResult { Success = rows > 0, RowsAffected = rows, Message = rows > 0 ? $"Assigned {rows} task(s) for {claimIds.Count} claim(s)." : "No matching task found for selected claim(s)." };
        }
        catch
        {
            await tx.RollbackAsync(ct);
            throw;
        }
    }

    public async Task<PagedResult<WorkflowTaskRow>> GetTasksAsync(DenialWorkflowFilter filter, CancellationToken ct)
    {
        filter.PageSize = filter.PageSize <= 0 ? 100 : Math.Clamp(filter.PageSize, 25, 500);
        if (filter.Page <= 0) filter.Page = 1;
        var where = BuildCommonWhere(filter, "t", includeStatus: true, includeAssigned: true);
        await using var con = OpenLab(filter.LabId); await con.OpenAsync(ct);
        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        string TaskText(string column, string alias) => taskColumns.Contains(column)
            ? $"LTRIM(RTRIM(ISNULL(t.{column},''))) AS {alias}"
            : $"CAST('' AS nvarchar(255)) AS {alias}";
        var patientNameSelect = taskColumns.Contains("PatName")
            ? "LTRIM(RTRIM(ISNULL(t.PatName,''))) AS PatientName"
            : TaskText("PatientName", "PatientName");
        var subscriberColumn = taskColumns.Contains("SubscriberID") ? "SubscriberID" : taskColumns.Contains("SubscriberId") ? "SubscriberId" : string.Empty;
        var subscriberIdSelect = !string.IsNullOrWhiteSpace(subscriberColumn)
            ? $"LTRIM(RTRIM(ISNULL(t.{subscriberColumn},''))) AS SubscriberId"
            : "CAST('' AS nvarchar(255)) AS SubscriberId";
        var taskClaimKeyExpr = taskColumns.Contains("ClaimIDNormalized")
            ? "LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,'')))"
            : "CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.ClaimID,''))), 'CLM-', ''))";
        var taskClaimUidExpr = taskColumns.Contains("ClaimUID")
            ? $"COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimUID,''))), ''), {taskClaimKeyExpr})"
            : taskClaimKeyExpr;
        var taskView = NormalizeTaskView(filter.TaskView);
        var countExpression = taskView is "myopen" or "myassigned"
            ? $"COUNT(DISTINCT NULLIF({taskClaimUidExpr},''))"
            : "COUNT_BIG(1)";
        var taskLabScope = LabScopeSql("t.LabId");
        var sql = $@"
DECLARE @HasTaskLab bit = CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END;

SELECT {countExpression}
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE (@HasTaskLab=0 OR {taskLabScope}) {where.WhereClause};

SELECT t.TaskID,t.UniqueTrackId,t.ClaimID,ClaimUID={taskClaimUidExpr},{TaskText("Source", "Source")},{patientNameSelect},t.PatientId,{subscriberIdSelect},t.CPTCode,t.Units,t.Modifier,t.DenialCode,t.DenialDescription,t.DenialClassification,t.ActionCode,t.RecommendedAction,t.ActionCategory,t.Task,t.Priority,t.InsuranceBalance,t.IsCurrentDenial,t.SLADays,t.Status,t.DateOpened,t.DueDate,t.DateCompleted,t.DaysRemaining,t.SLAStatus,t.AssignedTo,t.LabId,t.LabName,t.RunId,t.CreatedOn,t.SalesRepname,t.ClinicName,t.ReferringProvider,t.PayerName,PayerNameNormalized = t.PayerName,t.PayerCode,t.PayerType,t.FirstBilledDate,t.ChargeEnteredDate,t.BillingProvider,t.PanelName,t.DateOfService,t.ReviewerComments,t.ReviewerUpdatedOn,t.ReviewerUpdatedBy,t.ICDCodes,t.CoverageStatus,t.ICDComplianceStatus,t.DenialValidity
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE (@HasTaskLab=0 OR {taskLabScope}) {where.WhereClause}
ORDER BY CASE WHEN ISNULL(t.AssignedTo,'')='' THEN 0 ELSE 1 END, t.DueDate, t.TaskID
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";
        var result = new PagedResult<WorkflowTaskRow> { Page = filter.Page, PageSize = filter.PageSize };
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 }; AddFilterParams(cmd, filter); AddExtraParams(cmd, where.Parameters); AddPagingParams(cmd, filter);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct)) result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) result.Items.Add(ReadTask(rd));
        return result;
    }

    public async Task<PagedResult<VerificationTaskRow>> GetVerificationAsync(
  DenialWorkflowFilter filter,
  CancellationToken ct)
    {
        filter.PageSize = filter.PageSize <= 0 ? 50 : Math.Clamp(filter.PageSize, 25, 200);

        if (filter.Page <= 0)
            filter.Page = 1;

        var result = new PagedResult<VerificationTaskRow>
        {
            Page = filter.Page,
            PageSize = filter.PageSize
        };

        await using var con = OpenLab(filter.LabId);
        await con.OpenAsync(ct);

        if (!await TableExistsAsync(con, "dbo.DenialVerificationTask", ct))
            return result;

        var columns = await GetColumnSetAsync(con, "dbo.DenialVerificationTask", ct);
        var where = BuildVerificationWhere(filter, "v", columns);

        string S(string name, string size = "4000") => columns.Contains(name) ? $"v.{name}" : $"CAST('' AS nvarchar({size}))";
        string I(string name) => columns.Contains(name) ? $"v.{name}" : "CAST(NULL AS int)";
        string BI(string name) => columns.Contains(name) ? $"v.{name}" : "CAST(NULL AS bigint)";
        string D(string name) => columns.Contains(name) ? $"v.{name}" : "CAST(0 AS decimal(18,2))";
        string B(string name) => columns.Contains(name) ? $"v.{name}" : "CAST(0 AS bit)";
        string DT(string name) => columns.Contains(name) ? $"v.{name}" : "CAST(NULL AS datetime2)";
        string OrderBy() => columns.Contains("VerificationId") ? "v.VerificationId DESC" : columns.Contains("TaskID") ? "v.TaskID DESC" : "(SELECT 0)";
        var labPredicate = columns.Contains("LabId") ? $"(@HasVerificationLab=0 OR {LabScopeSql("v.LabId")})" : "1=1";
        var hasVerificationLabSql = columns.Contains("LabId")
            ? $"CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialVerificationTask WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END"
            : "CAST(0 AS bit)";

        var sql = $@"
DECLARE @HasVerificationLab bit = {hasVerificationLabSql};

SELECT COUNT_BIG(1)
FROM dbo.DenialVerificationTask v WITH (NOLOCK)
WHERE {labPredicate} {where.WhereClause};

SELECT
    {BI("VerificationId")} AS VerificationId,
    {S("TaskID", "100")} AS TaskID,
    {S("UniqueTrackId", "100")} AS UniqueTrackId,
    {S("ClaimID", "100")} AS ClaimID,
    {S("PatientId", "100")} AS PatientId,
    {S("CPTCode", "100")} AS CPTCode,
    {I("Units")} AS Units,
    {S("Modifier", "100")} AS Modifier,
    {S("DenialCode", "100")} AS DenialCode,
    {S("DenialDescription")} AS DenialDescription,
    {S("DenialClassification", "250")} AS DenialClassification,
    {S("ActionCode", "100")} AS ActionCode,
    {S("RecommendedAction")} AS RecommendedAction,
    {S("ActionCategory", "250")} AS ActionCategory,
    {S("Task")} AS Task,
    {S("Priority", "100")} AS Priority,
    {D("InsuranceBalance")} AS InsuranceBalance,
    {B("IsCurrentDenial")} AS IsCurrentDenial,
    {I("SLADays")} AS SLADays,
    {S("Status", "100")} AS Status,
    {DT("DateOpened")} AS DateOpened,
    {DT("DueDate")} AS DueDate,
    {DT("DateCompleted")} AS DateCompleted,
    {I("DaysRemaining")} AS DaysRemaining,
    {S("SLAStatus", "100")} AS SLAStatus,
    {S("AssignedTo", "256")} AS AssignedTo,
    {I("LabId")} AS LabId,
    {S("LabName", "256")} AS LabName,
    {S("RunId", "100")} AS RunId,
    {DT("CreatedOn")} AS CreatedOn,
    {S("SalesRepname", "256")} AS SalesRepname,
    {S("ClinicName", "256")} AS ClinicName,
    {S("ReferringProvider", "256")} AS ReferringProvider,
    {S("PayerName", "256")} AS PayerName,
    {S("PayerNameNormalized", "256")} AS PayerNameNormalized,
    {I("PayerCode")} AS PayerCode,
    {S("PayerType", "100")} AS PayerType,
    {DT("FirstBilledDate")} AS FirstBilledDate,
    {DT("ChargeEnteredDate")} AS ChargeEnteredDate,
    {S("BillingProvider", "256")} AS BillingProvider,
    {S("PanelName", "256")} AS PanelName,
    {DT("DateOfService")} AS DateOfService,
    {S("ReviewerComments")} AS ReviewerComments,
    {DT("ReviewerUpdatedOn")} AS ReviewerUpdatedOn,
    {S("ReviewerUpdatedBy", "256")} AS ReviewerUpdatedBy,
    {S("ICDCodes")} AS ICDCodes,
    {S("CoverageStatus", "250")} AS CoverageStatus,
    {S("ICDComplianceStatus", "250")} AS ICDComplianceStatus,
    {S("DenialValidity")} AS DenialValidity,
    {S("VerificationStatus", "100")} AS VerificationStatus,
    {S("VerificationComments")} AS VerificationComments,
    {S("OriginalRunId", "100")} AS OriginalRunId,
    {S("MissingDetectedRunId", "100")} AS MissingDetectedRunId,
    {DT("MovedOn")} AS MovedOn,
    {S("VerifiedBy", "256")} AS VerifiedBy,
    {DT("VerifiedOn")} AS VerifiedOn
FROM dbo.DenialVerificationTask v WITH (NOLOCK)
WHERE {labPredicate} {where.WhereClause}
ORDER BY {OrderBy()}
OFFSET @Offset ROWS
FETCH NEXT @PageSize ROWS ONLY;";

        await using var cmd = new SqlCommand(sql, con)
        {
            CommandTimeout = 180
        };

        AddFilterParams(cmd, filter);
        AddExtraParams(cmd, where.Parameters);
        AddPagingParams(cmd, filter);

        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct))
            result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);

        if (await rd.NextResultAsync(ct))
        {
            while (await rd.ReadAsync(ct))
                result.Items.Add(ReadVerification(rd));
        }

        return result;
    }

    public async Task UpsertActiveTaskAsync(DenialTaskImportRow row, WorkflowTaskRow? existing, int labId, string labName, string runId, string taskId, CancellationToken ct)
    {
        const string sql = @"IF EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WHERE LabId=@LabId AND UniqueTrackId=@UniqueTrackId)
UPDATE dbo.DenialTaskBoard SET RunId=@RunId, LabName=@LabName, ClaimID=@ClaimID, PatientId=@PatientId, CPTCode=@CPTCode, Units=@Units, Modifier=@Modifier, DenialCode=@DenialCode, DenialDescription=@DenialDescription, DenialClassification=@DenialClassification, ActionCode=@ActionCode, RecommendedAction=@RecommendedAction, ActionCategory=@ActionCategory, Task=@Task, Priority=@Priority, InsuranceBalance=@InsuranceBalance, SLADays=@SLADays, DueDate=@DueDate, SalesRepname=@SalesRepname, ClinicName=@ClinicName, ReferringProvider=@ReferringProvider, PayerName=@PayerName, PayerNameNormalized=@PayerNameNormalized, PayerCode=@PayerCode, PayerType=@PayerType, FirstBilledDate=@FirstBilledDate, ChargeEnteredDate=@ChargeEnteredDate, BillingProvider=@BillingProvider, PanelName=@PanelName, DateOfService=@DateOfService WHERE LabId=@LabId AND UniqueTrackId=@UniqueTrackId
ELSE
INSERT INTO dbo.DenialTaskBoard(TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,Units,Modifier,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,IsCurrentDenial,SLADays,Status,WorkFlowStatus,DateOpened,DueDate,AssignedTo,LabId,LabName,RunId,CreatedOn,SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService)
VALUES(@TaskID,@UniqueTrackId,@ClaimID,@PatientId,@CPTCode,@Units,@Modifier,@DenialCode,@DenialDescription,@DenialClassification,@ActionCode,@RecommendedAction,@ActionCategory,@Task,@Priority,@InsuranceBalance,1,@SLADays,'New','New',@DateOpened,@DueDate,'',@LabId,@LabName,@RunId,SYSDATETIME(),@SalesRepname,@ClinicName,@ReferringProvider,@PayerName,@PayerNameNormalized,@PayerCode,@PayerType,@FirstBilledDate,@ChargeEnteredDate,@BillingProvider,@PanelName,@DateOfService);

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    UPDATE dbo.DenialLineItem
    SET WorkFlowStatus = ISNULL(NULLIF(WorkFlowStatus,''), 'New')
    WHERE CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(VisitNumber,''))), 'CLM-', '')) = CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(@ClaimID,''))), 'CLM-', ''));
END;";

        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        AddTaskParams(cmd, row, labId, labName, runId, taskId);
        await cmd.ExecuteNonQueryAsync(ct);
    }


    public async Task MoveActiveToVerificationAsync(WorkflowTaskRow task, string currentRunId, string reason, CancellationToken ct)
    {
        const string sql = @"INSERT INTO dbo.DenialVerificationTask(TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,IsCurrentDenial,SLADays,Status,DateOpened,DueDate,DateCompleted,DaysRemaining,SLAStatus,AssignedTo,LabId,LabName,RunId,CreatedOn,SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService,ReviewerComments,ReviewerUpdatedOn,ReviewerUpdatedBy,VerificationStatus,VerificationComments,OriginalRunId,MissingDetectedRunId,MovedOn)
SELECT TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,IsCurrentDenial,SLADays,'Verification Pending',DateOpened,DueDate,DateCompleted,DaysRemaining,SLAStatus,AssignedTo,LabId,LabName,RunId,CreatedOn,SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService,ReviewerComments,ReviewerUpdatedOn,ReviewerUpdatedBy,'Verification Pending',@Reason,RunId,@CurrentRunId,SYSDATETIME()
FROM dbo.DenialTaskBoard WHERE TaskID=@TaskID;
DELETE FROM dbo.DenialTaskBoard WHERE TaskID=@TaskID;";
        await using var con = OpenLab(task.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@LabId", task.LabId); cmd.Parameters.AddWithValue("@TaskID", task.TaskId); cmd.Parameters.AddWithValue("@Reason", reason); cmd.Parameters.AddWithValue("@CurrentRunId", currentRunId); await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task MoveActiveToHistoryAsync(WorkflowTaskRow task, string actionType, string actionBy, string comments, CancellationToken ct)
    {
        await InsertHistoryAsync(task.TaskId, task.UniqueTrackId, task.LabId, task.RunId, actionType, task.Status, task.Status, task.AssignedTo, task.AssignedTo, comments, actionBy, string.Empty, ct);
        await using var con = OpenLab(task.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand("DELETE FROM dbo.DenialTaskBoard WHERE TaskID=@TaskID", con); cmd.Parameters.AddWithValue("@LabId", task.LabId); cmd.Parameters.AddWithValue("@TaskID", task.TaskId); await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task InsertHistoryAsync(string taskId, string uniqueTrackId, int labId, string runId, string actionType, string oldStatus, string newStatus, string oldAssignedTo, string newAssignedTo, string comments, string actionBy, string snapshotJson, CancellationToken ct)
    {
        const string sql = @"INSERT INTO dbo.DenialTaskHistory(TaskID,UniqueTrackId,LabId,RunId,ActionType,OldStatus,NewStatus,OldAssignedTo,NewAssignedTo,Comments,ActionBy,ActionDate,SnapshotJson) VALUES(@TaskID,@UniqueTrackId,@LabId,@RunId,@ActionType,@OldStatus,@NewStatus,@OldAssignedTo,@NewAssignedTo,@Comments,@ActionBy,SYSDATETIME(),@SnapshotJson);";
        await using var con = OpenLab(labId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@TaskID", taskId); cmd.Parameters.AddWithValue("@UniqueTrackId", uniqueTrackId); cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@RunId", runId); cmd.Parameters.AddWithValue("@ActionType", actionType); cmd.Parameters.AddWithValue("@OldStatus", oldStatus); cmd.Parameters.AddWithValue("@NewStatus", newStatus); cmd.Parameters.AddWithValue("@OldAssignedTo", oldAssignedTo); cmd.Parameters.AddWithValue("@NewAssignedTo", newAssignedTo); cmd.Parameters.AddWithValue("@Comments", comments); cmd.Parameters.AddWithValue("@ActionBy", actionBy); cmd.Parameters.AddWithValue("@SnapshotJson", snapshotJson); await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<int> AssignByInsightAsync(AssignInsightRequest request, CancellationToken ct)
    {
        const string sql = @"
DECLARE @ChangedClaims TABLE(ClaimId nvarchar(150) NOT NULL);

UPDATE dbo.DenialTaskBoard
SET AssignedTo=@ReviewerUserName,
    Status=CASE WHEN ISNULL(Status,'') IN ('','New') THEN 'Pending Review' ELSE Status END,
    WorkFlowStatus='Assigned To AR Reviewer',
    ReviewerUpdatedBy=@ActionBy,
    ReviewerUpdatedOn=SYSDATETIME()
OUTPUT CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(INSERTED.ClaimID,''))), 'CLM-', '')) INTO @ChangedClaims(ClaimId)
WHERE DenialCode=@DenialCode AND ISNULL(PayerName,'')=@PayerName AND (@RunId='' OR RunId=@RunId);

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    UPDATE l
    SET AssignedTo=@ReviewerUserName,
        WorkFlowStatus='Assigned To AR Reviewer'
    FROM dbo.DenialLineItem l
    JOIN @ChangedClaims c ON CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))=c.ClaimId;
END;";
        await using var con = OpenLab(request.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 }; cmd.Parameters.AddWithValue("@LabId", request.LabId); cmd.Parameters.AddWithValue("@ReviewerUserName", request.ReviewerUserName); cmd.Parameters.AddWithValue("@ActionBy", request.ActionBy); cmd.Parameters.AddWithValue("@DenialCode", request.DenialCode); cmd.Parameters.AddWithValue("@PayerName", request.PayerName); cmd.Parameters.AddWithValue("@RunId", request.RunId ?? string.Empty); return await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<int> UpdateTaskAsync(UpdateTaskRequest request, bool isClosed, bool isDuplicate, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(request.LabId, ct);
        request.Status = NormalizeWorkflowStatus(request.Status);
        if (isDuplicate)
        {
            var task = (await GetTasksAsync(new DenialWorkflowFilter { LabId = request.LabId, SearchText = request.TaskId, Page = 1, PageSize = 1 }, ct)).Items.FirstOrDefault();
            if (task is null) return 0;
            await MoveActiveToVerificationAsync(task, request.TaskId, request.Comments, ct);
            return 1;
        }
        await using var con = OpenLab(request.LabId);
        await con.OpenAsync(ct);
        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        var optionalSets = new List<string>();
        if (taskColumns.Contains("ActionCompleted")) optionalSets.Add("ActionCompleted=@ActionCompleted");
        if (taskColumns.Contains("ActualOutcome")) optionalSets.Add("ActualOutcome=@ActualOutcome");
        if (taskColumns.Contains("DocumentationType")) optionalSets.Add("DocumentationType=@DocumentationType");
        if (taskColumns.Contains("FollowUpReason")) optionalSets.Add("FollowUpReason=@FollowUpReason");
        if (taskColumns.Contains("ClosureReason")) optionalSets.Add("ClosureReason=@ClosureReason");
        if (taskColumns.Contains("SyncConfirmation")) optionalSets.Add("SyncConfirmation=@SyncConfirmation");
        if (taskColumns.Contains("ValidationStatus")) optionalSets.Add("ValidationStatus=@ValidationStatus");
        if (taskColumns.Contains("ExpectedResponseDate")) optionalSets.Add("ExpectedResponseDate=@ExpectedResponseDate");
        if (taskColumns.Contains("LastWorkflowUpdatedBy")) optionalSets.Add("LastWorkflowUpdatedBy=@ActionBy");
        if (taskColumns.Contains("LastWorkflowUpdatedOn")) optionalSets.Add("LastWorkflowUpdatedOn=SYSDATETIME()");
        var optionalSetSql = optionalSets.Count > 0 ? "," + Environment.NewLine + "    " + string.Join("," + Environment.NewLine + "    ", optionalSets) : string.Empty;
        var historySnapshot = BuildWorkflowStatusSnapshot(request);
        var sql = $@"
DECLARE @Changed TABLE(TaskID nvarchar(100), ClaimId nvarchar(150), OldWorkFlowStatus nvarchar(100), NewWorkFlowStatus nvarchar(100), OldAssignedTo nvarchar(255), NewAssignedTo nvarchar(255));

UPDATE dbo.DenialTaskBoard
SET Status=@Status,
    WorkFlowStatus=CASE WHEN @IsClosed=1 THEN 'Closed Claim' ELSE NULLIF(@Status,'') END,
    ReviewerComments=@Comments,
    ReviewerUpdatedBy=@ActionBy,
    ReviewerUpdatedOn=SYSDATETIME(),
    DateCompleted=CASE WHEN @IsClosed=1 THEN CONVERT(date,GETDATE()) ELSE DateCompleted END{optionalSetSql}
OUTPUT INSERTED.TaskID, CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(INSERTED.ClaimID,''))), 'CLM-', '')), DELETED.WorkFlowStatus, INSERTED.WorkFlowStatus, DELETED.AssignedTo, INSERTED.AssignedTo
INTO @Changed(TaskID, ClaimId, OldWorkFlowStatus, NewWorkFlowStatus, OldAssignedTo, NewAssignedTo)
WHERE TaskID=@TaskID;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    UPDATE l
    SET WorkFlowStatus = CASE WHEN @IsClosed=1 THEN 'Closed Claim' ELSE NULLIF(@Status,'') END
    FROM dbo.DenialLineItem l
    JOIN @Changed c ON CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))=c.ClaimId;
END;

IF @IsClosed=1
BEGIN
    ;WITH ClosedClaim AS
    (
        SELECT
            LabId = @LabId,
            ClaimId = c.ClaimId,
            PayerName = MAX(LTRIM(RTRIM(ISNULL(l.PayerName,'')))),
            PanelName = MAX(LTRIM(RTRIM(ISNULL(l.PanelName,'')))),
            PatientName = CAST('' AS nvarchar(255)),
            PatientDOB = MAX(l.PatientDOB),
            PatientId = MAX(LTRIM(RTRIM(ISNULL(l.PatientID,'')))),
            SubscriberId = CAST('' AS nvarchar(100)),
            ClinicName = MAX(LTRIM(RTRIM(ISNULL(l.ClinicName,'')))),
            SalesRepname = MAX(LTRIM(RTRIM(ISNULL(l.SalesRepname,'')))),
            ReferringProvider = MAX(LTRIM(RTRIM(ISNULL(l.ReferringProvider,'')))),
            DateOfService = MAX(l.DateOfService),
            AssignedTo = MAX(NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'')),
            TaskCount = COUNT(DISTINCT t.TaskID),
            InsuranceBalance = SUM(ISNULL(l.InsuranceBalance,0))
        FROM @Changed c
        LEFT JOIN dbo.DenialLineItem l ON CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))=c.ClaimId
        LEFT JOIN dbo.DenialTaskBoard t ON CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.ClaimID,''))), 'CLM-', ''))=c.ClaimId
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.DenialTaskBoard openTask
            WHERE CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(openTask.ClaimID,''))), 'CLM-', ''))=c.ClaimId
              AND LOWER(LTRIM(RTRIM(ISNULL(openTask.Status,'')))) NOT IN ('closed','completed')
        )
        GROUP BY c.ClaimId
    )
    MERGE dbo.DenialClosedClaims AS target
    USING ClosedClaim AS source
       ON target.LabId=source.LabId AND target.ClaimId=source.ClaimId
    WHEN MATCHED THEN UPDATE SET
        PayerName=source.PayerName, PanelName=source.PanelName, PatientName=source.PatientName, PatientDOB=source.PatientDOB,
        PatientId=source.PatientId, SubscriberId=source.SubscriberId, ClinicName=source.ClinicName, SalesRepname=source.SalesRepname,
        ReferringProvider=source.ReferringProvider, DateOfService=source.DateOfService, AssignedTo=source.AssignedTo,
        Status='Closed', WorkFlowStatus='Closed Claim', TaskCount=source.TaskCount, InsuranceBalance=source.InsuranceBalance,
        ClosedBy=@ActionBy, LastUpdatedOn=SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT(LabId,ClaimId,PayerName,PanelName,PatientName,PatientDOB,PatientId,SubscriberId,ClinicName,SalesRepname,ReferringProvider,DateOfService,AssignedTo,Status,WorkFlowStatus,TaskCount,InsuranceBalance,ClosedBy)
        VALUES(source.LabId,source.ClaimId,source.PayerName,source.PanelName,source.PatientName,source.PatientDOB,source.PatientId,source.SubscriberId,source.ClinicName,source.SalesRepname,source.ReferringProvider,source.DateOfService,source.AssignedTo,'Closed','Closed Claim',source.TaskCount,source.InsuranceBalance,@ActionBy);

    INSERT INTO dbo.DenialClosedClaimsHistory(ClosedClaimId,LabId,ClaimId,ActionType,OldWorkFlowStatus,NewWorkFlowStatus,OldAssignedTo,NewAssignedTo,Comments,ActionBy)
    SELECT dc.ClosedClaimId,@LabId,c.ClaimId,'Closed',c.OldWorkFlowStatus,c.NewWorkFlowStatus,c.OldAssignedTo,c.NewAssignedTo,@Comments,@ActionBy
    FROM @Changed c
    JOIN dbo.DenialClosedClaims dc ON dc.LabId=@LabId AND dc.ClaimId=c.ClaimId;
END;

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
BEGIN
    INSERT INTO dbo.DenialTaskHistory(TaskID,UniqueTrackId,LabId,RunId,ActionType,OldStatus,NewStatus,OldAssignedTo,NewAssignedTo,Comments,ActionBy,ActionDate,SnapshotJson)
    SELECT ISNULL(t.TaskID,''),ISNULL(t.UniqueTrackId,''),ISNULL(t.LabId,@LabId),ISNULL(t.RunId,''),'StatusUpdate',ISNULL(c.OldWorkFlowStatus,''),ISNULL(c.NewWorkFlowStatus,''),ISNULL(c.OldAssignedTo,''),ISNULL(c.NewAssignedTo,''),@Comments,@ActionBy,SYSDATETIME(),@SnapshotJson
    FROM @Changed c
    LEFT JOIN dbo.DenialTaskBoard t ON t.TaskID=c.TaskID;
END

SELECT COUNT(1) FROM @Changed;";
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        cmd.Parameters.AddWithValue("@LabId", request.LabId);
        cmd.Parameters.AddWithValue("@TaskID", request.TaskId);
        cmd.Parameters.AddWithValue("@Status", request.Status);
        cmd.Parameters.AddWithValue("@Comments", request.Comments ?? string.Empty);
        cmd.Parameters.AddWithValue("@ActionBy", request.ActionBy ?? string.Empty);
        cmd.Parameters.AddWithValue("@IsClosed", isClosed);
        cmd.Parameters.AddWithValue("@ActionCompleted", request.ActionCompleted.HasValue ? request.ActionCompleted.Value : (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@ActualOutcome", request.ActualOutcome ?? string.Empty);
        cmd.Parameters.AddWithValue("@DocumentationType", request.DocumentationType ?? string.Empty);
        cmd.Parameters.AddWithValue("@FollowUpReason", request.FollowUpReason ?? string.Empty);
        cmd.Parameters.AddWithValue("@ClosureReason", request.ClosureReason ?? string.Empty);
        cmd.Parameters.AddWithValue("@SyncConfirmation", request.SyncConfirmation ?? string.Empty);
        cmd.Parameters.AddWithValue("@ValidationStatus", request.ValidationStatus ?? string.Empty);
        cmd.Parameters.AddWithValue("@ExpectedResponseDate", request.ExpectedResponseDate.HasValue ? request.ExpectedResponseDate.Value.Date : (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@SnapshotJson", historySnapshot);
        var scalar = await cmd.ExecuteScalarAsync(ct);
        return scalar == DBNull.Value || scalar is null ? 0 : Convert.ToInt32(scalar);
    }

    private async Task<int> WriteClaimUploadTemplateAsync(SqlConnection con, DenialWorkflowFilter filter, Stream output, CancellationToken ct)
    {
        var where = BuildCommonWhere(filter, "t", includeStatus: true, includeAssigned: true);
        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        var claimUid = taskColumns.Contains("ClaimUID")
            ? "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimUID,''))),''), LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))), LTRIM(RTRIM(ISNULL(t.ClaimID,''))))"
            : "COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))),''), LTRIM(RTRIM(ISNULL(t.ClaimID,''))))";
        var patientName = taskColumns.Contains("PatName")
            ? "LTRIM(RTRIM(ISNULL(t.PatName,'')))"
            : taskColumns.Contains("PatientName") ? "LTRIM(RTRIM(ISNULL(t.PatientName,'')))" : "CAST('' AS nvarchar(255))";
        var taskLabPredicate = taskColumns.Contains("LabId")
            ? $"(@HasTaskLab=0 OR {LabScopeSql("t.LabId")})"
            : "1=1";
        var hasTaskLab = taskColumns.Contains("LabId")
            ? $"CASE WHEN EXISTS (SELECT 1 FROM dbo.DenialTaskBoard WITH (NOLOCK) WHERE {LabScopeSql("LabId")}) THEN 1 ELSE 0 END"
            : "CAST(0 AS bit)";
        var sql = $@"
DECLARE @HasTaskLab bit = {hasTaskLab};
SELECT ClaimID={claimUid}, PatientName=MAX({patientName}), PayerName=MAX(LTRIM(RTRIM(ISNULL(t.PayerName,''))))
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE {taskLabPredicate}
  AND NULLIF({claimUid},'') IS NOT NULL
  {where.WhereClause}
GROUP BY {claimUid}
ORDER BY {claimUid};";

        var claims = new List<(string ClaimId, string PatientName, string PayerName)>();
        await using (var cmd = new SqlCommand(sql, con) { CommandTimeout = 900 })
        {
            AddFilterParams(cmd, filter);
            AddExtraParams(cmd, where.Parameters);
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            while (await rd.ReadAsync(ct))
                claims.Add((GetString(rd, "ClaimID"), GetString(rd, "PatientName"), GetString(rd, "PayerName")));
        }

        using var workbook = new ClosedXML.Excel.XLWorkbook();
        var sheet = workbook.Worksheets.Add("Claim Upload");
        var lookupSheet = workbook.Worksheets.Add("Dropdown Values");
        var reviewerTemplate = IsReviewerOnly(filter.Role);
        var headers = reviewerTemplate
            ? new[] { "ClaimID", "PatientName", "PayerName", "UpdateStatus", "ExpectedResponseDate", "ActionCompleted", "ActualOutcome", "DocumentationType", "FollowUpReason", "ClosureReason", "ValidationStatus", "Comments" }
            : new[] { "ClaimID", "PatientName", "PayerName", "EscalationResponse", "EscalationResponseComment" };

        for (var col = 0; col < headers.Length; col++)
        {
            sheet.Cell(1, col + 1).Value = headers[col];
            sheet.Cell(1, col + 1).Style.Font.Bold = true;
            sheet.Cell(1, col + 1).Style.Fill.BackgroundColor = ClosedXML.Excel.XLColor.FromHtml("#D9EAF7");
        }
        for (var row = 0; row < claims.Count; row++)
        {
            sheet.Cell(row + 2, 1).Value = claims[row].ClaimId;
            sheet.Cell(row + 2, 2).Value = claims[row].PatientName;
            sheet.Cell(row + 2, 3).Value = claims[row].PayerName;
        }

        var lastRow = Math.Max(claims.Count + 1, 2);
        var lookupColumn = 1;
        void AddDropdown(string columnName, IEnumerable<string> values)
        {
            var column = Array.FindIndex(headers, x => string.Equals(x, columnName, StringComparison.OrdinalIgnoreCase)) + 1;
            if (column <= 0) return;
            var items = values.ToArray();
            lookupSheet.Cell(1, lookupColumn).Value = columnName;
            for (var i = 0; i < items.Length; i++) lookupSheet.Cell(i + 2, lookupColumn).Value = items[i];
            var source = lookupSheet.Range(2, lookupColumn, items.Length + 1, lookupColumn);
            sheet.Range(2, column, lastRow, column).CreateDataValidation().List(source, true);
            lookupColumn++;
        }

        if (reviewerTemplate)
        {
            AddDropdown("UpdateStatus", ["Assigned", "Payer Follow-up Required", "Pending Payer Response", "Pending Documentation", "Write-Off Pending Approval", "Escalated to AR Manager", "Closed"]);
            AddDropdown("ActionCompleted", ["Yes", "No"]);
            AddDropdown("ActualOutcome", ["Appeal Submitted", "Documentation Uploaded", "Rebill Submitted", "Corrected Claim Submitted", "Write-Off Recommended", "Payer Call Completed", "Claim Paid", "Claim Reprocessed", "Closed No Recovery", "Other"]);
            AddDropdown("DocumentationType", ["Medical Records Required", "Clinical Notes Required", "Authorization Reference Required", "Updated Insurance Required", "Requisition / Order Required", "Provider Information Required", "Diagnosis / ICD Clarification Required", "Patient Demographics Required", "EOB / Payer Correspondence Required", "Client Confirmation Required", "Other Documentation Required"]);
            AddDropdown("FollowUpReason", ["Denial unclear", "Action uncertain", "Payer policy conflict", "Need filing instructions", "Claim status check", "Timely filing confirmation", "Other"]);
            AddDropdown("ClosureReason", ["Paid/Recovered", "Written Off", "Denial Upheld", "No Further Action", "Invalid Denial", "Timely Filing Expired", "Duplicate", "Client Approved Closure"]);
        }
        else
        {
            AddDropdown("EscalationResponse", ["Proceed with Appeal", "Proceed with Rebill", "Proceed with Write-Off Request", "Perform Payer Follow-up", "Request Documentation", "Additional Information Needed", "No Further Action Required", "Close Claim / Line", "Other"]);
        }

        sheet.SheetView.FreezeRows(1);
        sheet.Columns().AdjustToContents(10, 42);
        sheet.Column(1).Style.Protection.Locked = true;
        sheet.Column(2).Style.Protection.Locked = true;
        sheet.Column(3).Style.Protection.Locked = true;
        lookupSheet.Hide();
        workbook.SaveAs(output);
        return claims.Count;
    }

    public async Task<int> UpdateClaimCommentsAsync(int labId, string claimId, string comments, string actionBy, CancellationToken ct)
    {
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        const string sql = @"
DECLARE @Changed TABLE(TaskID nvarchar(100),UniqueTrackId nvarchar(100),LabId int,RunId nvarchar(100),CurrentStatus nvarchar(100),AssignedTo nvarchar(256));

UPDATE t
SET ReviewerComments=@Comments,
    ReviewerUpdatedBy=@ActionBy,
    ReviewerUpdatedOn=SYSDATETIME()
OUTPUT INSERTED.TaskID,INSERTED.UniqueTrackId,ISNULL(INSERTED.LabId,@LabId),INSERTED.RunId,INSERTED.Status,INSERTED.AssignedTo
INTO @Changed(TaskID,UniqueTrackId,LabId,RunId,CurrentStatus,AssignedTo)
FROM dbo.DenialTaskBoard t
WHERE LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,'')))=@ClaimId
   OR LTRIM(RTRIM(ISNULL(t.ClaimID,'')))=@ClaimId
   OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) LIKE '%' + @ClaimId;

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
BEGIN
    INSERT INTO dbo.DenialTaskHistory(TaskID,UniqueTrackId,LabId,RunId,ActionType,OldStatus,NewStatus,OldAssignedTo,NewAssignedTo,Comments,ActionBy,ActionDate,SnapshotJson)
    SELECT ISNULL(TaskID,''),ISNULL(UniqueTrackId,''),ISNULL(LabId,@LabId),ISNULL(RunId,''),'ClaimComment',ISNULL(CurrentStatus,''),ISNULL(CurrentStatus,''),ISNULL(AssignedTo,''),ISNULL(AssignedTo,''),@Comments,@ActionBy,SYSDATETIME(),''
    FROM @Changed;
END

SELECT COUNT(1) FROM @Changed;";
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        AddLabScopeParams(cmd, labId);
        cmd.Parameters.AddWithValue("@ClaimId", claimId.Trim());
        cmd.Parameters.AddWithValue("@Comments", comments.Trim());
        cmd.Parameters.AddWithValue("@ActionBy", string.IsNullOrWhiteSpace(actionBy) ? "ReactWorkflow" : actionBy.Trim());
        var scalar = await cmd.ExecuteScalarAsync(ct);
        return scalar == DBNull.Value || scalar is null ? 0 : Convert.ToInt32(scalar);
    }

    public async Task<int> DecideVerificationAsync(VerificationDecisionRequest request, bool isClosed, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(request.LabId, ct);
        var sql = request.IsValidDenial
            ? @"INSERT INTO dbo.DenialTaskBoard(TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,IsCurrentDenial,SLADays,Status,WorkFlowStatus,DateOpened,DueDate,DateCompleted,DaysRemaining,SLAStatus,AssignedTo,LabId,LabName,RunId,CreatedOn,SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService,ReviewerComments,ReviewerUpdatedOn,ReviewerUpdatedBy)
SELECT TaskID,UniqueTrackId,ClaimID,PatientId,CPTCode,DenialCode,DenialDescription,DenialClassification,ActionCode,RecommendedAction,ActionCategory,Task,Priority,InsuranceBalance,1,SLADays,CASE WHEN @Status='' THEN 'Pending Review' ELSE @Status END,CASE WHEN NULLIF(AssignedTo,'') IS NULL THEN 'New' ELSE 'Assigned To AR Reviewer' END,DateOpened,DueDate,NULL,NULL,SLAStatus,AssignedTo,LabId,LabName,RunId,SYSDATETIME(),SalesRepname,ClinicName,ReferringProvider,PayerName,PayerNameNormalized,PayerCode,PayerType,FirstBilledDate,ChargeEnteredDate,BillingProvider,PanelName,DateOfService,@Comments,SYSDATETIME(),@ActionBy FROM dbo.DenialVerificationTask WHERE VerificationId=@VerificationId;
DELETE FROM dbo.DenialVerificationTask WHERE VerificationId=@VerificationId;"
            : @"UPDATE dbo.DenialVerificationTask SET VerificationStatus='Closed', VerificationComments=@Comments, VerifiedOn=SYSDATETIME(), VerifiedBy=@ActionBy WHERE VerificationId=@VerificationId; DELETE FROM dbo.DenialVerificationTask WHERE VerificationId=@VerificationId;";
        await using var con = OpenLab(request.LabId); await con.OpenAsync(ct); await using var cmd = new SqlCommand(sql, con); cmd.Parameters.AddWithValue("@LabId", request.LabId); cmd.Parameters.AddWithValue("@VerificationId", request.VerificationId); cmd.Parameters.AddWithValue("@Status", request.Status ?? string.Empty); cmd.Parameters.AddWithValue("@Comments", request.Comments ?? string.Empty); cmd.Parameters.AddWithValue("@ActionBy", request.ActionBy ?? string.Empty); return await cmd.ExecuteNonQueryAsync(ct);
    }


    private static string ResolveLabConnectionString(IConfiguration configuration, int labId, string labName, string? connectionKey = null)
    {
        // First allow an exact per-lab override: ConnectionStrings:Lab_{LabId}
        var byId = configuration.GetConnectionString($"Lab_{labId}");
        if (!string.IsNullOrWhiteSpace(byId)) return byId;

        // Preferred LRN Metrics mapping: LabId -> ConnectionKey -> ConnectionStrings entry.
        if (!string.IsNullOrWhiteSpace(connectionKey))
        {
            var byConnectionKey = configuration.GetConnectionString(connectionKey.Trim());
            if (!string.IsNullOrWhiteSpace(byConnectionKey)) return byConnectionKey;
        }

        var normalized = NormalizeKey(labName);
        var knownKey = normalized switch
        {
            "PCRLABSOFAMERICA" or "PCRLOA" => "PCRLOAConnStr",
            "COVE" => "CoveConnection",
            "INHEALTHDTR" or "INHEALTH" => "InHealthConn",
            "ELIXIR" => "ElixirConnection",
            "CERTUS" or "CERTUSLABORATORIES" => "CertusConnection",
            "BEECHTREE" => "BeechTreeConnStr",
            "AUGUSTUSLABS" or "AUGUSTUS" => "AugustusConnStr",
            "NORTHWEST" or "NWL" => "NWLConnection",
            "PCRDXAL" => "PCRALConnection",
            "PCRDXCO" => "PCRDxConnection",
            "PHILIFE" => "PhiLifeConnStr",
            "RISINGTIDES" => "RisingTidesConnStr",
            _ => string.Empty
        };

        if (!string.IsNullOrWhiteSpace(knownKey))
        {
            var conn = configuration.GetConnectionString(knownKey);
            if (!string.IsNullOrWhiteSpace(conn)) return conn;
        }

        foreach (var section in configuration.GetSection("ConnectionStrings").GetChildren())
        {
            var key = NormalizeKey(section.Key);
            if (key.Contains(normalized, StringComparison.OrdinalIgnoreCase) || normalized.Contains(key.Replace("CONNECTION", "").Replace("CONNSTR", ""), StringComparison.OrdinalIgnoreCase))
                return section.Value ?? string.Empty;
        }

        return string.Empty;
    }

    private static string NormalizeKey(string value)
        => new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());

    private static string BuildFilterCacheKey(string prefix, DenialWorkflowFilter f)
    {
        static string Clean(string? value) => (value ?? string.Empty).Trim().ToUpperInvariant();
        return string.Join('|',
            prefix,
            f.LabId,
            Clean(f.Role),
            Clean(f.UserName),
            Clean(f.Status),
            Clean(f.TaskView),
            Clean(f.Reviewer),
            Clean(f.AssignedTo),
            Clean(f.DenialCode),
            Clean(f.PayerName),
            Clean(f.Clinic),
            Clean(f.SalesRepname),
            Clean(f.ReferringProvider),
            Clean(f.DenialClassification),
            Clean(f.ActionCategory),
            Clean(f.Priority),
            Clean(f.RunId),
            Clean(f.SearchText),
            f.FromDate?.Date.ToString("yyyyMMdd") ?? string.Empty,
            f.ToDate?.Date.ToString("yyyyMMdd") ?? string.Empty);
    }

    private sealed record FilterOptionsCacheEntry(DateTime CachedOnUtc, DenialWorkflowFilterOptions Options);
    private sealed record DashboardCacheEntry(DateTime CachedOnUtc, DenialWorkflowDashboardSummary Summary);
    private sealed record ClaimCountsCacheEntry(DateTime CachedOnUtc, ClaimSubMenuCounts Counts);

    private sealed class LabConfigItem
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public string ConnectionKey { get; set; } = string.Empty;
        public bool IsActive { get; set; } = true;
    }

    private static List<LabConfigItem> DefaultActiveLabs() =>
    [
        new() { Id = 2, Name = "InHealth", ConnectionKey = "InHealthConn" },
        new() { Id = 4, Name = "Cove", ConnectionKey = "CoveConnection" },
        new() { Id = 7, Name = "PCRDx - AL", ConnectionKey = "PCRALConnection" },
        new() { Id = 8, Name = "PCRDx - CO", ConnectionKey = "PCRDxConnection" },
        new() { Id = 9, Name = "Rising Tides", ConnectionKey = "RisingTidesConnStr" },
        new() { Id = 10, Name = "BeechTree", ConnectionKey = "BeechTreeConnStr" },
        new() { Id = 12, Name = "Phi Life", ConnectionKey = "PhiLifeConnStr" },
        new() { Id = 13, Name = "PCR Labs of America", ConnectionKey = "PCRLOAConnStr" },
        new() { Id = 16, Name = "Elixir", ConnectionKey = "ElixirConnection" },
        new() { Id = 18, Name = "Certus", ConnectionKey = "CertusConnection" },
        new() { Id = 19, Name = "Augustus Labs", ConnectionKey = "AugustusConnStr" },
        new() { Id = 23, Name = "NorthWest", ConnectionKey = "NWLConnection" }
    ];


    private const string MultiSelectDelimiter = "¬";

    private static string TextInSql(string expression, string parameterName) =>
        $"EXISTS (SELECT 1 FROM STRING_SPLIT({parameterName}, N'{MultiSelectDelimiter}') mv WHERE LOWER(LTRIM(RTRIM({expression}))) = LOWER(LTRIM(RTRIM(mv.value))))";

    private static string TextLikeAnySql(string expression, string parameterName) =>
        $"EXISTS (SELECT 1 FROM STRING_SPLIT({parameterName}, N'{MultiSelectDelimiter}') mv WHERE {expression} LIKE '%' + LTRIM(RTRIM(mv.value)) + '%')";

    private static (string WhereClause, Dictionary<string, object> Parameters) BuildVerificationWhere(
        DenialWorkflowFilter f,
        string a,
        ISet<string> columns)
    {
        var w = new List<string>();
        var p = new Dictionary<string, object>();
        bool Has(string name) => columns.Contains(name);

        if (IsReviewerOnly(f.Role) && Has("AssignedTo"))
        {
            w.Add($"ISNULL({a}.AssignedTo,'')=@RoleUserName");
            p["@RoleUserName"] = f.UserName ?? string.Empty;
        }

        if (!string.IsNullOrWhiteSpace(f.Status))
        {
            if (Has("Status"))
            {
                w.Add(TextInSql($"ISNULL({a}.Status,'')", "@Status"));
                p["@Status"] = f.Status.Trim();
            }
            else if (Has("VerificationStatus"))
            {
                w.Add(TextInSql($"ISNULL({a}.VerificationStatus,'')", "@Status"));
                p["@Status"] = f.Status.Trim();
            }
        }

        if (!string.IsNullOrWhiteSpace(f.AssignedTo) && Has("AssignedTo"))
        {
            w.Add(TextInSql($"ISNULL({a}.AssignedTo,'')", "@AssignedTo"));
            p["@AssignedTo"] = f.AssignedTo.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.Reviewer) && Has("AssignedTo"))
        {
            w.Add(TextInSql($"ISNULL({a}.AssignedTo,'')", "@Reviewer"));
            p["@Reviewer"] = f.Reviewer.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.DenialCode) && Has("DenialCode"))
        {
            w.Add(TextInSql($"ISNULL({a}.DenialCode,'')", "@DenialCode"));
            p["@DenialCode"] = f.DenialCode.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.PayerName))
        {
            var payerParts = new List<string>();
            if (Has("PayerNameNormalized")) payerParts.Add(TextInSql($"ISNULL({a}.PayerNameNormalized,'')", "@PayerName"));
            if (Has("PayerName")) payerParts.Add(TextInSql($"ISNULL({a}.PayerName,'')", "@PayerName"));
            if (payerParts.Count > 0)
            {
                w.Add("(" + string.Join(" OR ", payerParts) + ")");
                p["@PayerName"] = f.PayerName.Trim();
            }
        }

        if (!string.IsNullOrWhiteSpace(f.ActionCategory) && Has("ActionCategory"))
        {
            w.Add(TextInSql($"ISNULL({a}.ActionCategory,'')", "@ActionCategory"));
            p["@ActionCategory"] = f.ActionCategory.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.Priority) && Has("Priority"))
        {
            w.Add(TextInSql($"ISNULL({a}.Priority,'')", "@Priority"));
            p["@Priority"] = f.Priority.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.Clinic) && Has("ClinicName"))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ClinicName,'')", "@Clinic"));
            p["@Clinic"] = f.Clinic.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.SalesRepname) && Has("SalesRepname"))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.SalesRepname,'')", "@SalesRepname"));
            p["@SalesRepname"] = f.SalesRepname.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.ReferringProvider) && Has("ReferringProvider"))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ReferringProvider,'')", "@ReferringProvider"));
            p["@ReferringProvider"] = f.ReferringProvider.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.DenialClassification) && Has("DenialClassification"))
        {
            w.Add(TextInSql($"ISNULL({a}.DenialClassification,'')", "@DenialClassification"));
            p["@DenialClassification"] = f.DenialClassification.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.RunId) && Has("RunId"))
        {
            w.Add($"ISNULL({a}.RunId,'')=@RunId");
            p["@RunId"] = f.RunId.Trim();
        }

        if (f.FromDate.HasValue && Has("CreatedOn"))
        {
            w.Add($"CAST({a}.CreatedOn AS date)>=@FromDate");
            p["@FromDate"] = f.FromDate.Value.Date;
        }

        if (f.ToDate.HasValue && Has("CreatedOn"))
        {
            w.Add($"CAST({a}.CreatedOn AS date)<=@ToDate");
            p["@ToDate"] = f.ToDate.Value.Date;
        }

        if (!string.IsNullOrWhiteSpace(f.SearchText))
        {
            var searchParts = new List<string>();
            foreach (var col in new[] { "TaskID", "ClaimID", "DenialCode", "PayerName", "PayerNameNormalized", "VerificationComments" })
                if (Has(col)) searchParts.Add($"ISNULL({a}.{col},'') LIKE @Search");

            if (searchParts.Count > 0)
            {
                w.Add("(" + string.Join(" OR ", searchParts) + ")");
                p["@Search"] = "%" + f.SearchText.Trim() + "%";
            }
        }

        return (w.Count == 0 ? string.Empty : " AND " + string.Join(" AND ", w), p);
    }

    private static (string WhereClause, Dictionary<string, object> Parameters) BuildCommonWhere(
        DenialWorkflowFilter f,
        string a,
        bool includeStatus,
        bool includeAssigned)
    {
        var w = new List<string>();
        var p = new Dictionary<string, object>();

        // DenialInsight table uses DenialCodes, while TaskBoard/Verification use DenialCode
        var denialColumn = string.Equals(a, "i", StringComparison.OrdinalIgnoreCase)
            ? "DenialCodes"
            : "DenialCode";

        // DenialInsight does not have these task-level columns
        var isInsight = string.Equals(a, "i", StringComparison.OrdinalIgnoreCase);

        if (IsReviewerOnly(f.Role))
        {
            w.Add($"ISNULL({a}.AssignedTo,'')=@RoleUserName");
            p["@RoleUserName"] = f.UserName ?? string.Empty;
        }
        if (includeStatus && !string.IsNullOrWhiteSpace(f.Status))
        {
            w.Add(TextInSql($"ISNULL({a}.Status,'')", "@Status"));
            p["@Status"] = f.Status.Trim();
        }

        if (includeAssigned && !string.IsNullOrWhiteSpace(f.AssignedTo))
        {
            w.Add(TextInSql($"ISNULL({a}.AssignedTo,'')", "@AssignedTo"));
            p["@AssignedTo"] = f.AssignedTo.Trim();
        }

        if (includeAssigned && !string.IsNullOrWhiteSpace(f.Reviewer))
        {
            w.Add(TextInSql($"ISNULL({a}.AssignedTo,'')", "@Reviewer"));
            p["@Reviewer"] = f.Reviewer.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.DenialCode))
        {
            w.Add(TextInSql($"ISNULL({a}.{denialColumn},'')", "@DenialCode"));
            p["@DenialCode"] = f.DenialCode.Trim();
        }

        // Use display/source payer name only. Do not filter by PayerNameNormalized here.
        if (!string.IsNullOrWhiteSpace(f.PayerName))
        {
            if (isInsight)
                w.Add(TextInSql($"ISNULL({a}.HighImpactInsurance,'')", "@PayerName"));
            else
                w.Add(TextInSql($"ISNULL({a}.PayerName,'')", "@PayerName"));

            p["@PayerName"] = f.PayerName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.ActionCategory))
        {
            w.Add(TextInSql($"ISNULL({a}.ActionCategory,'')", "@ActionCategory"));
            p["@ActionCategory"] = f.ActionCategory.Trim();
        }

        // Priority does not exist in DenialInsight
        if (!isInsight && !string.IsNullOrWhiteSpace(f.Priority))
        {
            w.Add(TextInSql($"ISNULL({a}.Priority,'')", "@Priority"));
            p["@Priority"] = f.Priority.Trim();
        }


        if (!isInsight && !string.IsNullOrWhiteSpace(f.Clinic))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ClinicName,'')", "@Clinic"));
            p["@Clinic"] = f.Clinic.Trim();
        }

        if (!isInsight && !string.IsNullOrWhiteSpace(f.SalesRepname))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.SalesRepname,'')", "@SalesRepname"));
            p["@SalesRepname"] = f.SalesRepname.Trim();
        }

        if (!isInsight && !string.IsNullOrWhiteSpace(f.ReferringProvider))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ReferringProvider,'')", "@ReferringProvider"));
            p["@ReferringProvider"] = f.ReferringProvider.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.DenialClassification))
        {
            if (isInsight)
            {
                w.Add(@"EXISTS (
                SELECT 1
                FROM dbo.DenialTaskBoard tbx WITH (NOLOCK)
                WHERE " + LabScopeSql("tbx.LabId") + @"
                  AND EXISTS (SELECT 1 FROM STRING_SPLIT(@DenialClassification, N'¬') mv WHERE LOWER(LTRIM(RTRIM(ISNULL(tbx.DenialClassification,'')))) = LOWER(LTRIM(RTRIM(mv.value))))
                  AND (
                        ISNULL(tbx.DenialCode,'') = ISNULL(i.DenialCodes,'')
                        OR ISNULL(tbx.PayerName,'') = ISNULL(i.HighImpactInsurance,'')
                      )
            )");
            }
            else
            {
                w.Add(TextInSql($"ISNULL({a}.DenialClassification,'')", "@DenialClassification"));
            }
            p["@DenialClassification"] = f.DenialClassification.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.RunId))
        {
            w.Add($"ISNULL({a}.RunId,'')=@RunId");
            p["@RunId"] = f.RunId.Trim();
        }

        if (f.FromDate.HasValue)
        {
            w.Add($"CAST({a}.CreatedOn AS date)>=@FromDate");
            p["@FromDate"] = f.FromDate.Value.Date;
        }

        if (f.ToDate.HasValue)
        {
            w.Add($"CAST({a}.CreatedOn AS date)<=@ToDate");
            p["@ToDate"] = f.ToDate.Value.Date;
        }

        if (!string.IsNullOrWhiteSpace(f.SearchText))
        {
            if (isInsight)
            {
                w.Add($@"(
                ISNULL({a}.{denialColumn},'') LIKE @Search
                OR ISNULL({a}.Descriptions,'') LIKE @Search
                OR ISNULL({a}.HighImpactInsurance,'') LIKE @Search
                OR ISNULL({a}.ActionCategory,'') LIKE @Search
                OR ISNULL({a}.ActionCode,'') LIKE @Search
                OR ISNULL({a}.Task,'') LIKE @Search
            )");
            }
            else
            {
                w.Add($@"(
                ISNULL({a}.TaskID,'') LIKE @Search
                OR ISNULL({a}.ClaimID,'') LIKE @Search
                OR ISNULL({a}.ClaimIDNormalized,'') LIKE @Search
                OR ISNULL({a}.{denialColumn},'') LIKE @Search
                OR ISNULL({a}.PayerName,'') LIKE @Search
            )");
            }

            p["@Search"] = "%" + f.SearchText.Trim() + "%";
        }

        if (!isInsight && !string.IsNullOrWhiteSpace(f.TaskView))
        {
            var taskViewSql = BuildTaskViewSql(f.TaskView, a);
            if (!string.IsNullOrWhiteSpace(taskViewSql)) w.Add(taskViewSql);
        }

        return (w.Count == 0 ? string.Empty : " AND " + string.Join(" AND ", w), p);
    }

    private static (string WhereClause, Dictionary<string, object> Parameters) BuildAgingTaskWhere(DenialWorkflowFilter f, string a, HashSet<string> cols)
    {
        var w = new List<string>();
        var p = new Dictionary<string, object>();
        bool Has(string column) => cols.Contains(column);

        if (IsReviewerOnly(f.Role) && Has("AssignedTo"))
        {
            w.Add($"ISNULL({a}.AssignedTo,'')=@TaskRoleUserName");
            p["@TaskRoleUserName"] = f.UserName ?? string.Empty;
        }

        if (!string.IsNullOrWhiteSpace(f.Status) && Has("Status"))
        {
            w.Add(TextInSql($"ISNULL({a}.Status,'')", "@TaskStatus"));
            p["@TaskStatus"] = f.Status.Trim();
        }

        var assignedFilter = !string.IsNullOrWhiteSpace(f.AssignedTo) ? f.AssignedTo : f.Reviewer;
        if (!string.IsNullOrWhiteSpace(assignedFilter) && Has("AssignedTo"))
        {
            w.Add(TextInSql($"ISNULL({a}.AssignedTo,'')", "@TaskAssignedTo"));
            p["@TaskAssignedTo"] = assignedFilter.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.DenialCode) && Has("DenialCode"))
        {
            w.Add(TextInSql($"ISNULL({a}.DenialCode,'')", "@TaskDenialCode"));
            p["@TaskDenialCode"] = f.DenialCode.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.PayerName) && Has("PayerName"))
        {
            w.Add(TextInSql($"ISNULL({a}.PayerName,'')", "@TaskPayerName"));
            p["@TaskPayerName"] = f.PayerName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.PanelName) && Has("PanelName"))
        {
            w.Add(TextInSql($"ISNULL({a}.PanelName,'')", "@TaskPanelName"));
            p["@TaskPanelName"] = f.PanelName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.ActionCategory) && Has("ActionCategory"))
        {
            w.Add(TextInSql($"ISNULL({a}.ActionCategory,'')", "@TaskActionCategory"));
            p["@TaskActionCategory"] = f.ActionCategory.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.Priority) && Has("Priority"))
        {
            w.Add(TextInSql($"ISNULL({a}.Priority,'')", "@TaskPriority"));
            p["@TaskPriority"] = f.Priority.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.Clinic) && Has("ClinicName"))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ClinicName,'')", "@TaskClinic"));
            p["@TaskClinic"] = f.Clinic.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.SalesRepname) && Has("SalesRepname"))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.SalesRepname,'')", "@TaskSalesRepname"));
            p["@TaskSalesRepname"] = f.SalesRepname.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.ReferringProvider) && Has("ReferringProvider"))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ReferringProvider,'')", "@TaskReferringProvider"));
            p["@TaskReferringProvider"] = f.ReferringProvider.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.DenialClassification) && Has("DenialClassification"))
        {
            w.Add(TextInSql($"ISNULL({a}.DenialClassification,'')", "@TaskDenialClassification"));
            p["@TaskDenialClassification"] = f.DenialClassification.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.RunId) && Has("RunId"))
        {
            w.Add($"ISNULL({a}.RunId,'')=@TaskRunId");
            p["@TaskRunId"] = f.RunId.Trim();
        }

        if (f.FromDate.HasValue && Has("DateOfService"))
        {
            w.Add($"CAST({a}.DateOfService AS date)>=@TaskFromDate");
            p["@TaskFromDate"] = f.FromDate.Value.Date;
        }

        if (f.ToDate.HasValue && Has("DateOfService"))
        {
            w.Add($"CAST({a}.DateOfService AS date)<=@TaskToDate");
            p["@TaskToDate"] = f.ToDate.Value.Date;
        }

        if (!string.IsNullOrWhiteSpace(f.SearchText))
        {
            var searchParts = new List<string>();
            foreach (var col in new[] { "TaskID", "ClaimID", "ClaimIDNormalized", "DenialCode", "PayerName" })
                if (Has(col)) searchParts.Add($"ISNULL({a}.{col},'') LIKE @TaskSearch");

            if (searchParts.Count > 0)
            {
                w.Add("(" + string.Join(" OR ", searchParts) + ")");
                p["@TaskSearch"] = "%" + f.SearchText.Trim() + "%";
            }
        }

        if (!string.IsNullOrWhiteSpace(f.TaskView))
        {
            var taskViewSql = BuildTaskViewSql(f.TaskView, a);
            if (!string.IsNullOrWhiteSpace(taskViewSql)) w.Add(taskViewSql);
        }

        return (w.Count == 0 ? string.Empty : " AND " + string.Join(" AND ", w), p);
    }

    private static (string WhereClause, Dictionary<string, object> Parameters) BuildClaimWhere(DenialWorkflowFilter f, string a)
    {
        var w = new List<string>();
        var p = new Dictionary<string, object>();

        if (IsReviewerOnly(f.Role))
        {
            w.Add($@"EXISTS (
                SELECT 1
                FROM dbo.DenialTaskBoard tbx WITH (NOLOCK)
                WHERE ISNULL(tbx.AssignedTo,'') = @RoleUserName
                  AND tbx.ClaimIDNormalized = CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL({a}.VisitNumber,''))), 'CLM-', ''))
            )");
            p["@RoleUserName"] = f.UserName ?? string.Empty;
        }
        if (!string.IsNullOrWhiteSpace(f.DenialCode))
        {
            w.Add(TextInSql($"ISNULL({a}.DenialCodeNormalized,'')", "@DenialCode"));
            p["@DenialCode"] = f.DenialCode.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.PayerName))
        {
            w.Add(TextInSql($"ISNULL({a}.PayerName,'')", "@PayerName"));
            p["@PayerName"] = f.PayerName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.PanelName))
        {
            w.Add(TextInSql($"ISNULL({a}.PanelName,'')", "@PanelName"));
            p["@PanelName"] = f.PanelName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.Clinic))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ClinicName,'')", "@Clinic"));
            p["@Clinic"] = f.Clinic.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.SalesRepname))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.SalesRepname,'')", "@SalesRepname"));
            p["@SalesRepname"] = f.SalesRepname.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.ReferringProvider))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ReferringProvider,'')", "@ReferringProvider"));
            p["@ReferringProvider"] = f.ReferringProvider.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.ActionCategory))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.ActionCategory,'')", "@ActionCategory"));
            p["@ActionCategory"] = f.ActionCategory.Trim();
        }

        if (!string.IsNullOrWhiteSpace(f.DenialClassification))
        {
            w.Add(TextLikeAnySql($"ISNULL({a}.DenialClassification,'')", "@DenialClassification"));
            p["@DenialClassification"] = f.DenialClassification.Trim();
        }

        if (f.FromDate.HasValue)
        {
            w.Add($"CAST({a}.DateOfService AS date)>=@FromDate");
            p["@FromDate"] = f.FromDate.Value.Date;
        }

        if (f.ToDate.HasValue)
        {
            w.Add($"CAST({a}.DateOfService AS date)<=@ToDate");
            p["@ToDate"] = f.ToDate.Value.Date;
        }

        if (!string.IsNullOrWhiteSpace(f.SearchText))
        {
            w.Add($@"(
			ISNULL({a}.VisitNumber,'') LIKE @Search OR
			ISNULL({a}.PatientID,'') LIKE @Search OR
			ISNULL({a}.ClinicName,'') LIKE @Search OR
			ISNULL({a}.PayerName,'') LIKE @Search OR
			ISNULL({a}.ReferringProvider,'') LIKE @Search
		)");

            p["@Search"] = "%" + f.SearchText.Trim() + "%";
        }

        if (!string.IsNullOrWhiteSpace(f.TaskView))
        {
            var taskViewSql = BuildClaimTaskViewExistsSql(f.TaskView, a);
            if (!string.IsNullOrWhiteSpace(taskViewSql)) w.Add(taskViewSql);
        }

        return (w.Count == 0 ? string.Empty : " AND " + string.Join(" AND ", w), p);
    }

    private static string BuildTaskViewSql(string? taskView, string a)
    {
        var view = NormalizeTaskView(taskView);
        return view switch
        {
            // Claim Assignment: New means no reviewer assigned, active, and created within 48 hours.
            // Imported rows may have blank/New/Open/Review/Pending Review statuses, so do not require one exact status.
            "new" => $"NULLIF(LTRIM(RTRIM(ISNULL({a}.AssignedTo,''))),'') IS NULL AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT IN ('closed','completed') AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT LIKE '%escal%' AND DATEDIFF(HOUR, ISNULL({a}.CreatedOn, SYSDATETIME()), SYSDATETIME()) <= 48",

            // Claim Assignment: Unassigned means no reviewer assigned after the first 48 hours.
            "unassigned" => $"NULLIF(LTRIM(RTRIM(ISNULL({a}.AssignedTo,''))),'') IS NULL AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT IN ('closed','completed') AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT LIKE '%escal%' AND DATEDIFF(HOUR, ISNULL({a}.CreatedOn, SYSDATETIME()), SYSDATETIME()) > 48",

            // Claim Assignment / My Worklist: assigned active rows.
            "assigned" => $"NULLIF(LTRIM(RTRIM(ISNULL({a}.AssignedTo,''))),'') IS NOT NULL AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT IN ('closed','completed') AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT LIKE '%escal%'",
            "payerfollowup" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('payer followup required','payer follow-up required','followup required')",
            "pendingdocumentation" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('pending documentation','documentation pending','document required')",
            "pendingpayerresponse" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('pending payer','pending payer response')",
            "writeoffapproval" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('write off approval pending','write-off pending approval','write off pending approval','write-off approval pending')",

            // Claim Assignment / My Worklist: closed rows.
            "closed" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('closed','completed')",

            // My Worklist: New means assigned active work after reviewer/user filter is applied.
            "open" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('','new','open','review','pending review','in progress','pending payer','pending documentation')",
            "myopen" => $"NULLIF(LTRIM(RTRIM(ISNULL({a}.AssignedTo,''))),'') IS NOT NULL AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT IN ('closed','completed') AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT LIKE '%escal%' AND DATEDIFF(HOUR, COALESCE({a}.ReviewerUpdatedOn, {a}.CreatedOn, SYSDATETIME()), SYSDATETIME()) <= 48",
            "myassigned" => $"NULLIF(LTRIM(RTRIM(ISNULL({a}.AssignedTo,''))),'') IS NOT NULL AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT IN ('closed','completed') AND LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) NOT LIKE '%escal%' AND DATEDIFF(HOUR, COALESCE({a}.ReviewerUpdatedOn, {a}.CreatedOn, SYSDATETIME()), SYSDATETIME()) > 48",

            // Claim Assignment / My Worklist: escalated rows.
            "escalations" => $"(LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) LIKE '%escal%' OR LOWER(LTRIM(RTRIM(ISNULL({a}.SLAStatus,'')))) IN ('breached','overdue','at risk','atrisk'))",
            "internalescalation" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('internal escalation','escalated')",
            "externalescalation" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) = 'external escalation'",
            "escalationresponse" => $"(LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('required review','in review','responded','response submitted','manager response','writeoffapproved','writeoffrejected') OR (LOWER(LTRIM(RTRIM(ISNULL({a}.Status,''))))='rework' AND LOWER(LTRIM(RTRIM(ISNULL({a}.WorkFlowStatus,''))))='response escalation'))",
            "verification" => $"LOWER(LTRIM(RTRIM(ISNULL({a}.Status,'')))) IN ('required review','verification pending')",

            // My Worklist: Rework - closed once and reassigned again
            "rework" => $@"EXISTS (
					SELECT 1
					FROM dbo.DenialTaskHistory h WITH (NOLOCK)
					WHERE (ISNULL(h.TaskID,'') = ISNULL({a}.TaskID,'') OR ISNULL(h.UniqueTrackId,'') = ISNULL({a}.UniqueTrackId,''))
					  AND {LabScopeSql("h.LabId")}
					  AND LOWER(LTRIM(RTRIM(ISNULL(h.OldStatus,'')))) IN ('closed','completed')
					  AND NULLIF(LTRIM(RTRIM(ISNULL(h.NewAssignedTo,''))),'') IS NOT NULL
				)",
            _ => string.Empty
        };
    }

    private static string BuildClaimTaskViewExistsSql(string? taskView, string a)
    {
        var taskPredicate = BuildTaskViewSql(taskView, "tbx");
        if (string.IsNullOrWhiteSpace(taskPredicate)) return string.Empty;

        return $@"EXISTS (
			SELECT 1
			FROM dbo.DenialTaskBoard tbx WITH (NOLOCK)
			WHERE tbx.ClaimIDNormalized = CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL({a}.VisitNumber,''))), 'CLM-', ''))
			  AND {LabScopeSql("tbx.LabId")}
			  AND {taskPredicate}
		)";
    }

    private static string NormalizeTaskView(string? taskView)
    {
        var value = (taskView ?? string.Empty).Trim().ToLowerInvariant().Replace("-", "").Replace("_", "").Replace(" ", "");
        return value switch
        {
            "new" => "new",
            "newunassigned" or "unassigned" => "unassigned",
            "assigned" or "active" => "assigned",
            "payerfollowup" or "payerresponsefollowup" => "payerfollowup",
            "pendingdocumentation" or "documentation" or "documentationqueue" => "pendingdocumentation",
            "pendingpayerresponse" or "payerresponse" => "pendingpayerresponse",
            "writeoffapproval" or "writeoff" => "writeoffapproval",
            "all" or "allclaims" => "all",
            "closed" or "completed" => "closed",
            "escalation" or "escalations" or "escalated" or "escalate" => "escalations",
            "internalescalation" or "internal" => "internalescalation",
            "externalescalation" or "external" => "externalescalation",
            "escalationresponse" or "response" => "escalationresponse",
            "verification" or "requiredreview" => "verification",
            "open" or "opennew" or "pending" => "open",
            "reviewernew" or "mynew" or "myopen" => "myopen",
            "reviewerassigned" or "myassigned" => "myassigned",
            "rework" or "reassigned" => "rework",
            _ => string.Empty
        };
    }

    public async Task EnsureClaimSupportTablesAsync(int labId, CancellationToken ct)
    {
        const string sql = @"
IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimNotes
    (
        NoteId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimNotes PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        TaskId nvarchar(100) NULL,
        CptCode nvarchar(50) NULL,
        NoteLevel nvarchar(20) NOT NULL,
        NoteText nvarchar(max) NOT NULL,
        Status nvarchar(50) NULL,
        NextFollowUpDate date NULL,
        CreatedBy nvarchar(256) NOT NULL,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClaimNotes_CreatedOn DEFAULT SYSUTCDATETIME(),
        IsDeleted bit NOT NULL CONSTRAINT DF_DenialClaimNotes_IsDeleted DEFAULT 0
    );
    CREATE INDEX IX_DenialClaimNotes_Claim ON dbo.DenialClaimNotes(LabId, ClaimId, NoteLevel, CreatedOn DESC);
    CREATE INDEX IX_DenialClaimNotes_Line ON dbo.DenialClaimNotes(LabId, ClaimId, TaskId, CptCode, CreatedOn DESC);
END;

IF OBJECT_ID('dbo.DenialClaimDocuments','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimDocuments
    (
        DocumentId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimDocuments PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        OriginalFileName nvarchar(260) NOT NULL,
        StoredFileName nvarchar(260) NOT NULL,
        ContentType nvarchar(150) NULL,
        FileSizeBytes bigint NOT NULL,
        FilePath nvarchar(1000) NOT NULL,
        Comment nvarchar(1000) NULL,
        UploadedBy nvarchar(256) NOT NULL,
        UploadedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClaimDocuments_UploadedOn DEFAULT SYSUTCDATETIME(),
        IsDeleted bit NOT NULL CONSTRAINT DF_DenialClaimDocuments_IsDeleted DEFAULT 0
    );
    CREATE INDEX IX_DenialClaimDocuments_Claim ON dbo.DenialClaimDocuments(LabId, ClaimId, UploadedOn DESC);
END;

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimEscalations
    (
        EscalationId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimEscalations PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        TaskId nvarchar(100) NULL,
        CptCode nvarchar(50) NULL,
        EscalationLevel nvarchar(20) NOT NULL,
        EscalationReason nvarchar(300) NOT NULL,
        Comments nvarchar(max) NULL,
        Status nvarchar(50) NOT NULL CONSTRAINT DF_DenialClaimEscalations_Status DEFAULT 'Open',
        EscalatedTo nvarchar(256) NULL,
        EscalatedToRole nvarchar(100) NULL,
        NextFollowUpDate date NULL,
        CreatedBy nvarchar(256) NOT NULL,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClaimEscalations_CreatedOn DEFAULT SYSUTCDATETIME(),
        IsDeleted bit NOT NULL CONSTRAINT DF_DenialClaimEscalations_IsDeleted DEFAULT 0
    );
    CREATE INDEX IX_DenialClaimEscalations_Claim ON dbo.DenialClaimEscalations(LabId, ClaimId, EscalationLevel, CreatedOn DESC);
    CREATE INDEX IX_DenialClaimEscalations_Line ON dbo.DenialClaimEscalations(LabId, ClaimId, TaskId, CptCode, CreatedOn DESC);

END;

IF OBJECT_ID('dbo.DenialClosedClaims','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClosedClaims
    (
        ClosedClaimId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClosedClaims PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        PayerName nvarchar(256) NULL,
        PanelName nvarchar(256) NULL,
        PatientName nvarchar(255) NULL,
        PatientDOB date NULL,
        PatientId nvarchar(100) NULL,
        SubscriberId nvarchar(100) NULL,
        ClinicName nvarchar(256) NULL,
        SalesRepname nvarchar(256) NULL,
        ReferringProvider nvarchar(256) NULL,
        DateOfService date NULL,
        AssignedTo nvarchar(255) NULL,
        Status nvarchar(100) NOT NULL CONSTRAINT DF_DenialClosedClaims_Status DEFAULT 'Closed',
        WorkFlowStatus nvarchar(100) NOT NULL CONSTRAINT DF_DenialClosedClaims_WorkFlowStatus DEFAULT 'Closed Claim',
        TaskCount int NOT NULL CONSTRAINT DF_DenialClosedClaims_TaskCount DEFAULT 0,
        InsuranceBalance decimal(18,2) NOT NULL CONSTRAINT DF_DenialClosedClaims_InsuranceBalance DEFAULT 0,
        ClosedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaims_ClosedOn DEFAULT SYSUTCDATETIME(),
        ClosedBy nvarchar(256) NULL,
        LastUpdatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaims_LastUpdatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialClosedClaims_Lab_Claim ON dbo.DenialClosedClaims(LabId, ClaimId);
    CREATE INDEX IX_DenialClosedClaims_Lab_ClosedOn ON dbo.DenialClosedClaims(LabId, ClosedOn DESC) INCLUDE(ClaimId, AssignedTo, WorkFlowStatus, InsuranceBalance);
END;

IF OBJECT_ID('dbo.DenialClosedClaimsHistory','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClosedClaimsHistory
    (
        HistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClosedClaimsHistory PRIMARY KEY,
        ClosedClaimId bigint NULL,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        ActionType nvarchar(100) NOT NULL,
        OldWorkFlowStatus nvarchar(100) NULL,
        NewWorkFlowStatus nvarchar(100) NULL,
        OldAssignedTo nvarchar(255) NULL,
        NewAssignedTo nvarchar(255) NULL,
        Comments nvarchar(max) NULL,
        ActionBy nvarchar(256) NULL,
        ActionDate datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaimsHistory_ActionDate DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_DenialClosedClaimsHistory_Lab_Claim ON dbo.DenialClosedClaimsHistory(LabId, ClaimId, ActionDate DESC);
END;

IF COL_LENGTH('dbo.DenialClaimNotes','Status') IS NULL ALTER TABLE dbo.DenialClaimNotes ADD Status nvarchar(50) NULL;
IF COL_LENGTH('dbo.DenialClaimNotes','NextFollowUpDate') IS NULL ALTER TABLE dbo.DenialClaimNotes ADD NextFollowUpDate date NULL;
IF COL_LENGTH('dbo.DenialClaimEscalations','EscalatedTo') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD EscalatedTo nvarchar(256) NULL;
IF COL_LENGTH('dbo.DenialClaimEscalations','EscalatedToRole') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD EscalatedToRole nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialClaimEscalations','NextFollowUpDate') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD NextFollowUpDate date NULL;
IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL AND COL_LENGTH('dbo.DenialTaskBoard','WorkFlowStatus') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD WorkFlowStatus nvarchar(100) NULL;
IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL AND COL_LENGTH('dbo.DenialLineItem','AssignedTo') IS NULL ALTER TABLE dbo.DenialLineItem ADD AssignedTo nvarchar(255) NULL;
IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL AND COL_LENGTH('dbo.DenialLineItem','WorkFlowStatus') IS NULL ALTER TABLE dbo.DenialLineItem ADD WorkFlowStatus nvarchar(100) NULL;
";
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<IReadOnlyList<DenialNoteRow>> GetNotesAsync(int labId, string claimId, string? taskId, string? cptCode, string noteLevel, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(labId, ct);
        var rows = new List<DenialNoteRow>();
        var isLine = string.Equals(noteLevel, "Line", StringComparison.OrdinalIgnoreCase);
        var sql = isLine ? @"
SELECT TOP (200) NoteId,LabId,ClaimId,TaskId,CptCode,NoteLevel,NoteText,Status,NextFollowUpDate,CreatedBy,CreatedOn
FROM dbo.DenialClaimNotes WITH (NOLOCK)
WHERE IsDeleted=0 AND LabId=@LabId AND NoteLevel='Line'
  AND (ClaimId=@ClaimId
       OR REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '')
       OR REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\'
       OR REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\')
  AND (@TaskId='' OR ISNULL(TaskId,'')=@TaskId)
  AND (@CptCode='' OR ISNULL(CptCode,'')=@CptCode)
ORDER BY CreatedOn DESC, NoteId DESC;" : @"
SELECT TOP (200) NoteId,LabId,ClaimId,TaskId,CptCode,NoteLevel,NoteText,Status,NextFollowUpDate,CreatedBy,CreatedOn
FROM dbo.DenialClaimNotes WITH (NOLOCK)
WHERE IsDeleted=0 AND LabId=@LabId AND NoteLevel='Claim'
  AND (ClaimId=@ClaimId
       OR REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '')
       OR REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\'
       OR REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\')
ORDER BY CreatedOn DESC, NoteId DESC;";
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@ClaimId", claimId.Trim());
        cmd.Parameters.AddWithValue("@TaskId", taskId?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@CptCode", cptCode?.Trim() ?? string.Empty);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct)) rows.Add(ReadNote(rd));
        return rows;
    }

    public async Task<DenialNoteRow> SaveNoteAsync(SaveDenialNoteRequest request, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(request.LabId, ct);
        const string sql = @"
INSERT INTO dbo.DenialClaimNotes(LabId,ClaimId,TaskId,CptCode,NoteLevel,NoteText,Status,NextFollowUpDate,CreatedBy)
OUTPUT INSERTED.NoteId,INSERTED.LabId,INSERTED.ClaimId,INSERTED.TaskId,INSERTED.CptCode,INSERTED.NoteLevel,INSERTED.NoteText,INSERTED.Status,INSERTED.NextFollowUpDate,INSERTED.CreatedBy,INSERTED.CreatedOn
VALUES(@LabId,@ClaimId,@TaskId,@CptCode,@NoteLevel,@NoteText,@Status,@NextFollowUpDate,@CreatedBy);";
        await using var con = OpenLab(request.LabId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", request.LabId);
        cmd.Parameters.AddWithValue("@ClaimId", request.ClaimId.Trim());
        cmd.Parameters.AddWithValue("@TaskId", (object?)request.TaskId?.Trim() ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@CptCode", (object?)request.CptCode?.Trim() ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@NoteLevel", string.Equals(request.NoteLevel, "Line", StringComparison.OrdinalIgnoreCase) ? "Line" : "Claim");
        cmd.Parameters.AddWithValue("@NoteText", request.NoteText.Trim());
        cmd.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(request.Status) ? (object)DBNull.Value : request.Status.Trim());
        cmd.Parameters.AddWithValue("@NextFollowUpDate", request.NextFollowUpDate.HasValue ? request.NextFollowUpDate.Value.Date : (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@CreatedBy", string.IsNullOrWhiteSpace(request.CreatedBy) ? "ReactWorkflow" : request.CreatedBy.Trim());
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct)) return ReadNote(rd);
        throw new InvalidOperationException("Unable to save note.");
    }

    public async Task<IReadOnlyList<ClaimDocumentRow>> GetClaimDocumentsAsync(int labId, string claimId, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(labId, ct);
        const string sql = @"
SELECT TOP (200) DocumentId,LabId,ClaimId,OriginalFileName,StoredFileName,ContentType,FileSizeBytes,FilePath,Comment,UploadedBy,UploadedOn
FROM dbo.DenialClaimDocuments WITH (NOLOCK)
WHERE IsDeleted=0 AND LabId=@LabId
  AND (ClaimId=@ClaimId
       OR REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '')
       OR REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\'
       OR REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\')
ORDER BY UploadedOn DESC, DocumentId DESC;";
        var rows = new List<ClaimDocumentRow>();
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@ClaimId", claimId.Trim());
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct)) rows.Add(ReadDocument(rd));
        return rows;
    }

    public async Task<ClaimDocumentRow?> GetClaimDocumentAsync(int labId, long documentId, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(labId, ct);
        const string sql = @"
SELECT TOP (1) DocumentId,LabId,ClaimId,OriginalFileName,StoredFileName,ContentType,FileSizeBytes,FilePath,Comment,UploadedBy,UploadedOn
FROM dbo.DenialClaimDocuments WITH (NOLOCK)
WHERE IsDeleted=0 AND LabId=@LabId AND DocumentId=@DocumentId;";
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@DocumentId", documentId);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        return await rd.ReadAsync(ct) ? ReadDocument(rd) : null;
    }

    public async Task<ClaimDocumentRow> SaveClaimDocumentAsync(ClaimDocumentRow row, CancellationToken ct)
    {
        const string sql = @"
INSERT INTO dbo.DenialClaimDocuments(LabId,ClaimId,OriginalFileName,StoredFileName,ContentType,FileSizeBytes,FilePath,Comment,UploadedBy)
OUTPUT INSERTED.DocumentId,INSERTED.LabId,INSERTED.ClaimId,INSERTED.OriginalFileName,INSERTED.StoredFileName,INSERTED.ContentType,INSERTED.FileSizeBytes,INSERTED.FilePath,INSERTED.Comment,INSERTED.UploadedBy,INSERTED.UploadedOn
VALUES(@LabId,@ClaimId,@OriginalFileName,@StoredFileName,@ContentType,@FileSizeBytes,@FilePath,@Comment,@UploadedBy);";
        await using var con = OpenLab(row.LabId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", row.LabId);
        cmd.Parameters.AddWithValue("@ClaimId", row.ClaimId.Trim());
        cmd.Parameters.AddWithValue("@OriginalFileName", row.OriginalFileName);
        cmd.Parameters.AddWithValue("@StoredFileName", row.StoredFileName);
        cmd.Parameters.AddWithValue("@ContentType", row.ContentType);
        cmd.Parameters.AddWithValue("@FileSizeBytes", row.FileSizeBytes);
        cmd.Parameters.AddWithValue("@FilePath", row.FilePath);
        cmd.Parameters.AddWithValue("@Comment", row.Comment ?? string.Empty);
        cmd.Parameters.AddWithValue("@UploadedBy", row.UploadedBy);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct)) return ReadDocument(rd);
        throw new InvalidOperationException("Unable to save document.");
    }

    public async Task<bool> CanDeleteClaimDocumentAsync(int labId, string claimId, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(labId, ct);
        const string sql = @"
DECLARE @NormalizedClaimId nvarchar(150) = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '');

IF EXISTS (
    SELECT 1
    FROM dbo.DenialClosedClaims c WITH (NOLOCK)
    WHERE c.LabId = @LabId
      AND (LTRIM(RTRIM(ISNULL(c.ClaimId,''))) = @ClaimId
           OR REPLACE(LTRIM(RTRIM(ISNULL(c.ClaimId,''))), 'CLM-', '') = @NormalizedClaimId)
)
BEGIN
    SELECT CAST(0 AS bit);
    RETURN;
END;

IF EXISTS (
    SELECT 1
    FROM dbo.DenialClaimEscalations e WITH (NOLOCK)
    WHERE e.IsDeleted = 0
      AND e.LabId = @LabId
      AND (LTRIM(RTRIM(ISNULL(e.ClaimId,''))) = @ClaimId
           OR REPLACE(LTRIM(RTRIM(ISNULL(e.ClaimId,''))), 'CLM-', '') = @NormalizedClaimId)
      AND (LOWER(LTRIM(RTRIM(ISNULL(e.Status,'')))) IN ('in review','responded','response submitted','manager response')
           OR ISNULL(e.Comments,'') LIKE '%Manager Response:%'
           OR ISNULL(e.Comments,'') LIKE '%Client Response:%'
           OR ISNULL(e.Comments,'') LIKE '%Account Manager Response:%')
)
BEGIN
    SELECT CAST(0 AS bit);
    RETURN;
END;

SELECT CAST(1 AS bit);";
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@ClaimId", claimId.Trim());
        var result = await cmd.ExecuteScalarAsync(ct);
        return result is bool b ? b : result != null && result != DBNull.Value && Convert.ToBoolean(result);
    }

    public async Task<int> DeleteClaimDocumentAsync(int labId, long documentId, CancellationToken ct)
    {
        const string sql = @"
UPDATE dbo.DenialClaimDocuments
SET IsDeleted = 1
WHERE IsDeleted = 0 AND LabId = @LabId AND DocumentId = @DocumentId;";
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@DocumentId", documentId);
        return await cmd.ExecuteNonQueryAsync(ct);
    }


    public async Task<IReadOnlyList<DenialClaimHistoryRow>> GetClaimHistoryAsync(int labId, string claimId, string? taskId, string? cptCode, string historyLevel, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(labId, ct);
        var rows = new List<DenialClaimHistoryRow>();
        var level = string.Equals(historyLevel, "Line", StringComparison.OrdinalIgnoreCase) ? "Line" : "Claim";

        var sql = @"
IF OBJECT_ID('tempdb..#ClaimTasks') IS NOT NULL DROP TABLE #ClaimTasks;
CREATE TABLE #ClaimTasks(TaskID nvarchar(100) NULL, UniqueTrackId nvarchar(100) NULL, ClaimID nvarchar(150) NULL, CptCode nvarchar(100) NULL);

INSERT INTO #ClaimTasks(TaskID,UniqueTrackId,ClaimID,CptCode)
SELECT ISNULL(t.TaskID,''), ISNULL(t.UniqueTrackId,''), ISNULL(t.ClaimID,''), ISNULL(t.CPTCode,'')
FROM dbo.DenialTaskBoard t WITH (NOLOCK)
WHERE (LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))) = @ClaimId
       OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) = @ClaimId
       OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) LIKE '%' + @ClaimId)
  AND (@Level='Claim' OR @TaskId='' OR ISNULL(t.TaskID,'')=@TaskId)
  AND (@Level='Claim' OR @CptCode='' OR ISNULL(t.CPTCode,'')=@CptCode);

-- Current assignment/status snapshot. Grouped so a claim with many lines shows one concise audit row per reviewer/status.
;WITH CurrentAssignment AS
(
    SELECT
        AssignedToGroup = ISNULL(AssignedTo,''),
        StatusGroup = ISNULL([Status],''),
        TaskCount = COUNT(1),
        LatestCreatedOn = MAX(CreatedOn)
    FROM dbo.DenialTaskBoard WITH (NOLOCK)
    WHERE (LTRIM(RTRIM(ISNULL(ClaimIDNormalized,''))) = @ClaimId
           OR LTRIM(RTRIM(ISNULL(ClaimID,''))) = @ClaimId
           OR LTRIM(RTRIM(ISNULL(ClaimID,''))) LIKE '%' + @ClaimId)
      AND (@Level='Claim' OR @TaskId='' OR ISNULL(TaskID,'')=@TaskId)
      AND (@Level='Claim' OR @CptCode='' OR ISNULL(CPTCode,'')=@CptCode)
    GROUP BY ISNULL(AssignedTo,''), ISNULL([Status],'')
)
SELECT TOP (100)
    HistoryId = CAST(ABS(CHECKSUM(AssignedToGroup + StatusGroup)) AS bigint),
    HistoryType = CAST('Current Assignment' AS nvarchar(50)),
    ClaimId = @ClaimId,
    TaskId = CAST('' AS nvarchar(100)),
    CptCode = CAST('' AS nvarchar(100)),
    ActionType = CAST('Current Assignment' AS nvarchar(100)),
    Title = CAST(CONCAT('Current assignment: ', ISNULL(NULLIF(AssignedToGroup,''),'Unassigned')) AS nvarchar(250)),
    Description = CAST(CONCAT(TaskCount, ' task(s) currently ', ISNULL(NULLIF(StatusGroup,''),'Open'), ' for ', ISNULL(NULLIF(AssignedToGroup,''),'Unassigned')) AS nvarchar(max)),
    OldStatus = CAST('' AS nvarchar(100)),
    NewStatus = StatusGroup,
    OldAssignedTo = CAST('' AS nvarchar(256)),
    NewAssignedTo = AssignedToGroup,
    ActionBy = CAST('System' AS nvarchar(256)),
    ActionDate = LatestCreatedOn,
    CreatedBy = CAST('System' AS nvarchar(256)),
    CreatedOn = LatestCreatedOn
FROM CurrentAssignment
ORDER BY LatestCreatedOn DESC;

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
BEGIN
    ;WITH HistBase AS
    (
        SELECT
            h.HistoryId,
            h.TaskID,
            h.UniqueTrackId,
            CptCode = ISNULL(ct.CptCode,''),
            h.ActionType,
            h.Comments,
            h.OldStatus,
            h.NewStatus,
            h.OldAssignedTo,
            h.NewAssignedTo,
            h.ActionBy,
            h.ActionDate
        FROM dbo.DenialTaskHistory h WITH (NOLOCK)
        LEFT JOIN #ClaimTasks ct ON ISNULL(ct.TaskID,'')=ISNULL(h.TaskID,'') OR ISNULL(ct.UniqueTrackId,'')=ISNULL(h.UniqueTrackId,'')
        WHERE h.LabId=@LabId
          AND EXISTS (SELECT 1 FROM #ClaimTasks m WHERE ISNULL(m.TaskID,'')=ISNULL(h.TaskID,'') OR ISNULL(m.UniqueTrackId,'')=ISNULL(h.UniqueTrackId,''))
          AND (@Level='Claim' OR @TaskId='' OR ISNULL(h.TaskID,'')=@TaskId)
    ), AssignmentAudit AS
    (
        SELECT
            HistoryId = MAX(CAST(HistoryId AS bigint)),
            HistoryType = CAST('Assignment Audit' AS nvarchar(50)),
            ClaimId = @ClaimId,
            TaskId = CAST('' AS nvarchar(100)),
            CptCode = CAST('' AS nvarchar(100)),
            ActionType = CAST('Assignment' AS nvarchar(100)),
            Title = CAST(CONCAT('Assigned ', COUNT(1), ' task(s) to ', ISNULL(NULLIF(MAX(ISNULL(NewAssignedTo,'')),''),'Unassigned')) AS nvarchar(250)),
            Description = CAST(CONCAT('Bulk assignment/audit grouped from ', COUNT(1), ' line task update(s).') AS nvarchar(max)),
            OldStatus = CAST('' AS nvarchar(100)),
            NewStatus = MAX(ISNULL(NewStatus,'')),
            OldAssignedTo = CAST('' AS nvarchar(256)),
            NewAssignedTo = MAX(ISNULL(NewAssignedTo,'')),
            ActionBy = MAX(ISNULL(ActionBy,'')),
            ActionDate = MAX(ActionDate),
            CreatedBy = MAX(ISNULL(ActionBy,'')),
            CreatedOn = MAX(ActionDate)
        FROM HistBase
        WHERE (ISNULL(ActionType,'') LIKE '%Assign%' OR ISNULL(OldAssignedTo,'')<>ISNULL(NewAssignedTo,''))
        GROUP BY ISNULL(NewAssignedTo,''), ISNULL(ActionBy,''), DATEADD(second, DATEDIFF(second, 0, ActionDate), 0)
    ), OtherAudit AS
    (
        SELECT TOP (500)
            HistoryId = CAST(HistoryId AS bigint),
            HistoryType = CAST('Task History' AS nvarchar(50)),
            ClaimId = @ClaimId,
            TaskId = ISNULL(TaskID,''),
            CptCode = ISNULL(CptCode,''),
            ActionType = ISNULL(ActionType,''),
            Title = ISNULL(ActionType,''),
            Description = ISNULL(Comments,''),
            OldStatus = ISNULL(OldStatus,''),
            NewStatus = ISNULL(NewStatus,''),
            OldAssignedTo = ISNULL(OldAssignedTo,''),
            NewAssignedTo = ISNULL(NewAssignedTo,''),
            ActionBy = ISNULL(ActionBy,''),
            ActionDate = ActionDate,
            CreatedBy = ISNULL(ActionBy,''),
            CreatedOn = ActionDate
        FROM HistBase
        WHERE NOT (ISNULL(ActionType,'') LIKE '%Assign%' OR ISNULL(OldAssignedTo,'')<>ISNULL(NewAssignedTo,''))
    )
    SELECT TOP (500) *
    FROM
    (
        SELECT * FROM AssignmentAudit
        UNION ALL
        SELECT * FROM OtherAudit
    ) x
    ORDER BY ActionDate DESC, HistoryId DESC;
END
ELSE
BEGIN
    SELECT TOP (0)
        HistoryId = CAST(0 AS bigint), HistoryType = CAST('Task History' AS nvarchar(50)), ClaimId = @ClaimId, TaskId = CAST('' AS nvarchar(100)), CptCode = CAST('' AS nvarchar(100)), ActionType = CAST('' AS nvarchar(100)), Title = CAST('' AS nvarchar(250)), Description = CAST('' AS nvarchar(max)), OldStatus = CAST('' AS nvarchar(100)), NewStatus = CAST('' AS nvarchar(100)), OldAssignedTo = CAST('' AS nvarchar(256)), NewAssignedTo = CAST('' AS nvarchar(256)), ActionBy = CAST('' AS nvarchar(256)), ActionDate = CAST(NULL AS datetime2), CreatedBy = CAST('' AS nvarchar(256)), CreatedOn = CAST(NULL AS datetime2);
END;

SELECT TOP (500)
    HistoryId = CAST(n.NoteId AS bigint),
    HistoryType = CAST(CASE WHEN n.NoteLevel='Line' THEN 'Line Note' ELSE 'Claim Note' END AS nvarchar(50)),
    ClaimId = ISNULL(n.ClaimId,''),
    TaskId = ISNULL(n.TaskId,''),
    CptCode = ISNULL(n.CptCode,''),
    ActionType = CAST('Note' AS nvarchar(100)),
    Title = CAST(CASE WHEN n.NoteLevel='Line' THEN 'Line note added' ELSE 'Claim note added' END AS nvarchar(250)),
    Description = ISNULL(n.NoteText,''),
    OldStatus = CAST('' AS nvarchar(100)),
    NewStatus = CAST('' AS nvarchar(100)),
    OldAssignedTo = CAST('' AS nvarchar(256)),
    NewAssignedTo = CAST('' AS nvarchar(256)),
    ActionBy = ISNULL(n.CreatedBy,''),
    ActionDate = n.CreatedOn,
    CreatedBy = ISNULL(n.CreatedBy,''),
    CreatedOn = n.CreatedOn
FROM dbo.DenialClaimNotes n WITH (NOLOCK)
WHERE n.IsDeleted=0 AND n.LabId=@LabId
  AND (n.ClaimId=@ClaimId
       OR REPLACE(LTRIM(RTRIM(ISNULL(n.ClaimId,''))), 'CLM-', '') = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '')
       OR REPLACE(LTRIM(RTRIM(ISNULL(n.ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\'
       OR REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(n.ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\')
  AND (@Level='Claim' OR n.NoteLevel='Line')
  AND (@Level='Claim' OR @TaskId='' OR ISNULL(n.TaskId,'')=@TaskId)
  AND (@Level='Claim' OR @CptCode='' OR ISNULL(n.CptCode,'')=@CptCode)
ORDER BY n.CreatedOn DESC, n.NoteId DESC;

SELECT TOP (500)
    HistoryId = CAST(e.EscalationId AS bigint),
    HistoryType = CAST(CASE WHEN e.EscalationLevel='Line' THEN 'Line Escalation' ELSE 'Claim Escalation' END AS nvarchar(50)),
    ClaimId = ISNULL(e.ClaimId,''),
    TaskId = ISNULL(e.TaskId,''),
    CptCode = ISNULL(e.CptCode,''),
    ActionType = CAST('Escalation' AS nvarchar(100)),
    Title = ISNULL(e.EscalationReason,''),
    Description = ISNULL(e.Comments,''),
    OldStatus = CAST('' AS nvarchar(100)),
    NewStatus = ISNULL(e.Status,''),
    OldAssignedTo = CAST('' AS nvarchar(256)),
    NewAssignedTo = CAST('' AS nvarchar(256)),
    ActionBy = ISNULL(e.CreatedBy,''),
    ActionDate = e.CreatedOn,
    CreatedBy = ISNULL(e.CreatedBy,''),
    CreatedOn = e.CreatedOn
FROM dbo.DenialClaimEscalations e WITH (NOLOCK)
WHERE e.IsDeleted=0 AND e.LabId=@LabId
  AND (e.ClaimId=@ClaimId
       OR REPLACE(LTRIM(RTRIM(ISNULL(e.ClaimId,''))), 'CLM-', '') = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '')
       OR REPLACE(LTRIM(RTRIM(ISNULL(e.ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\'
       OR REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(e.ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\')
  AND (@Level='Claim' OR e.EscalationLevel='Line')
  AND (@Level='Claim' OR @TaskId='' OR ISNULL(e.TaskId,'')=@TaskId)
  AND (@Level='Claim' OR @CptCode='' OR ISNULL(e.CptCode,'')=@CptCode)
ORDER BY e.CreatedOn DESC, e.EscalationId DESC;

SELECT TOP (500)
    HistoryId = CAST(d.DocumentId AS bigint),
    HistoryType = CAST('Document' AS nvarchar(50)),
    ClaimId = ISNULL(d.ClaimId,''),
    TaskId = CAST('' AS nvarchar(100)),
    CptCode = CAST('' AS nvarchar(100)),
    ActionType = CAST('Document Uploaded' AS nvarchar(100)),
    Title = ISNULL(d.OriginalFileName,''),
    Description = ISNULL(d.Comment,''),
    OldStatus = CAST('' AS nvarchar(100)),
    NewStatus = CAST('' AS nvarchar(100)),
    OldAssignedTo = CAST('' AS nvarchar(256)),
    NewAssignedTo = CAST('' AS nvarchar(256)),
    ActionBy = ISNULL(d.UploadedBy,''),
    ActionDate = d.UploadedOn,
    CreatedBy = ISNULL(d.UploadedBy,''),
    CreatedOn = d.UploadedOn
FROM dbo.DenialClaimDocuments d WITH (NOLOCK)
WHERE d.IsDeleted=0 AND d.LabId=@LabId
  AND (d.ClaimId=@ClaimId
       OR REPLACE(LTRIM(RTRIM(ISNULL(d.ClaimId,''))), 'CLM-', '') = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '')
       OR REPLACE(LTRIM(RTRIM(ISNULL(d.ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\'
       OR REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', '') LIKE REPLACE(LTRIM(RTRIM(ISNULL(d.ClaimId,''))), 'CLM-', '') + '\_%' ESCAPE '\')
  AND @Level='Claim'
ORDER BY d.UploadedOn DESC, d.DocumentId DESC;

DROP TABLE #ClaimTasks;";

        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@ClaimId", claimId.Trim());
        cmd.Parameters.AddWithValue("@TaskId", taskId?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@CptCode", cptCode?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@Level", level);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        do
        {
            while (await rd.ReadAsync(ct)) rows.Add(ReadClaimHistory(rd));
        } while (await rd.NextResultAsync(ct));

        return rows
            .OrderByDescending(x => x.ActionDate ?? x.CreatedOn ?? DateTime.MinValue)
            .ThenByDescending(x => x.HistoryId)
            .Take(500)
            .ToList();
    }

    public async Task<IReadOnlyList<DenialEscalationRow>> GetEscalationsAsync(int labId, string claimId, string? taskId, string? cptCode, string escalationLevel, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(labId, ct);
        var rows = new List<DenialEscalationRow>();
        var isLine = string.Equals(escalationLevel, "Line", StringComparison.OrdinalIgnoreCase);
        var sql = isLine ? @"
SELECT TOP (200) EscalationId,LabId,ClaimId,TaskId,CptCode,EscalationLevel,EscalationReason,Comments,Status,EscalatedTo,EscalatedToRole,NextFollowUpDate,CreatedBy,CreatedOn
FROM dbo.DenialClaimEscalations WITH (NOLOCK)
WHERE IsDeleted=0 AND LabId=@LabId AND EscalationLevel='Line'
  AND (ClaimId=@ClaimId OR REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', ''))
  AND (@TaskId='' OR ISNULL(TaskId,'')=@TaskId)
  AND (@CptCode='' OR ISNULL(CptCode,'')=@CptCode)
ORDER BY CreatedOn DESC, EscalationId DESC;" : @"
SELECT TOP (200) EscalationId,LabId,ClaimId,TaskId,CptCode,EscalationLevel,EscalationReason,Comments,Status,EscalatedTo,EscalatedToRole,NextFollowUpDate,CreatedBy,CreatedOn
FROM dbo.DenialClaimEscalations WITH (NOLOCK)
WHERE IsDeleted=0 AND LabId=@LabId AND EscalationLevel='Claim'
  AND (ClaimId=@ClaimId OR REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))), 'CLM-', '') = REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', ''))
ORDER BY CreatedOn DESC, EscalationId DESC;";
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@ClaimId", claimId.Trim());
        cmd.Parameters.AddWithValue("@TaskId", taskId?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@CptCode", cptCode?.Trim() ?? string.Empty);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct)) rows.Add(ReadEscalation(rd));
        return rows;
    }

    public async Task<PagedResult<DenialEscalationQueueRow>> GetEscalationQueueAsync(DenialWorkflowFilter filter, string escalationLevel, CancellationToken ct)
    {
        filter.PageSize = filter.PageSize <= 0 ? 100 : Math.Clamp(filter.PageSize, 25, 200);
        if (filter.Page <= 0) filter.Page = 1;
        var level = string.Equals(escalationLevel, "Line", StringComparison.OrdinalIgnoreCase) ? "Line" : "Claim";

        await EnsureClaimSupportTablesAsync(filter.LabId, ct);
        await using var con = OpenLab(filter.LabId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);

        var statusWhere = string.IsNullOrWhiteSpace(filter.Status) ? string.Empty : " AND EXISTS (SELECT 1 FROM STRING_SPLIT(@Status, N'¬') mv WHERE LOWER(LTRIM(RTRIM(ISNULL(e.Status,'')))) = LOWER(LTRIM(RTRIM(mv.value))))";
        var searchWhere = string.IsNullOrWhiteSpace(filter.SearchText) ? string.Empty : " AND (e.ClaimId LIKE @Search OR ISNULL(e.TaskId,'') LIKE @Search OR ISNULL(e.CptCode,'') LIKE @Search OR ISNULL(e.EscalationReason,'') LIKE @Search OR ISNULL(e.Comments,'') LIKE @Search OR ISNULL(e.CreatedBy,'') LIKE @Search)";
        var responseWhere = string.Equals(filter.TaskView, "response", StringComparison.OrdinalIgnoreCase)
            ? " AND (LOWER(LTRIM(RTRIM(ISNULL(e.Status,'')))) IN ('in review','responded','response submitted','manager response','writeoffapproved','writeoffrejected') OR ISNULL(e.Comments,'') LIKE '%Manager Response:%' OR ISNULL(e.Comments,'') LIKE '%Client Response:%' OR ISNULL(e.Comments,'') LIKE '%Account Manager Response:%')"
            : string.Empty;
        var escalationLabScope = LabScopeSql("e.LabId");
        var taskLabScope = LabScopeSql("t.LabId");
        var sql = $@"
SELECT COUNT_BIG(1)
FROM dbo.DenialClaimEscalations e WITH (NOLOCK)
WHERE e.IsDeleted=0 AND {escalationLabScope} AND e.EscalationLevel=@Level {statusWhere} {searchWhere} {responseWhere};

SELECT
    e.EscalationId,e.LabId,e.ClaimId,TaskId=ISNULL(e.TaskId,''),CptCode=ISNULL(e.CptCode,''),e.EscalationLevel,e.EscalationReason,e.Comments,e.Status,EscalatedTo=ISNULL(e.EscalatedTo,''),EscalatedToRole=ISNULL(e.EscalatedToRole,''),e.NextFollowUpDate,e.CreatedBy,e.CreatedOn,
    Analyst = e.CreatedBy,
    LabName = ISNULL(tb.LabName,''),
    Source = ISNULL(tb.Source,''),
    PayerName = ISNULL(tb.PayerName,''),
    PanelName = ISNULL(tb.PanelName,''),
    PatientName = ISNULL(tb.PatName,''),
    PatientId = ISNULL(tb.PatientId,''),
    SubscriberId = ISNULL(tb.SubscriberId,''),
    ClinicName = ISNULL(tb.ClinicName,''),
    ReferringProvider = ISNULL(tb.ReferringProvider,''),
    DateOfService = tb.DateOfService,
    ActionCategory = ISNULL(tb.ActionCategory,''),
    DenialClassification = ISNULL(tb.DenialClassification,''),
    DenialCode = ISNULL(tb.DenialCode,''),
    DenialDescription = ISNULL(tb.DenialDescription,''),
    InsuranceBalance = ISNULL(tb.InsuranceBalance,0),
    SlaStatus = ISNULL(tb.SLAStatus,''),
    DaysRemaining = tb.DaysRemaining,
    DueDate = tb.DueDate,
    AssignedTo = ISNULL(tb.AssignedTo,'')
FROM dbo.DenialClaimEscalations e WITH (NOLOCK)
OUTER APPLY
(
    SELECT TOP (1) t.*
    FROM dbo.DenialTaskBoard t WITH (NOLOCK)
    WHERE (LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))) = LTRIM(RTRIM(ISNULL(e.ClaimId,'')))
           OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) = LTRIM(RTRIM(ISNULL(e.ClaimId,'')))
           OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) LIKE '%' + LTRIM(RTRIM(ISNULL(e.ClaimId,''))))
      AND {taskLabScope}
      AND (@Level='Claim' OR ISNULL(e.TaskId,'')='' OR ISNULL(t.TaskID,'')=ISNULL(e.TaskId,''))
      AND (@Level='Claim' OR ISNULL(e.CptCode,'')='' OR ISNULL(t.CPTCode,'')=ISNULL(e.CptCode,''))
    ORDER BY CASE WHEN ISNULL(e.TaskId,'')<>'' AND ISNULL(t.TaskID,'')=ISNULL(e.TaskId,'') THEN 0 ELSE 1 END, t.TaskID
) tb
WHERE e.IsDeleted=0 AND {escalationLabScope} AND e.EscalationLevel=@Level {statusWhere} {searchWhere} {responseWhere}
ORDER BY CASE WHEN LOWER(ISNULL(e.Status,'')) IN ('resolved','closed','approved','returned for rework') THEN 1 ELSE 0 END, e.CreatedOn DESC, e.EscalationId DESC
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;";

        var result = new PagedResult<DenialEscalationQueueRow> { Page = filter.Page, PageSize = filter.PageSize };
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        AddLabScopeParams(cmd, filter.LabId);
        cmd.Parameters.AddWithValue("@Level", level);
        cmd.Parameters.AddWithValue("@Status", filter.Status?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@Search", "%" + (filter.SearchText?.Trim() ?? string.Empty) + "%");
        AddPagingParams(cmd, filter);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (await rd.ReadAsync(ct)) result.TotalCount = rd[0] == DBNull.Value ? 0 : Convert.ToInt32(rd[0]);
        if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) result.Items.Add(ReadEscalationQueue(rd));
        return result;
    }

    public async Task<int> ResolveEscalationAsync(ResolveDenialEscalationRequest request, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(request.LabId, ct);
        await using var con = OpenLab(request.LabId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        var escalationColumns = await GetColumnSetAsync(con, "dbo.DenialClaimEscalations", ct);
        var action = (request.ResolutionAction ?? string.Empty).Trim().ToLowerInvariant();
        var nextEscStatus = action switch
        {
            "approve" => "Resolved",
            "writeoff" => "Resolved",
            "approvewriteoff" => "WriteOffApproved",
            "rejectwriteoff" => "WriteOffRejected",
            "rework" => "Response Submitted",
            "others" => "Response Submitted",
            _ => "Response Submitted"
        };
        var nextTaskStatus = action switch
        {
            "approve" => "Closed",
            "writeoff" => "Closed",
            "approvewriteoff" => "WriteOffApproved",
            "rejectwriteoff" => "WriteOffRejected",
            "rework" => "Rework",
            "others" => "Rework",
            _ => "Rework"
        };
        var level = string.Equals(request.EscalationLevel, "Line", StringComparison.OrdinalIgnoreCase) ? "Line" : "Claim";
        var note = request.ResponseNote.Trim();
        var recommendedNextAction = request.RecommendedNextAction?.Trim() ?? string.Empty;
        var responseDetail = string.IsNullOrWhiteSpace(recommendedNextAction)
            ? note
            : $"{note}{Environment.NewLine}Recommended Next Action: {recommendedNextAction}";
        var actionBy = string.IsNullOrWhiteSpace(request.ActionBy) ? "ReactWorkflow" : request.ActionBy.Trim();
        var reassignTo = request.ReassignTo?.Trim() ?? string.Empty;
        var escalationRecommendationSet = escalationColumns.Contains("RecommendedNextAction")
            ? ", RecommendedNextAction=@RecommendedNextAction"
            : string.Empty;

        var sql = $@"
DECLARE @TargetClaimId nvarchar(150), @TargetTaskId nvarchar(100), @TargetCptCode nvarchar(100), @OriginalReviewer nvarchar(256);
SELECT @TargetClaimId=ClaimId, @TargetTaskId=ISNULL(TaskId,''), @TargetCptCode=ISNULL(CptCode,''), @OriginalReviewer=ISNULL(CreatedBy,'')
FROM dbo.DenialClaimEscalations WITH (UPDLOCK, ROWLOCK)
WHERE IsDeleted=0 AND LabId=@LabId AND EscalationId=@EscalationId;

IF @ResolutionAction IN ('approvewriteoff','rejectwriteoff')
   AND NULLIF(LTRIM(RTRIM(ISNULL(@OriginalReviewer,''))),'') IS NOT NULL
BEGIN
    SET @ReassignTo = @OriginalReviewer;
END

IF NULLIF(LTRIM(RTRIM(ISNULL(@ReassignTo,''))),'') IS NULL
   AND NULLIF(LTRIM(RTRIM(ISNULL(@OriginalReviewer,''))),'') IS NOT NULL
   AND @TaskStatus NOT IN ('Closed','Completed')
BEGIN
    SET @ReassignTo = @OriginalReviewer;
END

UPDATE dbo.DenialClaimEscalations
SET Status=@EscalationStatus, Comments = CONCAT(ISNULL(Comments,''), CHAR(13)+CHAR(10), 'Manager Response: ', @ResponseDetail){escalationRecommendationSet}
WHERE IsDeleted=0 AND LabId=@LabId AND EscalationId=@EscalationId;

DECLARE @Changed TABLE(TaskID nvarchar(100), UniqueTrackId nvarchar(100), ClaimId nvarchar(150), LabId int, RunId nvarchar(100), OldStatus nvarchar(100), NewStatus nvarchar(100), OldAssignedTo nvarchar(256), NewAssignedTo nvarchar(256));

UPDATE t
SET Status=@TaskStatus,
    RecommendedAction = CASE WHEN NULLIF(LTRIM(RTRIM(@RecommendedNextAction)),'') IS NULL THEN t.RecommendedAction ELSE @RecommendedNextAction END,
    AssignedTo = CASE WHEN @ReassignTo<>'' THEN @ReassignTo WHEN @ResolutionAction='rework' THEN '' ELSE t.AssignedTo END,
    WorkFlowStatus = CASE WHEN @TaskStatus IN ('Closed','Completed') THEN 'Closed Claim' WHEN @TaskStatus IN ('WriteOffApproved','WriteOffRejected') THEN @TaskStatus ELSE 'Response Escalation' END,
    ReviewerComments = CONCAT(ISNULL(NULLIF(t.ReviewerComments,''),''), CASE WHEN NULLIF(t.ReviewerComments,'') IS NULL THEN '' ELSE CHAR(13)+CHAR(10) END, 'Manager Response: ', @ResponseDetail),
    ReviewerUpdatedBy=@ActionBy,
    ReviewerUpdatedOn=SYSDATETIME(),
    DateCompleted = CASE WHEN @TaskStatus IN ('Closed','Completed') THEN CONVERT(date, GETDATE()) ELSE DateCompleted END
OUTPUT INSERTED.TaskID, INSERTED.UniqueTrackId, CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(INSERTED.ClaimID,''))), 'CLM-', '')), ISNULL(INSERTED.LabId,@LabId), INSERTED.RunId, DELETED.Status, INSERTED.Status, DELETED.AssignedTo, INSERTED.AssignedTo
INTO @Changed(TaskID,UniqueTrackId,ClaimId,LabId,RunId,OldStatus,NewStatus,OldAssignedTo,NewAssignedTo)
FROM dbo.DenialTaskBoard t
WHERE (LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))) = LTRIM(RTRIM(ISNULL(@TargetClaimId,'')))
       OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) = LTRIM(RTRIM(ISNULL(@TargetClaimId,'')))
       OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) LIKE '%' + LTRIM(RTRIM(ISNULL(@TargetClaimId,''))))
  AND (@Level='Claim' OR @TargetTaskId='' OR ISNULL(t.TaskID,'')=@TargetTaskId)
  AND (@Level='Claim' OR @TargetCptCode='' OR ISNULL(t.CPTCode,'')=@TargetCptCode);

DECLARE @TaskRows int = @@ROWCOUNT;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    UPDATE l
    SET AssignedTo = CASE WHEN @ReassignTo<>'' THEN @ReassignTo WHEN @ResolutionAction='rework' THEN '' ELSE l.AssignedTo END,
        WorkFlowStatus = CASE WHEN @TaskStatus IN ('Closed','Completed') THEN 'Closed Claim' WHEN @TaskStatus IN ('WriteOffApproved','WriteOffRejected') THEN @TaskStatus ELSE 'Response Escalation' END
    FROM dbo.DenialLineItem l
    JOIN (SELECT DISTINCT ClaimId FROM @Changed) c
      ON CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))=c.ClaimId;
END;

IF @TaskStatus IN ('Closed','Completed')
BEGIN
    ;WITH ClosedClaim AS
    (
        SELECT
            LabId = @LabId,
            ClaimId = c.ClaimId,
            PayerName = MAX(LTRIM(RTRIM(ISNULL(l.PayerName,'')))),
            PanelName = MAX(LTRIM(RTRIM(ISNULL(l.PanelName,'')))),
            PatientName = CAST('' AS nvarchar(255)),
            PatientDOB = MAX(l.PatientDOB),
            PatientId = MAX(LTRIM(RTRIM(ISNULL(l.PatientID,'')))),
            SubscriberId = CAST('' AS nvarchar(100)),
            ClinicName = MAX(LTRIM(RTRIM(ISNULL(l.ClinicName,'')))),
            SalesRepname = MAX(LTRIM(RTRIM(ISNULL(l.SalesRepname,'')))),
            ReferringProvider = MAX(LTRIM(RTRIM(ISNULL(l.ReferringProvider,'')))),
            DateOfService = MAX(l.DateOfService),
            AssignedTo = MAX(NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'')),
            TaskCount = COUNT(DISTINCT t.TaskID),
            InsuranceBalance = SUM(ISNULL(l.InsuranceBalance,0))
        FROM (SELECT DISTINCT ClaimId FROM @Changed) c
        LEFT JOIN dbo.DenialLineItem l ON CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', ''))=c.ClaimId
        LEFT JOIN dbo.DenialTaskBoard t ON CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(t.ClaimID,''))), 'CLM-', ''))=c.ClaimId
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.DenialTaskBoard openTask
            WHERE CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(openTask.ClaimID,''))), 'CLM-', ''))=c.ClaimId
              AND LOWER(LTRIM(RTRIM(ISNULL(openTask.Status,'')))) NOT IN ('closed','completed')
        )
        GROUP BY c.ClaimId
    )
    MERGE dbo.DenialClosedClaims AS target
    USING ClosedClaim AS source
       ON target.LabId=source.LabId AND target.ClaimId=source.ClaimId
    WHEN MATCHED THEN UPDATE SET
        PayerName=source.PayerName, PanelName=source.PanelName, PatientName=source.PatientName, PatientDOB=source.PatientDOB,
        PatientId=source.PatientId, SubscriberId=source.SubscriberId, ClinicName=source.ClinicName, SalesRepname=source.SalesRepname,
        ReferringProvider=source.ReferringProvider, DateOfService=source.DateOfService, AssignedTo=source.AssignedTo,
        Status='Closed', WorkFlowStatus='Closed Claim', TaskCount=source.TaskCount, InsuranceBalance=source.InsuranceBalance,
        ClosedBy=@ActionBy, LastUpdatedOn=SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT(LabId,ClaimId,PayerName,PanelName,PatientName,PatientDOB,PatientId,SubscriberId,ClinicName,SalesRepname,ReferringProvider,DateOfService,AssignedTo,Status,WorkFlowStatus,TaskCount,InsuranceBalance,ClosedBy)
        VALUES(source.LabId,source.ClaimId,source.PayerName,source.PanelName,source.PatientName,source.PatientDOB,source.PatientId,source.SubscriberId,source.ClinicName,source.SalesRepname,source.ReferringProvider,source.DateOfService,source.AssignedTo,'Closed','Closed Claim',source.TaskCount,source.InsuranceBalance,@ActionBy);

    INSERT INTO dbo.DenialClosedClaimsHistory(ClosedClaimId,LabId,ClaimId,ActionType,OldWorkFlowStatus,NewWorkFlowStatus,OldAssignedTo,NewAssignedTo,Comments,ActionBy)
    SELECT dc.ClosedClaimId,@LabId,c.ClaimId,'ClosedByEscalationResponse','Response Escalation','Closed Claim',c.OldAssignedTo,c.NewAssignedTo,@ResponseDetail,@ActionBy
    FROM @Changed c
    JOIN dbo.DenialClosedClaims dc ON dc.LabId=@LabId AND dc.ClaimId=c.ClaimId;
END;

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
BEGIN
    INSERT INTO dbo.DenialTaskHistory(TaskID,UniqueTrackId,LabId,RunId,ActionType,OldStatus,NewStatus,OldAssignedTo,NewAssignedTo,Comments,ActionBy,ActionDate,SnapshotJson)
    SELECT ISNULL(TaskID,''),ISNULL(UniqueTrackId,''),ISNULL(LabId,@LabId),ISNULL(RunId,''),CASE WHEN @ResolutionAction IN ('approvewriteoff','rejectwriteoff') THEN 'WriteOffDecision' ELSE 'ManagerEscalationResponse' END,ISNULL(OldStatus,''),ISNULL(NewStatus,''),ISNULL(OldAssignedTo,''),ISNULL(NewAssignedTo,''),@ResponseDetail,@ActionBy,SYSDATETIME(),''
    FROM @Changed;
END

SELECT @TaskRows;";
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        cmd.Parameters.AddWithValue("@LabId", request.LabId);
        cmd.Parameters.AddWithValue("@EscalationId", request.EscalationId);
        cmd.Parameters.AddWithValue("@EscalationStatus", nextEscStatus);
        cmd.Parameters.AddWithValue("@TaskStatus", nextTaskStatus);
        cmd.Parameters.AddWithValue("@ResolutionAction", action);
        cmd.Parameters.AddWithValue("@ResponseNote", note);
        cmd.Parameters.AddWithValue("@ResponseDetail", responseDetail);
        cmd.Parameters.AddWithValue("@RecommendedNextAction", recommendedNextAction);
        cmd.Parameters.AddWithValue("@ActionBy", actionBy);
        cmd.Parameters.AddWithValue("@ReassignTo", reassignTo);
        cmd.Parameters.AddWithValue("@Level", level);
        var scalar = await cmd.ExecuteScalarAsync(ct);
        return scalar == DBNull.Value || scalar is null ? 0 : Convert.ToInt32(scalar);
    }

    public async Task<int> UpdateEscalationAsync(UpdateDenialEscalationRequest request, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(request.LabId, ct);
        await using var con = OpenLab(request.LabId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);

        var level = string.Equals(request.EscalationLevel, "Line", StringComparison.OrdinalIgnoreCase) ? "Line" : "Claim";
        var actionBy = string.IsNullOrWhiteSpace(request.ActionBy) ? "ReactWorkflow" : request.ActionBy.Trim();
        var reason = request.EscalationReason.Trim();
        var comments = request.Comments?.Trim() ?? string.Empty;
        var status = string.IsNullOrWhiteSpace(request.Status) ? "Open" : request.Status.Trim();
        var escalatedTo = request.EscalatedTo?.Trim() ?? string.Empty;
        var escalatedToRole = request.EscalatedToRole?.Trim() ?? string.Empty;
        var isExternalEscalation =
            escalatedToRole.Contains("ClientManager", StringComparison.OrdinalIgnoreCase) ||
            escalatedToRole.Contains("AccountManager", StringComparison.OrdinalIgnoreCase) ||
            escalatedToRole.Contains("Client Manager", StringComparison.OrdinalIgnoreCase) ||
            escalatedToRole.Contains("Account Manager", StringComparison.OrdinalIgnoreCase);
        var taskEscalationStatus = isExternalEscalation ? "External Escalation" : "Internal Escalation";
        var escalationAssignee = isExternalEscalation ? escalatedTo : string.Empty;
        var updateComment = comments.Length > 0 ? $"Escalation Update: {comments}" : $"Escalation Update: {reason}";

        const string sql = @"
DECLARE @Rows int = 0;
DECLARE @TargetClaimId nvarchar(150), @TargetTaskId nvarchar(100), @TargetCptCode nvarchar(100);

UPDATE dbo.DenialClaimEscalations
SET EscalationReason=@EscalationReason,
    Comments = CONCAT(ISNULL(NULLIF(Comments,''),''), CASE WHEN NULLIF(Comments,'') IS NULL THEN '' ELSE CHAR(13)+CHAR(10) END, @UpdateComment),
    Status=@Status,
    EscalatedTo=@EscalatedTo,
    EscalatedToRole=@EscalatedToRole,
    NextFollowUpDate=@NextFollowUpDate
WHERE IsDeleted=0 AND LabId=@LabId AND EscalationId=@EscalationId;

SET @Rows = @@ROWCOUNT;

SELECT @TargetClaimId=ClaimId, @TargetTaskId=ISNULL(TaskId,''), @TargetCptCode=ISNULL(CptCode,'')
FROM dbo.DenialClaimEscalations WITH (NOLOCK)
WHERE IsDeleted=0 AND LabId=@LabId AND EscalationId=@EscalationId;

DECLARE @Changed TABLE
(
    TaskID nvarchar(100) NULL,
    UniqueTrackId nvarchar(100) NULL,
    LabId int NULL,
    RunId nvarchar(100) NULL,
    OldStatus nvarchar(100) NULL,
    NewStatus nvarchar(100) NULL,
    OldAssignedTo nvarchar(256) NULL,
    NewAssignedTo nvarchar(256) NULL
);

UPDATE t
SET Status = @TaskStatus,
    AssignedTo = CASE WHEN @EscalationAssignee <> '' THEN @EscalationAssignee ELSE t.AssignedTo END,
    WorkFlowStatus = CASE WHEN @TaskStatus='External Escalation' THEN 'External Escalation' ELSE 'Internal Escalation' END,
    ReviewerComments = CONCAT(ISNULL(NULLIF(t.ReviewerComments,''),''), CASE WHEN NULLIF(t.ReviewerComments,'') IS NULL THEN '' ELSE CHAR(13)+CHAR(10) END, @UpdateComment),
    ReviewerUpdatedBy = @ActionBy,
    ReviewerUpdatedOn = SYSDATETIME()
OUTPUT
    INSERTED.TaskID,
    INSERTED.UniqueTrackId,
    ISNULL(INSERTED.LabId, @LabId),
    INSERTED.RunId,
    DELETED.Status,
    INSERTED.Status,
    DELETED.AssignedTo,
    INSERTED.AssignedTo
INTO @Changed(TaskID, UniqueTrackId, LabId, RunId, OldStatus, NewStatus, OldAssignedTo, NewAssignedTo)
FROM dbo.DenialTaskBoard t
WHERE @Rows > 0
  AND (LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))) = LTRIM(RTRIM(ISNULL(@TargetClaimId,'')))
       OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) = LTRIM(RTRIM(ISNULL(@TargetClaimId,'')))
       OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) LIKE '%' + LTRIM(RTRIM(ISNULL(@TargetClaimId,''))))
  AND (@Level='Claim' OR @TargetTaskId='' OR ISNULL(t.TaskID,'')=@TargetTaskId)
  AND (@Level='Claim' OR @TargetCptCode='' OR ISNULL(t.CPTCode,'')=@TargetCptCode);

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    UPDATE l
    SET AssignedTo = CASE WHEN @EscalationAssignee <> '' THEN @EscalationAssignee ELSE l.AssignedTo END,
        WorkFlowStatus = CASE WHEN @TaskStatus='External Escalation' THEN 'External Escalation' ELSE 'Internal Escalation' END
    FROM dbo.DenialLineItem l
    WHERE CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')) = CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(@TargetClaimId,''))), 'CLM-', ''));
END;

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
BEGIN
    INSERT INTO dbo.DenialTaskHistory(TaskID,UniqueTrackId,LabId,RunId,ActionType,OldStatus,NewStatus,OldAssignedTo,NewAssignedTo,Comments,ActionBy,ActionDate,SnapshotJson)
    SELECT ISNULL(TaskID,''),ISNULL(UniqueTrackId,''),ISNULL(LabId,@LabId),ISNULL(RunId,''),'EscalationUpdate',ISNULL(OldStatus,''),ISNULL(NewStatus,''),ISNULL(OldAssignedTo,''),ISNULL(NewAssignedTo,''),@UpdateComment,@ActionBy,SYSDATETIME(),''
    FROM @Changed;
END

SELECT @Rows;";

        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 180 };
        cmd.Parameters.AddWithValue("@LabId", request.LabId);
        cmd.Parameters.AddWithValue("@EscalationId", request.EscalationId);
        cmd.Parameters.AddWithValue("@EscalationReason", reason);
        cmd.Parameters.AddWithValue("@UpdateComment", updateComment);
        cmd.Parameters.AddWithValue("@Status", status);
        cmd.Parameters.AddWithValue("@EscalatedTo", escalatedTo);
        cmd.Parameters.AddWithValue("@EscalatedToRole", escalatedToRole);
        cmd.Parameters.AddWithValue("@NextFollowUpDate", request.NextFollowUpDate.HasValue ? request.NextFollowUpDate.Value.Date : (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@ActionBy", actionBy);
        cmd.Parameters.AddWithValue("@TaskStatus", taskEscalationStatus);
        cmd.Parameters.AddWithValue("@EscalationAssignee", escalationAssignee);
        cmd.Parameters.AddWithValue("@Level", level);
        var scalar = await cmd.ExecuteScalarAsync(ct);
        return scalar == DBNull.Value || scalar is null ? 0 : Convert.ToInt32(scalar);
    }


    public async Task<DenialEscalationRow> SaveEscalationAsync(SaveDenialEscalationRequest request, CancellationToken ct)
    {
        await EnsureClaimSupportTablesAsync(request.LabId, ct);
        await using var con = OpenLab(request.LabId);
        await con.OpenAsync(ct);
        await EnsureDenialTaskBoardNormalizedClaimIdAsync(con, ct);
        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        var escalationColumns = await GetColumnSetAsync(con, "dbo.DenialClaimEscalations", ct);
        var insertColumns = new List<string> { "LabId", "ClaimId", "TaskId", "CptCode", "EscalationLevel", "EscalationReason", "Comments", "Status", "EscalatedTo", "EscalatedToRole", "NextFollowUpDate", "CreatedBy" };
        var insertValues = new List<string> { "@LabId", "@ClaimId", "@TaskId", "@CptCode", "@EscalationLevel", "@EscalationReason", "@Comments", "@Status", "@EscalatedTo", "@EscalatedToRole", "@NextFollowUpDate", "@CreatedBy" };
        void AddOptionalEscalationColumn(string column, string parameter)
        {
            if (!escalationColumns.Contains(column)) return;
            insertColumns.Add(column);
            insertValues.Add(parameter);
        }
        AddOptionalEscalationColumn("EscalationScope", "@EscalationScope");
        AddOptionalEscalationColumn("EscalationScopeValue", "@EscalationScopeValue");
        AddOptionalEscalationColumn("EscalationScopeDisplay", "@EscalationScopeDisplay");
        AddOptionalEscalationColumn("AffectedTaskIds", "@AffectedTaskIds");
        AddOptionalEscalationColumn("RecommendedNextAction", "@RecommendedNextAction");
        var insertSql = $@"
INSERT INTO dbo.DenialClaimEscalations({string.Join(",", insertColumns)})
OUTPUT INSERTED.EscalationId,INSERTED.LabId,INSERTED.ClaimId,INSERTED.TaskId,INSERTED.CptCode,INSERTED.EscalationLevel,INSERTED.EscalationReason,INSERTED.Comments,INSERTED.Status,INSERTED.EscalatedTo,INSERTED.EscalatedToRole,INSERTED.NextFollowUpDate,INSERTED.CreatedBy,INSERTED.CreatedOn
VALUES({string.Join(",", insertValues)});";
        var explicitEscalationAssignee = request.EscalatedTo?.Trim() ?? string.Empty;
        var explicitEscalationRole = request.EscalatedToRole?.Trim() ?? string.Empty;
        var isExternalEscalation =
            explicitEscalationRole.Contains("ClientManager", StringComparison.OrdinalIgnoreCase) ||
            explicitEscalationRole.Contains("AccountManager", StringComparison.OrdinalIgnoreCase) ||
            explicitEscalationRole.Contains("Client Manager", StringComparison.OrdinalIgnoreCase) ||
            explicitEscalationRole.Contains("Account Manager", StringComparison.OrdinalIgnoreCase);
        var taskEscalationStatus = isExternalEscalation ? "External Escalation" : "Internal Escalation";
        var escalationAssignee = isExternalEscalation ? explicitEscalationAssignee : string.Empty;

        await using var cmd = new SqlCommand(insertSql, con) { CommandTimeout = 120 };
        cmd.Parameters.AddWithValue("@LabId", request.LabId);
        cmd.Parameters.AddWithValue("@ClaimId", request.ClaimId.Trim());
        cmd.Parameters.AddWithValue("@TaskId", (object?)request.TaskId?.Trim() ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@CptCode", (object?)request.CptCode?.Trim() ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@EscalationLevel", string.Equals(request.EscalationLevel, "Line", StringComparison.OrdinalIgnoreCase) ? "Line" : "Claim");
        cmd.Parameters.AddWithValue("@EscalationReason", request.EscalationReason.Trim());
        cmd.Parameters.AddWithValue("@Comments", request.Comments?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@Status", string.IsNullOrWhiteSpace(request.Status) ? "Open" : request.Status.Trim());
        cmd.Parameters.AddWithValue("@EscalatedTo", explicitEscalationAssignee);
        cmd.Parameters.AddWithValue("@EscalatedToRole", explicitEscalationRole);
        cmd.Parameters.AddWithValue("@NextFollowUpDate", request.NextFollowUpDate.HasValue ? request.NextFollowUpDate.Value.Date : (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@CreatedBy", string.IsNullOrWhiteSpace(request.CreatedBy) ? "ReactWorkflow" : request.CreatedBy.Trim());
        cmd.Parameters.AddWithValue("@EscalationScope", string.IsNullOrWhiteSpace(request.EscalationScope) ? request.EscalationLevel : request.EscalationScope.Trim());
        cmd.Parameters.AddWithValue("@EscalationScopeValue", request.EscalationScopeValue?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@EscalationScopeDisplay", request.EscalationScopeDisplay?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@AffectedTaskIds", request.AffectedTaskIds?.Trim() ?? string.Empty);
        cmd.Parameters.AddWithValue("@RecommendedNextAction", request.RecommendedNextAction?.Trim() ?? string.Empty);

        DenialEscalationRow saved;
        await using (var rd = await cmd.ExecuteReaderAsync(ct))
        {
            if (!await rd.ReadAsync(ct))
                throw new InvalidOperationException("Unable to save escalation.");

            saved = ReadEscalation(rd);
        }

        const string updateTaskSql = @"
DECLARE @Changed TABLE
(
    TaskID nvarchar(100) NULL,
    UniqueTrackId nvarchar(100) NULL,
    LabId int NULL,
    RunId nvarchar(100) NULL,
    OldStatus nvarchar(100) NULL,
    NewStatus nvarchar(100) NULL,
    OldAssignedTo nvarchar(256) NULL,
    NewAssignedTo nvarchar(256) NULL
);

UPDATE t
SET Status = @TaskStatus,
    AssignedTo = CASE WHEN @EscalationAssignee <> '' THEN @EscalationAssignee ELSE t.AssignedTo END,
    WorkFlowStatus = CASE WHEN @TaskStatus='External Escalation' THEN 'External Escalation' ELSE 'Internal Escalation' END,
    ReviewerUpdatedBy = @CreatedBy,
    ReviewerUpdatedOn = SYSDATETIME()
OUTPUT
    INSERTED.TaskID,
    INSERTED.UniqueTrackId,
    ISNULL(INSERTED.LabId, @LabId),
    INSERTED.RunId,
    DELETED.Status,
    INSERTED.Status,
    DELETED.AssignedTo,
    INSERTED.AssignedTo
INTO @Changed(TaskID, UniqueTrackId, LabId, RunId, OldStatus, NewStatus, OldAssignedTo, NewAssignedTo)
FROM dbo.DenialTaskBoard t
WHERE (LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized,''))) = @ClaimId
       OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) = @ClaimId
       OR LTRIM(RTRIM(ISNULL(t.ClaimID,''))) LIKE '%' + @ClaimId)
  AND (@TaskId = '' OR ISNULL(t.TaskID,'') = @TaskId)
  AND (@CptCode = '' OR ISNULL(t.CPTCode,'') = @CptCode);

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    UPDATE l
    SET AssignedTo = CASE WHEN @EscalationAssignee <> '' THEN @EscalationAssignee ELSE l.AssignedTo END,
        WorkFlowStatus = CASE WHEN @TaskStatus='External Escalation' THEN 'External Escalation' ELSE 'Internal Escalation' END
    FROM dbo.DenialLineItem l
    WHERE CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(l.VisitNumber,''))), 'CLM-', '')) = CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(@ClaimId,''))), 'CLM-', ''));
END;

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
BEGIN
    INSERT INTO dbo.DenialTaskHistory
    (
        TaskID,
        UniqueTrackId,
        LabId,
        RunId,
        ActionType,
        OldStatus,
        NewStatus,
        OldAssignedTo,
        NewAssignedTo,
        Comments,
        ActionBy,
        ActionDate,
        SnapshotJson
    )
    SELECT
        ISNULL(TaskID,''),
        ISNULL(UniqueTrackId,''),
        ISNULL(LabId, @LabId),
        ISNULL(RunId,''),
        'Escalation',
        ISNULL(OldStatus,''),
        ISNULL(NewStatus,'Escalated'),
        ISNULL(OldAssignedTo,''),
        ISNULL(NewAssignedTo,''),
        @HistoryComments,
        @CreatedBy,
        SYSDATETIME(),
        ''
    FROM @Changed;
END;";

        await using var updateCmd = new SqlCommand(updateTaskSql, con) { CommandTimeout = 120 };
        updateCmd.Parameters.AddWithValue("@LabId", request.LabId);
        updateCmd.Parameters.AddWithValue("@ClaimId", request.ClaimId.Trim());
        updateCmd.Parameters.AddWithValue("@TaskId", request.TaskId?.Trim() ?? string.Empty);
        updateCmd.Parameters.AddWithValue("@CptCode", request.CptCode?.Trim() ?? string.Empty);
        updateCmd.Parameters.AddWithValue("@CreatedBy", string.IsNullOrWhiteSpace(request.CreatedBy) ? "ReactWorkflow" : request.CreatedBy.Trim());
        updateCmd.Parameters.AddWithValue("@EscalationAssignee", escalationAssignee);
        updateCmd.Parameters.AddWithValue("@TaskStatus", taskEscalationStatus);
        updateCmd.Parameters.AddWithValue("@HistoryComments", BuildEscalationHistoryComment(request));
        await ExecuteNonQueryWithDeadlockRetryAsync(updateCmd, ct);

        return saved;
    }

    private static async Task<int> ExecuteNonQueryWithDeadlockRetryAsync(SqlCommand cmd, CancellationToken ct)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await cmd.ExecuteNonQueryAsync(ct);
            }
            catch (SqlException ex) when (ex.Number == 1205 && attempt < 4)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(150 * attempt), ct);
            }
        }
    }



    private static bool IsClientInfoPendingEscalation(string? reason)
    {
        var value = (reason ?? string.Empty).Trim().ToLowerInvariant();
        return value.Contains("client info pending") || value.Contains("client information pending");
    }

    private async Task<string> ResolveClientManagerAssigneeAsync(int labId, CancellationToken ct)
    {
        try
        {
            await using var con = OpenMaster();
            await con.OpenAsync(ct);

            var userRoleColumns = await GetColumnSetAsync(con, "dbo.UserRoles", ct);
            var labUsersColumns = await GetColumnSetAsync(con, "dbo.LabUsers", ct);
            if (userRoleColumns.Count == 0 || labUsersColumns.Count == 0) return "Client Manager";

            var roleTable = await TableExistsAsync(con, "dbo.Roles", ct) ? "dbo.Roles" : await TableExistsAsync(con, "dbo.Role", ct) ? "dbo.Role" : string.Empty;
            var roleColumns = string.IsNullOrWhiteSpace(roleTable) ? new HashSet<string>(StringComparer.OrdinalIgnoreCase) : await GetColumnSetAsync(con, roleTable, ct);
            var roleNameColumn = new[] { "RoleName", "Name", "Role" }.FirstOrDefault(roleColumns.Contains);
            var roleIdColumn = new[] { "RoleID", "RoleId", "Id" }.FirstOrDefault(roleColumns.Contains);
            var userRoleIdColumn = new[] { "RoleID", "RoleId" }.FirstOrDefault(userRoleColumns.Contains);
            var userRoleUserIdColumn = new[] { "LabUserID", "LabUserId", "UserID", "UserId" }.FirstOrDefault(userRoleColumns.Contains) ?? "LabUserID";
            var labUserIdColumn = new[] { "LabUserID", "LabUserId", "UserID", "UserId" }.FirstOrDefault(labUsersColumns.Contains) ?? "LabUserID";
            var displayExpr = labUsersColumns.Contains("FirstName") || labUsersColumns.Contains("LastName")
                ? "NULLIF(LTRIM(RTRIM(CONCAT(ISNULL(lu.FirstName,''),' ',ISNULL(lu.LastName,'')))), '')"
                : "NULL";

            var labJoin = await TableExistsAsync(con, "dbo.UserLabs", ct)
                ? $"LEFT JOIN dbo.UserLabs ul ON lu.{labUserIdColumn}=ul.{labUserIdColumn}"
                : string.Empty;
            var labFilter = string.IsNullOrWhiteSpace(labJoin) ? string.Empty : "AND (@LabId <= 0 OR ul.LabId = @LabId)";

            var roleJoin = string.Empty;
            var roleFilter = string.Empty;
            if (!string.IsNullOrWhiteSpace(roleTable) && !string.IsNullOrWhiteSpace(roleNameColumn) && !string.IsNullOrWhiteSpace(roleIdColumn) && !string.IsNullOrWhiteSpace(userRoleIdColumn))
            {
                roleJoin = $"INNER JOIN {roleTable} r ON ur.{userRoleIdColumn}=r.{roleIdColumn}";
                roleFilter = $"AND UPPER(REPLACE(REPLACE(ISNULL(r.{roleNameColumn},''),' ',''),'-','')) = 'CLIENTMANAGER'";
            }
            else if (userRoleColumns.Contains("RoleName"))
            {
                roleFilter = "AND UPPER(REPLACE(REPLACE(ISNULL(ur.RoleName,''),' ',''),'-','')) = 'CLIENTMANAGER'";
            }
            else
            {
                return "Client Manager";
            }

            var sql = $@"
SELECT TOP (1)
	UserName = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(lu.UserName,''))), ''), {displayExpr}, 'Client Manager')
FROM dbo.LabUsers lu
INNER JOIN dbo.UserRoles ur ON lu.{labUserIdColumn}=ur.{userRoleUserIdColumn}
{roleJoin}
{labJoin}
WHERE 1=1
  {labFilter}
  {roleFilter}
ORDER BY UserName;";

            await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
            cmd.Parameters.AddWithValue("@LabId", labId);
            var value = Convert.ToString(await cmd.ExecuteScalarAsync(ct));
            return string.IsNullOrWhiteSpace(value) ? "Client Manager" : value.Trim();
        }
        catch
        {
            return "Client Manager";
        }
    }


    private static string BuildEscalationHistoryComment(SaveDenialEscalationRequest request)
    {
        var reason = request.EscalationReason?.Trim() ?? string.Empty;
        var comments = request.Comments?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(comments))
            return string.IsNullOrWhiteSpace(reason) ? "Task escalated." : $"Escalated: {reason}";

        if (string.IsNullOrWhiteSpace(reason))
            return comments;

        return $"Escalated: {reason} | {comments}";
    }

    private static string NormalizeWorkflowStatus(string? status)
    {
        var value = (status ?? string.Empty).Trim();
        return value.ToLowerInvariant() switch
        {
            "" or "open" or "in progress" or "in-progress" or "pending review" => "Assigned",
            "pending payer" => "Pending Payer Response",
            "escalated" or "internal escalation" or "external escalation" => "Escalated to AR Manager",
            "completed" => "Closed",
            "required review" or "returned for rework" => "Rework",
            _ => value
        };
    }

    private static string BuildWorkflowStatusSnapshot(UpdateTaskRequest request)
    {
        var parts = new List<string>
        {
            $"\"status\":\"{EscapeJson(request.Status)}\"",
            $"\"actionCompleted\":{(request.ActionCompleted.HasValue ? (request.ActionCompleted.Value ? "true" : "false") : "null")}",
            $"\"actualOutcome\":\"{EscapeJson(request.ActualOutcome)}\"",
            $"\"documentationType\":\"{EscapeJson(request.DocumentationType)}\"",
            $"\"followUpReason\":\"{EscapeJson(request.FollowUpReason)}\"",
            $"\"closureReason\":\"{EscapeJson(request.ClosureReason)}\"",
            $"\"syncConfirmation\":\"{EscapeJson(request.SyncConfirmation)}\"",
            $"\"validationStatus\":\"{EscapeJson(request.ValidationStatus)}\"",
            $"\"expectedResponseDate\":\"{(request.ExpectedResponseDate.HasValue ? request.ExpectedResponseDate.Value.ToString("yyyy-MM-dd") : string.Empty)}\"",
            $"\"updateScope\":\"{EscapeJson(request.UpdateScope)}\"",
            $"\"updateScopeValue\":\"{EscapeJson(request.UpdateScopeValue)}\""
        };
        return "{" + string.Join(",", parts) + "}";
    }

    private static string EscapeJson(string? value)
        => (value ?? string.Empty).Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal).Replace("\r", "\\r", StringComparison.Ordinal).Replace("\n", "\\n", StringComparison.Ordinal);


    private static string LabScopeSql(string labExpression)
        => $"({labExpression} = @LabId OR (@IncludeNorthWestPair = 1 AND {labExpression} IN (20, 23)))";

    private static string NullableLabScopeSql(string labExpression)
        => $"({labExpression} IS NULL OR {LabScopeSql(labExpression)})";

    private static bool IncludeNorthWestPair(int labId) => labId is 20 or 23;

    private static void AddLabScopeParams(SqlCommand cmd, int labId)
    {
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@IncludeNorthWestPair", IncludeNorthWestPair(labId));
    }

    private static void AddFilterParams(SqlCommand cmd, DenialWorkflowFilter f) => AddLabScopeParams(cmd, f.LabId);
    private static void AddExtraParams(SqlCommand cmd, Dictionary<string, object> ps) { foreach (var kv in ps) cmd.Parameters.AddWithValue(kv.Key, kv.Value); }
    private static void AddPagingParams(SqlCommand cmd, DenialWorkflowFilter f) { cmd.Parameters.AddWithValue("@Offset", (f.Page - 1) * f.PageSize); cmd.Parameters.AddWithValue("@PageSize", f.PageSize); }

    private static string BuildExportTaskViewWhere(string view)
    {
        var exLabScope = LabScopeSql("ex.LabId");
        var erLabScope = LabScopeSql("er.LabId");
        var eaLabScope = LabScopeSql("ea.LabId");
        return view switch
        {
            "new" => "AND NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NULL AND DATEDIFF(HOUR, ISNULL(t.CreatedOn, SYSDATETIME()), SYSDATETIME()) <= 48 AND LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) NOT IN ('closed','completed')",
            "unassigned" => "AND NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NULL AND DATEDIFF(HOUR, ISNULL(t.CreatedOn, SYSDATETIME()), SYSDATETIME()) > 48 AND LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) NOT IN ('closed','completed')",
            "assigned" => "AND NULLIF(LTRIM(RTRIM(ISNULL(t.AssignedTo,''))),'') IS NOT NULL AND LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) NOT IN ('closed','completed')",
            "closed" => "AND LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) IN ('closed','completed')",
            "internalescalation" => "AND LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) LIKE '%escal%' AND LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) <> 'external escalation'",
            "externalescalation" => $"AND (LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) = 'external escalation' OR EXISTS (SELECT 1 FROM dbo.DenialClaimEscalations ex WITH (NOLOCK) WHERE ex.IsDeleted=0 AND {exLabScope} AND ex.ClaimId IN (LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized, t.ClaimID))), LTRIM(RTRIM(ISNULL(t.ClaimID,'')))) AND (LOWER(ISNULL(ex.EscalatedToRole,'')) LIKE '%clientmanager%' OR LOWER(ISNULL(ex.EscalatedToRole,'')) LIKE '%accountmanager%')))",
            "escalationresponse" => $"AND EXISTS (SELECT 1 FROM dbo.DenialClaimEscalations er WITH (NOLOCK) WHERE er.IsDeleted=0 AND {erLabScope} AND er.ClaimId IN (LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized, t.ClaimID))), LTRIM(RTRIM(ISNULL(t.ClaimID,'')))) AND (LOWER(LTRIM(RTRIM(ISNULL(er.Status,'')))) IN ('in review','responded','response submitted','manager response','writeoffapproved','writeoffrejected') OR ISNULL(er.Comments,'') LIKE '%Manager Response:%' OR ISNULL(er.Comments,'') LIKE '%Client Response:%' OR ISNULL(er.Comments,'') LIKE '%Account Manager Response:%'))",
            "escalations" => $"AND (LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) LIKE '%escal%' OR EXISTS (SELECT 1 FROM dbo.DenialClaimEscalations ea WITH (NOLOCK) WHERE ea.IsDeleted=0 AND {eaLabScope} AND ea.ClaimId IN (LTRIM(RTRIM(ISNULL(t.ClaimIDNormalized, t.ClaimID))), LTRIM(RTRIM(ISNULL(t.ClaimID,''))))))",
            "verification" => "AND LOWER(LTRIM(RTRIM(ISNULL(t.Status,'')))) IN ('required review','verification pending')",
            _ => string.Empty
        };
    }

    private static async Task<int> WriteExcelXmlAsync(SqlDataReader rd, Stream output, CancellationToken ct)
    {
        await using var writer = new StreamWriter(output, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true), 64 * 1024, leaveOpen: true);
        await writer.WriteLineAsync("<?xml version=\"1.0\"?>");
        await writer.WriteLineAsync("<?mso-application progid=\"Excel.Sheet\"?>");
        await writer.WriteLineAsync("<Workbook xmlns=\"urn:schemas-microsoft-com:office:spreadsheet\" xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\">");
        await writer.WriteLineAsync("<Styles><Style ss:ID=\"Header\"><Font ss:Bold=\"1\"/><Interior ss:Color=\"#D9EAF7\" ss:Pattern=\"Solid\"/></Style></Styles>");

        var rowCount = 0;
        var sheetIndex = 1;
        var sheetOpen = false;
        var headers = Enumerable.Range(0, rd.FieldCount).Select(rd.GetName).ToArray();

        async Task StartSheetAsync()
        {
            if (sheetOpen)
            {
                await writer.WriteLineAsync("</Table></Worksheet>");
            }

            await writer.WriteLineAsync($"<Worksheet ss:Name=\"Claims {sheetIndex++}\"><Table>");
            await writer.WriteLineAsync("<Row>");
            foreach (var header in headers)
                await writer.WriteLineAsync($"<Cell ss:StyleID=\"Header\"><Data ss:Type=\"String\">{XmlEscape(header)}</Data></Cell>");
            await writer.WriteLineAsync("</Row>");
            sheetOpen = true;
        }

        await StartSheetAsync();
        while (await rd.ReadAsync(ct))
        {
            if (rowCount > 0 && rowCount % 1_000_000 == 0)
                await StartSheetAsync();

            await writer.WriteLineAsync("<Row>");
            for (var i = 0; i < rd.FieldCount; i++)
            {
                if (await rd.IsDBNullAsync(i, ct))
                {
                    await writer.WriteLineAsync("<Cell><Data ss:Type=\"String\"></Data></Cell>");
                    continue;
                }

                var value = rd.GetValue(i);
                var type = value is byte or short or int or long or float or double or decimal ? "Number" : "String";
                var text = value is DateTime dt ? dt.ToString("yyyy-MM-dd HH:mm:ss") : Convert.ToString(value) ?? string.Empty;
                await writer.WriteLineAsync($"<Cell><Data ss:Type=\"{type}\">{XmlEscape(text)}</Data></Cell>");
            }
            await writer.WriteLineAsync("</Row>");
            rowCount++;
        }

        if (sheetOpen) await writer.WriteLineAsync("</Table></Worksheet>");
        await writer.WriteLineAsync("</Workbook>");
        await writer.FlushAsync(ct);
        return rowCount;
    }

    private static async Task<int> WriteCsvAsync(SqlDataReader rd, Stream output, CancellationToken ct)
    {
        await using var writer = new StreamWriter(output, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true), 64 * 1024, leaveOpen: true);
        var headers = Enumerable.Range(0, rd.FieldCount).Select(rd.GetName);
        await writer.WriteLineAsync(string.Join(",", headers.Select(CsvEscape)));

        var rowCount = 0;
        while (await rd.ReadAsync(ct))
        {
            var values = new string[rd.FieldCount];
            for (var i = 0; i < rd.FieldCount; i++)
            {
                if (await rd.IsDBNullAsync(i, ct))
                {
                    values[i] = string.Empty;
                    continue;
                }

                var value = rd.GetValue(i);
                values[i] = value is DateTime dt
                    ? dt.ToString("yyyy-MM-dd HH:mm:ss")
                    : Convert.ToString(value) ?? string.Empty;
            }

            await writer.WriteLineAsync(string.Join(",", values.Select(CsvEscape)));
            rowCount++;
        }

        await writer.FlushAsync(ct);
        return rowCount;
    }

    private static void ResetOutputStream(Stream output)
    {
        if (!output.CanSeek) return;
        output.Position = 0;
        output.SetLength(0);
    }

    private static string CsvEscape(string value)
    {
        var clean = RemoveInvalidSpreadsheetChars(value ?? string.Empty);
        if (clean.Length > 0 && "=+-@".IndexOf(clean[0]) >= 0)
            clean = "'" + clean;
        return "\"" + clean.Replace("\"", "\"\"") + "\"";
    }

    private static string XmlEscape(string value)
        => RemoveInvalidSpreadsheetChars(value ?? string.Empty)
            .Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;")
            .Replace("\"", "&quot;")
            .Replace("'", "&apos;");

    private static string RemoveInvalidSpreadsheetChars(string value)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        var sb = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            if (ch == '\t' || ch == '\n' || ch == '\r' || ch >= ' ')
                sb.Append(ch);
        }
        return sb.ToString();
    }

    private static readonly string[] AgingBucketOrder = ["d0", "d30", "d60", "d90", "d120"];
    private static readonly IReadOnlyDictionary<string, string> AgingBucketLabels = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["d0"] = "0 - 30 Days",
        ["d30"] = "31 - 60 Days",
        ["d60"] = "61 - 90 Days",
        ["d90"] = "91 - 120 Days",
        ["d120"] = "120 Days+"
    };

    private sealed record AgingFlatRow(string Name, string SubTitle, string BucketKey, decimal Amount, int ClaimCount, int SlaBreaches);

    private static Dictionary<string, AgingBucketSummary> CreateEmptyAgingBuckets()
    {
        return AgingBucketOrder.ToDictionary(
            key => key,
            key => new AgingBucketSummary { Key = key, Label = AgingBucketLabels[key] },
            StringComparer.OrdinalIgnoreCase);
    }

    private static AgingFlatRow ReadAgingFlatRow(SqlDataReader rd) => new(
        GetString(rd, "Name"),
        GetString(rd, "SubTitle"),
        GetString(rd, "BucketKey"),
        GetDecimal(rd, "Amount"),
        GetInt(rd, "ClaimCount"),
        GetInt(rd, "SlaBreaches"));

    private static AgingListItem ReadAgingListItem(SqlDataReader rd) => new()
    {
        Name = GetString(rd, "Name"),
        SubTitle = GetString(rd, "SubTitle"),
        Amount = GetDecimal(rd, "Amount"),
        ClaimCount = GetInt(rd, "ClaimCount"),
        Status = GetString(rd, "Status"),
        DaysRemaining = GetInt(rd, "DaysRemaining")
    };

    private static IReadOnlyList<AgingMatrixRow> BuildAgingMatrixRows(IReadOnlyList<AgingFlatRow> rows, bool priorityUsesBreaches = false)
    {
        return rows
            .GroupBy(x => x.Name)
            .Select(g =>
            {
                var bucketMap = CreateEmptyAgingBuckets();
                foreach (var item in g)
                {
                    if (!bucketMap.TryGetValue(item.BucketKey, out var bucket)) continue;
                    bucket.Amount += item.Amount;
                    bucket.ClaimCount += item.ClaimCount;
                    bucket.SlaBreaches += item.SlaBreaches;
                }

                var totalAmount = bucketMap.Values.Sum(x => x.Amount);
                var totalClaims = bucketMap.Values.Sum(x => x.ClaimCount);
                var breaches = bucketMap.Values.Sum(x => x.SlaBreaches);
                var agedAmount = bucketMap["d60"].Amount + bucketMap["d90"].Amount + bucketMap["d120"].Amount;
                var priorityScore = priorityUsesBreaches
                    ? breaches
                    : totalAmount <= 0 ? 0 : Math.Clamp((int)Math.Round(((agedAmount / totalAmount) * 70m) + Math.Min(30m, breaches)), 0, 100);
                var priority = priorityScore >= 85 ? "critical" : priorityScore >= 65 ? "high" : priorityScore >= 40 ? "medium" : "low";
                return new AgingMatrixRow
                {
                    Name = string.IsNullOrWhiteSpace(g.Key) ? "Unclassified" : g.Key,
                    SubTitle = g.FirstOrDefault()?.SubTitle ?? string.Empty,
                    Priority = priority,
                    PriorityScore = priorityScore,
                    TotalAmount = totalAmount,
                    TotalClaims = totalClaims,
                    SlaBreaches = breaches,
                    Buckets = AgingBucketOrder.Select(key => bucketMap[key]).ToList()
                };
            })
            .OrderByDescending(x => x.PriorityScore)
            .ThenByDescending(x => x.TotalAmount)
            .ToList();
    }

    private static ClaimLevelRow ReadClaim(SqlDataReader rd) => new() { ClaimUid = GetString(rd, "ClaimUid"), ClaimId = GetString(rd, "ClaimId"), VisitNumber = GetString(rd, "VisitNumber"), AccessionNumber = GetString(rd, "AccessionNumber"), Source = GetString(rd, "Source"), PayerName = GetString(rd, "PayerName"), PanelName = GetString(rd, "PanelName"), PatientName = GetString(rd, "PatientName"), PatientDOB = GetDate(rd, "PatientDOB"), PatientId = GetString(rd, "PatientId"), SubscriberId = GetString(rd, "SubscriberId"), ClinicName = GetString(rd, "ClinicName"), SalesRepname = GetString(rd, "SalesRepname"), ReferringProvider = GetString(rd, "ReferringProvider"), DateOfService = GetDate(rd, "DateOfService"), AssignedTo = GetString(rd, "AssignedTo"), Status = GetString(rd, "Status"), ClaimStatus = GetString(rd, "ClaimStatus"), WorkflowStatus = GetString(rd, "WorkflowStatus"), QueueName = GetString(rd, "QueueName"), ClaimQueue = GetString(rd, "ClaimQueue"), TaskCount = GetInt(rd, "TaskCount"), CreatedOn = GetDate(rd, "CreatedOn"), InsuranceBalance = GetDecimal(rd, "InsuranceBalance") };

    private static DenialNoteRow ReadNote(SqlDataReader rd) => new() { NoteId = GetLong(rd, "NoteId"), LabId = GetInt(rd, "LabId"), ClaimId = GetString(rd, "ClaimId"), TaskId = GetString(rd, "TaskId"), CptCode = GetString(rd, "CptCode"), NoteLevel = GetString(rd, "NoteLevel"), NoteText = GetString(rd, "NoteText"), Status = GetString(rd, "Status"), NextFollowUpDate = GetDate(rd, "NextFollowUpDate"), CreatedBy = GetString(rd, "CreatedBy"), CreatedOn = GetDate(rd, "CreatedOn") ?? DateTime.MinValue };
    private static ClaimDocumentRow ReadDocument(SqlDataReader rd) => new() { DocumentId = GetLong(rd, "DocumentId"), LabId = GetInt(rd, "LabId"), ClaimId = GetString(rd, "ClaimId"), OriginalFileName = GetString(rd, "OriginalFileName"), StoredFileName = GetString(rd, "StoredFileName"), ContentType = GetString(rd, "ContentType"), FileSizeBytes = GetLong(rd, "FileSizeBytes"), FilePath = GetString(rd, "FilePath"), Comment = GetString(rd, "Comment"), UploadedBy = GetString(rd, "UploadedBy"), UploadedOn = GetDate(rd, "UploadedOn") ?? DateTime.MinValue };
    private static DenialEscalationRow ReadEscalation(SqlDataReader rd) => new() { EscalationId = GetLong(rd, "EscalationId"), LabId = GetInt(rd, "LabId"), ClaimId = GetString(rd, "ClaimId"), TaskId = GetString(rd, "TaskId"), CptCode = GetString(rd, "CptCode"), EscalationLevel = GetString(rd, "EscalationLevel"), EscalationReason = GetString(rd, "EscalationReason"), Comments = GetString(rd, "Comments"), Status = GetString(rd, "Status"), EscalatedTo = GetString(rd, "EscalatedTo"), EscalatedToRole = GetString(rd, "EscalatedToRole"), NextFollowUpDate = GetDate(rd, "NextFollowUpDate"), CreatedBy = GetString(rd, "CreatedBy"), CreatedOn = GetDate(rd, "CreatedOn") ?? DateTime.MinValue };

    private static DenialClaimHistoryRow ReadClaimHistory(SqlDataReader rd) => new()
    {
        HistoryId = GetLong(rd, "HistoryId"),
        HistoryType = GetString(rd, "HistoryType"),
        ClaimId = GetString(rd, "ClaimId"),
        TaskId = GetString(rd, "TaskId"),
        CptCode = GetString(rd, "CptCode"),
        ActionType = GetString(rd, "ActionType"),
        Title = GetString(rd, "Title"),
        Description = GetString(rd, "Description"),
        OldStatus = GetString(rd, "OldStatus"),
        NewStatus = GetString(rd, "NewStatus"),
        OldAssignedTo = GetString(rd, "OldAssignedTo"),
        NewAssignedTo = GetString(rd, "NewAssignedTo"),
        ActionBy = GetString(rd, "ActionBy"),
        ActionDate = GetDate(rd, "ActionDate"),
        CreatedBy = GetString(rd, "CreatedBy"),
        CreatedOn = GetDate(rd, "CreatedOn")
    };

    private static DenialEscalationQueueRow ReadEscalationQueue(SqlDataReader rd) => new()
    {
        EscalationId = GetLong(rd, "EscalationId"),
        LabId = GetInt(rd, "LabId"),
        ClaimId = GetString(rd, "ClaimId"),
        TaskId = GetString(rd, "TaskId"),
        CptCode = GetString(rd, "CptCode"),
        EscalationLevel = GetString(rd, "EscalationLevel"),
        EscalationReason = GetString(rd, "EscalationReason"),
        Comments = GetString(rd, "Comments"),
        Status = GetString(rd, "Status"),
        EscalatedTo = GetString(rd, "EscalatedTo"),
        EscalatedToRole = GetString(rd, "EscalatedToRole"),
        NextFollowUpDate = GetDate(rd, "NextFollowUpDate"),
        CreatedBy = GetString(rd, "CreatedBy"),
        CreatedOn = GetDate(rd, "CreatedOn") ?? DateTime.MinValue,
        Analyst = GetString(rd, "Analyst"),
        LabName = GetString(rd, "LabName"),
        Source = GetString(rd, "Source"),
        PayerName = GetString(rd, "PayerName"),
        PanelName = GetString(rd, "PanelName"),
        PatientName = GetString(rd, "PatientName"),
        PatientId = GetString(rd, "PatientId"),
        SubscriberId = GetString(rd, "SubscriberId"),
        ClinicName = GetString(rd, "ClinicName"),
        ReferringProvider = GetString(rd, "ReferringProvider"),
        DateOfService = GetDate(rd, "DateOfService"),
        ActionCategory = GetString(rd, "ActionCategory"),
        DenialClassification = GetString(rd, "DenialClassification"),
        DenialCode = GetString(rd, "DenialCode"),
        DenialDescription = GetString(rd, "DenialDescription"),
        InsuranceBalance = GetDecimal(rd, "InsuranceBalance"),
        SlaStatus = GetString(rd, "SlaStatus"),
        DaysRemaining = GetNullableInt(rd, "DaysRemaining"),
        DueDate = GetDate(rd, "DueDate"),
        AssignedTo = GetString(rd, "AssignedTo")
    };

    private static WorkflowTaskRow ReadTask(SqlDataReader rd) => new() { TaskId = GetString(rd, "TaskID"), UniqueTrackId = GetString(rd, "UniqueTrackId"), ClaimUid = GetString(rd, "ClaimUID"), ClaimId = GetString(rd, "ClaimID"), Source = GetString(rd, "Source"), PatientName = GetString(rd, "PatientName"), PatientId = GetString(rd, "PatientId"), SubscriberId = GetString(rd, "SubscriberId"), CptCode = GetString(rd, "CPTCode"), Units = GetNullableInt(rd, "Units"), Modifier = GetString(rd, "Modifier"), DenialCode = GetString(rd, "DenialCode"), DenialDescription = GetString(rd, "DenialDescription"), DenialClassification = GetString(rd, "DenialClassification"), ActionCode = GetString(rd, "ActionCode"), RecommendedAction = GetString(rd, "RecommendedAction"), ActionCategory = GetString(rd, "ActionCategory"), Task = GetString(rd, "Task"), Priority = GetString(rd, "Priority"), InsuranceBalance = GetDecimal(rd, "InsuranceBalance"), IsCurrentDenial = GetBool(rd, "IsCurrentDenial"), SlaDays = GetNullableInt(rd, "SLADays"), Status = GetString(rd, "Status"), DateOpened = GetDate(rd, "DateOpened"), DueDate = GetDate(rd, "DueDate"), DateCompleted = GetDate(rd, "DateCompleted"), DaysRemaining = GetNullableInt(rd, "DaysRemaining"), SlaStatus = GetString(rd, "SLAStatus"), AssignedTo = GetString(rd, "AssignedTo"), LabId = GetInt(rd, "LabId"), LabName = GetString(rd, "LabName"), RunId = GetString(rd, "RunId"), CreatedOn = GetDate(rd, "CreatedOn"), SalesRepname = GetString(rd, "SalesRepname"), ClinicName = GetString(rd, "ClinicName"), ReferringProvider = GetString(rd, "ReferringProvider"), PayerName = GetString(rd, "PayerName"), PayerNameNormalized = GetString(rd, "PayerNameNormalized"), PayerCode = GetNullableInt(rd, "PayerCode"), PayerType = GetString(rd, "PayerType"), FirstBilledDate = GetDate(rd, "FirstBilledDate"), ChargeEnteredDate = GetDate(rd, "ChargeEnteredDate"), BillingProvider = GetString(rd, "BillingProvider"), PanelName = GetString(rd, "PanelName"), DateOfService = GetDate(rd, "DateOfService"), ReviewerComments = GetString(rd, "ReviewerComments"), ReviewerUpdatedOn = GetDate(rd, "ReviewerUpdatedOn"), ReviewerUpdatedBy = GetString(rd, "ReviewerUpdatedBy"), ICDCodes = GetString(rd, "ICDCodes"), CoverageStatus = GetString(rd, "CoverageStatus"), ICDComplianceStatus = GetString(rd, "ICDComplianceStatus"), DenialValidity = GetString(rd, "DenialValidity") };
    private static VerificationTaskRow ReadVerification(SqlDataReader rd) { var t = ReadTask(rd); return new VerificationTaskRow { TaskId = t.TaskId, UniqueTrackId = t.UniqueTrackId, ClaimUid = t.ClaimUid, ClaimId = t.ClaimId, Source = t.Source, PatientName = t.PatientName, PatientId = t.PatientId, SubscriberId = t.SubscriberId, CptCode = t.CptCode, DenialCode = t.DenialCode, DenialDescription = t.DenialDescription, DenialClassification = t.DenialClassification, ActionCode = t.ActionCode, RecommendedAction = t.RecommendedAction, ActionCategory = t.ActionCategory, Task = t.Task, Priority = t.Priority, InsuranceBalance = t.InsuranceBalance, IsCurrentDenial = t.IsCurrentDenial, SlaDays = t.SlaDays, Status = t.Status, DateOpened = t.DateOpened, DueDate = t.DueDate, DateCompleted = t.DateCompleted, DaysRemaining = t.DaysRemaining, SlaStatus = t.SlaStatus, AssignedTo = t.AssignedTo, LabId = t.LabId, LabName = t.LabName, RunId = t.RunId, CreatedOn = t.CreatedOn, SalesRepname = t.SalesRepname, ClinicName = t.ClinicName, ReferringProvider = t.ReferringProvider, PayerName = t.PayerName, PayerNameNormalized = t.PayerNameNormalized, PayerCode = t.PayerCode, PayerType = t.PayerType, FirstBilledDate = t.FirstBilledDate, ChargeEnteredDate = t.ChargeEnteredDate, BillingProvider = t.BillingProvider, PanelName = t.PanelName, DateOfService = t.DateOfService, ReviewerComments = t.ReviewerComments, ReviewerUpdatedOn = t.ReviewerUpdatedOn, ReviewerUpdatedBy = t.ReviewerUpdatedBy, VerificationId = GetLong(rd, "VerificationId"), VerificationStatus = GetString(rd, "VerificationStatus"), VerificationComments = GetString(rd, "VerificationComments"), OriginalRunId = GetString(rd, "OriginalRunId"), MissingDetectedRunId = GetString(rd, "MissingDetectedRunId"), MovedOn = GetDate(rd, "MovedOn"), VerifiedBy = GetString(rd, "VerifiedBy"), VerifiedOn = GetDate(rd, "VerifiedOn") }; }
    private static DenialWorkflowInsightRow ReadInsight(SqlDataReader rd) => new() { DenialCodes = GetString(rd, "DenialCodes"), Descriptions = GetString(rd, "Descriptions"), NoOfDenialCount = GetInt(rd, "NoOfDenialCount"), NoOfClaimsCount = GetInt(rd, "NoOfClaimsCount"), TotalBalance = GetDecimal(rd, "TotalBalance"), HighImpactInsurance = GetString(rd, "HighImpactInsurance"), InsuranceBalance = GetDecimal(rd, "InsuranceBalance"), ImpactPercentage = GetDecimal(rd, "ImpactPercentage"), ActionCategory = GetString(rd, "ActionCategory"), ActionCode = GetString(rd, "ActionCode"), Action = GetString(rd, "Action"), Task = GetString(rd, "Task"), Feedback = GetString(rd, "Feedback"), Responsibility = GetString(rd, "Responsibility"), DiscussionDate = GetDate(rd, "DiscussionDate"), ETA = GetString(rd, "ETA"), LabName = GetString(rd, "LabName"), LabId = GetInt(rd, "LabId"), RunId = GetString(rd, "RunId"), CreatedOn = GetDate(rd, "CreatedOn"), AssignedTo = GetString(rd, "AssignedTo"), ResponsibilityReviewer = GetString(rd, "ResponsibilityReviewer") };
    private static void AddTaskParams(SqlCommand cmd, DenialTaskImportRow r, int labId, string labName, string runId, string taskId) { cmd.Parameters.AddWithValue("@TaskID", taskId); cmd.Parameters.AddWithValue("@LabId", labId); cmd.Parameters.AddWithValue("@LabName", labName); cmd.Parameters.AddWithValue("@RunId", runId); cmd.Parameters.AddWithValue("@UniqueTrackId", r.UniqueTrackId); cmd.Parameters.AddWithValue("@ClaimID", r.ClaimId); cmd.Parameters.AddWithValue("@PatientId", r.PatientId); cmd.Parameters.AddWithValue("@CPTCode", r.CptCode); cmd.Parameters.AddWithValue("@Units", (object?)r.Units ?? DBNull.Value); cmd.Parameters.AddWithValue("@Modifier", r.Modifier ?? string.Empty); cmd.Parameters.AddWithValue("@DenialCode", r.DenialCode); cmd.Parameters.AddWithValue("@DenialDescription", r.DenialDescription); cmd.Parameters.AddWithValue("@DenialClassification", r.DenialClassification); cmd.Parameters.AddWithValue("@ActionCode", r.ActionCode); cmd.Parameters.AddWithValue("@RecommendedAction", r.RecommendedAction); cmd.Parameters.AddWithValue("@ActionCategory", r.ActionCategory); cmd.Parameters.AddWithValue("@Task", r.Task); cmd.Parameters.AddWithValue("@Priority", r.Priority); cmd.Parameters.AddWithValue("@InsuranceBalance", r.InsuranceBalance); cmd.Parameters.AddWithValue("@SLADays", (object?)r.SlaDays ?? DBNull.Value); cmd.Parameters.AddWithValue("@DateOpened", (object?)r.DateOpened ?? DateTime.Today); cmd.Parameters.AddWithValue("@DueDate", (object?)r.DueDate ?? DBNull.Value); cmd.Parameters.AddWithValue("@SalesRepname", r.SalesRepname); cmd.Parameters.AddWithValue("@ClinicName", r.ClinicName); cmd.Parameters.AddWithValue("@ReferringProvider", r.ReferringProvider); cmd.Parameters.AddWithValue("@PayerName", r.PayerName); cmd.Parameters.AddWithValue("@PayerNameNormalized", r.PayerNameNormalized); cmd.Parameters.AddWithValue("@PayerCode", (object?)r.PayerCode ?? DBNull.Value); cmd.Parameters.AddWithValue("@PayerType", r.PayerType); cmd.Parameters.AddWithValue("@FirstBilledDate", (object?)r.FirstBilledDate ?? DBNull.Value); cmd.Parameters.AddWithValue("@ChargeEnteredDate", (object?)r.ChargeEnteredDate ?? DBNull.Value); cmd.Parameters.AddWithValue("@BillingProvider", r.BillingProvider); cmd.Parameters.AddWithValue("@PanelName", r.PanelName); cmd.Parameters.AddWithValue("@DateOfService", (object?)r.DateOfService ?? DBNull.Value); }
    private static async Task<IReadOnlyList<string>> ReadStringListAsync(SqlDataReader rd, CancellationToken ct)
    {
        var rows = new List<string>();
        while (await rd.ReadAsync(ct))
        {
            var value = GetString(rd, "Value");
            if (!string.IsNullOrWhiteSpace(value)) rows.Add(value);
        }
        return rows;
    }

    private static string NormalizeWorkflowRoleName(string? role)
    {
        var value = (role ?? string.Empty).Trim();
        var token = NormalizeRoleToken(value);
        return token switch
        {
            "CLIENTMANAGER" => "Client Manager",
            "ACCOUNTMANAGER" => "Account Manager",
            "ARANALYST" or "ARANALYSER" or "ARREVIEWER" => "AR Reviewer",
            _ when token.Contains("CLIENTMANAGER") => "Client Manager",
            _ when token.Contains("ACCOUNTMANAGER") => "Account Manager",
            _ when token.Contains("REVIEWER") || token.Contains("ANALYST") || token.Contains("ANALYSER") => "AR Reviewer",
            _ => string.IsNullOrWhiteSpace(value) ? "AR Reviewer" : value
        };
    }

    private static bool IsReviewerOnly(string? role)
    {
        var r = NormalizeRoleToken(role);
        return (r.Contains("ARREVIEWER") || r.Contains("ARANALYSER") || r.Contains("ARANALYZER") || r.Contains("REVIEWER"))
            && !r.Contains("MANAGER")
            && !r.Contains("ADMIN");
    }
    private static bool IsClientManagerRole(string? role) => NormalizeRoleToken(role).Contains("CLIENTMANAGER");
    private static string NormalizeRoleToken(string? role) => new string((role ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
    private static string GetString(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToString(r[n]) ?? string.Empty : string.Empty;
    private static int GetInt(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToInt32(r[n]) : 0;
    private static int? GetNullableInt(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToInt32(r[n]) : null;
    private static long GetLong(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToInt64(r[n]) : 0L;
    private static decimal GetDecimal(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToDecimal(r[n]) : 0m;
    private static bool GetBool(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value && Convert.ToBoolean(r[n]);
    private static DateTime? GetDate(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToDateTime(r[n]) : null;
    private static async Task<bool> TableExistsAsync(SqlConnection con, string tableName, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("SELECT CASE WHEN OBJECT_ID(@TableName) IS NULL THEN 0 ELSE 1 END", con);
        cmd.Parameters.AddWithValue("@TableName", tableName);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    private static async Task<HashSet<string>> GetColumnSetAsync(SqlConnection con, string tableName, CancellationToken ct)
    {
        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using var cmd = new SqlCommand(@"
SELECT c.name
FROM sys.columns c
WHERE c.object_id = OBJECT_ID(@TableName);", con);
        cmd.Parameters.AddWithValue("@TableName", tableName);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct))
            columns.Add(Convert.ToString(rd[0]) ?? string.Empty);
        return columns;
    }

    private static async Task<bool> HasColumnAsync(SqlConnection con, string tableName, string columnName, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("SELECT CASE WHEN COL_LENGTH(@TableName, @ColumnName) IS NULL THEN 0 ELSE 1 END", con);
        cmd.Parameters.AddWithValue("@TableName", tableName);
        cmd.Parameters.AddWithValue("@ColumnName", columnName);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct)) == 1;
    }

    private static bool HasColumn(IDataRecord r, string n) { for (var i = 0; i < r.FieldCount; i++) if (string.Equals(r.GetName(i), n, StringComparison.OrdinalIgnoreCase)) return true; return false; }
}

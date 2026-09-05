using System.Collections.Concurrent;
using System.Data;
using System.Text.Json;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services.ArReports;

/// <summary>
/// RPT-01 - AR Follow-up Activity Detail.
///
/// THE ACTIVITY SPINE
/// There is no single activity table. A qualifying activity is recorded in one of three places, so
/// the report unions them and gives each event a source-prefixed id, because the three tables have
/// independent identity sequences and a bare id would collide:
///
///   H:{HistoryId}     dbo.DenialTaskHistory      assignment, status update, manager response,
///                                                write-off decision, closure
///   N:{NoteId}        dbo.DenialClaimNotes       work notes, follow-up scheduling
///   E:{EscalationId}  dbo.DenialClaimEscalations escalations raised
///
/// DenialTaskHistory rows with ActionType='Escalation' are deliberately EXCLUDED: raising one
/// escalation writes one DenialClaimEscalations row and one history row PER AFFECTED TASK, so
/// counting the history rows would inflate "escalations raised" on any multi-line claim. The
/// escalation record is also the only place the reason, recipient and EscalationId actually live.
///
/// WHAT THIS REPORT IS NOT (spec section 2)
/// The due status on a row is the status of the follow-up date THAT ACTIVITY captured, evaluated
/// against the as-of date - an audit snapshot, not current backlog. Current overdue workload is
/// RPT-05's job and must come from the latest open workflow record. Nothing here should be read as
/// a current-inventory figure.
///
/// SCHEMA DRIFT
/// Labs migrate one at a time, so every optional column is probed through sys.columns before it is
/// referenced. A lab missing a column gets a documented fallback value rather than a failed report.
/// </summary>
public sealed class SqlArActivityReportRepository : IArActivityReportRepository
{
    private const string ReportCode = "RPT-01";
    private const string ReportName = "AR Follow-up Activity Detail";

    /// <summary>Default "Due Soon" window. Configuration decision left open by spec section 7; one place to change it.</summary>
    private const int DueSoonDays = 3;

    /// <summary>Hard ceiling on the activity window. A wider range is a data extract, not a screen.</summary>
    private const int MaxRangeDays = 366;

    /// <summary>
    /// Ceiling on a single Excel export. Well under the worksheet row limit, and beyond this an
    /// export belongs in the background job queue rather than on a request thread.
    /// </summary>
    internal const int MaxExportRows = 100_000;

    private const string MultiSelectDelimiter = "¬";

    private static readonly ConcurrentDictionary<int, byte> SchemaReady = new();
    private static readonly ConcurrentDictionary<int, SemaphoreSlim> SchemaLocks = new();
    private static readonly ConcurrentDictionary<string, (DateTime CachedOnUtc, IReadOnlyList<ArAnalystOrg> Rows)> OrgCache = new();
    private static readonly TimeSpan OrgCacheDuration = TimeSpan.FromMinutes(10);
    private static readonly ConcurrentDictionary<int, (DateTime CachedOnUtc, ArActivityFilterOptions Options)> OptionsCache = new();
    private static readonly TimeSpan OptionsCacheDuration = TimeSpan.FromMinutes(10);
    private static readonly ConcurrentDictionary<string, HashSet<string>> ColumnSetCache = new(StringComparer.OrdinalIgnoreCase);

    private readonly IDenialWorkflowRepository _workflowRepository;
    private readonly string _masterConnectionString;
    private readonly IReadOnlyDictionary<int, string> _labNamesById;
    private readonly IReadOnlyDictionary<int, string> _labConnectionsById;

    public SqlArActivityReportRepository(IConfiguration configuration, IDenialWorkflowRepository workflowRepository)
    {
        _workflowRepository = workflowRepository;
        _masterConnectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");

        var labItems = configuration.GetSection("LabConfig:LabsID").Get<List<ArLabConfigItem>>() ?? [];

        _labNamesById = labItems
            .Where(x => x.Id > 0 && x.IsActive && !string.IsNullOrWhiteSpace(x.Name))
            .GroupBy(x => x.Id)
            .ToDictionary(g => g.Key, g => g.First().Name.Trim());

        _labConnectionsById = labItems
            .Where(x => x.Id > 0 && x.IsActive)
            .GroupBy(x => x.Id)
            .ToDictionary(g => g.Key, g => LabConnectionResolver.Resolve(configuration, g.First().Id, g.First().Name, g.First().ConnectionKey));
    }

    private sealed class ArLabConfigItem
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public string ConnectionKey { get; set; } = string.Empty;
        public bool IsActive { get; set; } = true;
    }

    private SqlConnection OpenMaster() => new(_masterConnectionString);

    private SqlConnection OpenLab(int labId)
    {
        if (labId <= 0) throw new InvalidOperationException("LabId is required.");
        if (_labConnectionsById.TryGetValue(labId, out var conn) && !string.IsNullOrWhiteSpace(conn))
            return new SqlConnection(conn);
        throw new InvalidOperationException($"No lab database connection string is configured for LabId {labId}. Add LabConfig:LabsID and a matching ConnectionStrings entry.");
    }

    // NorthWest is stored across two lab ids (20/23) and every existing workflow query scopes the
    // same way. RPT-01 has to match, or its totals will not reconcile with the screens it audits.
    private static string LabScopeSql(string labExpression)
        => $"({labExpression} = @LabId OR (@IncludeNorthWestPair = 1 AND {labExpression} IN (20, 23)))";

    private static bool IncludeNorthWestPair(int labId) => labId is 20 or 23;

    private static void AddLabScopeParams(SqlCommand cmd, int labId)
    {
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@IncludeNorthWestPair", IncludeNorthWestPair(labId));
    }

    /// <summary>
    /// The normalized claim key. DenialTaskBoard / DenialClaimNotes carry it as a persisted computed
    /// column on migrated labs; where it is absent the same expression is inlined so the report
    /// still runs (unindexed, but correct).
    /// </summary>
    private static string ClaimKeyExpr(HashSet<string> columns, string alias, string normalizedName, string rawName)
        => columns.Contains(normalizedName)
            ? $"{alias}.{normalizedName}"
            : $"CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL({alias}.{rawName},''))),'CLM-',''))";

    // ==================================================================================
    // Schema
    // ==================================================================================

    public async Task EnsureReportObjectsAsync(int labId, CancellationToken ct)
    {
        if (SchemaReady.ContainsKey(labId)) return;

        // The activity spine reads DenialClaimNotes / DenialClaimEscalations and the Schema Pass A
        // configuration tables, all of which the workflow repository owns. Let it create them
        // first rather than re-declaring the same DDL in two places and letting the two drift.
        await _workflowRepository.EnsureClaimSupportTablesAsync(labId, ct);

        var gate = SchemaLocks.GetOrAdd(labId, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(ct);
        try
        {
            if (SchemaReady.ContainsKey(labId)) return;

            await using var con = OpenLab(labId);
            await con.OpenAsync(ct);

            // Batch 1: columns, tables, indexes. Every ALTER adds a nullable column (or a bit with a
            // default), so all of them are metadata-only - no rewrite of DenialTaskHistory.
            await using (var cmd = new SqlCommand(SchemaBatchColumnsAndTables, con) { CommandTimeout = 180 })
                await cmd.ExecuteNonQueryAsync(ct);

            // Batch 2 is separate because it reads columns of a table batch 1 may have just created.
            await using (var cmd = new SqlCommand(SchemaBatchCatalogSeed, con) { CommandTimeout = 120 })
                await cmd.ExecuteNonQueryAsync(ct);

            SchemaReady[labId] = 1;
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// Mirrors Sql/ArReports/RPT01_ActivityDetail_Setup.sql sections 1-6. The script carries the
    /// full rationale for each object and is the DBA-runnable form; this copy exists so the report
    /// works on a lab where the script has not been applied yet.
    /// </summary>
    internal const string SchemaBatchColumnsAndTables = @"
SET NOCOUNT ON;

IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimNotes','ContactMethod') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD ContactMethod nvarchar(60) NULL;
    IF COL_LENGTH('dbo.DenialClaimNotes','FollowUpCategory') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD FollowUpCategory nvarchar(80) NULL;
    IF COL_LENGTH('dbo.DenialClaimNotes','BalanceSnapshot') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD BalanceSnapshot decimal(18,2) NULL;
    IF COL_LENGTH('dbo.DenialClaimNotes','IsInternalOnly') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD IsInternalOnly bit NOT NULL CONSTRAINT DF_DenialClaimNotes_IsInternalOnly DEFAULT 0;
END;

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskHistory','ContactMethod') IS NULL
        ALTER TABLE dbo.DenialTaskHistory ADD ContactMethod nvarchar(60) NULL;
    IF COL_LENGTH('dbo.DenialTaskHistory','BalanceSnapshot') IS NULL
        ALTER TABLE dbo.DenialTaskHistory ADD BalanceSnapshot decimal(18,2) NULL;
END;

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimEscalations','UpdateSource') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD UpdateSource nvarchar(20) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','UploadBatchId') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD UploadBatchId nvarchar(100) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','BalanceSnapshot') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD BalanceSnapshot decimal(18,2) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','ClaimIdNormalized') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations
            ADD ClaimIdNormalized AS CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))),'CLM-','')) PERSISTED;
END;

-- Date-ranged reads of the three event tables. None of them was indexed on (LabId, event date):
-- they are indexed for per-claim reads, so a 90-day report scanned all three end to end.
IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskHistory_Lab_ActionDate' AND object_id=OBJECT_ID('dbo.DenialTaskHistory'))
BEGIN
    BEGIN TRY
        EXEC sys.sp_executesql N'CREATE NONCLUSTERED INDEX IX_DenialTaskHistory_Lab_ActionDate ON dbo.DenialTaskHistory (LabId, ActionDate DESC) INCLUDE (HistoryId, TaskID, UniqueTrackId, ActionType, OldStatus, NewStatus, OldAssignedTo, NewAssignedTo, ActionBy);';
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (1911,1913,2714) THROW;
    END CATCH
END;

IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialClaimNotes_Lab_CreatedOn' AND object_id=OBJECT_ID('dbo.DenialClaimNotes'))
BEGIN
    BEGIN TRY
        EXEC sys.sp_executesql N'CREATE NONCLUSTERED INDEX IX_DenialClaimNotes_Lab_CreatedOn ON dbo.DenialClaimNotes (LabId, CreatedOn DESC) INCLUDE (NoteId, ClaimId, TaskId, CptCode, NoteLevel, Status, NextFollowUpDate, CreatedBy, IsDeleted);';
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (1911,1913,2714) THROW;
    END CATCH
END;

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_DenialClaimEscalations_Lab_CreatedOn' AND object_id=OBJECT_ID('dbo.DenialClaimEscalations'))
BEGIN
    BEGIN TRY
        EXEC sys.sp_executesql N'CREATE NONCLUSTERED INDEX IX_DenialClaimEscalations_Lab_CreatedOn ON dbo.DenialClaimEscalations (LabId, CreatedOn DESC) INCLUDE (EscalationId, ClaimId, TaskId, CptCode, EscalationLevel, EscalationReason, EscalatedTo, Status, CreatedBy, IsDeleted);';
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (1911,1913,2714) THROW;
    END CATCH
END;

IF OBJECT_ID('dbo.DenialActivityContactMethod','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialActivityContactMethod
    (
        ContactMethodId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialActivityContactMethod PRIMARY KEY,
        MethodName nvarchar(60) NOT NULL,
        SortOrder int NOT NULL CONSTRAINT DF_DenialActivityContactMethod_Sort DEFAULT 100,
        IsActive bit NOT NULL CONSTRAINT DF_DenialActivityContactMethod_Active DEFAULT 1,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialActivityContactMethod_CreatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialActivityContactMethod_Name ON dbo.DenialActivityContactMethod (MethodName);
    INSERT INTO dbo.DenialActivityContactMethod (MethodName, SortOrder) VALUES
        ('Payer Portal',10),('Phone',20),('Fax',30),('Email',40),('Mail / Letter',50),
        ('Clearinghouse',60),('Application',70),('Batch Import',80),('System',90),('Not Recorded',100);
END;

IF OBJECT_ID('dbo.DenialFollowUpCategoryMaster','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialFollowUpCategoryMaster
    (
        FollowUpCategoryId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialFollowUpCategoryMaster PRIMARY KEY,
        CategoryName nvarchar(80) NOT NULL,
        ComplianceGroup nvarchar(40) NOT NULL CONSTRAINT DF_DenialFollowUpCategoryMaster_Group DEFAULT 'Payer',
        SortOrder int NOT NULL CONSTRAINT DF_DenialFollowUpCategoryMaster_Sort DEFAULT 100,
        IsActive bit NOT NULL CONSTRAINT DF_DenialFollowUpCategoryMaster_Active DEFAULT 1,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialFollowUpCategoryMaster_CreatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialFollowUpCategoryMaster_Name ON dbo.DenialFollowUpCategoryMaster (CategoryName);
    INSERT INTO dbo.DenialFollowUpCategoryMaster (CategoryName, ComplianceGroup, SortOrder) VALUES
        ('Payer Follow-up','Payer',10),('Appeal Follow-up','Payer',20),('Rebill Follow-up','Payer',30),
        ('Documentation Follow-up','Documentation',40),('Escalation Response','Escalation',50),
        ('Write-off Approval','Escalation',60),('Closure Verification','Payer',70);
END;

IF OBJECT_ID('dbo.DenialActionCompletionEvent','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialActionCompletionEvent
    (
        ActionCompletionEventId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialActionCompletionEvent PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        TaskId nvarchar(100) NULL,
        UniqueTrackId nvarchar(450) NULL,
        CptCode nvarchar(50) NULL,
        ActionCategory nvarchar(500) NULL,
        [Task] nvarchar(500) NULL,
        CompletedDateLabel nvarchar(80) NULL,
        IsCompleted bit NOT NULL CONSTRAINT DF_DenialActionCompletionEvent_IsCompleted DEFAULT 1,
        CompletedBy nvarchar(256) NULL,
        CompletedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialActionCompletionEvent_CompletedOn DEFAULT SYSUTCDATETIME(),
        CompletionNote nvarchar(max) NULL,
        StatusAtCompletion nvarchar(100) NULL,
        BalanceSnapshot decimal(18,2) NULL,
        UpdateSource nvarchar(20) NULL,
        UploadBatchId nvarchar(100) NULL,
        RunId nvarchar(100) NULL,
        AmendsCompletionEventId bigint NULL,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialActionCompletionEvent_CreatedOn DEFAULT SYSUTCDATETIME(),
        ClaimIdNormalized AS CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(ClaimId,''))),'CLM-','')) PERSISTED
    );
    CREATE INDEX IX_DenialActionCompletionEvent_Lab_CompletedOn ON dbo.DenialActionCompletionEvent (LabId, CompletedOn DESC) INCLUDE (ClaimId, TaskId, CptCode, ActionCategory, CompletedBy, IsCompleted);
    CREATE INDEX IX_DenialActionCompletionEvent_Lab_Task ON dbo.DenialActionCompletionEvent (LabId, TaskId, CompletedOn DESC);
END;

IF OBJECT_ID('dbo.DenialReportRunLog','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialReportRunLog
    (
        ReportRunLogId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialReportRunLog PRIMARY KEY,
        RunId nvarchar(60) NOT NULL,
        ReportCode nvarchar(20) NOT NULL,
        LabId int NOT NULL,
        GeneratedBy nvarchar(256) NOT NULL,
        GeneratedByRole nvarchar(100) NULL,
        GeneratedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialReportRunLog_GeneratedOn DEFAULT SYSUTCDATETIME(),
        AsOfOn datetime2(0) NULL,
        OutputType nvarchar(20) NOT NULL CONSTRAINT DF_DenialReportRunLog_OutputType DEFAULT 'Screen',
        AppliedFilters nvarchar(max) NULL,
        RowCountTotal int NOT NULL CONSTRAINT DF_DenialReportRunLog_RowCount DEFAULT 0,
        DurationMs int NOT NULL CONSTRAINT DF_DenialReportRunLog_DurationMs DEFAULT 0
    );
    CREATE INDEX IX_DenialReportRunLog_Report_GeneratedOn ON dbo.DenialReportRunLog (ReportCode, LabId, GeneratedOn DESC);
END;

IF OBJECT_ID('dbo.DenialReportSavedView','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialReportSavedView
    (
        SavedViewId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialReportSavedView PRIMARY KEY,
        ReportCode nvarchar(20) NOT NULL,
        LabId int NOT NULL,
        OwnerUserName nvarchar(256) NOT NULL,
        ViewName nvarchar(120) NOT NULL,
        FiltersJson nvarchar(max) NOT NULL,
        IsDefault bit NOT NULL CONSTRAINT DF_DenialReportSavedView_IsDefault DEFAULT 0,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialReportSavedView_CreatedOn DEFAULT SYSUTCDATETIME(),
        UpdatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialReportSavedView_UpdatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialReportSavedView_Owner_Name ON dbo.DenialReportSavedView (ReportCode, LabId, OwnerUserName, ViewName);
END;

IF OBJECT_ID('dbo.DenialReportCatalog','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialReportCatalog
    (
        ReportCatalogId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialReportCatalog PRIMARY KEY,
        ReportCode nvarchar(20) NOT NULL,
        ReportName nvarchar(160) NOT NULL,
        [Grain] nvarchar(120) NULL,
        Purpose nvarchar(500) NULL,
        [Status] nvarchar(20) NOT NULL CONSTRAINT DF_DenialReportCatalog_Status DEFAULT 'Inactive'
            CONSTRAINT CK_DenialReportCatalog_Status CHECK ([Status] IN ('Active','Inactive','Blocked')),
        StatusNote nvarchar(400) NULL,
        RouteKey nvarchar(60) NULL,
        SortOrder int NOT NULL CONSTRAINT DF_DenialReportCatalog_Sort DEFAULT 100,
        UpdatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialReportCatalog_UpdatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialReportCatalog_Code ON dbo.DenialReportCatalog (ReportCode);
END;
";

    /// <summary>
    /// Seeds the report catalog. Status/StatusNote are only set on INSERT: once AR operations
    /// flips a report Active or Inactive for a lab, a redeploy must not silently undo it.
    /// </summary>
    internal const string SchemaBatchCatalogSeed = @"
SET NOCOUNT ON;
MERGE dbo.DenialReportCatalog AS target
USING (VALUES
    ('RPT-01','AR Follow-up Activity Detail','One row per qualifying activity event','Auditable record of every meaningful follow-up activity performed on a claim or denial line item.','Active','Live. Claim and denial-line grain, Latest Activity Only, Excel export with reconciliation totals.','rpt01',10),
    ('RPT-02','AR Analyst Productivity Summary','One row per analyst per reporting period','Analyst output, workflow progression and action completion without rewarding repeated notes.','Inactive','Planned. Opening/closing workload needs the inventory snapshot job to have accrued history.','rpt02',20),
    ('RPT-03','AR Analyst Workload and Capacity','One row per analyst as of the selected date','Whether denial workload is distributed appropriately, and who carries stale or complex backlogs.','Inactive','Planned. Current-state only; the Capacity column group is an optional MVP enhancement.','rpt03',30),
    ('RPT-04','Action Completion','One row per completed action or task event','When appeals, rebills, write-offs, documentation submissions and payer follow-ups were completed.','Blocked','Blocked until action completion events accrue. RPT-01 reads dbo.DenialActionCompletionEvent.','rpt04',40),
    ('RPT-05','Follow-up Due and Compliance','One row per follow-up schedule instance','The daily AR control plan, and whether follow-ups are completed on time.','Inactive','Planned. Needs follow-up schedule history and completion linkage.','rpt05',50),
    ('RPT-06','Denial Work Progress by Classification/Action','Aggregated by dimension and reporting bucket','Movement of denial inventory through Open, Active, Pending, Escalated and Closed buckets.','Inactive','Planned. Movement measures need point-in-time inventory snapshots.','rpt06',60),
    ('RPT-07','Escalation Response and Rework','One row per escalation cycle','Clarification delays, manager response, escalation aging and work returned for rework.','Inactive','Planned. Needs response-to-escalation linkage; re-escalation makes timestamp inference unsafe.','rpt07',70),
    ('RPT-08','Closure and Outcome','One row per closed claim or denial line','How completed follow-up work ended, separating operational closure from verified financial outcome.','Inactive','Planned. Operational half is buildable now; verified financial measures await adjudication data.','rpt08',80),
    ('RPT-09','Operational SLA','One row per SLA measurement instance','Whether key workflow milestones complete within configurable operational service-level targets.','Blocked','Blocked on versioned SLA configuration and per-item measurement instances.','rpt09',90)
) AS source (ReportCode, ReportName, [Grain], Purpose, [Status], StatusNote, RouteKey, SortOrder)
    ON target.ReportCode = source.ReportCode
WHEN MATCHED THEN UPDATE SET
    target.ReportName = source.ReportName,
    target.[Grain]    = source.[Grain],
    target.Purpose    = source.Purpose,
    target.RouteKey   = source.RouteKey,
    target.SortOrder  = source.SortOrder,
    target.UpdatedOn  = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (ReportCode, ReportName, [Grain], Purpose, [Status], StatusNote, RouteKey, SortOrder)
    VALUES (source.ReportCode, source.ReportName, source.[Grain], source.Purpose, source.[Status], source.StatusNote, source.RouteKey, source.SortOrder);
";

    // ==================================================================================
    // Catalog
    // ==================================================================================

    public async Task<IReadOnlyList<ArReportCatalogItem>> GetCatalogAsync(int labId, CancellationToken ct)
    {
        await EnsureReportObjectsAsync(labId, ct);
        const string sql = @"
SELECT ReportCode, ReportName, [Grain], Purpose, [Status], StatusNote, RouteKey, SortOrder
FROM dbo.DenialReportCatalog WITH (NOLOCK)
ORDER BY SortOrder, ReportCode;";

        var rows = new List<ArReportCatalogItem>();
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct))
        {
            rows.Add(new ArReportCatalogItem
            {
                ReportCode = GetString(rd, "ReportCode"),
                ReportName = GetString(rd, "ReportName"),
                Grain = GetString(rd, "Grain"),
                Purpose = GetString(rd, "Purpose"),
                Status = GetString(rd, "Status"),
                StatusNote = GetString(rd, "StatusNote"),
                RouteKey = GetString(rd, "RouteKey"),
                SortOrder = GetInt(rd, "SortOrder")
            });
        }
        return rows;
    }

    // ==================================================================================
    // Filter options
    // ==================================================================================

    public async Task<ArActivityFilterOptions> GetFilterOptionsAsync(int labId, CancellationToken ct)
    {
        if (OptionsCache.TryGetValue(labId, out var cached) && DateTime.UtcNow - cached.CachedOnUtc < OptionsCacheDuration)
            return cached.Options;

        await EnsureReportObjectsAsync(labId, ct);

        // The workflow repository already caches these dropdowns for 15 minutes, and they are the
        // most expensive query in the estate (multiple GROUP BY scans over 300k+ row tables).
        // Reusing it means opening this report costs nothing extra once any workflow screen has
        // been visited.
        var shared = await _workflowRepository.GetFilterOptionsAsync(labId, ct);
        var org = await GetAnalystOrgAsync(ct);

        var tasks = new List<string>();
        var buckets = new List<string>();
        var agingBuckets = new List<string>();
        var contactMethods = new List<string>();
        var followUpCategories = new List<string>();
        var escalationStatuses = new List<string>();

        await using (var con = OpenLab(labId))
        {
            await con.OpenAsync(ct);

            // DenialTaskBoard.Task is not present on every lab yet, and this is a multi-result-set
            // batch: a conditional IF around the statement would shift every later result set by
            // one. Emit a typed empty result instead so the reader's sequence stays fixed.
            var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
            var taskListSql = taskColumns.Contains("Task")
                ? $@"
SELECT DISTINCT TOP (300) Value = LTRIM(RTRIM([Task]))
FROM dbo.DenialTaskBoard WITH (NOLOCK)
WHERE NULLIF(LTRIM(RTRIM(ISNULL([Task],''))),'') IS NOT NULL AND {LabScopeSql("LabId")}
ORDER BY Value;"
                : "SELECT Value = CAST('' AS nvarchar(500)) WHERE 1 = 0;";

            var sql = $@"
{taskListSql}

SELECT DISTINCT ReportingBucket FROM dbo.DenialStatusBucketMap WITH (NOLOCK) ORDER BY ReportingBucket;

SELECT BucketLabel FROM dbo.DenialAgingBucket WITH (NOLOCK) ORDER BY SortOrder;

SELECT MethodName FROM dbo.DenialActivityContactMethod WITH (NOLOCK) WHERE IsActive = 1 ORDER BY SortOrder, MethodName;

SELECT CategoryName FROM dbo.DenialFollowUpCategoryMaster WITH (NOLOCK) WHERE IsActive = 1 ORDER BY SortOrder, CategoryName;

SELECT DISTINCT TOP (50) Value = LTRIM(RTRIM([Status]))
FROM dbo.DenialClaimEscalations WITH (NOLOCK)
WHERE NULLIF(LTRIM(RTRIM(ISNULL([Status],''))),'') IS NOT NULL AND {LabScopeSql("LabId")}
ORDER BY Value;";

            await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
            AddLabScopeParams(cmd, labId);
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            while (await rd.ReadAsync(ct)) tasks.Add(GetString(rd, "Value"));
            if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) buckets.Add(GetString(rd, "ReportingBucket"));
            if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) agingBuckets.Add(GetString(rd, "BucketLabel"));
            if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) contactMethods.Add(GetString(rd, "MethodName"));
            if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) followUpCategories.Add(GetString(rd, "CategoryName"));
            if (await rd.NextResultAsync(ct)) while (await rd.ReadAsync(ct)) escalationStatuses.Add(GetString(rd, "Value"));
        }

        var options = new ArActivityFilterOptions
        {
            Analysts = shared.AssignedUsers.Where(x => !string.IsNullOrWhiteSpace(x)).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList(),
            Managers = org.Select(x => x.ManagerUserName).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList(),
            Teams = org.Select(x => x.TeamName).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList(),
            Payers = shared.PayerNames,
            DenialClassifications = shared.DenialClassifications,
            ActionCategories = shared.ActionCategories,
            Tasks = tasks,
            WorkflowStatuses = shared.Statuses,
            ReportingBuckets = buckets,
            AgingBuckets = agingBuckets,
            DueStatuses = DueStatusValues,
            EscalationStatuses = escalationStatuses.Count > 0 ? escalationStatuses : ["Open", "Responded", "Closed"],
            ActivityTypes = ActivityTypeValues,
            ContactMethods = contactMethods,
            FollowUpCategories = followUpCategories,
            UpdateSources = UpdateSourceValues
        };

        OptionsCache[labId] = (DateTime.UtcNow, options);
        return options;
    }

    private static readonly string[] DueStatusValues = ["Overdue", "Due Today", "Due Soon", "Future", "No Follow-up Date"];
    private static readonly string[] UpdateSourceValues = ["Application", "Excel Upload"];
    private static readonly string[] ActivityTypeValues =
    [
        "Work Note", "Status Update", "Assignment", "Escalation Raised", "Escalation Update",
        "Manager Response", "Write-off Decision", "Closure", "Workflow Event"
    ];

    // ==================================================================================
    // The report
    // ==================================================================================

    public async Task<ArActivityReportResult> GetActivityDetailAsync(ArActivityReportFilter filter, CancellationToken ct)
    {
        var started = DateTime.UtcNow;
        Normalize(filter);
        await EnsureReportObjectsAsync(filter.LabId, ct);

        var org = await GetAnalystOrgAsync(ct);
        var orgByUser = BuildOrgLookup(org);

        // GAP-2: the manager/team dimension lives in LRNMaster, the activity lives in the lab
        // database, and no cross-database join is available here. Resolving the manager filter to a
        // set of analyst user names BEFORE the query keeps paging correct - filtering afterwards
        // would silently return short pages.
        var analystScope = ResolveAnalystScope(filter, org);
        if (analystScope is { Count: 0 })
        {
            return new ArActivityReportResult
            {
                Metadata = await BuildMetadataAsync(filter, ct),
                EmptyStateReason = "No analyst is mapped to the selected manager or team. Manager and team come from the LRN Metrics user directory (LabUsers), not from the claim record."
            };
        }

        var result = new ArActivityReportResult { Metadata = await BuildMetadataAsync(filter, ct) };

        await using var con = OpenLab(filter.LabId);
        await con.OpenAsync(ct);

        var schema = new ArReportSchema(
            await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct),
            await GetColumnSetAsync(con, "dbo.DenialLineItem", ct),
            await GetColumnSetAsync(con, "dbo.DenialClaimNotes", ct),
            await GetColumnSetAsync(con, "dbo.DenialTaskHistory", ct),
            await GetColumnSetAsync(con, "dbo.DenialClaimEscalations", ct));

        var sql = BuildActivitySql(filter, schema, analystScope);

        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 240 };
        BindActivityParams(cmd, filter, analystScope);

        var rows = new List<ArActivityEventRow>();
        var summary = new ArActivitySummary();
        var groups = new List<ArActivityGroupRow>();
        var total = 0;

        await using (var rd = await cmd.ExecuteReaderAsync(ct))
        {
            while (await rd.ReadAsync(ct)) rows.Add(ReadEventRow(rd));

            if (await rd.NextResultAsync(ct) && await rd.ReadAsync(ct))
            {
                total = GetInt(rd, "TotalRows");
                summary.ActivityEvents = total;
                summary.DistinctClaimDaysWorked = GetInt(rd, "DistinctClaimDays");
                summary.DistinctLineDaysWorked = GetInt(rd, "DistinctLineDays");
                summary.DistinctClaimsWorked = GetInt(rd, "DistinctClaims");
                summary.DistinctLinesWorked = GetInt(rd, "DistinctLines");
                summary.DistinctAnalysts = GetInt(rd, "DistinctAnalysts");
                summary.EscalationsRaised = GetInt(rd, "EscalationsRaised");
                summary.NotesRecorded = GetInt(rd, "NotesRecorded");
                summary.StatusChanges = GetInt(rd, "StatusChanges");
                summary.ActionsCompleted = GetInt(rd, "ActionsCompleted");
                summary.ActionsCompletedFromEvents = GetInt(rd, "ActionsCompletedFromEvents");
                summary.RowsWithFallbackBalance = GetInt(rd, "RowsWithFallbackBalance");
            }

            // Balance worked comes back as its own aggregate: summing the per-row balance would
            // count the same claim balance once per note - the exact inflation spec section 3.1
            // calls out ("Do not sum the same balance for every note event").
            if (await rd.NextResultAsync(ct) && await rd.ReadAsync(ct))
                summary.BalanceWorked = GetDecimal(rd, "BalanceWorked");

            if (await rd.NextResultAsync(ct))
            {
                while (await rd.ReadAsync(ct))
                {
                    var key = GetString(rd, "GroupKey");
                    groups.Add(new ArActivityGroupRow
                    {
                        GroupKey = key,
                        GroupLabel = key,
                        ActivityEvents = GetInt(rd, "ActivityEvents"),
                        DistinctClaimDaysWorked = GetInt(rd, "DistinctClaimDays"),
                        DistinctLineDaysWorked = GetInt(rd, "DistinctLineDays"),
                        DistinctClaims = GetInt(rd, "DistinctClaims"),
                        ActionsCompleted = GetInt(rd, "ActionsCompleted"),
                        EscalationsRaised = GetInt(rd, "EscalationsRaised"),
                        BalanceWorked = GetDecimal(rd, "BalanceWorked")
                    });
                }
            }
        }

        ApplyOrgAndMasking(rows, orgByUser, result.Metadata.InternalNotesVisible);

        result.Summary = summary;
        result.Groups = groups;
        result.Detail = new PagedResult<ArActivityEventRow>
        {
            Items = rows,
            Page = filter.Page,
            PageSize = filter.PageSize,
            TotalCount = total
        };
        if (total == 0)
            result.EmptyStateReason = "No qualifying activity events matched the selected filters for this activity period.";

        var durationMs = (int)Math.Max(0, (DateTime.UtcNow - started).TotalMilliseconds);
        await LogRunAsync(result.Metadata, "Screen", total, durationMs, ct);
        return result;
    }

    /// <summary>
    /// Decorates rows with the manager/team dimension and enforces client-facing note masking.
    /// Masking keeps the ROW and blanks the text rather than dropping it, so the summary measures
    /// still reconcile to the visible detail count (FR-002) for every role.
    /// </summary>
    private static void ApplyOrgAndMasking(List<ArActivityEventRow> rows, Dictionary<string, ArAnalystOrg> orgByUser, bool internalNotesVisible)
    {
        foreach (var row in rows)
        {
            if (orgByUser.TryGetValue(row.AnalystName, out var analystOrg))
            {
                row.ManagerName = analystOrg.ManagerUserName;
                row.TeamName = analystOrg.TeamName;
            }

            if (!internalNotesVisible && row.NoteMasked)
            {
                row.NoteText = "Restricted - internal note";
                if (!string.IsNullOrWhiteSpace(row.EscalationReason)) row.EscalationReason = "Restricted";
            }
            else
            {
                row.NoteMasked = false;
            }
        }
    }

    private void BindActivityParams(SqlCommand cmd, ArActivityReportFilter filter, IReadOnlyCollection<string>? analystScope)
    {
        AddLabScopeParams(cmd, filter.LabId);
        cmd.Parameters.AddWithValue("@FromDate", filter.FromDate!.Value);
        cmd.Parameters.AddWithValue("@ToDateExclusive", filter.ToDate!.Value);
        cmd.Parameters.AddWithValue("@AsOf", filter.AsOf!.Value);
        cmd.Parameters.AddWithValue("@DueSoonDays", DueSoonDays);
        cmd.Parameters.AddWithValue("@Offset", (filter.Page - 1) * filter.PageSize);
        cmd.Parameters.AddWithValue("@PageSize", filter.PageSize);
        AddTextParam(cmd, "@Analyst", filter.Analyst);
        AddTextParam(cmd, "@Payer", filter.Payer);
        AddTextParam(cmd, "@DenialClassification", filter.DenialClassification);
        AddTextParam(cmd, "@ActionCategory", filter.ActionCategory);
        AddTextParam(cmd, "@TaskName", filter.Task);
        AddTextParam(cmd, "@WorkflowStatus", filter.WorkflowStatus);
        AddTextParam(cmd, "@ReportingBucket", filter.ReportingBucket);
        AddTextParam(cmd, "@AgingBucket", filter.AgingBucket);
        AddTextParam(cmd, "@DueStatus", filter.DueStatus);
        AddTextParam(cmd, "@EscalationStatus", filter.EscalationStatus);
        AddTextParam(cmd, "@ActivityType", filter.ActivityType);
        AddTextParam(cmd, "@ContactMethod", filter.ContactMethod);
        AddTextParam(cmd, "@UpdateSource", filter.UpdateSource);
        AddTextParam(cmd, "@SearchText", filter.SearchText);
        if (analystScope is { Count: > 0 })
            cmd.Parameters.AddWithValue("@AnalystScope", string.Join(MultiSelectDelimiter, analystScope));
    }

    public async Task<IReadOnlyList<ArActivityTimelineRow>> GetClaimTimelineAsync(ArActivityReportFilter filter, string claimId, CancellationToken ct)
    {
        await EnsureReportObjectsAsync(filter.LabId, ct);
        var claimKey = NormalizeClaimId(claimId);
        if (string.IsNullOrWhiteSpace(claimKey)) return Array.Empty<ArActivityTimelineRow>();

        await using var con = OpenLab(filter.LabId);
        await con.OpenAsync(ct);

        var taskColumns = await GetColumnSetAsync(con, "dbo.DenialTaskBoard", ct);
        var noteColumns = await GetColumnSetAsync(con, "dbo.DenialClaimNotes", ct);
        var historyColumns = await GetColumnSetAsync(con, "dbo.DenialTaskHistory", ct);
        var escalationColumns = await GetColumnSetAsync(con, "dbo.DenialClaimEscalations", ct);

        var noteInternal = noteColumns.Contains("IsInternalOnly") ? "ISNULL(n.IsInternalOnly,0)" : "CAST(0 AS bit)";
        var noteSource = noteColumns.Contains("UpdateSource") ? "ISNULL(n.UpdateSource,'UI')" : "CAST('UI' AS nvarchar(20))";
        var historySource = historyColumns.Contains("UpdateSource") ? "ISNULL(h.UpdateSource,'UI')" : "CAST('UI' AS nvarchar(20))";
        var escalationRole = escalationColumns.Contains("EscalatedToRole") ? "ISNULL(e.EscalatedToRole,'')" : "CAST('' AS nvarchar(100))";
        var noteClaimKey = ClaimKeyExpr(noteColumns, "n", "ClaimIdNormalized", "ClaimId");
        var taskClaimKey = ClaimKeyExpr(taskColumns, "t", "ClaimIDNormalized", "ClaimID");
        var escalationClaimKey = ClaimKeyExpr(escalationColumns, "e", "ClaimIdNormalized", "ClaimId");

        var sql = $@"
SELECT TOP (300) *
FROM (
    SELECT
        ActivityId     = 'N:' + CONVERT(varchar(20), n.NoteId),
        ActivityDate   = n.CreatedOn,
        ActivityType   = CAST('Work Note' AS nvarchar(60)),
        Author         = ISNULL(n.CreatedBy,''),
        LineItemId     = ISNULL(n.TaskId,''),
        CptCode        = ISNULL(n.CptCode,''),
        PreviousStatus = CAST('' AS nvarchar(100)),
        NewStatus      = ISNULL(n.[Status],''),
        NoteText       = CAST(ISNULL(n.NoteText,'') AS nvarchar(max)),
        IsInternalOnly = CONVERT(bit, {noteInternal}),
        UpdateSource   = CAST({noteSource} AS nvarchar(20)),
        RunId          = CAST('' AS nvarchar(100))
    FROM dbo.DenialClaimNotes n WITH (NOLOCK)
    WHERE {LabScopeSql("n.LabId")} AND n.IsDeleted = 0 AND {noteClaimKey} = @ClaimKey

    UNION ALL

    SELECT
        ActivityId     = 'H:' + CONVERT(varchar(20), h.HistoryId),
        ActivityDate   = h.ActionDate,
        ActivityType   = CAST({HistoryActivityTypeSql("h")} AS nvarchar(60)),
        Author         = ISNULL(h.ActionBy,''),
        LineItemId     = ISNULL(h.TaskID,''),
        CptCode        = ISNULL(t.CPTCode,''),
        PreviousStatus = ISNULL(h.OldStatus,''),
        NewStatus      = ISNULL(h.NewStatus,''),
        NoteText       = CAST(ISNULL(h.Comments,'') AS nvarchar(max)),
        IsInternalOnly = CONVERT(bit, 0),
        UpdateSource   = CAST({historySource} AS nvarchar(20)),
        RunId          = CAST(ISNULL(h.RunId,'') AS nvarchar(100))
    FROM dbo.DenialTaskHistory h WITH (NOLOCK)
    INNER JOIN dbo.DenialTaskBoard t WITH (NOLOCK)
        ON t.TaskID = h.TaskID AND {LabScopeSql("t.LabId")}
    WHERE {LabScopeSql("h.LabId")}
      AND {taskClaimKey} = @ClaimKey
      AND LOWER(LTRIM(RTRIM(ISNULL(h.ActionType,'')))) <> 'escalation'

    UNION ALL

    SELECT
        ActivityId     = 'E:' + CONVERT(varchar(20), e.EscalationId),
        ActivityDate   = e.CreatedOn,
        ActivityType   = CAST('Escalation Raised' AS nvarchar(60)),
        Author         = ISNULL(e.CreatedBy,''),
        LineItemId     = ISNULL(e.TaskId,''),
        CptCode        = ISNULL(e.CptCode,''),
        PreviousStatus = CAST('' AS nvarchar(100)),
        NewStatus      = ISNULL(e.[Status],''),
        NoteText       = CAST(CONCAT(ISNULL(e.EscalationReason,''), CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.Comments,''))),'') IS NULL THEN '' ELSE ' - ' + e.Comments END) AS nvarchar(max)),
        IsInternalOnly = CONVERT(bit, CASE WHEN {escalationRole} LIKE '%lient%' OR {escalationRole} LIKE '%ccount%' THEN 0 ELSE 1 END),
        UpdateSource   = CAST('UI' AS nvarchar(20)),
        RunId          = CAST('' AS nvarchar(100))
    FROM dbo.DenialClaimEscalations e WITH (NOLOCK)
    WHERE {LabScopeSql("e.LabId")} AND ISNULL(e.IsDeleted,0) = 0 AND {escalationClaimKey} = @ClaimKey
) x
ORDER BY x.ActivityDate DESC, x.ActivityId DESC;";

        var rows = new List<ArActivityTimelineRow>();
        var internalVisible = InternalNotesVisible(filter.Role);

        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 120 };
        AddLabScopeParams(cmd, filter.LabId);
        cmd.Parameters.AddWithValue("@ClaimKey", claimKey);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct))
        {
            var restricted = GetBool(rd, "IsInternalOnly") && !internalVisible;
            rows.Add(new ArActivityTimelineRow
            {
                ActivityId = GetString(rd, "ActivityId"),
                ActivityDate = GetDate(rd, "ActivityDate") ?? DateTime.MinValue,
                ActivityType = GetString(rd, "ActivityType"),
                Author = GetString(rd, "Author"),
                LineItemId = GetString(rd, "LineItemId"),
                CptCode = GetString(rd, "CptCode"),
                PreviousStatus = GetString(rd, "PreviousStatus"),
                NewStatus = GetString(rd, "NewStatus"),
                NoteText = restricted ? "Restricted - internal note" : GetString(rd, "NoteText"),
                NoteMasked = restricted,
                UpdateSource = NormalizeUpdateSource(GetString(rd, "UpdateSource")),
                RunId = GetString(rd, "RunId")
            });
        }
        return rows;
    }

    // ==================================================================================
    // SQL construction
    // ==================================================================================

    internal sealed record ArReportSchema(
        HashSet<string> Task,
        HashSet<string> Line,
        HashSet<string> Note,
        HashSet<string> History,
        HashSet<string> Escalation);

    private static string HistoryActivityTypeSql(string alias) => $@"CASE LOWER(LTRIM(RTRIM(ISNULL({alias}.ActionType,''))))
            WHEN 'assign' THEN 'Assignment'
            WHEN 'statusupdate' THEN 'Status Update'
            WHEN 'note' THEN 'Work Note'
            WHEN 'claimcomment' THEN 'Work Note'
            WHEN 'escalationupdate' THEN 'Escalation Update'
            WHEN 'managerescalationresponse' THEN 'Manager Response'
            WHEN 'writeoffdecision' THEN 'Write-off Decision'
            WHEN 'closedbyescalationresponse' THEN 'Closure'
            ELSE ISNULL(NULLIF(LTRIM(RTRIM({alias}.ActionType)),''),'Workflow Event')
        END";

    internal static string BuildActivitySql(ArActivityReportFilter filter, ArReportSchema schema, IReadOnlyCollection<string>? analystScope)
    {
        // ---- Optional-column guards -------------------------------------------------------
        var noteContact = schema.Note.Contains("ContactMethod") ? "ISNULL(n.ContactMethod,'')" : "CAST('' AS nvarchar(60))";
        var noteCategory = schema.Note.Contains("FollowUpCategory") ? "ISNULL(n.FollowUpCategory,'')" : "CAST('' AS nvarchar(80))";
        var noteBalance = schema.Note.Contains("BalanceSnapshot") ? "n.BalanceSnapshot" : "CAST(NULL AS decimal(18,2))";
        var noteInternal = schema.Note.Contains("IsInternalOnly") ? "ISNULL(n.IsInternalOnly,0)" : "CAST(0 AS bit)";
        var noteSource = schema.Note.Contains("UpdateSource") ? "ISNULL(n.UpdateSource,'UI')" : "CAST('UI' AS nvarchar(20))";
        var noteBatch = schema.Note.Contains("UploadBatchId") ? "ISNULL(n.UploadBatchId,'')" : "CAST('' AS nvarchar(100))";
        var noteReason = schema.Note.Contains("FollowUpReason") ? "ISNULL(n.FollowUpReason,'')" : "CAST('' AS nvarchar(250))";
        var noteClaimKey = ClaimKeyExpr(schema.Note, "n", "ClaimIdNormalized", "ClaimId");

        var historyContact = schema.History.Contains("ContactMethod") ? "ISNULL(h.ContactMethod,'')" : "CAST('' AS nvarchar(60))";
        var historyBalance = schema.History.Contains("BalanceSnapshot") ? "h.BalanceSnapshot" : "CAST(NULL AS decimal(18,2))";
        var historySource = schema.History.Contains("UpdateSource") ? "ISNULL(h.UpdateSource,'UI')" : "CAST('UI' AS nvarchar(20))";
        var historyBatch = schema.History.Contains("UploadBatchId") ? "ISNULL(h.UploadBatchId,'')" : "CAST('' AS nvarchar(100))";

        var escalationKey = ClaimKeyExpr(schema.Escalation, "e", "ClaimIdNormalized", "ClaimId");
        var escalationSource = schema.Escalation.Contains("UpdateSource") ? "ISNULL(e.UpdateSource,'UI')" : "CAST('UI' AS nvarchar(20))";
        var escalationBatch = schema.Escalation.Contains("UploadBatchId") ? "ISNULL(e.UploadBatchId,'')" : "CAST('' AS nvarchar(100))";
        var escalationBalance = schema.Escalation.Contains("BalanceSnapshot") ? "e.BalanceSnapshot" : "CAST(NULL AS decimal(18,2))";
        var escalationRecipient = schema.Escalation.Contains("EscalatedTo") ? "ISNULL(e.EscalatedTo,'')" : "CAST('' AS nvarchar(256))";
        var escalationRole = schema.Escalation.Contains("EscalatedToRole") ? "ISNULL(e.EscalatedToRole,'')" : "CAST('' AS nvarchar(100))";
        var escalationFollowUp = schema.Escalation.Contains("NextFollowUpDate") ? "e.NextFollowUpDate" : "CAST(NULL AS date)";

        var taskClaimKey = ClaimKeyExpr(schema.Task, "t", "ClaimIDNormalized", "ClaimID");
        var taskWorkflowStatus = schema.Task.Contains("WorkFlowStatus") ? "t.WorkFlowStatus" : "CAST(NULL AS nvarchar(100))";
        var taskStatus = schema.Task.Contains("Status") ? "t.[Status]" : "CAST(NULL AS nvarchar(100))";
        var taskAssignedOn = schema.Task.Contains("AssignedOn") ? "t.AssignedOn" : "CAST(NULL AS datetime2(0))";
        var taskAssignedBy = schema.Task.Contains("ReviewerUpdatedBy") ? "ISNULL(t.ReviewerUpdatedBy,'')" : "CAST('' AS nvarchar(256))";
        var taskPriority = schema.Task.Contains("Priority") ? "ISNULL(t.Priority,'')" : "CAST('' AS nvarchar(100))";
        var taskDos = schema.Task.Contains("DateOfService") ? "t.DateOfService" : "CAST(NULL AS date)";
        var taskName = schema.Task.Contains("Task") ? "ISNULL(t.[Task],'')" : "CAST('' AS nvarchar(500))";
        var taskActionCompleted = schema.Task.Contains("ActionCompleted") ? "ISNULL(t.ActionCompleted,0)" : "CAST(0 AS bit)";
        var taskDateCompleted = schema.Task.Contains("DateCompleted") ? "t.DateCompleted" : "CAST(NULL AS date)";
        var taskClaimUid = schema.Task.Contains("ClaimUID") ? "ISNULL(t.ClaimUID,'')" : "CAST('' AS nvarchar(600))";
        var taskRunId = schema.Task.Contains("RunId") ? "ISNULL(t.RunId,'')" : "CAST('' AS nvarchar(100))";
        var taskOrderBy = schema.Task.Contains("CreatedOn") ? "ORDER BY t.CreatedOn DESC" : string.Empty;

        var taskSelectList = $@"
        ClaimIdRaw     = ISNULL(t.ClaimID,''),
        CptCode        = ISNULL(t.CPTCode,''),
        PayerName      = ISNULL(t.PayerName,''),
        DenialCode     = ISNULL(t.DenialCode,''),
        DenialReason   = ISNULL(t.DenialDescription,''),
        Classification = ISNULL(t.DenialClassification,''),
        ActionCategory = ISNULL(t.ActionCategory,''),
        TaskName       = {taskName},
        StatusValue    = ISNULL({taskStatus},''),
        WorkFlowStatus = ISNULL({taskWorkflowStatus},''),
        AssignedTo     = ISNULL(t.AssignedTo,''),
        AssignedOn     = {taskAssignedOn},
        AssignedBy     = {taskAssignedBy},
        Priority       = {taskPriority},
        DateOfService  = {taskDos},
        InsuranceBalance    = ISNULL(t.InsuranceBalance,0),
        ActionCompletedFlag = {taskActionCompleted},
        DateCompleted  = {taskDateCompleted},
        ClaimUID       = {taskClaimUid},
        TaskRunId      = {taskRunId}";

        // Line-item enrichment supplies encounter/accession and the ONLY source of original charge.
        // Keyed on ClaimUID, which both tables carry in the canonical schema; where a lab has not
        // been migrated the columns come back empty rather than the report failing.
        var canJoinLine = schema.Task.Contains("ClaimUID") && schema.Line.Contains("ClaimUID");
        var accessionExpr = schema.Line.Contains("AccessionNo") ? "ISNULL(l.AccessionNo,'')"
            : schema.Line.Contains("AccessionNumber") ? "ISNULL(l.AccessionNumber,'')"
            : "CAST('' AS nvarchar(150))";
        var chargeExpr = schema.Line.Contains("BilledAmount") ? "ISNULL(l.BilledAmount,0)" : "CAST(0 AS decimal(18,2))";
        var lineCptFilter = schema.Line.Contains("CPTCode") ? " AND (ISNULL(a.CptCode,'') = '' OR ISNULL(l.CPTCode,'') = a.CptCode)" : string.Empty;
        var lineApply = canJoinLine
            ? $@"
OUTER APPLY (
    SELECT TOP (1)
        Accession      = {accessionExpr},
        OriginalCharge = CONVERT(decimal(18,2), {chargeExpr})
    FROM dbo.DenialLineItem l WITH (NOLOCK)
    WHERE {LabScopeSql("l.LabId")}
      AND l.ClaimUID = NULLIF(COALESCE(NULLIF(tbT.ClaimUID,''), NULLIF(tbC.ClaimUID,'')),''){lineCptFilter}
) li"
            : @"
OUTER APPLY (SELECT Accession = CAST('' AS nvarchar(150)), OriginalCharge = CAST(0 AS decimal(18,2))) li";

        // Grain key drives Latest Activity Only and the distinct-worked measures.
        var grainKeyExpr = string.Equals(filter.Grain, "Line", StringComparison.OrdinalIgnoreCase)
            ? "CONCAT(a.ClaimKey, '|', ISNULL(a.TaskId,''))"
            : "CONVERT(nvarchar(300), a.ClaimKey)";

        var groupKeyExpr = (filter.GroupBy ?? "none").Trim().ToLowerInvariant() switch
        {
            "analyst" => "ISNULL(NULLIF(a.Author,''),'(unattributed)')",
            // No "manager" grouping: manager is a LRNMaster dimension that this lab-database query
            // cannot join to, so grouping by it here would silently group by something else.
            "classification" => "ISNULL(NULLIF(e1.DenialClassification,''),'(unclassified)')",
            "action" => "ISNULL(NULLIF(e1.ActionCategory,''),'(no action)')",
            "payer" => "ISNULL(NULLIF(e1.PayerName,''),'(no payer)')",
            "activitytype" => "a.ActivityType",
            _ => "CAST('' AS nvarchar(400))"
        };

        var contactMethodExpr = "ISNULL(NULLIF(a.ContactMethod,''),'Not Recorded')";

        var filters = new List<string>
        {
            "(@Analyst = '' OR LOWER(LTRIM(RTRIM(e1.AnalystName))) = LOWER(@Analyst) OR LOWER(LTRIM(RTRIM(ISNULL(a.Author,'')))) = LOWER(@Analyst))",
            "(@Payer = '' OR LOWER(LTRIM(RTRIM(e1.PayerName))) = LOWER(@Payer))",
            "(@DenialClassification = '' OR LOWER(LTRIM(RTRIM(e1.DenialClassification))) = LOWER(@DenialClassification))",
            "(@ActionCategory = '' OR LOWER(LTRIM(RTRIM(e1.ActionCategory))) = LOWER(@ActionCategory))",
            "(@TaskName = '' OR LOWER(LTRIM(RTRIM(e1.TaskName))) = LOWER(@TaskName))",
            "(@WorkflowStatus = '' OR LOWER(LTRIM(RTRIM(e1.WorkflowStatus))) = LOWER(@WorkflowStatus))",
            "(@ReportingBucket = '' OR LOWER(LTRIM(RTRIM(e2.ReportingBucket))) = LOWER(@ReportingBucket))",
            "(@AgingBucket = '' OR LOWER(LTRIM(RTRIM(e2.AgingBucket))) = LOWER(@AgingBucket))",
            "(@DueStatus = '' OR LOWER(LTRIM(RTRIM(e2.DueStatus))) = LOWER(@DueStatus))",
            "(@EscalationStatus = '' OR LOWER(LTRIM(RTRIM(ISNULL(a.EscalationStatus,'')))) = LOWER(@EscalationStatus))",
            "(@ActivityType = '' OR LOWER(LTRIM(RTRIM(a.ActivityType))) = LOWER(@ActivityType))",
            $"(@ContactMethod = '' OR LOWER({contactMethodExpr}) = LOWER(@ContactMethod))",
            "(@UpdateSource = '' OR LOWER(e1.UpdateSourceLabel) = LOWER(@UpdateSource))",
            @"(@SearchText = '' OR e1.ClaimId LIKE '%' + @SearchText + '%'
              OR ISNULL(a.TaskId,'') LIKE '%' + @SearchText + '%'
              OR e1.CptCode LIKE '%' + @SearchText + '%'
              OR e1.PayerName LIKE '%' + @SearchText + '%'
              OR ISNULL(a.Author,'') LIKE '%' + @SearchText + '%'
              OR CAST(ISNULL(a.NoteText,'') AS nvarchar(max)) LIKE '%' + @SearchText + '%')"
        };
        if (analystScope is { Count: > 0 })
        {
            filters.Add($@"EXISTS (
                SELECT 1 FROM STRING_SPLIT(@AnalystScope, N'{MultiSelectDelimiter}') sv
                WHERE LOWER(LTRIM(RTRIM(sv.value))) IN (LOWER(LTRIM(RTRIM(ISNULL(a.Author,'')))), LOWER(LTRIM(RTRIM(e1.AnalystName))))
            )");
        }

        var sortColumn = (filter.SortBy ?? "activityDate").Trim().ToLowerInvariant() switch
        {
            "claimid" => "ClaimId",
            "analyst" => "AnalystName",
            "activitytype" => "ActivityType",
            "payer" => "PayerName",
            "balance" => "BalanceSnapshot",
            _ => "ActivityDate"
        };
        var sortDir = string.Equals(filter.SortDir, "asc", StringComparison.OrdinalIgnoreCase) ? "ASC" : "DESC";

        // Latest Activity Only: keep the most recent qualifying activity at the SELECTED grain
        // (spec section 3.1). Applied after enrichment so the surviving row still carries the full
        // claim/line context.
        var latestOnlyBlock = filter.LatestOnly
            ? @"
;WITH Ranked AS
(
    SELECT *, LatestRank = ROW_NUMBER() OVER (PARTITION BY GrainKey ORDER BY ActivityDate DESC, ActivityId DESC)
    FROM #Enriched
)
DELETE FROM Ranked WHERE LatestRank > 1;
"
            : string.Empty;

        return $@"
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Act') IS NOT NULL DROP TABLE #Act;
CREATE TABLE #Act
(
    ActivityId          nvarchar(60)  NOT NULL,
    SourceType          varchar(12)   NOT NULL,
    ClaimIdRaw          nvarchar(150) NULL,
    ClaimKey            varchar(150)  NULL,
    TaskId              nvarchar(100) NULL,
    CptCode             nvarchar(50)  NULL,
    ActivityDate        datetime2(0)  NOT NULL,
    ActivityType        nvarchar(60)  NOT NULL,
    Author              nvarchar(256) NULL,
    NoteText            nvarchar(max) NULL,
    ContactMethod       nvarchar(60)  NULL,
    PreviousStatus      nvarchar(100) NULL,
    NewStatus           nvarchar(100) NULL,
    StatusAtActivity    nvarchar(100) NULL,
    StatusReason        nvarchar(250) NULL,
    NextFollowUpDate    date          NULL,
    FollowUpCategory    nvarchar(80)  NULL,
    EscalationIdValue   bigint        NULL,
    EscalationReason    nvarchar(300) NULL,
    EscalationRecipient nvarchar(256) NULL,
    EscalationStatus    nvarchar(50)  NULL,
    UpdateSource        nvarchar(20)  NULL,
    UploadBatchId       nvarchar(100) NULL,
    BalanceSnapshot     decimal(18,2) NULL,
    IsInternalOnly      bit           NOT NULL,
    SourceRunId         nvarchar(100) NULL
);

-- ---------------------------------------------------------------------------------------
-- Source 1: workflow history. ActionType='Escalation' is excluded on purpose - see the class
-- comment; the escalation record below is the authoritative single event for a raise.
-- ---------------------------------------------------------------------------------------
INSERT INTO #Act
    (ActivityId, SourceType, ClaimIdRaw, ClaimKey, TaskId, CptCode, ActivityDate, ActivityType, Author,
     NoteText, ContactMethod, PreviousStatus, NewStatus, StatusAtActivity, StatusReason, NextFollowUpDate,
     FollowUpCategory, EscalationIdValue, EscalationReason, EscalationRecipient, EscalationStatus,
     UpdateSource, UploadBatchId, BalanceSnapshot, IsInternalOnly, SourceRunId)
SELECT
    'H:' + CONVERT(varchar(20), h.HistoryId),
    'History',
    ISNULL(tb.ClaimIdRaw,''),
    ISNULL(tb.ClaimKey,''),
    ISNULL(h.TaskID,''),
    ISNULL(tb.CptCode,''),
    h.ActionDate,
    {HistoryActivityTypeSql("h")},
    ISNULL(h.ActionBy,''),
    ISNULL(h.Comments,''),
    {historyContact},
    ISNULL(h.OldStatus,''),
    ISNULL(h.NewStatus,''),
    ISNULL(h.NewStatus,''),
    ISNULL(h.ActionType,''),
    NULL,
    '',
    NULL, '', '', '',
    {historySource}, {historyBatch}, {historyBalance},
    0,
    ISNULL(h.RunId,'')
FROM dbo.DenialTaskHistory h WITH (NOLOCK)
OUTER APPLY (
    SELECT TOP (1)
        ClaimIdRaw = ISNULL(t.ClaimID,''),
        ClaimKey   = {taskClaimKey},
        CptCode    = ISNULL(t.CPTCode,'')
    FROM dbo.DenialTaskBoard t WITH (NOLOCK)
    WHERE {LabScopeSql("t.LabId")} AND t.TaskID = h.TaskID
) tb
WHERE {LabScopeSql("h.LabId")}
  AND h.ActionDate >= @FromDate AND h.ActionDate < @ToDateExclusive
  AND LOWER(LTRIM(RTRIM(ISNULL(h.ActionType,'')))) <> 'escalation';

-- ---------------------------------------------------------------------------------------
-- Source 2: work notes. A note is not a status change, so PreviousStatus/NewStatus stay blank
-- (spec section 4: previous/new status must not be presented as factual unless the event IS the
-- status change). The status the note captured is kept separately as context.
-- ---------------------------------------------------------------------------------------
INSERT INTO #Act
    (ActivityId, SourceType, ClaimIdRaw, ClaimKey, TaskId, CptCode, ActivityDate, ActivityType, Author,
     NoteText, ContactMethod, PreviousStatus, NewStatus, StatusAtActivity, StatusReason, NextFollowUpDate,
     FollowUpCategory, EscalationIdValue, EscalationReason, EscalationRecipient, EscalationStatus,
     UpdateSource, UploadBatchId, BalanceSnapshot, IsInternalOnly, SourceRunId)
SELECT
    'N:' + CONVERT(varchar(20), n.NoteId),
    'Note',
    ISNULL(n.ClaimId,''),
    {noteClaimKey},
    ISNULL(n.TaskId,''),
    ISNULL(n.CptCode,''),
    n.CreatedOn,
    'Work Note',
    ISNULL(n.CreatedBy,''),
    ISNULL(n.NoteText,''),
    {noteContact},
    '',
    '',
    ISNULL(n.[Status],''),
    {noteReason},
    n.NextFollowUpDate,
    {noteCategory},
    NULL, '', '', '',
    {noteSource}, {noteBatch}, {noteBalance},
    {noteInternal},
    ''
FROM dbo.DenialClaimNotes n WITH (NOLOCK)
WHERE {LabScopeSql("n.LabId")}
  AND n.IsDeleted = 0
  AND n.CreatedOn >= @FromDate AND n.CreatedOn < @ToDateExclusive;

-- ---------------------------------------------------------------------------------------
-- Source 3: escalations raised. One row per escalation cycle, carrying the reason, recipient and
-- EscalationId the history rows do not have. An escalation routed to a Client or Account Manager
-- is addressed TO that role, so it is not internal-only; anything else is.
-- ---------------------------------------------------------------------------------------
INSERT INTO #Act
    (ActivityId, SourceType, ClaimIdRaw, ClaimKey, TaskId, CptCode, ActivityDate, ActivityType, Author,
     NoteText, ContactMethod, PreviousStatus, NewStatus, StatusAtActivity, StatusReason, NextFollowUpDate,
     FollowUpCategory, EscalationIdValue, EscalationReason, EscalationRecipient, EscalationStatus,
     UpdateSource, UploadBatchId, BalanceSnapshot, IsInternalOnly, SourceRunId)
SELECT
    'E:' + CONVERT(varchar(20), e.EscalationId),
    'Escalation',
    ISNULL(e.ClaimId,''),
    {escalationKey},
    ISNULL(e.TaskId,''),
    ISNULL(e.CptCode,''),
    e.CreatedOn,
    'Escalation Raised',
    ISNULL(e.CreatedBy,''),
    ISNULL(e.Comments,''),
    'Application',
    '',
    '',
    ISNULL(e.[Status],''),
    ISNULL(e.EscalationReason,''),
    {escalationFollowUp},
    'Escalation Response',
    e.EscalationId,
    ISNULL(e.EscalationReason,''),
    {escalationRecipient},
    ISNULL(e.[Status],''),
    {escalationSource}, {escalationBatch}, {escalationBalance},
    CASE WHEN {escalationRole} LIKE '%lient%' OR {escalationRole} LIKE '%ccount%' THEN 0 ELSE 1 END,
    ''
FROM dbo.DenialClaimEscalations e WITH (NOLOCK)
WHERE {LabScopeSql("e.LabId")}
  AND ISNULL(e.IsDeleted,0) = 0
  AND e.CreatedOn >= @FromDate AND e.CreatedOn < @ToDateExclusive;

CREATE INDEX IX_Act_ClaimKey ON #Act (ClaimKey, TaskId);

-- ---------------------------------------------------------------------------------------
-- Follow-up schedule context. Original due date and reschedule count are DERIVED from the note
-- history for the claims already in scope: the first due date ever scheduled, and how many times
-- it changed. Bounded by #Act, so this never scans the whole notes table.
-- ---------------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Sched') IS NOT NULL DROP TABLE #Sched;
SELECT
    ClaimKey    = {noteClaimKey},
    TaskKey     = ISNULL(n.TaskId,''),
    OriginalDue = MIN(n.NextFollowUpDate),
    DueValues   = COUNT(DISTINCT n.NextFollowUpDate)
INTO #Sched
FROM dbo.DenialClaimNotes n WITH (NOLOCK)
WHERE {LabScopeSql("n.LabId")}
  AND n.IsDeleted = 0
  AND n.NextFollowUpDate IS NOT NULL
  AND EXISTS (SELECT 1 FROM #Act ax WHERE ax.ClaimKey = {noteClaimKey})
GROUP BY {noteClaimKey}, ISNULL(n.TaskId,'');
CREATE INDEX IX_Sched ON #Sched (ClaimKey, TaskKey);

-- ---------------------------------------------------------------------------------------
-- Action completion. Read from the immutable completion event when one exists; the current
-- task-board flag is only a fallback, and the two are reported apart so an operational figure is
-- never passed off as event-backed.
-- ---------------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Comp') IS NOT NULL DROP TABLE #Comp;
SELECT ClaimKey, TaskKey, CompletedOn, CompletedBy, CompletedLabel
INTO #Comp
FROM (
    SELECT
        ClaimKey       = c.ClaimIdNormalized,
        TaskKey        = ISNULL(c.TaskId,''),
        CompletedOn    = c.CompletedOn,
        CompletedBy    = ISNULL(c.CompletedBy,''),
        CompletedLabel = ISNULL(c.CompletedDateLabel,''),
        CompletionRank = ROW_NUMBER() OVER (PARTITION BY c.ClaimIdNormalized, ISNULL(c.TaskId,'') ORDER BY c.CompletedOn DESC, c.ActionCompletionEventId DESC)
    FROM dbo.DenialActionCompletionEvent c WITH (NOLOCK)
    WHERE {LabScopeSql("c.LabId")}
      AND c.IsCompleted = 1
      AND EXISTS (SELECT 1 FROM #Act ax WHERE ax.ClaimKey = c.ClaimIdNormalized)
) x
WHERE x.CompletionRank = 1;
CREATE INDEX IX_Comp ON #Comp (ClaimKey, TaskKey);

-- ---------------------------------------------------------------------------------------
-- Enrichment + filtering.
-- Two task-board lookups: by TaskID when the event names a line, by claim otherwise. Both are
-- single-column index seeks (IX_DenialTaskBoard_Lab_TaskID / IX_DenialTaskBoard_ClaimIDNormalized)
-- driven by #Act, which is already narrowed to the activity window.
-- APPLY order matters: each alias may only reference aliases declared before it.
--   tbT/tbC -> li -> #Sched/#Comp -> e1 (coalesced base) -> bk/ag/agb (config lookups) -> e2 (derived)
-- ---------------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Enriched') IS NOT NULL DROP TABLE #Enriched;
SELECT
    a.ActivityId,
    a.SourceType,
    ClaimId    = e1.ClaimId,
    ClaimKey   = a.ClaimKey,
    LineItemId = ISNULL(a.TaskId,''),
    CptCode    = e1.CptCode,
    EncounterNumber = ISNULL(li.Accession,''),
    DateOfService   = e1.DateOfService,
    PayerName       = e1.PayerName,
    DenialCode      = e1.DenialCode,
    DenialReason    = e1.DenialReason,
    DenialClassification = e1.DenialClassification,
    WorkflowStatus  = e1.WorkflowStatus,
    ReportingBucket = e2.ReportingBucket,
    AgingBucket     = e2.AgingBucket,
    Priority        = e1.Priority,
    AnalystName     = e1.AnalystName,
    AssignedOn      = e1.AssignedOn,
    AssignedBy      = e1.AssignedBy,
    a.ActivityDate,
    ActivityDateKey = CONVERT(char(10), a.ActivityDate, 23),
    Author          = ISNULL(a.Author,''),
    a.ActivityType,
    ContactMethod   = {contactMethodExpr},
    NoteText        = ISNULL(a.NoteText,''),
    a.IsInternalOnly,
    PreviousStatus  = ISNULL(a.PreviousStatus,''),
    NewStatus       = ISNULL(a.NewStatus,''),
    StatusReason    = ISNULL(a.StatusReason,''),
    ActionCategory  = e1.ActionCategory,
    TaskName        = e1.TaskName,
    ActionCompleted = e2.ActionCompleted,
    ActionCompletedOn = e2.ActionCompletedOn,
    ActionCompletedBy = e2.ActionCompletedBy,
    ActionCompletedLabel = e2.ActionCompletedLabel,
    ActionCompletionIsEvent = e2.ActionCompletionIsEvent,
    a.NextFollowUpDate,
    FollowUpCategory = ISNULL(NULLIF(a.FollowUpCategory,''), e2.DerivedFollowUpCategory),
    OriginalFollowUpDate = sc.OriginalDue,
    RescheduleCount = CASE WHEN ISNULL(sc.DueValues,0) > 1 THEN sc.DueValues - 1 ELSE 0 END,
    DueStatus       = e2.DueStatus,
    Escalated       = CASE WHEN a.SourceType = 'Escalation' THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,
    EscalationId    = ISNULL(CONVERT(nvarchar(30), a.EscalationIdValue),''),
    EscalationReason = ISNULL(a.EscalationReason,''),
    EscalationRecipient = ISNULL(a.EscalationRecipient,''),
    EscalationStatus = ISNULL(a.EscalationStatus,''),
    OriginalCharge  = ISNULL(li.OriginalCharge,0),
    BalanceSnapshot = e2.BalanceSnapshot,
    BalanceIsSnapshot = e2.BalanceIsSnapshot,
    UpdateSource    = e1.UpdateSourceLabel,
    UploadBatchId   = ISNULL(a.UploadBatchId,''),
    RunId           = ISNULL(NULLIF(a.SourceRunId,''), e1.TaskRunId),
    CreatedBy       = ISNULL(a.Author,''),
    GrainKey        = {grainKeyExpr},
    GroupKey        = CONVERT(nvarchar(400), {groupKeyExpr})
INTO #Enriched
FROM #Act a
OUTER APPLY (
    SELECT TOP (1) {taskSelectList}
    FROM dbo.DenialTaskBoard t WITH (NOLOCK)
    WHERE {LabScopeSql("t.LabId")} AND ISNULL(a.TaskId,'') <> '' AND t.TaskID = a.TaskId
) tbT
OUTER APPLY (
    SELECT TOP (1) {taskSelectList}
    FROM dbo.DenialTaskBoard t WITH (NOLOCK)
    WHERE {LabScopeSql("t.LabId")} AND {taskClaimKey} = a.ClaimKey
    {taskOrderBy}
) tbC{lineApply}
LEFT JOIN #Sched sc ON sc.ClaimKey = a.ClaimKey AND sc.TaskKey = ISNULL(a.TaskId,'')
LEFT JOIN #Comp  cp ON cp.ClaimKey = a.ClaimKey AND cp.TaskKey = ISNULL(a.TaskId,'')
CROSS APPLY (
    SELECT
        ClaimId = ISNULL(NULLIF(a.ClaimIdRaw,''), ISNULL(NULLIF(COALESCE(tbT.ClaimIdRaw, tbC.ClaimIdRaw),''), a.ClaimKey)),
        CptCode = ISNULL(NULLIF(a.CptCode,''), ISNULL(COALESCE(tbT.CptCode, tbC.CptCode),'')),
        PayerName = ISNULL(COALESCE(NULLIF(tbT.PayerName,''), tbC.PayerName),''),
        DenialCode = ISNULL(COALESCE(NULLIF(tbT.DenialCode,''), tbC.DenialCode),''),
        DenialReason = ISNULL(COALESCE(NULLIF(tbT.DenialReason,''), tbC.DenialReason),''),
        DenialClassification = ISNULL(COALESCE(NULLIF(tbT.Classification,''), tbC.Classification),''),
        ActionCategory = ISNULL(COALESCE(NULLIF(tbT.ActionCategory,''), tbC.ActionCategory),''),
        TaskName = ISNULL(COALESCE(NULLIF(tbT.TaskName,''), tbC.TaskName),''),
        -- Workload snapshots follow the current assignee, but an activity stays with whoever
        -- performed it (spec section 3.2). AssignedTo is the claim's analyst; the author falls
        -- back in only when the claim carries no assignee at all.
        AnalystName = ISNULL(COALESCE(NULLIF(tbT.AssignedTo,''), NULLIF(tbC.AssignedTo,''), NULLIF(a.Author,'')),''),
        AssignedOn = COALESCE(tbT.AssignedOn, tbC.AssignedOn),
        AssignedBy = ISNULL(COALESCE(NULLIF(tbT.AssignedBy,''), tbC.AssignedBy),''),
        Priority = ISNULL(COALESCE(NULLIF(tbT.Priority,''), tbC.Priority),''),
        DateOfService = COALESCE(tbT.DateOfService, tbC.DateOfService),
        TaskRunId = ISNULL(COALESCE(NULLIF(tbT.TaskRunId,''), tbC.TaskRunId),''),
        ClaimUID = COALESCE(NULLIF(tbT.ClaimUID,''), tbC.ClaimUID),
        -- The status this row reports: the status the event itself recorded when it recorded one,
        -- otherwise the claim's current workflow status.
        WorkflowStatus = ISNULL(NULLIF(ISNULL(a.StatusAtActivity,''),''),
            ISNULL(COALESCE(NULLIF(tbT.WorkFlowStatus,''), NULLIF(tbT.StatusValue,''), NULLIF(tbC.WorkFlowStatus,''), NULLIF(tbC.StatusValue,'')),'')),
        CurrentBalance = ISNULL(COALESCE(tbT.InsuranceBalance, tbC.InsuranceBalance),0),
        ActionCompletedFlag = CASE WHEN COALESCE(tbT.ActionCompletedFlag, tbC.ActionCompletedFlag, 0) = 1 THEN 1 ELSE 0 END,
        FlagCompletedOn = CONVERT(datetime2(0), COALESCE(tbT.DateCompleted, tbC.DateCompleted)),
        UpdateSourceLabel = CASE WHEN LOWER(ISNULL(a.UpdateSource,'UI')) IN ('excel','upload','excel upload') THEN 'Excel Upload' ELSE 'Application' END
) e1
OUTER APPLY (
    SELECT TOP (1) bm.ReportingBucket
    FROM dbo.DenialStatusBucketMap bm WITH (NOLOCK)
    WHERE bm.StatusName = e1.WorkflowStatus
      AND bm.EffectiveFrom <= @AsOf
      AND (bm.EffectiveTo IS NULL OR bm.EffectiveTo > @AsOf)
    ORDER BY bm.EffectiveFrom DESC
) bk
OUTER APPLY (
    SELECT AgeDays = CASE WHEN e1.DateOfService IS NULL THEN NULL ELSE DATEDIFF(day, e1.DateOfService, CAST(@AsOf AS date)) END
) ag
OUTER APPLY (
    SELECT TOP (1) ab.BucketLabel
    FROM dbo.DenialAgingBucket ab WITH (NOLOCK)
    WHERE ag.AgeDays IS NOT NULL AND ag.AgeDays >= ab.MinDays AND (ab.MaxDays IS NULL OR ag.AgeDays <= ab.MaxDays)
    ORDER BY ab.SortOrder
) agb
CROSS APPLY (
    SELECT
        -- An unmapped status reads as 'Unmapped' rather than being silently dropped: a visible
        -- wrong bucket is correctable in dbo.DenialStatusBucketMap, a vanished row is not.
        ReportingBucket = ISNULL(NULLIF(bk.ReportingBucket,''),'Unmapped'),
        AgingBucket     = ISNULL(agb.BucketLabel,''),
        ActionCompleted = CASE WHEN cp.CompletedOn IS NOT NULL OR e1.ActionCompletedFlag = 1 THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,
        ActionCompletedOn = COALESCE(cp.CompletedOn, e1.FlagCompletedOn),
        ActionCompletedBy = ISNULL(cp.CompletedBy,''),
        ActionCompletedLabel = ISNULL(NULLIF(cp.CompletedLabel,''), e1.ActionCategory),
        ActionCompletionIsEvent = CASE WHEN cp.CompletedOn IS NOT NULL THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,
        BalanceSnapshot = CONVERT(decimal(18,2), COALESCE(a.BalanceSnapshot, e1.CurrentBalance)),
        BalanceIsSnapshot = CASE WHEN a.BalanceSnapshot IS NOT NULL THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END,
        DerivedFollowUpCategory = CONVERT(nvarchar(80), CASE
            WHEN a.SourceType = 'Escalation' THEN 'Escalation Response'
            WHEN e1.ActionCategory LIKE '%ppeal%' THEN 'Appeal Follow-up'
            WHEN e1.ActionCategory LIKE '%ebill%' THEN 'Rebill Follow-up'
            WHEN e1.WorkflowStatus LIKE '%ocumentation%' THEN 'Documentation Follow-up'
            WHEN a.NextFollowUpDate IS NULL THEN ''
            ELSE 'Payer Follow-up' END),
        -- Audit snapshot, NOT current backlog: this is the state of the due date THIS activity
        -- recorded, judged at the as-of instant (spec section 3.1 business rules).
        DueStatus = CONVERT(nvarchar(40), CASE
            WHEN a.NextFollowUpDate IS NULL THEN 'No Follow-up Date'
            WHEN a.NextFollowUpDate < CAST(@AsOf AS date) THEN 'Overdue'
            WHEN a.NextFollowUpDate = CAST(@AsOf AS date) THEN 'Due Today'
            WHEN a.NextFollowUpDate <= DATEADD(day, @DueSoonDays, CAST(@AsOf AS date)) THEN 'Due Soon'
            ELSE 'Future' END)
) e2
WHERE {string.Join("\n  AND ", filters)};
{latestOnlyBlock}
CREATE INDEX IX_Enriched_Grain ON #Enriched (GrainKey, ActivityDate DESC);

-- Result 1: the requested detail page.
SELECT *
FROM #Enriched
ORDER BY {sortColumn} {sortDir}, ActivityId DESC
OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

-- Result 2: summary measures over the WHOLE filtered set, not just the page (FR-002: every
-- summary metric must reconcile to the drill-down detail at the same grain and filter context).
SELECT
    TotalRows          = COUNT_BIG(1),
    DistinctClaimDays  = COUNT(DISTINCT CONCAT(ClaimKey, '|', Author, '|', ActivityDateKey)),
    DistinctLineDays   = COUNT(DISTINCT CONCAT(ClaimKey, '|', LineItemId, '|', Author, '|', ActivityDateKey)),
    DistinctClaims     = COUNT(DISTINCT ClaimKey),
    DistinctLines      = COUNT(DISTINCT CONCAT(ClaimKey, '|', LineItemId)),
    DistinctAnalysts   = COUNT(DISTINCT Author),
    EscalationsRaised  = SUM(CASE WHEN SourceType = 'Escalation' THEN 1 ELSE 0 END),
    NotesRecorded      = SUM(CASE WHEN ActivityType = 'Work Note' THEN 1 ELSE 0 END),
    StatusChanges      = SUM(CASE WHEN ActivityType = 'Status Update' THEN 1 ELSE 0 END),
    ActionsCompleted   = COUNT(DISTINCT CASE WHEN ActionCompleted = 1 THEN CONCAT(ClaimKey, '|', LineItemId) END),
    ActionsCompletedFromEvents = COUNT(DISTINCT CASE WHEN ActionCompletionIsEvent = 1 THEN CONCAT(ClaimKey, '|', LineItemId) END),
    RowsWithFallbackBalance = SUM(CASE WHEN BalanceIsSnapshot = 0 THEN 1 ELSE 0 END)
FROM #Enriched;

-- Result 3: balance worked. One balance per distinct claim/analyst/activity date - never the same
-- balance re-added for every note on that claim (spec section 3.1).
SELECT BalanceWorked = ISNULL(SUM(x.Balance), 0)
FROM (
    SELECT Balance = MAX(BalanceSnapshot)
    FROM #Enriched
    GROUP BY ClaimKey, Author, ActivityDateKey
) x;

-- Result 4: the grouping tab, empty when no grouping is selected. Balance is aggregated the same
-- claim-day way inside each group so a group total reconciles to the overall total.
WITH GroupBalance AS
(
    SELECT GroupKey, ClaimKey, Author, ActivityDateKey, Balance = MAX(BalanceSnapshot)
    FROM #Enriched
    WHERE GroupKey <> ''
    GROUP BY GroupKey, ClaimKey, Author, ActivityDateKey
),
GroupBalanceTotal AS
(
    SELECT GroupKey, BalanceWorked = SUM(Balance) FROM GroupBalance GROUP BY GroupKey
)
SELECT
    e.GroupKey,
    ActivityEvents    = COUNT_BIG(1),
    DistinctClaimDays = COUNT(DISTINCT CONCAT(e.ClaimKey, '|', e.Author, '|', e.ActivityDateKey)),
    DistinctLineDays  = COUNT(DISTINCT CONCAT(e.ClaimKey, '|', e.LineItemId, '|', e.Author, '|', e.ActivityDateKey)),
    DistinctClaims    = COUNT(DISTINCT e.ClaimKey),
    ActionsCompleted  = COUNT(DISTINCT CASE WHEN e.ActionCompleted = 1 THEN CONCAT(e.ClaimKey, '|', e.LineItemId) END),
    EscalationsRaised = SUM(CASE WHEN e.SourceType = 'Escalation' THEN 1 ELSE 0 END),
    BalanceWorked     = ISNULL(MAX(gb.BalanceWorked), 0)
FROM #Enriched e
LEFT JOIN GroupBalanceTotal gb ON gb.GroupKey = e.GroupKey
WHERE e.GroupKey <> ''
GROUP BY e.GroupKey
ORDER BY ActivityEvents DESC;

DROP TABLE #Enriched;
DROP TABLE #Comp;
DROP TABLE #Sched;
DROP TABLE #Act;
";
    }

    // ==================================================================================
    // Saved views + run log
    // ==================================================================================

    public async Task<IReadOnlyList<ArReportSavedView>> GetSavedViewsAsync(string reportCode, int labId, string ownerUserName, CancellationToken ct)
    {
        await EnsureReportObjectsAsync(labId, ct);
        const string sql = @"
SELECT SavedViewId, ReportCode, LabId, OwnerUserName, ViewName, FiltersJson, IsDefault, UpdatedOn
FROM dbo.DenialReportSavedView WITH (NOLOCK)
WHERE ReportCode = @ReportCode AND LabId = @LabId AND OwnerUserName = @Owner
ORDER BY IsDefault DESC, ViewName;";

        var rows = new List<ArReportSavedView>();
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        cmd.Parameters.AddWithValue("@ReportCode", reportCode);
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@Owner", ownerUserName ?? string.Empty);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct)) rows.Add(ReadSavedView(rd));
        return rows;
    }

    public async Task<ArReportSavedView> SaveViewAsync(string reportCode, string ownerUserName, ArReportSavedViewRequest request, CancellationToken ct)
    {
        await EnsureReportObjectsAsync(request.LabId, ct);
        const string sql = @"
SET NOCOUNT ON;
IF @IsDefault = 1
    UPDATE dbo.DenialReportSavedView SET IsDefault = 0
    WHERE ReportCode = @ReportCode AND LabId = @LabId AND OwnerUserName = @Owner;

MERGE dbo.DenialReportSavedView AS target
USING (SELECT @ReportCode AS ReportCode, @LabId AS LabId, @Owner AS OwnerUserName, @ViewName AS ViewName) AS source
    ON target.ReportCode = source.ReportCode AND target.LabId = source.LabId
       AND target.OwnerUserName = source.OwnerUserName AND target.ViewName = source.ViewName
WHEN MATCHED THEN UPDATE SET FiltersJson = @FiltersJson, IsDefault = @IsDefault, UpdatedOn = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (ReportCode, LabId, OwnerUserName, ViewName, FiltersJson, IsDefault)
    VALUES (@ReportCode, @LabId, @Owner, @ViewName, @FiltersJson, @IsDefault);

SELECT SavedViewId, ReportCode, LabId, OwnerUserName, ViewName, FiltersJson, IsDefault, UpdatedOn
FROM dbo.DenialReportSavedView
WHERE ReportCode = @ReportCode AND LabId = @LabId AND OwnerUserName = @Owner AND ViewName = @ViewName;";

        await using var con = OpenLab(request.LabId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        cmd.Parameters.AddWithValue("@ReportCode", reportCode);
        cmd.Parameters.AddWithValue("@LabId", request.LabId);
        cmd.Parameters.AddWithValue("@Owner", ownerUserName ?? string.Empty);
        cmd.Parameters.AddWithValue("@ViewName", request.ViewName.Trim());
        cmd.Parameters.AddWithValue("@FiltersJson", string.IsNullOrWhiteSpace(request.FiltersJson) ? "{}" : request.FiltersJson);
        cmd.Parameters.AddWithValue("@IsDefault", request.IsDefault);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (!await rd.ReadAsync(ct)) throw new InvalidOperationException("Unable to save the report view.");
        return ReadSavedView(rd);
    }

    public async Task<int> DeleteSavedViewAsync(string reportCode, int labId, string ownerUserName, int savedViewId, CancellationToken ct)
    {
        await EnsureReportObjectsAsync(labId, ct);
        // Owner is part of the predicate, not just the lookup: a user can only delete their own view.
        const string sql = @"
DELETE FROM dbo.DenialReportSavedView
WHERE SavedViewId = @SavedViewId AND ReportCode = @ReportCode AND LabId = @LabId AND OwnerUserName = @Owner;";
        await using var con = OpenLab(labId);
        await con.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
        cmd.Parameters.AddWithValue("@SavedViewId", savedViewId);
        cmd.Parameters.AddWithValue("@ReportCode", reportCode);
        cmd.Parameters.AddWithValue("@LabId", labId);
        cmd.Parameters.AddWithValue("@Owner", ownerUserName ?? string.Empty);
        return await cmd.ExecuteNonQueryAsync(ct);
    }

    private static ArReportSavedView ReadSavedView(IDataRecord rd) => new()
    {
        SavedViewId = GetInt(rd, "SavedViewId"),
        ReportCode = GetString(rd, "ReportCode"),
        LabId = GetInt(rd, "LabId"),
        OwnerUserName = GetString(rd, "OwnerUserName"),
        ViewName = GetString(rd, "ViewName"),
        FiltersJson = GetString(rd, "FiltersJson"),
        IsDefault = GetBool(rd, "IsDefault"),
        UpdatedOn = GetDate(rd, "UpdatedOn") ?? DateTime.UtcNow
    };

    public async Task LogRunAsync(ArReportRunMetadata metadata, string outputType, int rowCount, int durationMs, CancellationToken ct)
    {
        const string sql = @"
INSERT INTO dbo.DenialReportRunLog (RunId, ReportCode, LabId, GeneratedBy, GeneratedByRole, GeneratedOn, AsOfOn, OutputType, AppliedFilters, RowCountTotal, DurationMs)
VALUES (@RunId, @ReportCode, @LabId, @GeneratedBy, @GeneratedByRole, @GeneratedOn, @AsOfOn, @OutputType, @AppliedFilters, @RowCount, @DurationMs);";

        try
        {
            await using var con = OpenLab(metadata.LabId);
            await con.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 30 };
            cmd.Parameters.AddWithValue("@RunId", metadata.RunId);
            cmd.Parameters.AddWithValue("@ReportCode", metadata.ReportCode);
            cmd.Parameters.AddWithValue("@LabId", metadata.LabId);
            cmd.Parameters.AddWithValue("@GeneratedBy", metadata.GeneratedBy ?? string.Empty);
            cmd.Parameters.AddWithValue("@GeneratedByRole", metadata.GeneratedByRole ?? string.Empty);
            cmd.Parameters.AddWithValue("@GeneratedOn", metadata.GeneratedOn);
            cmd.Parameters.AddWithValue("@AsOfOn", metadata.AsOf);
            cmd.Parameters.AddWithValue("@OutputType", outputType);
            cmd.Parameters.AddWithValue("@AppliedFilters", JsonSerializer.Serialize(metadata.AppliedFilters));
            cmd.Parameters.AddWithValue("@RowCount", rowCount);
            cmd.Parameters.AddWithValue("@DurationMs", durationMs);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (SqlException)
        {
            // The run log is audit metadata about a report that has ALREADY been produced
            // successfully. Failing the user's report because the audit insert failed would trade a
            // working report for a logging problem; the API's own error log still records the fault.
        }
    }

    // ==================================================================================
    // Metadata, org lookup, helpers
    // ==================================================================================

    private async Task<ArReportRunMetadata> BuildMetadataAsync(ArActivityReportFilter filter, CancellationToken ct)
    {
        var generatedOn = DateTime.UtcNow;
        var internalVisible = InternalNotesVisible(filter.Role);
        var metadata = new ArReportRunMetadata
        {
            ReportCode = ReportCode,
            ReportName = ReportName,
            RunId = $"RPT01-{filter.LabId}-{generatedOn:yyyyMMddHHmmss}-{Guid.NewGuid().ToString("N")[..6].ToUpperInvariant()}",
            LabId = filter.LabId,
            LabName = _labNamesById.TryGetValue(filter.LabId, out var labName) ? labName : $"Lab {filter.LabId}",
            GeneratedBy = filter.UserName,
            GeneratedByRole = filter.Role,
            GeneratedOn = generatedOn,
            AsOf = filter.AsOf ?? generatedOn,
            Grain = string.Equals(filter.Grain, "Line", StringComparison.OrdinalIgnoreCase) ? "Denial line item" : "Claim",
            RoleView = internalVisible ? "Internal Management" : "Client-facing (restricted)",
            InternalNotesVisible = internalVisible,
            AppliedFilters = BuildAppliedFilters(filter),
            // FR-011: name the dependency rather than leaving a measure quietly missing.
            UnavailableMeasures =
            [
                "Contact method is blank for activities recorded before the note form captured it (dbo.DenialClaimNotes.ContactMethod).",
                "Balance snapshot falls back to the current outstanding balance for activities recorded before per-event capture; those rows are marked.",
                "Action completion is event-backed only where dbo.DenialActionCompletionEvent has a row; otherwise it reflects the current task-board flag."
            ]
        };

        try
        {
            var sql = $@"
SELECT TOP (1) RunId, CreatedOn
FROM LRNMaster.dbo.DenialAnalysisRunLog
WHERE {LabScopeSql("LabId")}
ORDER BY CreatedOn DESC;";
            await using var con = OpenMaster();
            await con.OpenAsync(ct);
            await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 30 };
            AddLabScopeParams(cmd, filter.LabId);
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            if (await rd.ReadAsync(ct))
            {
                metadata.DataRefreshRunId = GetString(rd, "RunId");
                metadata.DataRefreshedOn = GetDate(rd, "CreatedOn");
            }
        }
        catch (SqlException)
        {
            // NFR-004 wants the freshness stamp displayed, but a report is still valid without it.
            // The UI shows "Not available" rather than the whole run failing on a metadata lookup.
        }

        return metadata;
    }

    private static List<ArAppliedFilter> BuildAppliedFilters(ArActivityReportFilter f)
    {
        var items = new List<ArAppliedFilter>
        {
            // ToDate is held as an EXCLUSIVE upper bound internally; show the inclusive instant the
            // user actually chose, or the filter chip contradicts the date picker.
            new() { Label = "Activity period", Value = $"{f.FromDate:dd MMM yyyy HH:mm} to {f.ToDate!.Value.AddSeconds(-1):dd MMM yyyy HH:mm}" },
            new() { Label = "Report grain", Value = string.Equals(f.Grain, "Line", StringComparison.OrdinalIgnoreCase) ? "Denial line item" : "Claim" },
            new() { Label = "Latest Activity Only", Value = f.LatestOnly ? "Yes" : "No" }
        };
        void Add(string label, string value)
        {
            if (!string.IsNullOrWhiteSpace(value)) items.Add(new ArAppliedFilter { Label = label, Value = value.Trim() });
        }
        Add("AR analyst", f.Analyst);
        Add("AR manager", f.Manager);
        Add("Team", f.Team);
        Add("Payer", f.Payer);
        Add("Denial classification", f.DenialClassification);
        Add("Action category", f.ActionCategory);
        Add("Task", f.Task);
        Add("Workflow status", f.WorkflowStatus);
        Add("Reporting bucket", f.ReportingBucket);
        Add("AR aging bucket", f.AgingBucket);
        Add("Follow-up due status", f.DueStatus);
        Add("Escalation status", f.EscalationStatus);
        Add("Activity type", f.ActivityType);
        Add("Contact method", f.ContactMethod);
        Add("Update source", f.UpdateSource);
        Add("Search", f.SearchText);
        return items;
    }

    /// <summary>
    /// The analysts a manager/team filter resolves to. Null means "no analyst restriction"; an
    /// empty list means the filter matched nobody, which the caller reports as an explicit empty
    /// state rather than as a silently empty grid.
    /// </summary>
    private static List<string>? ResolveAnalystScope(ArActivityReportFilter filter, IReadOnlyList<ArAnalystOrg> org)
    {
        var hasManager = !string.IsNullOrWhiteSpace(filter.Manager);
        var hasTeam = !string.IsNullOrWhiteSpace(filter.Team);
        if (!hasManager && !hasTeam) return null;

        return org
            .Where(x => (!hasManager || string.Equals(x.ManagerUserName, filter.Manager, StringComparison.OrdinalIgnoreCase))
                     && (!hasTeam || string.Equals(x.TeamName, filter.Team, StringComparison.OrdinalIgnoreCase)))
            .Select(x => x.UserName)
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static Dictionary<string, ArAnalystOrg> BuildOrgLookup(IReadOnlyList<ArAnalystOrg> org)
    {
        var map = new Dictionary<string, ArAnalystOrg>(StringComparer.OrdinalIgnoreCase);
        foreach (var row in org)
        {
            if (!string.IsNullOrWhiteSpace(row.UserName)) map[row.UserName] = row;
            if (!string.IsNullOrWhiteSpace(row.DisplayName)) map.TryAdd(row.DisplayName, row);
        }
        return map;
    }

    /// <summary>
    /// AR Reporting GAP-2. AssignedTo on a claim is free text; the reporting-to relationship lives
    /// in LRNMaster.dbo.LabUsers. Columns are probed because not every environment has the manager
    /// and team columns yet - where they are absent the report shows no manager rather than failing.
    /// The directory is estate-wide, so it is cached once rather than per lab.
    /// </summary>
    private async Task<IReadOnlyList<ArAnalystOrg>> GetAnalystOrgAsync(CancellationToken ct)
    {
        const string cacheKey = "ar-report-analyst-org";
        if (OrgCache.TryGetValue(cacheKey, out var cached) && DateTime.UtcNow - cached.CachedOnUtc < OrgCacheDuration)
            return cached.Rows;

        var rows = new List<ArAnalystOrg>();
        try
        {
            await using var con = OpenMaster();
            await con.OpenAsync(ct);
            var columns = await GetColumnSetAsync(con, "dbo.LabUsers", ct);
            if (!columns.Contains("UserName"))
            {
                OrgCache[cacheKey] = (DateTime.UtcNow, rows);
                return rows;
            }

            var idColumn = new[] { "LabUserID", "LabUserId", "UserID", "UserId", "Id" }.FirstOrDefault(columns.Contains) ?? "LabUserID";
            var managerColumn = new[] { "ManagerUserID", "ManagerUserId", "ManagerId", "ReportsToUserID" }.FirstOrDefault(columns.Contains);
            var teamColumn = new[] { "TeamName", "Team", "TeamCode" }.FirstOrDefault(columns.Contains);
            var displayExpr = columns.Contains("FirstName") || columns.Contains("LastName")
                ? "NULLIF(LTRIM(RTRIM(CONCAT(ISNULL(u.FirstName,''),' ',ISNULL(u.LastName,'')))),'')"
                : "NULL";
            var managerExpr = managerColumn is null ? "''" : "ISNULL(m.UserName,'')";
            var managerJoin = managerColumn is null ? string.Empty : $"LEFT JOIN dbo.LabUsers m WITH (NOLOCK) ON m.{idColumn} = u.{managerColumn}";
            var teamExpr = teamColumn is null ? "''" : $"ISNULL(u.{teamColumn},'')";
            var activeFilter = columns.Contains("IsActive") ? "WHERE ISNULL(u.IsActive,1) = 1" : string.Empty;

            var sql = $@"
SELECT
    UserName        = ISNULL(u.UserName,''),
    DisplayName     = ISNULL(COALESCE({displayExpr}, u.UserName),''),
    ManagerUserName = {managerExpr},
    TeamName        = {teamExpr}
FROM dbo.LabUsers u WITH (NOLOCK)
{managerJoin}
{activeFilter};";

            await using var cmd = new SqlCommand(sql, con) { CommandTimeout = 60 };
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            while (await rd.ReadAsync(ct))
            {
                rows.Add(new ArAnalystOrg(
                    GetString(rd, "UserName"),
                    GetString(rd, "DisplayName"),
                    GetString(rd, "ManagerUserName"),
                    GetString(rd, "TeamName")));
            }
        }
        catch (SqlException)
        {
            // Manager/team is a decoration on every row, not the report's subject. If the master
            // directory is unreachable the activity detail is still correct and complete.
        }

        OrgCache[cacheKey] = (DateTime.UtcNow, rows);
        return rows;
    }

    internal static void Normalize(ArActivityReportFilter filter)
    {
        if (filter.LabId <= 0) throw new InvalidOperationException("LabId is required.");

        filter.Page = filter.Page <= 0 ? 1 : filter.Page;
        filter.PageSize = filter.PageSize <= 0
            ? (filter.IsExport ? MaxExportRows : 50)
            : Math.Clamp(filter.PageSize, 25, filter.IsExport ? MaxExportRows : 200);
        filter.Grain = string.Equals(filter.Grain, "Line", StringComparison.OrdinalIgnoreCase) ? "Line" : "Claim";
        filter.GroupBy = (filter.GroupBy ?? "none").Trim();

        var asOf = filter.AsOf ?? DateTime.Now;
        filter.AsOf = asOf;

        // Default window: the last 7 days of activity. The report is an activity log, so an
        // unbounded run is never what the user meant and would scan three event tables end to end.
        var from = filter.FromDate ?? asOf.Date.AddDays(-6);
        var to = filter.ToDate ?? asOf.Date;
        if (to < from) (from, to) = (to, from);

        // ToDate arrives as an inclusive calendar day from the UI. Convert it to an EXCLUSIVE upper
        // bound so an activity recorded at 16:40 on the last day is inside the range - a plain
        // "<= @ToDate" silently drops everything after midnight on the final day.
        var toExclusive = to.TimeOfDay == TimeSpan.Zero ? to.Date.AddDays(1) : to;
        if ((toExclusive - from).TotalDays > MaxRangeDays)
            throw new InvalidOperationException($"The activity period cannot exceed {MaxRangeDays} days. Narrow the date range, or export in batches.");

        filter.FromDate = from;
        filter.ToDate = toExclusive;
    }

    /// <summary>
    /// Spec section 2.6 / section 3.1: restricted internal notes and escalation content are excluded
    /// from unauthorized client-facing views and exports. Client Manager, Account Manager and Lab
    /// User are this application's client-facing roles.
    /// </summary>
    internal static bool InternalNotesVisible(string? role)
    {
        var token = new string((role ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        return !(token.Contains("CLIENTMANAGER") || token.Contains("ACCOUNTMANAGER") || token.Contains("LABUSER"));
    }

    private static string NormalizeUpdateSource(string? value)
    {
        var v = (value ?? string.Empty).Trim();
        return v.Equals("Excel", StringComparison.OrdinalIgnoreCase)
            || v.Equals("Upload", StringComparison.OrdinalIgnoreCase)
            || v.Equals("Excel Upload", StringComparison.OrdinalIgnoreCase)
            ? "Excel Upload"
            : "Application";
    }

    private static string NormalizeClaimId(string? claimId)
        => (claimId ?? string.Empty).Trim().Replace("CLM-", string.Empty, StringComparison.OrdinalIgnoreCase);

    private static void AddTextParam(SqlCommand cmd, string name, string? value)
        => cmd.Parameters.AddWithValue(name, (value ?? string.Empty).Trim());

    private static ArActivityEventRow ReadEventRow(IDataRecord r) => new()
    {
        ActivityId = GetString(r, "ActivityId"),
        SourceType = GetString(r, "SourceType"),
        ClaimId = GetString(r, "ClaimId"),
        LineItemId = GetString(r, "LineItemId"),
        EncounterNumber = GetString(r, "EncounterNumber"),
        CptCode = GetString(r, "CptCode"),
        DateOfService = GetDate(r, "DateOfService"),
        PayerName = GetString(r, "PayerName"),
        DenialCode = GetString(r, "DenialCode"),
        DenialClassification = GetString(r, "DenialClassification"),
        DenialReason = GetString(r, "DenialReason"),
        WorkflowStatus = GetString(r, "WorkflowStatus"),
        ReportingBucket = GetString(r, "ReportingBucket"),
        AgingBucket = GetString(r, "AgingBucket"),
        Priority = GetString(r, "Priority"),
        AnalystName = GetString(r, "AnalystName"),
        AssignedOn = GetDate(r, "AssignedOn"),
        AssignedBy = GetString(r, "AssignedBy"),
        ActivityDate = GetDate(r, "ActivityDate") ?? DateTime.MinValue,
        ActivityDateKey = GetString(r, "ActivityDateKey"),
        Author = GetString(r, "Author"),
        ActivityType = GetString(r, "ActivityType"),
        ContactMethod = GetString(r, "ContactMethod"),
        NoteText = GetString(r, "NoteText"),
        NoteMasked = GetBool(r, "IsInternalOnly"),
        PreviousStatus = GetString(r, "PreviousStatus"),
        NewStatus = GetString(r, "NewStatus"),
        StatusReason = GetString(r, "StatusReason"),
        ActionCategory = GetString(r, "ActionCategory"),
        Task = GetString(r, "TaskName"),
        ActionCompleted = GetBool(r, "ActionCompleted"),
        ActionCompletedOn = GetDate(r, "ActionCompletedOn"),
        ActionCompletedBy = GetString(r, "ActionCompletedBy"),
        ActionCompletedDateLabel = GetString(r, "ActionCompletedLabel"),
        ActionCompletionIsEvent = GetBool(r, "ActionCompletionIsEvent"),
        NextFollowUpDate = GetDate(r, "NextFollowUpDate"),
        FollowUpCategory = GetString(r, "FollowUpCategory"),
        OriginalFollowUpDate = GetDate(r, "OriginalFollowUpDate"),
        RescheduleCount = GetInt(r, "RescheduleCount"),
        DueStatus = GetString(r, "DueStatus"),
        Escalated = GetBool(r, "Escalated"),
        EscalationId = GetString(r, "EscalationId"),
        EscalationReason = GetString(r, "EscalationReason"),
        EscalationRecipient = GetString(r, "EscalationRecipient"),
        EscalationStatus = GetString(r, "EscalationStatus"),
        OriginalCharge = GetDecimal(r, "OriginalCharge"),
        BalanceSnapshot = GetDecimal(r, "BalanceSnapshot"),
        BalanceIsSnapshot = GetBool(r, "BalanceIsSnapshot"),
        UpdateSource = GetString(r, "UpdateSource"),
        UploadBatchId = GetString(r, "UploadBatchId"),
        RunId = GetString(r, "RunId"),
        CreatedBy = GetString(r, "CreatedBy")
    };

    private static async Task<HashSet<string>> GetColumnSetAsync(SqlConnection con, string tableName, CancellationToken ct)
    {
        var key = $"{con.Database}|{tableName}";
        if (ColumnSetCache.TryGetValue(key, out var cachedColumns)) return cachedColumns;

        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        const string sql = "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(@Table);";
        await using (var cmd = new SqlCommand(sql, con) { CommandTimeout = 30 })
        {
            cmd.Parameters.AddWithValue("@Table", tableName);
            await using var rd = await cmd.ExecuteReaderAsync(ct);
            while (await rd.ReadAsync(ct)) columns.Add(rd.GetString(0));
        }
        ColumnSetCache[key] = columns;
        return columns;
    }

    private static bool HasColumn(IDataRecord r, string name)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    private static string GetString(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToString(r[n]) ?? string.Empty : string.Empty;
    private static int GetInt(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToInt32(r[n]) : 0;
    private static decimal GetDecimal(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToDecimal(r[n]) : 0m;
    private static bool GetBool(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value && Convert.ToBoolean(r[n]);
    private static DateTime? GetDate(IDataRecord r, string n) => HasColumn(r, n) && r[n] != DBNull.Value ? Convert.ToDateTime(r[n]) : null;
}

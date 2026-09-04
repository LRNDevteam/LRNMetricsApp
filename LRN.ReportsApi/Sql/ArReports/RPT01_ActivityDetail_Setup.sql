/*
    RPT-01 — AR Follow-up Activity Detail
    Denial Workflow Management | AR Reporting Requirements v1.0 (2 Sep 2026)

    Run against EACH LAB database (not LRNMaster). Idempotent: safe to re-run.

    This script is the DBA-runnable form of what SqlArActivityReportRepository.EnsureReportObjectsAsync
    applies at runtime on first use of the report. Running it during a maintenance window means the
    first user of the report does not pay for the DDL.

    WHAT THIS COVERS
      Schema Pass A (dbo.DenialStatusBucketMap, dbo.DenialAgingBucket, UpdateSource/UploadBatchId
      stamping) already ships in SqlDenialWorkflowRepository.EnsureClaimSupportTablesAsync. This
      script adds only what RPT-01's own required column groups need on top of that:

        Requirement (spec §3.1 "Required detail columns")   Object added here
        ---------------------------------------------------------------------------------------
        Activity > contact method                           DenialClaimNotes.ContactMethod,
                                                            DenialTaskHistory.ContactMethod,
                                                            dbo.DenialActivityContactMethod (lookup)
        Follow-up > category                                DenialClaimNotes.FollowUpCategory,
                                                            dbo.DenialFollowUpCategoryMaster (lookup)
        Financial > outstanding balance SNAPSHOT            DenialClaimNotes.BalanceSnapshot,
                                                            DenialTaskHistory.BalanceSnapshot,
                                                            DenialClaimEscalations.BalanceSnapshot
        Action > completed date/time, completed by          dbo.DenialActionCompletionEvent
        Role-based visibility (spec §2.6, §3.1 caveats)     DenialClaimNotes.IsInternalOnly
        Audit source on escalation events (FR-012)          DenialClaimEscalations.UpdateSource /
                                                            .UploadBatchId
        As-of context + run id (FR-001, NFR-003)            dbo.DenialReportRunLog
        Saved views (spec §2.6)                             dbo.DenialReportSavedView
        Report catalog / active-inactive state              dbo.DenialReportCatalog

    WHY THE BALANCE COLUMNS ARE NULLABLE AND START EMPTY
      The readiness audit's finding stands: before this change only a CURRENT balance existed, so a
      historical activity row could not carry the balance as it stood at the time. These columns are
      populated from the write path going forward. RPT-01 falls back to the current task-board
      balance for rows created before this ships and LABELS that fallback in the UI and export --
      it does not silently present a current figure as a snapshot.

    WHY DenialActionCompletionEvent EXISTS
      DenialTaskBoard.ActionCompleted is a bit and DateCompleted a date, both overwritten in place:
      there is no completed-by, no timestamp and no history. RPT-01 requires "action completed
      date/time" as a detail column and "actions completed" as a summary measure. This table is the
      immutable event the spec asks for (§2.5 "Action Completed": completed flag + completed user +
      completion timestamp). RPT-01 reads it when rows exist and falls back to the task-board flag
      otherwise, again labelled. It is also the object RPT-04 is blocked on.

    NOT IN SCOPE OF THIS SCRIPT
      GAP-4 (escalation response linkage), GAP-6 capture job, GAP-7 (SLA config/instance) --
      those belong to RPT-07 / RPT-02 / RPT-09 respectively.
*/

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   1. Activity-event column additions.
   All nullable with no default expression (or a bit with a default), so every ALTER here is
   metadata-only in SQL Server -- no table rewrite, no long schema-modification lock, even on a
   large DenialTaskHistory.
   ===================================================================================== */

IF OBJECT_ID('dbo.DenialClaimNotes', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimNotes', 'ContactMethod') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD ContactMethod nvarchar(60) NULL;

    IF COL_LENGTH('dbo.DenialClaimNotes', 'FollowUpCategory') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD FollowUpCategory nvarchar(80) NULL;

    IF COL_LENGTH('dbo.DenialClaimNotes', 'BalanceSnapshot') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD BalanceSnapshot decimal(18,2) NULL;

    -- Client-facing views must exclude internal-only notes (spec §2.6 Role-based visibility and
    -- §3.1 "Internal notes must be excluded or masked for client-facing roles"). Existing notes
    -- default to 0 (shareable): flipping the default the other way would hide every historical
    -- note from Client/Account Managers overnight without anyone having classified them.
    IF COL_LENGTH('dbo.DenialClaimNotes', 'IsInternalOnly') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD IsInternalOnly bit NOT NULL
            CONSTRAINT DF_DenialClaimNotes_IsInternalOnly DEFAULT 0;
END;
GO

IF OBJECT_ID('dbo.DenialTaskHistory', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskHistory', 'ContactMethod') IS NULL
        ALTER TABLE dbo.DenialTaskHistory ADD ContactMethod nvarchar(60) NULL;

    IF COL_LENGTH('dbo.DenialTaskHistory', 'BalanceSnapshot') IS NULL
        ALTER TABLE dbo.DenialTaskHistory ADD BalanceSnapshot decimal(18,2) NULL;
END;
GO

IF OBJECT_ID('dbo.DenialClaimEscalations', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimEscalations', 'UpdateSource') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD UpdateSource nvarchar(20) NULL;

    IF COL_LENGTH('dbo.DenialClaimEscalations', 'UploadBatchId') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD UploadBatchId nvarchar(100) NULL;

    IF COL_LENGTH('dbo.DenialClaimEscalations', 'BalanceSnapshot') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations ADD BalanceSnapshot decimal(18,2) NULL;

    -- DenialClaimNotes and DenialTaskBoard both carry a persisted normalized claim id; escalations
    -- did not, so the report had to normalize per row (non-sargable). This table is small enough
    -- that adding the persisted computed column is cheap.
    IF COL_LENGTH('dbo.DenialClaimEscalations', 'ClaimIdNormalized') IS NULL
        ALTER TABLE dbo.DenialClaimEscalations
            ADD ClaimIdNormalized AS CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(ClaimId, ''))), 'CLM-', '')) PERSISTED;
END;
GO

/* =====================================================================================
   2. Indexes for the activity spine.
   RPT-01 filters every source by LabId + event date. None of the three tables was indexed that
   way (they are indexed for per-claim reads), so a 90-day report scanned all three end to end.
   Wrapped in TRY/CATCH like the rest of the runtime DDL in this codebase: some databases carry
   auto-created statistics under the same name (error 1913).
   ===================================================================================== */

IF OBJECT_ID('dbo.DenialTaskHistory', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskHistory_Lab_ActionDate' AND object_id = OBJECT_ID('dbo.DenialTaskHistory'))
BEGIN
    BEGIN TRY
        CREATE NONCLUSTERED INDEX IX_DenialTaskHistory_Lab_ActionDate
            ON dbo.DenialTaskHistory (LabId, ActionDate DESC)
            INCLUDE (HistoryId, TaskID, UniqueTrackId, ActionType, OldStatus, NewStatus, OldAssignedTo, NewAssignedTo, ActionBy);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
    END CATCH
END;
GO

IF OBJECT_ID('dbo.DenialClaimNotes', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialClaimNotes_Lab_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialClaimNotes'))
BEGIN
    BEGIN TRY
        CREATE NONCLUSTERED INDEX IX_DenialClaimNotes_Lab_CreatedOn
            ON dbo.DenialClaimNotes (LabId, CreatedOn DESC)
            INCLUDE (NoteId, ClaimId, TaskId, CptCode, NoteLevel, Status, NextFollowUpDate, CreatedBy, IsDeleted);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
    END CATCH
END;
GO

IF OBJECT_ID('dbo.DenialClaimEscalations', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialClaimEscalations_Lab_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialClaimEscalations'))
BEGIN
    BEGIN TRY
        CREATE NONCLUSTERED INDEX IX_DenialClaimEscalations_Lab_CreatedOn
            ON dbo.DenialClaimEscalations (LabId, CreatedOn DESC)
            INCLUDE (EscalationId, ClaimId, TaskId, CptCode, EscalationLevel, EscalationReason, EscalatedTo, Status, CreatedBy, IsDeleted);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (1911, 1913, 2714) THROW;
    END CATCH
END;
GO

/* =====================================================================================
   3. Configuration lookups.
   Spec §2.4/§2.6/§7: these are configuration rows AR operations edits, never constants in report
   code. Seeded with a first draft for review.
   ===================================================================================== */

IF OBJECT_ID('dbo.DenialActivityContactMethod', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialActivityContactMethod
    (
        ContactMethodId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialActivityContactMethod PRIMARY KEY,
        MethodName      nvarchar(60)  NOT NULL,
        SortOrder       int           NOT NULL CONSTRAINT DF_DenialActivityContactMethod_Sort DEFAULT 100,
        IsActive        bit           NOT NULL CONSTRAINT DF_DenialActivityContactMethod_Active DEFAULT 1,
        CreatedOn       datetime2(0)  NOT NULL CONSTRAINT DF_DenialActivityContactMethod_CreatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialActivityContactMethod_Name ON dbo.DenialActivityContactMethod (MethodName);

    INSERT INTO dbo.DenialActivityContactMethod (MethodName, SortOrder) VALUES
        ('Payer Portal',      10),
        ('Phone',             20),
        ('Fax',               30),
        ('Email',             40),
        ('Mail / Letter',     50),
        ('Clearinghouse',     60),
        ('Application',       70),
        ('Batch Import',      80),
        ('System',            90),
        ('Not Recorded',     100);
END;
GO

IF OBJECT_ID('dbo.DenialFollowUpCategoryMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialFollowUpCategoryMaster
    (
        FollowUpCategoryId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialFollowUpCategoryMaster PRIMARY KEY,
        CategoryName       nvarchar(80) NOT NULL,
        -- Spec §3.5: payer, escalation and documentation follow-up compliance are reported
        -- separately, so the category has to say which of those a schedule instance belongs to.
        ComplianceGroup    nvarchar(40) NOT NULL CONSTRAINT DF_DenialFollowUpCategoryMaster_Group DEFAULT 'Payer',
        SortOrder          int          NOT NULL CONSTRAINT DF_DenialFollowUpCategoryMaster_Sort DEFAULT 100,
        IsActive           bit          NOT NULL CONSTRAINT DF_DenialFollowUpCategoryMaster_Active DEFAULT 1,
        CreatedOn          datetime2(0) NOT NULL CONSTRAINT DF_DenialFollowUpCategoryMaster_CreatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialFollowUpCategoryMaster_Name ON dbo.DenialFollowUpCategoryMaster (CategoryName);

    INSERT INTO dbo.DenialFollowUpCategoryMaster (CategoryName, ComplianceGroup, SortOrder) VALUES
        ('Payer Follow-up',         'Payer',         10),
        ('Appeal Follow-up',        'Payer',         20),
        ('Rebill Follow-up',        'Payer',         30),
        ('Documentation Follow-up', 'Documentation', 40),
        ('Escalation Response',     'Escalation',    50),
        ('Write-off Approval',      'Escalation',    60),
        ('Closure Verification',    'Payer',         70);
END;
GO

/* =====================================================================================
   4. Action completion events (spec §2.5 "Action Completed").
   Append-only. A correction is a new row with AmendsCompletionEventId set, never an UPDATE --
   spec §3.4: "An action completion event is immutable; later correction creates an audited
   amendment rather than silently replacing the timestamp."
   ===================================================================================== */

IF OBJECT_ID('dbo.DenialActionCompletionEvent', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialActionCompletionEvent
    (
        ActionCompletionEventId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialActionCompletionEvent PRIMARY KEY,
        LabId                   int            NOT NULL,
        ClaimId                 nvarchar(150)  NOT NULL,
        TaskId                  nvarchar(100)  NULL,
        UniqueTrackId           nvarchar(450)  NULL,
        CptCode                 nvarchar(50)   NULL,
        ActionCategory          nvarchar(500)  NULL,
        [Task]                  nvarchar(500)  NULL,
        -- The action-specific display label the spec asks for: Appeal completed -> "Appeal Date",
        -- Rebill -> "Rebill Date", Write-off -> "Write-off Completion Date", Medical records ->
        -- "Documentation Submission Date". Stored so the label cannot drift from the event.
        CompletedDateLabel      nvarchar(80)   NULL,
        IsCompleted             bit            NOT NULL CONSTRAINT DF_DenialActionCompletionEvent_IsCompleted DEFAULT 1,
        CompletedBy             nvarchar(256)  NULL,
        CompletedOn             datetime2(0)   NOT NULL CONSTRAINT DF_DenialActionCompletionEvent_CompletedOn DEFAULT SYSUTCDATETIME(),
        CompletionNote          nvarchar(max)  NULL,
        StatusAtCompletion      nvarchar(100)  NULL,
        BalanceSnapshot         decimal(18,2)  NULL,
        UpdateSource            nvarchar(20)   NULL,
        UploadBatchId           nvarchar(100)  NULL,
        RunId                   nvarchar(100)  NULL,
        AmendsCompletionEventId bigint         NULL,
        CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_DenialActionCompletionEvent_CreatedOn DEFAULT SYSUTCDATETIME(),
        ClaimIdNormalized AS CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(ClaimId, ''))), 'CLM-', '')) PERSISTED
    );
    CREATE INDEX IX_DenialActionCompletionEvent_Lab_CompletedOn
        ON dbo.DenialActionCompletionEvent (LabId, CompletedOn DESC)
        INCLUDE (ClaimId, TaskId, CptCode, ActionCategory, CompletedBy, IsCompleted);
    CREATE INDEX IX_DenialActionCompletionEvent_Lab_Task
        ON dbo.DenialActionCompletionEvent (LabId, TaskId, CompletedOn DESC);
    CREATE INDEX IX_DenialActionCompletionEvent_Lab_Claim
        ON dbo.DenialActionCompletionEvent (LabId, ClaimIdNormalized, CompletedOn DESC);
END;
GO

/* =====================================================================================
   5. Report run log (FR-001 report run metadata, NFR-003 auditability).
   One row per executed report run. The run id it issues is what the on-screen header and the
   Excel export both display, so an exported workbook can be traced back to the exact filter set
   and as-of instant that produced it.
   ===================================================================================== */

IF OBJECT_ID('dbo.DenialReportRunLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialReportRunLog
    (
        ReportRunLogId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialReportRunLog PRIMARY KEY,
        RunId           nvarchar(60)  NOT NULL,
        ReportCode      nvarchar(20)  NOT NULL,
        LabId           int           NOT NULL,
        GeneratedBy     nvarchar(256) NOT NULL,
        GeneratedByRole nvarchar(100) NULL,
        GeneratedOn     datetime2(0)  NOT NULL CONSTRAINT DF_DenialReportRunLog_GeneratedOn DEFAULT SYSUTCDATETIME(),
        AsOfOn          datetime2(0)  NULL,
        OutputType      nvarchar(20)  NOT NULL CONSTRAINT DF_DenialReportRunLog_OutputType DEFAULT 'Screen',
        AppliedFilters  nvarchar(max) NULL,
        RowCountTotal   int           NOT NULL CONSTRAINT DF_DenialReportRunLog_RowCount DEFAULT 0,
        DurationMs      int           NOT NULL CONSTRAINT DF_DenialReportRunLog_DurationMs DEFAULT 0
    );
    CREATE INDEX IX_DenialReportRunLog_Report_GeneratedOn ON dbo.DenialReportRunLog (ReportCode, LabId, GeneratedOn DESC);
    CREATE UNIQUE INDEX UX_DenialReportRunLog_RunId ON dbo.DenialReportRunLog (RunId);
END;
GO

/* =====================================================================================
   6. Saved views (spec §2.6: "Users can save filter, sort, grouping, and selected-column
   preferences within their authorization scope").
   Scoped to (ReportCode, LabId, OwnerUserName) -- a saved view never crosses a lab boundary, so
   it cannot become a way to see a lab the owner is not authorized for.
   ===================================================================================== */

IF OBJECT_ID('dbo.DenialReportSavedView', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialReportSavedView
    (
        SavedViewId   int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialReportSavedView PRIMARY KEY,
        ReportCode    nvarchar(20)  NOT NULL,
        LabId         int           NOT NULL,
        OwnerUserName nvarchar(256) NOT NULL,
        ViewName      nvarchar(120) NOT NULL,
        FiltersJson   nvarchar(max) NOT NULL,
        IsDefault     bit           NOT NULL CONSTRAINT DF_DenialReportSavedView_IsDefault DEFAULT 0,
        CreatedOn     datetime2(0)  NOT NULL CONSTRAINT DF_DenialReportSavedView_CreatedOn DEFAULT SYSUTCDATETIME(),
        UpdatedOn     datetime2(0)  NOT NULL CONSTRAINT DF_DenialReportSavedView_UpdatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialReportSavedView_Owner_Name
        ON dbo.DenialReportSavedView (ReportCode, LabId, OwnerUserName, ViewName);
END;
GO

/* =====================================================================================
   7. Report catalog.
   Which AR reports exist and which are live. RPT-01 ships Active; everything else is Inactive
   until its own build lands, so the Reports screen is driven by data rather than by a hard-coded
   "coming soon" block that has to be edited for every release.
   Statuses: Active | Inactive | Blocked. "Blocked" carries the readiness audit's verdict for
   RPT-04 and RPT-09, whose source events do not exist yet.
   ===================================================================================== */

IF OBJECT_ID('dbo.DenialReportCatalog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialReportCatalog
    (
        ReportCatalogId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialReportCatalog PRIMARY KEY,
        ReportCode      nvarchar(20)  NOT NULL,
        ReportName      nvarchar(160) NOT NULL,
        [Grain]         nvarchar(120) NULL,
        Purpose         nvarchar(500) NULL,
        [Status]        nvarchar(20)  NOT NULL CONSTRAINT DF_DenialReportCatalog_Status DEFAULT 'Inactive'
            CONSTRAINT CK_DenialReportCatalog_Status CHECK ([Status] IN ('Active', 'Inactive', 'Blocked')),
        StatusNote      nvarchar(400) NULL,
        RouteKey        nvarchar(60)  NULL,
        SortOrder       int           NOT NULL CONSTRAINT DF_DenialReportCatalog_Sort DEFAULT 100,
        UpdatedOn       datetime2(0)  NOT NULL CONSTRAINT DF_DenialReportCatalog_UpdatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE UNIQUE INDEX UX_DenialReportCatalog_Code ON dbo.DenialReportCatalog (ReportCode);
END;
GO

MERGE dbo.DenialReportCatalog AS target
USING (VALUES
    ('RPT-01', 'AR Follow-up Activity Detail',                  'One row per qualifying activity event',            'Auditable record of every meaningful follow-up activity performed on a claim or denial line item.',        'Active',   'Live. Claim and denial-line grain, Latest Activity Only, Excel export with reconciliation totals.', 'rpt01',  10),
    ('RPT-02', 'AR Analyst Productivity Summary',               'One row per analyst per reporting period',         'Analyst output, workflow progression and action completion without rewarding repeated notes.',             'Inactive', 'Planned. Opening/closing workload needs the inventory snapshot job (GAP-6) to have accrued history.', 'rpt02', 20),
    ('RPT-03', 'AR Analyst Workload and Capacity',              'One row per analyst as of the selected date',      'Whether denial workload is distributed appropriately, and who carries stale or complex backlogs.',          'Inactive', 'Planned. Current-state only; the Capacity column group is an optional MVP enhancement.',              'rpt03', 30),
    ('RPT-04', 'Action Completion',                             'One row per completed action or task event',       'When appeals, rebills, write-offs, documentation submissions and payer follow-ups were completed.',         'Blocked',  'Blocked until action completion events accrue. RPT-01 now writes dbo.DenialActionCompletionEvent.',   'rpt04', 40),
    ('RPT-05', 'Follow-up Due and Compliance',                  'One row per follow-up schedule instance',          'The daily AR control plan, and whether follow-ups are completed on time.',                                  'Inactive', 'Planned. Needs follow-up schedule history and completion linkage (GAP-5).',                           'rpt05', 50),
    ('RPT-06', 'Denial Work Progress by Classification/Action', 'Aggregated by dimension and reporting bucket',     'Movement of denial inventory through Open, Active, Pending, Escalated and Closed buckets.',                 'Inactive', 'Planned. Movement measures need point-in-time snapshots (GAP-6).',                                    'rpt06', 60),
    ('RPT-07', 'Escalation Response and Rework',                'One row per escalation cycle',                     'Clarification delays, manager response, escalation aging and work returned for rework.',                    'Inactive', 'Planned. Needs response-to-escalation linkage (GAP-4); re-escalation makes timestamp inference unsafe.', 'rpt07', 70),
    ('RPT-08', 'Closure and Outcome',                           'One row per closed claim or denial line',          'How completed follow-up work ended, separating operational closure from verified financial outcome.',       'Inactive', 'Planned. Operational half is buildable now; verified financial measures await adjudication data.',    'rpt08', 80),
    ('RPT-09', 'Operational SLA',                               'One row per SLA measurement instance',             'Whether key workflow milestones complete within configurable operational service-level targets.',           'Blocked',  'Blocked on versioned SLA configuration and per-item measurement instances (GAP-7).',                  'rpt09', 90)
) AS source (ReportCode, ReportName, [Grain], Purpose, [Status], StatusNote, RouteKey, SortOrder)
    ON target.ReportCode = source.ReportCode
WHEN MATCHED THEN UPDATE SET
    target.ReportName = source.ReportName,
    target.[Grain]    = source.[Grain],
    target.Purpose    = source.Purpose,
    target.RouteKey   = source.RouteKey,
    target.SortOrder  = source.SortOrder,
    target.UpdatedOn  = SYSUTCDATETIME()
    -- Status and StatusNote are deliberately NOT overwritten on re-run: once operations flips a
    -- report Active or Inactive for a lab, a redeploy of this script must not undo that.
WHEN NOT MATCHED THEN INSERT (ReportCode, ReportName, [Grain], Purpose, [Status], StatusNote, RouteKey, SortOrder)
    VALUES (source.ReportCode, source.ReportName, source.[Grain], source.Purpose, source.[Status], source.StatusNote, source.RouteKey, source.SortOrder);
GO

PRINT 'RPT-01 AR Follow-up Activity Detail: schema ready.';
GO

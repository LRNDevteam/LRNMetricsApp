/* ============================================================================
   RUN AGAINST: EACH LAB DATABASE (NWL_LRN, Augustus_LRN, Certus_LRN, Cove, etc.)
   Run once per lab. RE-RUNNABLE and non-destructive - every statement is
   IF-NOT-EXISTS / IF-COLUMN-NOT-EXISTS guarded.

   Canonical source: LRN.ReportsApi\Sql\DenialDashboardSnapshot_Setup.sql
   (kept in step with SqlDenialDashboardSnapshotRepository.SchemaStatements,
   which also creates these objects lazily on first use - this script exists
   for a reviewable, versioned record and for DBAs who want to apply it ahead
   of a deploy rather than relying on lazy creation).
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

/* ----------------------------------------------------------------------------
   0) dbo.DenialInsight - safety net for the AR Manager inline-edit feature
      (Observations / Responsible Person / Discussion Date / ETA).

   These columns should already exist in every lab's dbo.DenialInsight (the
   table has carried them since before this change - DenialInsightBuilder
   has always written blanks into them). This block is defensive only: the
   write path (SqlDenialDashboardRepository.UpdateInsightDetailsAsync) checks
   which columns actually exist before writing to them, and SILENTLY skips
   any column that is missing rather than erroring - so a lab database that
   is missing one of these columns would show the Save button succeed while
   that one field quietly never persists. Running this block guarantees that
   cannot happen.
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialInsight', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialInsight', 'Feedback') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialInsight ADD Feedback NVARCHAR(MAX) NULL;
        PRINT 'Added dbo.DenialInsight.Feedback';
    END;

    IF COL_LENGTH('dbo.DenialInsight', 'Responsibility') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialInsight ADD Responsibility NVARCHAR(200) NULL;
        PRINT 'Added dbo.DenialInsight.Responsibility';
    END;

    IF COL_LENGTH('dbo.DenialInsight', 'DiscussionDate') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialInsight ADD DiscussionDate DATE NULL;
        PRINT 'Added dbo.DenialInsight.DiscussionDate';
    END;

    IF COL_LENGTH('dbo.DenialInsight', 'ETA') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialInsight ADD ETA NVARCHAR(50) NULL;
        PRINT 'Added dbo.DenialInsight.ETA';
    END;

    IF COL_LENGTH('dbo.DenialInsight', 'ResponsibilityReviewer') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialInsight ADD ResponsibilityReviewer NVARCHAR(200) NULL;
        PRINT 'Added dbo.DenialInsight.ResponsibilityReviewer';
    END;

    IF COL_LENGTH('dbo.DenialInsight', 'AssignedTo') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialInsight ADD AssignedTo NVARCHAR(200) NULL;
        PRINT 'Added dbo.DenialInsight.AssignedTo';
    END;
END
ELSE
BEGIN
    PRINT 'dbo.DenialInsight does not exist in this database - nothing to check. It is created by LRN.DenialDatabaseWorker on its next successful run for this lab.';
END;
GO

/* ----------------------------------------------------------------------------
   1) dbo.DenialDashboardSnapshot
   Weekly, monthly and on-demand Excel snapshots of the Denial Dashboard
   (Monthly Summary + Weekly Summary + Denial Insight - the same workbook
   "Download Excel" already produces). Past retention (4 active per period
   type, configurable via LRN.ReportsApi's DenialDashboardSnapshots:*
   settings) snapshots are archived (IsArchived=1), never deleted.

   NOTE: this is a SEPARATE table from dbo.DenialSummarySnapshot (a different
   page's snapshots, see DenialSummary_Setup.sql) - do not confuse the two.

   Built by: LabMetricsDashboard\Services\DenialDashboard\DenialDashboardSnapshotScheduler.cs
             (workbook) + LRN.ReportsApi\Services\DenialDashboardSnapshotService.cs (storage/retention)
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.DenialDashboardSnapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialDashboardSnapshot
    (
        SnapshotId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialDashboardSnapshot PRIMARY KEY CLUSTERED,
        LabId       INT             NOT NULL,
        PeriodType  NVARCHAR(20)    NOT NULL,
        PeriodStart DATE            NOT NULL,
        PeriodEnd   DATE            NOT NULL,
        FileName    NVARCHAR(260)   NOT NULL,
        Content     VARBINARY(MAX)  NOT NULL,   -- the .xlsx
        SizeBytes   BIGINT          NOT NULL,
        IsArchived  BIT             NOT NULL CONSTRAINT DF_DenialDashboardSnapshot_IsArchived DEFAULT 0,
        ArchivedOn  DATETIME2(0)    NULL,
        CreatedOn   DATETIME2(0)    NOT NULL CONSTRAINT DF_DenialDashboardSnapshot_CreatedOn DEFAULT SYSUTCDATETIME(),
        CreatedBy   NVARCHAR(200)   NULL,
        CONSTRAINT CK_DenialDashboardSnapshot_PeriodType CHECK (PeriodType IN (N'Weekly', N'Monthly', N'OnDemand'))
    );
    PRINT 'Created dbo.DenialDashboardSnapshot';
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_DenialDashboardSnapshot_Period' AND object_id = OBJECT_ID('dbo.DenialDashboardSnapshot'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_DenialDashboardSnapshot_Period
    ON dbo.DenialDashboardSnapshot (LabId, PeriodType, PeriodStart)
    WHERE PeriodType IN (N'Weekly', N'Monthly');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialDashboardSnapshot_List' AND object_id = OBJECT_ID('dbo.DenialDashboardSnapshot'))
    CREATE NONCLUSTERED INDEX IX_DenialDashboardSnapshot_List
    ON dbo.DenialDashboardSnapshot (LabId, IsArchived, PeriodStart DESC)
    INCLUDE (PeriodType, PeriodEnd, FileName, SizeBytes, ArchivedOn, CreatedOn, CreatedBy);
GO

PRINT 'Lab database Denial Workflow objects are up to date.';
GO

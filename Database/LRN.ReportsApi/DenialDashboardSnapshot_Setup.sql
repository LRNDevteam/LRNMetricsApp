/* ============================================================================
   Denial Dashboard snapshots (run in EACH lab database)

     dbo.DenialDashboardSnapshot   Weekly, monthly and on-demand Excel snapshots of the Denial
                                   Dashboard (Monthly Summary + Weekly Summary + Denial Insight -
                                   the same workbook "Download Excel" already produces). Past
                                   retention they are archived, never deleted. Sibling to
                                   dbo.DenialSummarySnapshot (a different page's snapshots) - same
                                   shape, separate table on purpose, see DenialDashboardSnapshot_Setup.

   RE-RUNNABLE and non-destructive. Optional: the Reports API creates the same objects on
   first use (SqlDenialDashboardSnapshotRepository.SchemaStatements - keep the two in step).
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.DenialDashboardSnapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialDashboardSnapshot
    (
        SnapshotId  bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialDashboardSnapshot PRIMARY KEY CLUSTERED,
        LabId       int             NOT NULL,
        PeriodType  nvarchar(20)    NOT NULL,
        PeriodStart date            NOT NULL,
        PeriodEnd   date            NOT NULL,
        FileName    nvarchar(260)   NOT NULL,
        Content     varbinary(max)  NOT NULL,   -- the .xlsx
        SizeBytes   bigint          NOT NULL,
        IsArchived  bit             NOT NULL CONSTRAINT DF_DenialDashboardSnapshot_IsArchived DEFAULT 0,
        ArchivedOn  datetime2(0)    NULL,
        CreatedOn   datetime2(0)    NOT NULL CONSTRAINT DF_DenialDashboardSnapshot_CreatedOn DEFAULT SYSUTCDATETIME(),
        CreatedBy   nvarchar(200)   NULL,
        CONSTRAINT CK_DenialDashboardSnapshot_PeriodType CHECK (PeriodType IN (N'Weekly', N'Monthly', N'OnDemand'))
    );
    PRINT 'Created dbo.DenialDashboardSnapshot';
END;
GO

-- One weekly and one monthly snapshot per period, however many instances run the scheduler.
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

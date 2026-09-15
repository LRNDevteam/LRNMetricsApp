/* ============================================================================
   Denial Summary - observations and snapshots (run in EACH lab database)

     dbo.DenialSummaryObservation  Observation (rich text), Responsible Person and the
                                   Observation / Target / Follow-up / Completed dates for one
                                   row of the Denial Summary page (spec 4a-4d).
     dbo.DenialSummarySnapshot     Weekly, monthly and on-demand Excel snapshots of the
                                   summary (4g). Past retention they are archived, never
                                   deleted (4h, 4i).

   RE-RUNNABLE and non-destructive. Optional: the Reports API creates the same objects on
   first use (SqlDenialSummaryRepository.SchemaStatements - keep the two in step).
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.DenialSummaryObservation', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialSummaryObservation
    (
        LabId             int            NOT NULL,
        SummaryType       nvarchar(40)   NOT NULL,   -- Classification | ActionCategory
        SummaryKey        nvarchar(255)  NOT NULL,   -- the row's display name, e.g. 'Unclassified'
        ObservationHtml   nvarchar(max)  NULL,       -- sanitized: formatting tags only, no attributes
        ResponsiblePerson nvarchar(200)  NULL,       -- free text
        ObservationDate   date           NULL,
        TargetDate        date           NULL,
        FollowUpDate      date           NULL,
        CompletedDate     date           NULL,
        CreatedOn         datetime2(0)   NOT NULL CONSTRAINT DF_DenialSummaryObservation_CreatedOn DEFAULT SYSUTCDATETIME(),
        CreatedBy         nvarchar(200)  NULL,
        UpdatedOn         datetime2(0)   NULL,
        UpdatedBy         nvarchar(200)  NULL,
        RowVer            rowversion     NOT NULL,   -- optimistic concurrency between editors
        CONSTRAINT PK_DenialSummaryObservation PRIMARY KEY CLUSTERED (LabId, SummaryType, SummaryKey)
    );
    PRINT 'Created dbo.DenialSummaryObservation';
END;
GO

IF OBJECT_ID('dbo.DenialSummarySnapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialSummarySnapshot
    (
        SnapshotId            bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialSummarySnapshot PRIMARY KEY CLUSTERED,
        LabId                 int             NOT NULL,
        PeriodType            nvarchar(20)    NOT NULL,
        PeriodStart           date            NOT NULL,
        PeriodEnd             date            NOT NULL,
        FileName              nvarchar(260)   NOT NULL,
        Content               varbinary(max)  NOT NULL,   -- the .xlsx
        SizeBytes             bigint          NOT NULL,
        TotalClaims           int             NOT NULL CONSTRAINT DF_DenialSummarySnapshot_TotalClaims DEFAULT 0,
        TotalInsuranceBalance decimal(18,2)   NOT NULL CONSTRAINT DF_DenialSummarySnapshot_TotalIns DEFAULT 0,
        IsArchived            bit             NOT NULL CONSTRAINT DF_DenialSummarySnapshot_IsArchived DEFAULT 0,
        ArchivedOn            datetime2(0)    NULL,
        CreatedOn             datetime2(0)    NOT NULL CONSTRAINT DF_DenialSummarySnapshot_CreatedOn DEFAULT SYSUTCDATETIME(),
        CreatedBy             nvarchar(200)   NULL,
        CONSTRAINT CK_DenialSummarySnapshot_PeriodType CHECK (PeriodType IN (N'Weekly', N'Monthly', N'OnDemand'))
    );
    PRINT 'Created dbo.DenialSummarySnapshot';
END;
GO

-- One weekly and one monthly snapshot per period, however many API instances run the scheduler.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_DenialSummarySnapshot_Period' AND object_id = OBJECT_ID('dbo.DenialSummarySnapshot'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_DenialSummarySnapshot_Period
    ON dbo.DenialSummarySnapshot (LabId, PeriodType, PeriodStart)
    WHERE PeriodType IN (N'Weekly', N'Monthly');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialSummarySnapshot_List' AND object_id = OBJECT_ID('dbo.DenialSummarySnapshot'))
    CREATE NONCLUSTERED INDEX IX_DenialSummarySnapshot_List
    ON dbo.DenialSummarySnapshot (LabId, IsArchived, PeriodStart DESC)
    INCLUDE (PeriodType, PeriodEnd, FileName, SizeBytes, TotalClaims, TotalInsuranceBalance, ArchivedOn, CreatedOn, CreatedBy);
GO

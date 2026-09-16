/*
    dbo.DenialClaimLevelInsight — the Denial Insight table behind the Denial Claim Report.
    Run against EACH LAB database (not LRNMaster).

    One row per denial code / insurance on one of the two tabs:

      Bucket     'Current'  — what the client imported and is working on this week
                 'Previous' — the previously discussed items, copied across from Current

      WeekStart  Monday of the week the insights describe.
      SortOrder  The rank the client put the rows in. Their workbook is ranked by impact and
                 the order carries meaning, so it is preserved rather than re-sorted on read.

    Observation and Action hold sanitized HTML, so the workbook's bold text and bullet points
    survive the round trip from Excel, into the database, onto the page and back out to the export.

    LabMetricsDashboard creates this table itself on first use, so the script is a convenience for
    deploying ahead of the app - not a prerequisite. It is re-runnable and makes no change on a
    database that is already up to date.
*/

SET NOCOUNT ON;
GO

/*
    An earlier build of this feature called the table dbo.DenialInsightClaimLevel. Where that one
    exists and the new one does not, it is RENAMED rather than dropped and recreated, so any
    insights a lab has already imported survive the change.

    Its Archive rows fold into Previous: the three-tab design was replaced by two, and Archive held
    the same kind of content as Previous - previously discussed items - so discarding those rows
    would throw away real work.
*/
IF OBJECT_ID('dbo.DenialInsightClaimLevel', 'U') IS NOT NULL
   AND OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NULL
BEGIN
    EXEC sp_rename 'dbo.DenialInsightClaimLevel', 'DenialClaimLevelInsight';
    PRINT 'Renamed dbo.DenialInsightClaimLevel to dbo.DenialClaimLevelInsight.';
END
GO

IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimLevelInsight
    (
        Id                BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimLevelInsight PRIMARY KEY,
        Bucket            NVARCHAR(20)   NOT NULL CONSTRAINT DF_DCLI_Bucket DEFAULT 'Current',
        WeekStart         DATE           NOT NULL CONSTRAINT DF_DCLI_WeekStart DEFAULT CAST(SYSUTCDATETIME() AS date),
        SortOrder         INT            NOT NULL CONSTRAINT DF_DCLI_SortOrder DEFAULT 0,
        DenialCode        NVARCHAR(100)  NOT NULL,
        DenialDescription NVARCHAR(1000) NULL,
        PayerName         NVARCHAR(255)  NULL,
        NoOfDenials       INT            NOT NULL CONSTRAINT DF_DCLI_NoOfDenials DEFAULT 0,
        TotalBalance      DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DCLI_TotalBalance DEFAULT 0,
        InsuranceBalance  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DCLI_InsuranceBalance DEFAULT 0,
        ImpactPercentage  DECIMAL(18,2)  NOT NULL CONSTRAINT DF_DCLI_ImpactPercentage DEFAULT 0,
        Observation       NVARCHAR(MAX)  NULL,
        ActionCategory    NVARCHAR(500)  NULL,
        Action            NVARCHAR(MAX)  NULL,
        FeedbackResponse  NVARCHAR(MAX)  NULL,
        Responsibility    NVARCHAR(255)  NULL,
        DiscussionDate    DATE           NULL,
        ETA               DATE           NULL,
        ClosedDate        DATE           NULL,
        UpdatedOn         DATETIME2(3)   NULL,
        UpdatedBy         NVARCHAR(200)  NULL
    );

    PRINT 'Created dbo.DenialClaimLevelInsight.';
END
GO

/* Columns a renamed table from the earlier build will not have. */
IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimLevelInsight', 'Bucket') IS NULL
BEGIN
    ALTER TABLE dbo.DenialClaimLevelInsight
        ADD Bucket NVARCHAR(20) NOT NULL CONSTRAINT DF_DCLI_Bucket DEFAULT 'Current';
    PRINT 'Added Bucket.';
END
GO

IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimLevelInsight', 'WeekStart') IS NULL
BEGIN
    ALTER TABLE dbo.DenialClaimLevelInsight
        ADD WeekStart DATE NOT NULL CONSTRAINT DF_DCLI_WeekStart DEFAULT CAST(SYSUTCDATETIME() AS date);
    PRINT 'Added WeekStart.';
END
GO

IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimLevelInsight', 'SortOrder') IS NULL
BEGIN
    ALTER TABLE dbo.DenialClaimLevelInsight
        ADD SortOrder INT NOT NULL CONSTRAINT DF_DCLI_SortOrder DEFAULT 0;
    PRINT 'Added SortOrder.';
END
GO

/* NoOfClaims was dropped: the client's template has no such column, and the value was always 0. */
IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimLevelInsight', 'NoOfClaims') IS NOT NULL
BEGIN
    DECLARE @df sysname;
    SELECT @df = dc.name
    FROM   sys.default_constraints dc
    JOIN   sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE  dc.parent_object_id = OBJECT_ID('dbo.DenialClaimLevelInsight') AND c.name = 'NoOfClaims';

    IF @df IS NOT NULL
        EXEC('ALTER TABLE dbo.DenialClaimLevelInsight DROP CONSTRAINT [' + @df + ']');

    ALTER TABLE dbo.DenialClaimLevelInsight DROP COLUMN NoOfClaims;
    PRINT 'Dropped the unused NoOfClaims column.';
END
GO

/* Archive is no longer a tab. Those rows are previously discussed items, so they join Previous. */
IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM dbo.DenialClaimLevelInsight WHERE Bucket NOT IN ('Current', 'Previous'))
BEGIN
    UPDATE dbo.DenialClaimLevelInsight
    SET    Bucket = 'Previous'
    WHERE  Bucket NOT IN ('Current', 'Previous');

    PRINT 'Folded Archive rows into Previous Week.';
END
GO

/* Identity of a row: the tab, the week, the denial code and the insurance. */
IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.DenialClaimLevelInsight')
                 AND name IN ('UX_DenialInsightClaimLevel_Code_Payer',
                              'UX_DenialInsightClaimLevel_Bucket_Week_Code_Payer'))
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialClaimLevelInsight')
                 AND name = 'UX_DenialInsightClaimLevel_Code_Payer')
        DROP INDEX UX_DenialInsightClaimLevel_Code_Payer ON dbo.DenialClaimLevelInsight;

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialClaimLevelInsight')
                 AND name = 'UX_DenialInsightClaimLevel_Bucket_Week_Code_Payer')
        DROP INDEX UX_DenialInsightClaimLevel_Bucket_Week_Code_Payer ON dbo.DenialClaimLevelInsight;

    PRINT 'Dropped the previous build''s unique index.';
END
GO

IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE object_id = OBJECT_ID('dbo.DenialClaimLevelInsight')
                     AND name = 'UX_DenialClaimLevelInsight_Bucket_Week_Code_Payer')
BEGIN
    CREATE UNIQUE INDEX UX_DenialClaimLevelInsight_Bucket_Week_Code_Payer
        ON dbo.DenialClaimLevelInsight (Bucket, WeekStart, DenialCode, PayerName);

    PRINT 'Created UX_DenialClaimLevelInsight_Bucket_Week_Code_Payer.';
END
GO

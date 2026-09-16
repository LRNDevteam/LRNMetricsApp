/*
    Denial Insight tabs: Current Week / Previous Week / Archive.
    Run against EACH LAB database (not LRNMaster).

    Adds the two columns that give an insight row its place in time:

      Bucket     'Current', 'Previous' or 'Archive' - which tab the row appears on.
                 An explicit column rather than something derived from the week, because
                 "Copy Data to Previous Week" is a deliberate action the user takes: rows have
                 to stay where they were put until the user moves them, not drift between tabs
                 as the calendar turns.

      WeekStart  Monday of the week the insights describe.

    The unique index moves from (DenialCode, PayerName) to
    (Bucket, WeekStart, DenialCode, PayerName). Without that change the same denial code could
    not exist in two different weeks, which is exactly what the three tabs require.

    LabMetricsDashboard applies all of this itself on first use, so this script is a convenience
    for deploying ahead of the app - not a prerequisite. It is re-runnable and makes no change
    on a database that is already up to date.

    Existing rows keep their data. They become Current Week of whatever week they are stamped
    with by the column default, which is where they were already being shown.
*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.DenialInsightClaimLevel', 'U') IS NULL
BEGIN
    PRINT 'dbo.DenialInsightClaimLevel does not exist yet. LabMetricsDashboard creates it on first use - nothing to do.';
END
GO

IF OBJECT_ID('dbo.DenialInsightClaimLevel', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialInsightClaimLevel', 'Bucket') IS NULL
BEGIN
    ALTER TABLE dbo.DenialInsightClaimLevel
        ADD Bucket NVARCHAR(20) NOT NULL CONSTRAINT DF_DICL_Bucket DEFAULT 'Current';

    PRINT 'Added dbo.DenialInsightClaimLevel.Bucket.';
END
GO

IF OBJECT_ID('dbo.DenialInsightClaimLevel', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialInsightClaimLevel', 'WeekStart') IS NULL
BEGIN
    ALTER TABLE dbo.DenialInsightClaimLevel
        ADD WeekStart DATE NOT NULL CONSTRAINT DF_DICL_WeekStart DEFAULT CAST(SYSUTCDATETIME() AS date);

    PRINT 'Added dbo.DenialInsightClaimLevel.WeekStart.';
END
GO

/* The old key would now reject the same denial appearing in two different weeks. */
IF OBJECT_ID('dbo.DenialInsightClaimLevel', 'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.DenialInsightClaimLevel')
                 AND name = 'UX_DenialInsightClaimLevel_Code_Payer')
BEGIN
    DROP INDEX UX_DenialInsightClaimLevel_Code_Payer ON dbo.DenialInsightClaimLevel;
    PRINT 'Dropped UX_DenialInsightClaimLevel_Code_Payer.';
END
GO

IF OBJECT_ID('dbo.DenialInsightClaimLevel', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE object_id = OBJECT_ID('dbo.DenialInsightClaimLevel')
                     AND name = 'UX_DenialInsightClaimLevel_Bucket_Week_Code_Payer')
BEGIN
    CREATE UNIQUE INDEX UX_DenialInsightClaimLevel_Bucket_Week_Code_Payer
        ON dbo.DenialInsightClaimLevel (Bucket, WeekStart, DenialCode, PayerName);

    PRINT 'Created UX_DenialInsightClaimLevel_Bucket_Week_Code_Payer.';
END
GO

/*
    Derived denial columns on the claim-level table.
    Run against EACH LAB database (not LRNMaster).

    DenialCodeNormalized  Denial code(s) with the claim adjustment group prefix stripped, so
                          CO10 / PR10 / PI10 all read as 10, and a multi-code cell such as
                          "CO10, CO189" reads as "10, 189".

    DenialDescription     Each normalized code paired with its description, e.g.
                          "10 - <description>; 189 - <description>".

                          The description is resolved in four steps, in this order:
                            1. dbo.DenialCodeMaster (this lab's Denial-Action master), raw code
                            2. LRNMaster.dbo.DenialMapperSuperMaster, raw code
                            3. dbo.DenialCodeMaster, normalized code
                            4. LRNMaster.dbo.DenialMapperSuperMaster, normalized code

                          The masters hold only the prefixed codes (CO10, PR10, PI10) and all
                          three share one description, which is why steps 3 and 4 match on the
                          normalized code - a claim carrying CO10 still finds a description the
                          master stores only under PR10.

    Both columns are populated by LRN.MasterFileProcessorWorker immediately after the claim-level
    bulk copy commits (DenialDescriptionEnricher). The worker creates them itself if they are
    absent, so this script is a convenience for deploying ahead of the run - not a prerequisite.
    It is re-runnable and makes no change on a database that already has the columns.
*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NULL
BEGIN
    RAISERROR('dbo.ClaimLevelData does not exist in this database. Run the lab deployment scripts first.', 16, 1);
END
GO

/*
    nvarchar(400), not wider, because this column is indexed below.

    A nonclustered index key tops out at 1700 bytes, so an nvarchar wider than 850 cannot be an
    index key at all - SQL Server creates the index but warns that inserts will fail once a value
    gets long enough. 400 characters is roughly 57 codes at "189, " apiece, far more than any real
    claim carries, and leaves the index comfortably valid instead of merely warned about.

    The worker caps what it writes to the same 400 characters, so the two cannot disagree.
*/
IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.columns
                   WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
                     AND name = 'DenialCodeNormalized')
BEGIN
    ALTER TABLE dbo.ClaimLevelData ADD [DenialCodeNormalized] nvarchar(400) NULL;
    PRINT 'Added dbo.ClaimLevelData.DenialCodeNormalized.';
END
GO

/*
    An earlier version of this script created the column as nvarchar(1000), which produced:
        "Warning! The maximum key length for a nonclustered index is 1700 bytes. The index
         'IX_ClaimLevelData_DenialCodeNormalized' has maximum length of 2000 bytes."
    Narrow it, dropping the over-wide index first so the ALTER is allowed. The index is recreated
    at the bottom of this script.

    Nothing is narrowed if any row would actually lose data - the script says so and leaves the
    column as it is, rather than silently truncating a lab's values.
*/
IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
                 AND name = 'DenialCodeNormalized'
                 AND max_length > 400 * 2)   -- max_length is in BYTES for nvarchar
BEGIN
    IF EXISTS (SELECT 1 FROM dbo.ClaimLevelData WITH (NOLOCK)
               WHERE LEN([DenialCodeNormalized]) > 400)
    BEGIN
        PRINT 'SKIPPED narrowing DenialCodeNormalized: some rows hold more than 400 characters.';
        PRINT 'Inspect them, then re-run the Master File Processor claim-level import to rewrite the column.';
    END
    ELSE
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.indexes
                   WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
                     AND name = 'IX_ClaimLevelData_DenialCodeNormalized')
        BEGIN
            DROP INDEX IX_ClaimLevelData_DenialCodeNormalized ON dbo.ClaimLevelData;
            PRINT 'Dropped the over-wide IX_ClaimLevelData_DenialCodeNormalized so the column can be narrowed.';
        END

        ALTER TABLE dbo.ClaimLevelData ALTER COLUMN [DenialCodeNormalized] nvarchar(400) NULL;
        PRINT 'Narrowed dbo.ClaimLevelData.DenialCodeNormalized to nvarchar(400).';
    END
END
GO

IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.columns
                   WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
                     AND name = 'DenialDescription')
BEGIN
    ALTER TABLE dbo.ClaimLevelData ADD [DenialDescription] nvarchar(max) NULL;
    PRINT 'Added dbo.ClaimLevelData.DenialDescription.';
END
GO

/*
    Filtered index for the denial reporting, which reads only the denied rows.
    Not created by the worker - an index is a DBA decision, and adding one silently to a
    seven-figure table during an import is not this pipeline's call to make.

    Created only once the column is 400 characters or narrower. Building it over a wider column
    is what produced the 1700-byte key-length warning, and an index SQL Server has warned about
    is worse than no index: it works until one long value makes an insert fail.
*/
IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
                 AND name = 'DenialCodeNormalized'
                 AND max_length <= 400 * 2)
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                   WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
                     AND name = 'IX_ClaimLevelData_DenialCodeNormalized')
BEGIN
    CREATE NONCLUSTERED INDEX IX_ClaimLevelData_DenialCodeNormalized
        ON dbo.ClaimLevelData ([DenialCodeNormalized])
        WHERE [DenialCodeNormalized] IS NOT NULL;

    PRINT 'Created IX_ClaimLevelData_DenialCodeNormalized.';
END
GO


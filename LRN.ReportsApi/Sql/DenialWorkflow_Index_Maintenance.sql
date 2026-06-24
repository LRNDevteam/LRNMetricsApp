/*
    Denial Workflow index maintenance
    ------------------------------------------------------------
    Run after large imports, heavy task-board updates, or during a
    maintenance window. This script only touches Denial Workflow tables.

    Rules:
      - 5% to 30% fragmentation: REORGANIZE
      - 30%+ fragmentation: REBUILD
      - Always update statistics after maintenance
*/

SET NOCOUNT ON;

IF DB_NAME() IN ('master', 'model', 'msdb', 'tempdb')
BEGIN
    THROW 51000, 'Run DenialWorkflow_Index_Maintenance.sql in the lab/customer database, not a system database.', 1;
END;

DECLARE @sql nvarchar(max);
DECLARE @tableName sysname;
DECLARE @indexName sysname;
DECLARE @fragmentation decimal(8,2);

IF OBJECT_ID('tempdb..#DwfTables') IS NOT NULL
    DROP TABLE #DwfTables;

CREATE TABLE #DwfTables
(
    TableName sysname NOT NULL PRIMARY KEY
);

INSERT INTO #DwfTables (TableName)
SELECT t.name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = 'dbo'
  AND t.name IN
  (
      'DenialTaskBoard',
      'DenialLineItem',
      'DenialClaimEscalations',
      'DenialClaimNotes',
      'DenialClaimDocuments',
      'DenialVerificationTask',
      'DenialClosedClaims',
      'DenialClosedClaimsHistory',
      'DenialInsight',
      'DenialTaskHistory'
  );

IF OBJECT_ID('tempdb..#FragmentedIndexes') IS NOT NULL
    DROP TABLE #FragmentedIndexes;

CREATE TABLE #FragmentedIndexes
(
    TableName sysname NOT NULL,
    IndexName sysname NOT NULL,
    Fragmentation decimal(8,2) NOT NULL
);

INSERT INTO #FragmentedIndexes (TableName, IndexName, Fragmentation)
SELECT
    t.name AS TableName,
    i.name AS IndexName,
    ips.avg_fragmentation_in_percent AS Fragmentation
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i
    ON i.object_id = ips.object_id
   AND i.index_id = ips.index_id
JOIN sys.tables t
    ON t.object_id = ips.object_id
JOIN sys.schemas s
    ON s.schema_id = t.schema_id
JOIN #DwfTables dt
    ON dt.TableName = t.name
WHERE s.name = 'dbo'
  AND i.index_id > 0
  AND i.is_disabled = 0
  AND i.name IS NOT NULL
  AND ips.page_count >= 100
  AND ips.avg_fragmentation_in_percent >= 5;

DECLARE index_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT TableName, IndexName, Fragmentation
FROM #FragmentedIndexes
ORDER BY Fragmentation DESC;

OPEN index_cursor;
FETCH NEXT FROM index_cursor INTO @tableName, @indexName, @fragmentation;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @fragmentation >= 30
    BEGIN
        SET @sql = N'ALTER INDEX ' + QUOTENAME(@indexName)
            + N' ON dbo.' + QUOTENAME(@tableName)
            + N' REBUILD WITH (SORT_IN_TEMPDB = ON);';
        PRINT 'Rebuilding ' + @tableName + '.' + @indexName + ' fragmentation=' + CONVERT(varchar(20), @fragmentation);
    END
    ELSE
    BEGIN
        SET @sql = N'ALTER INDEX ' + QUOTENAME(@indexName)
            + N' ON dbo.' + QUOTENAME(@tableName)
            + N' REORGANIZE;';
        PRINT 'Reorganizing ' + @tableName + '.' + @indexName + ' fragmentation=' + CONVERT(varchar(20), @fragmentation);
    END;

    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM index_cursor INTO @tableName, @indexName, @fragmentation;
END;

CLOSE index_cursor;
DEALLOCATE index_cursor;

DECLARE stats_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT TableName
FROM #DwfTables
ORDER BY TableName;

OPEN stats_cursor;
FETCH NEXT FROM stats_cursor INTO @tableName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'UPDATE STATISTICS dbo.' + QUOTENAME(@tableName) + N' WITH RESAMPLE;';
    PRINT 'Updating statistics for dbo.' + @tableName;
    EXEC sys.sp_executesql @sql;

    FETCH NEXT FROM stats_cursor INTO @tableName;
END;

CLOSE stats_cursor;
DEALLOCATE stats_cursor;

PRINT 'Completed Denial Workflow index maintenance for ' + DB_NAME();

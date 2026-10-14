/* ============================================================================
   Demo lab step 4 - re-stamp the cloned data as LRNLabDemo instead of PCR.

   >>> RUN AGAINST THE DEMO DATABASE (LRNLabDemo). The USE below does that. <<<

   WHY THIS IS NEEDED
   The clone carries PCR's identity in its own rows: LabId = 13 and
   LabName = 'PCR Labs of America'. The application registers the demo lab as
   LabId 99, and every claim-scoped query filters [LabId] = @LabId. So:

     * Queries with no LabId filter worked      -> 4,735 open tasks, SLA counts,
                                                   balances, classification rows.
     * Queries scoped to LabId 99 found nothing -> 0 open claims, 0 assigned,
                                                   0 unassigned, 0 escalated,
                                                   an empty Claim Assignment page.

   That split is the whole bug. Re-stamping the data to 99 / 'LRNLabDemo' makes
   the demo self-consistent, and has the side benefit of removing PCR's name from
   the demo data set.

   SCHEMA-DRIVEN, like the de-identify script: it finds every LabId / LabName
   column in the database rather than working from a hand-written table list, so
   a table added later is not silently missed.

   RE-RUNNABLE. After the first pass there is nothing left matching the old id,
   so a second run reports zero changes.

   Start with @Apply = 0 (the default): it reports what it would change.
   ============================================================================ */

/* Several of these tables carry filtered indexes, and an UPDATE against one fails
   outright unless QUOTED_IDENTIFIER and ANSI_NULLS are ON. SSMS sets them by
   default; sqlcmd does NOT, so without this the big tables (DenialTaskBoard,
   DenialLineItem, LineLevelData) silently land in the !! FAILED list while the
   small ones succeed - leaving the database half re-stamped.
   If you run this through sqlcmd, pass -I as well. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

USE LRNLabDemo;
GO

SET NOCOUNT ON;

DECLARE @Apply BIT = 0;   -- 0 = report only, 1 = actually re-stamp

DECLARE @OldLabId   INT           = 13;              -- PCR's id, inherited by the clone
DECLARE @NewLabId   INT           = 99;              -- must match dbo.Labs / dbo.LRNMetricsLab / appsettings LabsID
DECLARE @NewLabName NVARCHAR(200) = N'LRNLabDemo';   -- must match the lab config key and the JSON file name

/* ── Guard: never let this run against a client database ─────────────────── */
IF DB_NAME() NOT LIKE N'%Demo%'
BEGIN
    DECLARE @Wrong NVARCHAR(200) = DB_NAME();
    PRINT N'Refusing to run: the current database is "' + @Wrong + N'", which is not a demo database.';
    RAISERROR(N'Re-stamp aborted: current database "%s" is not a demo database.', 16, 1, @Wrong);
    RETURN;
END

/* ── Find every LabId / LabName column ───────────────────────────────────── */
SELECT
    QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) AS FullTable,
    c.name AS ColumnName,
    CASE WHEN c.name = 'LabName' THEN 'NAME' ELSE 'ID' END AS Kind
INTO #Target
FROM sys.tables  t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
WHERE c.name IN ('LabId', 'LabID', 'LabName')
  AND c.is_computed = 0;

PRINT N'Columns carrying the lab identity in ' + DB_NAME() + N':';
SELECT FullTable, ColumnName, Kind FROM #Target ORDER BY FullTable, ColumnName;

IF @Apply = 0
BEGIN
    PRINT N'';
    PRINT N'REPORT ONLY - nothing was changed. Set @Apply = 1 and run again.';
    DROP TABLE #Target;
    RETURN;
END

/* ── Re-stamp ────────────────────────────────────────────────────────────
   LabName is matched on "PCR%" rather than an exact string: the clone holds both
   'PCR Labs of America' and 'PCR_Labs_Of_America', and an exact match would leave
   the second spelling behind.                                                  */
DECLARE @FullTable NVARCHAR(300), @Column SYSNAME, @Kind VARCHAR(10);
DECLARE @sql NVARCHAR(MAX);
DECLARE @Changed INT = 0, @TotalRows BIGINT = 0;

DECLARE TargetCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT FullTable, ColumnName, Kind FROM #Target ORDER BY FullTable, ColumnName;

OPEN TargetCursor;
FETCH NEXT FROM TargetCursor INTO @FullTable, @Column, @Kind;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = CASE @Kind
        WHEN 'ID' THEN
            N'UPDATE ' + @FullTable + N'
              SET ' + QUOTENAME(@Column) + N' = @NewId
              WHERE ' + QUOTENAME(@Column) + N' = @OldId;'
        ELSE
            N'UPDATE ' + @FullTable + N'
              SET ' + QUOTENAME(@Column) + N' = @NewName
              WHERE ' + QUOTENAME(@Column) + N' LIKE N''PCR%'';'
    END;

    BEGIN TRY
        EXEC sp_executesql @sql,
             N'@OldId INT, @NewId INT, @NewName NVARCHAR(200)',
             @OldId = @OldLabId, @NewId = @NewLabId, @NewName = @NewLabName;

        IF @@ROWCOUNT > 0
        BEGIN
            SET @Changed   = @Changed + 1;
            SET @TotalRows = @TotalRows + @@ROWCOUNT;
            PRINT N'  re-stamped ' + @FullTable + N'.' + @Column;
        END
    END TRY
    BEGIN CATCH
        -- Keep going so one constrained column cannot leave the rest half-stamped,
        -- which would be worse than the state we started in.
        PRINT N'  !! FAILED ' + @FullTable + N'.' + @Column + N' : ' + ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM TargetCursor INTO @FullTable, @Column, @Kind;
END

CLOSE TargetCursor;
DEALLOCATE TargetCursor;
DROP TABLE #Target;

PRINT N'';
PRINT N'Re-stamp finished: ' + CAST(@Changed AS NVARCHAR(10)) + N' column(s), '
    + CAST(@TotalRows AS NVARCHAR(20)) + N' row update(s).';
PRINT N'Check for any !! FAILED lines above.';
PRINT N'Next: run Demo_LRNLabDemo_03_RegisterLab.sql against LRNMaster.';
GO

/* ------------------------------------------------------------------- Verify
   Every row should now read 99 / LRNLabDemo. Anything still on 13 or PCR means
   a column failed above. */
SELECT 'DenialTaskBoard' AS Tbl, LabId, LabName, COUNT(*) AS [Rows] FROM dbo.DenialTaskBoard GROUP BY LabId, LabName
UNION ALL SELECT 'DenialLineItem', LabId, LabName, COUNT(*) FROM dbo.DenialLineItem GROUP BY LabId, LabName
UNION ALL SELECT 'ClaimLevelData', LabID, LabName, COUNT(*) FROM dbo.ClaimLevelData GROUP BY LabID, LabName;
GO

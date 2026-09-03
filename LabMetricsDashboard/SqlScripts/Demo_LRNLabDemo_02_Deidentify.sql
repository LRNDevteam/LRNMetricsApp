/* ============================================================================
   Demo lab step 2 of 3 - remove patient identifiers from the LRNLabDemo clone.

   >>> RUN THIS AGAINST THE DEMO DATABASE ONLY. <<<
   It rewrites data in place. The guard below refuses to run against anything
   whose name does not contain "Demo", but check your connection anyway.

   HOW IT FINDS THE COLUMNS
   Schema-driven, not a hand-written table list: it scans INFORMATION_SCHEMA for
   columns whose names match the patterns in #PhiColumn below, across every user
   table. A hand-written list silently goes stale the first time someone adds a
   column; this does not.

   WHAT IT DOES
     * Patient identifiers (PatientId, MRN, account numbers) are replaced with a
       DETERMINISTIC pseudonym derived from the original value. The same patient
       gets the same fake id in every table, so claims, line items, tasks, notes
       and escalations still join up and the demo tells a coherent story.
     * Names and subscriber names become "Demo Patient <n>" style values, again
       derived from the original so they stay consistent across tables.
     * Dates of birth are shifted by a fixed number of days and reduced to the
       first of the month.

   WHAT IT DELIBERATELY DOES NOT DO
     Service, billing, check and posting dates are left ALONE. Shifting them
     would move every claim out of the aging buckets and reporting windows the
     demo exists to show. With names, ids and DOB gone, what remains is a claims
     data set rather than identifiable patient records - but it is NOT a formal
     Safe Harbor de-identification, and it does not remove free-text PHI that may
     have been typed into note or comment fields. Read the "Residual risk" note
     in docs/demo-lab/DemoLab_Setup.md before demoing outside the company.

   RE-RUNNABLE. Running twice pseudonymises the already-pseudonymised values,
   which is harmless. Normally you re-run step 1 then step 2 together.

   Start with @Apply = 0 (the default): it reports exactly which columns it would
   rewrite, and changes nothing.
   ============================================================================ */

/* Several of these tables carry filtered indexes, and an UPDATE against one fails
   outright unless QUOTED_IDENTIFIER and ANSI_NULLS are ON. SSMS sets them by
   default; sqlcmd does NOT, so without this the biggest tables - DenialTaskBoard,
   DenialLineItem, LineLevelData, ClaimLevelData, the ones actually holding patient
   data - land in the !! FAILED list while the small ones succeed. The report would
   look almost clean while the PHI was still there.
   If you run this through sqlcmd, pass -I as well. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* Select the demo database explicitly, so the script cannot be run against
   whatever happened to be in the connection's dropdown - which for a fresh SSMS
   window is master. If you cloned to a name other than LRNLabDemo, change it
   here; the guard below still insists on "Demo" in the name either way. */
USE LRNLabDemo;
GO

SET NOCOUNT ON;

DECLARE @Apply     BIT = 0;      -- 0 = report only, 1 = actually rewrite
DECLARE @DobShift  INT = -3477;  -- days; any fixed value, kept out of round numbers

/* ── Guard: never let this point at a client database ────────────────────── */
IF DB_NAME() NOT LIKE N'%Demo%'
BEGIN
    DECLARE @Wrong NVARCHAR(200) = DB_NAME();
    PRINT N'Refusing to run: the current database is "' + @Wrong + N'", which is not a demo database.';
    PRINT N'Fix the USE statement at the top of this script, or switch the connection to the demo database.';
    RAISERROR(N'De-identification aborted: current database "%s" is not a demo database.', 16, 1, @Wrong);
    RETURN;
END

/* ── The columns that count as patient identifiers ───────────────────────── */
CREATE TABLE #PhiColumn (Pattern SYSNAME, Treatment VARCHAR(20));
INSERT INTO #PhiColumn (Pattern, Treatment) VALUES
    -- Stable pseudonym: keeps rows joinable across tables.
    (N'PatientId',        'PSEUDONYM'),
    (N'PatientID',        'PSEUDONYM'),
    (N'PatientAccount%',  'PSEUDONYM'),
    (N'MRN',              'PSEUDONYM'),
    (N'MemberId',         'PSEUDONYM'),
    (N'SubscriberId',     'PSEUDONYM'),
    (N'PolicyNumber',     'PSEUDONYM'),
    -- Human-readable placeholder.
    (N'PatientName',      'NAME'),
    (N'PatientFirst%',    'NAME'),
    (N'PatientLast%',     'NAME'),
    (N'Subscriber',       'NAME'),
    (N'SubscriberName',   'NAME'),
    (N'GuarantorName',    'NAME'),
    -- Shifted and flattened to the 1st of the month.
    (N'PatientDOB',       'DOB'),
    (N'DOB',              'DOB'),
    (N'DateOfBirth',      'DOB'),
    (N'BirthDate',        'DOB');

/* ── Match those patterns against the real schema ─────────────────────────
   Computed columns and anything non-writable are excluded, or the UPDATE fails.

   Note the DOBTEXT case: these tables are CSV-loaded, so a date of birth is often
   held as varchar rather than a date type. Requiring a real date type would have
   silently skipped exactly those columns - the worst possible failure for a PHI
   scrub, because the report would look clean. A text DOB gets a fixed placeholder
   instead of a shift, since there is no reliable format to shift.             */
SELECT
    QUOTENAME(c.TABLE_SCHEMA) + N'.' + QUOTENAME(c.TABLE_NAME) AS FullTable,
    c.COLUMN_NAME,
    c.DATA_TYPE,
    -- -1 for MAX types; used to keep replacement values inside a narrow column
    -- (a char(8) 'YYYYMMDD' date of birth will not hold '1900-01-01').
    ISNULL(c.CHARACTER_MAXIMUM_LENGTH, 4000) AS MaxLen,
    CAST(CASE
        WHEN p.Treatment = 'DOB'
         AND c.DATA_TYPE IN ('date', 'datetime', 'datetime2', 'smalldatetime') THEN 'DOB'
        WHEN p.Treatment = 'DOB'                                               THEN 'DOBTEXT'
        ELSE p.Treatment
    END AS VARCHAR(20)) AS Treatment
INTO #Target
FROM INFORMATION_SCHEMA.COLUMNS c
JOIN INFORMATION_SCHEMA.TABLES  t
       ON  t.TABLE_SCHEMA = c.TABLE_SCHEMA
       AND t.TABLE_NAME   = c.TABLE_NAME
       AND t.TABLE_TYPE   = 'BASE TABLE'
JOIN #PhiColumn p
       ON c.COLUMN_NAME LIKE p.Pattern
WHERE COLUMNPROPERTY(OBJECT_ID(QUOTENAME(c.TABLE_SCHEMA) + '.' + QUOTENAME(c.TABLE_NAME)), c.COLUMN_NAME, 'IsComputed') = 0
  AND (
        (p.Treatment =  'DOB' AND c.DATA_TYPE IN ('date', 'datetime', 'datetime2', 'smalldatetime',
                                                  'char', 'nchar', 'varchar', 'nvarchar'))
     OR (p.Treatment <> 'DOB' AND c.DATA_TYPE IN ('char', 'nchar', 'varchar', 'nvarchar', 'int', 'bigint'))
      );

/* A column may match more than one pattern (e.g. "PatientId"); keep one row each. */
;WITH Deduped AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY FullTable, COLUMN_NAME ORDER BY Treatment) AS rn
    FROM #Target
)
DELETE FROM Deduped WHERE rn > 1;

PRINT N'Columns matched as patient identifiers in ' + DB_NAME() + N':';
SELECT FullTable, COLUMN_NAME, DATA_TYPE, Treatment FROM #Target ORDER BY FullTable, COLUMN_NAME;

IF @Apply = 0
BEGIN
    PRINT N'';
    PRINT N'REPORT ONLY - nothing was changed.';
    PRINT N'Review the list above, then set @Apply = 1 and run again.';
    DROP TABLE #Target; DROP TABLE #PhiColumn;
    RETURN;
END

/* ── Rewrite ─────────────────────────────────────────────────────────────
   One UPDATE per column, built from the matched schema.

   The pseudonym is HASHBYTES over the original value, so it is stable across
   tables and across re-runs, and there is no lookup table left behind that
   could map it back. Numeric id columns get a numeric pseudonym so the column
   type still fits.                                                          */
DECLARE @FullTable NVARCHAR(300), @Column SYSNAME, @DataType SYSNAME, @Treatment VARCHAR(20), @MaxLen INT;
DECLARE @Fit INT;
DECLARE @sql NVARCHAR(MAX);
DECLARE @Changed INT = 0, @TotalRows BIGINT = 0;

DECLARE TargetCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT FullTable, COLUMN_NAME, DATA_TYPE, Treatment, MaxLen FROM #Target ORDER BY FullTable, COLUMN_NAME;

OPEN TargetCursor;
FETCH NEXT FROM TargetCursor INTO @FullTable, @Column, @DataType, @Treatment, @MaxLen;

WHILE @@FETCH_STATUS = 0
BEGIN
    /* Replacement values are wrapped in LEFT(...) so a narrow column (char(8),
       varchar(10)) truncates instead of failing the UPDATE outright. -1 means a
       MAX type, where nothing can overflow. */
    SET @Fit = CASE WHEN @MaxLen = -1 OR @MaxLen > 4000 THEN 4000 ELSE @MaxLen END;

    SET @sql =
        CASE
            WHEN @Treatment = 'DOB' THEN
                N'UPDATE ' + @FullTable + N'
                  SET ' + QUOTENAME(@Column) + N' = DATEADD(DAY, 1 - DAY(DATEADD(DAY, @Shift, ' + QUOTENAME(@Column) + N')),
                                                            DATEADD(DAY, @Shift, ' + QUOTENAME(@Column) + N'))
                  WHERE ' + QUOTENAME(@Column) + N' IS NOT NULL;'

            WHEN @Treatment = 'DOBTEXT' THEN
                N'UPDATE ' + @FullTable + N'
                  SET ' + QUOTENAME(@Column) + N' = LEFT(''1900-01-01'', @Fit)
                  WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), ' + QUOTENAME(@Column) + N'))), '''') IS NOT NULL;'

            WHEN @Treatment = 'NAME' THEN
                N'UPDATE ' + @FullTable + N'
                  SET ' + QUOTENAME(@Column) + N' = LEFT(''Demo Patient '' +
                        CAST(ABS(CHECKSUM(HASHBYTES(''SHA2_256'', CONVERT(NVARCHAR(200), ' + QUOTENAME(@Column) + N')))) % 100000 AS NVARCHAR(10)), @Fit)
                  WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), ' + QUOTENAME(@Column) + N'))), '''') IS NOT NULL;'

            WHEN @DataType IN ('int', 'bigint') THEN
                N'UPDATE ' + @FullTable + N'
                  SET ' + QUOTENAME(@Column) + N' =
                        ABS(CHECKSUM(HASHBYTES(''SHA2_256'', CONVERT(NVARCHAR(200), ' + QUOTENAME(@Column) + N')))) % 900000 + 100000
                  WHERE ' + QUOTENAME(@Column) + N' IS NOT NULL;'

            ELSE  -- text identifier
                N'UPDATE ' + @FullTable + N'
                  SET ' + QUOTENAME(@Column) + N' = LEFT(''DP'' +
                        RIGHT(''000000'' + CAST(ABS(CHECKSUM(HASHBYTES(''SHA2_256'', CONVERT(NVARCHAR(200), ' + QUOTENAME(@Column) + N')))) % 900000 + 100000 AS NVARCHAR(10)), 6), @Fit)
                  WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), ' + QUOTENAME(@Column) + N'))), '''') IS NOT NULL;'
        END;

    BEGIN TRY
        EXEC sp_executesql @sql, N'@Shift INT, @Fit INT', @Shift = @DobShift, @Fit = @Fit;
        SET @Changed   = @Changed + 1;
        SET @TotalRows = @TotalRows + @@ROWCOUNT;
        PRINT N'  scrubbed ' + @FullTable + N'.' + @Column + N' (' + @Treatment + N')';
    END TRY
    BEGIN CATCH
        -- Keep going: one awkward column (a computed default, a unique index that
        -- the pseudonym collides with) must not leave the rest identifiable. Every
        -- failure is printed so you can deal with it by hand.
        PRINT N'  !! FAILED ' + @FullTable + N'.' + @Column + N' : ' + ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM TargetCursor INTO @FullTable, @Column, @DataType, @Treatment, @MaxLen;
END

CLOSE TargetCursor;
DEALLOCATE TargetCursor;
DROP TABLE #Target;
DROP TABLE #PhiColumn;

PRINT N'';
PRINT N'De-identification finished: ' + CAST(@Changed AS NVARCHAR(10)) + N' column(s), '
    + CAST(@TotalRows AS NVARCHAR(20)) + N' row update(s).';
PRINT N'Check the output above for any !! FAILED lines and handle those columns by hand.';
PRINT N'Free-text note and comment fields are NOT scrubbed - spot-check them before an external demo.';
GO

-- ============================================================
-- Diagnostic v2: Why does "Total Samples" (Row A, NAFlag not blank) show 0
-- for DOS 2026-01-01..2026-06-28 in the live/filtered path (file 24),
-- while the unfiltered aggregate view (file 26 / Inhealth_ES_LIS) shows
-- non-zero counts for the same months?
--
-- v1 ruled out the "different date column" hypothesis: ReqCollectDate does
-- not exist on this LIMSMaster, so both files 24 and 26 already resolve to
-- Entry_DateCreated. This version:
--   (a) prints every value via PRINT (not SELECT), so it survives copy/paste
--       from a Messages-only output pane,
--   (b) checks whether Inhealth_ES_LIS (the aggregate table) is stale,
--   (c) inspects the NA column's actual type/values (e.g. bit vs varchar)
--       since a non-string NA column could make "NAFlag not blank" trivially
--       true for every row, which is a different bug than a date mismatch.
--
-- Run in: Inhealth_LRN
-- Does NOT modify any data or objects.
-- ============================================================

DECLARE @DosFrom DATE = '2026-01-01';
DECLARE @DosTo   DATE = '2026-06-28';

-- ── STEP 1: column inventory (name + type) ─────────────────────────────
PRINT '=== STEP 1: LIMSMaster date/NA column inventory ===';
DECLARE @col1 SYSNAME, @type1 NVARCHAR(50);
DECLARE col_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name, TYPE_NAME(system_type_id)
    FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
      AND name IN ('ReqCollectDate','Entry_DateCreated','RequestCollectDate','DateOfCollection',
                   'DateofService','CollectionDate','ServiceDate','AccessionDate',
                   'NA','IsNA','NotApplicable','NA_Flag','NAStatus')
    ORDER BY name;
OPEN col_cur;
FETCH NEXT FROM col_cur INTO @col1, @type1;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '  ' + @col1 + '  (' + @type1 + ')';
    FETCH NEXT FROM col_cur INTO @col1, @type1;
END
CLOSE col_cur; DEALLOCATE col_cur;

-- ── STEP 2: NAFlag column + a sample of its distinct values ───────────
DECLARE @NACol SYSNAME = (
    SELECT TOP 1 name FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
      AND name IN ('NA','IsNA','NotApplicable','NA_Flag','NAStatus')
    ORDER BY CASE name WHEN 'NA' THEN 0 WHEN 'IsNA' THEN 1 WHEN 'NotApplicable' THEN 2
                       WHEN 'NA_Flag' THEN 3 WHEN 'NAStatus' THEN 4 ELSE 5 END);
PRINT '';
PRINT '=== STEP 2: Resolved NAFlag column = ' + ISNULL(@NACol, '(none found)') + ' ===';

IF @NACol IS NOT NULL
BEGIN
    -- Temp table must be created in this (outer) scope first — a temp table
    -- created via SELECT...INTO *inside* sp_executesql is local to that call
    -- and disappears the moment sp_executesql returns (Msg 208 otherwise).
    DROP TABLE IF EXISTS #NADist;
    CREATE TABLE #NADist (Val NVARCHAR(50) NULL, Cnt INT NOT NULL);

    DECLARE @DistinctSql NVARCHAR(MAX) = N'
        INSERT INTO #NADist (Val, Cnt)
        SELECT TOP 10 CONVERT(NVARCHAR(50), [' + @NACol + N']) AS Val, COUNT(*) AS Cnt
        FROM dbo.LIMSMaster
        GROUP BY CONVERT(NVARCHAR(50), [' + @NACol + N'])
        ORDER BY COUNT(*) DESC;';
    EXEC sp_executesql @DistinctSql;

    DECLARE @dv NVARCHAR(50), @dc INT;
    DECLARE nd_cur CURSOR LOCAL FAST_FORWARD FOR SELECT Val, Cnt FROM #NADist;
    OPEN nd_cur; FETCH NEXT FROM nd_cur INTO @dv, @dc;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT '  value=[' + ISNULL(@dv, 'NULL') + ']  count=' + CAST(@dc AS VARCHAR(20));
        FETCH NEXT FROM nd_cur INTO @dv, @dc;
    END
    CLOSE nd_cur; DEALLOCATE nd_cur;
    DROP TABLE IF EXISTS #NADist;
END

-- ── STEP 3: Row A count for the DOS window, live-style (Entry_DateCreated) ──
PRINT '';
PRINT '=== STEP 3: Row A (Total Samples, NAFlag not blank) for DOS 2026-01-01..2026-06-28 ===';
IF @NACol IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'Entry_DateCreated')
BEGIN
    DECLARE @cnt3 INT;
    DECLARE @Sql3 NVARCHAR(MAX) = N'
        SELECT @o = COUNT(DISTINCT OrderID)
        FROM dbo.LIMSMaster
        WHERE NULLIF(CONVERT(NVARCHAR(50), [' + @NACol + N']), '''') IS NOT NULL
          AND TRY_CAST(Entry_DateCreated AS DATE) BETWEEN @f AND @t;';
    EXEC sp_executesql @Sql3, N'@f DATE, @t DATE, @o INT OUTPUT', @f=@DosFrom, @t=@DosTo, @o=@cnt3 OUTPUT;
    PRINT '  TotalSamples_ByEntryDateCreated (Jan-Jun 2026) = ' + CAST(@cnt3 AS VARCHAR(20));

    -- Same count with NO date filter at all, for comparison
    DECLARE @cnt3b INT;
    DECLARE @Sql3b NVARCHAR(MAX) = N'
        SELECT @o = COUNT(DISTINCT OrderID)
        FROM dbo.LIMSMaster
        WHERE NULLIF(CONVERT(NVARCHAR(50), [' + @NACol + N']), '''') IS NOT NULL;';
    EXEC sp_executesql @Sql3b, N'@o INT OUTPUT', @o=@cnt3b OUTPUT;
    PRINT '  TotalSamples_AllTime (no date filter)        = ' + CAST(@cnt3b AS VARCHAR(20));

    -- Entry_DateCreated min/max for the NA-flagged rows, to see where they actually fall
    DECLARE @minD DATE, @maxD DATE, @nullD INT;
    DECLARE @Sql3c NVARCHAR(MAX) = N'
        SELECT @mn = MIN(TRY_CAST(Entry_DateCreated AS DATE)),
               @mx = MAX(TRY_CAST(Entry_DateCreated AS DATE)),
               @nl = SUM(CASE WHEN TRY_CAST(Entry_DateCreated AS DATE) IS NULL THEN 1 ELSE 0 END)
        FROM dbo.LIMSMaster
        WHERE NULLIF(CONVERT(NVARCHAR(50), [' + @NACol + N']), '''') IS NOT NULL;';
    EXEC sp_executesql @Sql3c, N'@mn DATE OUTPUT, @mx DATE OUTPUT, @nl INT OUTPUT',
        @mn=@minD OUTPUT, @mx=@maxD OUTPUT, @nl=@nullD OUTPUT;
    PRINT '  Entry_DateCreated range for NA-flagged rows  = ' + ISNULL(CONVERT(VARCHAR(10),@minD,120),'NULL') + ' .. ' + ISNULL(CONVERT(VARCHAR(10),@maxD,120),'NULL');
    PRINT '  NA-flagged rows with NULL Entry_DateCreated  = ' + CAST(@nullD AS VARCHAR(20));
END
ELSE
    PRINT '  (skipped — NAFlag or Entry_DateCreated column missing)';

-- ── STEP 4: Aggregate table freshness + its stored Row A values ───────────
PRINT '';
PRINT '=== STEP 4: Inhealth_ES_LIS (aggregate table) — Row A stored values ===';
IF OBJECT_ID('dbo.Inhealth_ES_LIS','U') IS NOT NULL
BEGIN
    DECLARE @ry INT, @rm INT, @rc DECIMAL(18,2), @rr DATETIME;
    DECLARE agg_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT ESYear, ESMonth, ESMonthClaimCount, RefreshedAt
        FROM dbo.Inhealth_ES_LIS
        WHERE RoleID = 'A' AND ((ESYear = 2026 AND ESMonth BETWEEN 1 AND 6) OR (ESYear = 0 AND ESMonth = 0))
        ORDER BY ESYear, ESMonth;
    OPEN agg_cur; FETCH NEXT FROM agg_cur INTO @ry, @rm, @rc, @rr;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT '  ESYear=' + CAST(@ry AS VARCHAR(10)) + ' ESMonth=' + CAST(@rm AS VARCHAR(10))
            + ' ClaimCount=' + CAST(@rc AS VARCHAR(20))
            + ' RefreshedAt=' + ISNULL(CONVERT(VARCHAR(30), @rr, 120), 'NULL');
        FETCH NEXT FROM agg_cur INTO @ry, @rm, @rc, @rr;
    END
    CLOSE agg_cur; DEALLOCATE agg_cur;

    -- How long ago was this table refreshed, overall?
    DECLARE @lastRefresh DATETIME;
    SELECT @lastRefresh = MAX(RefreshedAt) FROM dbo.Inhealth_ES_LIS;
    PRINT '  Most recent RefreshedAt across ALL rows = ' + ISNULL(CONVERT(VARCHAR(30), @lastRefresh, 120), 'NULL')
        + '  (current server time = ' + CONVERT(VARCHAR(30), GETDATE(), 120) + ')';
END
ELSE
    PRINT '  dbo.Inhealth_ES_LIS does not exist.';

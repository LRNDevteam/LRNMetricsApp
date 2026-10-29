/* =============================================================================
   NorthWest - Denial Summary client logic (2026-10-29)
   File     : 51_NW_DenialSummary_ClientLogic2.sql
   Database : NWL_LRN
   Requires : 45_NW_DenialSummary.sql, 49_NW_PostedDates_CollectionDenialSummary.sql,
              40_NW_ClaimLevelData_BilledUnbilled.sql (NWLDenialPostedDate)

   Monthly                  DenialCodeNormalized not blank, InsuranceBalance > 0,
                            NWLDenialPostedDate not in Jan 2025; rows PayerName_Raw ->
                            top 3 denial codes by claim count; columns NWLDenialPostedDate month.
   Facility wise Denial     DenialCodeNormalized not blank, InsuranceBalance > 0,
                            ClinicName not blank; rows ClinicName -> DenialCodeNormalized.
   Denial vs Facility %     no filter (was BilledUnbilled = Billed); rows ClinicName;
                            No. of Claims (ClaimsBilled column) = every claim,
                            Adjudicated = Adjudicated, Denied = DeniedStatus = Denied,
                            Denied % = Denied / Adjudicated; sorted by No. of Claims.
   Result contracts are unchanged (the ClaimsBilled column now holds every claim).
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'51_NW_DenialSummary_ClientLogic2.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/* ---------------------------------------------------------------------------
   Monthly / Weekly engine
   @Grain 'M' = every NWLDenialPostedDate month except Jan 2025, with a total per year
          'W' = the 4 Thursday-Wednesday weeks ending on the Wednesday on/after the
                billed week-range end date (latest WeekFolder; latest
                NWLDenialPostedDate up to today when there is no week folder).
                Labelled "dd MMM - dd MMM". A claim's week:
                 - PostedWeek "Week 1".."Week 4" -> that week (Week 1 = oldest)
                 - PostedWeek "MM.dd.yyyy - MM.dd.yyyy" -> the week holding its start
                 - otherwise the week of its NWLDenialPostedDate
                Claims outside the 4 weeks are not in the Weekly tab.
   @DenialFrom / @DenialTo filter NWLDenialPostedDate.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_NW_DenialAnalysis_Compute
    @Grain       CHAR(1),
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Grain NOT IN ('M', 'W')
    BEGIN
        RAISERROR('usp_NW_DenialAnalysis_Compute: @Grain must be M or W.', 16, 1);
        RETURN;
    END;

    DECLARE @TopPayers INT = 10, @TopCodes INT = 3, @Weeks INT = 4;

    SELECT d.ClaimKey, d.PayerName, d.DenialCode, d.DenialPostedDate AS PostedDate, d.PostedWeek, d.Bal
    INTO   #c
    FROM   dbo.fn_NW_DenialSummaryClaims() d
    WHERE  (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
            OR d.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
            OR d.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
            OR d.DenialCode IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DenialCodes, N'|')))
      AND  (@DenialFrom IS NULL OR d.DenialPostedDate >= @DenialFrom)
      AND  (@DenialTo   IS NULL OR d.DenialPostedDate <= @DenialTo)
      -- Monthly: NWLDenialPostedDate not in Jan 2025.
      AND  NOT (@Grain = 'M' AND d.DenialPostedDate >= '20250101' AND d.DenialPostedDate < '20250201');

    /* Weekly window: 4 Thu-Wed weeks, Week 4 ending on the Wednesday on/after the week-range end */
    DECLARE @Anchor DATE, @W4End DATE, @W1Start DATE;
    IF @Grain = 'W'
    BEGIN
        SELECT @Anchor = MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
        FROM   dbo.ClaimLevelData
        WHERE  WeekFolder IS NOT NULL;
        IF @Anchor IS NULL
            SELECT @Anchor = MAX(PostedDate) FROM #c WHERE PostedDate <= CAST(GETDATE() AS DATE);

        -- 1900-01-03 was a Wednesday.
        SET @W4End   = DATEADD(DAY, (7 - DATEDIFF(DAY, '19000103', @Anchor) % 7) % 7, @Anchor);
        SET @W1Start = DATEADD(DAY, -27, @W4End);
    END;

    /* Bucket of every claim */
    SELECT c.ClaimKey, c.PayerName, c.DenialCode, c.Bal, c.PostedDate, c.PostedWeek,
           CAST(CASE WHEN @Grain = 'M'
                     THEN CASE WHEN c.PostedDate IS NOT NULL
                               THEN CONVERT(CHAR(10), DATEFROMPARTS(YEAR(c.PostedDate), MONTH(c.PostedDate), 1), 120) END
                     WHEN wk.WeekIdx BETWEEN 1 AND @Weeks
                     THEN N'W|' + CAST(wk.WeekIdx AS NVARCHAR(10))
                END AS NVARCHAR(520)) AS BucketKey
    INTO   #cb
    FROM   #c c
    CROSS  APPLY (SELECT TRY_CONVERT(DATE, REPLACE(LTRIM(RTRIM(
                             LEFT(c.PostedWeek, NULLIF(CHARINDEX(N'-', c.PostedWeek), 0) - 1))), N'.', N'/'), 101) AS PostedStart) pw
    CROSS  APPLY (SELECT CASE WHEN @Grain <> 'W' THEN NULL
                              WHEN c.PostedWeek LIKE N'Week [1-4]'
                                  THEN CAST(RIGHT(c.PostedWeek, 1) AS INT)
                              WHEN pw.PostedStart BETWEEN @W1Start AND @W4End
                                  THEN 4 - DATEDIFF(DAY, pw.PostedStart, @W4End) / 7
                              WHEN c.PostedWeek IS NULL AND c.PostedDate BETWEEN @W1Start AND @W4End
                                  THEN 4 - DATEDIFF(DAY, c.PostedDate, @W4End) / 7
                         END AS WeekIdx) wk;

    DELETE FROM #cb WHERE BucketKey IS NULL;

    /* Period columns */
    CREATE TABLE #per
    (
        BucketKey   NVARCHAR(520) NOT NULL,
        PeriodType  CHAR(1)       NOT NULL,
        PeriodKey   VARCHAR(10)   NOT NULL,
        PeriodLabel NVARCHAR(40)  NOT NULL,
        PeriodStart DATE          NULL,
        PeriodEnd   DATE          NULL,
        PeriodYear  INT           NULL,
        SortKey     INT           NOT NULL
    );

    IF @Grain = 'M'
    BEGIN
        INSERT INTO #per (BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear, SortKey)
        SELECT CONVERT(NVARCHAR(520), CONVERT(CHAR(10), m.MonthStart, 120)),
               'M',
               CONVERT(VARCHAR(10), m.MonthStart, 120),
               CAST(FORMAT(m.MonthStart, 'MMM', 'en-US') AS NVARCHAR(40)),
               m.MonthStart,
               EOMONTH(m.MonthStart),
               YEAR(m.MonthStart),
               DATEDIFF(DAY, '19000101', m.MonthStart)
        FROM  (SELECT DISTINCT DATEFROMPARTS(YEAR(PostedDate), MONTH(PostedDate), 1) AS MonthStart
               FROM   #cb
               WHERE  PostedDate IS NOT NULL) m;
    END
    ELSE
    BEGIN
        -- All four weeks are columns, even a week with no denials.
        INSERT INTO #per (BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear, SortKey)
        SELECT N'W|' + CAST(k.WeekIdx AS NVARCHAR(10)), 'W',
               CONVERT(VARCHAR(10), d.ws, 120),
               CAST(FORMAT(d.ws, 'dd MMM', 'en-US') + N' - ' + FORMAT(d.we, 'dd MMM', 'en-US') AS NVARCHAR(40)),
               d.ws, d.we, YEAR(d.ws), k.WeekIdx
        FROM   (VALUES (1), (2), (3), (4)) k(WeekIdx)
        CROSS  APPLY (SELECT DATEADD(DAY, -6 - 7 * (4 - k.WeekIdx), @W4End) AS ws,
                             DATEADD(DAY,     -7 * (4 - k.WeekIdx), @W4End) AS we) d
        WHERE  @W4End IS NOT NULL;
    END;

    SELECT CAST(BucketKey AS NVARCHAR(520)) AS BucketKey, PeriodType, PeriodKey, PeriodLabel,
           PeriodStart, PeriodEnd, PeriodYear, SortKey
    INTO   #col0
    FROM   #per
    UNION ALL
    SELECT N'', 'Y', CAST('total-' + CAST(PeriodYear AS VARCHAR(4)) AS VARCHAR(10)),
           CAST(CAST(PeriodYear AS VARCHAR(4)) + ' | Total' AS NVARCHAR(40)),
           MIN(PeriodStart), MAX(PeriodEnd), PeriodYear, 0
    FROM   #per
    WHERE  @Grain = 'M'
    GROUP  BY PeriodYear
    UNION ALL
    SELECT N'', 'A', CAST('' AS VARCHAR(10)), CAST(N'Grand Total' AS NVARCHAR(40)), NULL, NULL, NULL, 0;

    SELECT BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN PeriodType = 'A' THEN 1 ELSE 0 END,
                                       CASE WHEN @Grain = 'M' THEN PeriodYear END,
                                       CASE WHEN PeriodType = 'Y' THEN 1 ELSE 0 END,
                                       SortKey) AS ColOrder
    INTO   #col
    FROM   #col0;

    /* Claims the columns hold; totals, ranks and coverage describe these only */
    SELECT n.PayerName, dbo.fn_NW_PayerKey(n.PayerName) AS PayerKey
    INTO   #pk
    FROM  (SELECT DISTINCT PayerName FROM #cb) n;

    SELECT c.ClaimKey, c.PayerName, k.PayerKey, c.DenialCode, c.Bal, p.BucketKey, p.PeriodYear
    INTO   #b
    FROM   #cb c
    JOIN   #per p ON p.BucketKey = c.BucketKey
    JOIN   #pk k  ON k.PayerName = c.PayerName;

    /* Payers by No. of Claims, then balance */
    SELECT PayerKey,
           ISNULL(MIN(NULLIF(PayerName, N'')), N'(no payer)') AS PayerLabel,
           SUM(Bal) AS Bal,
           ROW_NUMBER() OVER (ORDER BY COUNT(ClaimKey) DESC, SUM(Bal) DESC, PayerKey) AS PayerRank
    INTO   #pr
    FROM   #b
    GROUP  BY PayerKey;

    DECLARE @Coverage DECIMAL(9,2) = ISNULL(
        (SELECT CASE WHEN SUM(Bal) > 0
                     THEN ROUND(SUM(CASE WHEN PayerRank <= @TopPayers THEN Bal ELSE 0 END) * 100.0 / SUM(Bal), 0)
                     ELSE 0 END
         FROM   #pr), 0);

    /* Top 3 denial codes per listed payer, by No. of Claims, then balance */
    SELECT b.PayerKey, b.DenialCode,
           ROW_NUMBER() OVER (PARTITION BY b.PayerKey
                              ORDER BY COUNT(b.ClaimKey) DESC, SUM(b.Bal) DESC, b.DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b b
    JOIN   #pr p ON p.PayerKey = b.PayerKey AND p.PayerRank <= @TopPayers
    GROUP  BY b.PayerKey, b.DenialCode;

    DELETE FROM #cr WHERE CodeRank > @TopCodes;

    /* Rows: payer A..J, its codes numbered down the whole table, Grand Total last */
    SELECT 'P' AS RowType, p.PayerKey, CAST(N'' AS NVARCHAR(400)) AS DenialCode, p.PayerRank, 0 AS CodeRank,
           p.PayerRank * 10 AS RowSeq,
           CAST(CHAR(64 + p.PayerRank) AS VARCHAR(10)) AS IndexLabel,
           CAST(p.PayerLabel AS NVARCHAR(4000)) AS RowLabel,
           p.PayerLabel
    INTO   #r
    FROM   #pr p
    WHERE  p.PayerRank <= @TopPayers
    UNION ALL
    SELECT 'C', c.PayerKey, c.DenialCode, p.PayerRank, c.CodeRank,
           p.PayerRank * 10 + c.CodeRank,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerRank, c.CodeRank) AS VARCHAR(10)),
           dbo.fn_NW_DenialRowLabel(c.DenialCode, NULL),
           p.PayerLabel
    FROM   #cr c
    JOIN   #pr p ON p.PayerKey = c.PayerKey
    UNION ALL
    SELECT 'T', N'', N'', 0, 0, 2147483647, '', N'Grand Total', N'Grand Total';

    /* Cells: period, year subtotal (Monthly) and grand total of every row */
    ;WITH m AS
    (
        SELECT r.RowSeq, b.ClaimKey, b.Bal, b.BucketKey, b.PeriodYear
        FROM   #b b
        JOIN   #r r ON r.RowType IN ('P', 'C') AND r.PayerKey = b.PayerKey
                   AND (r.RowType = 'P' OR r.DenialCode = b.DenialCode)
        UNION ALL
        SELECT 2147483647, b.ClaimKey, b.Bal, b.BucketKey, b.PeriodYear
        FROM   #b b
    )
    SELECT RowSeq,
           CAST(CASE WHEN GROUPING(BucketKey) = 0 THEN @Grain
                     WHEN GROUPING(PeriodYear) = 0 THEN 'Y'
                     ELSE 'A' END AS CHAR(1)) AS PeriodType,
           BucketKey, PeriodYear,
           COUNT(ClaimKey) AS ClaimCount,
           SUM(Bal)                 AS Bal
    INTO   #cell
    FROM   m
    GROUP  BY GROUPING SETS ((RowSeq, PeriodYear, BucketKey), (RowSeq, PeriodYear), (RowSeq));

    ;WITH grid AS
    (
        SELECT r.RowType, r.DenialCode, r.PayerRank, r.CodeRank, r.RowSeq, r.IndexLabel, r.RowLabel, r.PayerLabel,
               k.PeriodType, k.PeriodKey, k.PeriodLabel, k.ColOrder,
               k.PeriodStart AS ColStart, k.PeriodEnd AS ColEnd, k.PeriodYear AS ColYear,
               x.ClaimCount, x.Bal
        FROM   #r r
        CROSS  JOIN #col k
        LEFT   JOIN #cell x ON x.RowSeq = r.RowSeq
                           AND x.PeriodType = k.PeriodType
                           AND (   k.PeriodType = 'A'
                                OR (k.PeriodType = 'Y' AND x.PeriodYear = k.PeriodYear)
                                OR (k.PeriodType IN ('M', 'W') AND x.BucketKey = k.BucketKey))
        WHERE  r.RowType = 'T' OR x.RowSeq IS NOT NULL
    )
    SELECT CAST(RowType AS CHAR(1))                  AS RowType,
           CAST(PayerLabel AS NVARCHAR(500))         AS PayerName,
           CAST(DenialCode AS NVARCHAR(400))         AS DenialCode,
           PayerRank, CodeRank,
           PeriodType,
           PeriodKey,
           ColYear  AS PeriodYear,
           ColStart AS PeriodStart,
           ColEnd   AS PeriodEnd,
           PeriodLabel,
           ISNULL(ClaimCount, 0)                 AS ClaimCount,
           CAST(ISNULL(Bal, 0) AS DECIMAL(18,2)) AS TotalInsuranceBalance,
           DENSE_RANK() OVER (ORDER BY RowSeq)   AS SortOrder,
           DENSE_RANK() OVER (ORDER BY ColOrder) AS PeriodOrder,
           IndexLabel,
           RowLabel,
           @Coverage AS CoveragePct
    FROM   grid
    ORDER  BY SortOrder, PeriodOrder;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Facility wise
   RowType 'F' clinic (ClinicName), 'D' denial code under the clinic, 'T' grand total.
   ClinicName not blank. Sorted by Claim Count, then balance.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialByFacility
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL,
    @ForceLive   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialByFacility)
    BEGIN
        SELECT RowType, ClinicName, DenialCode, ClaimCount, TotalInsuranceBalance,
               SortOrder, ClinicRank, CodeRank
        FROM   dbo.NW_DenialByFacility
        ORDER  BY SortOrder;
        RETURN;
    END;

    SELECT d.ClaimID, d.ClinicName, d.DenialCode, d.TotalInsuranceBalance AS Bal
    INTO   #b
    FROM   dbo.fn_NW_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
    WHERE  d.TotalInsuranceBalance > 0
      AND  d.DenialCode IS NOT NULL
      AND  d.ClinicName <> N'(Blank)';   -- vw_NW_DenialClaims shows a blank ClinicName as '(Blank)'

    SELECT ClinicName,
           ROW_NUMBER() OVER (ORDER BY COUNT(ClaimID) DESC, SUM(Bal) DESC, ClinicName) AS ClinicRank
    INTO   #fr
    FROM   #b
    GROUP  BY ClinicName;

    SELECT ClinicName, DenialCode,
           ROW_NUMBER() OVER (PARTITION BY ClinicName
                              ORDER BY COUNT(ClaimID) DESC, SUM(Bal) DESC, DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b
    GROUP  BY ClinicName, DenialCode;

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(b.ClinicName) = 1 THEN 'T'
                    WHEN GROUPING(b.DenialCode) = 1 THEN 'F'
                    ELSE 'D' END                               AS RowType,
               ISNULL(b.ClinicName, N'Grand Total')            AS ClinicName,
               ISNULL(b.DenialCode, N'')                       AS DenialCode,
               COUNT(b.ClaimID)                       AS ClaimCount,
               CAST(ISNULL(SUM(b.Bal), 0) AS DECIMAL(18,2))    AS TotalInsuranceBalance
        FROM   #b b
        GROUP  BY GROUPING SETS ((b.ClinicName, b.DenialCode), (b.ClinicName), ())
    ),
    ranked AS
    (
        SELECT g.RowType, g.ClinicName, g.DenialCode, g.ClaimCount, g.TotalInsuranceBalance,
               ISNULL(fr.ClinicRank, 0) AS ClinicRank,
               ISNULL(cr.CodeRank, 0)   AS CodeRank
        FROM   g
        LEFT   JOIN #fr fr ON fr.ClinicName = g.ClinicName AND g.RowType <> 'T'
        LEFT   JOIN #cr cr ON cr.ClinicName = g.ClinicName AND cr.DenialCode = g.DenialCode AND g.RowType = 'D'
    )
    SELECT CAST(RowType AS CHAR(1)) AS RowType, ClinicName, DenialCode, ClaimCount, TotalInsuranceBalance,
           CAST(ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                            ClinicRank,
                                            CASE WHEN RowType = 'F' THEN 0 ELSE 1 END,
                                            CodeRank) AS INT) AS SortOrder,
           ClinicRank, CodeRank
    FROM   ranked
    ORDER  BY SortOrder;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Denial vs Facility %
   Filter : none (every claim). ClaimsBilled = No. of Claims (every claim of the clinic),
   AdjudicatedClaims = Adjudicated = 'Adjudicated', DeniedClaims = DeniedStatus = 'Denied'.
   RowType 'F' clinic, 'T' grand total. Sorted by No. of Claims DESC.
   @PayerNames / @PayerTypes / @DenialFrom / @DenialTo (CheckDate) are optional;
   @DenialCodes is accepted for contract parity and ignored.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialFacilityPct
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL,
    @ForceLive   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialFacilityPct)
    BEGIN
        SELECT RowType, ClinicName, ClaimsBilled, AdjudicatedClaims, DeniedClaims, DeniedPct,
               SortOrder, ClinicRank
        FROM   dbo.NW_DenialFacilityPct
        ORDER  BY SortOrder;
        RETURN;
    END;

    SELECT n.ClaimKey,
           n.ClinicName,
           1                                                                                AS IsBilled,
           CASE WHEN LTRIM(RTRIM(ISNULL(c.Adjudicated, N'')))   = N'Adjudicated'  THEN 1 ELSE 0 END AS IsAdjudicated,
           CASE WHEN LTRIM(RTRIM(ISNULL(c.DeniedStatus, N'')))  = N'Denied'       THEN 1 ELSE 0 END AS IsDenied
    INTO   #f
    FROM   dbo.ClaimLevelData c
    CROSS  APPLY (SELECT NULLIF(LTRIM(RTRIM(c.ClaimID)), N'')                                        AS ClaimKey,
                         ISNULL(NULLIF(LTRIM(RTRIM(c.ClinicName)), N''), N'(Blank)')                 AS ClinicName,
                         ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown')              AS PayerName,
                         ISNULL(NULLIF(LTRIM(RTRIM(c.PayerType)), N''), N'Unknown')                  AS PayerType,
                         TRY_CAST(NULLIF(LTRIM(RTRIM(c.CheckDate)), N'') AS DATE)                    AS CheckDt) n
    WHERE  n.ClaimKey IS NOT NULL
      AND  (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
            OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
            OR n.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND  (@DenialFrom IS NULL OR n.CheckDt >= @DenialFrom)
      AND  (@DenialTo   IS NULL OR n.CheckDt <= @DenialTo);

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(ClinicName) = 1 THEN 'T' ELSE 'F' END AS RowType,
               ISNULL(ClinicName, N'Grand Total')                      AS ClinicName,
               COUNT(CASE WHEN IsBilled      = 1 THEN ClaimKey END) AS ClaimsBilled,
               COUNT(CASE WHEN IsAdjudicated = 1 THEN ClaimKey END) AS AdjudicatedClaims,
               COUNT(CASE WHEN IsDenied      = 1 THEN ClaimKey END) AS DeniedClaims
        FROM   #f
        GROUP  BY GROUPING SETS ((ClinicName), ())
    ),
    ranked AS
    (
        SELECT g.RowType, g.ClinicName, g.ClaimsBilled, g.AdjudicatedClaims, g.DeniedClaims,
               CAST(g.DeniedClaims * 1.0 / NULLIF(g.AdjudicatedClaims, 0) AS DECIMAL(18,6)) AS DeniedPct,
               CASE WHEN g.RowType = 'F'
                    THEN ROW_NUMBER() OVER (PARTITION BY g.RowType ORDER BY g.ClaimsBilled DESC, g.ClinicName)
                    ELSE 0 END AS ClinicRank
        FROM   g
    )
    SELECT CAST(RowType AS CHAR(1)) AS RowType, ClinicName, ClaimsBilled, AdjudicatedClaims, DeniedClaims, DeniedPct,
           CAST(ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                            ClaimsBilled DESC, ClinicName) AS INT) AS SortOrder,
           ClinicRank
    FROM   ranked
    ORDER  BY SortOrder;
END
GO

/* ---------------------------------------------------------------------------
   Rebuild the affected snapshots (Monthly also refreshes the tiles)
   --------------------------------------------------------------------------- */
EXEC dbo.usp_RefreshNW_DenialMonthly;
GO
EXEC dbo.usp_RefreshNW_DenialWeekly;
GO
EXEC dbo.usp_RefreshNW_DenialByFacility;
GO
EXEC dbo.usp_RefreshNW_DenialFacilityPct;
GO

SET NOEXEC OFF;
GO

PRINT '51_NW_DenialSummary_ClientLogic2.sql completed.';
GO

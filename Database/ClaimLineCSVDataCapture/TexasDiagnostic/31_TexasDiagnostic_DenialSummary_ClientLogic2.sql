/* =============================================================================
   TexasDiagnostic - Denial Summary client logic (2026-10-30)
   Database : TexasDiagnostic        Run after 30_TexasDiagnostic_DenialSummary.sql

   Monthly  Filter  : ClaimLevelDenialCode not blank (was DenialCode)
            Rows    : Top 10 PayerName_Raw by Total Insurance Balance (was every
                      payer by claim count), Top 3 DenialCodeNormalized by claim count
            Columns : DenialDate month
   Weekly   Filter  : ClaimLevelDenialCode not blank (was DenialCode)
            Rows    : Top 10 PayerName_Raw by claim count (was every payer),
                      Top 3 DenialCodeNormalized by claim count
            Columns : Friday-Thursday weeks; DeniedWeek "Week 1".."Week 4" when not
                      blank, otherwise the week of DenialDate
   Denial List and the tiles count the same ClaimLevelDenialCode claims.
   Result contracts are unchanged.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
    RAISERROR('Run 31_TexasDiagnostic_DenialSummary_ClientLogic2.sql on the TexasDiagnostic database.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------------------
   Base view / filter function (Denial List, filter options)
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TD_DenialClaims
AS
SELECT
    CAST(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), '') AS NVARCHAR(200))            AS ClaimID,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), c.PayerName_Raw))), ''), 'Unknown') AS NVARCHAR(500)) AS PayerName,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.PayerType))), ''), 'Unknown') AS NVARCHAR(200))     AS PayerType,
    CAST(CASE WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode))), '') IS NOT NULL
              THEN COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.DenialCodeNormalized))), ''),
                            LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode)))) END AS NVARCHAR(400)) AS DenialCode,
    COALESCE(TRY_CONVERT(DATE, c.DenialDate, 101), TRY_CAST(c.DenialDate AS DATE))                AS DenialDate,
    ISNULL(TRY_CONVERT(DECIMAL(18,2),
                       REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), '$', ''), ',', '')), 0)
                                                                                                  AS TotalInsuranceBalance
FROM dbo.ClaimLevelData c;
GO

/* ---------------------------------------------------------------------------
   Monthly / Weekly / tiles claim rows: one row per claim whose ClaimLevelDenialCode
   is not blank. Denial Code = DenialCodeNormalized, Denial Date = DenialDate,
   DeniedWeek as written ("Week 1".."Week 4"), NULL when blank.
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_TD_DenialSummaryClaims()
RETURNS TABLE
AS
RETURN
    SELECT NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'')                AS ClaimKey,
           CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), c.PayerName_Raw), N''))) AS NVARCHAR(500)) AS PayerName,
           CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.PayerType), N''))) AS NVARCHAR(200))     AS PayerType,
           CAST(COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.DenialCodeNormalized))), N''),
                         LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode)))) AS NVARCHAR(400)) AS DenialCode,
           LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(4000), c.DenialDescription), N'')))     AS DenialDescription,
           COALESCE(TRY_CONVERT(DATE, c.DenialDate, 101), TRY_CAST(c.DenialDate AS DATE)) AS DenialDate,
           CAST(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.DeniedWeek))), N'') AS NVARCHAR(100)) AS DeniedWeek,
           ISNULL(b.Bal, 0)                                                             AS Bal
    FROM   dbo.ClaimLevelData c
    CROSS  APPLY (SELECT TRY_CONVERT(DECIMAL(18,2),
                         REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), N'$', N''), N',', N'')) AS Bal) b
    WHERE  LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode), N''))) <> N'';
GO

/* ---------------------------------------------------------------------------
   Monthly / Weekly engine
   @Grain 'M' = every Denial Month up to the loaded week, with a total per year;
                insurances by Total Insurance Balance
          'W' = the 4 Friday-Thursday weeks ending with the week of the newest
                WeekFolder end date; a claim's week is its DeniedWeek "Week 1".."Week 4"
                (Week 4 = newest), else the week of its DenialDate; insurances by
                No. of Claims
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_TD_DenialAnalysis_Compute
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
        RAISERROR('usp_TD_DenialAnalysis_Compute: @Grain must be M or W.', 16, 1);
        RETURN;
    END;

    DECLARE @TopPayers INT = 10, @TopCodes INT = 3, @Weeks INT = 4;
    -- 2026-09-18 was a Friday; ((n % 7) + 7) % 7 keeps the offset positive.
    DECLARE @Friday DATE = '20260918', @LastFri DATE;

    -- End date of the newest WeekFolder ("10.14.2026 - 10.20.2026" -> 2026-10-20).
    DECLARE @LoadedThrough DATE =
    (
        SELECT MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
        FROM   dbo.ClaimLevelData
        WHERE  WeekFolder IS NOT NULL
    );

    SELECT d.ClaimKey, d.PayerName, d.DenialCode, d.DenialDescription, d.DenialDate, d.DeniedWeek, d.Bal
    INTO   #c
    FROM   dbo.fn_TD_DenialSummaryClaims() d
    WHERE  d.ClaimKey IS NOT NULL
      AND  (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
            OR d.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
            OR d.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
            OR d.DenialCode IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DenialCodes, N'|')))
      AND  (@DenialFrom IS NULL OR d.DenialDate >= @DenialFrom)
      AND  (@DenialTo   IS NULL OR d.DenialDate <= @DenialTo);

    /* Columns */
    CREATE TABLE #per (PeriodType CHAR(1) NOT NULL, PeriodStart DATE NOT NULL, PeriodEnd DATE NOT NULL, PeriodYear INT NOT NULL);

    IF @Grain = 'M'
    BEGIN
        DECLARE @Cutoff DATE =
            CASE WHEN @LoadedThrough IS NOT NULL
                      AND EXISTS (SELECT 1 FROM #c WHERE DenialDate <= @LoadedThrough)
                 THEN @LoadedThrough END;

        INSERT INTO #per (PeriodType, PeriodStart, PeriodEnd, PeriodYear)
        SELECT DISTINCT 'M', DATEFROMPARTS(YEAR(DenialDate), MONTH(DenialDate), 1), EOMONTH(DenialDate), YEAR(DenialDate)
        FROM   #c
        WHERE  DenialDate IS NOT NULL
          AND  (@Cutoff IS NULL OR DenialDate <= @Cutoff);
    END
    ELSE
    BEGIN
        DECLARE @Anchor DATE = ISNULL(@LoadedThrough, (SELECT MAX(DenialDate) FROM #c));
        SET @LastFri = DATEADD(DAY, -((DATEDIFF(DAY, @Friday, @Anchor) % 7 + 7) % 7), @Anchor);

        INSERT INTO #per (PeriodType, PeriodStart, PeriodEnd, PeriodYear)
        SELECT 'W', DATEADD(DAY, -7 * v.n, @LastFri), DATEADD(DAY, 6 - 7 * v.n, @LastFri),
               YEAR(DATEADD(DAY, -7 * v.n, @LastFri))
        FROM   (VALUES (0), (1), (2), (3)) v(n)
        WHERE  v.n < @Weeks AND @LastFri IS NOT NULL;
    END;

    SELECT PeriodType, PeriodStart, PeriodEnd, PeriodYear
    INTO   #col
    FROM   #per
    UNION ALL
    SELECT 'Y', MIN(PeriodStart), MAX(PeriodEnd), PeriodYear
    FROM   #per
    WHERE  @Grain = 'M'
    GROUP  BY PeriodYear
    UNION ALL
    SELECT 'A', NULL, NULL, NULL;

    /* Claims the columns hold; totals, ranks and coverage describe these only */
    SELECT n.PayerName, dbo.fn_TD_PayerKey(n.PayerName) AS PayerKey
    INTO   #pk
    FROM  (SELECT DISTINCT PayerName FROM #c) n;

    SELECT c.ClaimKey, c.PayerName, k.PayerKey, c.DenialCode, c.DenialDescription, c.Bal,
           p.PeriodStart, p.PeriodYear
    INTO   #b
    FROM   #c c
    CROSS  APPLY (SELECT CASE WHEN @Grain = 'W' AND c.DeniedWeek LIKE N'Week [1-4]'
                              THEN DATEADD(DAY, 7 * (CAST(RIGHT(c.DeniedWeek, 1) AS INT) - @Weeks), @LastFri)
                              ELSE c.DenialDate END AS BucketDate) w
    JOIN   #per p ON w.BucketDate BETWEEN p.PeriodStart AND p.PeriodEnd
    JOIN   #pk k  ON k.PayerName = c.PayerName;

    /* Insurances: Monthly by Total Insurance Balance, then No. of Claims;
       Weekly by No. of Claims, then Total Insurance Balance */
    SELECT PayerKey,
           ISNULL(MIN(NULLIF(PayerName, N'')), N'(no payer)') AS PayerLabel,
           SUM(Bal) AS Bal,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN @Grain = 'M' THEN SUM(Bal) ELSE COUNT(DISTINCT ClaimKey) END DESC,
                                       CASE WHEN @Grain = 'M' THEN COUNT(DISTINCT ClaimKey) ELSE SUM(Bal) END DESC,
                                       PayerKey) AS PayerRank
    INTO   #pr
    FROM   #b
    GROUP  BY PayerKey;

    DECLARE @Coverage DECIMAL(9,2) = ISNULL(
        (SELECT CASE WHEN SUM(Bal) > 0
                     THEN ROUND(SUM(CASE WHEN PayerRank <= @TopPayers THEN Bal ELSE 0 END) * 100.0 / SUM(Bal), 0)
                     ELSE 0 END
         FROM   #pr), 0);

    /* Top 3 Denial Codes per insurance, by No. of Claims, then Total Insurance Balance */
    SELECT b.PayerKey, b.DenialCode,
           ISNULL(MIN(NULLIF(b.DenialDescription, N'')), N'') AS DenialDescription,
           ROW_NUMBER() OVER (PARTITION BY b.PayerKey
                              ORDER BY COUNT(DISTINCT b.ClaimKey) DESC, SUM(b.Bal) DESC, b.DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b b
    JOIN   #pr p ON p.PayerKey = b.PayerKey AND p.PayerRank <= @TopPayers
    GROUP  BY b.PayerKey, b.DenialCode;

    DELETE FROM #cr WHERE CodeRank > @TopCodes;

    /* Rows: insurance A..Z, AA.., its codes numbered down the whole table, Grand Total last */
    SELECT 'P' AS RowType, p.PayerKey, CAST(N'' AS NVARCHAR(400)) AS DenialCode, p.PayerRank, 0 AS CodeRank,
           p.PayerRank * 10 AS RowSeq,
           CASE WHEN p.PayerRank <= 26 THEN CAST(CHAR(64 + p.PayerRank) AS VARCHAR(10))
                ELSE CAST(CHAR(64 + (p.PayerRank - 1) / 26) AS VARCHAR(10)) + CHAR(65 + (p.PayerRank - 1) % 26) END AS IndexLabel,
           CAST(p.PayerLabel AS NVARCHAR(4000)) AS RowLabel,
           p.PayerLabel
    INTO   #r
    FROM   #pr p
    WHERE  p.PayerRank <= @TopPayers
    UNION ALL
    SELECT 'C', c.PayerKey, c.DenialCode, p.PayerRank, c.CodeRank,
           p.PayerRank * 10 + c.CodeRank,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerRank, c.CodeRank) AS VARCHAR(10)),
           dbo.fn_TD_DenialRowLabel(c.DenialCode, c.DenialDescription),
           p.PayerLabel
    FROM   #cr c
    JOIN   #pr p ON p.PayerKey = c.PayerKey
    UNION ALL
    SELECT 'T', N'', N'', 0, 0, 2147483647, '', N'Grand Total', N'Grand Total';

    /* Cells: period, year subtotal (Monthly) and grand total of every row */
    ;WITH m AS
    (
        SELECT r.RowSeq, b.ClaimKey, b.Bal, b.PeriodStart, b.PeriodYear
        FROM   #b b
        JOIN   #r r ON r.RowType IN ('P', 'C') AND r.PayerKey = b.PayerKey
                   AND (r.RowType = 'P' OR r.DenialCode = b.DenialCode)
        UNION ALL
        SELECT 2147483647, b.ClaimKey, b.Bal, b.PeriodStart, b.PeriodYear
        FROM   #b b
    )
    SELECT RowSeq,
           CAST(CASE WHEN GROUPING(PeriodStart) = 0 THEN @Grain
                     WHEN GROUPING(PeriodYear)  = 0 THEN 'Y'
                     ELSE 'A' END AS CHAR(1)) AS PeriodType,
           PeriodStart, PeriodYear,
           COUNT(DISTINCT ClaimKey) AS ClaimCount,
           SUM(Bal)                 AS Bal
    INTO   #cell
    FROM   m
    GROUP  BY GROUPING SETS ((RowSeq, PeriodYear, PeriodStart), (RowSeq, PeriodYear), (RowSeq));

    ;WITH grid AS
    (
        SELECT r.RowType, r.DenialCode, r.PayerRank, r.CodeRank, r.RowSeq, r.IndexLabel, r.RowLabel, r.PayerLabel,
               k.PeriodType, k.PeriodStart AS ColStart, k.PeriodEnd AS ColEnd, k.PeriodYear AS ColYear,
               x.ClaimCount, x.Bal
        FROM   #r r
        CROSS  JOIN #col k
        LEFT   JOIN #cell x ON x.RowSeq = r.RowSeq
                           AND x.PeriodType = k.PeriodType
                           AND (k.PeriodType = 'A' OR x.PeriodYear = k.PeriodYear)
                           AND (k.PeriodType IN ('Y', 'A') OR x.PeriodStart = k.PeriodStart)
        WHERE  r.RowType = 'T' OR x.RowSeq IS NOT NULL
    )
    SELECT RowType,
           PayerLabel AS PayerName,
           DenialCode, PayerRank, CodeRank,
           PeriodType,
           CAST(CASE PeriodType WHEN 'Y' THEN 'total-' + CAST(ColYear AS VARCHAR(4))
                                WHEN 'A' THEN ''
                                ELSE CONVERT(CHAR(10), ColStart, 120) END AS VARCHAR(10)) AS PeriodKey,
           ColYear  AS PeriodYear,
           ColStart AS PeriodStart,
           ColEnd   AS PeriodEnd,
           CAST(CASE PeriodType WHEN 'M' THEN FORMAT(ColStart, 'MMM', 'en-US')
                                WHEN 'W' THEN FORMAT(ColStart, 'dd MMM', 'en-US') + N' - ' + FORMAT(ColEnd, 'dd MMM', 'en-US')
                                WHEN 'Y' THEN CAST(ColYear AS VARCHAR(4)) + ' | Total'
                                ELSE 'Grand Total' END AS NVARCHAR(40)) AS PeriodLabel,
           ISNULL(ClaimCount, 0)                 AS ClaimCount,
           CAST(ISNULL(Bal, 0) AS DECIMAL(18,2)) AS TotalInsuranceBalance,
           DENSE_RANK() OVER (ORDER BY RowSeq)   AS SortOrder,
           DENSE_RANK() OVER (ORDER BY CASE WHEN PeriodType = 'A' THEN 1 ELSE 0 END, ColYear,
                                       CASE WHEN PeriodType = 'Y' THEN 1 ELSE 0 END, ColStart) AS PeriodOrder,
           IndexLabel,
           RowLabel,
           @Coverage AS CoveragePct
    FROM   grid
    ORDER  BY SortOrder, PeriodOrder;
END
GO

-- fn_TD_DenialClaims selects d.* from the view; refresh its column metadata.
EXEC sp_refreshsqlmodule N'dbo.fn_TD_DenialClaims';
GO

EXEC dbo.usp_RefreshTD_DenialMonthly;
EXEC dbo.usp_RefreshTD_DenialWeekly;
EXEC dbo.usp_RefreshTD_DenialList;
GO

PRINT '31_TexasDiagnostic_DenialSummary_ClientLogic2.sql completed.';
GO

SET NOEXEC OFF;
GO

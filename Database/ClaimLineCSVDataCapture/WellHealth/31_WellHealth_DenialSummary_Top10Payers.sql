/* =============================================================================
   WellHealth - Denial Summary: Top 10 insurances
   Database : WellHealth        Run after 30_WellHealth_DenialSummary.sql

   Client logic change (2026-10-30), Monthly / Weekly tabs:
     Rows    : Top 10 insurances (PayerName_Raw) by Total Insurance Balance, then
               No. of Claims (was every insurance)
     Drill   : Top 3 Denial Codes per insurance by Total Insurance Balance (unchanged)
   Filters, columns, Grand Total and the Denial List tabs are unchanged.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'WellHealth'
BEGIN
    RAISERROR('Run 31_WellHealth_DenialSummary_Top10Payers.sql on the WellHealth database.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------------------
   Monthly / Weekly engine
   @Grain 'M' = every Denial Month up to the loaded week, with a total per year
          'W' = the 4 Monday-Sunday weeks ending with the week of the newest
                WeekFolder end date
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_WH_DenialAnalysis_Compute
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
        RAISERROR('usp_WH_DenialAnalysis_Compute: @Grain must be M or W.', 16, 1);
        RETURN;
    END;

    DECLARE @TopPayers INT = 10, @TopCodes INT = 3, @Weeks INT = 4;

    -- End date of the newest WeekFolder ("09.21.2026 - 09.27.2026" -> 2026-09-27).
    DECLARE @LoadedThrough DATE =
    (
        SELECT MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
        FROM   dbo.ClaimLevelData
        WHERE  WeekFolder IS NOT NULL
    );

    SELECT d.ClaimKey, d.PayerName, d.DenialCode, d.DenialDescription, d.DenialDate, d.Bal
    INTO   #c
    FROM   dbo.fn_WH_DenialSummaryClaims() d
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

    -- Monday of a date's week: 1900-01-01 is a Monday, whatever SET DATEFIRST says.
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
    ELSE IF @LoadedThrough IS NOT NULL
    BEGIN
        DECLARE @LastMonday DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @LoadedThrough) % 7), @LoadedThrough);

        INSERT INTO #per (PeriodType, PeriodStart, PeriodEnd, PeriodYear)
        SELECT 'W', DATEADD(DAY, -7 * v.n, @LastMonday), DATEADD(DAY, 6 - 7 * v.n, @LastMonday),
               YEAR(DATEADD(DAY, -7 * v.n, @LastMonday))
        FROM   (VALUES (0), (1), (2), (3)) v(n)
        WHERE  v.n < @Weeks;
    END
    ELSE
    BEGIN
        -- No WeekFolder: the newest 4 Monday-Sunday weeks the denial dates fall in.
        INSERT INTO #per (PeriodType, PeriodStart, PeriodEnd, PeriodYear)
        SELECT TOP (@Weeks) 'W', s.WeekStart, DATEADD(DAY, 6, s.WeekStart), YEAR(s.WeekStart)
        FROM  (SELECT DISTINCT DATEADD(DAY, -(DATEDIFF(DAY, '19000101', DenialDate) % 7), DenialDate) AS WeekStart
               FROM   #c
               WHERE  DenialDate IS NOT NULL) s
        ORDER  BY s.WeekStart DESC;
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
    SELECT n.PayerName, dbo.fn_WH_PayerKey(n.PayerName) AS PayerKey
    INTO   #pk
    FROM  (SELECT DISTINCT PayerName FROM #c) n;

    SELECT c.ClaimKey, c.PayerName, k.PayerKey, c.DenialCode, c.DenialDescription, c.Bal,
           p.PeriodStart, p.PeriodYear
    INTO   #b
    FROM   #c c
    JOIN   #per p ON c.DenialDate BETWEEN p.PeriodStart AND p.PeriodEnd
    JOIN   #pk k  ON k.PayerName = c.PayerName;

    /* Insurances by Total Insurance Balance, then No. of Claims */
    SELECT PayerKey,
           ISNULL(MIN(NULLIF(PayerName, N'')), N'(no payer)') AS PayerLabel,
           SUM(Bal) AS Bal,
           ROW_NUMBER() OVER (ORDER BY SUM(Bal) DESC, COUNT(DISTINCT ClaimKey) DESC, PayerKey) AS PayerRank
    INTO   #pr
    FROM   #b
    GROUP  BY PayerKey;

    DECLARE @Coverage DECIMAL(9,2) = ISNULL(
        (SELECT CASE WHEN SUM(Bal) > 0
                     THEN ROUND(SUM(CASE WHEN PayerRank <= @TopPayers THEN Bal ELSE 0 END) * 100.0 / SUM(Bal), 0)
                     ELSE 0 END
         FROM   #pr), 0);

    /* Top 3 Denial Codes per listed insurance, by Total Insurance Balance, then No. of Claims */
    SELECT b.PayerKey, b.DenialCode,
           ISNULL(MIN(NULLIF(b.DenialDescription, N'')), N'') AS DenialDescription,
           ROW_NUMBER() OVER (PARTITION BY b.PayerKey
                              ORDER BY SUM(b.Bal) DESC, COUNT(DISTINCT b.ClaimKey) DESC, b.DenialCode) AS CodeRank
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
           dbo.fn_WH_DenialRowLabel(c.DenialCode, c.DenialDescription),
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

EXEC dbo.usp_RefreshWH_DenialMonthly;
EXEC dbo.usp_RefreshWH_DenialWeekly;
GO

PRINT '31_WellHealth_DenialSummary_Top10Payers.sql completed.';
GO

SET NOEXEC OFF;
GO

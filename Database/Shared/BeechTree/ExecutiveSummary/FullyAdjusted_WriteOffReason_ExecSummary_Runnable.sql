/*==============================================================================
  SELF-CONTAINED / RUNNABLE version.

  The previous script assumed #Base and #Periods already existed (they are built
  earlier inside your larger proc). This version builds them first so it runs on
  its own.

  >>> ADJUST ME <<<
  Set @SourceHasStatus below to the table that actually holds BillStatus /
  ClaimStatus / ClaimID. It is assumed here to be dbo.ClaimLevelData. If those
  columns live in a different (billing) table, change the FROM in "Build #Base".
==============================================================================*/

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Base')    IS NOT NULL DROP TABLE #Base;
IF OBJECT_ID('tempdb..#Periods') IS NOT NULL DROP TABLE #Periods;

/*-- Build #Base : the Fully Adjusted (write-off) claims -----------------------*/
SELECT
    LTRIM(RTRIM(CAST(cl.ClaimID AS NVARCHAR(50)))) AS ClaimID,
    cl.BillStatus,
    cl.ClaimStatus
INTO #Base
FROM dbo.ClaimLevelData AS cl          -- <-- change if BillStatus/ClaimStatus live elsewhere
WHERE cl.BillStatus  = 'Billed'
  AND cl.ClaimStatus = 'Complete W/O';

/*-- Build #Periods : one row per Year/Month that actually has write-offs ------
    (grand-total handling is done in the query itself, so ESYear=0 is optional
     here; we only need the real periods.) -------------------------------------*/
SELECT DISTINCT
    YEAR (TRY_CAST(ws2.DateofService AS DATE)) AS ESYear,
    MONTH(TRY_CAST(ws2.DateofService AS DATE)) AS ESMonth
INTO #Periods
FROM dbo.BTWOSummary ws2
INNER JOIN #Base b
    ON  LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
      = LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
WHERE TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL;

/*============================ REPORTING QUERY =================================*/
;WITH WO AS
(
    SELECT
        ws2.MatchingCount,
        ISNULL(NULLIF(LTRIM(RTRIM(ws2.TransactionCodeCombined)), ''), '(No reason entered)') AS WriteOffReason,
        YEAR (TRY_CAST(ws2.DateofService AS DATE)) AS WOYear,
        MONTH(TRY_CAST(ws2.DateofService AS DATE)) AS WOMonth
    FROM   dbo.BTWOSummary ws2
    INNER JOIN #Base b
        ON  LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
          = LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
    WHERE  TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
      AND  b.BillStatus  = 'Billed'
      AND  b.ClaimStatus = 'Complete W/O'
),
Reasons AS
(
    SELECT DISTINCT WriteOffReason FROM WO
),
Periods AS
(
    SELECT ESYear, ESMonth FROM #Periods WHERE ESYear <> 0
),
Grid AS
(
    SELECT p.ESYear, p.ESMonth, r.WriteOffReason
    FROM   Periods p
    CROSS JOIN Reasons r
),
Monthly AS
(
    SELECT
        g.ESYear,
        g.ESMonth,
        g.WriteOffReason,
        ISNULL(SUM(wo.MatchingCount), 0) AS Cnt
    FROM   Grid g
    LEFT JOIN WO wo
           ON wo.WOYear         = g.ESYear
          AND wo.WOMonth        = g.ESMonth
          AND wo.WriteOffReason = g.WriteOffReason
    GROUP BY g.ESYear, g.ESMonth, g.WriteOffReason
)
/* 1) Monthly detail, per reason */
SELECT ESYear, ESMonth, WriteOffReason, 'V' AS Col, 'Fully Adjusted' AS Bucket, Cnt AS FullyAdjustedCount
FROM Monthly
UNION ALL
/* 2) Per-reason subtotal across all months */
SELECT 0, 0, WriteOffReason, 'V', 'Fully Adjusted', SUM(Cnt)
FROM Monthly GROUP BY WriteOffReason
UNION ALL
/* 3) Grand total across all reasons and months */
SELECT 0, 0, 'ALL REASONS', 'V', 'Fully Adjusted', SUM(Cnt)
FROM Monthly
ORDER BY ESYear, ESMonth, WriteOffReason;

/* cleanup */
IF OBJECT_ID('tempdb..#Base')    IS NOT NULL DROP TABLE #Base;
IF OBJECT_ID('tempdb..#Periods') IS NOT NULL DROP TABLE #Periods;

/*==============================================================================
  EXECUTIVE SUMMARY - Fully Adjusted (Write-Off) counts BY WRITE-OFF REASON.

  Fully Adjusted  = b.BillStatus = 'Billed' AND b.ClaimStatus = 'Complete W/O'
  Write-off reason = the TransactionCode / TransactionCodeDesc the user entered
                     in BTTransactionDetailData. The refresh proc already carries
                     this into BTWOSummary as:
                        TransactionCode
                        TransactionCodeDesc
                        TransactionCodeCombined  (Code + ' - ' + Desc)

  Output (all rows tally by construction):
     - one row per (Year, Month, WriteOffReason)          -> monthly detail
     - one row per (WriteOffReason) with ESYear/ESMonth=0  -> reason subtotal
     - one row 'ALL REASONS' with ESYear/ESMonth=0         -> grand total
        grand total == SUM(reason subtotals) == SUM(all monthly cells)
==============================================================================*/

;WITH WO AS
(
    /* Matched Fully Adjusted write-off rows, tagged with reason + service month. */
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
    /* Every period x every reason, so months with 0 for a reason still show.
       If you do NOT want zero-filled rows, delete this CTE and the Grid join in
       Monthly, and aggregate WO directly by WOYear/WOMonth/WriteOffReason. */
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
           ON wo.WOYear        = g.ESYear
          AND wo.WOMonth       = g.ESMonth
          AND wo.WriteOffReason = g.WriteOffReason
    GROUP BY g.ESYear, g.ESMonth, g.WriteOffReason
)
/* 1) Monthly detail, per reason */
SELECT
    ESYear,
    ESMonth,
    WriteOffReason,
    'V'              AS Col,
    'Fully Adjusted' AS Bucket,
    Cnt              AS FullyAdjustedCount
FROM Monthly

UNION ALL

/* 2) Per-reason subtotal across all months */
SELECT
    0, 0,
    WriteOffReason,
    'V', 'Fully Adjusted',
    SUM(Cnt)
FROM Monthly
GROUP BY WriteOffReason

UNION ALL

/* 3) Grand total across all reasons and months */
SELECT
    0, 0,
    'ALL REASONS',
    'V', 'Fully Adjusted',
    SUM(Cnt)
FROM Monthly

ORDER BY ESYear, ESMonth, WriteOffReason;

/*==============================================================================
  Fully Adjusted (Write-Off) monthly counts that TALLY to the grand total.

  Fully Adjusted definition:  b.BillStatus = 'Billed'  AND  b.ClaimStatus = 'Complete W/O'
  This filter lives in #Base (the b alias below).

  WHY THE OLD QUERY DIDN'T TALLY
  ------------------------------
  The original report used:
        LEFT JOIN ( ... ) ws
          ON (p.ESYear = 0 OR (ws.WOYear = p.ESYear AND ws.WOMonth = p.ESMonth))

  The "p.ESYear = 0" branch makes the grand-total row count EVERY matched
  BTWOSummary row, regardless of its service date. But each month row only
  counts rows whose DateofService falls inside that period. So any matched row
  whose service month is NOT represented in #Periods gets counted in the total
  but in no month -> total > sum(months).

  FIX
  ---
  Compute the per-month buckets once, then derive the grand total by SUMMING
  those buckets. The total is now, by construction, exactly equal to the sum of
  the displayed months. Nothing can fall into the total without also landing in
  a month.
==============================================================================*/

;WITH WO AS
(
    /* Step 1 + 2: matched Fully Adjusted write-off rows, with service month.
       #Base is already filtered to BillStatus='Billed' AND ClaimStatus='Complete W/O'. */
    SELECT
        ws2.MatchingCount,
        YEAR (TRY_CAST(ws2.DateofService AS DATE)) AS WOYear,
        MONTH(TRY_CAST(ws2.DateofService AS DATE)) AS WOMonth
    FROM   dbo.BTWOSummary ws2
    INNER JOIN #Base b
        ON  LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
          = LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
    WHERE  TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
      AND  b.BillStatus  = 'Billed'          -- redundant if #Base is pre-filtered; kept for safety
      AND  b.ClaimStatus = 'Complete W/O'
),
Monthly AS
(
    /* One row per reporting period. Only real periods here (ESYear <> 0). */
    SELECT
        p.ESYear,
        p.ESMonth,
        ISNULL(SUM(wo.MatchingCount), 0) AS Cnt
    FROM   #Periods p
    LEFT JOIN WO
           ON wo.WOYear = p.ESYear
          AND wo.WOMonth = p.ESMonth
    WHERE  p.ESYear <> 0
    GROUP BY p.ESYear, p.ESMonth
)
/* Month rows */
SELECT  ESYear, ESMonth, 'V' AS Col, 'Fully Adjusted' AS Bucket, Cnt AS FullyAdjustedCount
FROM    Monthly
UNION ALL
/* Grand-total row: guaranteed to equal the sum of the month rows above */
SELECT  0, 0, 'V', 'Fully Adjusted', ISNULL(SUM(Cnt), 0)
FROM    Monthly
ORDER BY ESYear, ESMonth;


/*------------------------------------------------------------------------------
  OPTIONAL SANITY CHECK
  Confirms the sum of the month buckets equals the raw matched total.
  If these differ, some service dates fall outside #Periods (expected: the
  derived total above will follow the month buckets, not the raw total).
------------------------------------------------------------------------------*/
-- SELECT
--     RawMatchedTotal =
--     (
--         SELECT ISNULL(SUM(ws2.MatchingCount),0)
--         FROM   dbo.BTWOSummary ws2
--         INNER JOIN #Base b
--             ON  LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
--               = LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
--         WHERE TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
--           AND b.BillStatus = 'Billed' AND b.ClaimStatus = 'Complete W/O'
--     );

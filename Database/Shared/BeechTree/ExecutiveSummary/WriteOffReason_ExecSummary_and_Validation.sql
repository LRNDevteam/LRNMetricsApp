/*==============================================================================
  A) VALIDATION - reproduces your two reference numbers for Jan-2025
  B) EXEC SUMMARY - write-off reason split per month (built from BTWOSummary v2)
==============================================================================*/

/*-------------------------------------------------------------------------
  A) VALIDATION
-------------------------------------------------------------------------*/
-- (A1) Total write-off claims in ClaimLevelData  -> expected 6513
SELECT COUNT(ClaimID) AS TotalClaimCount
FROM   dbo.ClaimLevelData
WHERE  BilledUnbilled = 'Billed'
  AND  ClaimStatus    = 'Complete W/O'
  AND  MONTH(DateofService) = 1
  AND  YEAR (DateofService) = 2025;

-- (A2) Distinct visit numbers matched in BTTransactionDetailData -> expected 6496
SELECT COUNT(DISTINCT VisitNumber) AS WriteOffVisitNumbers
FROM   dbo.BTTransactionDetailData
WHERE  MONTH(DateofService) = 1
  AND  YEAR (DateofService) = 2025
  AND  VisitNumber IN (
        SELECT ClaimID FROM dbo.ClaimLevelData
        WHERE  BilledUnbilled = 'Billed'
          AND  ClaimStatus    = 'Complete W/O'
          AND  MONTH(DateofService) = 1
          AND  YEAR (DateofService) = 2025);

-- (A3) Same 6496 read back from BTWOSummary v2 (distinct claims, un-split)
SELECT COUNT(DISTINCT ClaimID) AS WriteOffVisitNumbers_FromSummary
FROM   dbo.BTWOSummary
WHERE  YEAR (DateofService) = 2025
  AND  MONTH(DateofService) = 1;


/*-------------------------------------------------------------------------
  B) EXEC SUMMARY - reason split per month, with reason + grand totals.

     SUM(MatchingCount) per reason = distinct claims carrying that reason.
     Because one claim can carry more than one write-off reason, the sum of
     the reason rows can be >= the distinct-visit total (6496). The
     "ALL REASONS (distinct claims)" row shows the un-split distinct count.
-------------------------------------------------------------------------*/
;WITH WO AS
(
    SELECT
        ClaimID,
        ISNULL(NULLIF(LTRIM(RTRIM(TransactionCodeCombined)), ''), '(No reason entered)') AS WriteOffReason,
        YEAR (DateofService) AS WOYear,
        MONTH(DateofService) AS WOMonth,
        MatchingCount
    FROM dbo.BTWOSummary
)
/* per month per reason */
SELECT
    WOYear, WOMonth, WriteOffReason,
    SUM(MatchingCount) AS ClaimCount
FROM WO
GROUP BY WOYear, WOMonth, WriteOffReason

UNION ALL
/* per reason, all months */
SELECT 0, 0, WriteOffReason, SUM(MatchingCount)
FROM WO GROUP BY WriteOffReason

UNION ALL
/* grand total - SPLIT (sum of all reason cells) */
SELECT 0, 0, 'ALL REASONS (split total)', SUM(MatchingCount)
FROM WO

UNION ALL
/* grand total - DISTINCT claims (un-split; this is the 6496-type number) */
SELECT 0, 0, 'ALL REASONS (distinct claims)', COUNT(DISTINCT ClaimID)
FROM WO

ORDER BY WOYear, WOMonth, WriteOffReason;

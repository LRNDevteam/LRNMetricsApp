/*==============================================================================
  usp_RefreshBT_WOSummary  (v2 - corrected write-off logic)

  WHAT WAS WRONG IN v1
  --------------------
   1. Join used EXACT date equality: TRY_CAST(td.DateOfService) = TRY_CAST(cl.DateofService).
      Write-off transactions are posted on a different day than the claim's DOS,
      so valid matches were silently dropped.
   2. MatchingCount = COUNT(*) counted TRANSACTION ROWS, not claims. A claim with
      several detail lines was over-counted.
   3. Wrong status column (BillStatus). The correct filter is BilledUnbilled.

  CORRECT LOGIC (matches your validation queries)
  -----------------------------------------------
   Write-off claim set : ClaimLevelData WHERE BilledUnbilled='Billed'
                                          AND ClaimStatus='Complete W/O'
   Match               : BTTransactionDetailData.VisitNumber = ClaimLevelData.ClaimID
                         AND same YEAR + MONTH of DateOfService
   Count               : COUNT(DISTINCT VisitNumber)  (distinct claims, not rows)

  GRAIN STORED IN BTWOSummary
  ---------------------------
   One row per  (ClaimID, TransactionCode, TransactionCodeDesc, Year, Month).
   MatchingCount = 1  -> each row is one distinct claim under that write-off
   reason for that month, so SUM(MatchingCount) = distinct-visit count and
   COUNT(DISTINCT ClaimID) still works for un-split totals.
   DateofService holds the 1st-of-month bucket date so YEAR()/MONTH() reporting
   is unchanged.
==============================================================================*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[usp_RefreshBT_WOSummary]
AS
BEGIN
    SET NOCOUNT ON;

    /* Step 1: clear previous aggregates */
    TRUNCATE TABLE dbo.BTWOSummary;

    /* Step 2: rebuild - distinct claim x reason x month for write-off claims */
    INSERT INTO dbo.BTWOSummary
        (ClaimID, TransactionCode, TransactionCodeDesc, TransactionCodeCombined, DateofService, MatchingCount)
    SELECT
        LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50))))       AS ClaimID,
        td.TransactionCode,
        td.TransactionCodeDesc,
        ISNULL(LTRIM(RTRIM(td.TransactionCode)),     '')
            + ' - '
            + ISNULL(LTRIM(RTRIM(td.TransactionCodeDesc)), '')  AS TransactionCodeCombined,
        DATEFROMPARTS(
            YEAR (TRY_CAST(td.DateOfService AS DATE)),
            MONTH(TRY_CAST(td.DateOfService AS DATE)), 1)        AS DateofService,   -- month bucket
        1                                                        AS MatchingCount    -- 1 distinct claim
    FROM dbo.BTTransactionDetailData AS td
    INNER JOIN dbo.ClaimLevelData    AS cl
        ON  LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50))))
          = LTRIM(RTRIM(CAST(cl.ClaimID     AS NVARCHAR(50))))
        AND YEAR (TRY_CAST(td.DateOfService AS DATE)) = YEAR (TRY_CAST(cl.DateofService AS DATE))
        AND MONTH(TRY_CAST(td.DateOfService AS DATE)) = MONTH(TRY_CAST(cl.DateofService AS DATE))
    WHERE cl.BilledUnbilled = 'Billed'
      AND cl.ClaimStatus    = 'Complete W/O'
      AND TRY_CAST(td.DateOfService AS DATE) IS NOT NULL
      AND TRY_CAST(cl.DateofService AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50)))),
        td.TransactionCode,
        td.TransactionCodeDesc,
        ISNULL(LTRIM(RTRIM(td.TransactionCode)),     '')
            + ' - '
            + ISNULL(LTRIM(RTRIM(td.TransactionCodeDesc)), ''),
        YEAR (TRY_CAST(td.DateOfService AS DATE)),
        MONTH(TRY_CAST(td.DateOfService AS DATE));

    /* Step 3: return control totals to caller */
    SELECT
        COUNT(*)                        AS SummaryRows,          -- distinct claim x reason x month
        SUM(MatchingCount)              AS TotalReasonSplit,     -- sum of the split
        COUNT(DISTINCT ClaimID)         AS DistinctWriteOffClaims
    FROM dbo.BTWOSummary;
END
GO

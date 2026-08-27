/*==============================================================================
  usp_RefreshBT_WOSummary  (v4)

  CHANGES vs v3
  -------------
   1. MATCH ON VisitNumber = ClaimID ONLY.  v3 also required the transaction's
      DateOfService month to equal the claim's month, which dropped claims whose
      write-off was entered in a later month (e.g. ClaimID 18960958: service DOS
      Jan-2025, write-off entered Aug-2025). Those are now kept.
   2. REASON = the transaction with the LATEST DateOfEntry for that claim
      (ROW_NUMBER ordered by DateOfEntry DESC).
   3. BUCKET by the CLAIM's DateofService month (from ClaimLevelData), so the
      V.n sub-rows line up with the parent V (which is counted from ClaimLevelData).

  GRAIN: one row per write-off claim that has >=1 transaction-detail row.
         MatchingCount = 1.  DateofService = 1st-of-month of the claim's service
         month so YEAR()/MONTH() reporting is unchanged.

  NOTE: "latest DateOfEntry" uses TRY_CAST(... AS DATETIME2). If DateOfEntry does
  not carry a time and you get ties, the DateOfService / TransactionCode tie-
  breakers below make the pick deterministic.
==============================================================================*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[usp_RefreshBT_WOSummary]
AS
BEGIN
    SET NOCOUNT ON;

    /* Step 1: clear */
    TRUNCATE TABLE dbo.BTWOSummary;

    /* Step 2: rank each write-off claim's transactions by latest DateOfEntry */
    ;WITH Ranked AS
    (
        SELECT
            LTRIM(RTRIM(CAST(cl.ClaimID AS NVARCHAR(50)))) AS ClaimID,
            td.TransactionCode,
            td.TransactionCodeDesc,
            YEAR (TRY_CAST(cl.DateofService AS DATE)) AS WOYear,   -- claim's service month
            MONTH(TRY_CAST(cl.DateofService AS DATE)) AS WOMonth,
            ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(CAST(cl.ClaimID AS NVARCHAR(50))))
                ORDER BY
                    TRY_CAST(td.DateOfEntry   AS DATETIME2) DESC,   -- latest entry wins
                    TRY_CAST(td.DateOfService AS DATE)      DESC,   -- tie-break
                    td.TransactionCode                      DESC    -- deterministic
            ) AS rn
        FROM dbo.ClaimLevelData AS cl
        INNER JOIN dbo.BTTransactionDetailData AS td
            ON  LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50))))
              = LTRIM(RTRIM(CAST(cl.ClaimID     AS NVARCHAR(50))))
        WHERE cl.BilledUnbilled = 'Billed'
          AND cl.ClaimStatus    = 'Complete W/O'
          AND TRY_CAST(cl.DateofService AS DATE) IS NOT NULL
    )
    /* Step 3: keep the latest-entry reason, one row per claim */
    INSERT INTO dbo.BTWOSummary
        (ClaimID, TransactionCode, TransactionCodeDesc, TransactionCodeCombined, DateofService, MatchingCount)
    SELECT
        ClaimID,
        TransactionCode,
        TransactionCodeDesc,
        ISNULL(LTRIM(RTRIM(TransactionCode)),     '')
            + ' - '
            + ISNULL(LTRIM(RTRIM(TransactionCodeDesc)), '') AS TransactionCodeCombined,
        DATEFROMPARTS(WOYear, WOMonth, 1)                   AS DateofService,   -- claim month bucket
        1                                                   AS MatchingCount
    FROM Ranked
    WHERE rn = 1;

    /* Step 4: control totals */
    SELECT
        COUNT(*)                AS SummaryRows,
        SUM(MatchingCount)      AS TotalReasonSplit,
        COUNT(DISTINCT ClaimID) AS DistinctWriteOffClaims
    FROM dbo.BTWOSummary;
END
GO

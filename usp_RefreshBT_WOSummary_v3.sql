/*==============================================================================
  usp_RefreshBT_WOSummary  (v3)

  Same corrected matching as v2 (BilledUnbilled filter, month/year match,
  distinct visits) BUT each claim is now assigned exactly ONE write-off reason:
  the reason on its MOST RECENT write-off transaction (latest DateOfService)
  within that month. This makes the reason split total to the distinct-visit
  count (e.g. 6496 for Jan-2025) instead of double-counting multi-reason claims.

  GRAIN: one row per (ClaimID, Year, Month) = one distinct claim per month,
         tagged with its winning reason. MatchingCount = 1.

  >>> ORDERING NOTE <<<
  "Most recent" is ordered by DateOfService here. If BTTransactionDetailData has
  a true posting/entry date or a transaction sequence/ID column, use THAT in the
  ORDER BY of the ROW_NUMBER() below for a more accurate "latest" (and to break
  same-service-date ties). Search for  -- <ORDER BY latest>  and adjust.
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

    /* Step 2: rank each write-off transaction per claim+month, latest first */
    ;WITH Matched AS
    (
        SELECT
            LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50)))) AS ClaimID,
            td.TransactionCode,
            td.TransactionCodeDesc,
            YEAR (TRY_CAST(td.DateOfService AS DATE)) AS WOYear,
            MONTH(TRY_CAST(td.DateOfService AS DATE)) AS WOMonth,
            ROW_NUMBER() OVER (
                PARTITION BY
                    LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50)))),
                    YEAR (TRY_CAST(td.DateOfService AS DATE)),
                    MONTH(TRY_CAST(td.DateOfService AS DATE))
                ORDER BY
                    TRY_CAST(td.DateOfService AS DATE) DESC,   -- <ORDER BY latest>  (swap for posting date / txn id if available)
                    td.TransactionCode DESC                    -- deterministic tie-break
            ) AS rn
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
    )
    /* Step 3: keep only the winning (latest) reason per claim+month */
    INSERT INTO dbo.BTWOSummary
        (ClaimID, TransactionCode, TransactionCodeDesc, TransactionCodeCombined, DateofService, MatchingCount)
    SELECT
        ClaimID,
        TransactionCode,
        TransactionCodeDesc,
        ISNULL(LTRIM(RTRIM(TransactionCode)),     '')
            + ' - '
            + ISNULL(LTRIM(RTRIM(TransactionCodeDesc)), '') AS TransactionCodeCombined,
        DATEFROMPARTS(WOYear, WOMonth, 1)                   AS DateofService,   -- month bucket
        1                                                   AS MatchingCount
    FROM Matched
    WHERE rn = 1;

    /* Step 4: control totals - TotalReasonSplit now == DistinctWriteOffClaims */
    SELECT
        COUNT(*)                AS SummaryRows,
        SUM(MatchingCount)      AS TotalReasonSplit,
        COUNT(DISTINCT ClaimID) AS DistinctWriteOffClaims
    FROM dbo.BTWOSummary;
END
GO

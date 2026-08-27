/*==============================================================================
  usp_RefreshBT_WOSummary  (v5)

  SCOPE CHANGE: BTWOSummary now captures WRITE-OFF TRANSACTION LINES from
  BTTransactionDetailData regardless of the claim's ClaimStatus. So a claim that
  is 'Fully Paid' at claim level but has a write-off line (e.g. VisitNumber
  18960958, WOINT) IS now included. This no longer ties to the fully-adjusted
  ('Complete W/O') claim count.

  >>> ASSUMPTION to verify <<<
  A "write-off line" is identified by  TransactionCode LIKE 'WO%'.
  (This excludes '#INT'/interest and 'None'.) If your write-off codes follow a
  different pattern, edit the WHERE clause marked  -- <WO code filter>.

  GRAIN: one row per (VisitNumber, write-off reason, service month).
         MatchingCount = 1, so SUM per (reason, month) = distinct visits carrying
         that reason. A visit with two different WO reasons appears twice (once
         per reason) - that is the intended "all write-off lines" behaviour.
  Bucketed by the LINE's DateOfService month.
==============================================================================*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[usp_RefreshBT_WOSummary]
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.BTWOSummary;

    INSERT INTO dbo.BTWOSummary
        (ClaimID, TransactionCode, TransactionCodeDesc, TransactionCodeCombined, DateofService, MatchingCount)
    SELECT
        LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50))))      AS ClaimID,
        td.TransactionCode,
        td.TransactionCodeDesc,
        ISNULL(LTRIM(RTRIM(td.TransactionCode)),     '')
            + ' - '
            + ISNULL(LTRIM(RTRIM(td.TransactionCodeDesc)), '')  AS TransactionCodeCombined,
        DATEFROMPARTS(
            YEAR (TRY_CAST(td.DateOfService AS DATE)),
            MONTH(TRY_CAST(td.DateOfService AS DATE)), 1)       AS DateofService,   -- line's service month
        1                                                       AS MatchingCount
    FROM dbo.BTTransactionDetailData AS td
    WHERE td.TransactionCode LIKE 'WO%'                         -- <WO code filter>
      AND TRY_CAST(td.DateOfService AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50)))),
        td.TransactionCode,
        td.TransactionCodeDesc,
        ISNULL(LTRIM(RTRIM(td.TransactionCode)),     '')
            + ' - '
            + ISNULL(LTRIM(RTRIM(td.TransactionCodeDesc)), ''),
        YEAR (TRY_CAST(td.DateOfService AS DATE)),
        MONTH(TRY_CAST(td.DateOfService AS DATE));

    /* control totals */
    SELECT
        COUNT(*)                            AS SummaryRows,          -- visit x reason x month
        SUM(MatchingCount)                  AS TotalReasonLines,
        COUNT(DISTINCT ClaimID)             AS DistinctVisitsWithWO
    FROM dbo.BTWOSummary;
END
GO

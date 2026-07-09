/*==============================================================================
  usp_RefreshBT_WOSummary  (v6)  --  CORRECT model

  DRIVER = the Complete W/O claims (this GUARANTEES the monthly totals):
        ClaimLevelData WHERE ClaimStatus='Complete W/O' AND BilledUnbilled='Billed'
        (~87,698 rows)

  For each such claim we LEFT JOIN its write-off reason from
  BTTransactionDetailData (matched on VisitNumber = ClaimID, latest DateOfEntry).
  Claims with no matching write-off line get reason = 'No reason'.

  => For any month:  SUM(MatchingCount) = # Complete W/O claims that month.
     e.g. Jan-2025: 6096 total = (claims with a matched reason) + ('No reason').

  GRAIN: one row per (ClaimID, service month). MatchingCount = 1.
         Bucketed by the CLAIM's DateofService month.

  >>> ASSUMPTION <<< a write-off reason line is TransactionCode LIKE 'WO%'.
      Edit the marker  -- <WO code filter>  if your codes differ.
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

    ;WITH COWO AS
    (
        -- one row per Complete W/O claim per service month (the driver)
        SELECT DISTINCT
            LTRIM(RTRIM(CAST(cl.ClaimID AS NVARCHAR(50)))) AS ClaimID,
            YEAR (TRY_CAST(cl.DateofService AS DATE))       AS WOYear,
            MONTH(TRY_CAST(cl.DateofService AS DATE))       AS WOMonth
        FROM dbo.ClaimLevelData cl
        WHERE cl.ClaimStatus    = 'Complete W/O'
          AND cl.BilledUnbilled = 'Billed'
          AND TRY_CAST(cl.DateofService AS DATE) IS NOT NULL
    ),
    Reason AS
    (
        -- latest-entry write-off reason per visit
        SELECT ClaimID, TransactionCode, TransactionCodeDesc
        FROM (
            SELECT
                LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50)))) AS ClaimID,
                td.TransactionCode,
                td.TransactionCodeDesc,
                ROW_NUMBER() OVER (
                    PARTITION BY LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50))))
                    ORDER BY
                        TRY_CAST(td.DateOfEntry   AS DATETIME2) DESC,
                        TRY_CAST(td.DateOfService AS DATE)      DESC,
                        td.TransactionCode                      DESC
                ) AS rn
            FROM dbo.BTTransactionDetailData td
            WHERE td.TransactionCode LIKE 'WO%'              -- <WO code filter>
        ) x
        WHERE rn = 1
    )
    INSERT INTO dbo.BTWOSummary
        (ClaimID, TransactionCode, TransactionCodeDesc, TransactionCodeCombined, DateofService, MatchingCount)
    SELECT
        c.ClaimID,
        r.TransactionCode,
        r.TransactionCodeDesc,
        CASE WHEN r.ClaimID IS NULL
             THEN 'No reason'
             ELSE ISNULL(LTRIM(RTRIM(r.TransactionCode)),     '')
                    + ' - '
                    + ISNULL(LTRIM(RTRIM(r.TransactionCodeDesc)), '')
        END                                     AS TransactionCodeCombined,
        DATEFROMPARTS(c.WOYear, c.WOMonth, 1)   AS DateofService,   -- claim month bucket
        1                                       AS MatchingCount
    FROM COWO c
    LEFT JOIN Reason r
        ON r.ClaimID = c.ClaimID;

    /* control totals */
    SELECT
        COUNT(*)                AS SummaryRows,           -- = # Complete W/O claim-months
        SUM(MatchingCount)      AS TotalClaims,
        COUNT(DISTINCT ClaimID) AS DistinctClaims,
        SUM(CASE WHEN TransactionCodeCombined = 'No reason' THEN 1 ELSE 0 END) AS NoReasonClaims
    FROM dbo.BTWOSummary;
END
GO

/*==============================================================================
  DIAGNOSTIC: why is ClaimID 18960958 missing from BTWOSummary?
  The v3 refresh inserts a row only when ALL of these hold:
    (1) cl.ClaimID = td.VisitNumber            (trim/cast match)
    (2) cl.BilledUnbilled = 'Billed'
    (3) cl.ClaimStatus    = 'Complete W/O'
    (4) YEAR/MONTH of td.DateOfService = YEAR/MONTH of cl.DateofService
    (5) both dates TRY_CAST to a valid DATE
  Run each section; the one that returns nothing / mismatches is your culprit.
==============================================================================*/
DECLARE @Claim NVARCHAR(50) = '18960958';

/*-- (A) ClaimLevelData side: status + service month ------------------------*/
SELECT
    cl.ClaimID,
    cl.BilledUnbilled,
    cl.ClaimStatus,
    cl.DateofService                          AS RawDOS,
    TRY_CAST(cl.DateofService AS DATE)        AS CastDOS,
    YEAR (TRY_CAST(cl.DateofService AS DATE))  AS CL_Year,
    MONTH(TRY_CAST(cl.DateofService AS DATE))  AS CL_Month,
    CASE WHEN cl.BilledUnbilled = 'Billed'
          AND cl.ClaimStatus    = 'Complete W/O'
         THEN 'PASSES write-off filter'
         ELSE 'FAILS write-off filter -> excluded' END AS FilterCheck
FROM dbo.ClaimLevelData cl
WHERE LTRIM(RTRIM(CAST(cl.ClaimID AS NVARCHAR(50)))) = @Claim;

/*-- (B) BTTransactionDetailData side: each txn + its service month ---------*/
SELECT
    td.VisitNumber,
    td.TransactionCode,
    td.TransactionCodeDesc,
    td.DateOfService                          AS RawDOS,
    TRY_CAST(td.DateOfService AS DATE)        AS CastDOS,
    YEAR (TRY_CAST(td.DateOfService AS DATE))  AS TD_Year,
    MONTH(TRY_CAST(td.DateOfService AS DATE))  AS TD_Month
FROM dbo.BTTransactionDetailData td
WHERE LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50)))) = @Claim
ORDER BY TRY_CAST(td.DateOfService AS DATE);

/*-- (C) Simulate the exact v3 join - what SHOULD land in BTWOSummary -------*/
SELECT
    LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50)))) AS ClaimID,
    td.TransactionCode, td.TransactionCodeDesc,
    YEAR (TRY_CAST(td.DateOfService AS DATE)) AS WOYear,
    MONTH(TRY_CAST(td.DateOfService AS DATE)) AS WOMonth
FROM dbo.BTTransactionDetailData td
INNER JOIN dbo.ClaimLevelData cl
    ON  LTRIM(RTRIM(CAST(td.VisitNumber AS NVARCHAR(50))))
      = LTRIM(RTRIM(CAST(cl.ClaimID     AS NVARCHAR(50))))
    AND YEAR (TRY_CAST(td.DateOfService AS DATE)) = YEAR (TRY_CAST(cl.DateofService AS DATE))
    AND MONTH(TRY_CAST(td.DateOfService AS DATE)) = MONTH(TRY_CAST(cl.DateofService AS DATE))
WHERE LTRIM(RTRIM(CAST(cl.ClaimID AS NVARCHAR(50)))) = @Claim
  AND cl.BilledUnbilled = 'Billed'
  AND cl.ClaimStatus    = 'Complete W/O'
  AND TRY_CAST(td.DateOfService AS DATE) IS NOT NULL
  AND TRY_CAST(cl.DateofService AS DATE) IS NOT NULL;

/*-- (D) What is actually in BTWOSummary now --------------------------------*/
SELECT * FROM dbo.BTWOSummary
WHERE LTRIM(RTRIM(CAST(ClaimID AS NVARCHAR(50)))) = @Claim;

/*
    Rising Tides Executive Summary - PMS "Insurance Balance" (X), client logic (2026-09-30)

      X  Insurance Balance = BilledUnbilled = 'Billed'
                             AND ClaimStatus IN ('Fully Denied','No Response','Partially Denied','Partially Adjusted')
         (was missing 'Partially Adjusted'; current data 2451 -> 2467 = X1 1012 + X2 1226 + X3 229)

    1. Patches only that filter inside the deployed dbo.usp_RefreshRT_ExecutiveSummary
       (everything else, including the script-32 call at the end, is kept). Skipped if already applied.
    2. Fixes the RT PMS drill-down definitions: they still used the old codes
       (W = Insurance Balance, X = Patient Payment); the report uses W = Patient Payment,
       X = Insurance Balance, X1 Fully Denied, X2 No Response, X3 Partially Denied (incl. Partially Adjusted).
    3. Re-runs the PMS / Cash refresh and returns a check.
*/
SET NOCOUNT ON;
GO

DECLARE @procId INT = OBJECT_ID('dbo.usp_RefreshRT_ExecutiveSummary', 'P');
IF @procId IS NULL
    THROW 51110, 'dbo.usp_RefreshRT_ExecutiveSummary was not found.', 1;

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(@procId);
IF @def IS NULL
    THROW 51111, 'Unable to read dbo.usp_RefreshRT_ExecutiveSummary definition.', 1;

DECLARE @oldFilter NVARCHAR(200) = N'b.ClaimStatus IN (''Fully Denied'',''No Response'',''Partially Denied'')';
DECLARE @newFilter NVARCHAR(200) = N'b.ClaimStatus IN (''Fully Denied'',''No Response'',''Partially Denied'',''Partially Adjusted'')';

IF CHARINDEX(@oldFilter, @def) > 0
BEGIN
    DECLARE @procKeyword INT = PATINDEX('%PROCEDURE%', UPPER(@def));
    IF @procKeyword = 0
        THROW 51112, 'Unable to safely patch dbo.usp_RefreshRT_ExecutiveSummary.', 1;

    SET @def = N'ALTER ' + SUBSTRING(REPLACE(@def, @oldFilter, @newFilter), @procKeyword, LEN(@def) + 100);
    EXEC sys.sp_executesql @def;
    PRINT 'usp_RefreshRT_ExecutiveSummary: Insurance Balance filter updated.';
END
ELSE IF CHARINDEX(@newFilter, @def) > 0
    PRINT 'usp_RefreshRT_ExecutiveSummary: Insurance Balance filter already applied.';
ELSE
    THROW 51113, 'Insurance Balance filter text not found in dbo.usp_RefreshRT_ExecutiveSummary - review manually.', 1;
GO

/* PMS drill-down definitions (Year / Grand Total links). */
DELETE FROM dbo.LisDrillRowDef
WHERE LabPrefix = N'RT' AND Source = N'PMS'
  AND RowCode IN (N'W', N'W1', N'W2', N'W3', N'X', N'X1', N'X2', N'X3');

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2,
     Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals)
VALUES
 (N'RT', N'W',  N'Patient Payment', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Payment',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'X',  N'Insurance Balance', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Denied,Partially Adjusted',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied',
     N'No Response', N'ClaimStatus', N'No Response',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied,Partially Adjusted'),
 (N'RT', N'X1', N'Fully Denied', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'X2', N'No Response', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'X3', N'Partially Denied', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'IN', N'Partially Denied,Partially Adjusted',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

-- Rebuild PMS / Cash now (also refreshes Billed Mismatches / Average Payment when script 32 is deployed).
EXEC dbo.usp_RefreshRT_ExecutiveSummary;
GO

-- Check: X must equal X1 + X2 + X3 (current data: 2467 = 1012 + 1226 + 229).
SELECT ESYear, ESMonth,
       SUM(CASE WHEN RoleID = 'X' THEN ESMonthClaimCount ELSE 0 END)                  AS InsuranceBalance_X,
       SUM(CASE WHEN RoleID IN ('X1','X2','X3') THEN ESMonthClaimCount ELSE 0 END)    AS X1_X2_X3,
       SUM(CASE WHEN RoleID = 'X' THEN ESMonthClaimCount ELSE 0 END)
     - SUM(CASE WHEN RoleID IN ('X1','X2','X3') THEN ESMonthClaimCount ELSE 0 END)    AS Difference
FROM dbo.RT_ES_PMS
WHERE RoleID IN ('X','X1','X2','X3')
GROUP BY ESYear, ESMonth
ORDER BY CASE WHEN ESYear = 0 THEN 1 ELSE 0 END, ESYear, ESMonth;
GO

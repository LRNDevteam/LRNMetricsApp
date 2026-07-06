-- ============================================================
-- Standalone query: No. of Billed Claims (Row G) and
--                    No. of Unbilled Claims (Row H)
-- Run in NWL_LRN
-- Mirrors current production logic in usp_RefreshNW_ExecutiveSummary
-- (Billed derived from FirstBilledDate / EmedixSubmissionDate;
--  Row H is ClaimType-based, no Billed/status filter)
-- ============================================================

-- Step 1: Build #Base the same way the production aggregate SP does
DROP TABLE IF EXISTS #Base;
CREATE TABLE #Base
(
    AccessionNumber NVARCHAR(100) NOT NULL,
    ESYear          INT           NOT NULL,
    ESMonth         INT           NOT NULL,
    Billed          NVARCHAR(50)  NOT NULL,
    ClaimType       NVARCHAR(200) NOT NULL,
    ClaimStatus     NVARCHAR(200) NOT NULL
);

INSERT INTO #Base
SELECT
    LTRIM(RTRIM(ISNULL(AccessionNumber, ''))) AS AccessionNumber,
    YEAR (TRY_CAST(DateofService AS DATE))    AS ESYear,
    MONTH(TRY_CAST(DateofService AS DATE))    AS ESMonth,
    CASE
        WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), FirstBilledDate),     ''))), '') IS NOT NULL THEN 'Billed'
        WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), EmedixSubmissionDate),''))), '') IS NOT NULL THEN 'Billed'
        ELSE 'Unbilled'
    END                                        AS Billed,
    ISNULL(LTRIM(RTRIM(ClaimType)),   '')     AS ClaimType,
    ISNULL(LTRIM(RTRIM(ClaimStatus)), '')     AS ClaimStatus
FROM dbo.ClaimLevelData
WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber,''))), '') IS NOT NULL;

-- Step 2: Row G — No. of Billed Claims, per month
PRINT '-- Row G: No. of Billed Claims (per month) --';
SELECT
    ESYear,
    ESMonth,
    COUNT(DISTINCT CASE
            WHEN Billed = 'Billed'
             AND ClaimType NOT IN ('ADCS - Invoice', 'Test Patient Entries')
             AND ClaimStatus <> 'Billed Amount 0'
            THEN AccessionNumber
          END) AS BilledClaimsCount
FROM #Base
GROUP BY ESYear, ESMonth
ORDER BY ESYear, ESMonth;

-- Step 3: Row G — grand total
PRINT '-- Row G: No. of Billed Claims (grand total) --';
SELECT
    COUNT(DISTINCT CASE
            WHEN Billed = 'Billed'
             AND ClaimType NOT IN ('ADCS - Invoice', 'Test Patient Entries')
             AND ClaimStatus <> 'Billed Amount 0'
            THEN AccessionNumber
          END) AS TotalBilledClaims
FROM #Base;

-- Step 4: Row H — No. of Unbilled Claims, per month
PRINT '-- Row H: No. of Unbilled Claims (per month) --';
SELECT
    ESYear,
    ESMonth,
    COUNT(DISTINCT CASE
            WHEN ClaimType IN ('Unbilled in Daqbilling', 'Unbilled in Webpm')
            THEN AccessionNumber
          END) AS UnbilledClaimsCount
FROM #Base
GROUP BY ESYear, ESMonth
ORDER BY ESYear, ESMonth;

-- Step 5: Row H — grand total
PRINT '-- Row H: No. of Unbilled Claims (grand total) --';
SELECT
    COUNT(DISTINCT CASE
            WHEN ClaimType IN ('Unbilled in Daqbilling', 'Unbilled in Webpm')
            THEN AccessionNumber
          END) AS TotalUnbilledClaims
FROM #Base;

DROP TABLE IF EXISTS #Base;

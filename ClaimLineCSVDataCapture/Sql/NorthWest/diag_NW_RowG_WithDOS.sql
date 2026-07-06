-- ============================================================
-- Diagnostic: Row G "No. of Billed Claims" with DOS filter
-- Run in NWL_LRN
-- ============================================================

DECLARE @DosFrom DATE = '2026-01-01';
DECLARE @DosTo   DATE = '2026-06-30';

-- Step 1: Build #Base the same way the production aggregate SP does
--         (Billed derived from FirstBilledDate / EmedixSubmissionDate)
DROP TABLE IF EXISTS #Base;
CREATE TABLE #Base
(
    AccessionNumber  NVARCHAR(100)  NOT NULL,
    ESYear           INT            NOT NULL,
    ESMonth          INT            NOT NULL,
    Billed           NVARCHAR(50)   NOT NULL,
    ClaimType        NVARCHAR(200)  NOT NULL,
    ClaimStatus      NVARCHAR(200)  NOT NULL,
    ChargeAmount     DECIMAL(18,2)  NOT NULL,
    InsurancePayment DECIMAL(18,2)  NOT NULL,
    InsuranceBalance DECIMAL(18,2)  NOT NULL
);

INSERT INTO #Base
SELECT
    LTRIM(RTRIM(ISNULL(AccessionNumber, '')))              AS AccessionNumber,
    YEAR (TRY_CAST(DateofService AS DATE))                 AS ESYear,
    MONTH(TRY_CAST(DateofService AS DATE))                 AS ESMonth,
    -- Billed derived from date columns (matches production SP)
    CASE
        WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), FirstBilledDate),    ''))), '') IS NOT NULL THEN 'Billed'
        WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), EmedixSubmissionDate),''))), '') IS NOT NULL THEN 'Billed'
        ELSE 'Unbilled'
    END                                                    AS Billed,
    ISNULL(LTRIM(RTRIM(ClaimType)),   '')                  AS ClaimType,
    ISNULL(LTRIM(RTRIM(ClaimStatus)), '')                  AS ClaimStatus,
    ISNULL(TRY_CAST(ChargeAmount      AS DECIMAL(18,2)), 0),
    ISNULL(TRY_CAST(InsurancePayment  AS DECIMAL(18,2)), 0),
    ISNULL(TRY_CAST(InsuranceBalance  AS DECIMAL(18,2)), 0)
FROM dbo.ClaimLevelData
WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber,''))), '') IS NOT NULL
  AND TRY_CAST(DateofService AS DATE) >= @DosFrom
  AND TRY_CAST(DateofService AS DATE) <= @DosTo;

-- Step 2: Check what Billed values are now in #Base
PRINT '-- Billed value distribution in #Base --';
SELECT Billed, COUNT(*) AS RecordCount
FROM #Base
GROUP BY Billed
ORDER BY RecordCount DESC;

-- Step 3: Row G — No. of Billed Claims (production SP logic)
PRINT '-- Row G per month --';
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

-- Step 4: Grand total
PRINT '-- Row G grand total --';
SELECT
    COUNT(DISTINCT CASE
            WHEN Billed = 'Billed'
             AND ClaimType NOT IN ('ADCS - Invoice', 'Test Patient Entries')
             AND ClaimStatus <> 'Billed Amount 0'
            THEN AccessionNumber
          END) AS TotalBilledClaims
FROM #Base;

DROP TABLE IF EXISTS #Base;

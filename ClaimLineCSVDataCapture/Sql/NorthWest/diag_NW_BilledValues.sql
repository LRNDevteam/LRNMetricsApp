-- ============================================================
-- Diagnostic: NW Billed Claims = 0 in filtered path
-- Run in NorthWest_LRN to identify root cause
-- ============================================================

-- 1. Which billed-related columns exist in ClaimLevelData?
PRINT '-- STEP 1: Column detection --';
SELECT name, TYPE_NAME(system_type_id) AS TypeName, max_length
FROM sys.columns
WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
  AND name IN ('Billed','BillStatus','BillingStatus','BilledStatus',
               'FirstBillDate','FirstBilledDate','First_Bill_Date',
               'EmedixSubmissionDate','EmedixSubmitDate',
               'ClaimType','ClaimCategory')
ORDER BY name;

-- 2. What are the actual Billed column values for 2026 Jan–Jun?
--    (Uses 'Billed' — replace with whichever column name step 1 shows)
PRINT '-- STEP 2: Billed value distribution for DOS 2026-01-01 to 2026-06-30 --';
SELECT
    ISNULL(LTRIM(RTRIM(CAST([Billed] AS NVARCHAR(200)))), '<<NULL/EMPTY>>') AS BilledValue,
    COUNT(*)                                AS RecordCount,
    MIN(TRY_CAST(DateofService AS DATE))    AS EarliestDOS,
    MAX(TRY_CAST(DateofService AS DATE))    AS LatestDOS
FROM dbo.ClaimLevelData
WHERE TRY_CAST(DateofService AS DATE) >= '2026-01-01'
  AND TRY_CAST(DateofService AS DATE) <= '2026-06-30'
GROUP BY LTRIM(RTRIM(CAST([Billed] AS NVARCHAR(200))))
ORDER BY RecordCount DESC;

-- 3. How many rows would #Base get for this DOS range?
PRINT '-- STEP 3: #Base row count sanity check --';
SELECT COUNT(*) AS BaseRowCount
FROM dbo.ClaimLevelData
WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber,''))), '') IS NOT NULL
  AND TRY_CAST(DateofService AS DATE) >= '2026-01-01'
  AND TRY_CAST(DateofService AS DATE) <= '2026-06-30';

-- 4. How many would pass the Row G condition AS-IS?
PRINT '-- STEP 4: Row G count with current condition --';
SELECT COUNT(DISTINCT AccessionNumber) AS BilledClaimsCount
FROM dbo.ClaimLevelData
WHERE TRY_CAST(DateofService AS DATE) >= '2026-01-01'
  AND TRY_CAST(DateofService AS DATE) <= '2026-06-30'
  AND TRY_CAST(DateofService AS DATE) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber,''))), '') IS NOT NULL
  AND ISNULL(LTRIM(RTRIM([Billed])), '') IN ('Billed', 'Billed - Client')
  AND ISNULL(LTRIM(RTRIM(ClaimStatus)), '') <> 'Billed Amount 0';

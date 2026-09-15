SET NOCOUNT ON;

PRINT '=== Q1 COUNT by FirstBilledDate month (client) ===';
SELECT COUNT(*) AS LineCount,
       SUM(TRY_CAST(Units AS DECIMAL(18,2))) AS SumUnits,
       SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))) AS SumCharges
FROM dbo.LineLevelData
WHERE LTRIM(RTRIM(CPTCode)) = '87798'
  AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
  AND LTRIM(RTRIM(ISNULL(FirstBilledDate,''))) <> ''
  AND FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM') = '2025-11';

PRINT '=== Q2 FirstBilledDate month + ChargeEnteredDate not blank ===';
SELECT COUNT(*) AS LineCount
FROM dbo.LineLevelData
WHERE LTRIM(RTRIM(CPTCode)) = '87798'
  AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
  AND LTRIM(RTRIM(ISNULL(FirstBilledDate,''))) <> ''
  AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
  AND FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM') = '2025-11';

PRINT '=== Q3 COUNT by ChargeEnteredDate month (current SP month) ===';
SELECT COUNT(*) AS LineCount,
       SUM(TRY_CAST(Units AS DECIMAL(18,2))) AS SumUnits
FROM dbo.LineLevelData
WHERE LTRIM(RTRIM(CPTCode)) = '87798'
  AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
  AND LTRIM(RTRIM(ISNULL(FirstBilledDate,''))) <> ''
  AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
  AND FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') = '2025-11';

PRINT '=== Q4 snapshot ===';
SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
FROM dbo.Cove_CPTBreakdown
WHERE LTRIM(RTRIM(CPTCode)) = '87798' AND BilledYearMonth = '2025-11';

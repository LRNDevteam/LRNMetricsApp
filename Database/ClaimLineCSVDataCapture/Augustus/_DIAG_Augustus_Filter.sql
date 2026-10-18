/* ============================================================
   Augustus filter diagnostic — run in SSMS against Augustus_LRN
   Goal: find why selecting Clinics (or Panels) returns all zeros.
   Run each step and note the result.
   ============================================================ */
USE Augustus_LRN;
GO

-- 1) Is the DEPLOYED Read SP actually my updated (CHARINDEX) version?
--    Expect: HasCharindex = 1.  If 0, the SP was NOT re-deployed.
SELECT
    HasCharindex   = CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.usp_GetAug_ExecutiveSummary')) LIKE '%CHARINDEX%' THEN 1 ELSE 0 END,
    StillUsesIN    = CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.usp_GetAug_ExecutiveSummary')) LIKE '%IN (SELECT Val FROM #FilterClinics)%' THEN 1 ELSE 0 END;
GO

-- 2) Does ClaimLevelData have rows, and parseable DateofService?
--    (The filtered path requires TRY_CAST(DateofService AS DATE) IS NOT NULL.)
SELECT
    TotalRows      = COUNT(*),
    ParseableDates = SUM(CASE WHEN TRY_CAST(DateofService AS DATE) IS NOT NULL THEN 1 ELSE 0 END),
    NonNullClinic  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ClinicName)),'') IS NOT NULL THEN 1 ELSE 0 END)
FROM dbo.ClaimLevelData;
GO

-- 3) What ClinicName values actually exist (top 30 by volume)?
--    Compare these EXACTLY to the dropdown chips you selected.
SELECT TOP 30 ClinicName = LTRIM(RTRIM(ClinicName)), Rows = COUNT(*)
FROM dbo.ClaimLevelData
WHERE NULLIF(LTRIM(RTRIM(ClinicName)),'') IS NOT NULL
GROUP BY LTRIM(RTRIM(ClinicName))
ORDER BY COUNT(*) DESC;
GO

-- 4) Reproduce the EXACT filter the app runs for the 4 selected clinics.
--    Expect MatchRows > 0.  If 0, the selected names are not present in ClinicName.
DECLARE @Clinics NVARCHAR(MAX) = N'Advanced Urgent Care,BMC BELLWOOD,BMC Melrose,Broadway Medical Center';
SELECT MatchRows = COUNT(*)
FROM dbo.ClaimLevelData
WHERE CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,''))) COLLATE DATABASE_DEFAULT + ',',
                ',' + @Clinics + ',') > 0;
GO

-- 4b) How many of those also have a parseable DateofService (what #Base keeps)?
DECLARE @Clinics2 NVARCHAR(MAX) = N'Advanced Urgent Care,BMC BELLWOOD,BMC Melrose,Broadway Medical Center';
SELECT BaseRows = COUNT(*)
FROM dbo.ClaimLevelData
WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(AccessionNumber)),'') IS NOT NULL
  AND CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,''))) COLLATE DATABASE_DEFAULT + ',',
                ',' + @Clinics2 + ',') > 0;
GO

-- 5) End-to-end: run the SP exactly as the app does for a clinic filter.
--    If steps 2-4 show data but this returns zeros, the issue is inside the SP.
EXEC dbo.usp_GetAug_ExecutiveSummary
     @Clinics = N'Advanced Urgent Care,BMC BELLWOOD,BMC Melrose,Broadway Medical Center';
GO

-- 6) Confirm the dropdown source matches the filter column.
EXEC dbo.usp_GetAug_ExecutiveSummary_FilterOptions;
GO

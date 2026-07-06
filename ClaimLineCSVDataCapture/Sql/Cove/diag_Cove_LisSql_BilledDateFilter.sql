-- ============================================================
-- Diagnostic: @LisSql with BilledDate filter
-- Mirrors exactly what usp_GetCove_ExecutiveSummary builds
-- when @BilledFrom / @BilledTo are passed WITH a dimension filter
-- (Panel / Clinic / Provider) so @HasLisFilter = 1.
--
-- Run in: Cove_LRN
-- ============================================================

DECLARE @BilledFrom DATE = '2026-01-01';
DECLARE @BilledTo   DATE = '2026-06-29';

-- Dimension filter params (set to "no filter" for this test)
DECLARE @HasPanelFilter    BIT          = 0;
DECLARE @HasClinicFilter   BIT          = 0;
DECLARE @HasProviderFilter BIT          = 0;
DECLARE @Panels            NVARCHAR(MAX) = NULL;
DECLARE @Clinics           NVARCHAR(MAX) = NULL;
DECLARE @Providers         NVARCHAR(MAX) = NULL;

-- DOS params (NULL = no DOS filter in this test)
DECLARE @DosFrom DATE = NULL;
DECLARE @DosTo   DATE = NULL;

-- ── Build #Lis ───────────────────────────────────────────────
DROP TABLE IF EXISTS #Lis;
CREATE TABLE #Lis
(
    Accession    NVARCHAR(100) NOT NULL,
    NewStatus    NVARCHAR(200) NOT NULL,
    PanelType    NVARCHAR(200) NOT NULL,
    BillCategory NVARCHAR(200) NOT NULL,
    SubStatus    NVARCHAR(200) NOT NULL,
    LISYear      INT           NOT NULL DEFAULT 0,
    LISMonth     INT           NOT NULL DEFAULT 0
);

-- This is the static equivalent of @LisSql using Cove's resolved column names:
--   @AccCol          = Accession
--   @DateCol         = DateOfCollection  (→ LISYear/LISMonth period)
--   @NewStatusCol    = NewStatus
--   @PanelTypeCol    = PanelType
--   @BillCategoryCol = BillCategory
--   @SubStatusCol    = SubStatus
--   @BilledDateCol   = BilledDate        (→ BilledDate filter)
INSERT INTO #Lis (Accession, NewStatus, PanelType, BillCategory, SubStatus, LISYear, LISMonth)
SELECT
    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [Accession]))),
    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [NewStatus]),    ''))),
    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [PanelType]),    ''))),
    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [BillCategory]), ''))),
    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [SubStatus]),    ''))),
    ISNULL(YEAR (TRY_CAST([DateOfCollection] AS DATE)), 0),
    ISNULL(MONTH(TRY_CAST([DateOfCollection] AS DATE)), 0)
FROM dbo.LIMSMaster
WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [Accession]))), '') IS NOT NULL
  -- Dimension filters (all OFF in this test)
  AND (@HasPanelFilter    = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[PanelType]),   ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Panels    + ',') > 0)
  AND (@HasClinicFilter   = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[FacilityName]),'')   )) COLLATE DATABASE_DEFAULT + ',', ',' + @Clinics   + ',') > 0)
  AND (@HasProviderFilter = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[PhysicianName]),'')  )) COLLATE DATABASE_DEFAULT + ',', ',' + @Providers + ',') > 0)
  -- DOS filter (NULL in this test)
  AND (@DosFrom    IS NULL OR TRY_CAST([DateOfCollection] AS DATE) >= @DosFrom)
  AND (@DosTo      IS NULL OR TRY_CAST([DateOfCollection] AS DATE) <= @DosTo)
  -- BilledDate filter — native DATE column, direct compare (SARGable, uses index)
  AND (@BilledFrom IS NULL OR [BilledDate] >= @BilledFrom)
  AND (@BilledTo   IS NULL OR [BilledDate] <= @BilledTo);

-- ── Verify #Lis contents ─────────────────────────────────────
PRINT '-- #Lis row count --';
SELECT COUNT(*) AS LisRowCount FROM #Lis;

PRINT '-- BillCategory distribution --';
SELECT BillCategory, COUNT(DISTINCT Accession) AS AccessionCount
FROM #Lis
GROUP BY BillCategory
ORDER BY AccessionCount DESC;

PRINT '-- LIS rows A-E per month --';
SELECT
    l.LISYear, l.LISMonth,
    COUNT(DISTINCT l.Accession)                                                                            AS A_TotalSamples,
    COUNT(DISTINCT CASE WHEN l.NewStatus = 'Billable'                                THEN l.Accession END) AS B_Billable,
    COUNT(DISTINCT CASE WHEN l.NewStatus = 'Billable' AND l.BillCategory = 'Billed'     THEN l.Accession END) AS C_Billed,
    COUNT(DISTINCT CASE WHEN l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' THEN l.Accession END) AS D_NotBilled,
    COUNT(DISTINCT CASE WHEN l.NewStatus <> 'Billable'                               THEN l.Accession END) AS E_Other
FROM #Lis l
GROUP BY l.LISYear, l.LISMonth
ORDER BY l.LISYear, l.LISMonth;

PRINT '-- Grand total --';
SELECT
    COUNT(DISTINCT l.Accession)                                                                            AS A_TotalSamples,
    COUNT(DISTINCT CASE WHEN l.NewStatus = 'Billable'                                THEN l.Accession END) AS B_Billable,
    COUNT(DISTINCT CASE WHEN l.NewStatus = 'Billable' AND l.BillCategory = 'Billed'     THEN l.Accession END) AS C_Billed,
    COUNT(DISTINCT CASE WHEN l.NewStatus = 'Billable' AND l.BillCategory = 'Not Billed' THEN l.Accession END) AS D_NotBilled,
    COUNT(DISTINCT CASE WHEN l.NewStatus <> 'Billable'                               THEN l.Accession END) AS E_Other
FROM #Lis l;

DROP TABLE IF EXISTS #Lis;

-- ============================================================
-- Cove – Executive Summary Filter Options SP
-- File : 22_Cove_ExecutiveSummary_FilterOptions.sql
-- DB   : Cove_LRN
--
-- usp_GetCove_ExecutiveSummary_FilterOptions
--
-- Returns a single result set with all dimension values needed
-- to populate the Executive Summary filter dropdowns.
-- Each row has: FilterType, FilterValue, SortOrder.
--
-- FilterType values returned:
--   'Year'     – distinct billing years from ClaimLevelData.DateofService
--   'Panel'    – distinct PanelType values from ClaimLevelData UNION LIMSMaster
--   'Clinic'   – distinct ClinicName values from ClaimLevelData
--   'Provider' – distinct ReferringProvider values from ClaimLevelData
--   'Rep'      – distinct SalesRepname values from ClaimLevelData
--
-- Called by ExecutiveSummaryController.FilterOptions (AJAX) for Cove lab only.
-- No inline queries — all data sourced from indexed base tables via this SP.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_ExecutiveSummary_FilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Years ────────────────────────────────────────────────────────────────
    SELECT
        'Year'                                               AS FilterType,
        CAST(YEAR(TRY_CAST(DateofService AS DATE)) AS NVARCHAR(50)) AS FilterValue,
        YEAR(TRY_CAST(DateofService AS DATE))               AS SortOrder
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
    GROUP BY YEAR(TRY_CAST(DateofService AS DATE))

    UNION ALL

    -- ── Panels (ClaimLevelData.PanelType) ────────────────────────────────────
    SELECT
        'Panel'                                              AS FilterType,
        LTRIM(RTRIM(PanelType))                             AS FilterValue,
        0                                                   AS SortOrder
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(PanelType))

    UNION ALL

    -- ── Panels (LIMSMaster.PanelType) – distinct values not already in CLD ──
    -- Uses the same column auto-detection as the LIS Aggregate / Read SPs so
    -- it stays resilient to schema variations across environments.
    SELECT
        'Panel'                                              AS FilterType,
        LTRIM(RTRIM(PanelType))                             AS FilterValue,
        0                                                   AS SortOrder
    FROM dbo.LIMSMaster
    WHERE NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL
      AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    GROUP BY LTRIM(RTRIM(PanelType))

    UNION ALL

    -- ── Clinics ──────────────────────────────────────────────────────────────
    SELECT
        'Clinic'                                             AS FilterType,
        LTRIM(RTRIM(ClinicName))                            AS FilterValue,
        0                                                   AS SortOrder
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(ClinicName)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ClinicName))

    UNION ALL

    -- ── Referring Providers ───────────────────────────────────────────────────
    SELECT
        'Provider'                                           AS FilterType,
        LTRIM(RTRIM(ReferringProvider))                     AS FilterValue,
        0                                                   AS SortOrder
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(ReferringProvider)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ReferringProvider))

    UNION ALL

    -- ── Sales Reps ────────────────────────────────────────────────────────────
    SELECT
        'Rep'                                                AS FilterType,
        LTRIM(RTRIM(SalesRepname))                          AS FilterValue,
        0                                                   AS SortOrder
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(SalesRepname)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(SalesRepname))

    ORDER BY FilterType, SortOrder DESC, FilterValue;
END;
GO

PRINT '22_Cove_ExecutiveSummary_FilterOptions.sql completed.';
GO

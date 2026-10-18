-- ============================================================
-- RisingTides – Executive Summary Filter Options SP
-- File : 22_RisingTides_ExecutiveSummary_FilterOptions.sql
-- DB   : Rising_Tides
--
-- usp_GetRT_ExecutiveSummary_FilterOptions
--
-- Returns FilterType, FilterValue, SortOrder rows for:
--   'Year'     – distinct billing years from ClaimLevelData.DateofService
--   'Panel'    – distinct PanelName values from ClaimLevelData
--   'Clinic'   – distinct ClinicName values from ClaimLevelData
--   'Provider' – distinct ReferringProvider values from ClaimLevelData
--   'Rep'      – distinct SalesRepname values from ClaimLevelData
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_ExecutiveSummary_FilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        'Year'                                               AS FilterType,
        CAST(YEAR(TRY_CAST(DateofService AS DATE)) AS NVARCHAR(50)) AS FilterValue,
        YEAR(TRY_CAST(DateofService AS DATE))               AS SortOrder
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
    GROUP BY YEAR(TRY_CAST(DateofService AS DATE))

    UNION ALL

    SELECT 'Panel', LTRIM(RTRIM(PanelName)), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(PanelName)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(PanelName))

    UNION ALL

    SELECT 'Clinic', LTRIM(RTRIM(ClinicName)), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(ClinicName)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ClinicName))

    UNION ALL

    SELECT 'Provider', LTRIM(RTRIM(ReferringProvider)), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(ReferringProvider)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(ReferringProvider))

    UNION ALL

    SELECT 'Rep', LTRIM(RTRIM(SalesRepname)), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(SalesRepname)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(SalesRepname))

    ORDER BY FilterType, SortOrder DESC, FilterValue;
END;
GO

PRINT '22_RisingTides_ExecutiveSummary_FilterOptions.sql completed.';
GO

-- ============================================================
-- Inhealth – Executive Summary Filter Options SP
-- File : 25_Inhealth_ExecutiveSummary_FilterOptions.sql
-- DB   : Inhealth_LRN
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetInh_ExecutiveSummary_FilterOptions
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

    -- Panel dropdown is sourced from PanelNameBasedOnCPT so the listed values
    -- match the panel filter in usp_GetInh_ExecutiveSummary (file 24).
    SELECT 'Panel', LTRIM(RTRIM(PanelNameBasedOnCPT)), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(PanelNameBasedOnCPT)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(PanelNameBasedOnCPT))

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

PRINT '25_Inhealth_ExecutiveSummary_FilterOptions.sql completed.';
GO

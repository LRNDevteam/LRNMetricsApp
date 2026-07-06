-- ============================================================
-- Certus – Executive Summary Filter Options SP
-- File : 22_Certus_ExecutiveSummary_FilterOptions.sql
-- DB   : Certus_LRN
--
-- Fix: Panel option list was reading dbo.ClaimLevelData.PanelType, the same
-- stale/incorrect column already corrected to Panelname in
-- 16_Certus_ExecutiveSummary_Aggregate.sql and 17_Certus_ExecutiveSummary_Read.sql.
-- Because this SP fills the Panel dropdown, any value picked from it never
-- matched a real Panelname value in the main SP's filter -> 0 rows whenever
-- a Panel filter was applied, even though the unfiltered/aggregate path worked.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCert_ExecutiveSummary_FilterOptions
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

    SELECT 'Panel', LTRIM(RTRIM(Panelname)), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(Panelname))

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

PRINT '22_Certus_ExecutiveSummary_FilterOptions.sql completed.';
GO

/* =============================================================================
   VariantX Labs — cloned from Elixir (22_Elixir_ExecutiveSummary_FilterOptions.sql)
   Prefix: VarX_ / VarX_CS_ / VarX_ES_
   Refresh: usp_RefreshVarX_*
   Read:    usp_GetVarX_*
   Source tables: dbo.ClaimLevelData, dbo.LineLevelData, dbo.LIMSMaster
   No inline UI queries — dashboard/ReportWorker must call these SPs only.
   ============================================================================= */
-- ============================================================
-- VariantX – Executive Summary Filter Options SP
-- File : 22_VariantX_ExecutiveSummary_FilterOptions.sql
-- DB   : VariantX_LRN
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_ExecutiveSummary_FilterOptions
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

    SELECT 'Panel', LTRIM(RTRIM(PanelType)), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(PanelType)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(PanelType))

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

PRINT '22_VariantX_ExecutiveSummary_FilterOptions.sql completed.';
GO


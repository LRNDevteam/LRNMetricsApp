/* =============================================================================
   Analyze Pathology (prefix AnP_) - GENERATED from Sql/VariantX/22b_VariantX_ExecutiveSummary_FilterOptions_Fix.sql
   by Generate-FromVariantX.ps1. Edit the VariantX script or the generator, not this file.
   Database: AnalyzePathology

   Analyze Pathology mappings applied on top of the VariantX logic:
     ClaimLevelData.AdjucticatedCount / Bucket30Count / Bucket60Count
         -> Adjudicated / Bucket30 / Bucket60  (AdjucticatedAmount -> AdjudicatedAmount)
     Billed / Unbilled from ClaimLevelData.BilledStatus LIKE 'Unbilled%'
     ClaimStatus 'Fully Denied' counts as 'Denied', '0 Billed Amount' as 'Billed Amount 0'
     LIMSMaster.BillCategory 'Unbilled' counts as 'Not Billed',
         NewStatus 'Yet to Be Validate' as 'Yet to be validated'
     LIMSMaster panel column: PanelName (PanelCategory is never populated)
   Comments further down were written for VariantX ("AnalyzePathology" there
   was substituted for "VariantX").
   ============================================================================= */
/* =============================================================================
   Analyze Pathology — cloned from Elixir (22_Elixir_ExecutiveSummary_FilterOptions.sql)
   Prefix: AnP_ / AnP_CS_ / AnP_ES_
   Refresh: usp_RefreshAnP_*
   Read:    usp_GetAnP_*
   Source tables: dbo.ClaimLevelData, dbo.LineLevelData, dbo.LIMSMaster
   No inline UI queries — dashboard/ReportWorker must call these SPs only.
   ============================================================================= */
-- ============================================================
-- AnalyzePathology – Executive Summary Filter Options SP
-- File : 22_AnalyzePathology_ExecutiveSummary_FilterOptions.sql
-- DB   : AnalyzePathology
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_ExecutiveSummary_FilterOptions
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

PRINT '22_AnalyzePathology_ExecutiveSummary_FilterOptions.sql completed.';
GO


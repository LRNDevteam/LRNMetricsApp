/* =============================================================================
   07_CodingValidation_WtdTotalBilled_2026-07-30.sql
   -----------------------------------------------------------------------------
   INCREMENTAL deploy — adds TotalBilledCharges to dbo.CodingAgg_WtdSummary
   (same logic as YTD Summary: SUM(TRY_CAST(TotalCharge AS DECIMAL(18,2)))).

   This script:
     1) Adds the column if missing (idempotent)
     2) Updates dbo.usp_GetCodingAggWtdSummary to return the new column

   AFTER THIS SCRIPT, you must also deploy the updated refresh procedure from
   04_CodingAggregates.sql or 05_CodingValidation_Incremental_2026-07-28.sql
   (usp_RefreshCodingAggregates now populates TotalBilledCharges on WTD Summary),
   then rebuild aggregates once per lab:

       EXEC dbo.usp_RefreshCodingAggregates @LabName = '<lab>';

   Safe to re-run. Does NOT change YTD Insights.
   ============================================================================= */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   1. CodingAgg_WtdSummary - add TotalBilledCharges (idempotent)
   --------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.CodingAgg_WtdSummary') AND name = 'TotalBilledCharges')
    ALTER TABLE dbo.CodingAgg_WtdSummary ADD TotalBilledCharges DECIMAL(18,2) NULL;
GO

/* ---------------------------------------------------------------------------
   2. Read proc — expose TotalBilledCharges after TotalClaims
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetCodingAggWtdSummary
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        WeekFolder, PanelName,
        BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
        TotalClaims, TotalBilledCharges, DistinctClaimsWithMissingCpts,
        TotalBilledChargesForMissingCpts, AvgAllowedAmountForMissingCpts,
        -- >>> CVTPL-1.4 CHANGE (2026-07-27): expose additional-CPT + revenue columns per template v1.4.
        --     REVERT: delete this line.
        DistinctClaimsWithAdditionalCpts, TotalBilledChargesForAdditionalCpts,
        LostRevenue, RevenueAtRisk, NetImpact
        -- <<< END CVTPL-1.4 CHANGE
    FROM dbo.CodingAgg_WtdSummary
    -- CVBILL-1.4: order by the week's end date (billed-date label "MM/dd/yyyy to MM/dd/yyyy"), newest first.
    --             REVERT: ORDER BY WeekFolder DESC, PanelName;
    ORDER BY TRY_CAST(RIGHT(WeekFolder, 10) AS DATE) DESC, PanelName;
END
GO

PRINT '07_CodingValidation_WtdTotalBilled_2026-07-30.sql completed.';
PRINT 'Next: deploy updated usp_RefreshCodingAggregates from 04/05, then EXEC dbo.usp_RefreshCodingAggregates.';
GO

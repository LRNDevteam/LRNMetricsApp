/* =============================================================================
   OBSOLETE — do not run.

   VariantX CPT Breakdown is defined in 10_VariantX_CPTBreakdown.sql:
     FirstBilledDate filter, SUM(Units) + SUM(ChargeAmount), totals only
     (usp_GetVarX_CPTBreakdownTotals).

   This file previously pivoted on ChargeEnteredDate and stored COUNT(ClaimID)
   as BilledUnits, which did not match the client sheet.
   ============================================================================= */
PRINT '10b_VariantX_CPTBreakdown_ChargeEnteredDate.sql is obsolete — use 10_VariantX_CPTBreakdown.sql.';
GO

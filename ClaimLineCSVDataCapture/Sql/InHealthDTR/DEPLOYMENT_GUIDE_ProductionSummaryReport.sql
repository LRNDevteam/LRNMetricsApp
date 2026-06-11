-- ============================================================
-- InHealthDTR ProductionSummaryReport — Complete Deployment Guide
-- ============================================================
-- Date: 2025 (Implementation based on PhiLife templates)
-- Purpose: Deploy InHealthDTR reporting stored procedures and tables
--          for ProductionSummaryReport integration
--
-- Scope: Tables, Refresh SPs, and Read SPs for:
--        • Monthly Billed Production Summary
--        • Weekly Billed Production Summary
--        • Payer Breakdown (payer-by-month, payer-by-panel)
--        • Coding Breakdown (panel summary, CPT detail)
--        • Unbilled Aging
--        • CPT Breakdown
-- ============================================================

/*
== SUMMARY OF NEWLY CREATED FILES ==

This deployment adds 5 new SQL scripts to ClaimLineCSVDataCapture\Sql\InHealthDTR:

  08_InHealthDTR_PayerBreakdown.sql
	 Creates: InH_PayerBreakdown, InH_PayerByPanel tables
	 SPs:     usp_RefreshInH_PayerBreakdown, usp_RefreshInH_PayerByPanel

  09_InHealthDTR_CodingBreakdown.sql
	 Creates: InH_CodingPanelSummary, InH_CodingCPTDetail tables
	 SP:      usp_RefreshInH_CodingBreakdown_Billed

  10_InHealthDTR_UnbilledAging.sql
	 Creates: InH_UnbilledAging table
	 SP:      usp_RefreshInH_UnbilledAging

  11_InHealthDTR_CPTBreakdown.sql
	 Creates: InH_CPTBreakdown table
	 SP:      usp_RefreshInH_CPTBreakdown

  14_InHealthDTR_ReadSPs.sql
	 Creates: 7 read-only SPs for ProductionSummaryReport
	 - usp_GetInH_MonthlyBilledProductionSummary
	 - usp_GetInH_WeeklyBilledProductionSummary
	 - usp_GetInH_PayerBreakdown
	 - usp_GetInH_PayerByPanel
	 - usp_GetInH_CodingPanelSummary
	 - usp_GetInH_CodingCPTDetail
	 - usp_GetInH_UnbilledAging
	 - usp_GetInH_CPTBreakdown

== DEPLOYMENT STEPS ==

1. RUN EXISTING SETUP (if not already done):
   a. ClaimLineCSVDataCapture\Sql\InHealthDTR\01_Verify_Columns.sql
	  → Verifies schema and TVP alignment

   b. ClaimLineCSVDataCapture\Sql\InHealthDTR\02_InHealthDTR_Alter_ClaimLevelData_AddFields.sql
	  → Adds InHealthDTR-specific columns to ClaimLevelData

   c. ClaimLineCSVDataCapture\Sql\InHealthDTR\03_InHealthDTR_Alter_LineLevelData_AddFields.sql
	  → Adds InHealthDTR-specific columns to LineLevelData (includes PatientName)

   d. ClaimLineCSVDataCapture\Sql\InHealthDTR\04_InHealthDTR_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql
	  → Creates ClaimLevelDataTVP and usp_BulkInsertClaimLevelData

   e. ClaimLineCSVDataCapture\Sql\InHealthDTR\05_InHealthDTR_Recreate_LineLevelDataTVP_And_UpdateSP.sql
	  → Creates LineLevelDataTVP and usp_BulkInsertLineLevelData

2. RUN EXISTING PRODUCTION SUMMARY SPs (if not already done):
   a. ClaimLineCSVDataCapture\Sql\InHealthDTR\06_InHealthDTR_MonthlyBilledProductionSummary.sql
	  → Creates InH_MonthlyBilledProductionSummary and refresh SP

   b. ClaimLineCSVDataCapture\Sql\InHealthDTR\07_InHealthDTR_WeeklyBilledProductionSummary.sql
	  → Creates InH_WeeklyBilledProductionSummary and refresh SP

3. RUN NEW REPORTING SPs (in order):
   a. ClaimLineCSVDataCapture\Sql\InHealthDTR\08_InHealthDTR_PayerBreakdown.sql
	  → Creates payer breakdown tables and refresh SPs

   b. ClaimLineCSVDataCapture\Sql\InHealthDTR\09_InHealthDTR_CodingBreakdown.sql
	  → Creates coding breakdown tables and refresh SP

   c. ClaimLineCSVDataCapture\Sql\InHealthDTR\10_InHealthDTR_UnbilledAging.sql
	  → Creates unbilled aging table and refresh SP

   d. ClaimLineCSVDataCapture\Sql\InHealthDTR\11_InHealthDTR_CPTBreakdown.sql
	  → Creates CPT breakdown table and refresh SP

   e. ClaimLineCSVDataCapture\Sql\InHealthDTR\14_InHealthDTR_ReadSPs.sql
	  → Creates all read-only SPs for report integration

4. VERIFY DEPLOYMENT:
   Run: ClaimLineCSVDataCapture\Sql\InHealthDTR\INHEALTH_DTR_REPORTING_SUMMARY.sql
   → Provides summary of created tables and SPs

== REFRESH THE AGGREGATION TABLES ==

After deployment, populate the summary tables with current data:

   EXEC dbo.usp_RefreshInH_MonthlyBilledProductionSummary;
   EXEC dbo.usp_RefreshInH_WeeklyBilledProductionSummary;
   EXEC dbo.usp_RefreshInH_PayerBreakdown;
   EXEC dbo.usp_RefreshInH_PayerByPanel;
   EXEC dbo.usp_RefreshInH_CodingBreakdown_Billed;
   EXEC dbo.usp_RefreshInH_UnbilledAging;
   EXEC dbo.usp_RefreshInH_CPTBreakdown;

== INTEGRATION WITH ProductionSummaryReport ==

The read SPs are designed to be called by LabMetricsDashboard.SqlLabProductionSummaryRepository:

   • Fast path (no filters):
	 EXEC dbo.usp_GetInH_MonthlyBilledProductionSummary;
	 → Returns cached data from InH_MonthlyBilledProductionSummary (fast)

   • Live path (with filters):
	 EXEC dbo.usp_GetInH_MonthlyBilledProductionSummary
		  @PayerNames='Payer1|Payer2', @PanelNames='Panel1',
		  @FirstBilledFrom='2024-01-01', @FirstBilledTo='2024-12-31';
	 → Aggregates live from ClaimLevelData (flexible filtering)

All read SPs follow this dual-path pattern.

== AUTOMATION ==

To automate refresh cycle, consider adding a SQL Agent job or scheduled task that runs:

   -- Step 1: Refresh all summary tables (runs nightly or on schedule)
   EXEC dbo.usp_RefreshInH_MonthlyBilledProductionSummary;
   EXEC dbo.usp_RefreshInH_WeeklyBilledProductionSummary;
   EXEC dbo.usp_RefreshInH_PayerBreakdown;
   EXEC dbo.usp_RefreshInH_PayerByPanel;
   EXEC dbo.usp_RefreshInH_CodingBreakdown_Billed;
   EXEC dbo.usp_RefreshInH_UnbilledAging;
   EXEC dbo.usp_RefreshInH_CPTBreakdown;

== COMPATIBILITY NOTES ==

• InHealthDTR uses individual CPTCode/Units/Modifier in LineLevelData
  (differs from PhiLife's aggregate CPTCodeXUnitsXModifier)

• Both labs share the same report table/SP naming pattern:
  Lab-specific prefix (InH_ for InHealthDTR, Phi_ for PhiLife) + function name

• Filter parameters use '|' as delimiter to safely handle names with commas

• All SPs check for NULL/empty filters; no filters returns cached snapshot (fast path)

== TROUBLESHOOTING ==

If SPs fail to create:
   1. Verify ClaimLevelData and LineLevelData tables exist
   2. Verify all required columns exist (see 01_Verify_Columns.sql output)
   3. Verify TVP definitions exist (should be done by scripts 04/05)
   4. Verify no naming conflicts with existing tables/SPs

If read SPs return no data:
   1. Verify refresh SPs have been executed (populate summary tables)
   2. Verify ClaimLevelData/LineLevelData contain records with non-NULL FirstBilledDate
   3. Run read SPs without filters first (should return cached snapshot)

== SUPPORT ==

For issues or questions about the reporting structure, reference:
   • INHEALTH_DTR_REPORTING_SUMMARY.sql (overview of tables and SPs)
   • Original PhiLife templates in ClaimLineCSVDataCapture\Sql\PhiLife\
   • LabMetricsDashboard.SqlLabProductionSummaryRepository (report integration)

*/

PRINT '============================================================';
PRINT 'InHealthDTR ProductionSummaryReport — Deployment Guide';
PRINT 'Complete. See comments above for detailed instructions.';
PRINT '============================================================';

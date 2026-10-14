-- InHealthDTR Production Summary Report Stored Procedures — Summary
-- ============================================================
-- Created: Based on PhiLife templates for consistent reporting patterns
-- Purpose: Support the ProductionSummaryReport with InHealthDTR data
--
-- New files created:
-- 08_InHealthDTR_PayerBreakdown.sql
-- 09_InHealthDTR_CodingBreakdown.sql
-- 10_InHealthDTR_UnbilledAging.sql
-- 11_InHealthDTR_CPTBreakdown.sql
-- 14_InHealthDTR_ReadSPs.sql
--
-- Existing files (already in place):
-- 06_InHealthDTR_MonthlyBilledProductionSummary.sql
-- 07_InHealthDTR_WeeklyBilledProductionSummary.sql
-- ============================================================

-- TABLES CREATED / REFERENCED:
-- ============================================================

-- 06: Monthly Billed Production Summary
--   Table: dbo.InH_MonthlyBilledProductionSummary
--   SP:    dbo.usp_RefreshInH_MonthlyBilledProductionSummary
--   Read:  dbo.usp_GetInH_MonthlyBilledProductionSummary (in 14_InHealthDTR_ReadSPs.sql)

-- 07: Weekly Billed Production Summary
--   Table: dbo.InH_WeeklyBilledProductionSummary
--   SP:    dbo.usp_RefreshInH_WeeklyBilledProductionSummary
--   Read:  dbo.usp_GetInH_WeeklyBilledProductionSummary (in 14_InHealthDTR_ReadSPs.sql)

-- 08: Payer Breakdown
--   Table: dbo.InH_PayerBreakdown
--   Table: dbo.InH_PayerByPanel
--   SP:    dbo.usp_RefreshInH_PayerBreakdown
--   SP:    dbo.usp_RefreshInH_PayerByPanel
--   Read:  dbo.usp_GetInH_PayerBreakdown (in 14_InHealthDTR_ReadSPs.sql)
--   Read:  dbo.usp_GetInH_PayerByPanel (in 14_InHealthDTR_ReadSPs.sql)

-- 09: Coding Breakdown
--   Table: dbo.InH_CodingPanelSummary
--   Table: dbo.InH_CodingCPTDetail
--   SP:    dbo.usp_RefreshInH_CodingBreakdown_Billed
--   Read:  dbo.usp_GetInH_CodingPanelSummary (in 14_InHealthDTR_ReadSPs.sql)
--   Read:  dbo.usp_GetInH_CodingCPTDetail (in 14_InHealthDTR_ReadSPs.sql)

-- 10: Unbilled Aging
--   Table: dbo.InH_UnbilledAging
--   SP:    dbo.usp_RefreshInH_UnbilledAging
--   Read:  dbo.usp_GetInH_UnbilledAging (in 14_InHealthDTR_ReadSPs.sql)
--   Note:  Uses Aging column from ClaimLevelData (not AgingBucket)

-- 11: CPT Breakdown
--   Table: dbo.InH_CPTBreakdown
--   SP:    dbo.usp_RefreshInH_CPTBreakdown
--   Read:  dbo.usp_GetInH_CPTBreakdown (in 14_InHealthDTR_ReadSPs.sql)

-- ============================================================
-- DEPLOYMENT SEQUENCE
-- ============================================================
-- Run in order within the same session or script batch:
-- 1. 06_InHealthDTR_MonthlyBilledProductionSummary.sql  (existing)
-- 2. 07_InHealthDTR_WeeklyBilledProductionSummary.sql   (existing)
-- 3. 08_InHealthDTR_PayerBreakdown.sql                  (new)
-- 4. 09_InHealthDTR_CodingBreakdown.sql                 (new)
-- 5. 10_InHealthDTR_UnbilledAging.sql                   (new)
-- 6. 11_InHealthDTR_CPTBreakdown.sql                    (new)
-- 7. 14_InHealthDTR_ReadSPs.sql                         (new)

-- ============================================================
-- REFRESH PROCEDURE EXECUTION
-- ============================================================
-- Call these refresh SPs to populate the summary tables from current ClaimLevelData/LineLevelData:

-- EXEC dbo.usp_RefreshInH_MonthlyBilledProductionSummary;
-- EXEC dbo.usp_RefreshInH_WeeklyBilledProductionSummary;
-- EXEC dbo.usp_RefreshInH_PayerBreakdown;
-- EXEC dbo.usp_RefreshInH_PayerByPanel;
-- EXEC dbo.usp_RefreshInH_CodingBreakdown_Billed;
-- EXEC dbo.usp_RefreshInH_UnbilledAging;
-- EXEC dbo.usp_RefreshInH_CPTBreakdown;

-- ============================================================
-- READ STORED PROCEDURES (in 14_InHealthDTR_ReadSPs.sql)
-- ============================================================
-- Each read SP supports two execution paths:
--   1) NO parameters supplied  -> returns cached snapshot from summary table (fast path)
--   2) ANY filter parameters   -> aggregates live from ClaimLevelData/LineLevelData

-- Monthly Billed Production Summary with optional filters:
--   EXEC dbo.usp_GetInH_MonthlyBilledProductionSummary
--        @PayerNames='Payer1|Payer2', @PanelNames='Panel1|Panel2',
--        @FirstBilledFrom='2024-01-01', @FirstBilledTo='2024-12-31';

-- Weekly Billed Production Summary:
--   EXEC dbo.usp_GetInH_WeeklyBilledProductionSummary
--        @PayerNames='Payer1', @PanelNames='Panel1',
--        @FirstBilledFrom='2024-01-01', @FirstBilledTo='2024-12-31';

-- Payer Breakdown (by month):
--   EXEC dbo.usp_GetInH_PayerBreakdown
--        @PayerNames='Payer1|Payer2',
--        @FirstBilledFrom='2024-01-01', @FirstBilledTo='2024-12-31';

-- Payer by Panel:
--   EXEC dbo.usp_GetInH_PayerByPanel
--        @PayerNames='Payer1', @PanelNames='Panel1',
--        @FirstBilledFrom='2024-01-01', @FirstBilledTo='2024-12-31';

-- Coding Breakdown — Panel Summary:
--   EXEC dbo.usp_GetInH_CodingPanelSummary
--        @PanelNames='Panel1|Panel2',
--        @FirstBilledFrom='2024-01-01', @FirstBilledTo='2024-12-31';

-- Coding Breakdown — CPT Detail:
--   EXEC dbo.usp_GetInH_CodingCPTDetail
--        @PanelNames='Panel1',
--        @FirstBilledFrom='2024-01-01', @FirstBilledTo='2024-12-31';

-- Unbilled Aging:
--   EXEC dbo.usp_GetInH_UnbilledAging
--        @PanelNames='Panel1|Panel2';

-- CPT Breakdown:
--   EXEC dbo.usp_GetInH_CPTBreakdown
--        @CPTCodes='99213|99214|99215',
--        @FirstBilledFrom='2024-01-01', @FirstBilledTo='2024-12-31';

-- ============================================================
-- INTEGRATION WITH ProductionSummaryReport
-- ============================================================
-- The read SPs are designed for use by:
--   LabMetricsDashboard.SqlLabProductionSummaryRepository
--
-- The report will call the appropriate usp_GetInH_* SP based on the selected report tab.
-- Filter parameters (payers, panels, dates) are passed from the report UI via the | delimiter.

-- ============================================================
-- KEY DESIGN DIFFERENCES FROM PHILIFE
-- ============================================================
-- InHealthDTR uses:
--   • Individual CPTCode/Units/Modifier in LineLevelData (line-level detail)
--   • Payer name field: PayerName_Raw (consistent with mapping)
--   • Panel field: Panelname (consistent with mapping)
--   • Aging field in ClaimLevelData for unbilled categorization (not AgingBucket)
--   • PostedWeek field in ClaimLevelData for weekly aggregation

-- PhiLife uses:
--   • Aggregate CPTCodeXUnitsXModifier in LineLevelData
--   • AgingBucket field (lab-specific addition) in both ClaimLevelData and LineLevelData
--   • Same payer/panel/billing fields but inverted structure

-- Both labs follow the same table/procedure naming convention (lab-specific prefix + function name)
-- and the same report aggregation patterns.

PRINT '14_InHealthDTR_ReadSPs Summary completed.';

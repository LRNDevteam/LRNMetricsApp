-- ============================================================
-- QUICK REFERENCE: InHealthDTR ProductionSummaryReport SPs
-- ============================================================

-- REFRESH SPs (Populate aggregation tables from current data)
-- ============================================================

-- 06: Monthly Billed Production Summary
EXEC dbo.usp_RefreshInH_MonthlyBilledProductionSummary;

-- 07: Weekly Billed Production Summary
EXEC dbo.usp_RefreshInH_WeeklyBilledProductionSummary;

-- 08: Payer Breakdown
EXEC dbo.usp_RefreshInH_PayerBreakdown;
EXEC dbo.usp_RefreshInH_PayerByPanel;

-- 09: Coding Breakdown
EXEC dbo.usp_RefreshInH_CodingBreakdown_Billed;

-- 10: Unbilled Aging
EXEC dbo.usp_RefreshInH_UnbilledAging;

-- 11: CPT Breakdown
EXEC dbo.usp_RefreshInH_CPTBreakdown;


-- READ SPs (For ProductionSummaryReport — use with or without filters)
-- ============================================================

-- Monthly Billed Production Summary
-- Fast path (no filters):
EXEC dbo.usp_GetInH_MonthlyBilledProductionSummary;

-- Live path (with filters):
EXEC dbo.usp_GetInH_MonthlyBilledProductionSummary
	@PayerNames='Payer1|Payer2',
	@PanelNames='Panel1|Panel2',
	@FirstBilledFrom='2024-01-01',
	@FirstBilledTo='2024-12-31';


-- Weekly Billed Production Summary
EXEC dbo.usp_GetInH_WeeklyBilledProductionSummary
	@PayerNames=NULL,
	@PanelNames=NULL,
	@FirstBilledFrom=NULL,
	@FirstBilledTo=NULL;


-- Payer Breakdown (by month)
EXEC dbo.usp_GetInH_PayerBreakdown
	@PayerNames='Payer1|Payer2',
	@FirstBilledFrom='2024-01-01',
	@FirstBilledTo='2024-12-31';


-- Payer by Panel
EXEC dbo.usp_GetInH_PayerByPanel
	@PayerNames=NULL,
	@PanelNames=NULL,
	@FirstBilledFrom=NULL,
	@FirstBilledTo=NULL;


-- Coding Breakdown — Panel Summary
EXEC dbo.usp_GetInH_CodingPanelSummary
	@PanelNames='Panel1',
	@FirstBilledFrom='2024-01-01',
	@FirstBilledTo='2024-12-31';


-- Coding Breakdown — CPT Detail
EXEC dbo.usp_GetInH_CodingCPTDetail
	@PanelNames=NULL,
	@FirstBilledFrom=NULL,
	@FirstBilledTo=NULL;


-- Unbilled Aging
EXEC dbo.usp_GetInH_UnbilledAging
	@PanelNames='Panel1|Panel2',
	@DaysAged=NULL;


-- CPT Breakdown
EXEC dbo.usp_GetInH_CPTBreakdown
	@CPTCodes='99213|99214|99215',
	@FirstBilledFrom='2024-01-01',
	@FirstBilledTo='2024-12-31';


-- ============================================================
-- TABLES CREATED
-- ============================================================

-- dbo.InH_MonthlyBilledProductionSummary          (06)
-- dbo.InH_WeeklyBilledProductionSummary           (07)
-- dbo.InH_PayerBreakdown                          (08)
-- dbo.InH_PayerByPanel                            (08)
-- dbo.InH_CodingPanelSummary                      (09)
-- dbo.InH_CodingCPTDetail                         (09)
-- dbo.InH_UnbilledAging                           (10)
-- dbo.InH_CPTBreakdown                            (11)


-- ============================================================
-- FILTER PARAMETER NOTES
-- ============================================================

-- Parameters use '|' as delimiter for multiple values:
--   @PayerNames='Payer1|Payer2|Payer3'
--   @PanelNames='Panel1|Panel2'
--   @CPTCodes='99213|99214'

-- NULL or empty parameters are ignored (no filter applied)

-- If ANY filter is supplied, SP aggregates live from tables
-- If NO filters supplied, SP returns cached snapshot (fast)


-- ============================================================
-- FILES DEPLOYED
-- ============================================================

-- 08_InHealthDTR_PayerBreakdown.sql
--    → InH_PayerBreakdown, InH_PayerByPanel
--    → usp_RefreshInH_PayerBreakdown, usp_RefreshInH_PayerByPanel

-- 09_InHealthDTR_CodingBreakdown.sql
--    → InH_CodingPanelSummary, InH_CodingCPTDetail
--    → usp_RefreshInH_CodingBreakdown_Billed

-- 10_InHealthDTR_UnbilledAging.sql
--    → InH_UnbilledAging
--    → usp_RefreshInH_UnbilledAging

-- 11_InHealthDTR_CPTBreakdown.sql
--    → InH_CPTBreakdown
--    → usp_RefreshInH_CPTBreakdown

-- 14_InHealthDTR_ReadSPs.sql
--    → 8 Read-only SPs for ProductionSummaryReport

PRINT 'InHealthDTR ProductionSummaryReport Quick Reference loaded.';

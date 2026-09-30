/* =============================================================================
   VariantX_LRN — Execute ALL aggregate refresh SPs + verify read SPs exist
   File : 99_VariantX_ExecuteAllAggregates.sql
   DB   : VariantX_LRN

   WHY Executive Summary fails with:
     "The stored procedure 'dbo.usp_GetVarX_ExecutiveSummary' does not exist."
   → You must CREATE that SP first by running (in order):
        15_VariantX_ExecutiveSummary_Tables.sql
        16_VariantX_ExecutiveSummary_Aggregate.sql   -- creates usp_RefreshVarX_ExecutiveSummary
        17_VariantX_ExecutiveSummary_Read.sql        -- creates usp_GetVarX_ExecutiveSummary  << REQUIRED
        19_VariantX_ExecutiveSummary_LIS_Alt.sql
        18 / 20 / 21 / 22 (detail + filter options) if not already applied

   Empty Collection / Production tabs mean aggregate tables were never populated.
   This script EXECUTES every refresh SP (skips safely if an SP is missing).

   Run against: VariantX_LRN
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

PRINT '=== VariantX aggregate refresh starting @ ' + CONVERT(VARCHAR(30), GETDATE(), 120) + ' ===';
GO

/* =============================================================================
   1) PRODUCTION SUMMARY aggregates
   ============================================================================= */
PRINT '';
PRINT '--- Production Summary ---';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_MonthlyBilledProductionSummary', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_MonthlyBilledProductionSummary; PRINT 'OK: usp_RefreshVarX_MonthlyBilledProductionSummary'; END TRY BEGIN CATCH PRINT 'FAIL: MonthlyBilled → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_MonthlyBilledProductionSummary — run 06_VariantX_MonthlyBilledProductionSummary.sql';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_WeeklyBilledProductionSummary', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_WeeklyBilledProductionSummary; PRINT 'OK: usp_RefreshVarX_WeeklyBilledProductionSummary'; END TRY BEGIN CATCH PRINT 'FAIL: WeeklyBilled → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_WeeklyBilledProductionSummary — run 07_VariantX_WeeklyBilledProductionSummary.sql';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_PayerBreakdown', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_PayerBreakdown; PRINT 'OK: usp_RefreshVarX_PayerBreakdown'; END TRY BEGIN CATCH PRINT 'FAIL: PayerBreakdown → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_PayerBreakdown — run 08_VariantX_PayerBreakdown.sql';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_PayerByPanel', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_PayerByPanel; PRINT 'OK: usp_RefreshVarX_PayerByPanel'; END TRY BEGIN CATCH PRINT 'FAIL: PayerByPanel → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_PayerByPanel — run 08_VariantX_PayerBreakdown.sql';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_UnbilledAging', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_UnbilledAging; PRINT 'OK: usp_RefreshVarX_UnbilledAging'; END TRY BEGIN CATCH PRINT 'FAIL: UnbilledAging → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_UnbilledAging — run 09_VariantX_UnbilledAging.sql';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CPTBreakdown', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CPTBreakdown; PRINT 'OK: usp_RefreshVarX_CPTBreakdown'; END TRY BEGIN CATCH PRINT 'FAIL: CPTBreakdown → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CPTBreakdown — run 10_VariantX_CPTBreakdown.sql';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CodingBreakdown_Unbilled', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CodingBreakdown_Unbilled; PRINT 'OK: usp_RefreshVarX_CodingBreakdown_Unbilled'; END TRY BEGIN CATCH PRINT 'FAIL: CodingBreakdown → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CodingBreakdown_Unbilled — run 11_VariantX_CodingBreakdown.sql';

/* =============================================================================
   2) COLLECTION SUMMARY aggregates
   ============================================================================= */
PRINT '';
PRINT '--- Collection Summary ---';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_Top5ReimbursementPct', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_Top5ReimbursementPct; PRINT 'OK: usp_RefreshVarX_CS_Top5ReimbursementPct'; END TRY BEGIN CATCH PRINT 'FAIL: Top5Pct → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_Top5ReimbursementPct — run 12_VariantX_CollectionSummary.sql';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_Top5ReimbursementPay', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_Top5ReimbursementPay; PRINT 'OK: usp_RefreshVarX_CS_Top5ReimbursementPay'; END TRY BEGIN CATCH PRINT 'FAIL: Top5Pay → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_Top5ReimbursementPay';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_MonthlyClaimVolume', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_MonthlyClaimVolume; PRINT 'OK: usp_RefreshVarX_CS_MonthlyClaimVolume'; END TRY BEGIN CATCH PRINT 'FAIL: MonthlyClaimVolume → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_MonthlyClaimVolume';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_WeeklyClaimVolume', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_WeeklyClaimVolume; PRINT 'OK: usp_RefreshVarX_CS_WeeklyClaimVolume'; END TRY BEGIN CATCH PRINT 'FAIL: WeeklyClaimVolume → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_WeeklyClaimVolume';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_PanelAverages', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_PanelAverages; PRINT 'OK: usp_RefreshVarX_CS_PanelAverages'; END TRY BEGIN CATCH PRINT 'FAIL: PanelAverages → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_PanelAverages — run 12b fix if needed';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_AvgPayments', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_AvgPayments; PRINT 'OK: usp_RefreshVarX_CS_AvgPayments'; END TRY BEGIN CATCH PRINT 'FAIL: AvgPayments → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_AvgPayments';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_InsuranceVsAging', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_InsuranceVsAging; PRINT 'OK: usp_RefreshVarX_CS_InsuranceVsAging'; END TRY BEGIN CATCH PRINT 'FAIL: InsuranceVsAging → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_InsuranceVsAging';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_PanelVsPayment', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_PanelVsPayment; PRINT 'OK: usp_RefreshVarX_CS_PanelVsPayment'; END TRY BEGIN CATCH PRINT 'FAIL: PanelVsPayment → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_PanelVsPayment';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_RepVsPayment', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_RepVsPayment; PRINT 'OK: usp_RefreshVarX_CS_RepVsPayment'; END TRY BEGIN CATCH PRINT 'FAIL: RepVsPayment → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_RepVsPayment';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_InsuranceVsPaymentPct', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_InsuranceVsPaymentPct; PRINT 'OK: usp_RefreshVarX_CS_InsuranceVsPaymentPct'; END TRY BEGIN CATCH PRINT 'FAIL: InsuranceVsPaymentPct → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_InsuranceVsPaymentPct';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_InsuranceVsPayment', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_InsuranceVsPayment; PRINT 'OK: usp_RefreshVarX_CS_InsuranceVsPayment'; END TRY BEGIN CATCH PRINT 'FAIL: InsuranceVsPayment → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_InsuranceVsPayment';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_CptVsPaymentPct', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_CptVsPaymentPct; PRINT 'OK: usp_RefreshVarX_CS_CptVsPaymentPct'; END TRY BEGIN CATCH PRINT 'FAIL: CptVsPaymentPct → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_CptVsPaymentPct';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_StatusSummary', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_StatusSummary; PRINT 'OK: usp_RefreshVarX_CS_StatusSummary'; END TRY BEGIN CATCH PRINT 'FAIL: StatusSummary → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_StatusSummary';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_CS_ProviderSummary', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_CS_ProviderSummary; PRINT 'OK: usp_RefreshVarX_CS_ProviderSummary'; END TRY BEGIN CATCH PRINT 'FAIL: ProviderSummary → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_CS_ProviderSummary';

/* =============================================================================
   3) EXECUTIVE SUMMARY aggregates
   ============================================================================= */
PRINT '';
PRINT '--- Executive Summary ---';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_ExecutiveSummary', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_ExecutiveSummary; PRINT 'OK: usp_RefreshVarX_ExecutiveSummary'; END TRY BEGIN CATCH PRINT 'FAIL: Refresh ExecutiveSummary → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_ExecutiveSummary — run 16_VariantX_ExecutiveSummary_Aggregate.sql';

IF OBJECT_ID(N'dbo.usp_RefreshVarX_ExecutiveSummary_LIS_Alt', 'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshVarX_ExecutiveSummary_LIS_Alt; PRINT 'OK: usp_RefreshVarX_ExecutiveSummary_LIS_Alt'; END TRY BEGIN CATCH PRINT 'FAIL: LIS_Alt → ' + ERROR_MESSAGE(); END CATCH
ELSE PRINT 'SKIP (missing): usp_RefreshVarX_ExecutiveSummary_LIS_Alt — run 19_VariantX_ExecutiveSummary_LIS_Alt.sql';

/* =============================================================================
   4) VERIFY read SPs the UI calls
   ============================================================================= */
PRINT '';
PRINT '--- Verify UI read SPs ---';

SELECT ProcName,
       CASE WHEN OBJECT_ID(N'dbo.' + ProcName, N'P') IS NOT NULL THEN 'EXISTS' ELSE 'MISSING — deploy CREATE script' END AS Status
FROM (VALUES
    (N'usp_GetVarX_ExecutiveSummary'),
    (N'usp_GetVarX_ExecutiveSummary_FilterOptions'),
    (N'usp_GetVarX_ExecutiveSummary_Detail'),
    (N'usp_GetExecutiveSummaryDetail_PMSCash'),
    (N'usp_GetExecutiveSummaryDetail_LIS'),
    (N'usp_GetVarX_MonthlyBilledProductionSummary'),
    (N'usp_GetVarX_WeeklyBilledProductionSummary'),
    (N'usp_GetVarX_CS_AvgPayments'),
    (N'usp_GetVarX_CS_PanelAverages'),
    (N'usp_GetVarX_CS_Top5ReimbursementPct')
) v(ProcName);

IF OBJECT_ID(N'dbo.usp_GetVarX_ExecutiveSummary', 'P') IS NULL
BEGIN
    PRINT '';
    PRINT '*** FIX Executive Summary UI error: run 17_VariantX_ExecutiveSummary_Read.sql on VariantX_LRN ***';
END
ELSE
    PRINT 'usp_GetVarX_ExecutiveSummary is present.';

/* =============================================================================
   5) Row counts for aggregate tables
   ============================================================================= */
PRINT '';
PRINT '--- Aggregate table row counts ---';

SELECT t.name AS TableName, SUM(p.rows) AS ApproxRows
FROM sys.tables t
INNER JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name LIKE 'VarX[_]%'
GROUP BY t.name
ORDER BY t.name;

PRINT '';
PRINT '=== VariantX aggregate refresh finished @ ' + CONVERT(VARCHAR(30), GETDATE(), 120) + ' ===';
GO

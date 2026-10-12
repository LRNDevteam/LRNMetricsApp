/* =============================================================================
   WellHealth - run every Production Summary refresh SP and verify the read SPs
   Database : WellHealth

   Deploy order (each script is re-runnable):
     05  ProductionBase (views + filter functions)
     06  MonthlyBilledProductionSummary      07  WeeklyBilledProductionSummary
     08  PayerBreakdown + PayerByPanel       09  UnbilledAging
     10  CPTBreakdown                        11  CodingBreakdown
     40  PanelBreakdownWithPayers
     12  CollectionSummary (SP-only, WH_CS2_* snapshots)
     25  LIS Summary aggregate tables (WH_LIS_*, filled by the dashboard's LIS refresh)
     26  LIS Summary (SP-built rows / totals)
     30  Denial Summary (WH_Denial* snapshots)
     36  Executive Summary (WH_ES_* ; DOS year <= 2026)
     99  this script
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

PRINT '=== WellHealth aggregate refresh starting @ ' + CONVERT(VARCHAR(30), GETDATE(), 120) + ' ===';

DECLARE @Procs TABLE (Seq INT IDENTITY(1,1), ProcName SYSNAME);
INSERT INTO @Procs (ProcName) VALUES
    (N'usp_RefreshWH_MonthlyBilledProductionSummary'),
    (N'usp_RefreshWH_WeeklyBilledProductionSummary'),
    (N'usp_RefreshWH_PayerBreakdown'),
    (N'usp_RefreshWH_PayerByPanel'),
    (N'usp_RefreshWH_PanelBreakdownWithPayers'),
    (N'usp_RefreshWH_UnbilledAging'),
    (N'usp_RefreshWH_CPTBreakdown'),
    (N'usp_RefreshWH_CodingBreakdown_Unbilled'),
    -- Collection Summary (12)
    (N'usp_RefreshWH_CS_Top5ReimbursementPct'),
    (N'usp_RefreshWH_CS_Top5ReimbursementPay'),
    (N'usp_RefreshWH_CS_MonthlyClaimVolume'),
    (N'usp_RefreshWH_CS_WeeklyClaimVolume'),
    (N'usp_RefreshWH_CS_PanelAverages'),
    (N'usp_RefreshWH_CS_InsuranceVsAging'),
    (N'usp_RefreshWH_CS_PanelVsPayment'),
    (N'usp_RefreshWH_CS_RepVsPayment'),
    (N'usp_RefreshWH_CS_InsuranceVsPaymentPct'),
    (N'usp_RefreshWH_CS_InsuranceVsPayment'),
    (N'usp_RefreshWH_CS_CptVsPaymentPct'),
    (N'usp_RefreshWH_CS_StatusSummary'),
    (N'usp_RefreshWH_CS_ProviderSummary'),
    -- LIS Summary (26)
    (N'usp_RefreshWH_LISSummary'),
    -- Denial Summary (30); DenialMonthly also refreshes the tiles
    (N'usp_RefreshWH_DenialMonthly'),
    (N'usp_RefreshWH_DenialWeekly'),
    (N'usp_RefreshWH_DenialList'),
    (N'usp_RefreshWH_DenialPlanType'),
    -- Executive Summary (36)
    (N'usp_RefreshWH_ExecutiveSummary');

DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @Procs), @p SYSNAME, @sql NVARCHAR(400);
WHILE @i <= @n
BEGIN
    SELECT @p = ProcName FROM @Procs WHERE Seq = @i;
    IF OBJECT_ID(N'dbo.' + @p, N'P') IS NULL
        PRINT 'SKIP (missing): ' + @p;
    ELSE
    BEGIN TRY
        SET @sql = N'EXEC dbo.' + QUOTENAME(@p) + N';';
        EXEC sp_executesql @sql;
        PRINT 'OK:   ' + @p;
    END TRY
    BEGIN CATCH
        PRINT 'FAIL: ' + @p + ' -> ' + ERROR_MESSAGE();
    END CATCH;
    SET @i += 1;
END;
GO

PRINT '';
PRINT '--- UI read SPs ---';
SELECT v.ProcName,
       CASE WHEN OBJECT_ID(N'dbo.' + v.ProcName, N'P') IS NOT NULL THEN 'EXISTS' ELSE 'MISSING' END AS Status
FROM (VALUES
    (N'usp_GetWH_MonthlyBilledProductionSummary'),
    (N'usp_GetWH_WeeklyBilledProductionSummary'),
    (N'usp_GetWH_PayerBreakdown'),
    (N'usp_GetWH_PayerByPanel'),
    (N'usp_GetWH_PanelBreakdownWithPayers'),
    (N'usp_GetWH_UnbilledAging'),
    (N'usp_GetWH_CPTBreakdown'),
    (N'usp_GetWH_CPTBreakdownTotals'),
    (N'usp_GetWH_CodingBreakdown'),
    (N'usp_GetWH_CS_MonthlyClaimVolume'),
    (N'usp_GetWH_CS_AvgPayments_ClientLogic'),
    (N'usp_GetWH_LISSummary'),
    (N'usp_GetWH_DenialMonthly'),
    (N'usp_GetWH_DenialWeekly'),
    (N'usp_GetWH_DenialSummaryTiles'),
    (N'usp_GetWH_DenialList'),
    (N'usp_GetWH_DenialPlanType'),
    (N'usp_GetWH_DenialFilterOptions'),
    (N'usp_GetWH_ExecutiveSummary'),
    (N'usp_GetWH_ExecutiveSummary_FilterOptions')
) v(ProcName);

SELECT t.name AS TableName, SUM(p.rows) AS ApproxRows
FROM   sys.tables t
JOIN   sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE  t.name LIKE 'WH[_]%'
GROUP  BY t.name
ORDER  BY t.name;

PRINT '=== WellHealth aggregate refresh finished @ ' + CONVERT(VARCHAR(30), GETDATE(), 120) + ' ===';
GO

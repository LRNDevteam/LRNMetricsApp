/* =============================================================================
   Analyze Pathology - run every aggregate refresh SP and verify the read SPs
   Database : AnalyzePathology

   Deploy order (each script is re-runnable):
     05  ProductionBase (views + filter functions)
     06  MonthlyBilledProductionSummary      07  WeeklyBilledProductionSummary
     08  PayerBreakdown + PayerByPanel       09  UnbilledAging
     10  CPTBreakdown                        11  CodingBreakdown
     40  PanelBreakdownWithPayers
     12, 12b, 14b, 23                        Collection Summary
     15, 16, 17b, 18, 19, 20, 21b, 22, 22b   Executive Summary
     24  MappingFixes
     26  LIS Summary (SP-built rows / totals)
     27  Executive Summary client logic (replaces 16 / 17b / 19 procedures)
     99  this script

   Scripts 12-24 are generated from Sql/VariantX by Generate-FromVariantX.ps1.
   Scripts 20 and 21b replace the database's generic
   usp_GetExecutiveSummaryDetail_LIS / usp_GetExecutiveSummaryDetail_PMSCash.
   ============================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

PRINT '=== Analyze Pathology aggregate refresh starting @ ' + CONVERT(VARCHAR(30), GETDATE(), 120) + ' ===';

DECLARE @Procs TABLE (Seq INT IDENTITY(1,1), ProcName SYSNAME);
INSERT INTO @Procs (ProcName) VALUES
    -- Production Summary
    (N'usp_RefreshAnP_MonthlyBilledProductionSummary'),
    (N'usp_RefreshAnP_WeeklyBilledProductionSummary'),
    (N'usp_RefreshAnP_PayerBreakdown'),
    (N'usp_RefreshAnP_PayerByPanel'),
    (N'usp_RefreshAnP_PanelBreakdownWithPayers'),
    (N'usp_RefreshAnP_UnbilledAging'),
    (N'usp_RefreshAnP_CPTBreakdown'),
    (N'usp_RefreshAnP_CodingBreakdown_Unbilled'),
    -- Collection Summary
    (N'usp_RefreshAnP_CS_Top5ReimbursementPct'),
    (N'usp_RefreshAnP_CS_Top5ReimbursementPay'),
    (N'usp_RefreshAnP_CS_MonthlyClaimVolume'),
    (N'usp_RefreshAnP_CS_WeeklyClaimVolume'),
    (N'usp_RefreshAnP_CS_PanelAverages'),
    (N'usp_RefreshAnP_CS_AvgPayments'),
    (N'usp_RefreshAnP_CS_InsuranceVsAging'),
    (N'usp_RefreshAnP_CS_PanelVsPayment'),
    (N'usp_RefreshAnP_CS_RepVsPayment'),
    (N'usp_RefreshAnP_CS_InsuranceVsPaymentPct'),
    (N'usp_RefreshAnP_CS_InsuranceVsPayment'),
    (N'usp_RefreshAnP_CS_CptVsPaymentPct'),
    (N'usp_RefreshAnP_CS_StatusSummary'),
    (N'usp_RefreshAnP_CS_ProviderSummary'),
    -- Executive Summary (27 rebuilds LIS + PMS + Cash + Avg in one pass)
    (N'usp_RefreshAnP_ExecutiveSummary'),
    (N'usp_RefreshAnP_ExecutiveSummary_LIS_Alt'),
    -- LIS Summary (26)
    (N'usp_RefreshAnP_LISSummary');

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
    (N'usp_GetAnP_MonthlyBilledProductionSummary'),
    (N'usp_GetAnP_WeeklyBilledProductionSummary'),
    (N'usp_GetAnP_PayerBreakdown'),
    (N'usp_GetAnP_PayerByPanel'),
    (N'usp_GetAnP_PanelBreakdownWithPayers'),
    (N'usp_GetAnP_UnbilledAging'),
    (N'usp_GetAnP_CPTBreakdown'),
    (N'usp_GetAnP_CodingBreakdown'),
    (N'usp_GetAnP_CS_AvgPayments'),
    (N'usp_GetAnP_CS_PanelAverages'),
    (N'usp_GetAnP_CS_Top5ReimbursementPct'),
    (N'usp_GetAnP_ExecutiveSummary'),
    (N'usp_GetAnP_LISSummary'),
    (N'usp_GetAnP_ExecutiveSummary_FilterOptions'),
    (N'usp_GetAnP_ExecutiveSummary_Detail'),
    (N'usp_GetExecutiveSummaryDetail_PMSCash'),
    (N'usp_GetExecutiveSummaryDetail_LIS')
) v(ProcName);

SELECT t.name AS TableName, SUM(p.rows) AS ApproxRows
FROM   sys.tables t
JOIN   sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE  t.name LIKE 'AnP[_]%'
GROUP  BY t.name
ORDER  BY t.name;

PRINT '=== Analyze Pathology aggregate refresh finished @ ' + CONVERT(VARCHAR(30), GETDATE(), 120) + ' ===';
GO

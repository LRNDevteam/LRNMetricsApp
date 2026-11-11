/* =============================================================================
   NorthWest - Production Summary - CPT Breakdown refresh fails on NULL month
   File     : 53_NW_CPTBreakdown_NullChargeEnteredDate.sql
   Database : NWL_LRN

   Issue : usp_RefreshNW_CPTBreakdown filtered billed lines on FirstBilledDate but
           took BilledYearMonth from ChargeEnteredDate. Run R20261106NWL5344
           (10.29.2026 - 11.04.2026) loaded every Webpm line (1,102,723) with a
           blank ChargeEnteredDate, so 737,653 billed lines grouped into a NULL
           month and the insert failed:
             Msg 515 - Cannot insert the value NULL into column 'BilledYearMonth',
             table 'NWL_LRN.dbo.NW_CPTBreakdown'.
           The TRUNCATE had already run, leaving NW_CPTBreakdown empty.
   Fix   : Skip lines without a ChargeEnteredDate, the same rule as
           fn_NW_BilledClaims and usp_GetNW_CPTBreakdownBySource. TRUNCATE and
           INSERT run in one transaction so a failure keeps the previous snapshot.
           The completion message reports the inserted row count (it was read
           after DROP TABLE, which always reset it to 0).
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'53_NW_CPTBreakdown_NullChargeEnteredDate.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Rows INT;

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                        AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
        COUNT(*)                                                         AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0)         AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #Raw
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND FirstBilledDate <> ''
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    BEGIN TRANSACTION;

    TRUNCATE TABLE dbo.NW_CPTBreakdown;

    INSERT INTO dbo.NW_CPTBreakdown
        (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw ORDER BY CPTCode, BilledYearMonth;

    SET @Rows = @@ROWCOUNT;

    COMMIT TRANSACTION;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_CPTBreakdown completed — ' + CAST(@Rows AS NVARCHAR(20)) + ' rows.';
END;
GO

EXEC dbo.usp_RefreshNW_CPTBreakdown;
GO

SET NOEXEC OFF;
GO

PRINT '53_NW_CPTBreakdown_NullChargeEnteredDate.sql completed.';
GO

/* =============================================================================
   VariantX Labs — cloned from Elixir (09_Elixir_UnbilledAging.sql)
   Prefix: VarX_ / VarX_CS_ / VarX_ES_
   Refresh: usp_RefreshVarX_*
   Read:    usp_GetVarX_*
   Source tables: dbo.ClaimLevelData, dbo.LineLevelData, dbo.LIMSMaster
   No inline UI queries — dashboard/ReportWorker must call these SPs only.
   ============================================================================= */
-- VariantX Labs � Unbilled � Aging (by AgingDOS)
-- Rule:
--   Filter  : FirstBilledDate IS NULL or blank  (truly unbilled claims)
--             and PayerName_Raw is not blank
--   Row     : PayerName_Raw
--   Columns : AgingDOS bucket | COUNT(DISTINCT visit no) | SUM(ChargeAmount)
--   Note    : VariantX uses AgingDOS (age from date of service).
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VarX_UnbilledAging')
CREATE TABLE dbo.VarX_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500)   NOT NULL,   -- application contract; stores PayerName_Raw
    AgingBucket  NVARCHAR(100)   NOT NULL,   -- sourced from AgingDOS column
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                                       AS PanelName,
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown')                                        AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        ))                                                                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown');

    TRUNCATE TABLE dbo.VarX_UnbilledAging;

    INSERT INTO dbo.VarX_UnbilledAging (PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY Panelname, AgingBucket;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshVarX_UnbilledAging completed � ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PanelName, AgingBucket, ClaimCount, TotalCharges
FROM dbo.VarX_UnbilledAging ORDER BY PanelName, AgingBucket;
*/

PRINT '09_VariantX_UnbilledAging.sql completed.';


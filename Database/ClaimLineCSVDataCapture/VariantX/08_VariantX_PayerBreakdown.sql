/* =============================================================================
   VariantX Labs — cloned from Elixir (08_Elixir_PayerBreakdown.sql)
   Prefix: VarX_ / VarX_CS_ / VarX_ES_
   Refresh: usp_RefreshVarX_*
   Read:    usp_GetVarX_*
   Source tables: dbo.ClaimLevelData, dbo.LineLevelData, dbo.LIMSMaster
   No inline UI queries — dashboard/ReportWorker must call these SPs only.
   ============================================================================= */
-- VariantX Labs � Payer Breakdown  +  Payer � Panel
--
-- Filter (both SPs):
--   TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--
-- Table 1 � VarX_PayerBreakdown  (Payer � FirstBilledDate Month)
--   Row: PayerName_Raw
--   Col: FirstBilledDate yyyy-MM | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   ? feeds Payer Breakdown tab
--
-- Table 2 � VarX_PayerByPanel  (Payer � Panelname)
--   Row: PayerName_Raw
--   Col: Panelname | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   ? feeds Payer X Panel tab
--   UI query: SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
--             FROM dbo.VarX_PayerByPanel ORDER BY PayerName, PanelName
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1a: VarX_PayerBreakdown  (Payer � Month)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VarX_PayerBreakdown')
CREATE TABLE dbo.VarX_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from FirstBilledDate
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 1b: VarX_PayerByPanel  (Payer � Panelname)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VarX_PayerByPanel')
CREATE TABLE dbo.VarX_PayerByPanel
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    PanelType    NVARCHAR(MAX)   NOT NULL,   -- stores Panelname; aliased PanelName when queried
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2a: Stored procedure � Payer � Month
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName_Raw,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')        AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)     AS TotalCharges
    INTO #RawPM
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.VarX_PayerBreakdown;

    INSERT INTO dbo.VarX_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPM
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #RawPM;

    PRINT 'usp_RefreshVarX_PayerBreakdown completed � ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Step 2b: Stored procedure � Payer � Panelname
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                                              AS PayerName_Raw,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))                 AS Panelname,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                                     AS TotalCharges
    INTO #RawPP
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')));

    TRUNCATE TABLE dbo.VarX_PayerByPanel;

    INSERT INTO dbo.VarX_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, Panelname, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP
    ORDER BY PayerName_Raw, Panelname;

    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshVarX_PayerByPanel completed � ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.VarX_PayerBreakdown ORDER BY PayerName, BilledYearMonth;

SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
FROM dbo.VarX_PayerByPanel ORDER BY PayerName, PanelType;
*/

PRINT '08_VariantX_PayerBreakdown.sql completed.';


-- COVE Labs — Payer Breakdown  +  Payer × Panel
--
-- Filter (both SPs):
--   TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   No PayerName_Raw NULL/blank exclusion — blank payer ? 'Unknown'.
--
-- Table 1 – Cove_PayerBreakdown  (Payer × FirstBilledDate Month)
--   Row: PayerName_Raw
--   Col: FirstBilledDate yyyy-MM | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   ? feeds Payer Breakdown tab
--
-- Table 2 – Cove_PayerByPanel  (Payer × Panelname)
--   Row: PayerName_Raw
--   Col: Panelname | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   ? feeds Payer X Panel tab
--   UI query: SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
--             FROM dbo.Cove_PayerByPanel ORDER BY PayerName, PanelName
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1a: Cove_PayerBreakdown  (Payer × Month)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Cove_PayerBreakdown')
CREATE TABLE dbo.Cove_PayerBreakdown
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
-- Step 1b: Cove_PayerByPanel  (Payer × Panelname)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Cove_PayerByPanel')
CREATE TABLE dbo.Cove_PayerByPanel
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
-- Step 2a: Stored procedure — Payer × Month
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    -- Column pivot on FirstBilledDate month/year.
    -- No PayerName_Raw null check — blank/null payer ? 'Unknown'.
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

    TRUNCATE TABLE dbo.Cove_PayerBreakdown;

    INSERT INTO dbo.Cove_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPM
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #RawPM;

    PRINT 'usp_RefreshCove_PayerBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Step 2b: Stored procedure — Payer × Panelname
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_PayerByPanel
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

    TRUNCATE TABLE dbo.Cove_PayerByPanel;

    INSERT INTO dbo.Cove_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, Panelname, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP
    ORDER BY PayerName_Raw, Panelname;

    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshCove_PayerByPanel completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
-- Payer × Month
SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.Cove_PayerBreakdown ORDER BY PayerName, BilledYearMonth;

-- Payer × Panel  (UI format: PanelType aliased as PanelName)
SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
FROM dbo.Cove_PayerByPanel ORDER BY PayerName, PanelType;
*/

PRINT '08_Cove_PayerBreakdown.sql completed.';

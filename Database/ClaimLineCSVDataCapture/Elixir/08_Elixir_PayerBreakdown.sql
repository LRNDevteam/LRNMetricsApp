-- Elixir Labs — Payer Breakdown  +  Payer × Panel
--
-- Filter (both SPs):
--   TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--
-- Table 1 – Elix_PayerBreakdown  (Payer × FirstBilledDate Month)
--   Row: PayerName_Raw
--   Col: FirstBilledDate yyyy-MM | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   ? feeds Payer Breakdown tab
--
-- Table 2 – Elix_PayerByPanel  (Payer × Panelname)
--   Row: PayerName_Raw
--   Col: Panelname | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   ? feeds Payer X Panel tab
--   UI query: SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
--             FROM dbo.Elix_PayerByPanel ORDER BY PayerName, PanelName
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1a: Elix_PayerBreakdown  (Payer × Month)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Elix_PayerBreakdown')
CREATE TABLE dbo.Elix_PayerBreakdown
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
-- Step 1b: Elix_PayerByPanel  (Payer × Panelname)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Elix_PayerByPanel')
CREATE TABLE dbo.Elix_PayerByPanel
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
CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_PayerBreakdown
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

    TRUNCATE TABLE dbo.Elix_PayerBreakdown;

    INSERT INTO dbo.Elix_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPM
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #RawPM;

    PRINT 'usp_RefreshElix_PayerBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Step 2b: Stored procedure — Payer × Panelname
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_PayerByPanel
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

    TRUNCATE TABLE dbo.Elix_PayerByPanel;

    INSERT INTO dbo.Elix_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, Panelname, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP
    ORDER BY PayerName_Raw, Panelname;

    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshElix_PayerByPanel completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.Elix_PayerBreakdown ORDER BY PayerName, BilledYearMonth;

SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
FROM dbo.Elix_PayerByPanel ORDER BY PayerName, PanelType;
*/

PRINT '08_Elixir_PayerBreakdown.sql completed.';

-- ============================================================
-- Augustus Labs — Payer Breakdown  +  Payer × Panel
--
-- Filter (both SPs):
--   TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
--   No PayerName_Raw NULL exclusion — blank/null payer ? 'Unknown'.
--
-- Table 1 – Aug_PayerBreakdown   (Payer × ChargeEnteredDate Month)
--   Row: PayerName_Raw
--   Col: yyyy-MM | ClaimCount | TotalCharges
--   ? feeds Payer Breakdown tab
--
-- Table 2 – Aug_PayerByPanel     (Payer × PanelNew)
--   Row: PayerName_Raw
--   Col: PanelNew (stored as PanelType, aliased PanelName in queries) | ClaimCount | TotalCharges
--   ? feeds Payer X Panel tab
--   UI query: SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
--             FROM dbo.Aug_PayerByPanel ORDER BY PayerName, PanelName
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1a: Aug_PayerBreakdown  (Payer × Month)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Aug_PayerBreakdown')
CREATE TABLE dbo.Aug_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from ChargeEnteredDate
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 1b: Aug_PayerByPanel  (Payer × PanelNew)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Aug_PayerByPanel')
CREATE TABLE dbo.Aug_PayerByPanel
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    PanelType    NVARCHAR(MAX)   NOT NULL,   -- stores PanelNew; aliased PanelName when queried
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2a: Stored procedure — Payer × Month
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))          AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        COUNT(*)                                                 AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
    INTO #RawPM
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate   AS DATE) IS NOT NULL
     -- AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.Aug_PayerBreakdown;

    INSERT INTO dbo.Aug_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPM
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #RawPM;

    PRINT 'usp_RefreshAug_PayerBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Step 2b: Stored procedure — Payer × PanelNew
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))          AS PayerName_Raw,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)'))) AS PanelNew,
        COUNT(DISTINCT
            COALESCE(
                NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                NULLIF(LTRIM(RTRIM(ClaimID)), '')
            ))                                                   AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
    INTO #RawPP
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate   AS DATE) IS NOT NULL
     -- AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
       LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)')));

    TRUNCATE TABLE dbo.Aug_PayerByPanel;

    INSERT INTO dbo.Aug_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, PanelNew, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP
    ORDER BY PayerName_Raw, PanelNew;

    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshAug_PayerByPanel completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Quick verification queries
-- ============================================================
/*
-- Payer × Month
SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.Aug_PayerBreakdown ORDER BY PayerName, BilledYearMonth;

-- Payer × Panel  (UI format: PanelType aliased as PanelName)
SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
FROM dbo.Aug_PayerByPanel ORDER BY PayerName, PanelType;
*/

PRINT '09_Augustus_PayerBreakdown.sql completed.';

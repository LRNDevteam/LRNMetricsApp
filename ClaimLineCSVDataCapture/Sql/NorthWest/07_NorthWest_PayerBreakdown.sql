-- ============================================================
-- ============================================================
-- NorthWest Lab - Payer Breakdown  +  Payer × Panel
--
-- Filter (both SPs):
--   ClaimStatus NOT IN
--     'Unbilled in Daq', 'Unbilled in Daq - PR',
--     'Unbilled in Webpm', 'Unbilled in Webpm - PR',
--     'Billed amount 0'
--
-- Table 1 – NW_PayerBreakdown  (Payer × Month)
--   Row: PayerName
--   Col: ChargeEnteredDate yyyy-MM | ClaimCount | TotalCharges
--   → feeds Payer Breakdown tab
--
-- Table 2 – NW_PayerByPanel  (Payer × PanelType)
--   Row: PayerName
--   Col: PanelType (stored as PanelType, aliased PanelName in queries) | ClaimCount | TotalCharges
--   → feeds Payer X Panel tab
--   UI query: SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
--             FROM dbo.NW_PayerByPanel ORDER BY PayerName, PanelName
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1a: NW_PayerBreakdown table  (Payer × Month)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_PayerBreakdown')
CREATE TABLE dbo.NW_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM'
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 1b: NW_PayerByPanel table  (Payer × PanelType)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_PayerByPanel')
CREATE TABLE dbo.NW_PayerByPanel
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    PanelType       NVARCHAR(MAX)   NOT NULL,   -- aliased AS PanelName when queried
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2a: Stored procedure – Payer × Month
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                      AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
        COUNT(*)                                                         AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #RawPM
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq',
              'Unbilled in Daq - PR',
              'Unbilled in Webpm',
              'Unbilled in Webpm - PR',
              'Billed amount 0'
          )
      AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      --AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.NW_PayerBreakdown;

    INSERT INTO dbo.NW_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPM
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #RawPM;

    PRINT 'usp_RefreshNW_PayerBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows loaded.';
END
GO

-- ============================================================
-- Step 2b: Stored procedure – Payer × PanelType
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;

    -- Use ISNULL(NULLIF(PanelType,''), PanelName) so rows without a PanelType
    -- still fall back to the base PanelName value.
    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                      AS PayerName_Raw,
        LTRIM(RTRIM(
            ISNULL(
                NULLIF(ISNULL(PanelType, ''), ''),
                ISNULL(PanelName, 'Unknown')
            )
        ))                                                               AS PanelType,
        COUNT(DISTINCT
            COALESCE(
                NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                NULLIF(LTRIM(RTRIM(ClaimID)), '')
            )
        )                                                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #RawPP
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq',
              'Unbilled in Daq - PR',
              'Unbilled in Webpm',
              'Unbilled in Webpm - PR',
              'Billed amount 0'
          )
      AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(
            ISNULL(
                NULLIF(ISNULL(PanelType, ''), ''),
                ISNULL(PanelName, 'Unknown')
            )
        ));

    TRUNCATE TABLE dbo.NW_PayerByPanel;

    INSERT INTO dbo.NW_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, PanelType, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP
    ORDER BY PayerName_Raw, PanelType;

    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshNW_PayerByPanel completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows loaded.';
END
GO

-- ============================================================
-- Quick verification queries
-- ============================================================
/*
-- Payer × Month
SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.NW_PayerBreakdown
ORDER BY PayerName, BilledYearMonth;

-- Payer × Panel  (UI format: PanelType aliased as PanelName)
SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
FROM dbo.NW_PayerByPanel
ORDER BY PayerName, PanelType;

-- Grand total per payer across all panels
SELECT PayerName, SUM(ClaimCount) AS TotalClaims, SUM(TotalCharges) AS TotalCharges
FROM dbo.NW_PayerByPanel
GROUP BY PayerName
ORDER BY TotalClaims DESC;
*/

PRINT '07_NorthWest_PayerBreakdown.sql completed.';

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_PayerBreakdown')
CREATE TABLE dbo.NW_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM'
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    -- Collect payer x month production data excluding unbilled/zero-charge statuses
    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                        AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')            AS BilledYearMonth,
        COUNT(*)                                                           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)           AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq',
              'Unbilled in Daq - PR',
              'Unbilled in Webpm',
              'Unbilled in Webpm - PR',
              'Billed amount 0'
          )
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)),  '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    -- Atomic replace of the aggregate table.
    TRUNCATE TABLE dbo.NW_PayerBreakdown;

    INSERT INTO dbo.NW_PayerBreakdown
    (
        PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt
    )
    SELECT
        PayerName_Raw,
        BilledYearMonth,
        ClaimCount,
        TotalCharges,
        GETDATE()
    FROM #Raw
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_PayerBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows loaded.';
END
GO

-- ============================================================
-- Quick verification queries
-- ============================================================
/*
-- Distinct payer-month preview
SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.NW_PayerBreakdown
ORDER BY PayerName, BilledYearMonth;

-- Raw counts (same logic as the proc) for inspection
SELECT
    LTRIM(RTRIM(ISNULL(PayerName, 'Unknown'))) AS PayerName,
    FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
    COUNT(*) AS ClaimCount,
    ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
FROM dbo.ClaimLevelData
WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
          'Unbilled in Daq',
          'Unbilled in Daq - PR',
          'Unbilled in Webpm',
          'Unbilled in Webpm - PR',
          'Billed amount 0'
      )
  AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(PayerName)), '') IS NOT NULL
GROUP BY LTRIM(RTRIM(ISNULL(PayerName,'Unknown'))), FORMAT(TRY_CAST(ChargeEnteredDate AS DATE),'yyyy-MM')
ORDER BY PayerName, BilledYearMonth;
*/

PRINT '07_NorthWest_PayerBreakdown.sql completed.';

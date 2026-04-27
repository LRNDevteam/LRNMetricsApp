-- ============================================================
-- NorthWest Lab - Unbilled vs Aging
-- Rule:
--   Filter  : ClaimStatus IN ('Unbilled in Daq', 'Unbilled in Webpm')
--   Rows    : PayerName
--   Columns : Aging | No of claim count | Sum of charge amount
--
-- Creates aggregate table + stored procedure to populate it.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_UnbilledAging')
CREATE TABLE dbo.NW_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    Aging        NVARCHAR(100)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))        AS PayerName_Raw,
        ISNULL(LTRIM(RTRIM(ISNULL(Aging, 'Unknown'))), 'Unknown') AS Aging,
        COUNT(*)                                           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) IN (
          'Unbilled in Daq',
          'Unbilled in Webpm'
      )
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        ISNULL(LTRIM(RTRIM(ISNULL(Aging, 'Unknown'))), 'Unknown');

    TRUNCATE TABLE dbo.NW_UnbilledAging;

    INSERT INTO dbo.NW_UnbilledAging (PayerName, Aging, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, Aging, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY PayerName_Raw, Aging;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_UnbilledAging completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows loaded.';
END
GO

-- ============================================================
-- Quick verification queries
-- ============================================================
/*
SELECT PayerName, Aging, ClaimCount, TotalCharges
FROM dbo.NW_UnbilledAging
ORDER BY PayerName, Aging;
*/

PRINT '08_NorthWest_UnbilledAging.sql completed.';

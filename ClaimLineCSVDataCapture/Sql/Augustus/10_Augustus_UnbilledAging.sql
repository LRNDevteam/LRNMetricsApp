-- ============================================================
-- Augustus Labs — Unbilled × Aging
-- Rule:
--   Filter  : FirstBilledDate IS NULL or blank  (truly unbilled claims)
--   Row     : PanelNew  (not PayerName like NorthWest)
--   Columns : Aging bucket (from Aging column) | ClaimCount | TotalCharges
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Aug_UnbilledAging')
CREATE TABLE dbo.Aug_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500)   NOT NULL,   -- stores PanelNew value
    Aging        NVARCHAR(100)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
         LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)'))) AS PanelNew,
        ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')                  AS Aging,
        COUNT(DISTINCT
            COALESCE(
                NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                NULLIF(LTRIM(RTRIM(ClaimID)), '')
            ))                                                   AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)  AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
    GROUP BY
         LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)'))) ,
        ISNULL(LTRIM(RTRIM(Aging)), 'Unknown');

    TRUNCATE TABLE dbo.Aug_UnbilledAging;

    INSERT INTO dbo.Aug_UnbilledAging (PanelName, Aging, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelNew, Aging, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY PanelNew, Aging;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshAug_UnbilledAging completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PanelName AS PanelNew, Aging, ClaimCount, TotalCharges
FROM dbo.Aug_UnbilledAging ORDER BY PanelName, Aging;
*/

PRINT '10_Augustus_UnbilledAging.sql completed.';

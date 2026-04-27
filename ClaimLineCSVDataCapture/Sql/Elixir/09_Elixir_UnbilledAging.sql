-- Elixir Labs — Unbilled × Aging (by AgingDOS)
-- Rule:
--   Filter  : FirstBilledDate IS NULL or blank  (truly unbilled claims)
--   Row     : Panelname  (Panel Group)
--   Columns : AgingDOS bucket | COUNT(DISTINCT visit no) | SUM(ChargeAmount)
--   Note    : Elixir uses AgingDOS (age from date of service).
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Elix_UnbilledAging')
CREATE TABLE dbo.Elix_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500)   NOT NULL,   -- stores Panelname value
    AgingBucket  NVARCHAR(100)   NOT NULL,   -- sourced from AgingDOS column
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown')                                        AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        ))                                                                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown');

    TRUNCATE TABLE dbo.Elix_UnbilledAging;

    INSERT INTO dbo.Elix_UnbilledAging (PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY Panelname, AgingBucket;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshElix_UnbilledAging completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PanelName, AgingBucket, ClaimCount, TotalCharges
FROM dbo.Elix_UnbilledAging ORDER BY PanelName, AgingBucket;
*/

PRINT '09_Elixir_UnbilledAging.sql completed.';

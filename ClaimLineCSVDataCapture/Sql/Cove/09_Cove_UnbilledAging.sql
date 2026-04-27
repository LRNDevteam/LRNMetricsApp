-- COVE Labs — Unbilled × Aging (by AgingDOS)
-- Rule:
--   Filter  : FirstBilledDate IS NULL or blank  (truly unbilled claims)
--   Row     : Panelname  (Panel)
--   Columns : AgingDOS bucket | COUNT(DISTINCT ClaimID)
--   Note    : COVE uses AgingDOS (age from date of service) instead of the generic Aging column.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Cove_UnbilledAging')
CREATE TABLE dbo.Cove_UnbilledAging
(
    SummaryId   INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName   NVARCHAR(500)   NOT NULL,   -- stores Panelname value
    AgingDOS    NVARCHAR(100)   NOT NULL,
    ClaimCount  INT             NOT NULL DEFAULT 0,
    RefreshedAt DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown')                                        AS AgingDOS,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                AS ClaimCount
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown');

    TRUNCATE TABLE dbo.Cove_UnbilledAging;

    INSERT INTO dbo.Cove_UnbilledAging (PanelName, AgingDOS, ClaimCount, RefreshedAt)
    SELECT Panelname, AgingDOS, ClaimCount, GETDATE()
    FROM #Raw
    ORDER BY Panelname, AgingDOS;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshCove_UnbilledAging completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PanelName, AgingDOS, ClaimCount
FROM dbo.Cove_UnbilledAging ORDER BY PanelName, AgingDOS;
*/

PRINT '09_Cove_UnbilledAging.sql completed.';

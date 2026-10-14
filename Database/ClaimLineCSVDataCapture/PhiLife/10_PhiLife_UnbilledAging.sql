-- PhiLife — Unbilled — Aging (by AgingBucket column)
-- Rule:
--   Source  : LineLevelData
--   Filter  : FirstBilledDate IS NULL or blank
--   Row     : Panelname (Panel Group)
--   Columns : AgingBucket | COUNT(DISTINCT visit no) | SUM(ChargeAmount)
--
-- Note: PhiLife's LineLevelData carries AgingBucket and BilledUnbilled,
--       so UnbilledAging sources from LineLevelData (not ClaimLevelData).
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_UnbilledAging')
CREATE TABLE dbo.Phi_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500)   NOT NULL,
    AgingBucket  NVARCHAR(200)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown')                                     AS AgingBucket,
        COUNT(COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        ))                                                                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown');

    TRUNCATE TABLE dbo.Phi_UnbilledAging;

    INSERT INTO dbo.Phi_UnbilledAging (PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY Panelname, AgingBucket;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshPhi_UnbilledAging completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '10_PhiLife_UnbilledAging.sql completed.';


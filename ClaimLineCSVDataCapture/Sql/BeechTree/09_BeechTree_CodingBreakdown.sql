-- BeechTree — Coding (Billed) Breakdown
-- Rule:
--   Source  : ClaimLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL  (billed claims only)
--   Row     : Panelname (Panel Group)  +  CPTCodeXUnitsXModifier
--   Metric  : COUNT(DISTINCT visit no), SUM(ChargeAmount)
--
-- Storage:
--   BT_CodingPanelSummary  — one row per Panelname
--   BT_CodingCPTDetail     — one row per Panelname + CPTCodeXUnitsXModifier
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCodeXUnitsXModifier'
)
BEGIN
    ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifier NVARCHAR(MAX) NULL;
    PRINT 'Added CPTCodeXUnitsXModifier to dbo.ClaimLevelData.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'BT_CodingPanelSummary')
CREATE TABLE dbo.BT_CodingPanelSummary
(
    SummaryId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500) NOT NULL,
    ClaimCount   INT           NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'BT_CodingCPTDetail')
CREATE TABLE dbo.BT_CodingCPTDetail
(
    DetailId               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName              NVARCHAR(500)  NOT NULL,
    CPTCodeXUnitsXModifier NVARCHAR(MAX)  NOT NULL,
    ClaimCount             INT            NOT NULL DEFAULT 0,
    TotalCharges           DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt            DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshBT_CodingBreakdown_Billed
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
        LTRIM(RTRIM(ISNULL(CPTCodeXUnitsXModifier, '')))                                 AS CPTDetail,
        COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)),         '')
        )                                                                                AS VisitKey,
        TRY_CAST(ChargeAmount AS DECIMAL(18,2))                                          AS Charge
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL;

    SELECT Panelname, COUNT(DISTINCT VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
    INTO #PanelSummary FROM #Raw GROUP BY Panelname;

    SELECT Panelname, CPTDetail, COUNT(DISTINCT VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
    INTO #CPTDetail FROM #Raw WHERE CPTDetail <> '' GROUP BY Panelname, CPTDetail;

    TRUNCATE TABLE dbo.BT_CodingPanelSummary;
    INSERT INTO dbo.BT_CodingPanelSummary (PanelName, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, ClaimCount, TotalCharges, GETDATE() FROM #PanelSummary ORDER BY TotalCharges DESC;

    TRUNCATE TABLE dbo.BT_CodingCPTDetail;
    INSERT INTO dbo.BT_CodingCPTDetail (PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, CPTDetail, ClaimCount, TotalCharges, GETDATE()
    FROM #CPTDetail ORDER BY Panelname, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
    DROP TABLE IF EXISTS #PanelSummary;
    DROP TABLE IF EXISTS #CPTDetail;

    PRINT 'usp_RefreshBT_CodingBreakdown_Billed completed.';
END
GO

PRINT '09_BeechTree_CodingBreakdown.sql completed.';

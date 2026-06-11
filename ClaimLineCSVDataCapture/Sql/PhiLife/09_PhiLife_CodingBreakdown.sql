-- PhiLife — Coding (Billed) Breakdown
-- Rule:
--   Source  : LineLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL  (billed claims only)
--   Row     : Panelname (Panel Group)  +  CPTCodeXUnitsXModifier
--   Metric  : COUNT(DISTINCT visit no), SUM(ChargeAmount)
--
-- Note: PhiLife's LineLevelData carries the aggregate CPT column
--       CPTCodeXUnitsXModifier, so CodingBreakdown sources from LineLevelData.
--
-- Storage:
--   Phi_CodingPanelSummary  — one row per Panelname
--   Phi_CodingCPTDetail     — one row per Panelname + CPTCodeXUnitsXModifier
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CodingPanelSummary')
CREATE TABLE dbo.Phi_CodingPanelSummary
(
    SummaryId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500) NOT NULL,
    ClaimCount   INT           NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_CodingCPTDetail')
CREATE TABLE dbo.Phi_CodingCPTDetail
(
    DetailId               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName              NVARCHAR(500)  NOT NULL,
    CPTCodeXUnitsXModifier NVARCHAR(MAX)  NOT NULL,
    ClaimCount             INT            NOT NULL DEFAULT 0,
    TotalCharges           DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt            DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CodingBreakdown_Billed
AS
BEGIN
    SET NOCOUNT ON;

    -- LineLevelData has CPTCodeXUnitsXModifier (aggregate CPT column) for PhiLife
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
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> '';

    SELECT Panelname, COUNT(VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
    INTO #PanelSummary FROM #Raw GROUP BY Panelname;

    SELECT Panelname, CPTDetail, COUNT(VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
    INTO #CPTDetail FROM #Raw WHERE CPTDetail <> '' GROUP BY Panelname, CPTDetail;

    TRUNCATE TABLE dbo.Phi_CodingPanelSummary;
    INSERT INTO dbo.Phi_CodingPanelSummary (PanelName, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, ClaimCount, TotalCharges, GETDATE() FROM #PanelSummary ORDER BY TotalCharges DESC;

    TRUNCATE TABLE dbo.Phi_CodingCPTDetail;
    INSERT INTO dbo.Phi_CodingCPTDetail (PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, CPTDetail, ClaimCount, TotalCharges, GETDATE()
    FROM #CPTDetail ORDER BY Panelname, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
    DROP TABLE IF EXISTS #PanelSummary;
    DROP TABLE IF EXISTS #CPTDetail;

    PRINT 'usp_RefreshPhi_CodingBreakdown_Billed completed.';
END
GO

PRINT '09_PhiLife_CodingBreakdown.sql completed.';

-- InHealthDTR — Coding (Billed) Breakdown
-- Rule:
--   Source  : LineLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL  (billed claims only)
--   Row     : Panelname (Panel Group)  +  CPTCode
--   Metric  : COUNT(line records), SUM(ChargeAmount)
--
-- Note: InHealthDTR's LineLevelData carries individual CPTCode, Units, Modifier
--       in separate columns (line-level detail), so CodingBreakdown sources from LineLevelData.
--
-- Storage:
--   InH_CodingPanelSummary  — one row per Panelname
--   InH_CodingCPTDetail     — one row per Panelname + CPTCode
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'InH_CodingPanelSummary')
CREATE TABLE dbo.InH_CodingPanelSummary
(
	SummaryId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
	PanelName    NVARCHAR(500) NOT NULL,
	ClaimCount   INT           NOT NULL DEFAULT 0,
	TotalCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
	RefreshedAt  DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'InH_CodingCPTDetail')
CREATE TABLE dbo.InH_CodingCPTDetail
(
	DetailId      INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
	PanelName     NVARCHAR(500)  NOT NULL,
	CPTCode       NVARCHAR(200)  NOT NULL,
	ClaimCount    INT            NOT NULL DEFAULT 0,
	TotalCharges  DECIMAL(18,2)  NOT NULL DEFAULT 0,
	RefreshedAt   DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshInH_CodingBreakdown_Billed
AS
BEGIN
	SET NOCOUNT ON;

	-- LineLevelData has individual CPTCode, Units, Modifier columns for InHealthDTR
	SELECT
		LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
		LTRIM(RTRIM(ISNULL(CPTCode, '')))                                                AS CPTDetail,
		COALESCE(
			NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
			NULLIF(LTRIM(RTRIM(ClaimID)),         '')
		)                                                                                AS VisitKey,
		TRY_CAST(ChargeAmount AS DECIMAL(18,2))                                          AS Charge
	INTO #Raw
	FROM dbo.LineLevelData
	WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> '';

	SELECT Panelname, COUNT(*) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
	INTO #PanelSummary FROM #Raw GROUP BY Panelname;

	SELECT Panelname, CPTDetail, COUNT(*) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
	INTO #CPTDetail FROM #Raw WHERE CPTDetail <> '' GROUP BY Panelname, CPTDetail;

	TRUNCATE TABLE dbo.InH_CodingPanelSummary;
	INSERT INTO dbo.InH_CodingPanelSummary (PanelName, ClaimCount, TotalCharges, RefreshedAt)
	SELECT Panelname, ClaimCount, TotalCharges, GETDATE() FROM #PanelSummary ORDER BY TotalCharges DESC;

	TRUNCATE TABLE dbo.InH_CodingCPTDetail;
	INSERT INTO dbo.InH_CodingCPTDetail (PanelName, CPTCode, ClaimCount, TotalCharges, RefreshedAt)
	SELECT Panelname, CPTDetail, ClaimCount, TotalCharges, GETDATE()
	FROM #CPTDetail ORDER BY Panelname, TotalCharges DESC;

	DROP TABLE IF EXISTS #Raw;
	DROP TABLE IF EXISTS #PanelSummary;
	DROP TABLE IF EXISTS #CPTDetail;

	PRINT 'usp_RefreshInH_CodingBreakdown_Billed completed.';
END
GO

PRINT '09_InHealthDTR_CodingBreakdown.sql completed.';

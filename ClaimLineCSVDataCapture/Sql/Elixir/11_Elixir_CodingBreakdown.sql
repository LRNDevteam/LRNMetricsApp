-- Elixir Labs — Coding (Unbilled) Breakdown
-- Rule:
--   Source  : ClaimLevelData
--   Filter  : FirstBilledDate IS NULL or blank  (unbilled claims)
--   Row     : Panelname (Panel Group)
--   Drilldown: CPTCodeXUnitsXModifier (CPT detail within panel)
--   Metric  : COUNT(DISTINCT visit no = AccessionNumber/ClaimID), SUM(ChargeAmount)
--
-- Storage:
--   Elix_CodingPanelSummary  — one row per Panelname
--   Elix_CodingCPTDetail     — one row per Panelname + CPTCodeXUnitsXModifier
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 0: Ensure CPTCodeXUnitsXModifier column exists
-- ============================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
      AND name = 'CPTCodeXUnitsXModifier'
)
BEGIN
    ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifier NVARCHAR(MAX) NULL;
    PRINT 'Added CPTCodeXUnitsXModifier to dbo.ClaimLevelData.';
END
GO

-- ============================================================
-- Step 1a: Panel summary table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Elix_CodingPanelSummary')
CREATE TABLE dbo.Elix_CodingPanelSummary
(
    SummaryId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500) NOT NULL,   -- stores Panelname value
    ClaimCount   INT           NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 1b: CPT detail table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Elix_CodingCPTDetail')
CREATE TABLE dbo.Elix_CodingCPTDetail
(
    DetailId               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName              NVARCHAR(500)  NOT NULL,
    CPTCodeXUnitsXModifier NVARCHAR(MAX)  NOT NULL,
    ClaimCount             INT            NOT NULL DEFAULT 0,
    TotalCharges           DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt            DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_CodingBreakdown_Unbilled
AS
BEGIN
    SET NOCOUNT ON;

    -- Collect unbilled claims. Distinct visit = unique AccessionNumber, falling back to ClaimID.
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
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '');

    -- Panel summary: distinct visit count + total charges
    SELECT
        Panelname,
        COUNT(DISTINCT VisitKey)    AS ClaimCount,
        ISNULL(SUM(Charge), 0)      AS TotalCharges
    INTO #PanelSummary
    FROM #Raw
    GROUP BY Panelname;

    -- CPT detail: distinct visit count + total charges per Panelname × CPTDetail
    SELECT
        Panelname,
        CPTDetail,
        COUNT(DISTINCT VisitKey)    AS ClaimCount,
        ISNULL(SUM(Charge), 0)      AS TotalCharges
    INTO #CPTDetail
    FROM #Raw
    WHERE CPTDetail <> ''
    GROUP BY Panelname, CPTDetail;

    TRUNCATE TABLE dbo.Elix_CodingPanelSummary;
    INSERT INTO dbo.Elix_CodingPanelSummary (PanelName, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, ClaimCount, TotalCharges, GETDATE()
    FROM #PanelSummary
    ORDER BY TotalCharges DESC;

    TRUNCATE TABLE dbo.Elix_CodingCPTDetail;
    INSERT INTO dbo.Elix_CodingCPTDetail
        (PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, CPTDetail, ClaimCount, TotalCharges, GETDATE()
    FROM #CPTDetail
    ORDER BY Panelname, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
    DROP TABLE IF EXISTS #PanelSummary;
    DROP TABLE IF EXISTS #CPTDetail;

    PRINT 'usp_RefreshElix_CodingBreakdown_Unbilled completed.';
END
GO

/*
SELECT PanelName, ClaimCount, TotalCharges FROM dbo.Elix_CodingPanelSummary ORDER BY TotalCharges DESC;
SELECT PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges FROM dbo.Elix_CodingCPTDetail ORDER BY PanelName, TotalCharges DESC;
*/

PRINT '11_Elixir_CodingBreakdown.sql completed.';

-- ============================================================
-- Augustus Labs — Coding (Unbilled) Breakdown
-- Rule:
--   Source  : ClaimLevelData
--   Filter  : FirstBilledDate IS NULL or blank
--   Row     : PanelNew (panel-level summary)
--   Drilldown: CPTCodeXUnitsXModifier (CPT detail within panel)
--   Metric  : Distinct visit count (AccessionNumber or ClaimID), Sum ChargeAmount
--
-- Storage:
--   Aug_CodingPanelSummary  — one row per PanelNew
--   Aug_CodingCPTDetail     — one row per PanelNew + CPTCodeXUnitsXModifier
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
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Aug_CodingPanelSummary')
CREATE TABLE dbo.Aug_CodingPanelSummary
(
    SummaryId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500) NOT NULL,   -- stores PanelNew value
    ClaimCount   INT           NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 1b: CPT detail table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Aug_CodingCPTDetail')
CREATE TABLE dbo.Aug_CodingCPTDetail
(
    DetailId               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName              NVARCHAR(500)  NOT NULL,   -- stores PanelNew value
    CPTCodeXUnitsXModifier NVARCHAR(MAX)  NOT NULL,
    ClaimCount             INT            NOT NULL DEFAULT 0,
    TotalCharges           DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt            DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CodingBreakdown_Unbilled
AS
BEGIN
    SET NOCOUNT ON;

    -- Collect unbilled claims with PanelNew and CPT detail.
    -- Distinct visit = unique AccessionNumber, falling back to ClaimID.
    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),''), '(No PanelNew)'))) AS PanelNew,
        LTRIM(RTRIM(ISNULL(CPTCodeXUnitsXModifier, '')))         AS CPTDetail,
        COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        )                                                        AS VisitKey,
        TRY_CAST(ChargeAmount AS DECIMAL(18,2))                  AS Charge
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '');

    -- Panel summary: distinct visits + total charges
    SELECT
        PanelNew,
        COUNT(DISTINCT VisitKey)                                 AS ClaimCount,
        ISNULL(SUM(Charge), 0)                                   AS TotalCharges
    INTO #PanelSummary
    FROM #Raw
    GROUP BY PanelNew;

    -- CPT detail: distinct visits + total charges per PanelNew × CPTDetail
    SELECT
        PanelNew,
        CPTDetail,
        COUNT(DISTINCT VisitKey)                                 AS ClaimCount,
        ISNULL(SUM(Charge), 0)                                   AS TotalCharges
    INTO #CPTDetail
    FROM #Raw
    WHERE CPTDetail <> ''
    GROUP BY PanelNew, CPTDetail;

    -- Atomic replace
    TRUNCATE TABLE dbo.Aug_CodingPanelSummary;
    INSERT INTO dbo.Aug_CodingPanelSummary (PanelName, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelNew, ClaimCount, TotalCharges, GETDATE()
    FROM #PanelSummary
    ORDER BY TotalCharges DESC;

    TRUNCATE TABLE dbo.Aug_CodingCPTDetail;
    INSERT INTO dbo.Aug_CodingCPTDetail
        (PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelNew, CPTDetail, ClaimCount, TotalCharges, GETDATE()
    FROM #CPTDetail
    ORDER BY PanelNew, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
    DROP TABLE IF EXISTS #PanelSummary;
    DROP TABLE IF EXISTS #CPTDetail;

    PRINT 'usp_RefreshAug_CodingBreakdown_Unbilled completed.';
END
GO

/*
SELECT PanelName, ClaimCount, TotalCharges FROM dbo.Aug_CodingPanelSummary ORDER BY TotalCharges DESC;
SELECT PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges FROM dbo.Aug_CodingCPTDetail ORDER BY PanelName, TotalCharges DESC;
*/

PRINT '12_Augustus_CodingBreakdown.sql completed.';

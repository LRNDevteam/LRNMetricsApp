-- ============================================================
-- ============================================================
-- NorthWest Lab - Coding (Unbilled) Breakdown
-- Rule:
--   Data Source : ClaimLevelData ONLY (all columns including CPTCodeXUnitsXModifier)
--   Filter      : LEN(FirstBilledDate) <= 0  (blank / NULL)
--   Row         : PanelName  (panel-level summary)
--   Drilldown   : CPTCodeXUnitsXModifier  (CPT detail within panel)
--   Columns     : Distinct Visit Count (AccessionNumber or ClaimID), Sum(ChargeAmount)
--   Sort        : Grand Total DESC
--
-- Storage layout:
--   NW_CodingPanelSummary   - one row per PanelName
--   NW_CodingCPTDetail      - one row per PanelName + CPTCodeXUnitsXModifier
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 0: Patch ClaimLevelData if CPTCodeXUnitsXModifier is missing.
-- The base 01_CreateTables.sql defines this column, but databases
-- provisioned before it was added will not have it yet.
-- ============================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ClaimLevelData')
      AND name = 'CPTCodeXUnitsXModifier'
)
BEGIN
    ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifier NVARCHAR(MAX) NULL;
    PRINT 'Added missing column CPTCodeXUnitsXModifier to dbo.ClaimLevelData.';
END

-- Apply the same patch to the archive table so inserts do not fail there either.
IF OBJECT_ID('dbo.ClaimLevelDataArchive') IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ClaimLevelDataArchive')
      AND name = 'CPTCodeXUnitsXModifier'
)
BEGIN
    ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCodeXUnitsXModifier NVARCHAR(MAX) NULL;
    PRINT 'Added missing column CPTCodeXUnitsXModifier to dbo.ClaimLevelDataArchive.';
END
GO

-- ============================================================
-- Step 1: Aggregate tables
-- ============================================================

-- Panel-level totals (row A / B / C in the report)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_CodingPanelSummary')
CREATE TABLE dbo.NW_CodingPanelSummary
(
    SummaryId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500) NOT NULL,
    ClaimCount   INT           NOT NULL DEFAULT 0,   -- distinct AccessionNumber (or ClaimID)
    TotalCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

-- CPT detail rows (drill-down 1 / 2 / 3... within each panel)
-- Drop and recreate if the column definition changed (CPTCode -> CPTCodeXUnitsXModifier).
IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.NW_CodingCPTDetail')
      AND name = 'CPTCode'          -- old column name from previous version
)
BEGIN
    DROP TABLE dbo.NW_CodingCPTDetail;
    PRINT 'Dropped dbo.NW_CodingCPTDetail (old schema with CPTCode column).';
END

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'NW_CodingCPTDetail')
CREATE TABLE dbo.NW_CodingCPTDetail
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
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CodingBreakdown_Unbilled
AS
BEGIN
    SET NOCOUNT ON;

    -- --------------------------------------------------------
    -- #1  Pull all unbilled claims from ClaimLevelData.
    --     Filter: FirstBilledDate is blank (NULL, empty, or whitespace).
    --     VisitId: prefer AccessionNumber; fall back to ClaimID.
    --     CPT key: CPTCodeXUnitsXModifier column on ClaimLevelData.
    -- --------------------------------------------------------
    SELECT
        COALESCE(
            NULLIF(LTRIM(RTRIM(cl.AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(cl.ClaimID)),         '')
        )                                                           AS VisitId,
        LTRIM(RTRIM(ISNULL(NULLIF(cl.PanelName, ''), 'Unknown')))  AS PanelName,
        LTRIM(RTRIM(ISNULL(NULLIF(cl.CPTCodeXUnitsXModifier, ''), 'Unknown'))) AS CPTKey,
        ISNULL(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2)), 0)      AS ChargeAmount
    INTO #Unbilled
    FROM dbo.ClaimLevelData cl
    WHERE LEN(ISNULL(cl.FirstBilledDate, '')) <= 0;   -- matches your verified query

    -- --------------------------------------------------------
    -- #2  Panel-level summary
    --     ClaimCount = distinct VisitId per panel
    --     TotalCharges = sum of ChargeAmount per panel
    -- --------------------------------------------------------
    SELECT
        PanelName,
        COUNT(DISTINCT VisitId)     AS ClaimCount,
        SUM(ChargeAmount)           AS TotalCharges
    INTO #PanelSummary
    FROM #Unbilled
    GROUP BY PanelName;

    -- --------------------------------------------------------
    -- #3  CPT detail
    --     ClaimCount = distinct VisitId per panel + CPT combination
    --     TotalCharges = sum of ChargeAmount per panel + CPT combination
    -- --------------------------------------------------------
    SELECT
        PanelName,
        CPTKey                      AS CPTCodeXUnitsXModifier,
        COUNT(DISTINCT VisitId)     AS ClaimCount,
        SUM(ChargeAmount)           AS TotalCharges
    INTO #CPTDetail
    FROM #Unbilled
    GROUP BY PanelName, CPTKey;

    -- --------------------------------------------------------
    -- #4  Atomic replace — panel summary
    -- --------------------------------------------------------
    TRUNCATE TABLE dbo.NW_CodingPanelSummary;

    INSERT INTO dbo.NW_CodingPanelSummary (PanelName, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, ClaimCount, TotalCharges, GETDATE()
    FROM #PanelSummary
    ORDER BY TotalCharges DESC;

    -- --------------------------------------------------------
    -- #5  Atomic replace — CPT detail
    -- --------------------------------------------------------
    TRUNCATE TABLE dbo.NW_CodingCPTDetail;

    INSERT INTO dbo.NW_CodingCPTDetail (PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges, GETDATE()
    FROM #CPTDetail
    ORDER BY PanelName, TotalCharges DESC;

    -- Clean up
    DROP TABLE IF EXISTS #Unbilled;
    DROP TABLE IF EXISTS #PanelSummary;
    DROP TABLE IF EXISTS #CPTDetail;

    PRINT 'usp_RefreshNW_CodingBreakdown_Unbilled completed.';
END
GO

-- ============================================================
-- Quick verification queries
-- ============================================================
/*
-- Raw unbilled claim count (validate filter matches your ad-hoc query)
SELECT COUNT(*) AS UnbilledRows
FROM dbo.ClaimLevelData
WHERE LEN(ISNULL(FirstBilledDate, '')) <= 0;

-- Panel-level totals
SELECT PanelName, ClaimCount, TotalCharges
FROM dbo.NW_CodingPanelSummary
ORDER BY TotalCharges DESC;

-- Grand total (should match panel total sum)
SELECT SUM(ClaimCount) AS GrandClaimCount, SUM(TotalCharges) AS GrandTotalCharges
FROM dbo.NW_CodingPanelSummary;

-- CPT detail for a specific panel
SELECT PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
FROM dbo.NW_CodingCPTDetail
WHERE PanelName = 'Panel 1'
ORDER BY TotalCharges DESC;

-- Full hierarchical view (panel header + CPT detail rows)
SELECT
    p.PanelName,
    p.ClaimCount        AS Panel_ClaimCount,
    p.TotalCharges      AS Panel_TotalCharges,
    d.CPTCodeXUnitsXModifier,
    d.ClaimCount        AS CPT_ClaimCount,
    d.TotalCharges      AS CPT_TotalCharges
FROM dbo.NW_CodingPanelSummary p
JOIN dbo.NW_CodingCPTDetail    d ON d.PanelName = p.PanelName
ORDER BY p.TotalCharges DESC, d.TotalCharges DESC;
*/

PRINT '10_NorthWest_CodingBreakdown.sql completed.';

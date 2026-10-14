-- PCRLabsofAmerica — Coding (Billed) Breakdown
-- Rule:
--   Source  : ClaimLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL  (billed claims only)
--   Row     : Panelname (Panel Group)
--   Drilldown: CPTCodeXUnitsXModifier (CPT detail within panel)
--   Metric  : COUNT(DISTINCT visit no = AccessionNumber/ClaimID), SUM(ChargeAmount)
--
-- Storage:
--   PCR_CodingPanelSummary  — one row per Panelname
--   PCR_CodingCPTDetail     — one row per Panelname + CPTCodeXUnitsXModifier
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
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_CodingPanelSummary')
CREATE TABLE dbo.PCR_CodingPanelSummary
(
    SummaryId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500) NOT NULL,
    ClaimCount   INT           NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 1b: CPT detail table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_CodingCPTDetail')
CREATE TABLE dbo.PCR_CodingCPTDetail
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
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CodingBreakdown_Billed
AS
BEGIN
    SET NOCOUNT ON;

    -- Collect billed claims (FirstBilledDate NOT blank).
    -- Distinct visit = unique AccessionNumber, falling back to ClaimID.
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
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL and FirstBilledDate !='';

    -- Panel summary
    SELECT
        Panelname,
        --COUNT(DISTINCT VisitKey)    AS ClaimCount,
		COUNT( VisitKey)    AS ClaimCount,
        ISNULL(SUM(Charge), 0)      AS TotalCharges
    INTO #PanelSummary
    FROM #Raw
    GROUP BY Panelname;

    -- CPT detail
    SELECT
        Panelname,
        CPTDetail,
        COUNT(DISTINCT VisitKey)    AS ClaimCount,
        ISNULL(SUM(Charge), 0)      AS TotalCharges
    INTO #CPTDetail
    FROM #Raw
    WHERE CPTDetail <> ''
    GROUP BY Panelname, CPTDetail;

    TRUNCATE TABLE dbo.PCR_CodingPanelSummary;
    INSERT INTO dbo.PCR_CodingPanelSummary (PanelName, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, ClaimCount, TotalCharges, GETDATE()
    FROM #PanelSummary
    ORDER BY TotalCharges DESC;

    TRUNCATE TABLE dbo.PCR_CodingCPTDetail;
    INSERT INTO dbo.PCR_CodingCPTDetail
        (PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, CPTDetail, ClaimCount, TotalCharges, GETDATE()
    FROM #CPTDetail
    ORDER BY Panelname, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
    DROP TABLE IF EXISTS #PanelSummary;
    DROP TABLE IF EXISTS #CPTDetail;

    PRINT 'usp_RefreshPCR_CodingBreakdown_Billed completed.';
END
GO


/*
SELECT PanelName, ClaimCount, TotalCharges FROM dbo.PCR_CodingPanelSummary ORDER BY TotalCharges DESC;
SELECT PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges FROM dbo.PCR_CodingCPTDetail ORDER BY PanelName, TotalCharges DESC;
*/

-- ============================================================
-- Step 3: Read stored procedure
-- Called by LabMetricsDashboard.SqlLabProductionSummaryRepository.
-- Returns TWO result sets (panel summary, then CPT detail). See
-- usp_GetPCR_MonthlyBilledProductionSummary header for the parameter
-- contract (no params -> snapshot tables; any param -> live aggregate).
-- The Coding tab only filters on PanelNames + dates; the other parameters
-- are accepted for a uniform call signature and otherwise ignored.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CodingBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,   -- accepted for signature parity; not used
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, ClaimCount, TotalCharges
        FROM    dbo.PCR_CodingPanelSummary
        ORDER BY TotalCharges DESC;

        SELECT  PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
        FROM    dbo.PCR_CodingCPTDetail
        ORDER BY PanelName, TotalCharges DESC;
        RETURN;
    END

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- Filtered live aggregate over billed claims (matches usp_RefreshPCR_CodingBreakdown_Billed body
    -- with the additional filter clauses).
    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS Panelname,
        LTRIM(RTRIM(ISNULL(CPTCodeXUnitsXModifier, '')))                            AS CPTDetail,
        COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)),         '')
        )                                                                            AS VisitKey,
        TRY_CAST(ChargeAmount AS DECIMAL(18,2))                                      AS Charge
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND (@HasPanelFilter    = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom           IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
      AND (@DosTo             IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
      AND (@FirstBillFrom     IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo       IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom   IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo     IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo);

    SELECT  Panelname             AS PanelName,
            COUNT(VisitKey)        AS ClaimCount,
            ISNULL(SUM(Charge), 0) AS TotalCharges
    FROM    #Raw
    GROUP BY Panelname
    ORDER BY TotalCharges DESC;

    SELECT  Panelname                AS PanelName,
            CPTDetail                AS CPTCodeXUnitsXModifier,
            COUNT(DISTINCT VisitKey) AS ClaimCount,
            ISNULL(SUM(Charge), 0)   AS TotalCharges
    FROM    #Raw
    WHERE   CPTDetail <> ''
    GROUP BY Panelname, CPTDetail
    ORDER BY PanelName, TotalCharges DESC;

    DROP TABLE IF EXISTS #Raw;
END
GO

PRINT '09_PCRLabsofAmerica_CodingBreakdown.sql completed.';

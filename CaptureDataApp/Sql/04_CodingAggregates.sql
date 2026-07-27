-- =============================================================================
-- 04_CodingAggregates.sql
-- Aggregate tables + stored procedures for the Coding Summary dashboard.
--
-- Purpose : Pre-compute the YTD/WTD Insights & Summary datasets once per data
--           load (CaptureDataApp) instead of running expensive GROUP BY /
--           FOR XML queries on every dashboard page hit.
--
-- Objects :
--   Tables : dbo.CodingAgg_YtdInsights   (per Year/Panel/CPT-combination)
--            dbo.CodingAgg_YtdSummary    (per Year/Panel)
--            dbo.CodingAgg_WtdInsights   (per Week/Panel/CPT-combination)
--            dbo.CodingAgg_WtdSummary    (per Week/Panel)
--   Procs  : dbo.usp_RefreshCodingAggregates   (rebuild all 4 tables)
--            dbo.usp_GetCodingAggYtdInsights
--            dbo.usp_GetCodingAggYtdSummary
--            dbo.usp_GetCodingAggWtdInsights
--            dbo.usp_GetCodingAggWtdSummary
--            dbo.usp_GetCodingFinancialSummary (reads CodingFinancialSummary)
--            dbo.usp_GetCodingValidationDetail (latest week, TOP 5000)
--
-- Conventions (must match the Coding Summary UI):
--   BillableCptCombo = ExpectedCPTCode (panel master / what SHOULD be billed)
--   BilledCptCombo   = ActualCPTCode   (what WAS billed)
--   NetImpact        = LostRevenue - RevenueAtRisk  (YTD)
--                    = RevenueLoss - PotentialRecoupment (WTD)
--
-- Deployment: run once per lab database, then either run CaptureDataApp or
--             execute:  EXEC dbo.usp_RefreshCodingAggregates @LabName = '<lab>';
-- =============================================================================

-- ── 1. Aggregate tables ──────────────────────────────────────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CodingAgg_YtdInsights')
CREATE TABLE dbo.CodingAgg_YtdInsights
(
    AggId                               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    LabName                             NVARCHAR(500)  NULL,
    ServiceYear                         INT            NOT NULL,
    PanelName                           NVARCHAR(500)  NOT NULL,
    BillableCptCombo                    NVARCHAR(MAX)  NULL,
    BilledCptCombo                      NVARCHAR(MAX)  NULL,
    MissingCpts                         NVARCHAR(MAX)  NULL,
    AdditionalCpts                      NVARCHAR(MAX)  NULL,
    TotalClaims                         INT            NOT NULL DEFAULT 0,
    BilledChargesPerClaim               DECIMAL(18,2)  NULL,
    TotalBilledChargesForMissingCpts    DECIMAL(18,2)  NULL,
    LostRevenue                         DECIMAL(18,2)  NULL,
    TotalBilledChargesForAdditionalCpts DECIMAL(18,2)  NULL,
    RevenueAtRisk                       DECIMAL(18,2)  NULL,
    NetImpact                           DECIMAL(18,2)  NULL,
    RefreshedDateTime                   DATETIME       NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_CodingAgg_YtdInsights_YearPanel'
                 AND object_id = OBJECT_ID('dbo.CodingAgg_YtdInsights'))
CREATE INDEX IX_CodingAgg_YtdInsights_YearPanel
    ON dbo.CodingAgg_YtdInsights (ServiceYear DESC, PanelName);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CodingAgg_YtdSummary')
CREATE TABLE dbo.CodingAgg_YtdSummary
(
    AggId                               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    LabName                             NVARCHAR(500)  NULL,
    ServiceYear                         INT            NOT NULL,
    PanelName                           NVARCHAR(500)  NOT NULL,
    BillableCptCombo                    NVARCHAR(MAX)  NULL,
    BilledCptCombo                      NVARCHAR(MAX)  NULL,
    MissingCpts                         NVARCHAR(MAX)  NULL,
    AdditionalCpts                      NVARCHAR(MAX)  NULL,
    TotalClaims                         INT            NOT NULL DEFAULT 0,
    TotalBilledCharges                  DECIMAL(18,2)  NULL,
    DistinctClaimsWithMissingCpts       INT            NOT NULL DEFAULT 0,
    TotalBilledChargesForMissingCpts    DECIMAL(18,2)  NULL,
    DistinctClaimsWithAdditionalCpts    INT            NOT NULL DEFAULT 0,
    TotalBilledChargesForAdditionalCpts DECIMAL(18,2)  NULL,
    LostRevenue                         DECIMAL(18,2)  NULL,
    RevenueAtRisk                       DECIMAL(18,2)  NULL,
    NetImpact                           DECIMAL(18,2)  NULL,
    RefreshedDateTime                   DATETIME       NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_CodingAgg_YtdSummary_YearPanel'
                 AND object_id = OBJECT_ID('dbo.CodingAgg_YtdSummary'))
CREATE INDEX IX_CodingAgg_YtdSummary_YearPanel
    ON dbo.CodingAgg_YtdSummary (ServiceYear DESC, PanelName);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CodingAgg_WtdInsights')
CREATE TABLE dbo.CodingAgg_WtdInsights
(
    AggId                               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    LabName                             NVARCHAR(500)  NULL,
    WeekFolder                          NVARCHAR(500)  NOT NULL,
    PanelName                           NVARCHAR(500)  NOT NULL,
    BillableCptCombo                    NVARCHAR(MAX)  NULL,
    BilledCptCombo                      NVARCHAR(MAX)  NULL,
    MissingCpts                         NVARCHAR(MAX)  NULL,
    AdditionalCpts                      NVARCHAR(MAX)  NULL,
    TotalClaims                         INT            NOT NULL DEFAULT 0,
    TotalBilledCharges                  DECIMAL(18,2)  NULL,
    BilledChargesForMissingCpts         DECIMAL(18,2)  NULL,
    RevenueLoss                         DECIMAL(18,2)  NULL,
    BilledChargesForAdditionalCpts      DECIMAL(18,2)  NULL,
    PotentialRecoupment                 DECIMAL(18,2)  NULL,
    NetImpact                           DECIMAL(18,2)  NULL,
    RefreshedDateTime                   DATETIME       NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_CodingAgg_WtdInsights_WeekPanel'
                 AND object_id = OBJECT_ID('dbo.CodingAgg_WtdInsights'))
CREATE INDEX IX_CodingAgg_WtdInsights_WeekPanel
    ON dbo.CodingAgg_WtdInsights (WeekFolder DESC, PanelName);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'CodingAgg_WtdSummary')
CREATE TABLE dbo.CodingAgg_WtdSummary
(
    AggId                               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    LabName                             NVARCHAR(500)  NULL,
    WeekFolder                          NVARCHAR(500)  NOT NULL,
    PanelName                           NVARCHAR(500)  NOT NULL,
    BillableCptCombo                    NVARCHAR(MAX)  NULL,
    BilledCptCombo                      NVARCHAR(MAX)  NULL,
    MissingCpts                         NVARCHAR(MAX)  NULL,
    AdditionalCpts                      NVARCHAR(MAX)  NULL,
    TotalClaims                         INT            NOT NULL DEFAULT 0,
    DistinctClaimsWithMissingCpts       INT            NOT NULL DEFAULT 0,
    TotalBilledChargesForMissingCpts    DECIMAL(18,2)  NULL,
    AvgAllowedAmountForMissingCpts      DECIMAL(18,2)  NULL,
    RefreshedDateTime                   DATETIME       NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_CodingAgg_WtdSummary_WeekPanel'
                 AND object_id = OBJECT_ID('dbo.CodingAgg_WtdSummary'))
CREATE INDEX IX_CodingAgg_WtdSummary_WeekPanel
    ON dbo.CodingAgg_WtdSummary (WeekFolder DESC, PanelName);
GO

-- ── 2. Refresh procedure ─────────────────────────────────────────────────────
-- Full rebuild of all four aggregate tables from dbo.CodingValidation.
-- @LabName     : stamped onto the rows (informational; each lab has its own DB).
-- @OnlyIfEmpty : 1 = refresh only when the aggregate tables are empty while
--                CodingValidation has rows (used on the "file already loaded"
--                path so first-time deployments still get populated).
-- Returns one result set: (Dataset, RowsInserted) per table, for caller logging.

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCodingAggregates
    @LabName     NVARCHAR(500) = NULL,
    @OnlyIfEmpty BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @OnlyIfEmpty = 1
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.CodingAgg_YtdSummary)
           OR NOT EXISTS (SELECT 1 FROM dbo.CodingValidation)
        BEGIN
            SELECT Dataset = CAST(NULL AS NVARCHAR(50)),
                   RowsInserted = CAST(NULL AS INT)
            WHERE 1 = 0;   -- nothing to do → empty result set
            RETURN;
        END
    END

    DECLARE @cYtdIns INT, @cYtdSum INT, @cWtdIns INT, @cWtdSum INT;

    BEGIN TRANSACTION;

        DELETE FROM dbo.CodingAgg_YtdInsights;
        DELETE FROM dbo.CodingAgg_YtdSummary;
        DELETE FROM dbo.CodingAgg_WtdInsights;
        DELETE FROM dbo.CodingAgg_WtdSummary;

        -- ── 2a. YTD Insights: one row per Year/Panel/CPT-combination ─────────
        INSERT INTO dbo.CodingAgg_YtdInsights
            (LabName, ServiceYear, PanelName,
             BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
             TotalClaims, BilledChargesPerClaim,
             TotalBilledChargesForMissingCpts, LostRevenue,
             TotalBilledChargesForAdditionalCpts, RevenueAtRisk, NetImpact)
        SELECT
            @LabName,
            YEAR(TRY_CAST(DateofService AS DATE))                        AS ServiceYear,
            PanelName,
            ISNULL(ExpectedCPTCode,    '')                               AS BillableCptCombo,
            ISNULL(ActualCPTCode,      '')                               AS BilledCptCombo,
            ISNULL(MissingCPTCodes,    '')                               AS MissingCpts,
            ISNULL(AdditionalCPTCodes, '')                               AS AdditionalCpts,
            COUNT(*)                                                     AS TotalClaims,
            AVG(TRY_CAST(TotalCharge              AS DECIMAL(18,2)))     AS BilledChargesPerClaim,
            SUM(TRY_CAST(MissingCPT_Charges       AS DECIMAL(18,2)))     AS TotalBilledChargesForMissingCpts,
            SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2)))     AS LostRevenue,
            SUM(TRY_CAST(AdditionalCPT_Charges    AS DECIMAL(18,2)))     AS TotalBilledChargesForAdditionalCpts,
            SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2)))  AS RevenueAtRisk,
            ISNULL(SUM(TRY_CAST(MissingCPT_AvgPaidAmount    AS DECIMAL(18,2))), 0)
          - ISNULL(SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2))), 0) AS NetImpact
        FROM dbo.CodingValidation
        WHERE PanelName IS NOT NULL AND PanelName <> ''
          AND YEAR(TRY_CAST(DateofService AS DATE)) IS NOT NULL
        GROUP BY
            YEAR(TRY_CAST(DateofService AS DATE)),
            PanelName,
            ISNULL(ExpectedCPTCode,    ''),
            ISNULL(ActualCPTCode,      ''),
            ISNULL(MissingCPTCodes,    ''),
            ISNULL(AdditionalCPTCodes, '');
        SET @cYtdIns = @@ROWCOUNT;

        -- ── 2b. YTD Summary: one row per Year/Panel (+ distinct combo lists) ─
        INSERT INTO dbo.CodingAgg_YtdSummary
            (LabName, ServiceYear, PanelName,
             BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
             TotalClaims, TotalBilledCharges,
             DistinctClaimsWithMissingCpts, TotalBilledChargesForMissingCpts,
             DistinctClaimsWithAdditionalCpts, TotalBilledChargesForAdditionalCpts,
             LostRevenue, RevenueAtRisk, NetImpact)
        SELECT
            @LabName,
            g.ServiceYear,
            g.PanelName,
            STUFF((
                SELECT DISTINCT '*' + d1.ExpectedCPTCode
                FROM dbo.CodingValidation d1
                WHERE YEAR(TRY_CAST(d1.DateofService AS DATE)) = g.ServiceYear
                  AND d1.PanelName = g.PanelName
                  AND d1.ExpectedCPTCode IS NOT NULL AND d1.ExpectedCPTCode <> ''
                ORDER BY '*' + d1.ExpectedCPTCode
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BillableCptCombo,
            STUFF((
                SELECT DISTINCT '*' + d2.ActualCPTCode
                FROM dbo.CodingValidation d2
                WHERE YEAR(TRY_CAST(d2.DateofService AS DATE)) = g.ServiceYear
                  AND d2.PanelName = g.PanelName
                  AND d2.ActualCPTCode IS NOT NULL AND d2.ActualCPTCode <> ''
                ORDER BY '*' + d2.ActualCPTCode
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BilledCptCombo,
            STUFF((
                SELECT DISTINCT '*' + d3.MissingCPTCodes
                FROM dbo.CodingValidation d3
                WHERE YEAR(TRY_CAST(d3.DateofService AS DATE)) = g.ServiceYear
                  AND d3.PanelName = g.PanelName
                  AND d3.MissingCPTCodes IS NOT NULL AND d3.MissingCPTCodes <> ''
                ORDER BY '*' + d3.MissingCPTCodes
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS MissingCpts,
            STUFF((
                SELECT DISTINCT '*' + d4.AdditionalCPTCodes
                FROM dbo.CodingValidation d4
                WHERE YEAR(TRY_CAST(d4.DateofService AS DATE)) = g.ServiceYear
                  AND d4.PanelName = g.PanelName
                  AND d4.AdditionalCPTCodes IS NOT NULL AND d4.AdditionalCPTCodes <> ''
                ORDER BY '*' + d4.AdditionalCPTCodes
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS AdditionalCpts,
            g.TotalClaims,
            g.TotalBilledCharges,
            g.DistinctClaimsWithMissingCpts,
            g.TotalBilledChargesForMissingCpts,
            g.DistinctClaimsWithAdditionalCpts,
            g.TotalBilledChargesForAdditionalCpts,
            g.LostRevenue,
            g.RevenueAtRisk,
            ISNULL(g.LostRevenue, 0) - ISNULL(g.RevenueAtRisk, 0)         AS NetImpact
        FROM (
            SELECT
                YEAR(TRY_CAST(DateofService AS DATE))                     AS ServiceYear,
                PanelName,
                COUNT(*)                                                  AS TotalClaims,
                SUM(TRY_CAST(TotalCharge AS DECIMAL(18,2)))               AS TotalBilledCharges,
                COUNT(DISTINCT CASE WHEN MissingCPTCodes IS NOT NULL
                                     AND MissingCPTCodes <> ''
                                    THEN AccessionNo END)                 AS DistinctClaimsWithMissingCpts,
                SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2)))        AS TotalBilledChargesForMissingCpts,
                COUNT(DISTINCT CASE WHEN AdditionalCPTCodes IS NOT NULL
                                     AND AdditionalCPTCodes <> ''
                                    THEN AccessionNo END)                 AS DistinctClaimsWithAdditionalCpts,
                SUM(TRY_CAST(AdditionalCPT_Charges AS DECIMAL(18,2)))     AS TotalBilledChargesForAdditionalCpts,
                SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2)))  AS LostRevenue,
                SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2))) AS RevenueAtRisk
            FROM dbo.CodingValidation
            WHERE PanelName IS NOT NULL AND PanelName <> ''
              AND YEAR(TRY_CAST(DateofService AS DATE)) IS NOT NULL
            GROUP BY YEAR(TRY_CAST(DateofService AS DATE)), PanelName
        ) g;
        SET @cYtdSum = @@ROWCOUNT;

        -- ── 2c. WTD Insights: one row per Week/Panel/CPT-combination ─────────
        INSERT INTO dbo.CodingAgg_WtdInsights
            (LabName, WeekFolder, PanelName,
             BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
             TotalClaims, TotalBilledCharges,
             BilledChargesForMissingCpts, RevenueLoss,
             BilledChargesForAdditionalCpts, PotentialRecoupment, NetImpact)
        SELECT
            @LabName,
            WeekFolder,
            PanelName,
            ISNULL(ExpectedCPTCode,    '')                               AS BillableCptCombo,
            ISNULL(ActualCPTCode,      '')                               AS BilledCptCombo,
            ISNULL(MissingCPTCodes,    '')                               AS MissingCpts,
            ISNULL(AdditionalCPTCodes, '')                               AS AdditionalCpts,
            COUNT(*)                                                     AS TotalClaims,
            SUM(TRY_CAST(TotalCharge              AS DECIMAL(18,2)))     AS TotalBilledCharges,
            SUM(TRY_CAST(MissingCPT_Charges       AS DECIMAL(18,2)))     AS BilledChargesForMissingCpts,
            SUM(TRY_CAST(MissingCPT_AvgPaidAmount AS DECIMAL(18,2)))     AS RevenueLoss,
            SUM(TRY_CAST(AdditionalCPT_Charges    AS DECIMAL(18,2)))     AS BilledChargesForAdditionalCpts,
            SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2)))  AS PotentialRecoupment,
            ISNULL(SUM(TRY_CAST(MissingCPT_AvgPaidAmount    AS DECIMAL(18,2))), 0)
          - ISNULL(SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount AS DECIMAL(18,2))), 0) AS NetImpact
        FROM dbo.CodingValidation
        WHERE WeekFolder IS NOT NULL AND WeekFolder <> ''
          AND PanelName  IS NOT NULL AND PanelName  <> ''
        GROUP BY
            WeekFolder,
            PanelName,
            ISNULL(ExpectedCPTCode,    ''),
            ISNULL(ActualCPTCode,      ''),
            ISNULL(MissingCPTCodes,    ''),
            ISNULL(AdditionalCPTCodes, '');
        SET @cWtdIns = @@ROWCOUNT;

        -- ── 2d. WTD Summary: one row per Week/Panel (+ distinct combo lists) ─
        INSERT INTO dbo.CodingAgg_WtdSummary
            (LabName, WeekFolder, PanelName,
             BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
             TotalClaims, DistinctClaimsWithMissingCpts,
             TotalBilledChargesForMissingCpts, AvgAllowedAmountForMissingCpts)
        SELECT
            @LabName,
            g.WeekFolder,
            g.PanelName,
            STUFF((
                SELECT DISTINCT '*' + d1.ExpectedCPTCode
                FROM dbo.CodingValidation d1
                WHERE d1.WeekFolder = g.WeekFolder
                  AND d1.PanelName  = g.PanelName
                  AND d1.ExpectedCPTCode IS NOT NULL AND d1.ExpectedCPTCode <> ''
                ORDER BY '*' + d1.ExpectedCPTCode
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BillableCptCombo,
            STUFF((
                SELECT DISTINCT '*' + d2.ActualCPTCode
                FROM dbo.CodingValidation d2
                WHERE d2.WeekFolder = g.WeekFolder
                  AND d2.PanelName  = g.PanelName
                  AND d2.ActualCPTCode IS NOT NULL AND d2.ActualCPTCode <> ''
                ORDER BY '*' + d2.ActualCPTCode
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BilledCptCombo,
            STUFF((
                SELECT DISTINCT '*' + d3.MissingCPTCodes
                FROM dbo.CodingValidation d3
                WHERE d3.WeekFolder = g.WeekFolder
                  AND d3.PanelName  = g.PanelName
                  AND d3.MissingCPTCodes IS NOT NULL AND d3.MissingCPTCodes <> ''
                ORDER BY '*' + d3.MissingCPTCodes
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS MissingCpts,
            STUFF((
                SELECT DISTINCT '*' + d4.AdditionalCPTCodes
                FROM dbo.CodingValidation d4
                WHERE d4.WeekFolder = g.WeekFolder
                  AND d4.PanelName  = g.PanelName
                  AND d4.AdditionalCPTCodes IS NOT NULL AND d4.AdditionalCPTCodes <> ''
                ORDER BY '*' + d4.AdditionalCPTCodes
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS AdditionalCpts,
            g.TotalClaims,
            g.DistinctClaimsWithMissingCpts,
            g.TotalBilledChargesForMissingCpts,
            g.AvgAllowedAmountForMissingCpts
        FROM (
            SELECT
                WeekFolder,
                PanelName,
                COUNT(*)                                                  AS TotalClaims,
                COUNT(DISTINCT CASE WHEN MissingCPTCodes IS NOT NULL
                                     AND MissingCPTCodes <> ''
                                    THEN AccessionNo END)                 AS DistinctClaimsWithMissingCpts,
                SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2)))        AS TotalBilledChargesForMissingCpts,
                AVG(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2))) AS AvgAllowedAmountForMissingCpts
            FROM dbo.CodingValidation
            WHERE WeekFolder IS NOT NULL AND WeekFolder <> ''
              AND PanelName  IS NOT NULL AND PanelName  <> ''
            GROUP BY WeekFolder, PanelName
        ) g;
        SET @cWtdSum = @@ROWCOUNT;

    COMMIT TRANSACTION;

    -- Row counts for caller logging
    SELECT Dataset = N'YtdInsights', RowsInserted = @cYtdIns
    UNION ALL SELECT N'YtdSummary',  @cYtdSum
    UNION ALL SELECT N'WtdInsights', @cWtdIns
    UNION ALL SELECT N'WtdSummary',  @cWtdSum;
END
GO

-- ── 3. Read procedures (used by LabMetricsDashboard + CaptureDataApp JSON) ───

CREATE OR ALTER PROCEDURE dbo.usp_GetCodingAggYtdInsights
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        ServiceYear, PanelName,
        BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
        TotalClaims, BilledChargesPerClaim,
        TotalBilledChargesForMissingCpts, LostRevenue,
        TotalBilledChargesForAdditionalCpts, RevenueAtRisk, NetImpact
    FROM dbo.CodingAgg_YtdInsights
    ORDER BY ServiceYear DESC, PanelName, BillableCptCombo, BilledCptCombo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCodingAggYtdSummary
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        ServiceYear, PanelName,
        BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
        TotalClaims, TotalBilledCharges,
        DistinctClaimsWithMissingCpts, TotalBilledChargesForMissingCpts,
        DistinctClaimsWithAdditionalCpts, TotalBilledChargesForAdditionalCpts,
        LostRevenue, RevenueAtRisk, NetImpact
    FROM dbo.CodingAgg_YtdSummary
    ORDER BY ServiceYear DESC, PanelName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCodingAggWtdInsights
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        WeekFolder, PanelName,
        BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
        TotalClaims, TotalBilledCharges,
        BilledChargesForMissingCpts, RevenueLoss,
        BilledChargesForAdditionalCpts, PotentialRecoupment, NetImpact
    FROM dbo.CodingAgg_WtdInsights
    ORDER BY WeekFolder DESC, PanelName, BillableCptCombo, BilledCptCombo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCodingAggWtdSummary
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        WeekFolder, PanelName,
        BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
        TotalClaims, DistinctClaimsWithMissingCpts,
        TotalBilledChargesForMissingCpts, AvgAllowedAmountForMissingCpts
    FROM dbo.CodingAgg_WtdSummary
    ORDER BY WeekFolder DESC, PanelName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCodingFinancialSummary
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        SummaryId, WeekFolder, ReportDate,
        TotalClaims, TotalBilledCharges, ExpectedBilledCharges,
        RevenueImpact_Claims, RevenueImpact_ActualBilled,
        RevenueImpact_PotentialLoss, RevenueImpact_ExpectedRecoup,
        RevenueLoss_Claims, RevenueLoss_ActualBilled, RevenueLoss_PotentialLoss,
        RevenueAtRisk_Claims, RevenueAtRisk_ActualBilled, RevenueAtRisk_PotentialRecoup,
        Compliance_TotalClaims, Compliance_ClaimsWithIssues, ComplianceRate,
        ClaimsWithMissingCPTs, ClaimsWithAdditionalCPTs,
        ClaimsWithBothMissingAndAdditional, TotalErrorClaims, ComplianceRatePct
    FROM dbo.CodingFinancialSummary
    ORDER BY InsertedDateTime DESC;
END
GO

-- Used by CaptureDataApp's DBRefresh mode: clearing the file-log entry lets
-- usp_BulkInsertCodingValidation reload a regenerated report that has the same
-- RunId (it archives the current rows into CodingValidationData first).
CREATE OR ALTER PROCEDURE dbo.usp_ClearCodingValidationFileLog
    @RunId NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.CodingValidationFileLog WHERE RunId = @RunId;
    SELECT @@ROWCOUNT AS RowsDeleted;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCodingValidationDetail
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LatestWeek NVARCHAR(500);
    SELECT TOP (1) @LatestWeek = WeekFolder
    FROM dbo.CodingValidation WITH (NOLOCK)
    WHERE WeekFolder IS NOT NULL AND LTRIM(RTRIM(WeekFolder)) <> ''
    ORDER BY InsertedDateTime DESC;

    IF @LatestWeek IS NULL
        RETURN;

    SELECT TOP 5000
        WeekFolder, AccessionNo, PanelName, DateofService,
        ActualCPTCode, ExpectedCPTCode,
        MissingCPTCodes, AdditionalCPTCodes,
        ValidationStatus, TotalCharge,
        MissingCPT_Charges, AdditionalCPT_Charges, Remarks
    FROM dbo.CodingValidation WITH (NOLOCK)
    WHERE WeekFolder = @LatestWeek
      AND AccessionNo   IS NOT NULL AND LTRIM(RTRIM(AccessionNo))   <> ''
      AND PanelName     IS NOT NULL AND LTRIM(RTRIM(PanelName))     <> ''
      AND DateofService IS NOT NULL AND LTRIM(RTRIM(DateofService)) <> ''
    ORDER BY PanelName, AccessionNo;
END
GO

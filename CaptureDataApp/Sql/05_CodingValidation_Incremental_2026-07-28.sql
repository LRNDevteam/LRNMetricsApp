/* =============================================================================
   05_CodingValidation_Incremental_2026-07-28.sql
   -----------------------------------------------------------------------------
   INCREMENTAL deploy script — contains ONLY the objects changed/added in the
   Coding Validation work of Jul 2026. Use this instead of re-running the full
   04_CodingAggregates.sql baseline (which also re-creates the 4 aggregate tables
   and the unchanged read procs).

   DEPLOY TO: every lab database that runs Coding Validation. Idempotent
              (CREATE OR ALTER + guarded ALTER TABLE) — safe to re-run.

   AFTER DEPLOY, run once per lab to rebuild the aggregates with the new logic:
       EXEC dbo.usp_RefreshCodingAggregates @LabName = '<lab>';

   ---------------------------------------------------------------------------
   CONTENTS (change tags in brackets)
   ---------------------------------------------------------------------------
   0. dbo.CodingAgg_WtdSummary                    [CVTPL-1.4] 5 added columns
   1. dbo.usp_RefreshCodingAggregates             [CVTPL-1.4 / CVBILL-1.4 / CVDEV-1.4 / CVRI / CVTOTCHG]
        - Net Impact = Revenue at Risk - Lost Revenue
        - Lost Rev / Rev at Risk = SUM(Average ALLOWED amount)
        - WTD Summary gains 5 columns
        - All periods keyed off FirstBillDate; WTD = latest 2 Fri-Thu weeks;
          YTD = all earlier billed-date years (excludes the WTD window)
        - Claim counts = COUNT(DISTINCT VisitNumber)
        - Panels shown only if they have >=1 Missing/Additional CPT claim
        - Recomputes CodingFinancialSummary.RevenueImpact_* [CVRI]
        - YTD Insights 'BilledChargesPerClaim' now holds TOTAL billed charges
          (SUM, was AVG); UI/Excel label = "Total Billed Charges"      [CVTOTCHG]
   2. dbo.usp_GetCodingAggWtdInsights             [CVBILL-1.4] chronological week order
   3. dbo.usp_GetCodingAggWtdSummary              [CVTPL-1.4 / CVBILL-1.4] new columns + order
   4. dbo.usp_GetCodingValidationSourceInfo       [CVUI-SRC]  NEW - source RunId / inserted date
   5. dbo.usp_GetCodingRevenueImpact              [CVRI]      NEW - Revenue Impact from CodingValidation
   6. dbo.usp_GetCodingValidationDetail           [CVDETAIL+] 19 extra columns (screen proc, still capped)
   7. dbo.usp_GetCodingValidationDetailExport     [CVDETAIL-ALL]  NEW - ALL rows for the Excel export
   8. dbo.usp_GetCodingValidationDetailPaged      [CVDETAIL-PAGE] NEW - paged + filtered for the UI tab
   *  Export + Paged procs drop rows that would render completely empty [CVDETAIL-BLANK]

   APP DEPLOY REQUIRED WITH THIS SCRIPT: LabMetricsDashboard + LRN.ReportWorker.
   Deploy SQL FIRST, then the apps.

   REVERT: search the repo for the tag names above.
   ============================================================================= */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   0. CodingAgg_WtdSummary - add the 5 template v1.4 columns (idempotent)
   --------------------------------------------------------------------------- */
-- >>> CVTPL-1.4 CHANGE (2026-07-27): idempotent ADD COLUMN for already-deployed WTD Summary tables.
--     REVERT: delete this whole guarded block.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.CodingAgg_WtdSummary') AND name = 'DistinctClaimsWithAdditionalCpts')
    ALTER TABLE dbo.CodingAgg_WtdSummary ADD DistinctClaimsWithAdditionalCpts INT NOT NULL DEFAULT 0;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.CodingAgg_WtdSummary') AND name = 'TotalBilledChargesForAdditionalCpts')
    ALTER TABLE dbo.CodingAgg_WtdSummary ADD TotalBilledChargesForAdditionalCpts DECIMAL(18,2) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.CodingAgg_WtdSummary') AND name = 'LostRevenue')
    ALTER TABLE dbo.CodingAgg_WtdSummary ADD LostRevenue DECIMAL(18,2) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.CodingAgg_WtdSummary') AND name = 'RevenueAtRisk')
    ALTER TABLE dbo.CodingAgg_WtdSummary ADD RevenueAtRisk DECIMAL(18,2) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.CodingAgg_WtdSummary') AND name = 'NetImpact')
    ALTER TABLE dbo.CodingAgg_WtdSummary ADD NetImpact DECIMAL(18,2) NULL;
GO
-- <<< END CVTPL-1.4 CHANGE
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.CodingAgg_WtdSummary') AND name = 'TotalBilledCharges')
    ALTER TABLE dbo.CodingAgg_WtdSummary ADD TotalBilledCharges DECIMAL(18,2) NULL;
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

        -- >>> CVBILL-1.4 CHANGE (2026-07-27b): billed-date logic matched to the client's output.
        --     Verified against client file 20260723R0155 — all 11 YTD panel rows and 7 WTD groups
        --     reconcile exactly (e.g. ABR, UTI PCR Reflex: YTD 2026=72, 2025=46).
        --     Rules derived from that file:
        --       • Date basis  : FirstBillDate (billed date), NOT DateofService / source WeekFolder.
        --       • Week        : Friday -> Thursday calendar weeks, label "MM/dd/yyyy to MM/dd/yyyy".
        --       • WTD         : the latest @WtdWeeks (=2) Fri->Thu weeks (the week containing MAX(FirstBillDate)
        --                       and the prior week). The client's report spans 2 weeks; change @WtdWeeks if
        --                       the client's cadence differs (spec text says 4, but the file shows 2).
        --       • YTD         : ALL billed-date years for claims billed BEFORE the WTD window
        --                       (grouped by YEAR(FirstBillDate); excludes the WTD range).
        --       • Claim count : DISTINCT VisitNumber (template: "unique visit numbers").
        --     REVERT: drop this #cv block and restore CodingValidation / WeekFolder / YEAR(DateofService) grouping.
        DECLARE @WtdWeeks INT = 2;   -- number of latest Fri->Thu weeks that make up WTD (client = 2)
        DECLARE @MaxBill DATE =
            (SELECT MAX(TRY_CAST(FirstBillDate AS DATE))
             FROM dbo.CodingValidation
             WHERE PanelName IS NOT NULL AND PanelName <> '');
        -- Thursday that ENDS the Fri->Thu week containing @MaxBill.
        -- DATEFIRST-independent: 1900-01-01 was a Monday, so (DATEDIFF%7) gives 0=Mon..3=Thu..6=Sun.
        DECLARE @WtdEnd  DATE = DATEADD(DAY, (3 - (DATEDIFF(DAY, '19000101', @MaxBill) % 7) + 7) % 7, @MaxBill);
        DECLARE @WtdStart DATE = DATEADD(DAY, -(7 * @WtdWeeks - 1), @WtdEnd);   -- start of the earliest WTD week

        IF OBJECT_ID('tempdb..#cv') IS NOT NULL DROP TABLE #cv;

        SELECT
            cv.PanelName,
            cv.AccessionNo,
            cv.VisitNumber,                         -- CVBILL-1.4: claim counts are DISTINCT VisitNumber
            cv.ExpectedCPTCode,
            cv.ActualCPTCode,
            cv.MissingCPTCodes,
            cv.AdditionalCPTCodes,
            cv.TotalCharge,
            cv.MissingCPT_Charges,
            cv.AdditionalCPT_Charges,
            cv.MissingCPT_AvgAllowedAmount,
            cv.AdditionalCPT_AvgAllowedAmount,
            b.BillDate,
            BillYear = YEAR(b.BillDate),
            Scope =
                CASE
                    WHEN b.BillDate BETWEEN @WtdStart AND @WtdEnd THEN 'WTD'   -- latest 2 Fri->Thu weeks
                    WHEN b.BillDate < @WtdStart                   THEN 'YTD'   -- ALL earlier years
                    ELSE NULL
                END,
            -- Friday->Thursday week label "MM/dd/yyyy to MM/dd/yyyy" (WTD rows only)
            BillWeek =
                CASE WHEN b.BillDate BETWEEN @WtdStart AND @WtdEnd THEN
                    CONVERT(NVARCHAR(10), DATEADD(DAY, -6, we.WeekEnd), 101)
                    + ' to ' +
                    CONVERT(NVARCHAR(10), we.WeekEnd, 101)
                END
        INTO #cv
        FROM dbo.CodingValidation cv
        CROSS APPLY (SELECT BillDate = TRY_CAST(cv.FirstBillDate AS DATE)) b
        CROSS APPLY (SELECT WeekEnd = DATEADD(DAY, (3 - (DATEDIFF(DAY, '19000101', b.BillDate) % 7) + 7) % 7, b.BillDate)) we
        WHERE cv.PanelName IS NOT NULL AND cv.PanelName <> ''
          AND b.BillDate IS NOT NULL;

        CREATE INDEX IX_cv_Scope ON #cv (Scope, PanelName);
        -- <<< END CVBILL-1.4 CHANGE

        -- ── 2a. YTD Insights: one row per Year/Panel/CPT-combination ─────────
        INSERT INTO dbo.CodingAgg_YtdInsights
            (LabName, ServiceYear, PanelName,
             BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
             TotalClaims, BilledChargesPerClaim,
             TotalBilledChargesForMissingCpts, LostRevenue,
             TotalBilledChargesForAdditionalCpts, RevenueAtRisk, NetImpact)
        SELECT
            @LabName,
            BillYear                                                     AS ServiceYear,  -- CVBILL-1.4: was YEAR(DateofService)
            PanelName,
            ISNULL(ExpectedCPTCode,    '')                               AS BillableCptCombo,
            ISNULL(ActualCPTCode,      '')                               AS BilledCptCombo,
            ISNULL(MissingCPTCodes,    '')                               AS MissingCpts,
            ISNULL(AdditionalCPTCodes, '')                               AS AdditionalCpts,
            COUNT(DISTINCT VisitNumber)                                                   AS TotalClaims,
            -- >>> CVTOTCHG (2026-07-28): this column is now TOTAL Billed Charges for the group
            --     (was AVG = per-claim charge). The storage column keeps its original name
            --     'BilledChargesPerClaim' to avoid a schema rename on already-deployed labs;
            --     the UI/Excel label is "Total Billed Charges". WTD Insights already used SUM.
            --     REVERT: restore AVG(...) here and the "Billed / claim" labels.
            SUM(TRY_CAST(TotalCharge              AS DECIMAL(18,2)))     AS BilledChargesPerClaim,
            -- <<< END CVTOTCHG
            SUM(TRY_CAST(MissingCPT_Charges       AS DECIMAL(18,2)))     AS TotalBilledChargesForMissingCpts,
            -- >>> CVTPL-1.4 CHANGE (2026-07-27): Allowed basis + Net Impact sign per template v1.4.
            --     REVERT: restore the pre-1.4 lines shown in the comment below.
            --     PRE-1.4: LostRevenue = SUM(MissingCPT_AvgPaidAmount)
            --     PRE-1.4: RevenueAtRisk = SUM(AdditionalCPT_AvgPaidAmount)
            --     PRE-1.4: NetImpact = SUM(MissingCPT_AvgPaidAmount) - SUM(AdditionalCPT_AvgPaidAmount)
            SUM(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2)))  AS LostRevenue,
            SUM(TRY_CAST(AdditionalCPT_Charges    AS DECIMAL(18,2)))     AS TotalBilledChargesForAdditionalCpts,
            SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))) AS RevenueAtRisk,
            ISNULL(SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))), 0)
          - ISNULL(SUM(TRY_CAST(MissingCPT_AvgAllowedAmount    AS DECIMAL(18,2))), 0) AS NetImpact
            -- <<< END CVTPL-1.4 CHANGE
        FROM #cv                                         -- CVBILL-1.4: was dbo.CodingValidation
        WHERE Scope = 'YTD'                              -- CVBILL-1.4: billed-date YTD window
          -- >>> CVDEV-1.4 (2026-07-27): coding insights list deviation combos only (claim has a Missing or Additional CPT).
          --     REVERT: delete this AND line.
          AND (ISNULL(MissingCPTCodes,'') <> '' OR ISNULL(AdditionalCPTCodes,'') <> '')
          -- <<< END CVDEV-1.4
        GROUP BY
            BillYear,                                    -- CVBILL-1.4: was YEAR(DateofService)
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
            -- CVBILL-1.4: STUFF combo lists now read #cv (Scope='YTD', BillYear) instead of CodingValidation/YEAR(DateofService)
            STUFF((
                SELECT DISTINCT '*' + d1.ExpectedCPTCode
                FROM #cv d1
                WHERE d1.Scope = 'YTD' AND d1.BillYear = g.ServiceYear
                  AND d1.PanelName = g.PanelName
                  AND d1.ExpectedCPTCode IS NOT NULL AND d1.ExpectedCPTCode <> ''
                ORDER BY '*' + d1.ExpectedCPTCode
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BillableCptCombo,
            STUFF((
                SELECT DISTINCT '*' + d2.ActualCPTCode
                FROM #cv d2
                WHERE d2.Scope = 'YTD' AND d2.BillYear = g.ServiceYear
                  AND d2.PanelName = g.PanelName
                  AND d2.ActualCPTCode IS NOT NULL AND d2.ActualCPTCode <> ''
                ORDER BY '*' + d2.ActualCPTCode
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BilledCptCombo,
            STUFF((
                SELECT DISTINCT '*' + d3.MissingCPTCodes
                FROM #cv d3
                WHERE d3.Scope = 'YTD' AND d3.BillYear = g.ServiceYear
                  AND d3.PanelName = g.PanelName
                  AND d3.MissingCPTCodes IS NOT NULL AND d3.MissingCPTCodes <> ''
                ORDER BY '*' + d3.MissingCPTCodes
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS MissingCpts,
            STUFF((
                SELECT DISTINCT '*' + d4.AdditionalCPTCodes
                FROM #cv d4
                WHERE d4.Scope = 'YTD' AND d4.BillYear = g.ServiceYear
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
            -- >>> CVTPL-1.4 CHANGE (2026-07-27): Net Impact = RevenueAtRisk - LostRevenue per template v1.4.
            --     REVERT: restore -> ISNULL(g.LostRevenue, 0) - ISNULL(g.RevenueAtRisk, 0) AS NetImpact
            ISNULL(g.RevenueAtRisk, 0) - ISNULL(g.LostRevenue, 0)         AS NetImpact
            -- <<< END CVTPL-1.4 CHANGE
        FROM (
            SELECT
                BillYear                                                 AS ServiceYear,  -- CVBILL-1.4: was YEAR(DateofService)
                PanelName,
                COUNT(DISTINCT VisitNumber)                                                AS TotalClaims,
                SUM(TRY_CAST(TotalCharge AS DECIMAL(18,2)))               AS TotalBilledCharges,
                COUNT(DISTINCT CASE WHEN MissingCPTCodes IS NOT NULL
                                     AND MissingCPTCodes <> ''
                                    THEN VisitNumber END)                AS DistinctClaimsWithMissingCpts,
                SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2)))        AS TotalBilledChargesForMissingCpts,
                COUNT(DISTINCT CASE WHEN AdditionalCPTCodes IS NOT NULL
                                     AND AdditionalCPTCodes <> ''
                                    THEN VisitNumber END)                AS DistinctClaimsWithAdditionalCpts,
                SUM(TRY_CAST(AdditionalCPT_Charges AS DECIMAL(18,2)))     AS TotalBilledChargesForAdditionalCpts,
                -- >>> CVTPL-1.4 CHANGE (2026-07-27): Allowed basis per template v1.4.
                --     REVERT: LostRevenue = SUM(MissingCPT_AvgPaidAmount); RevenueAtRisk = SUM(AdditionalCPT_AvgPaidAmount)
                SUM(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2)))  AS LostRevenue,
                SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))) AS RevenueAtRisk
                -- <<< END CVTPL-1.4 CHANGE
            FROM #cv                                      -- CVBILL-1.4: was dbo.CodingValidation
            WHERE Scope = 'YTD'                           -- CVBILL-1.4: billed-date YTD window
            GROUP BY BillYear, PanelName                  -- CVBILL-1.4: was YEAR(DateofService), PanelName
            -- >>> CVDEV-1.4 (2026-07-27): show a panel only if it has >=1 claim with a Missing/Additional CPT
            --     (template: "summary is presented only for claims that have a Missing or Additional CPT").
            --     The count itself stays all-visits; this only drops panels with zero deviations
            --     (e.g. 'Fungal Nail Panel, Wound Panel' whose claims are all "No Deviation found").
            --     REVERT: delete this HAVING line.
            HAVING MAX(CASE WHEN ISNULL(MissingCPTCodes,'') <> '' OR ISNULL(AdditionalCPTCodes,'') <> '' THEN 1 ELSE 0 END) = 1
            -- <<< END CVDEV-1.4
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
            BillWeek                                                     AS WeekFolder,  -- CVBILL-1.4: billed-date week range, was source WeekFolder
            PanelName,
            ISNULL(ExpectedCPTCode,    '')                               AS BillableCptCombo,
            ISNULL(ActualCPTCode,      '')                               AS BilledCptCombo,
            ISNULL(MissingCPTCodes,    '')                               AS MissingCpts,
            ISNULL(AdditionalCPTCodes, '')                               AS AdditionalCpts,
            COUNT(DISTINCT VisitNumber)                                                   AS TotalClaims,
            SUM(TRY_CAST(TotalCharge              AS DECIMAL(18,2)))     AS TotalBilledCharges,
            SUM(TRY_CAST(MissingCPT_Charges       AS DECIMAL(18,2)))     AS BilledChargesForMissingCpts,
            -- >>> CVTPL-1.4 CHANGE (2026-07-27): Allowed basis + Net Impact sign per template v1.4.
            --     REVERT: RevenueLoss = SUM(MissingCPT_AvgPaidAmount); PotentialRecoupment = SUM(AdditionalCPT_AvgPaidAmount)
            --     REVERT NetImpact: SUM(MissingCPT_AvgPaidAmount) - SUM(AdditionalCPT_AvgPaidAmount)
            SUM(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2)))  AS RevenueLoss,
            SUM(TRY_CAST(AdditionalCPT_Charges    AS DECIMAL(18,2)))     AS BilledChargesForAdditionalCpts,
            SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))) AS PotentialRecoupment,
            ISNULL(SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))), 0)
          - ISNULL(SUM(TRY_CAST(MissingCPT_AvgAllowedAmount    AS DECIMAL(18,2))), 0) AS NetImpact
            -- <<< END CVTPL-1.4 CHANGE
        FROM #cv                                          -- CVBILL-1.4: was dbo.CodingValidation
        WHERE Scope = 'WTD'                               -- CVBILL-1.4: latest 2 billed-date weeks
          AND PanelName  IS NOT NULL AND PanelName  <> ''
          -- >>> CVDEV-1.4 (2026-07-27): coding insights list deviation combos only.
          --     REVERT: delete this AND line.
          AND (ISNULL(MissingCPTCodes,'') <> '' OR ISNULL(AdditionalCPTCodes,'') <> '')
          -- <<< END CVDEV-1.4
        GROUP BY
            BillWeek,                                     -- CVBILL-1.4: was source WeekFolder
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
             TotalClaims, TotalBilledCharges, DistinctClaimsWithMissingCpts,
             TotalBilledChargesForMissingCpts, AvgAllowedAmountForMissingCpts,
             -- >>> CVTPL-1.4 CHANGE (2026-07-27): additional-CPT + revenue columns per template v1.4.
             --     REVERT: remove this line's 5 column names.
             DistinctClaimsWithAdditionalCpts, TotalBilledChargesForAdditionalCpts,
             LostRevenue, RevenueAtRisk, NetImpact)
             -- <<< END CVTPL-1.4 CHANGE
        SELECT
            @LabName,
            g.WeekFolder,
            g.PanelName,
            -- CVBILL-1.4: STUFF combo lists now read #cv (Scope='WTD', BillWeek) instead of CodingValidation/WeekFolder
            STUFF((
                SELECT DISTINCT '*' + d1.ExpectedCPTCode
                FROM #cv d1
                WHERE d1.Scope = 'WTD' AND d1.BillWeek = g.WeekFolder
                  AND d1.PanelName  = g.PanelName
                  AND d1.ExpectedCPTCode IS NOT NULL AND d1.ExpectedCPTCode <> ''
                ORDER BY '*' + d1.ExpectedCPTCode
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BillableCptCombo,
            STUFF((
                SELECT DISTINCT '*' + d2.ActualCPTCode
                FROM #cv d2
                WHERE d2.Scope = 'WTD' AND d2.BillWeek = g.WeekFolder
                  AND d2.PanelName  = g.PanelName
                  AND d2.ActualCPTCode IS NOT NULL AND d2.ActualCPTCode <> ''
                ORDER BY '*' + d2.ActualCPTCode
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS BilledCptCombo,
            STUFF((
                SELECT DISTINCT '*' + d3.MissingCPTCodes
                FROM #cv d3
                WHERE d3.Scope = 'WTD' AND d3.BillWeek = g.WeekFolder
                  AND d3.PanelName  = g.PanelName
                  AND d3.MissingCPTCodes IS NOT NULL AND d3.MissingCPTCodes <> ''
                ORDER BY '*' + d3.MissingCPTCodes
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS MissingCpts,
            STUFF((
                SELECT DISTINCT '*' + d4.AdditionalCPTCodes
                FROM #cv d4
                WHERE d4.Scope = 'WTD' AND d4.BillWeek = g.WeekFolder
                  AND d4.PanelName  = g.PanelName
                  AND d4.AdditionalCPTCodes IS NOT NULL AND d4.AdditionalCPTCodes <> ''
                ORDER BY '*' + d4.AdditionalCPTCodes
                FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 1, '') AS AdditionalCpts,
            g.TotalClaims,
            g.TotalBilledCharges,
            g.DistinctClaimsWithMissingCpts,
            g.TotalBilledChargesForMissingCpts,
            g.AvgAllowedAmountForMissingCpts,
            -- >>> CVTPL-1.4 CHANGE (2026-07-27): additional-CPT + revenue values per template v1.4.
            --     REVERT: delete these 5 outer projections and the matching 5 inner-subquery lines below.
            g.DistinctClaimsWithAdditionalCpts,
            g.TotalBilledChargesForAdditionalCpts,
            g.LostRevenue,
            g.RevenueAtRisk,
            ISNULL(g.RevenueAtRisk, 0) - ISNULL(g.LostRevenue, 0)         AS NetImpact
            -- <<< END CVTPL-1.4 CHANGE
        FROM (
            SELECT
                BillWeek AS WeekFolder,                       -- CVBILL-1.4: billed-date week range, was source WeekFolder
                PanelName,
                COUNT(DISTINCT VisitNumber)                                                AS TotalClaims,
                SUM(TRY_CAST(TotalCharge AS DECIMAL(18,2)))               AS TotalBilledCharges,
                COUNT(DISTINCT CASE WHEN MissingCPTCodes IS NOT NULL
                                     AND MissingCPTCodes <> ''
                                    THEN VisitNumber END)                AS DistinctClaimsWithMissingCpts,
                SUM(TRY_CAST(MissingCPT_Charges AS DECIMAL(18,2)))        AS TotalBilledChargesForMissingCpts,
                AVG(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2))) AS AvgAllowedAmountForMissingCpts,
                -- >>> CVTPL-1.4 CHANGE (2026-07-27): per template v1.4 (Lost/AtRisk = Sum of Avg Allowed Amount).
                --     REVERT: delete these 4 inner projections.
                COUNT(DISTINCT CASE WHEN AdditionalCPTCodes IS NOT NULL
                                     AND AdditionalCPTCodes <> ''
                                    THEN VisitNumber END)                AS DistinctClaimsWithAdditionalCpts,
                SUM(TRY_CAST(AdditionalCPT_Charges AS DECIMAL(18,2)))     AS TotalBilledChargesForAdditionalCpts,
                SUM(TRY_CAST(MissingCPT_AvgAllowedAmount AS DECIMAL(18,2)))    AS LostRevenue,
                SUM(TRY_CAST(AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))) AS RevenueAtRisk
                -- <<< END CVTPL-1.4 CHANGE
            FROM #cv                                          -- CVBILL-1.4: was dbo.CodingValidation
            WHERE Scope = 'WTD'                               -- CVBILL-1.4: latest 2 billed-date weeks
              AND PanelName  IS NOT NULL AND PanelName  <> ''
            GROUP BY BillWeek, PanelName                      -- CVBILL-1.4: was WeekFolder, PanelName
            -- >>> CVDEV-1.4 (2026-07-27): show a panel/week only if it has >=1 Missing/Additional claim.
            --     Count stays all-visits; drops zero-deviation panels. REVERT: delete this HAVING line.
            HAVING MAX(CASE WHEN ISNULL(MissingCPTCodes,'') <> '' OR ISNULL(AdditionalCPTCodes,'') <> '' THEN 1 ELSE 0 END) = 1
            -- <<< END CVDEV-1.4
        ) g;
        SET @cWtdSum = @@ROWCOUNT;

        -- CVBILL-1.4: #cv is a session temp table; drop before COMMIT so re-runs are clean.
        IF OBJECT_ID('tempdb..#cv') IS NOT NULL DROP TABLE #cv;

        -- >>> CVRI (2026-07-27 / 2026-07-30): recompute Revenue Impact into CodingFinancialSummary
        --     from CodingValidation (deviation claims; Paid basis), keyed by WeekFolder only.
        --     PREVIOUSLY: CROSS APPLY + OR NOT EXISTS fallback when WeekFolder had no deviations —
        --     that plan did ~100M+ logical reads on Cove (~32k rows) and hung the refresh for minutes.
        --     Now: one GROUP BY WeekFolder, INNER JOIN — unmatched financial rows keep existing RI.
        --     REVERT: restore the CROSS APPLY / OR NOT EXISTS block from git history.
        ;WITH ri AS (
            SELECT
                cv.WeekFolder,
                Claims         = COUNT(DISTINCT cv.VisitNumber),
                ActualBilled   = ISNULL(SUM(TRY_CAST(cv.TotalCharge                   AS DECIMAL(18,2))), 0),
                PotentialLoss  = ISNULL(SUM(TRY_CAST(cv.MissingCPT_AvgPaidAmount       AS DECIMAL(18,2))), 0),
                ExpectedRecoup = ISNULL(SUM(TRY_CAST(cv.AdditionalCPT_AvgPaidAmount    AS DECIMAL(18,2))), 0)
            FROM dbo.CodingValidation cv
            WHERE ISNULL(cv.MissingCPTCodes, '') <> ''
               OR ISNULL(cv.AdditionalCPTCodes, '') <> ''
            GROUP BY cv.WeekFolder
        )
        UPDATE f
        SET f.RevenueImpact_Claims         = ri.Claims,
            f.RevenueImpact_ActualBilled   = ri.ActualBilled,
            f.RevenueImpact_PotentialLoss  = ri.PotentialLoss,
            f.RevenueImpact_ExpectedRecoup = ri.ExpectedRecoup
        FROM dbo.CodingFinancialSummary f
        INNER JOIN ri ON ri.WeekFolder = f.WeekFolder;
        -- <<< END CVRI

        -- Client expected Financial Dashboard: classify by ValidationStatus, not charge > 0.
        ;WITH fin AS (
            SELECT
                cv.WeekFolder,
                MissingOnlyClaims     = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Missing CPTs' THEN 1 ELSE 0 END),
                MissingOnlyBilled     = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Missing CPTs' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0),
                AdditionalOnlyClaims  = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Additional CPTs coded' THEN 1 ELSE 0 END),
                AdditionalOnlyBilled  = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Additional CPTs coded' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0),
                BothClaims            = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN 1 ELSE 0 END),
                BothBilled            = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0)
            FROM dbo.CodingValidation cv
            WHERE ISNULL(cv.AccessionNo, '') <> ''
            GROUP BY cv.WeekFolder
        )
        UPDATE f
        SET f.RevenueLoss_Claims                   = fin.MissingOnlyClaims + fin.BothClaims,
            f.RevenueLoss_ActualBilled             = fin.MissingOnlyBilled + fin.BothBilled,
            f.RevenueAtRisk_Claims                 = fin.AdditionalOnlyClaims + fin.BothClaims,
            f.RevenueAtRisk_ActualBilled           = fin.AdditionalOnlyBilled + fin.BothBilled,
            f.ClaimsWithMissingCPTs                = fin.MissingOnlyClaims,
            f.ClaimsWithAdditionalCPTs             = fin.AdditionalOnlyClaims,
            f.ClaimsWithBothMissingAndAdditional   = fin.BothClaims,
            f.TotalErrorClaims                     = fin.MissingOnlyClaims + fin.BothClaims
        FROM dbo.CodingFinancialSummary f
        INNER JOIN fin ON fin.WeekFolder = f.WeekFolder;

    COMMIT TRANSACTION;

    -- Row counts for caller logging
    SELECT Dataset = N'YtdInsights', RowsInserted = @cYtdIns
    UNION ALL SELECT N'YtdSummary',  @cYtdSum
    UNION ALL SELECT N'WtdInsights', @cWtdIns
    UNION ALL SELECT N'WtdSummary',  @cWtdSum;
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
    -- CVBILL-1.4: order by the week's end date (billed-date label "MM/dd/yyyy to MM/dd/yyyy"), newest first.
    --             REVERT: ORDER BY WeekFolder DESC, PanelName, BillableCptCombo, BilledCptCombo;
    ORDER BY TRY_CAST(RIGHT(WeekFolder, 10) AS DATE) DESC, PanelName, BillableCptCombo, BilledCptCombo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCodingAggWtdSummary
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        WeekFolder, PanelName,
        BillableCptCombo, BilledCptCombo, MissingCpts, AdditionalCpts,
        TotalClaims, TotalBilledCharges, DistinctClaimsWithMissingCpts,
        TotalBilledChargesForMissingCpts, AvgAllowedAmountForMissingCpts,
        -- >>> CVTPL-1.4 CHANGE (2026-07-27): expose additional-CPT + revenue columns per template v1.4.
        --     REVERT: delete this line.
        DistinctClaimsWithAdditionalCpts, TotalBilledChargesForAdditionalCpts,
        LostRevenue, RevenueAtRisk, NetImpact
        -- <<< END CVTPL-1.4 CHANGE
    FROM dbo.CodingAgg_WtdSummary
    -- CVBILL-1.4: order by the week's end date (billed-date label "MM/dd/yyyy to MM/dd/yyyy"), newest first.
    --             REVERT: ORDER BY WeekFolder DESC, PanelName;
    ORDER BY TRY_CAST(RIGHT(WeekFolder, 10) AS DATE) DESC, PanelName;
END
GO

-- >>> CVUI-SRC CHANGE (2026-07-27): source-data provenance for the Coding Summary UI.
--     Returns the processed source files (RunId + when inserted) that populated CodingValidation.
--     REVERT: drop this stored procedure.
CREATE OR ALTER PROCEDURE dbo.usp_GetCodingValidationSourceInfo
    @Top INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top)
        RunId, WeekFolder, LabName, FileName, FileCreatedDateTime, InsertedDateTime
    FROM dbo.CodingValidationFileLog
    ORDER BY InsertedDateTime DESC, FileLogId DESC;
END
GO

-- <<< END CVUI-SRC CHANGE

-- >>> CVRI (2026-07-27): compute Revenue Impact directly from dbo.CodingValidation.
--     Mirrors the source report's "Revenue Impact" block so the numbers can be reproduced
--     / reconciled instead of only read from the Financial Dashboard sheet.
--
--     Claim set : claims WITH a deviation — i.e. ValidationStatus in
--                 ('Missing CPTs','Additional CPTs coded','Both Missing and Additional CPTs identified'),
--                 which is equivalent to (MissingCPTCodes <> '' OR AdditionalCPTCodes <> '').
--     Columns   : Total No. of Claims       = COUNT(DISTINCT VisitNumber)
--                 Total Actual Billed Charges = SUM(TotalCharge)
--                 Potential Loss in Revenue   = SUM(MissingCPT_AvgPaidAmount)      -- PAID basis (as per the source block)
--                 Expected Potential Recoup   = SUM(AdditionalCPT_AvgPaidAmount)   -- PAID basis
--
--     @WeekFolder : NULL = all loaded data; pass a WeekFolder to reconcile against that
--                   report's Financial Dashboard (which is scoped to one week/report).
--     REVERT: drop this stored procedure.
CREATE OR ALTER PROCEDURE dbo.usp_GetCodingRevenueImpact
    @WeekFolder NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        TotalClaims               = COUNT(DISTINCT VisitNumber),
        TotalActualBilledCharges  = ISNULL(SUM(TRY_CAST(TotalCharge                 AS DECIMAL(18,2))), 0),
        PotentialLossInRevenue    = ISNULL(SUM(TRY_CAST(MissingCPT_AvgPaidAmount     AS DECIMAL(18,2))), 0),
        ExpectedPotentialRecoup   = ISNULL(SUM(TRY_CAST(AdditionalCPT_AvgPaidAmount  AS DECIMAL(18,2))), 0)
    FROM dbo.CodingValidation
    WHERE (ISNULL(MissingCPTCodes,'') <> '' OR ISNULL(AdditionalCPTCodes,'') <> '')   -- deviation claims only
      AND (@WeekFolder IS NULL OR WeekFolder = @WeekFolder);
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
        MissingCPT_Charges, AdditionalCPT_Charges, Remarks,
        -- >>> CVDETAIL+ (2026-07-27): extra columns for the Validation Detail sheet.
        --     REVERT: delete these column names.
        VisitNumber, PayerName_Raw, Carrier, Payer_Code, PayerCommonCode,
        Payer_Group_Code, Global_Payer_ID, FirstBillDate, AllowedAmount, InsurancePayment,
        ExpectedCharges,
        MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount, MissingCPT_AvgPatientResponsibilityAmount,
        AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount, AdditionalCPT_AvgPatientResponsibilityAmount,
        MissingCPT_ChargeSource, AdditionalCPT_ChargeSource
        -- <<< END CVDETAIL+
    FROM dbo.CodingValidation WITH (NOLOCK)
    WHERE WeekFolder = @LatestWeek
      AND AccessionNo   IS NOT NULL AND LTRIM(RTRIM(AccessionNo))   <> ''
      AND PanelName     IS NOT NULL AND LTRIM(RTRIM(PanelName))     <> ''
      AND DateofService IS NOT NULL AND LTRIM(RTRIM(DateofService)) <> ''
    ORDER BY PanelName, AccessionNo;
END
GO

-- >>> CVDETAIL-ALL (2026-07-27): uncapped Validation Detail for the EXCEL EXPORT.
--     usp_GetCodingValidationDetail stays TOP 5000 / latest-week for the dashboard tab (fast page load);
--     this proc returns EVERY row (all weeks, no TOP) so the exported sheet misses nothing.
--     Same column list as the capped proc (incl. CVDETAIL+ columns).
--     REVERT: drop this stored procedure and re-point the export to usp_GetCodingValidationDetail.
CREATE OR ALTER PROCEDURE dbo.usp_GetCodingValidationDetailExport
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        WeekFolder, AccessionNo, PanelName, DateofService,
        ActualCPTCode, ExpectedCPTCode,
        MissingCPTCodes, AdditionalCPTCodes,
        ValidationStatus, TotalCharge,
        MissingCPT_Charges, AdditionalCPT_Charges, Remarks,
        VisitNumber, PayerName_Raw, Carrier, Payer_Code, PayerCommonCode,
        Payer_Group_Code, Global_Payer_ID, FirstBillDate, AllowedAmount, InsurancePayment,
        ExpectedCharges,
        MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount, MissingCPT_AvgPatientResponsibilityAmount,
        AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount, AdditionalCPT_AvgPatientResponsibilityAmount,
        MissingCPT_ChargeSource, AdditionalCPT_ChargeSource
    FROM dbo.CodingValidation WITH (NOLOCK)
    -- >>> CVDETAIL-BLANK (2026-07-28): drop rows that would render completely EMPTY.
    --     The test covers exactly the columns shown in the Validation Detail grid/sheet
    --     (Accession, Panel, Date of Service, Status, the three charge columns) plus the CPT code
    --     columns. A row is kept when ANY of them holds a non-space character, so no single column
    --     is mandatory — AccessionNo or DateofService may legitimately be blank on a real claim.
    --     Why not test every column: stray spacer rows from the source workbook can still carry a
    --     VisitNumber / PatientID / administrative value. Those rows pass a "whole row empty" test
    --     yet display as blank lines in the grid, which is the bug being fixed here.
    --     REVERT: remove this WHERE clause to return literally every row.
    WHERE NULLIF(LTRIM(RTRIM(CONCAT(
              AccessionNo, PanelName, DateofService, ValidationStatus,
              TotalCharge, MissingCPT_Charges, AdditionalCPT_Charges,
              ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes))), '') IS NOT NULL
    -- <<< END CVDETAIL-BLANK
    ORDER BY WeekFolder DESC, PanelName, AccessionNo;
END
GO

-- <<< END CVDETAIL-ALL

-- >>> CVDETAIL-PAGE (2026-07-28): server-side paging + filtering for the Validation Detail TAB.
--     Rendering all rows in the browser was too slow, so the screen now fetches one page at a time.
--     Filters are applied in SQL so they span the whole dataset (not just the current page).
--     Returns THREE result sets:
--       1) the page of rows (+ TotalRows = filtered total, via COUNT(*) OVER())
--       2) distinct PanelName list        (drop-down options, unfiltered)
--       3) distinct ValidationStatus list (drop-down options, unfiltered)
--     The Excel export continues to use usp_GetCodingValidationDetailExport (all rows).
--     REVERT: drop this procedure and re-point CodingController.DetailPane back to the export proc.
CREATE OR ALTER PROCEDURE dbo.usp_GetCodingValidationDetailPaged
    @Offset     INT           = 0,
    @PageSize   INT           = 50,
    @PanelName  NVARCHAR(500) = NULL,
    @Status     NVARCHAR(500) = NULL,
    @Search     NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageSize IS NULL OR @PageSize <= 0  SET @PageSize = 50;
    IF @Offset   IS NULL OR @Offset   <  0  SET @Offset   = 0;

    DECLARE @P NVARCHAR(500) = NULLIF(LTRIM(RTRIM(@PanelName)), '');
    DECLARE @S NVARCHAR(500) = NULLIF(LTRIM(RTRIM(@Status)),    '');
    DECLARE @Q NVARCHAR(500) = NULLIF(LTRIM(RTRIM(@Search)),    '');

    -- 1) Page of rows (+ filtered total)
    SELECT
        TotalRows = COUNT(*) OVER(),
        WeekFolder, AccessionNo, PanelName, DateofService,
        ActualCPTCode, ExpectedCPTCode,
        MissingCPTCodes, AdditionalCPTCodes,
        ValidationStatus, TotalCharge,
        MissingCPT_Charges, AdditionalCPT_Charges, Remarks,
        VisitNumber, PayerName_Raw, Carrier, Payer_Code, PayerCommonCode,
        Payer_Group_Code, Global_Payer_ID, FirstBillDate, AllowedAmount, InsurancePayment,
        ExpectedCharges,
        MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount, MissingCPT_AvgPatientResponsibilityAmount,
        AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount, AdditionalCPT_AvgPatientResponsibilityAmount,
        MissingCPT_ChargeSource, AdditionalCPT_ChargeSource
    FROM dbo.CodingValidation WITH (NOLOCK)
    -- CVDETAIL-BLANK (2026-07-28): drop a row only when it carries NO claim data at all (see the
    -- export proc for the full rationale). Any single column may legitimately be blank on a real claim.
    WHERE NULLIF(LTRIM(RTRIM(CONCAT(
              AccessionNo, PanelName, DateofService, ValidationStatus,
              TotalCharge, MissingCPT_Charges, AdditionalCPT_Charges,
              ActualCPTCode, ExpectedCPTCode, MissingCPTCodes, AdditionalCPTCodes))), '') IS NOT NULL
      AND (@P IS NULL OR PanelName        = @P)
      AND (@S IS NULL OR ValidationStatus = @S)
      AND (@Q IS NULL OR
              ISNULL(AccessionNo,     '') LIKE '%' + @Q + '%'
           OR ISNULL(ActualCPTCode,   '') LIKE '%' + @Q + '%'
           OR ISNULL(ExpectedCPTCode, '') LIKE '%' + @Q + '%'
           OR ISNULL(MissingCPTCodes, '') LIKE '%' + @Q + '%'
           OR ISNULL(VisitNumber,     '') LIKE '%' + @Q + '%')
    ORDER BY WeekFolder DESC, PanelName, AccessionNo
    OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

    -- 2) Panel drop-down options
    SELECT DISTINCT PanelName
    FROM dbo.CodingValidation WITH (NOLOCK)
    WHERE NULLIF(LTRIM(RTRIM(PanelName)), '') IS NOT NULL
    ORDER BY PanelName;

    -- 3) Status drop-down options
    SELECT DISTINCT ValidationStatus
    FROM dbo.CodingValidation WITH (NOLOCK)
    WHERE NULLIF(LTRIM(RTRIM(ValidationStatus)), '') IS NOT NULL
    ORDER BY ValidationStatus;
END
GO
PRINT '05_CodingValidation_Incremental_2026-07-28.sql completed.';
GO

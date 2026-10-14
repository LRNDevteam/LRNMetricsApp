-- ============================================================
-- Certus – Executive Summary PMS / Cash / Avg Aggregate Refresh SP
-- File : 16_Certus_ExecutiveSummary_Aggregate.sql
-- DB   : Certus_LRN
--
-- Mirrors Augustus\16_Augustus_ExecutiveSummary_Aggregate.sql.
-- This SP owns and TRUNCATEs Certus_ES_PMS, Certus_ES_Cash, Certus_ES_Avg.
-- Certus_ES_LIS is owned by 19_Certus_ExecutiveSummary_LIS_Alt.sql
-- (usp_RefreshCertus_ExecutiveSummary_LIS_Alt), which sources from
-- dbo.LIMSMaster using ReqCollectDate as the date column.
--
-- Source: dbo.ClaimLevelData, period bucket = DateofService (ESYear/ESMonth),
-- plus a (0,0) grand-total sentinel row.
--
-- PanelGroup lookups (F.<PanelGroup>, I.<PanelGroup>, P.1.<PanelGroup>,
-- P.3.<PanelGroup>): dbo.ClaimLevelData.Panelname is matched (trimmed,
-- case-insensitive) against dbo.PanelGroup(PanelName, PanelGroup); any
-- PanelName not found in dbo.PanelGroup is bucketed as 'Other'. dbo.PanelGroup
-- has a few PanelName values mapped to more than one PanelGroup (e.g.
-- 'Rejection', 'Unable to locate') - these are deduped by picking the
-- lowest PanelGroupID per PanelName so the join stays 1:1 and doesn't fan out
-- claim counts. If dbo.PanelGroup doesn't exist, every claim falls back to
-- 'Other' (single group).
--
-- RoleID scheme (Certus "Billable Samples - PMS Breakdown" /
-- "Cash Breakdown" / "Average Payment Per Claim"):
--
--   PMS Breakdown
--   F      No. of Billed Claims          -> ClaimStatus NOT IN ('Unbilled','Unbilled - PB')
--     F.<PanelGroup>  dynamic, same condition, split by PanelGroup
--   G      Unbilled Claims               -> ClaimStatus IN ('Unbilled','Unbilled - PB')
--     (13 named sub-breakdowns - Unbilled, ACCU Labs - Non-Billable, Commit -
--      Hold/Medicaid TX, Toxicology - Advanta Toxicology LLC, Commit -
--      Non-Billable, Unbilled - Not Received By Commit, Unbilled - Toxicology,
--      Hold/Medicaid TX, Exception, Client Bill, Billed to Insurance, Client
--      Bill - Elixir Laboratories, Toxicology - Billed To Insurance, Toxicology
--      - Patient Pay - are NOT implemented: spec marks these "hide this -
--      waiting for requirement". See commented block below G.)
--   H      Billed Mismatches             -> PMS Row F - LIS Row C (BillTo='Insurance Bill' AND BillingStatus='Billed')
--   I      No. of Fully Paid Claims      -> ClaimStatus='Fully Paid'
--     I.<PanelGroup>  dynamic, same condition, split by PanelGroup
--   J      No. of Patient Responsibility Claims -> ClaimStatus='Patient Responsibility'
--   K      No. of Patient Paid Claims    -> ClaimStatus='Patient Payment'
--   L      No. of Adjusted/Written Off   -> ClaimStatus='Fully Adjusted'
--   M      Test Patients                 -> ClaimStatus='Test Patient'
--   N      No. of Partially Adjusted     -> ClaimStatus='Partially Adjusted'
--   O      No. of Partially Paid Claims  -> ClaimStatus='Partially Paid'
--   P      No. of Insurance Balance Claims -> ClaimStatus IN ('Denied','No Response','Partially Denied')
--     P.1    No. of Fully Denied Claims  -> ClaimStatus='Denied'
--       P.1.<PanelGroup>  dynamic, same condition, split by PanelGroup
--       (AR-follow-up sub-breakdowns + Total Claims worked / Commit Worked % -
--        NOT implemented: "we will add these breakdowns later, this needs to
--        be derived from AR Report which is not available every week")
--     P.2    No. of Partially Denied Claims -> ClaimStatus='Partially Denied'  (new)
--     P.3    No. of No Response from Payor Claims -> ClaimStatus='No Response' (was P.2)
--       P.3.<PanelGroup>  dynamic, same condition, split by PanelGroup
--       (AR-follow-up sub-breakdowns - NOT implemented, same reason as P.1)
--
--   Cash Breakdown
--   Q      Total Billed ($)              -> ClaimStatus NOT IN ('Unbilled','Unbilled - PB'); SUM(ChargeAmount)
--   R      Unbilled Claims ($)           -> ClaimStatus IN ('Unbilled','Unbilled - PB'); SUM(ChargeAmount)
--   S      Insurance Payment ($)         -> ClaimStatus='Fully Paid'; SUM(InsurancePayment)
--   T      Patient Responsibility ($)    -> ClaimStatus NOT IN ('Unbilled','Unbilled - PB'); SUM(PatientBalance)
--   U      Adjustments / Write Off ($)   -> SUM(InsuranceAdjustments + PatientAdjustments)
--   V      Patient Paid ($)              -> PatientPayment > 0; SUM(PatientPayment)
--   W      Partially Paid ($)            -> ClaimStatus='Partially Paid'; SUM(InsurancePayment)
--   X      Insurance Balance ($)         -> SUM(InsuranceBalance)
--   X.1      Denials                     -> ClaimStatus='Denied'; SUM(InsuranceBalance)
--   X.2      Partially Denied            -> ClaimStatus='Partially Denied'; SUM(InsuranceBalance)
--   X.3      No Response from Payor      -> ClaimStatus='No Response'; SUM(InsuranceBalance)
--
--   Average Payment Per Claim
--   Y      Average Payment ($) - Total Pay/Billed Claims -> ClaimStatus NOT IN ('Unbilled','Unbilled - PB')
--   Z      Average Payment ($) - Total Pay/Paid Claims
--   AA     Average Payment ($) - Total Pay/Adjudicated Claims
--
-- NOTE: 'Billed amount 0'/'Partial Paid'/'Fully Denied'/'Test' were stale
-- ClaimStatus literals left over from an earlier data model; they've been
-- replaced with the values confirmed by the new spec ('Unbilled'/'Unbilled -
-- PB', 'Partially Paid', 'Denied', 'Test Patient') everywhere they appeared
-- (F, G, K, M, O, P, P.1, Q, R, W, X.1, Y), so PMS/Cash/Avg all agree on the
-- same ClaimStatus vocabulary.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCert_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Certus_ES_PMS;
    TRUNCATE TABLE dbo.Certus_ES_Cash;
    TRUNCATE TABLE dbo.Certus_ES_Avg;

    -- ── #PanelGroupMap : dbo.PanelGroup deduped 1:1 by PanelName ────────────
    -- A few PanelName values map to more than one PanelGroup in dbo.PanelGroup
    -- (e.g. 'Rejection', 'Unable to locate'); pick the lowest PanelGroupID per
    -- PanelName so the join below can't fan out claim counts.
    DROP TABLE IF EXISTS #PanelGroupMap;
    CREATE TABLE #PanelGroupMap (PanelNameKey NVARCHAR(200) NOT NULL PRIMARY KEY, PanelGroup NVARCHAR(100) NOT NULL);

    IF OBJECT_ID('dbo.PanelGroup', 'U') IS NOT NULL
    BEGIN
        INSERT INTO #PanelGroupMap (PanelNameKey, PanelGroup)
        SELECT PanelNameKey, PanelGroup
        FROM
        (
            SELECT
                UPPER(LTRIM(RTRIM(PanelName))) AS PanelNameKey,
                LTRIM(RTRIM(PanelGroup))        AS PanelGroup,
                ROW_NUMBER() OVER (PARTITION BY UPPER(LTRIM(RTRIM(PanelName))) ORDER BY PanelGroupID) AS rn
            FROM dbo.PanelGroup
            WHERE NULLIF(LTRIM(RTRIM(PanelName)), '') IS NOT NULL
        ) x
        WHERE rn = 1;
    END

    -- ── #Base : one row per ClaimLevelData record with period bucket ───────
    DROP TABLE IF EXISTS #Base;

    SELECT
        c.AccessionNumber,
        YEAR (TRY_CAST(c.DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(c.DateofService AS DATE))  AS ESMonth,
        ISNULL(LTRIM(RTRIM(c.ClaimStatus)), '')      AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(c.Panelname)), '')        AS PanelName,
        ISNULL(pgm.PanelGroup, 'Other')              AS PanelGroup,
        ISNULL(TRY_CAST(c.ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(c.InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(c.PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(c.InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(c.PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(c.InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(c.PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData c
    LEFT JOIN #PanelGroupMap pgm ON pgm.PanelNameKey = UPPER(LTRIM(RTRIM(ISNULL(c.Panelname, ''))))
    WHERE TRY_CAST(c.DateofService AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(c.AccessionNumber)), '') IS NOT NULL;

    -- ── #Periods : distinct (ESYear, ESMonth) + (0,0) grand-total sentinel ──
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
    UNION ALL SELECT 0, 0;

    -- ── #PanelGroups : distinct PanelGroup values present in #Base ──────────
    -- Drives the F.<PanelGroup> / I.<PanelGroup> / P.1.<PanelGroup> /
    -- P.3.<PanelGroup> sub-row breakdowns dynamically (no fixed group list -
    -- whatever groups are actually present, including 'Other').
    DROP TABLE IF EXISTS #PanelGroups;
    SELECT DISTINCT PanelGroup INTO #PanelGroups FROM #Base WHERE NULLIF(PanelGroup, '') IS NOT NULL;

    -- ── #LisBilled : LIMSMaster BillTo='Insurance Bill' AND BillingStatus=
    --    'Billed' counts per ReqCollectDate period, used for PMS row H
    --    (Billed Mismatches = PMS row F - this count, mirrors LIS row C).
    --    Certus uses ReqCollectDate as the date column in LIMSMaster.
    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL);

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        -- Per-period rows (ReqCollectDate → ESYear / ESMonth)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT
            YEAR (TRY_CAST(ReqCollectDate AS DATE)),
            MONTH(TRY_CAST(ReqCollectDate AS DATE)),
            COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillTo = 'Insurance Bill'
          AND BillingStatus = 'Billed'
          AND TRY_CAST(ReqCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
        GROUP BY
            YEAR (TRY_CAST(ReqCollectDate AS DATE)),
            MONTH(TRY_CAST(ReqCollectDate AS DATE));

        -- Grand-total sentinel (ESYear=0, ESMonth=0)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT 0, 0, COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillTo = 'Insurance Bill'
          AND BillingStatus = 'Billed'
          AND TRY_CAST(ReqCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL;
    END

    -- ────────────────────────────────────────────────────────────────────
    --  Certus_ES_PMS  -  F, F.<PanelGroup>, G, H, I, I.<PanelGroup>, J, K, L,
    --                    M, N, O, P, P.1, P.1.<PanelGroup>, P.2, P.3,
    --                    P.3.<PanelGroup>
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Certus_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- F  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.AccessionNumber END) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- F.<PanelGroup>  No. of Billed Claims by Panel Group - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'F.' + pg.PanelGroup,
               N'  ' + pg.PanelGroup,
               COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND b.PanelGroup = pg.PanelGroup THEN b.AccessionNumber END)
        FROM #Periods p
        CROSS JOIN #PanelGroups pg
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, pg.PanelGroup

        -- G  Unbilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'Unbilled Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Unbilled','Unbilled - PB') THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- G's 13 named sub-breakdowns (Unbilled, ACCU Labs - Non-Billable,
        -- Commit - Hold/Medicaid TX, Toxicology - Advanta Toxicology LLC,
        -- Commit - Non-Billable, Unbilled - Not Received By Commit, Unbilled -
        -- Toxicology, Hold/Medicaid TX, Exception, Client Bill, Billed to
        -- Insurance, Client Bill - Elixir Laboratories, Toxicology - Billed To
        -- Insurance, Toxicology - Patient Pay) are marked "hide this - waiting
        -- for requirement - add it and comment it this part" in the spec.
        -- Intentionally NOT implemented/inserted until that requirement lands -
        -- placeholder left here so it's easy to wire up later:
        --
        -- UNION ALL
        -- SELECT p.ESYear, p.ESMonth, 'G.1', '  Unbilled',
        --        COUNT(DISTINCT CASE WHEN b.ClaimStatus = '<TBD>' THEN b.AccessionNumber END)
        -- FROM #Periods p LEFT JOIN #Base b ON (...) GROUP BY p.ESYear, p.ESMonth
        -- (repeat pattern for the remaining 12 sub-rows once source column/values are confirmed)

        -- H  Billed Mismatches - Other samples billed (PMS Row F - LIS Row C)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'Billed Mismatches - Other Samples Billed',
               (COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.AccessionNumber END)
                - ISNULL(lb.BilledCount, 0)) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        LEFT JOIN #LisBilled lb ON lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth
        GROUP BY p.ESYear, p.ESMonth, lb.BilledCount

        -- I  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Fully Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- I.<PanelGroup>  No. of Fully Paid Claims by Panel Group - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'I.' + pg.PanelGroup,
               N'  ' + pg.PanelGroup,
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' AND b.PanelGroup = pg.PanelGroup THEN b.AccessionNumber END)
        FROM #Periods p
        CROSS JOIN #PanelGroups pg
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, pg.PanelGroup

        -- J  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Patient Responsibility Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Patient Responsibility' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- K  No. of Patient Paid Claims  (ClaimStatus = 'Patient Payment' per spec)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Patient Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Patient Payment' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- L  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Adjusted/Written Off Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Adjusted' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- M  Test Patients  (ClaimStatus = 'Test Patient' per spec)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'Test Patients',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Test Patient' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Partially Adjusted Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Adjusted' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- O  No. of Partially Paid Claims  (ClaimStatus = 'Partially Paid' per spec)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Partially Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Paid' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P  No. of Insurance Balance Claims  (Denied, No Response, Partially Denied)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P', 'No. of Insurance Balance Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Denied','No Response','Partially Denied') THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.1  No. of Fully Denied Claims  (ClaimStatus = 'Denied' per spec)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.1', '  No. of Fully Denied Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Denied' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.1.<PanelGroup>  No. of Fully Denied Claims by Panel Group - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'P.1.' + pg.PanelGroup,
               N'    ' + pg.PanelGroup,
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Denied' AND b.PanelGroup = pg.PanelGroup THEN b.AccessionNumber END)
        FROM #Periods p
        CROSS JOIN #PanelGroups pg
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, pg.PanelGroup

        -- P.1's AR-follow-up sub-breakdowns (Denials under AR follow Up, Not
        -- worked by commit, Recently Submitted Claim in Process, Partial
        -- Denial Under AR Follow up, Non-Billable/Exception/Client Bill/Hold,
        -- Adjusted, Processed & Applied towards patient responsibility,
        -- Processed & Paid, Total Claims worked, Commit Worked %) are marked
        -- "we will add these breakdowns later, this needs to be derived from
        -- AR Report which is not available every week" in the spec.
        -- Intentionally NOT implemented/inserted - placeholder for later:
        --
        -- UNION ALL
        -- SELECT p.ESYear, p.ESMonth, 'P.1.1', '    Denials under AR follow Up',
        --        <count, once AR Report feed is available>
        -- FROM #Periods p GROUP BY p.ESYear, p.ESMonth
        -- (repeat for the remaining AR-derived sub-rows + Total Claims worked / Commit Worked %)

        -- P.2  No. of Partially Denied Claims  (new row; ClaimStatus = 'Partially Denied')
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.2', '  No. of Partially Denied Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Denied' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.3  No. of No Response from Payor Claims  (renumbered from old P.2)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.3', '  No. of No Response from Payor Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'No Response' THEN b.AccessionNumber END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.3.<PanelGroup>  No. of No Response from Payor Claims by Panel Group - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'P.3.' + pg.PanelGroup,
               N'    ' + pg.PanelGroup,
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'No Response' AND b.PanelGroup = pg.PanelGroup THEN b.AccessionNumber END)
        FROM #Periods p
        CROSS JOIN #PanelGroups pg
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, pg.PanelGroup

        -- P.3's AR-follow-up sub-breakdowns (Not worked by commit, Non-Billable/
        -- Exception/Client Bill/Hold, Recently Submitted Claim in Process,
        -- Denials under AR follow Up, Processed & Paid, Processed & Applied
        -- towards patient responsibility, Total Claims worked, Commit Worked %)
        -- are NOT implemented for the same AR Report reason as P.1's above.
    ) pms;

    -- ────────────────────────────────────────────────────────────────────
    --  Certus_ES_Cash  -  Q, R, S, T, U, V, W, X, X.1, X.2, X.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Certus_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeAmount, GETDATE()
    FROM
    (
        -- Q  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'Q' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  Unbilled Claims ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'Unbilled Claims ($)',
               SUM(CASE WHEN b.ClaimStatus IN ('Unbilled','Unbilled - PB') THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  Insurance Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'Insurance Payment ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- T  Patient Responsibility ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T', 'Patient Responsibility ($)',
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Adjustments / Write Off ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Adjustments / Write Off ($)',
               SUM(ISNULL(b.InsuranceAdjustments, 0) + ISNULL(b.PatientAdjustments, 0))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- V  Patient Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Patient Paid ($)',
               SUM(CASE WHEN b.PatientPayment > 0 THEN b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W  Partially Paid ($)  (ClaimStatus = 'Partially Paid' per spec)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Partially Paid ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Partially Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X', 'Insurance Balance ($)',
               SUM(b.InsuranceBalance)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.1  Denials  (ClaimStatus = 'Denied' per spec)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.1', '  Denials',
               SUM(CASE WHEN b.ClaimStatus = 'Denied' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.2  Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.2', '  Partially Denied',
               SUM(CASE WHEN b.ClaimStatus = 'Partially Denied' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.3', '  No Response from Payor',
               SUM(CASE WHEN b.ClaimStatus = 'No Response' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- ────────────────────────────────────────────────────────────────────
    --  Certus_ES_Avg  -  Y, Z, AA
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Certus_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- Y  Average Payment ($) - Total Pay / Billed Claims
        SELECT p.ESYear, p.ESMonth, 'Y' AS RoleID, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.AccessionNumber END) AS ClaimCount,
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END) AS PayTotal
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z  Average Payment ($) - Total Pay / Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z', 'Average Payment ($) - Total Pay/Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.AccessionNumber END),
               SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AA  Average Payment ($) - Total Pay / Adjudicated Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.AccessionNumber END),
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) avgrows;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #PanelGroups;
    DROP TABLE IF EXISTS #PanelGroupMap;
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshCert_ExecutiveSummary completed.';
END;
GO

PRINT '16_Certus_ExecutiveSummary_Aggregate.sql completed.';
GO

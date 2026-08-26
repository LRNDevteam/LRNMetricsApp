-- ============================================================
-- Augustus – Executive Summary Cash Breakdown client fixes (NEW SPs)
-- File : 16c_Augustus_ExecutiveSummary_CashBreakdown_v2.sql
-- DB   : Augustus_Labs / Augustus_LRN
--
-- Do NOT drop/replace LIVE:
--   usp_RefreshAug_ExecutiveSummary
--   usp_GetAug_ExecutiveSummary
--   usp_GetAug_ExecutiveSummary_Detail
--   usp_GetExecutiveSummaryDetail_PMSCash
--
-- New SPs in this file:
--   dbo.usp_RefreshAug_ExecutiveSummary_v2
--   dbo.usp_GetAug_ExecutiveSummary_v2
--   dbo.usp_GetAug_ExecutiveSummary_Detail_v2
--   dbo.usp_GetExecutiveSummaryDetail_PMSCash_v2
--
-- Cash Breakdown logic changes (ClaimLevelData):
--   U   Patient Responsibility ($)
--       SUM(PatientBalance) WHERE PatientBalance > 0
--   U.1   Daqbilling  — U AND Source = Daq
--   U.2   IRCM        — U AND Source = IRCM
--   X   Insurance Balance ($)
--       SUM(InsuranceBalance) WHERE InsuranceBalance > 0
--       AND ClaimStatus IN ('Partially Denied','Fully Denied','No Response','Partial Paid')
--   X.1   Fully Denied
--       InsuranceBalance > 0 AND ClaimStatus = 'Fully Denied'
--   X.2   Partially Denied
--       InsuranceBalance > 0 AND ClaimStatus IN ('Partially Denied','Partial Paid')
--   X.3   No Response from Payor
--       InsuranceBalance > 0 AND ClaimStatus = 'No Response'
--
-- usp_RefreshAug_ExecutiveSummary_v2 still TRUNCATEs Augustus_ES_PMS,
-- Augustus_ES_Cash, Augustus_ES_Avg (same snapshot tables as LIVE).
-- Point the nightly refresh job at _v2 after deploy so the no-filter
-- GET path matches. GET v2 also recomputes U/X live on the no-filter
-- path so the grid is correct even before the job is switched.
-- ============================================================
--
-- Source: dbo.ClaimLevelData, period bucket = DateofService (ESYear/ESMonth),
-- plus a (0,0) grand-total sentinel row.
--
-- RoleID scheme (from the "Billable Samples - PMS Breakdown" /
-- "Cash Breakdown" / "Average Payment Per Claim" spec images):
--
--   PMS Breakdown
--   F      No. of Billed Claims          -> FirstBilledDate <> '' AND ClaimStatus <> 'Billed amount 0'
--   F.1      No. of Claims Billed in IRCM   -> F AND Source = IRCM
--   F.2      No. of Claims Billed in Daq Billing -> F AND Source = Daq
--   G      No. of Unbilled Claims         -> FirstBilledDate = '' AND ClaimStatus <> 'Billed amount 0'
--   H      Client bill claims             -> ClaimStatus = 'Billed amount 0'
--   I      No. of Fully Paid Claims       -> ClaimStatus = 'Fully Paid'
--   J      No. of Patient Paid Claims     -> ClaimStatus = 'Patient paid'
--   K      No. of Patient Responsibility  -> ClaimStatus = 'Pat Responsibility'
--   L      No. of Partially Paid Claims   -> ClaimStatus = 'Partial Paid'
--   M      No. of Adjusted/Written Off Claims -> ClaimStatus = 'Fully Adjusted'
--   N      No. of Partially Adjusted/Written Off -> ClaimStatus = 'Partially Adjusted'
--   O      No. of Insurance Balance Claims -> ClaimStatus IN ('Fully Denied','Partially Denied','No Response')
--   O.1      No. of Fully Denied Claims   -> ClaimStatus = 'Fully Denied'
--   O.2      No. of Partially Denied Claims -> ClaimStatus = 'Partially Denied'
--   O.3      No. of No Response from Payor -> ClaimStatus = 'No Response'
--
--   Cash Breakdown
--   P      Total Billed ($)              -> FirstBilledDate <> '' AND ClaimStatus <> 'Billed amount 0'; SUM(ChargeAmount)
--   P.1      Total Charge of Claims Billed (IRCM) -> P AND Source = IRCM
--   P.2      Total Charge of Claims Billed (Daq)  -> P AND Source = Daq
--   Q      Total Unbilled ($)            -> FirstBilledDate = '' AND ClaimStatus <> 'Billed amount 0'; SUM(ChargeAmount)
--   R      Insurance Payment ($)         -> Ins. Payment > 0 AND ClaimStatus = 'Fully Paid'; SUM(InsurancePayment)
--   S      Partially Paid ($)            -> ClaimStatus = 'Partially Paid'; SUM(InsurancePayment)
--   T      Patient Paid ($)              -> Pat. Payment > 0; SUM(PatientPayment)
--   U      Patient Responsibility ($)    -> PatientBalance > 0; SUM(PatientBalance)
--   U.1      Daqbilling                  -> U AND Source = Daq
--   U.2      IRCM                        -> U AND Source = IRCM
--   V      Adjustment amount ($)         -> SUM(InsuranceAdjustments + PatientAdjustments)
--   W      Total Payments ($) - Insurance -> Ins. Payment > 0; SUM(InsurancePayment)
--   X      Insurance Balance ($)         -> InsBal > 0 AND ClaimStatus IN
--                                          ('Partially Denied','Fully Denied','No Response','Partial Paid')
--   X.1      Fully Denied                -> InsBal > 0 AND ClaimStatus = 'Fully Denied'
--   X.2      Partially Denied            -> InsBal > 0 AND ClaimStatus IN ('Partially Denied','Partial Paid')
--   X.3      No Response from Payor      -> InsBal > 0 AND ClaimStatus = 'No Response'
--
--   Average Payment Per Claim
--   Y      Average Payment ($) - Total Pay/Billed Claims
--   Z      Average Payment ($) - Total Pay/Paid Claims
--   AA     Average Payment ($) - Total Pay/Adjudicated Claims
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_ExecutiveSummary_v2
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Augustus_ES_PMS;
    TRUNCATE TABLE dbo.Augustus_ES_Cash;
    TRUNCATE TABLE dbo.Augustus_ES_Avg;

    -- ── #Base : one row per ClaimLevelData record with period bucket ───────
    DROP TABLE IF EXISTS #Base;

    SELECT
        ClaimID,
        AccessionNumber,
        YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
        ISNULL(LTRIM(RTRIM(BillingStatus)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Source)), '')        AS Source,
        ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), FirstBilledDate))), '') AS FirstBilledDate,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData;
    -- NOTE: DateofService / AccessionNumber filters intentionally removed
    -- so all ClaimLevelData rows (including those with no service date) are counted.
    -- Records with no DateofService land in ESYear=NULL/ESMonth=NULL and are
    -- excluded from period breakdowns but included in the (0,0) grand total.

    -- ── DEBUG: #Base row counts ──────────────────────────────────────────────
    DECLARE @n INT;
    SELECT @n = COUNT(*) FROM #Base;
    PRINT '>> #Base total rows: ' + CAST(@n AS VARCHAR);

    SELECT @n = COUNT(*) FROM #Base WHERE Source = 'Daq';
    PRINT '>> #Base Source=Daq total: ' + CAST(@n AS VARCHAR);

    SELECT @n = COUNT(*) FROM #Base WHERE Source = 'Daq' AND FirstBilledDate <> '';
    PRINT '>> #Base Source=Daq AND FirstBilledDate<> : ' + CAST(@n AS VARCHAR);

    SELECT @n = COUNT(*) FROM #Base WHERE Source = 'Daq' AND FirstBilledDate <> '' AND ClaimStatus <> 'Billed amount 0';
    PRINT '>> #Base Source=Daq AND FirstBilledDate<> AND ClaimStatus<>Billed amount 0: ' + CAST(@n AS VARCHAR);

    -- COUNT vs COUNT(DISTINCT) on ClaimID
    SELECT @n = COUNT(ClaimID) FROM #Base WHERE Source = 'Daq' AND FirstBilledDate <> '' AND ClaimStatus <> 'Billed amount 0';
    PRINT '>> COUNT(ClaimID)          Daq: ' + CAST(@n AS VARCHAR);

    SELECT @n = COUNT(DISTINCT ClaimID) FROM #Base WHERE Source = 'Daq' AND FirstBilledDate <> '' AND ClaimStatus <> 'Billed amount 0';
    PRINT '>> COUNT(DISTINCT ClaimID) Daq: ' + CAST(@n AS VARCHAR);
    -- ── END DEBUG ────────────────────────────────────────────────────────────

    -- ── #Periods : distinct (ESYear, ESMonth) + (0,0) grand-total sentinel ──
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
    WHERE ESYear IS NOT NULL AND ESMonth IS NOT NULL  -- exclude NULL-period rows (no DateofService)
    UNION ALL SELECT 0, 0;

    -- ── #LisBilled : LIMSMaster BillingStatus='Billed' counts per
    --    RequestCollectDate period, used for PMS row 'G' (Unbilled Mismatches).
    --    Augustus uses RequestCollectDate as the date column in LIMSMaster.
    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL);

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        -- Per-period rows (RequestCollectDate → ESYear / ESMonth)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE)),
            COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillingStatus = 'Billed'
          AND TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
        GROUP BY
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE));

        -- Grand-total sentinel (ESYear=0, ESMonth=0)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT 0, 0, COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillingStatus = 'Billed'
          AND TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL;
    END

    -- ────────────────────────────────────────────────────────────────────
    --  Augustus_ES_PMS  -  F, F.1, F.2, G, H, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Augustus_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- F  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
               COUNT(DISTINCT b.ClaimID) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate <> ''
                          AND b.ClaimStatus <> 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- F.1  No. of Claims Billed in IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F.1', '  No. of Claims Billed in IRCM',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate <> ''
                          AND b.ClaimStatus <> 'Billed amount 0'
                          AND b.Source = 'IRCM'
        GROUP BY p.ESYear, p.ESMonth

        -- F.2  No. of Claims Billed in Daq Billing
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F.2', '  No. of Claims Billed in Daq Billing',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate <> ''
                          AND b.ClaimStatus <> 'Billed amount 0'
                          AND b.Source = 'Daq'
        GROUP BY p.ESYear, p.ESMonth

        -- G  No. of Unbilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'No. of Unbilled Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.FirstBilledDate = ''
                          AND b.ClaimStatus <> 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- H  Client bill claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'Client bill claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- I  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Fully Paid Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- J  No. of Patient Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Patient Paid Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Patient paid'
        GROUP BY p.ESYear, p.ESMonth

        -- K  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Patient Responsibility Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Pat Responsibility'
        GROUP BY p.ESYear, p.ESMonth

        -- L  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Partially Paid Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partial Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- M  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Adjusted/Written Off Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Partially Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted/Written Off Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- O  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Insurance Balance Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response')
        GROUP BY p.ESYear, p.ESMonth

        -- O.1  No. of Fully Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.1', '  No. of Fully Denied Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- O.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.2', '  No. of Partially Denied Claims',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- O.3  No. of No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.3', '  No. of No Response from Payor',
               COUNT(DISTINCT b.ClaimID)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'No Response'
        GROUP BY p.ESYear, p.ESMonth
    ) pms;

    -- ────────────────────────────────────────────────────────────────────
    --  Augustus_ES_Cash  -  P, P.1, P.2, Q, R, S, T, U, U.1, U.2, V, W, X, X.1, X.2, X.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Augustus_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeAmount, GETDATE()
    FROM
    (
        -- P  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'P' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus<>'Billed amount 0' THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.1  Total Charge of Claims Billed in IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.1', '  Total Charge of Claims Billed (IRCM)',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.2  Total Charge of Claims Billed in Daq
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.2', '  Total Charge of Claims Billed (Daq)',
               SUM(CASE WHEN b.FirstBilledDate <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q  Total Unbilled ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'Total Unbilled ($)',
               SUM(CASE WHEN b.FirstBilledDate = '' AND b.ClaimStatus<>'Billed amount 0' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  Insurance Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'Insurance Payment ($)',
               SUM(CASE WHEN b.InsurancePayment > 0 AND b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'Partially Paid ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Partial Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- T  Patient Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T', 'Patient Paid ($)',
               SUM(CASE WHEN b.PatientPayment > 0 THEN b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Patient Responsibility ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Patient Responsibility ($)',
               SUM(CASE WHEN b.PatientBalance > 0 THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.1  Daqbilling
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.1', '  Daqbilling',
               SUM(CASE WHEN b.PatientBalance > 0 AND b.Source='Daq' THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.2  IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.2', '  IRCM',
               SUM(CASE WHEN b.PatientBalance > 0 AND b.Source='IRCM' THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- V  Adjustment amount ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Adjustment amount ($)',
               SUM(ISNULL(b.InsuranceAdjustments, 0) + ISNULL(b.PatientAdjustments, 0))
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W  Total Payments ($) - Insurance
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Total Payments ($) - Insurance',
               SUM(CASE WHEN b.InsurancePayment > 0 THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X', 'Insurance Balance ($)',
               SUM(CASE WHEN b.InsuranceBalance > 0
                         AND b.ClaimStatus IN ('Partially Denied','Fully Denied','No Response','Partial Paid')
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.1  Fully Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.1', '  Fully Denied',
               SUM(CASE WHEN b.InsuranceBalance > 0 AND b.ClaimStatus = 'Fully Denied'
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.2  Partially Denied (includes Partial Paid)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.2', '  Partially Denied',
               SUM(CASE WHEN b.InsuranceBalance > 0
                         AND b.ClaimStatus IN ('Partially Denied','Partial Paid')
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.3', '  No Response from Payor',
               SUM(CASE WHEN b.InsuranceBalance > 0 AND b.ClaimStatus = 'No Response'
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- ────────────────────────────────────────────────────────────────────
    --  Augustus_ES_Avg  -  Y, Z, AA
    --  Fetches numerator ($) from Augustus_ES_Cash and
    --  denominator (counts) from Augustus_ES_PMS already populated above.
    --
    --  Y  = W (Total Payments Insurance $)        / F  (No. of Billed Claims)
    --  Z  = W (Total Payments Insurance $)        / I  (No. of Fully Paid Claims)
    --  AA = W (Total Payments Insurance $)
    --     + T (Patient Paid $)
    --       / I+J+K+L+M+O.1+O.2  (Fully Paid + Patient Paid + Pat Responsibility +
    --                               Partially Paid + Adj/Written Off +
    --                               Fully Denied + Partially Denied)
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Augustus_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT
        a.RoleID,
        a.Description,
        a.ESYear,
        a.ESMonth,
        a.ClaimCount,
        CASE WHEN a.ClaimCount > 0 THEN a.PayAmount / a.ClaimCount ELSE 0 END,
        GETDATE()
    FROM
    (
        -- ── Y  Total Payments Insurance / No. of Billed Claims ───────────────
        SELECT
            'Y'                                              AS RoleID,
            'Average Payment ($) - Total Pay/Billed Claims' AS Description,
            p.ESYear, p.ESMonth,
            ISNULL(f.ESMonthClaimCount,  0)                 AS ClaimCount,
            ISNULL(w.ESMonthChargeAmount, 0)                AS PayAmount
        FROM #Periods p
        LEFT JOIN dbo.Augustus_ES_PMS  f ON f.ESYear = p.ESYear AND f.ESMonth = p.ESMonth AND f.RoleID = 'F'
        LEFT JOIN dbo.Augustus_ES_Cash w ON w.ESYear = p.ESYear AND w.ESMonth = p.ESMonth AND w.RoleID = 'W'

        -- ── Z  Total Payments Insurance / No. of Fully Paid Claims ──────────
        UNION ALL
        SELECT
            'Z',
            'Average Payment ($) - Total Pay/Paid Claims',
            p.ESYear, p.ESMonth,
            ISNULL(i.ESMonthClaimCount,  0),
            ISNULL(w.ESMonthChargeAmount, 0)
        FROM #Periods p
        LEFT JOIN dbo.Augustus_ES_PMS  i ON i.ESYear = p.ESYear AND i.ESMonth = p.ESMonth AND i.RoleID = 'I'
        LEFT JOIN dbo.Augustus_ES_Cash w ON w.ESYear = p.ESYear AND w.ESMonth = p.ESMonth AND w.RoleID = 'W'

        -- ── AA  (Insurance Pay + Patient Pay) / Sum of adjudicated counts ───
        UNION ALL
        SELECT
            'AA',
            'Average Payment ($) - Total Pay/Adjudicated Claims',
            p.ESYear, p.ESMonth,
            -- Denominator: Fully Paid + Patient Paid + Pat Responsibility +
            --              Partially Paid + Adj/Written Off + Fully Denied + Partially Denied
            ISNULL(i.ESMonthClaimCount,  0) + ISNULL(j.ESMonthClaimCount,  0)
          + ISNULL(k.ESMonthClaimCount,  0) + ISNULL(l.ESMonthClaimCount,  0)
          + ISNULL(m.ESMonthClaimCount,  0) + ISNULL(o1.ESMonthClaimCount, 0)
          + ISNULL(o2.ESMonthClaimCount, 0),
            -- Numerator: Total Insurance Payments + Patient Paid
            ISNULL(w.ESMonthChargeAmount, 0) + ISNULL(t.ESMonthChargeAmount, 0)
        FROM #Periods p
        LEFT JOIN dbo.Augustus_ES_PMS  i  ON i.ESYear  = p.ESYear AND i.ESMonth  = p.ESMonth AND i.RoleID  = 'I'
        LEFT JOIN dbo.Augustus_ES_PMS  j  ON j.ESYear  = p.ESYear AND j.ESMonth  = p.ESMonth AND j.RoleID  = 'J'
        LEFT JOIN dbo.Augustus_ES_PMS  k  ON k.ESYear  = p.ESYear AND k.ESMonth  = p.ESMonth AND k.RoleID  = 'K'
        LEFT JOIN dbo.Augustus_ES_PMS  l  ON l.ESYear  = p.ESYear AND l.ESMonth  = p.ESMonth AND l.RoleID  = 'L'
        LEFT JOIN dbo.Augustus_ES_PMS  m  ON m.ESYear  = p.ESYear AND m.ESMonth  = p.ESMonth AND m.RoleID  = 'M'
        LEFT JOIN dbo.Augustus_ES_PMS  o1 ON o1.ESYear = p.ESYear AND o1.ESMonth = p.ESMonth AND o1.RoleID = 'O.1'
        LEFT JOIN dbo.Augustus_ES_PMS  o2 ON o2.ESYear = p.ESYear AND o2.ESMonth = p.ESMonth AND o2.RoleID = 'O.2'
        LEFT JOIN dbo.Augustus_ES_Cash w  ON w.ESYear  = p.ESYear AND w.ESMonth  = p.ESMonth AND w.RoleID  = 'W'
        LEFT JOIN dbo.Augustus_ES_Cash t  ON t.ESYear  = p.ESYear AND t.ESMonth  = p.ESMonth AND t.RoleID  = 'T'
    ) a;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshAug_ExecutiveSummary_v2 completed.';
END;
GO

PRINT '16c_Augustus_ExecutiveSummary_CashBreakdown_v2.sql — refresh SP completed.';
GO


GO


-- ============================================================
-- Augustus â€“ Executive Summary Read SP
-- File : 17_Augustus_ExecutiveSummary_Read.sql
-- DB   : Augustus_LRN
--
-- Mirrors Cove\17_Cove_ExecutiveSummary_Read.sql.
--
-- usp_GetAug_ExecutiveSummary_v2(@YearFrom,@YearTo,@MonthFrom,@MonthTo, ...)
--   @YearFrom/@YearTo/@MonthFrom/@MonthTo : INT = 0 (0 = unbounded)
--   @HasFilter = 1 if any parameter is non-zero / non-null.
--
-- No-filter path (fast read): UNION ALL of the 4 aggregate tables
-- (Augustus_ES_LIS, Augustus_ES_PMS, Augustus_ES_Cash, Augustus_ES_Avg),
-- each row already bucketed by (ESYear, ESMonth) with a (0,0) grand-total
-- sentinel, returned as (RowCode, Category, Description, BillYear, BillMonth,
-- MetricValue).
--
-- Filtered path (live re-aggregation): re-derives ALL RowCodes from
-- dbo.LIMSMaster (LIS) and dbo.ClaimLevelData (PMS/Cash/Avg).
-- BillYear/BillMonth are derived from whichever date basis is active
-- (DOS vs FirstBilledDate, see @UseBilledDate) so month-wise columns are
-- preserved exactly, and a FirstBilledDate filter buckets rows by when
-- they were actually billed rather than by DateofService.
--
-- Augustus LIS uses:
--   BillTo         -> maps to BillCategory column in LIMSMaster
--   BillingStatus  -> maps to NewStatus column
--   FinalStatus    -> maps to SubStatus column
--   ClientStatus1  -> maps to a secondary SubStatus flag
--   ReqCollectDate -> DOS date column
--   FirstBilledDate -> FirstBilledDate column (same name as ClaimLevelData's)
--   ClinicName     -> ClinicName column
--   Providers      -> DoctorLastName + ', ' + DoctorFirstName
--   Panels         -> PanelType column (confirmed in use; PanelName also exists
--                     on LIMSMaster as a fallback candidate)
--
-- NOTE: COUNT()/SUM() below intentionally do NOT use DISTINCT â€” this matches the
-- confirmed-working deployed procedure. Do not add DISTINCT back in.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAug_ExecutiveSummary_v2
(
    @YearFrom     INT           = 0,
    @YearTo       INT           = 0,
    @MonthFrom    INT           = 0,
    @MonthTo      INT           = 0,
    @DosFrom      DATE          = NULL,
    @DosTo        DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    @Panels       NVARCHAR(MAX) = NULL,
    @Clinics      NVARCHAR(MAX) = NULL,
    @Providers    NVARCHAR(MAX) = NULL,
    @Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT = CASE
        WHEN ISNULL(@YearFrom,  0) <> 0 THEN 1
        WHEN ISNULL(@YearTo,    0) <> 0 THEN 1
        WHEN ISNULL(@MonthFrom, 0) <> 0 THEN 1
        WHEN ISNULL(@MonthTo,   0) <> 0 THEN 1
        WHEN @DosFrom      IS NOT NULL THEN 1
        WHEN @DosTo        IS NOT NULL THEN 1
        WHEN @BilledFrom   IS NOT NULL THEN 1
        WHEN @BilledTo     IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL THEN 1
        ELSE 0
    END;

    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    --  NO FILTER  -  fast read from the 4 aggregate tables
    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    IF @HasFilter = 0
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
                   1 AS CatOrder, Id AS SortId
            FROM dbo.Augustus_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)),
                   2, Id
            FROM dbo.Augustus_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   3, Id
            FROM dbo.Augustus_ES_Cash
            WHERE RoleID NOT IN ('U','U.1','U.2','X','X.1','X.2','X.3')

            UNION ALL
            -- Live U/X monthly buckets (NULL DateofService excluded from months,
            -- included in the (0,0) grand total below).
            SELECT v.RoleID, 'Cash', v.Description, ux.ESYear, ux.ESMonth,
                   SUM(v.Amt), 3, v.SortId
            FROM
            (
                SELECT
                    YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
                    MONTH(TRY_CAST(DateofService AS DATE)) AS ESMonth,
                    ISNULL(LTRIM(RTRIM(ClaimStatus)), '') AS ClaimStatus,
                    ISNULL(LTRIM(RTRIM(Source)), '')      AS Source,
                    ISNULL(TRY_CAST(PatientBalance   AS DECIMAL(18,2)), 0) AS PatientBalance,
                    ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) AS InsuranceBalance
                FROM dbo.ClaimLevelData
            ) ux
            CROSS APPLY
            (
                VALUES
                    ('U',   'Patient Responsibility ($)', CASE WHEN ux.PatientBalance > 0 THEN ux.PatientBalance ELSE 0 END, 80),
                    ('U.1', '  Daqbilling',               CASE WHEN ux.PatientBalance > 0 AND ux.Source='Daq' THEN ux.PatientBalance ELSE 0 END, 81),
                    ('U.2', '  IRCM',                     CASE WHEN ux.PatientBalance > 0 AND ux.Source='IRCM' THEN ux.PatientBalance ELSE 0 END, 82),
                    ('X',   'Insurance Balance ($)',      CASE WHEN ux.InsuranceBalance > 0 AND ux.ClaimStatus IN ('Partially Denied','Fully Denied','No Response','Partial Paid') THEN ux.InsuranceBalance ELSE 0 END, 90),
                    ('X.1', '  Fully Denied',             CASE WHEN ux.InsuranceBalance > 0 AND ux.ClaimStatus = 'Fully Denied' THEN ux.InsuranceBalance ELSE 0 END, 91),
                    ('X.2', '  Partially Denied',         CASE WHEN ux.InsuranceBalance > 0 AND ux.ClaimStatus IN ('Partially Denied','Partial Paid') THEN ux.InsuranceBalance ELSE 0 END, 92),
                    ('X.3', '  No Response from Payor',   CASE WHEN ux.InsuranceBalance > 0 AND ux.ClaimStatus = 'No Response' THEN ux.InsuranceBalance ELSE 0 END, 93)
            ) v(RoleID, Description, Amt, SortId)
            WHERE ux.ESYear IS NOT NULL
            GROUP BY v.RoleID, v.Description, v.SortId, ux.ESYear, ux.ESMonth

            UNION ALL
            SELECT v.RoleID, 'Cash', v.Description, 0, 0,
                   SUM(v.Amt), 3, v.SortId
            FROM
            (
                SELECT
                    ISNULL(LTRIM(RTRIM(ClaimStatus)), '') AS ClaimStatus,
                    ISNULL(LTRIM(RTRIM(Source)), '')      AS Source,
                    ISNULL(TRY_CAST(PatientBalance   AS DECIMAL(18,2)), 0) AS PatientBalance,
                    ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) AS InsuranceBalance
                FROM dbo.ClaimLevelData
            ) ux
            CROSS APPLY
            (
                VALUES
                    ('U',   'Patient Responsibility ($)', CASE WHEN ux.PatientBalance > 0 THEN ux.PatientBalance ELSE 0 END, 80),
                    ('U.1', '  Daqbilling',               CASE WHEN ux.PatientBalance > 0 AND ux.Source='Daq' THEN ux.PatientBalance ELSE 0 END, 81),
                    ('U.2', '  IRCM',                     CASE WHEN ux.PatientBalance > 0 AND ux.Source='IRCM' THEN ux.PatientBalance ELSE 0 END, 82),
                    ('X',   'Insurance Balance ($)',      CASE WHEN ux.InsuranceBalance > 0 AND ux.ClaimStatus IN ('Partially Denied','Fully Denied','No Response','Partial Paid') THEN ux.InsuranceBalance ELSE 0 END, 90),
                    ('X.1', '  Fully Denied',             CASE WHEN ux.InsuranceBalance > 0 AND ux.ClaimStatus = 'Fully Denied' THEN ux.InsuranceBalance ELSE 0 END, 91),
                    ('X.2', '  Partially Denied',         CASE WHEN ux.InsuranceBalance > 0 AND ux.ClaimStatus IN ('Partially Denied','Partial Paid') THEN ux.InsuranceBalance ELSE 0 END, 92),
                    ('X.3', '  No Response from Payor',   CASE WHEN ux.InsuranceBalance > 0 AND ux.ClaimStatus = 'No Response' THEN ux.InsuranceBalance ELSE 0 END, 93)
            ) v(RoleID, Description, Amt, SortId)
            GROUP BY v.RoleID, v.Description, v.SortId

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount,
                   4, Id
            FROM dbo.Augustus_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;

        RETURN;
    END

    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    --  FILTERED  -  live re-aggregation with month-wise breakdown
    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    -- Dimension filter staging tables
    CREATE TABLE #FilterPanels   (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterClinics  (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterProviders(Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterReps     (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL
        INSERT INTO #FilterPanels(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Panels, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL
        INSERT INTO #FilterClinics(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Clinics, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL
        INSERT INTO #FilterProviders(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Providers, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL
        INSERT INTO #FilterReps(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Reps, ',') WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @HasPanelFilter    BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterPanels)    THEN 1 ELSE 0 END;
    DECLARE @HasClinicFilter   BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterClinics)   THEN 1 ELSE 0 END;
    DECLARE @HasProviderFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterProviders) THEN 1 ELSE 0 END;
    DECLARE @HasRepFilter      BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterReps)      THEN 1 ELSE 0 END;

    -- Date mode: DOS vs FirstBilledDate are mutually exclusive in the UI (same
    -- convention as Cove/Elixir/RisingTides). @UseBilledDate = 1 â†’ FirstBilledDate
    -- filter is active (@BilledFrom/@BilledTo set, @DosFrom/@DosTo NULL) â€” LIS and
    -- PMS/Cash/Avg period basis switches from ReqCollectDate/DateofService to
    -- FirstBilledDate. @UseBilledDate = 0 â†’ DOS mode (or no date filter).
    DECLARE @UseBilledDate BIT = CASE
        WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
         AND  @DosFrom IS NULL AND @DosTo IS NULL
        THEN 1 ELSE 0 END;

    -- @HasDosFilter: 1 only when the user explicitly set a DOS range. Used below
    -- to decide whether #Base may fall back to FirstBilledDate for rows with no
    -- parseable DateofService â€” that fallback must NOT apply when an explicit DOS
    -- range was requested (a row without a real DateofService can't legitimately
    -- match a DOS range), but SHOULD apply when browsing with no date filter at
    -- all (e.g. only a Clinic/Provider/Panel/Rep filter), so that claims billed
    -- via FirstBilledDate but missing DateofService aren't silently dropped from
    -- every PMS/Cash/Avg row.
    DECLARE @HasDosFilter BIT = CASE WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1 ELSE 0 END;

    -- @HasLisFilter: 1 when any filter that applies to LIMSMaster is active.
    -- DOS date range (@DosFrom/@DosTo) applied via ReqCollectDate; FirstBilledDate
    -- range (@BilledFrom/@BilledTo, @UseBilledDate=1) applied via LIMSMaster's
    -- FirstBilledDate column. Provider filter now applied via
    -- DoctorLastName + ', ' + DoctorFirstName (see @LisProviderExpr below).
    -- SalesRep is not tracked in LIMSMaster for Augustus, so a Rep-only filter
    -- must NOT trigger a full LIMSMaster scan; the aggregate table is used instead.
    DECLARE @HasLisFilter BIT = CASE WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
                                       OR @DosFrom IS NOT NULL OR @DosTo IS NOT NULL
                                       OR @UseBilledDate = 1
                                       THEN 1 ELSE 0 END;

    -- â”€â”€ LIS: build #Lis from dbo.LIMSMaster, date-filtered on ReqCollectDate â”€â”€
    -- BillYear/BillMonth added so the filtered path produces month-wise rows.
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession     NVARCHAR(100) NOT NULL,
        BillTo        NVARCHAR(200) NOT NULL,
        BillingStatus NVARCHAR(200) NOT NULL,
        FinalStatus   NVARCHAR(200) NOT NULL,
        ClientStatus1 NVARCHAR(200) NOT NULL,
        PanelType     NVARCHAR(200) NOT NULL,
        BillYear      INT           NOT NULL,
        BillMonth     INT           NOT NULL
    );

    IF @HasLisFilter = 1 AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        DECLARE @AccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','Accession','AccessionNo')
            ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

        DECLARE @DateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'ReqCollectDate' THEN 0 WHEN 'RequestCollectDate' THEN 1
                WHEN 'DateOfCollection' THEN 2 WHEN 'DateofService' THEN 3
                WHEN 'CollectionDate' THEN 4 WHEN 'ServiceDate' THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

        DECLARE @BillToCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillTo','BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
            ORDER BY CASE name WHEN 'BillTo' THEN 0 WHEN 'BillCategory' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BilledorNot' THEN 4 WHEN 'BillStatus' THEN 5 ELSE 6 END);

        DECLARE @BillingStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillingStatus','NewStatus','Status','BillStatus')
            ORDER BY CASE name WHEN 'BillingStatus' THEN 0 WHEN 'NewStatus' THEN 1 WHEN 'Status' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

        DECLARE @FinalStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('FinalStatus','SubStatus','Sub_Status','ClientStatus')
            ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'SubStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

        DECLARE @ClientStatus1Col SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClientStatus1','ClientStatus','ClientStatus2','ClientFlag')
            ORDER BY CASE name WHEN 'ClientStatus1' THEN 0 WHEN 'ClientStatus' THEN 1 WHEN 'ClientStatus2' THEN 2 WHEN 'ClientFlag' THEN 3 ELSE 4 END);

        -- LIS dimension filter columns â€” Augustus-specific mappings:
        --   Panels    -> PanelType (priority 0), then PanelName, PanelCategory ...
        --   Clinics   -> ClinicName
        --   Providers -> DoctorLastName + ', ' + DoctorFirstName (concatenated;
        --                matches the "LastName, FirstName" format used elsewhere)
        --   SalesRep  -> not available on LIMSMaster for Augustus
        DECLARE @LisPanelTypeCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PanelType','PanelName','PanelCategory','Panelname','TestPanel','Panel')
            ORDER BY CASE name
                WHEN 'PanelType'     THEN 0
                WHEN 'PanelName'     THEN 1
                WHEN 'PanelCategory' THEN 2
                WHEN 'Panelname'     THEN 3
                ELSE 4 END);

        DECLARE @LisClinicNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClinicName','Clinic','FacilityName','Facility')
            ORDER BY CASE name
                WHEN 'ClinicName' THEN 0 WHEN 'Clinic' THEN 1 WHEN 'FacilityName' THEN 2 ELSE 3 END);

        -- Referring Provider: fixed column pair (DoctorLastName, DoctorFirstName) â€”
        -- concatenated as 'LastName, FirstName' to match the Provider filter's format.
        DECLARE @LisDoctorLastNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'DoctorLastName');

        DECLARE @LisDoctorFirstNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'DoctorFirstName');

        -- FirstBilledDate: fixed column name on LIMSMaster (same name as ClaimLevelData's).
        DECLARE @LisBilledDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'FirstBilledDate');

        IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @BillToCol IS NOT NULL AND @BillingStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        BEGIN
            DECLARE @CS1Expr NVARCHAR(400) = CASE WHEN @ClientStatus1Col IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatus1Col + N']), '''')))'
                ELSE N'''''' END;

            DECLARE @PanelTypeExpr NVARCHAR(400) = CASE WHEN @LisPanelTypeCol IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @LisPanelTypeCol + N']), '''')))'
                ELSE N'''''' END;

            DECLARE @LisProviderExpr NVARCHAR(500) = CASE WHEN @LisDoctorLastNameCol IS NOT NULL AND @LisDoctorFirstNameCol IS NOT NULL
                THEN N'(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @LisDoctorLastNameCol + N']), ''''))) + '', '' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @LisDoctorFirstNameCol + N']), ''''))))'
                ELSE NULL END;

            -- LIS period basis:
            --   DOS mode (default)   â†’ TRY_CAST([<ReqCollectDate col>] AS DATE)
            --   FirstBilledDate mode â†’ TRY_CAST([FirstBilledDate] AS DATE)
            DECLARE @LisPeriodExpr NVARCHAR(200) =
                CASE WHEN @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
                     THEN N'TRY_CAST([' + @LisBilledDateCol + N'] AS DATE)'
                     ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;

            -- Dimension filters applied: Panelsâ†’PanelType, Clinicsâ†’ClinicName,
            -- Providersâ†’DoctorLastName+', '+DoctorFirstName. SalesRep not applied to LIS.
            DECLARE @LisSql NVARCHAR(MAX) = N'
                INSERT INTO #Lis (Accession, BillTo, BillingStatus, FinalStatus, ClientStatus1, PanelType, BillYear, BillMonth)
                SELECT
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
                    LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
                    ' + @CS1Expr + N',
                    ' + @PanelTypeExpr + N',
                    ISNULL(YEAR (' + @LisPeriodExpr + N'), 0),
                    ISNULL(MONTH(' + @LisPeriodExpr + N'), 0)
                FROM dbo.LIMSMaster
                WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL';

            -- Date predicate: DOS mode filters/bounds on @DateCol (ReqCollectDate);
            -- FirstBilledDate mode filters/bounds on FirstBilledDate.
            IF @UseBilledDate = 1 AND @LisBilledDateCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iBilledFrom IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) >= @iBilledFrom)
                  AND (@iBilledTo   IS NULL OR TRY_CAST([' + @LisBilledDateCol + N'] AS DATE) <= @iBilledTo)';
            ELSE
                SET @LisSql = @LisSql + N'
                  AND (@iDosFrom IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) >= @iDosFrom)
                  AND (@iDosTo   IS NULL OR TRY_CAST([' + @DateCol + N'] AS DATE) <= @iDosTo)';

            -- Panel filter: Panels â†’ PanelType
            IF @LisPanelTypeCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasPanelFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisPanelTypeCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iPanels + '','') > 0)';

            -- Clinic filter: Clinics â†’ ClinicName
            IF @LisClinicNameCol IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasClinicFilter = 0 OR CHARINDEX('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200),[' + @LisClinicNameCol + N']),''''))) COLLATE DATABASE_DEFAULT + '','', '','' + @iClinics + '','') > 0)';

            -- Provider filter: Providers â†’ DoctorLastName + ', ' + DoctorFirstName
            IF @LisProviderExpr IS NOT NULL
                SET @LisSql = @LisSql + N'
                  AND (@iHasProviderFilter = 0 OR CHARINDEX('','' + ' + @LisProviderExpr + N' COLLATE DATABASE_DEFAULT + '','', '','' + @iProviders + '','') > 0)';

            SET @LisSql = @LisSql + N';';

            EXEC sp_executesql @LisSql,
                N'@iHasPanelFilter    BIT,           @iPanels    NVARCHAR(MAX),
                  @iHasClinicFilter   BIT,           @iClinics   NVARCHAR(MAX),
                  @iHasProviderFilter BIT,           @iProviders NVARCHAR(MAX),
                  @iDosFrom DATE, @iDosTo DATE, @iBilledFrom DATE, @iBilledTo DATE',
                @iHasPanelFilter    = @HasPanelFilter,    @iPanels    = @Panels,
                @iHasClinicFilter   = @HasClinicFilter,   @iClinics   = @Clinics,
                @iHasProviderFilter = @HasProviderFilter, @iProviders = @Providers,
                @iDosFrom = @DosFrom, @iDosTo = @DosTo, @iBilledFrom = @BilledFrom, @iBilledTo = @BilledTo;
        END
    END

    -- â”€â”€ PMS/Cash/Avg: build #Base from dbo.ClaimLevelData, date-filtered â”€â”€â”€â”€
    -- BillYear/BillMonth added so the filtered path produces month-wise rows.
    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        AccessionNumber      NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        BillYear             INT           NOT NULL,
        BillMonth            INT           NOT NULL,
        BillStatus           NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus          NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        Source               NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        FirstBilledDate      DATE          NULL,
        ChargeAmount         DECIMAL(18,2) NOT NULL,
        InsurancePayment     DECIMAL(18,2) NOT NULL,
        PatientPayment       DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance     DECIMAL(18,2) NOT NULL,
        PatientBalance       DECIMAL(18,2) NOT NULL
    );

    -- PMS/Cash/Avg period basis now follows the same DOS vs FirstBilledDate mode as
    -- LIS (@UseBilledDate). Previously BillYear/BillMonth were ALWAYS derived from
    -- DateofService even when filtering by FirstBilledDate â€” a claim billed within
    -- the selected FirstBilledDate range but with an out-of-range DateofService
    -- still got bucketed under its (unrelated) DOS year/month, showing under the
    -- wrong "DATA BASED ON BILLED DATE" column (same bug fixed for RisingTides).
    -- Fixed by branching the period expression + date bound on @UseBilledDate,
    -- mirroring Cove/Elixir/RisingTides' #Base construction.
    IF @UseBilledDate = 0
    BEGIN
        INSERT INTO #Base (AccessionNumber, BillYear, BillMonth, BillStatus, ClaimStatus, Source, FirstBilledDate,
                            ChargeAmount, InsurancePayment, PatientPayment,
                            InsuranceAdjustments, PatientAdjustments,
                            InsuranceBalance, PatientBalance)
        SELECT
            AccessionNumber,
            -- Period bucket: DateofService when it's parseable; when it's not AND
            -- no explicit DOS range was requested (@HasDosFilter=0), fall back to
            -- FirstBilledDate so the row isn't lost from every PMS/Cash/Avg row.
            ISNULL(YEAR (COALESCE(TRY_CAST(DateofService AS DATE),
                                   CASE WHEN @HasDosFilter = 0 THEN TRY_CAST(FirstBilledDate AS DATE) END)), 0),
            ISNULL(MONTH(COALESCE(TRY_CAST(DateofService AS DATE),
                                   CASE WHEN @HasDosFilter = 0 THEN TRY_CAST(FirstBilledDate AS DATE) END)), 0),
            ISNULL(LTRIM(RTRIM(BillingStatus)),  ''),
            ISNULL(LTRIM(RTRIM(ClaimStatus)),    ''),
            ISNULL(LTRIM(RTRIM(Source)),         ''),
            TRY_CAST(FirstBilledDate AS DATE),
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
        FROM dbo.ClaimLevelData
        -- Base gate: a row qualifies if DateofService is parseable (as before), OR
        -- â€” only when no explicit DOS range was requested â€” if FirstBilledDate is
        -- parseable. Without this OR, a claim with a valid FirstBilledDate but a
        -- blank/unparseable DateofService was silently excluded from #Base
        -- entirely whenever any non-date filter (Clinic, Provider, Panel, Rep) was
        -- applied with no date range set, undercounting Row F/F.1/F.2/G (and every
        -- other PMS/Cash/Avg row) relative to a raw ClaimLevelData count.
        WHERE (
                TRY_CAST(DateofService AS DATE) IS NOT NULL
                OR (@HasDosFilter = 0 AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL)
              )
          AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
          AND (ISNULL(@YearFrom,0)=0  OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
          AND (ISNULL(@YearTo,0)=0    OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
          AND (ISNULL(@MonthFrom,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
          AND (ISNULL(@MonthTo,0)=0   OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
          AND (@DosFrom    IS NULL OR TRY_CAST(DateofService AS DATE) >= @DosFrom)
          AND (@DosTo      IS NULL OR TRY_CAST(DateofService AS DATE) <= @DosTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Panels + ',') > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Clinics + ',') > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Providers + ',') > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Reps + ',') > 0);
    END
    ELSE  -- @UseBilledDate = 1 : period + filter on FirstBilledDate
    BEGIN
        -- NOTE: FirstBilledDate must be included here (it was previously omitted
        -- from this branch's column/select list, which left #Base.FirstBilledDate
        -- NULL for every row in Billed-Date mode â€” even though every row here, by
        -- definition of the WHERE clause below, has a non-null FirstBilledDate in
        -- the selected range). That gap made PMS row F "No. of Billed Claims"
        -- always read 0 and row G "No. of Unbilled Claims" always read the full
        -- claim count when filtering by Billed Date.
        INSERT INTO #Base (AccessionNumber, BillYear, BillMonth, BillStatus, ClaimStatus, Source, FirstBilledDate,
                            ChargeAmount, InsurancePayment, PatientPayment,
                            InsuranceAdjustments, PatientAdjustments,
                            InsuranceBalance, PatientBalance)
        SELECT
            AccessionNumber,
            ISNULL(YEAR (TRY_CAST(FirstBilledDate AS DATE)), 0),
            ISNULL(MONTH(TRY_CAST(FirstBilledDate AS DATE)), 0),
            ISNULL(LTRIM(RTRIM(BillingStatus)),  ''),
            ISNULL(LTRIM(RTRIM(ClaimStatus)),    ''),
            ISNULL(LTRIM(RTRIM(Source)),         ''),
            TRY_CAST(FirstBilledDate AS DATE),
            ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
            ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
          AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
          AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
          AND (@HasPanelFilter    = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(Panelname,         ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Panels + ',') > 0)
          AND (@HasClinicFilter   = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ClinicName,        ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Clinics + ',') > 0)
          AND (@HasProviderFilter = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(ReferringProvider, ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Providers + ',') > 0)
          AND (@HasRepFilter      = 0 OR CHARINDEX(',' + LTRIM(RTRIM(ISNULL(SalesRepname,      ''))) COLLATE DATABASE_DEFAULT + ',', ',' + @Reps + ',') > 0)
        OPTION (RECOMPILE);
    END

    -- â”€â”€ Populate #LisOut: aggregate (fast path) or live from #Lis (filtered path) â”€â”€
    -- When @HasLisFilter = 0 (SalesRep-only filter), LIMSMaster was not scanned
    -- above; LIS rows are served from the pre-built aggregate to stay responsive.
    DROP TABLE IF EXISTS #LisOut;
    CREATE TABLE #LisOut
    (
        RowCode     NVARCHAR(420) NOT NULL,
        Description NVARCHAR(420) NOT NULL,
        BillYear    INT           NOT NULL,
        BillMonth   INT           NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL
    );

    IF @HasLisFilter = 0
    BEGIN
        -- No LIS-applicable filter â€” serve directly from aggregate (fast)
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
        FROM dbo.Augustus_ES_LIS;
    END
    ELSE
    BEGIN
        -- LIS-applicable filter(s) active â€” build from #Lis (live LIMSMaster data)
        -- new RoleID scheme: A=Total Samples, B=Billable, B1.x=panel sub-rows,
        -- B2.1/B2.2=billed/unbilled, C-F=other bill categories.
        ;WITH Lis AS
        (
            -- A  Total Samples (all accessions)
            SELECT 'A' AS RowCode, 'Total Samples' AS Description, BillYear, BillMonth,
               CAST(COUNT(Accession) AS DECIMAL(18,2)) AS MetricValue
        FROM #Lis GROUP BY BillYear, BillMonth
        -- B  Billable Samples (Insurance)
        UNION ALL
        SELECT 'B', 'Billable Samples', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- B2.1  Billed
        UNION ALL
        SELECT 'B2.1', '  Billed (First Billed Date = Date AND Billed Amount <> 0)', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.1.1', '    Claim Submitted in IRCM (First Billed Date = Date AND Billed Amount <> 0 AND Source = IRCM)', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Billed' AND FinalStatus='Claim Submitted in IRCM' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.1.2', '    Claim Submitted in Daqbilling (First Billed Date = Date AND Billed Amount <> 0 AND Source = Daq)', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Billed' AND FinalStatus='Claim Submitted in Daqbilling' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- B2.2  Unbilled
        UNION ALL
        SELECT 'B2.2', '  Unbilled (First Billed Date = Blank AND Billed Amount <> 0)', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Unbilled' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.2.1', '    Resulted yet to be billed', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Unbilled' AND FinalStatus='Resulted yet to be billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.2.1*', '      Ready to bill', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Unbilled' AND FinalStatus='Resulted yet to be billed' AND ClientStatus1='Ready to bill' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'B2.2.2', '    Insurance name not listed', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' AND BillingStatus='Unbilled' AND FinalStatus='Insurance Name Not Listed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- C  Yet to be Validated
        UNION ALL
        SELECT 'C', 'Yet to be Validated', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo='Yet to be Validated' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'C.1', '  Billed', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo='Yet to be Validated' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- D  Client Bills
        UNION ALL
        SELECT 'D', 'Client Bills', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo='Client Bills' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'D.1', '  Billed', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo='Client Bills' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- E  System Test
        UNION ALL
        SELECT 'E', 'System Test', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo='System Test' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'E.1', '  Billed', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo='System Test' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        -- F  Self pay
        UNION ALL
        SELECT 'F', 'Self pay', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo='Self pay' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.1', '  Billed', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo='Self pay' AND BillingStatus='Billed' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis GROUP BY BillYear, BillMonth
        )
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT RowCode, Description, BillYear, BillMonth, MetricValue FROM Lis;

        -- B1.x  Panel sub-rows under B (Billable Samples / Insurance)
        INSERT INTO #LisOut (RowCode, Description, BillYear, BillMonth, MetricValue)
        SELECT 'B1.' + LTRIM(RTRIM(PanelType)), '  ' + LTRIM(RTRIM(PanelType)),
               BillYear, BillMonth,
               CAST(COUNT(CASE WHEN BillTo LIKE '%Insurance%' THEN Accession END) AS DECIMAL(18,2))
        FROM #Lis
        WHERE BillTo LIKE '%Insurance%' AND LTRIM(RTRIM(PanelType)) <> ''
        GROUP BY LTRIM(RTRIM(PanelType)), BillYear, BillMonth;
    END

    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  PMS  -  F, F.1, F.2, G, H, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    ;WITH PMS AS
    (
        -- F/F.1/F.2/G determine Billed vs Unbilled from whether FirstBilledDate is
        -- populated (native DATE column on #Base) rather than the BillStatus text
        -- field. IS NOT NULL / IS NULL is used directly instead of comparing to ''
        -- (which would force an implicit, fragile empty-string-to-DATE conversion).
        SELECT 'F' AS RowCode, 'No. of Billed Claims' AS Description, BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2)) AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.1', '  No. of Claims Billed in IRCM', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' AND Source='IRCM' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'F.2', '  No. of Claims Billed in Daq Billing', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NOT NULL AND ClaimStatus<>'Billed amount 0' AND Source='Daq' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'G', 'No. of Unbilled Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN FirstBilledDate IS NULL AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'H', 'Client bill claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Billed amount 0' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'I', 'No. of Fully Paid Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'J', 'No. of Patient Paid Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Patient paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'K', 'No. of Patient Responsibility Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Pat Responsibility' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'L', 'No. of Partially Paid Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Partial Paid' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'M', 'No. of Adjusted/Written Off Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Fully Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'N', 'No. of Partially Adjusted/Written Off Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Partially Adjusted' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O', 'No. of Insurance Balance Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.1', '  No. of Fully Denied Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Fully Denied' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.2', '  No. of Partially Denied Claims', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='Partially Denied' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'O.3', '  No. of No Response from Payor', BillYear, BillMonth,
               CAST(COUNT(CASE WHEN ClaimStatus='No Response' THEN AccessionNumber END) AS DECIMAL(18,2))
        FROM #Base GROUP BY BillYear, BillMonth
    ),
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  Cash  -  P, P.1, P.2, Q, R, S, T, U, U.1, U.2, V, W, X, X.1, X.2, X.3
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    Cash AS
    (
        SELECT 'P' AS RowCode, 'Total Billed ($)' AS Description, BillYear, BillMonth,
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END) AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'P.1', '  Total Charge of Claims Billed (IRCM)', BillYear, BillMonth,
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='IRCM' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'P.2', '  Total Charge of Claims Billed (Daq)', BillYear, BillMonth,
               SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' AND Source='Daq' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'Q', 'Total Unbilled ($)', BillYear, BillMonth,
               SUM(CASE WHEN (BillStatus='' OR BillStatus IS NULL) AND ClaimStatus<>'Billed amount 0' THEN ChargeAmount ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'R', 'Insurance Payment ($)', BillYear, BillMonth,
               SUM(CASE WHEN InsurancePayment > 0 AND ClaimStatus='Fully Paid' THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'S', 'Partially Paid ($)', BillYear, BillMonth,
               SUM(CASE WHEN ClaimStatus='Partial Paid' THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'T', 'Patient Paid ($)', BillYear, BillMonth,
               SUM(CASE WHEN PatientPayment > 0 THEN PatientPayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U', 'Patient Responsibility ($)', BillYear, BillMonth,
               SUM(CASE WHEN PatientBalance > 0 THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U.1', '  Daqbilling', BillYear, BillMonth,
               SUM(CASE WHEN PatientBalance > 0 AND Source='Daq' THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'U.2', '  IRCM', BillYear, BillMonth,
               SUM(CASE WHEN PatientBalance > 0 AND Source='IRCM' THEN PatientBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'V', 'Adjustment amount ($)', BillYear, BillMonth,
               SUM(InsuranceAdjustments + PatientAdjustments)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'W', 'Total Payments ($) - Insurance', BillYear, BillMonth,
               SUM(CASE WHEN InsurancePayment > 0 THEN InsurancePayment ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X', 'Insurance Balance ($)', BillYear, BillMonth,
               SUM(CASE WHEN InsuranceBalance > 0 AND ClaimStatus IN ('Partially Denied','Fully Denied','No Response','Partial Paid') THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.1', '  Fully Denied', BillYear, BillMonth,
               SUM(CASE WHEN InsuranceBalance > 0 AND ClaimStatus='Fully Denied' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.2', '  Partially Denied', BillYear, BillMonth,
               SUM(CASE WHEN InsuranceBalance > 0 AND ClaimStatus IN ('Partially Denied','Partial Paid') THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
        UNION ALL
        SELECT 'X.3', '  No Response from Payor', BillYear, BillMonth,
               SUM(CASE WHEN InsuranceBalance > 0 AND ClaimStatus='No Response' THEN InsuranceBalance ELSE 0 END)
        FROM #Base GROUP BY BillYear, BillMonth
    ),
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    --  Avg  -  Y, Z, AA
    -- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    AvgRows AS
    (
        SELECT 'Y' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description, BillYear, BillMonth,
               CASE WHEN COUNT(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(CASE WHEN BillStatus='Billed' AND ClaimStatus<>'Billed amount 0' THEN AccessionNumber END)
                    ELSE 0 END AS MetricValue
        FROM #Base GROUP BY BillYear, BillMonth

        UNION ALL
        SELECT 'Z', 'Average Payment ($) - Total Pay/Paid Claims', BillYear, BillMonth,
               CASE WHEN COUNT(CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN ClaimStatus='Fully Paid' THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(CASE WHEN ClaimStatus='Fully Paid' THEN AccessionNumber END)
                    ELSE 0 END
        FROM #Base GROUP BY BillYear, BillMonth

        UNION ALL
        SELECT 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims', BillYear, BillMonth,
               CASE WHEN COUNT(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END) > 0
                    THEN SUM(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN InsurancePayment + PatientPayment ELSE 0 END)
                         / COUNT(CASE WHEN ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN AccessionNumber END)
                    ELSE 0 END
        FROM #Base GROUP BY BillYear, BillMonth
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM
    (
        SELECT RowCode, 'LIS'  AS Category, Description, BillYear, BillMonth, MetricValue, 1 AS CatOrder FROM #LisOut
        UNION ALL
        SELECT RowCode, 'PMS',  Description, BillYear, BillMonth, MetricValue, 2 FROM PMS
        UNION ALL
        SELECT RowCode, 'Cash', Description, BillYear, BillMonth, MetricValue, 3 FROM Cash
        UNION ALL
        SELECT RowCode, 'Avg',  Description, BillYear, BillMonth, MetricValue, 4 FROM AvgRows
    ) result
    ORDER BY BillYear, BillMonth, CatOrder, RowCode;

    DROP TABLE IF EXISTS #LisOut;
    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '17_Augustus_ExecutiveSummary_Read_v2 completed.';
GO



GO


-- ============================================================
-- Augustus â€“ Executive Summary Detail (Drill-Down) SP
-- File : 18_Augustus_ExecutiveSummary_Detail.sql
-- DB   : Augustus_LRN
--
-- Mirrors Cove\18_Cove_ExecutiveSummary_Detail.sql.
--
--   @Category = 'PMS' | 'Cash'  -> dbo.ClaimLevelData
--   @Category = 'LIS'           -> dbo.LIMSMaster (date col: ReqCollectDate)
--
-- Parameters
--   @Category â€“ 'PMS' | 'Cash' | 'LIS'
--   @RowCode  â€“ PMS:  F,F.1,F.2,G,H,I,J,K,L,M,N,O,O.1,O.2,O.3
--               Cash: P,P.1,P.2,Q,R,S,T,U,U.1,U.2,V,W,X,X.1,X.2,X.3
--               LIS:  A,A.1,A.1.1,A.1.2,A.2,A.2.1,A.2.1*,A.2.2,
--                     B,B.1,C,C.1,D,D.1,E,E.1
--   @Year     â€“ calendar year  (0 = all years)
--   @Month    â€“ calendar month (0 = all months)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAug_ExecutiveSummary_Detail_v2
(
    @Category NVARCHAR(10),
    @RowCode  NVARCHAR(20),
    @Year     INT = 0,
    @Month    INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    --  PMS / Cash  -  source: dbo.ClaimLevelData
    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    IF @Category IN ('PMS','Cash')
    BEGIN
        DROP TABLE IF EXISTS #Base;

        SELECT
            AccessionNumber,
            LTRIM(RTRIM(ISNULL(PatientName,     '')))  AS PatientName,
            LTRIM(RTRIM(ISNULL(PayerName,       '')))  AS PayerName,
            ISNULL(LTRIM(RTRIM(Panelname)), '')        AS Panelname,
            LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
            LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
            DateofService,
            FirstBilledDate,
            ISNULL(LTRIM(RTRIM(BillingStatus)),  '')      AS BillStatus,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), '')      AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(PayerType)), '')        AS PayerType,
            ISNULL(LTRIM(RTRIM(Source)), '')           AS Source,
            ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
            ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
            ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
            ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
            ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
            ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments
        INTO #Base
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
          AND (@Year=0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
          AND (@Month=0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

        SELECT DISTINCT
            b.AccessionNumber AS VisitNumber,
            b.PatientName,
            b.PayerName,
            b.Panelname        AS PanelName,
            b.ClinicName,
            b.BillingProvider,
            b.DateofService,
            b.FirstBilledDate,
            b.BillStatus,
            b.ClaimStatus,
            b.PayerType,
            b.Source,
            b.ChargeAmount,
            b.InsurancePayment,
            b.PatientPayment,
            b.InsuranceBalance,
            b.PatientBalance,
            b.InsuranceAdjustments,
            b.PatientAdjustments
        FROM #Base b
        WHERE
            -- â”€â”€ PMS (same predicates as usp_RefreshAug_ExecutiveSummary) â”€â”€
               (@RowCode = 'F'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'F.1'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM')
            OR (@RowCode = 'F.2'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq')
            OR (@RowCode = 'G'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') = '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'H'    AND b.ClaimStatus='Billed amount 0')
            OR (@RowCode = 'I'    AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'J'    AND b.ClaimStatus='Patient paid')
            OR (@RowCode = 'K'    AND b.ClaimStatus='Pat Responsibility')
            OR (@RowCode = 'L'    AND b.ClaimStatus='Partial Paid')
            OR (@RowCode = 'M'    AND b.ClaimStatus='Fully Adjusted')
            OR (@RowCode = 'N'    AND b.ClaimStatus='Partially Adjusted')
            OR (@RowCode = 'O'    AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response'))
            OR (@RowCode = 'O.1'  AND b.ClaimStatus='Fully Denied')
            OR (@RowCode = 'O.2'  AND b.ClaimStatus='Partially Denied')
            OR (@RowCode = 'O.3'  AND b.ClaimStatus='No Response')
            -- â”€â”€ Cash â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            OR (@RowCode = 'P'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'P.1'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM')
            OR (@RowCode = 'P.2'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq')
            OR (@RowCode = 'Q'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') = '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'R'    AND b.InsurancePayment > 0 AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'S'    AND b.ClaimStatus='Partial Paid')
            OR (@RowCode = 'T'    AND b.PatientPayment > 0)
            OR (@RowCode = 'U'    AND b.PatientBalance > 0)
            OR (@RowCode = 'U.1'  AND b.PatientBalance > 0 AND b.Source='Daq')
            OR (@RowCode = 'U.2'  AND b.PatientBalance > 0 AND b.Source='IRCM')
            OR (@RowCode = 'V'    AND 1=1)   -- all rows contribute to adjustments
            OR (@RowCode = 'W'    AND b.InsurancePayment > 0)
            OR (@RowCode = 'X'    AND b.InsuranceBalance > 0 AND b.ClaimStatus IN ('Partially Denied','Fully Denied','No Response','Partial Paid'))
            OR (@RowCode = 'X.1'  AND b.InsuranceBalance > 0 AND b.ClaimStatus='Fully Denied')
            OR (@RowCode = 'X.2'  AND b.InsuranceBalance > 0 AND b.ClaimStatus IN ('Partially Denied','Partial Paid'))
            OR (@RowCode = 'X.3'  AND b.InsuranceBalance > 0 AND b.ClaimStatus='No Response')
            -- â”€â”€ Avg (return billed rows as reference) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            OR (@RowCode = 'Y'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0')
            OR (@RowCode = 'Z'    AND b.ClaimStatus='Fully Paid')
            OR (@RowCode = 'AA'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
        ORDER BY b.DateofService, b.AccessionNumber;

        DROP TABLE IF EXISTS #Base;
        RETURN;
    END

    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    --  LIS  -  source: dbo.LIMSMaster (ReqCollectDate, dynamic col detect)
    -- â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    IF @Category = 'LIS'
    BEGIN
        DROP TABLE IF EXISTS #Lis;
        CREATE TABLE #Lis
        (
            Accession        NVARCHAR(100) NOT NULL,
            ReqCollectDate   DATE          NULL,
            BillTo           NVARCHAR(200) NOT NULL,
            BillingStatus    NVARCHAR(200) NOT NULL,
            FinalStatus      NVARCHAR(200) NOT NULL,
            ClientStatus1    NVARCHAR(200) NOT NULL,
            PatientName      NVARCHAR(200) NOT NULL,
            ClientName       NVARCHAR(200) NOT NULL
        );

        IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
        BEGIN
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber, CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName, CAST(NULL AS DATE) AS ReqCollectDate,
                CAST(NULL AS NVARCHAR(200)) AS BillTo, CAST(NULL AS NVARCHAR(200)) AS BillingStatus,
                CAST(NULL AS NVARCHAR(200)) AS FinalStatus, CAST(NULL AS NVARCHAR(200)) AS ClientStatus1;
            RETURN;
        END

        DECLARE @AccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','Accession','AccessionNo')
            ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

        DECLARE @DateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'ReqCollectDate' THEN 0 WHEN 'RequestCollectDate' THEN 1
                WHEN 'DateOfCollection' THEN 2 WHEN 'DateofService' THEN 3
                WHEN 'CollectionDate' THEN 4 WHEN 'ServiceDate' THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

        DECLARE @BillToCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillTo','BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
            ORDER BY CASE name WHEN 'BillTo' THEN 0 WHEN 'BillCategory' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BilledorNot' THEN 4 WHEN 'BillStatus' THEN 5 ELSE 6 END);

        DECLARE @BillingStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('BillingStatus','NewStatus','Status','BillStatus')
            ORDER BY CASE name WHEN 'BillingStatus' THEN 0 WHEN 'NewStatus' THEN 1 WHEN 'Status' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

        DECLARE @FinalStatusCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('FinalStatus','SubStatus','Sub_Status','ClientStatus')
            ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'SubStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

        DECLARE @ClientStatus1Col SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClientStatus1','ClientStatus','ClientStatus2','ClientFlag')
            ORDER BY CASE name WHEN 'ClientStatus1' THEN 0 WHEN 'ClientStatus' THEN 1 WHEN 'ClientStatus2' THEN 2 WHEN 'ClientFlag' THEN 3 ELSE 4 END);

        DECLARE @PatientNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('PatientName','Patient_Name','PatientFullName')
            ORDER BY CASE name WHEN 'PatientName' THEN 0 WHEN 'Patient_Name' THEN 1 WHEN 'PatientFullName' THEN 2 ELSE 3 END);

        DECLARE @ClientNameCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('ClientName','Client_Name','ClinicName','Client')
            ORDER BY CASE name WHEN 'ClientName' THEN 0 WHEN 'Client_Name' THEN 1 WHEN 'ClinicName' THEN 2 WHEN 'Client' THEN 3 ELSE 4 END);

        IF @AccCol IS NULL OR @DateCol IS NULL OR @BillToCol IS NULL OR @BillingStatusCol IS NULL OR @FinalStatusCol IS NULL
        BEGIN
            PRINT 'usp_GetAug_ExecutiveSummary_Detail: required LIMSMaster columns not found.';
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS VisitNumber, CAST(NULL AS NVARCHAR(200)) AS PatientName,
                CAST(NULL AS NVARCHAR(200)) AS ClientName, CAST(NULL AS DATE) AS ReqCollectDate,
                CAST(NULL AS NVARCHAR(200)) AS BillTo, CAST(NULL AS NVARCHAR(200)) AS BillingStatus,
                CAST(NULL AS NVARCHAR(200)) AS FinalStatus, CAST(NULL AS NVARCHAR(200)) AS ClientStatus1;
            RETURN;
        END

        DECLARE @CS1Expr NVARCHAR(400) = CASE WHEN @ClientStatus1Col IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientStatus1Col + N']), '''')))'
            ELSE N'''''' END;
        DECLARE @PatientNameExpr NVARCHAR(300) = CASE WHEN @PatientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PatientNameCol + N']), '''')))'
            ELSE N'''''' END;
        DECLARE @ClientNameExpr NVARCHAR(300) = CASE WHEN @ClientNameCol IS NOT NULL
            THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @ClientNameCol + N']), '''')))'
            ELSE N'''''' END;

        DECLARE @LisSql NVARCHAR(MAX) = N'
            INSERT INTO #Lis (Accession, ReqCollectDate, BillTo, BillingStatus, FinalStatus, ClientStatus1, PatientName, ClientName)
            SELECT
                LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
                TRY_CAST([' + @DateCol + N'] AS DATE),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
                LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
                ' + @CS1Expr + N',
                ' + @PatientNameExpr + N',
                ' + @ClientNameExpr + N'
            FROM dbo.LIMSMaster
            WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
              AND (@iYear=0  OR YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)) = @iYear)
              AND (@iMonth=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)) = @iMonth);';

        EXEC sp_executesql @LisSql,
            N'@iYear INT, @iMonth INT',
            @iYear=@Year, @iMonth=@Month;

        SELECT DISTINCT
            l.Accession        AS VisitNumber,
            l.PatientName,
            l.ClientName,
            l.ReqCollectDate,
            l.BillTo,
            l.BillingStatus,
            l.FinalStatus,
            l.ClientStatus1
        FROM #Lis l
        WHERE
               (@RowCode = 'A')
            OR (@RowCode = 'A.1'    AND l.BillTo='Insurance Bills' AND l.BillingStatus='Billed')
            OR (@RowCode = 'A.1.1'  AND l.BillTo='Insurance Bills' AND l.BillingStatus='Billed' AND l.FinalStatus='Claim Submitted in IRCM')
            OR (@RowCode = 'A.1.2'  AND l.BillTo='Insurance Bills' AND l.BillingStatus='Billed' AND l.FinalStatus='Claim Submitted in Daqbilling')
            OR (@RowCode = 'A.2'    AND l.BillTo='Insurance Bills' AND l.BillingStatus='Unbilled')
            OR (@RowCode = 'A.2.1'  AND l.BillTo='Insurance Bills' AND l.BillingStatus='Unbilled' AND l.FinalStatus='Resulted yet to be billed')
            OR (@RowCode = 'A.2.1*' AND l.BillTo='Insurance Bills' AND l.BillingStatus='Unbilled' AND l.FinalStatus='Resulted yet to be billed' AND l.ClientStatus1='Ready to bill')
            OR (@RowCode = 'A.2.2'  AND l.BillTo='Insurance Bills' AND l.BillingStatus='Unbilled' AND l.FinalStatus='Insurance Name Not Listed')
            OR (@RowCode = 'B'      AND l.BillTo='Yet to be Validated')
            OR (@RowCode = 'B.1'    AND l.BillTo='Yet to be Validated' AND l.BillingStatus='Billed')
            OR (@RowCode = 'C'      AND l.BillTo='Client Bills')
            OR (@RowCode = 'C.1'    AND l.BillTo='Client Bills' AND l.BillingStatus='Billed')
            OR (@RowCode = 'D'      AND l.BillTo='System Test')
            OR (@RowCode = 'D.1'    AND l.BillTo='System Test' AND l.BillingStatus='Billed')
            OR (@RowCode = 'E'      AND l.BillTo='Self pay')
            OR (@RowCode = 'E.1'    AND l.BillTo='Self pay' AND l.BillingStatus='Billed')
        ORDER BY l.ReqCollectDate, l.Accession;

        DROP TABLE IF EXISTS #Lis;
        RETURN;
    END
END;
GO

PRINT '18_Augustus_ExecutiveSummary_Detail.sql completed.';
GO



GO


-- ============================================================
-- Augustus â€“ Executive Summary PMS / Cash Detail-Rows SP (generic name)
-- File : 21_Augustus_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : Augustus_LRN
--
-- Mirrors Cove\21_Cove_ExecutiveSummaryDetailRows_PMSCash.sql.
-- Uses the GENERIC (non lab-prefixed) procedure name
-- dbo.usp_GetExecutiveSummaryDetail_PMSCash, called by
-- ExecutiveSummaryController.Detail for ANY lab's 'PMS'/'Cash' categories.
--
-- Returns the underlying dbo.ClaimLevelData rows that drive a given
-- PMS RowCode (F, F.1, F.2, G, H, I, J, K, L, M, N, O, O.1, O.2, O.3) or
-- Cash RowCode (P, P.1, P.2, Q, R, S, T, U, U.1, U.2, V, W, X, X.1, X.2, X.3)
-- or Avg RowCode (Y, Z, AA) from the Executive Summary.
--
-- Same predicates as 16_Augustus_ExecutiveSummary_Aggregate.sql /
-- 17_Augustus_ExecutiveSummary_Read.sql / 18_Augustus_ExecutiveSummary_Detail.sql.
--
-- Augustus uses a 'Source' column (IRCM / Daq) in ClaimLevelData for F.1/F.2,
-- P.1/P.2, U.1/U.2 sub-rows.
--
-- @Year/@Month: 0 = all years / all months (matches grand-total period)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PMSCash_v2
(
    @Category NVARCHAR(10),
    @RowCode  NVARCHAR(20),
    @Year     INT = 0,
    @Month    INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        LTRIM(RTRIM(ISNULL(PatientName,     '')))  AS PatientName,
        LTRIM(RTRIM(ISNULL(PayerName,       '')))  AS PayerName,
        ISNULL(LTRIM(RTRIM(Panelname)), '')        AS Panelname,
        LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
        LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
        DateofService,
        FirstBilledDate,
        ISNULL(LTRIM(RTRIM(BilledStatus)),  '')      AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')      AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(PayerType)), '')        AS PayerType,
        ISNULL(LTRIM(RTRIM(Source)), '')           AS Source,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
      AND (@Year=0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
      AND (@Month=0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

    SELECT DISTINCT
        b.AccessionNumber AS VisitNumber,
        b.PatientName,
        b.PayerName,
        b.Panelname        AS PanelName,
        b.ClinicName,
        b.BillingProvider,
        b.DateofService,
        b.FirstBilledDate,
        b.BillStatus,
        b.ClaimStatus,
        b.PayerType,
        b.Source,
        b.ChargeAmount,
        b.InsurancePayment,
        b.PatientPayment,
        b.InsuranceBalance,
        b.PatientBalance,
        b.InsuranceAdjustments,
        b.PatientAdjustments
    FROM #Base b
    WHERE
        -- â”€â”€ PMS (same predicates as usp_RefreshAug_ExecutiveSummary) â”€â”€â”€â”€â”€â”€â”€â”€â”€
           (@RowCode = 'F'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'F.1'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM')
        OR (@RowCode = 'F.2'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq')
        OR (@RowCode = 'G'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') = '' AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'H'    AND b.ClaimStatus='Billed amount 0')
        OR (@RowCode = 'I'    AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'J'    AND b.ClaimStatus='Patient paid')
        OR (@RowCode = 'K'    AND b.ClaimStatus='Pat Responsibility')
        OR (@RowCode = 'L'    AND b.ClaimStatus='Partial Paid')
        OR (@RowCode = 'M'    AND b.ClaimStatus='Fully Adjusted')
        OR (@RowCode = 'N'    AND b.ClaimStatus='Partially Adjusted')
        OR (@RowCode = 'O'    AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response'))
        OR (@RowCode = 'O.1'  AND b.ClaimStatus='Fully Denied')
        OR (@RowCode = 'O.2'  AND b.ClaimStatus='Partially Denied')
        OR (@RowCode = 'O.3'  AND b.ClaimStatus='No Response')
        -- â”€â”€ Cash (FirstBilledDate for P/Q; amounts as aggregate) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        OR (@RowCode = 'P'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'P.1'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM')
        OR (@RowCode = 'P.2'  AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') <> '' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq')
        OR (@RowCode = 'Q'    AND ISNULL(LTRIM(RTRIM(CONVERT(NVARCHAR(50), b.FirstBilledDate))), '') = '' AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'R'    AND b.InsurancePayment > 0 AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'S'    AND b.ClaimStatus='Partial Paid')
        OR (@RowCode = 'T'    AND b.PatientPayment > 0)
        OR (@RowCode = 'U'    AND b.PatientBalance > 0)
        OR (@RowCode = 'U.1'  AND b.PatientBalance > 0 AND b.Source='Daq')
        OR (@RowCode = 'U.2'  AND b.PatientBalance > 0 AND b.Source='IRCM')
        OR (@RowCode = 'V'    AND 1=1)   -- all rows have adjustment amounts
        OR (@RowCode = 'W'    AND b.InsurancePayment > 0)
        OR (@RowCode = 'X'    AND b.InsuranceBalance > 0 AND b.ClaimStatus IN ('Partially Denied','Fully Denied','No Response','Partial Paid'))
        OR (@RowCode = 'X.1'  AND b.InsuranceBalance > 0 AND b.ClaimStatus='Fully Denied')
        OR (@RowCode = 'X.2'  AND b.InsuranceBalance > 0 AND b.ClaimStatus IN ('Partially Denied','Partial Paid'))
        OR (@RowCode = 'X.3'  AND b.InsuranceBalance > 0 AND b.ClaimStatus='No Response')
        -- â”€â”€ Avg (reference rows) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        OR (@RowCode = 'Y'    AND b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'Z'    AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'AA'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
    ORDER BY b.DateofService, b.AccessionNumber;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '21_Augustus_ExecutiveSummaryDetailRows_PMSCash_v2 completed.';
GO

-- ============================================================
-- LisDrillRowDef (Cash) — Augustus U / X predicates
-- Updates drill filters so Insight Cash drill matches v2 logic.
-- Does not touch other labs or other Augustus Cash rows (P–T, V, W).
-- ============================================================
IF OBJECT_ID('dbo.LisDrillRowDef', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.LisDrillRowDef', 'AmountCol') IS NOT NULL
BEGIN
    DELETE FROM dbo.LisDrillRowDef
    WHERE LabPrefix = N'Aug'
      AND Source    = N'Cash'
      AND RowCode IN (N'U', N'U.1', N'U.2', N'X', N'X.1', N'X.2', N'X.3');

    INSERT INTO dbo.LisDrillRowDef
        (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
         Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
    VALUES
     (N'Aug', N'U',   N'Patient Responsibility ($)', N'DateofService', N'Cash', N'PatientBalance',
         N'PatientBalance', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
     (N'Aug', N'U.1', N'Daqbilling', N'DateofService', N'Cash', N'PatientBalance',
         N'PatientBalance', N'>', N'0', N'Source', N'=', N'Daq', NULL,NULL,NULL, NULL,NULL,NULL),
     (N'Aug', N'U.2', N'IRCM', N'DateofService', N'Cash', N'PatientBalance',
         N'PatientBalance', N'>', N'0', N'Source', N'=', N'IRCM', NULL,NULL,NULL, NULL,NULL,NULL),
     (N'Aug', N'X',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
         N'InsuranceBalance', N'>', N'0', N'ClaimStatus', N'IN', N'Partially Denied,Fully Denied,No Response,Partial Paid', NULL,NULL,NULL, NULL,NULL,NULL),
     (N'Aug', N'X.1', N'Fully Denied', N'DateofService', N'Cash', N'InsuranceBalance',
         N'InsuranceBalance', N'>', N'0', N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL),
     (N'Aug', N'X.2', N'Partially Denied', N'DateofService', N'Cash', N'InsuranceBalance',
         N'InsuranceBalance', N'>', N'0', N'ClaimStatus', N'IN', N'Partially Denied,Partial Paid', NULL,NULL,NULL, NULL,NULL,NULL),
     (N'Aug', N'X.3', N'No Response from Payor', N'DateofService', N'Cash', N'InsuranceBalance',
         N'InsuranceBalance', N'>', N'0', N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL);

    UPDATE dbo.LisDrillRowDef SET
        Sec1Name = N'Fully Denied',     Sec1Col = N'ClaimStatus', Sec1Vals = N'Fully Denied',
        Sec2Name = N'Partially Denied', Sec2Col = N'ClaimStatus', Sec2Vals = N'Partially Denied,Partial Paid',
        Sec3Name = N'No Response',      Sec3Col = N'ClaimStatus', Sec3Vals = N'No Response'
    WHERE LabPrefix = N'Aug' AND Source = N'Cash' AND RowCode = N'X';
END
GO

PRINT '16c_Augustus_ExecutiveSummary_CashBreakdown_v2.sql completed.';
PRINT '  usp_RefreshAug_ExecutiveSummary_v2';
PRINT '  usp_GetAug_ExecutiveSummary_v2';
PRINT '  usp_GetAug_ExecutiveSummary_Detail_v2';
PRINT '  usp_GetExecutiveSummaryDetail_PMSCash_v2';
GO



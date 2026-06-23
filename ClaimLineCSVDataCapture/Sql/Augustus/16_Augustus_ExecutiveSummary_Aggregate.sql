-- ============================================================
-- Augustus – Executive Summary PMS / Cash / Avg Aggregate Refresh SP
-- File : 16_Augustus_ExecutiveSummary_Aggregate.sql
-- DB   : Augustus_LRN
--
-- Mirrors Cove\16_Cove_ExecutiveSummary_Aggregate.sql.
-- This SP owns and TRUNCATEs Augustus_ES_PMS, Augustus_ES_Cash, Augustus_ES_Avg.
-- Augustus_ES_LIS is owned by 19_Augustus_ExecutiveSummary_LIS_Alt.sql
-- (usp_RefreshAugustus_ExecutiveSummary_LIS_Alt), which sources from
-- dbo.LIMSMaster.
--
-- Source: dbo.ClaimLevelData, period bucket = DateofService (ESYear/ESMonth),
-- plus a (0,0) grand-total sentinel row.
--
-- RoleID scheme (from the "Billable Samples - PMS Breakdown" /
-- "Cash Breakdown" / "Average Payment Per Claim" spec images):
--
--   PMS Breakdown
--   F      No. of Billed Claims          -> BillingStatus = Billed AND ClaimStatus <> 'Billed amount 0'
--   F.1      No. of Claims Billed in IRCM   -> F AND Source = IRCM
--   F.2      No. of Claims Billed in Daq Billing -> F AND Source = Daq
--   G      No. of Unbilled Claims         -> BillingStatus = Blank AND ClaimStatus <> 'Billed amount 0'
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
--   P      Total Billed ($)              -> Billed = Billed AND ClaimStatus <> 'Billed amount 0'; SUM(ChargeAmount)
--   P.1      Total Charge of Claims Billed (IRCM) -> P AND Source = IRCM
--   P.2      Total Charge of Claims Billed (Daq)  -> P AND Source = Daq
--   Q      Total Unbilled ($)            -> Billed = Blank AND ClaimStatus <> 'Billed amount 0'; SUM(ChargeAmount)
--   R      Insurance Payment ($)         -> Ins. Payment > 0 AND ClaimStatus = 'Fully Paid'; SUM(InsurancePayment)
--   S      Partially Paid ($)            -> ClaimStatus = 'Partially Paid'; SUM(InsurancePayment)
--   T      Patient Paid ($)              -> Pat. Payment > 0; SUM(PatientPayment)
--   U      Patient Responsibility ($)    -> ClaimStatus not equal to Unbilled all; SUM(PatientBalance)
--   U.1      Daqbilling                  -> U AND Source = Daq
--   U.2      IRCM                        -> U AND Source = IRCM
--   V      Adjustment amount ($)         -> SUM(InsuranceAdjustments + PatientAdjustments)
--   W      Total Payments ($) - Insurance -> Ins. Payment > 0; SUM(InsurancePayment)
--   X      Insurance Balance ($)         -> Claim level full Ins. Balance; SUM(InsuranceBalance)
--   X.1      Fully Denied                -> ClaimStatus = 'Fully Denied'; SUM(InsuranceBalance)
--   X.2      Partially Denied            -> ClaimStatus = 'Partially Denied'; SUM(InsuranceBalance)
--   X.3      No Response from Payor      -> ClaimStatus = 'No Response'; SUM(InsuranceBalance)
--
--   Average Payment Per Claim
--   Y      Average Payment ($) - Total Pay/Billed Claims
--   Z      Average Payment ($) - Total Pay/Paid Claims
--   AA     Average Payment ($) - Total Pay/Adjudicated Claims
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Augustus_ES_PMS;
    TRUNCATE TABLE dbo.Augustus_ES_Cash;
    TRUNCATE TABLE dbo.Augustus_ES_Avg;

    -- ── #Base : one row per ClaimLevelData record with period bucket ───────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
        ISNULL(LTRIM(RTRIM(BillingStatus)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Source)), '')        AS Source,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL;

    -- ── #Periods : distinct (ESYear, ESMonth) + (0,0) grand-total sentinel ──
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
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
               COUNT(DISTINCT b.AccessionNumber) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus <> 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- F.1  No. of Claims Billed in IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F.1', '  No. of Claims Billed in IRCM',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus <> 'Billed amount 0'
                          AND b.Source = 'IRCM'
        GROUP BY p.ESYear, p.ESMonth

        -- F.2  No. of Claims Billed in Daq Billing
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'F.2', '  No. of Claims Billed in Daq Billing',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus <> 'Billed amount 0'
                          AND b.Source = 'Daq'
        GROUP BY p.ESYear, p.ESMonth

        -- G  No. of Unbilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'No. of Unbilled Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND (b.BillStatus = '' OR b.BillStatus IS NULL)
                          AND b.ClaimStatus <> 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- H  Client bill claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'Client bill claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- I  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Fully Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- J  No. of Patient Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Patient Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Patient paid'
        GROUP BY p.ESYear, p.ESMonth

        -- K  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Patient Responsibility Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Pat Responsibility'
        GROUP BY p.ESYear, p.ESMonth

        -- L  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Partially Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partial Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- M  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Adjusted/Written Off Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Partially Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted/Written Off Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- O  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Insurance Balance Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response')
        GROUP BY p.ESYear, p.ESMonth

        -- O.1  No. of Fully Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.1', '  No. of Fully Denied Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- O.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.2', '  No. of Partially Denied Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- O.3  No. of No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.3', '  No. of No Response from Payor',
               COUNT(DISTINCT b.AccessionNumber)
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
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.1  Total Charge of Claims Billed in IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.1', '  Total Charge of Claims Billed (IRCM)',
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P.2  Total Charge of Claims Billed in Daq
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.2', '  Total Charge of Claims Billed (Daq)',
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q  Total Unbilled ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'Total Unbilled ($)',
               SUM(CASE WHEN (b.BillStatus='' OR b.BillStatus IS NULL) AND b.ClaimStatus<>'Billed amount 0' THEN b.ChargeAmount ELSE 0 END)
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
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.1  Daqbilling
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.1', '  Daqbilling',
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND b.Source='Daq' THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.2  IRCM
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.2', '  IRCM',
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND b.Source='IRCM' THEN b.PatientBalance ELSE 0 END)
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
               SUM(b.InsuranceBalance)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X.1  Fully Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.1', '  Fully Denied',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Denied' THEN b.InsuranceBalance ELSE 0 END)
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
    --  Augustus_ES_Avg  -  Y, Z, AA
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Augustus_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- Y  Average Payment ($) - Total Pay / Billed Claims
        SELECT p.ESYear, p.ESMonth, 'Y' AS RoleID, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' THEN b.AccessionNumber END) AS ClaimCount,
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' THEN b.InsurancePayment + b.PatientPayment ELSE 0 END) AS PayTotal
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
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshAug_ExecutiveSummary completed.';
END;
GO

PRINT '16_Augustus_ExecutiveSummary_Aggregate.sql completed.';
GO

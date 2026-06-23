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
-- RoleID scheme (Certus "Billable Samples - PMS Breakdown" /
-- "Cash Breakdown" / "Average Payment Per Claim"):
--
--   PMS Breakdown
--   F      No. of Billed Claims          -> BillingStatus='Billed' AND ClaimStatus<>'Billed amount 0'
--   G      Unbilled Claims               -> BillingStatus Blank AND ClaimStatus<>'Billed amount 0'
--   H      Billed Mismatches             -> PMS Billed Claims - LIS Billed (derived from LIMSMaster)
--   I      No. of Fully Paid Claims      -> ClaimStatus='Fully Paid'
--   J      No. of Patient Responsibility Claims -> ClaimStatus='Patient Responsibility'
--   K      No. of Patient Paid Claims    -> ClaimStatus='Patient Paid'
--   L      No. of Adjusted/Written Off   -> ClaimStatus='Fully Adjusted'
--   M      Test Patients                 -> ClaimStatus='Test'
--   N      No. of Partially Adjusted     -> ClaimStatus='Partially Adjusted'
--   O      No. of Partially Paid Claims  -> ClaimStatus='Partial Paid'
--   P      No. of Insurance Balance Claims -> ClaimStatus IN ('Fully Denied','No Response')
--   P.1      No. of Fully Denied Claims  -> ClaimStatus='Fully Denied'
--   P.2      No. of No Response from Payor -> ClaimStatus='No Response'
--
--   Cash Breakdown
--   Q      Total Billed ($)              -> BillingStatus='Billed'; SUM(ChargeAmount)
--   R      Unbilled Claims ($)           -> Unbilled; SUM(ChargeAmount)
--   S      Insurance Payment ($)         -> ClaimStatus='Fully Paid'; SUM(InsurancePayment)
--   T      Patient Responsibility ($)    -> ClaimStatus NOT Unbilled; SUM(PatientBalance)
--   U      Adjustments / Write Off ($)   -> SUM(InsuranceAdjustments + PatientAdjustments)
--   V      Patient Paid ($)              -> PatientPayment > 0; SUM(PatientPayment)
--   W      Partially Paid ($)            -> ClaimStatus='Partial Paid'; SUM(InsurancePayment)
--   X      Insurance Balance ($)         -> SUM(InsuranceBalance)
--   X.1      Denials                     -> ClaimStatus='Fully Denied'; SUM(InsuranceBalance)
--   X.2      Partially Denied            -> ClaimStatus='Partially Denied'; SUM(InsuranceBalance)
--   X.3      No Response from Payor      -> ClaimStatus='No Response'; SUM(InsuranceBalance)
--
--   Average Payment Per Claim
--   Y      Average Payment ($) - Total Pay/Billed Claims
--   Z      Average Payment ($) - Total Pay/Paid Claims
--   AA     Average Payment ($) - Total Pay/Adjudicated Claims
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

    -- ── #Base : one row per ClaimLevelData record with period bucket ───────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
       -- ISNULL(LTRIM(RTRIM(Billin)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')      AS ClaimStatus,
        --ISNULL(LTRIM(RTRIM(Source)), '')           AS Source,
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
    --    ReqCollectDate period, used for PMS row H (Billed Mismatches).
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
        WHERE BillingStatus = 'Billed'
          AND TRY_CAST(ReqCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
        GROUP BY
            YEAR (TRY_CAST(ReqCollectDate AS DATE)),
            MONTH(TRY_CAST(ReqCollectDate AS DATE));

        -- Grand-total sentinel (ESYear=0, ESMonth=0)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT 0, 0, COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillingStatus = 'Billed'
          AND TRY_CAST(ReqCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL;
    END

    -- ────────────────────────────────────────────────────────────────────
    --  Certus_ES_PMS  -  F, G, H, I, J, K, L, M, N, O, P, P.1, P.2
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Certus_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- F  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
               COUNT(DISTINCT b.AccessionNumber) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          --AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus <> 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- G  Unbilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'Unbilled Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          --AND (b.BillStatus = '' OR b.BillStatus IS NULL)
                          AND b.ClaimStatus <> 'Billed amount 0'
        GROUP BY p.ESYear, p.ESMonth

        -- H  Billed Mismatches - Other samples billed (PMS Billed - LIS Billed)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'Billed Mismatches - Other Samples Billed',
               (COUNT(DISTINCT CASE WHEN b.ClaimStatus<>'Billed amount 0' THEN b.AccessionNumber END)
                - ISNULL(lb.BilledCount, 0)) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        LEFT JOIN #LisBilled lb ON lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth
        GROUP BY p.ESYear, p.ESMonth, lb.BilledCount

        -- I  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Fully Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- J  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Patient Responsibility Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Patient Responsibility'
        GROUP BY p.ESYear, p.ESMonth

        -- K  No. of Patient Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Patient Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Patient Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- L  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Adjusted/Written Off Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- M  Test Patients
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'Test Patients',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Test'
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Partially Adjusted Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- O  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Partially Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partial Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- P  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P', 'No. of Insurance Balance Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus IN ('Fully Denied','No Response')
        GROUP BY p.ESYear, p.ESMonth

        -- P.1  No. of Fully Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.1', '  No. of Fully Denied Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- P.2  No. of No Response from Payor Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P.2', '  No. of No Response from Payor Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'No Response'
        GROUP BY p.ESYear, p.ESMonth
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
               SUM(CASE WHEN  b.ClaimStatus<>'Billed amount 0' THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  Unbilled Claims ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'Unbilled Claims ($)',
               SUM(CASE WHEN  b.ClaimStatus<>'Billed amount 0' THEN b.ChargeAmount ELSE 0 END)
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

        -- W  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Partially Paid ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Partial Paid' THEN b.InsurancePayment ELSE 0 END)
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

        -- X.1  Denials
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X.1', '  Denials',
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
    --  Certus_ES_Avg  -  Y, Z, AA
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Certus_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- Y  Average Payment ($) - Total Pay / Billed Claims
        SELECT p.ESYear, p.ESMonth, 'Y' AS RoleID, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.ClaimStatus<>'Billed amount 0' THEN b.AccessionNumber END) AS ClaimCount,
               SUM(CASE WHEN  b.ClaimStatus<>'Billed amount 0' THEN b.InsurancePayment + b.PatientPayment ELSE 0 END) AS PayTotal
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

    PRINT 'usp_RefreshCert_ExecutiveSummary completed.';
END;
GO

PRINT '16_Certus_ExecutiveSummary_Aggregate.sql completed.';
GO

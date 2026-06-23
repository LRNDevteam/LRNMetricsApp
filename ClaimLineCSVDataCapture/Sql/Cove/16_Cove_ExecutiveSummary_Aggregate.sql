-- ============================================================
-- Cove – Executive Summary PMS / Cash / Avg Aggregate Refresh SP
-- File : 16_Cove_ExecutiveSummary_Aggregate.sql
-- DB   : Cove_LRN
--
-- Mirrors PhiLife\16_PhiLife_ExecutiveSummary_Aggregate.sql. This SP owns
-- and TRUNCATEs Cove_ES_PMS, Cove_ES_Cash, and Cove_ES_Avg only.
-- Cove_ES_LIS is owned by 19_Cove_ExecutiveSummary_LIS_Alt.sql
-- (usp_RefreshCove_ExecutiveSummary_LIS_Alt), which sources from
-- dbo.LIMSMaster instead of dbo.ClaimLevelData.
--
-- Source: dbo.ClaimLevelData, period bucket = DateofService (ESYear/ESMonth),
-- plus a (0,0) grand-total sentinel row (#Periods = distinct + UNION (0,0)).
--
-- RoleID scheme (from the Cove "Billable Samples - PMS Breakdown" /
-- "Cash Breakdown" / "Average Payment Per Claim" spec image):
--
--   PMS Breakdown
--   F     No. of Billed Claims                 -> BillStatus IN ('Billed','Billed-Client')
--   G       Billed Mismatches - Accessions NA / -> F minus COUNT(DISTINCT Accession) from
--           Other Sample                            LIMSMaster where BillCategory='Billed'
--                                                   keyed by DateOfCollection period.
--                                                   Degenerates to 0 when LIMSMaster does
--                                                   not exist or has no rows for the period.
--   H     No. of Fully Paid Claims              -> ClaimStatus IN ('Fully Paid','Paid-Client')
--   I     No. of Patient Responsibility Claims  -> ClaimStatus = 'Patient Responsibility'
--   J     No. of Adjusted/Written Off Claims    -> ClaimStatus = 'Fully Adjusted'
--   K     No. of Partially Adjusted/Written Off -> ClaimStatus = 'Partially Adjusted'
--           Claims
--   L     No. of Partially Paid Claims          -> ClaimStatus = 'Partially Paid'
--   M     No. of Patient Paid Claims            -> ClaimStatus = 'Patient Payment'
--   N     No. of Insurance Balance Claims       -> ClaimStatus IN ('Fully Denied','Partially Denied','No Response','No Response-Client')
--   N.1     No. of Fully Denied Claims          -> ClaimStatus = 'Fully Denied'
--   N.2     No. of Partially Denied Claims      -> ClaimStatus = 'Partially Denied'
--   N.3     No. of No Response from Payor       -> ClaimStatus IN ('No Response','No Response-Client')
--           Claims
--
--   Cash Breakdown
--   O     Total Billed ($)                      -> BillStatus IN ('Billed','Billed-Client'); SUM(ChargeAmount)
--   P     Insurance Payment ($)                 -> ClaimStatus IN ('Fully Paid','Paid-Client'); SUM(InsurancePayment)
--   Q     Patient Responsibility ($)            -> ClaimStatus NOT IN ('Unbilled','Unbilled - PB','No Response','No Response-Client'); SUM(PatientBalance)
--   R     Patient Payment ($)                   -> PatientPayment > 0; SUM(PatientPayment)
--   S     Adjustments / Write Off ($)           -> ClaimStatus NOT IN ('Unbilled','Unbilled - PB'); SUM(InsuranceAdjustments + PatientAdjustments)
--   T     Partially Paid ($)                    -> ClaimStatus = 'Partially Paid'; SUM(InsurancePayment)
--   U     Insurance Balance ($)                 -> ClaimStatus NOT IN ('Unbilled','Unbilled - PB'); SUM(InsuranceBalance)
--   U.1     Denials                             -> ClaimStatus = 'Fully Denied'; SUM(InsuranceBalance)
--   U.2     Partially Denied                    -> ClaimStatus IN ('Partially Denied','Partially Adjusted','Partially Paid','Patient Payment','Patient Responsibility'); SUM(InsuranceBalance)
--   U.3     No Response from Payor              -> ClaimStatus IN ('No Response','No Response-Client'); SUM(InsuranceBalance)
--
--   Average Payment Per Claim
--   V     Average Payment ($) - Total Pay/Billed Claims      -> SUM(InsurancePayment+PatientPayment) over F / COUNT(F)
--   W     Average Payment ($) - Total Pay/Paid Claims        -> SUM(InsurancePayment+PatientPayment) over H / COUNT(H)
--   X     Average Payment ($) - Total Pay/Adjudicated Claims -> SUM(InsurancePayment+PatientPayment) over (ClaimStatus NOT IN ('Unbilled','Unbilled - PB')) / COUNT(same)
--
--   The spec image leaves V/W/X's logic blank; the "Total Pay/<X> Claims"
--   labels are taken at face value: numerator = SUM(InsurancePayment +
--   PatientPayment), denominator = the corresponding claim-count row
--   (F, H, or the 'adjudicated' = not-Unbilled set). ESMonthChargeAmount
--   stores the resulting average; ESMonthClaimCount stores the
--   denominator (claim count) for reference/debugging.
--
-- Cash/PMS rows for which the denominator is 0 store an average of 0
-- (NULLIF/division-by-zero guarded).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Cove_ES_PMS;
    TRUNCATE TABLE dbo.Cove_ES_Cash;
    TRUNCATE TABLE dbo.Cove_ES_Avg;

    -- ── #Base : one row per ClaimLevelData record with period bucket ───────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
        ISNULL(LTRIM(RTRIM(BillStatus)),  '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
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

    -- ── #LisBilled : LIMSMaster BillCategory='Billed' counts per DateOfCollection
    --    period, used for PMS row 'G' (Billed Mismatches - Accessions NA / Other Sample).
    --
    --    Formula (per spec):
    --      G = No. of Billed Claims (F, from ClaimLevelData / DateofService)
    --        - COUNT(DISTINCT Accession) from LIMSMaster where BillCategory='Billed'
    --          (keyed by DateOfCollection)
    --
    --    A (0,0) grand-total sentinel row is included so the mismatch total
    --    across all periods is also computed correctly.
    --    Degenerates to 0 when LIMSMaster does not exist or has no matching rows.
    -- ─────────────────────────────────────────────────────────────────────────────
    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL);

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        -- Per-period rows (DateOfCollection → ESYear / ESMonth)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT
            YEAR (TRY_CAST(DateOfCollection AS DATE)),
            MONTH(TRY_CAST(DateOfCollection AS DATE)),
            COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillCategory = 'Billed'
          AND TRY_CAST(DateOfCollection AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
        GROUP BY
            YEAR (TRY_CAST(DateOfCollection AS DATE)),
            MONTH(TRY_CAST(DateOfCollection AS DATE));

        -- Grand-total sentinel (ESYear=0, ESMonth=0)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT 0, 0, COUNT(DISTINCT Accession)
        FROM dbo.LIMSMaster
        WHERE BillCategory = 'Billed'
          AND TRY_CAST(DateOfCollection AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL;
    END

    -- ────────────────────────────────────────────────────────────────────
    --  Cove_ES_PMS  -  F, G, H, I, J, K, L, M, N, N.1, N.2, N.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Cove_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- F  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
               COUNT(DISTINCT b.AccessionNumber) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed','Billed-Client')
        GROUP BY p.ESYear, p.ESMonth

        -- G  Billed Mismatches - Accessions NA / Other Sample
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'Billed Mismatches - Accessions NA / Other Sample',
               CASE WHEN COUNT(DISTINCT b.AccessionNumber) - MAX(ISNULL(lb.BilledCount,0)) > 0
                    THEN COUNT(DISTINCT b.AccessionNumber) - MAX(ISNULL(lb.BilledCount,0))
                    ELSE 0 END
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus IN ('Billed','Billed-Client')
        LEFT JOIN #LisBilled lb ON lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth
        GROUP BY p.ESYear, p.ESMonth

        -- H  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'No. of Fully Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus IN ('Fully Paid','Paid-Client')
        GROUP BY p.ESYear, p.ESMonth

        -- I  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Patient Responsibility Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Patient Responsibility'
        GROUP BY p.ESYear, p.ESMonth

        -- J  No. of Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Adjusted/Written Off Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- K  No. of Partially Adjusted/Written Off Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Partially Adjusted/Written Off Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- L  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Partially Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- M  No. of Patient Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Patient Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Patient Payment'
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Insurance Balance Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response','No Response-Client')
        GROUP BY p.ESYear, p.ESMonth

        -- N.1  No. of Fully Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N.1', '  No. of Fully Denied Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Fully Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- N.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N.2', '  No. of Partially Denied Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus = 'Partially Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- N.3  No. of No Response from Payor Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N.3', '  No. of No Response from Payor Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.ClaimStatus IN ('No Response','No Response-Client')
        GROUP BY p.ESYear, p.ESMonth
    ) pms;

    -- ────────────────────────────────────────────────────────────────────
    --  Cove_ES_Cash  -  O, P, Q, R, S, T, U, U.1, U.2, U.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Cove_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeAmount, GETDATE()
    FROM
    (
        -- O  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'O' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.BillStatus IN ('Billed','Billed-Client') THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- P  Insurance Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'P', 'Insurance Payment ($)',
               SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client') THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q  Patient Responsibility ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'Patient Responsibility ($)',
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB','No Response','No Response-Client') THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  Patient Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'Patient Payment ($)',
               SUM(CASE WHEN b.PatientPayment > 0 THEN b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  Adjustments / Write Off ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'Adjustments / Write Off ($)',
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.InsuranceAdjustments + b.PatientAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- T  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T', 'Partially Paid ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Partially Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Insurance Balance ($)',
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.1  Denials
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.1', '  Denials',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Denied' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.2  Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.2', '  Partially Denied',
               SUM(CASE WHEN b.ClaimStatus IN ('Partially Denied','Partially Adjusted','Partially Paid','Patient Payment','Patient Responsibility') THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U.3', '  No Response from Payor',
               SUM(CASE WHEN b.ClaimStatus IN ('No Response','No Response-Client') THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- ────────────────────────────────────────────────────────────────────
    --  Cove_ES_Avg  -  V, W, X
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Cove_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- V  Average Payment ($) - Total Pay / Billed Claims
        SELECT p.ESYear, p.ESMonth, 'V' AS RoleID, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.BillStatus IN ('Billed','Billed-Client') THEN b.AccessionNumber END) AS ClaimCount,
               SUM(CASE WHEN b.BillStatus IN ('Billed','Billed-Client') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END) AS PayTotal
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W  Average Payment ($) - Total Pay / Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Average Payment ($) - Total Pay/Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client') THEN b.AccessionNumber END),
               SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Paid-Client') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X  Average Payment ($) - Total Pay / Adjudicated Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X', 'Average Payment ($) - Total Pay/Adjudicated Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.AccessionNumber END),
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) avgrows;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshCove_ExecutiveSummary completed.';
END;
GO

PRINT '16_Cove_ExecutiveSummary_Aggregate.sql completed.';
GO

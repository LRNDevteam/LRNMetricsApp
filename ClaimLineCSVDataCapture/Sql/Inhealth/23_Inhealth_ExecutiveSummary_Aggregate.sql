-- ============================================================
-- Inhealth – Executive Summary PMS / Cash / Avg Aggregate Refresh SP
-- File : 23_Inhealth_ExecutiveSummary_Aggregate.sql
-- DB   : Inhealth_LRN
--
-- Mirrors Augustus\16_Augustus_ExecutiveSummary_Aggregate.sql.
-- This SP owns and TRUNCATEs Inhealth_ES_PMS, Inhealth_ES_Cash, Inhealth_ES_Avg.
-- Inhealth_ES_LIS is owned by 26_Inhealth_ExecutiveSummary_LIS_Alt.sql
-- (usp_RefreshInh_ExecutiveSummary_LIS_Alt), which sources from
-- dbo.LIMSMaster using Entry_DateCreated as the date column.
--
-- Source: dbo.ClaimLevelData, period bucket = DateofService (ESYear/ESMonth),
-- plus a (0,0) grand-total sentinel row.
--
-- Inhealth ClaimLevelData uses BillStatus column (values: 'Billed', 'Unbilled').
--
-- RoleID scheme:
--   PMS Breakdown
--   F      No. of Billed Claims             -> BillStatus = 'Billed'
--   G      Billed Mismatches                -> PMS Billed - LIS BillCategory='Billed' count
--   H      No. of UnBilled Claims           -> BillStatus = 'Unbilled'
--   H.1      Unbilled                       -> BillStatus='Unbilled' AND ClaimStatus='Unbilled'
--   H.2      Unbilled - Patient Balance     -> BillStatus='Unbilled' AND ClaimStatus='Unbilled - Patient Balance'
--   I      No. of Fully Paid Claims         -> BillStatus='Billed' AND ClaimStatus='Fully Paid'
--   J      No. of Patient Responsibility    -> BillStatus='Billed' AND ClaimStatus='Patient Responsibility'
--   K      No. of Fully Adjusted Claims     -> BillStatus='Billed' AND ClaimStatus='Complete W/O'
--   L      No. of Partially Adjusted Claims -> BillStatus='Billed' AND ClaimStatus='Partially Adjusted'
--   M      No. of Patient Payments Claims   -> BillStatus='Billed' AND ClaimStatus='Patient Payment'
--   N      No. of Partially Paid Claims     -> BillStatus='Billed' AND ClaimStatus='Partially Paid'
--   O      No. of Insurance Balance Claims  -> BillStatus='Billed' AND ClaimStatus IN ('FullyDenied','Partially Denied','No Response')
--   O.1      No. of Denied Claims           -> BillStatus='Billed' AND ClaimStatus='FullyDenied'
--   O.2      No. of Partially Denied Claims -> BillStatus='Billed' AND ClaimStatus='Partially Denied'
--   O.3      No. of No Response from Payor  -> BillStatus='Billed' AND ClaimStatus='No Response'
--
--   Cash Breakdown
--   P      Total Billed ($)                 -> BillStatus='Billed'; SUM(ChargeAmount)
--   Q      Total Unbilled ($)               -> BillStatus='Unbilled'; SUM(ChargeAmount)
--   Q.1      Unbilled                       -> BillStatus='Unbilled' AND ClaimStatus='Unbilled'; SUM(ChargeAmount)
--   Q.2      Unbilled - Patient Balance     -> BillStatus='Unbilled' AND ClaimStatus='Unbilled - Patient Balance'; SUM(ChargeAmount)
--   R      Insurance Payment ($)            -> BillStatus='Billed' AND ClaimStatus='Fully Paid'; SUM(InsurancePayment)
--   S      Patient Payments ($)             -> BillStatus='Billed'; SUM(PatientPayment)
--   T      Partially Paid ($)               -> BillStatus='Billed' AND ClaimStatus='Partially Paid'; SUM(InsurancePayment)
--   U      Patient Responsibility ($)       -> BillStatus='Billed'; SUM(PatientBalance)
--   V      Total Adjustments ($)            -> BillStatus='Billed'; SUM(InsuranceAdjustments + PatientAdjustments)
--   W      Insurance Balance ($)            -> BillStatus='Billed'; SUM(InsuranceBalance)
--   W.1      Denials                        -> BillStatus='Billed' AND ClaimStatus='FullyDenied'; SUM(InsuranceBalance)
--   W.2      Partially Denied               -> BillStatus='Billed' AND ClaimStatus='Partially Denied'; SUM(InsuranceBalance)
--   W.3      No Response from Payor         -> BillStatus='Billed' AND ClaimStatus='No Response'; SUM(InsuranceBalance)
--
--   Average Payment Per Claim
--   X      Average Payment ($) - Total Pay/Billed Claims
--   Y      Average Payment ($) - Fully Paid Claim Value/Paid Claims
--   Z      Average Payment ($) - Total Pay/Adjudicated Claims
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshInh_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Inhealth_ES_PMS;
    TRUNCATE TABLE dbo.Inhealth_ES_Cash;
    TRUNCATE TABLE dbo.Inhealth_ES_Avg;

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

    -- ── #LisBilled : LIMSMaster BillCategory='Billed' counts per
    --    Entry_DateCreated period, used for PMS row G (Billed Mismatches).
    --    Inhealth uses Entry_DateCreated as the date column in LIMSMaster.
    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL);

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        -- Per-period rows (Entry_DateCreated → ESYear / ESMonth)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT
            YEAR (TRY_CAST(Entry_DateCreated AS DATE)),
            MONTH(TRY_CAST(Entry_DateCreated AS DATE)),
            COUNT(DISTINCT OrderID)
        FROM dbo.LIMSMaster
        WHERE BillCategory = 'Billed'
          AND TRY_CAST(Entry_DateCreated AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), OrderID))), '') IS NOT NULL
        GROUP BY
            YEAR (TRY_CAST(Entry_DateCreated AS DATE)),
            MONTH(TRY_CAST(Entry_DateCreated AS DATE));

        -- Grand-total sentinel (ESYear=0, ESMonth=0)
        INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
        SELECT 0, 0, COUNT(DISTINCT OrderID)
        FROM dbo.LIMSMaster
        WHERE BillCategory = 'Billed'
          AND TRY_CAST(Entry_DateCreated AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), OrderID))), '') IS NOT NULL;
    END

    -- ────────────────────────────────────────────────────────────────────
    --  Inhealth_ES_PMS  -  F, G, H, H.1, H.2, I, J, K, L, M, N, O, O.1, O.2, O.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Inhealth_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- F  No. of Billed Claims
        SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
               COUNT(DISTINCT b.AccessionNumber) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        -- G  Billed Mismatches (PMS Billed Count - LIS BillCategory='Billed' Count)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'G', 'Billed Mismatches',
               (COUNT(DISTINCT CASE WHEN b.BillStatus='Billed' THEN b.AccessionNumber END)
                - ISNULL(lb.BilledCount, 0)) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        LEFT JOIN #LisBilled lb ON lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth
        GROUP BY p.ESYear, p.ESMonth, lb.BilledCount

        -- H  No. of UnBilled Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H', 'No. of UnBilled Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        -- H.1  Unbilled
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.1', '  Unbilled',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Unbilled'
                          AND b.ClaimStatus = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        -- H.2  Unbilled - Patient Balance
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'H.2', '  Unbilled - Patient Balance',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Unbilled'
                          AND b.ClaimStatus = 'Unbilled - Patient Balance'
        GROUP BY p.ESYear, p.ESMonth

        -- I  No. of Fully Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'I', 'No. of Fully Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'Fully Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- J  No. of Patient Responsibility Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'J', 'No. of Patient Responsibility Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'Patient Responsibility'
        GROUP BY p.ESYear, p.ESMonth

        -- K  No. of Fully Adjusted Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'K', 'No. of Fully Adjusted Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'Complete W/O'
        GROUP BY p.ESYear, p.ESMonth

        -- L  No. of Partially Adjusted Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'L', 'No. of Partially Adjusted Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'Partially Adjusted'
        GROUP BY p.ESYear, p.ESMonth

        -- M  No. of Patient Payments Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'M', 'No. of Patient Payments Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'Patient Payment'
        GROUP BY p.ESYear, p.ESMonth

        -- N  No. of Partially Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Paid Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'Partially Paid'
        GROUP BY p.ESYear, p.ESMonth

        -- O  No. of Insurance Balance Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O', 'No. of Insurance Balance Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus IN ('FullyDenied','Partially Denied','No Response')
        GROUP BY p.ESYear, p.ESMonth

        -- O.1  No. of Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.1', '  No. of Denied Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'FullyDenied'
        GROUP BY p.ESYear, p.ESMonth

        -- O.2  No. of Partially Denied Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.2', '  No. of Partially Denied Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'Partially Denied'
        GROUP BY p.ESYear, p.ESMonth

        -- O.3  No. of No Response from Payor Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'O.3', '  No. of No Response from Payor Claims',
               COUNT(DISTINCT b.AccessionNumber)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
                          AND b.BillStatus = 'Billed'
                          AND b.ClaimStatus = 'No Response'
        GROUP BY p.ESYear, p.ESMonth
    ) pms;

    -- ────────────────────────────────────────────────────────────────────
    --  Inhealth_ES_Cash  -  P, Q, Q.1, Q.2, R, S, T, U, V, W, W.1, W.2, W.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Inhealth_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeAmount, GETDATE()
    FROM
    (
        -- P  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'P' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.BillStatus='Billed' THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q  Total Unbilled ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q', 'Total Unbilled ($)',
               SUM(CASE WHEN b.BillStatus='Unbilled' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q.1  Unbilled
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q.1', '  Unbilled',
               SUM(CASE WHEN b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Q.2  Unbilled - Patient Balance
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Q.2', '  Unbilled - Patient Balance',
               SUM(CASE WHEN b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled - Patient Balance' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- R  Insurance Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'R', 'Insurance Payment ($)',
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  Patient Payments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S', 'Patient Payments ($)',
               SUM(CASE WHEN b.BillStatus='Billed' THEN b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- T  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T', 'Partially Paid ($)',
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Partially Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Patient Responsibility ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Patient Responsibility ($)',
               SUM(CASE WHEN b.BillStatus='Billed' THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- V  Total Adjustments ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Total Adjustments ($)',
               SUM(CASE WHEN b.BillStatus='Billed' THEN ISNULL(b.InsuranceAdjustments,0) + ISNULL(b.PatientAdjustments,0) ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Insurance Balance ($)',
               SUM(CASE WHEN b.BillStatus='Billed' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W.1  Denials
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W.1', '  Denials',
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='FullyDenied' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W.2  Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W.2', '  Partially Denied',
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Partially Denied' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W.3  No Response from Payor
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W.3', '  No Response from Payor',
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='No Response' THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- ────────────────────────────────────────────────────────────────────
    --  Inhealth_ES_Avg  -  X, Y, Z
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Inhealth_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- X  Average Payment ($) - Total Pay/Billed Claims
        --    Sum(InsurancePayment Fully Paid + Partially Paid) / Count(Billed Claims)
        SELECT p.ESYear, p.ESMonth, 'X' AS RoleID,
               'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.BillStatus='Billed' THEN b.AccessionNumber END) AS ClaimCount,
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus IN ('Fully Paid','Partially Paid')
                        THEN b.InsurancePayment ELSE 0 END) AS PayTotal
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Y  Average Payment ($) - Fully Paid Claim Value/Paid Claims
        --    Sum(InsurancePayment Fully Paid) / Count(Fully Paid Claims)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Y',
               'Average Payment ($) - Fully Paid Claim Value/Paid Claims',
               COUNT(DISTINCT CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid' THEN b.AccessionNumber END),
               SUM(CASE WHEN b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z  Average Payment ($) - Total Pay/Adjudicated Claims
        --    Sum(InsurancePayment + PatientPayment) / Count(Adjudicated Claims)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z',
               'Average Payment ($) - Total Pay/Adjudicated Claims',
               COUNT(DISTINCT CASE WHEN b.BillStatus='Billed'
                                   AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                         'Partially Paid','Patient Payment','FullyDenied','Partially Denied')
                                   THEN b.AccessionNumber END),
               SUM(CASE WHEN b.BillStatus='Billed'
                        AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                              'Partially Paid','Patient Payment','FullyDenied','Partially Denied')
                        THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) avgrows;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshInh_ExecutiveSummary completed.';
END;
GO

PRINT '23_Inhealth_ExecutiveSummary_Aggregate.sql completed.';
GO

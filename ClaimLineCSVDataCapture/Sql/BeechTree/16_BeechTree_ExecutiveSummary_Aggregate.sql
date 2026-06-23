-- ============================================================
-- BeechTree – Executive Summary PMS / Cash / Avg Aggregate Refresh SP
-- File : 16_BeechTree_ExecutiveSummary_Aggregate.sql
-- DB   : BeechTree_LRN
--
-- Mirrors Augustus\16_Augustus_ExecutiveSummary_Aggregate.sql.
-- This SP owns and TRUNCATEs BeechTree_ES_PMS, BeechTree_ES_Cash, BeechTree_ES_Avg.
-- BeechTree_ES_LIS is owned by 19_BeechTree_ExecutiveSummary_LIS_Alt.sql
-- (usp_RefreshBT_ExecutiveSummary_LIS_Alt).
--
-- Source: dbo.ClaimLevelData
--   Date column  : DateofService (ESYear / ESMonth)
--   Distinct key : ClaimID
--   Billed flag  : BilledUnbilled column
--
-- RoleID scheme (from "PMS Breakdown" / "Cash Breakdown" / "Average Payment Per Claim" spec):
--
--   PMS Breakdown
--   R      Billed – Includes all Claims Billed in AMD     (BilledUnbilled='Billed')
--   S      Billed Mismatches – Non Diagnose LIS Samples    (BilledUnbilled='Billed' AND [mismatch flag])
--   T      Unbilled – Entered to AMD – Yet to be released  (BilledUnbilled='UnBilled')
--   U      Fully Paid – Insurance Pay                      (ClaimStatus='Fully Paid')
--   V      Fully Adjusted                                  (ClaimStatus='Fully Adjusted')
--   W      Patient Responsibility                          (ClaimStatus='Pat Responsibility')
--   X      Partially Paid                                  (ClaimStatus='Partial Paid')
--   Y      Patient Payment                                 (PatientPayment > 0)
--   Z      Insurance Balance                               (ClaimStatus IN ('Fully Denied','Partially Denied','No Response'))
--     Z.1    Fully Denied                                  (ClaimStatus='Fully Denied')
--     Z.2    No Response                                   (ClaimStatus='No Response')
--     Z.3    Partially Denied                              (ClaimStatus='Partially Denied')
--
--   Cash Breakdown
--   AA     Total Billed ($)                               SUM(ChargeAmount) WHERE BilledUnbilled='Billed'
--   AB     Unbilled ($)                                   SUM(ChargeAmount) WHERE BilledUnbilled='UnBilled'
--   AC     Insurance Payment (fully paid) ($)             SUM(InsurancePayment) WHERE ClaimStatus='Fully Paid'
--   AD     Partially Paid ($)                             SUM(InsurancePayment) WHERE ClaimStatus='Partial Paid'
--   AE     Patient Payment ($)                            SUM(PatientPayment) WHERE PatientPayment > 0
--   AF     Fully Adjusted (Complete W/O)                  SUM(InsuranceAdjustments+PatientAdjustments) WHERE ClaimStatus='Fully Adjusted'
--   AG     Contractual Obligation W/O                     SUM(InsuranceAdjustments) WHERE InsuranceAdjustments > 0
--   AH     Patient Balance ($)                            SUM(PatientBalance) WHERE ClaimStatus NOT IN ('Unbilled','Unbilled - PB')
--   AI     Patient WO                                     SUM(PatientAdjustments) WHERE PatientAdjustments > 0
--   AJ     Insurance Balance ($)                          SUM(InsuranceBalance) WHERE ClaimStatus IN ('Fully Denied','Partially Denied','No Response')
--
--   Average Payment Per Claim
--   AK     Average Payment ($) - Total Pay/Billed Claims
--   AL     Average Payment ($) - Total Pay/Paid Claims
--   AM     Average Payment ($) - Total Pay/Adjudicated Claims
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshBT_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.BeechTree_ES_PMS;
    TRUNCATE TABLE dbo.BeechTree_ES_Cash;
    TRUNCATE TABLE dbo.BeechTree_ES_Avg;

    -- ── #Base : one row per ClaimLevelData record with period bucket ───────
    DROP TABLE IF EXISTS #Base;

    SELECT
        ClaimID,
        YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
        ISNULL(LTRIM(RTRIM(BilledUnbilled)), '')            AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)),    '')            AS ClaimStatus,
        ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(CONVERT(NVARCHAR(50), ClaimID), '') IS NOT NULL;

    -- ── #Periods : distinct (ESYear, ESMonth) + (0,0) grand-total sentinel ──
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
    UNION ALL SELECT 0, 0;

    -- ── #LisBilled : LIMSMaster BilledorNot='Billed' counts per
    --    RequestCollectDate period. Used for row S (Billed Mismatches):
    --    S = PMS Billed Claims (R) - LIS Billed Samples (this table).
    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled (ESYear INT NOT NULL, ESMonth INT NOT NULL, BilledCount INT NOT NULL);

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
    BEGIN
        -- Detect accession and date columns dynamically (mirrors file 19)
        DECLARE @LbAccCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('AccessionNumber','VisitNumber','OrderID','Accession','AccessionNo')
            ORDER BY CASE name
                WHEN 'AccessionNumber' THEN 0 WHEN 'VisitNumber' THEN 1
                WHEN 'OrderID' THEN 2 WHEN 'Accession' THEN 3 WHEN 'AccessionNo' THEN 4 ELSE 5 END);

        DECLARE @LbDateCol SYSNAME = (
            SELECT TOP 1 name FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
              AND name IN ('RequestCollectDate','ReqCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
            ORDER BY CASE name
                WHEN 'RequestCollectDate' THEN 0 WHEN 'ReqCollectDate' THEN 1
                WHEN 'DateOfCollection'   THEN 2 WHEN 'DateofService'  THEN 3
                WHEN 'CollectionDate'     THEN 4 WHEN 'ServiceDate'    THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

        IF @LbAccCol IS NOT NULL AND @LbDateCol IS NOT NULL
        BEGIN
            DECLARE @LbSql NVARCHAR(MAX) = N'
                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
                SELECT
                    YEAR (TRY_CAST([' + @LbDateCol + N'] AS DATE)),
                    MONTH(TRY_CAST([' + @LbDateCol + N'] AS DATE)),
                    COUNT(DISTINCT LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LbAccCol + N']))))
                FROM dbo.LIMSMaster
                WHERE BilledorNot = ''Billed''
                  AND TRY_CAST([' + @LbDateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LbAccCol + N']))), '''') IS NOT NULL
                GROUP BY
                    YEAR (TRY_CAST([' + @LbDateCol + N'] AS DATE)),
                    MONTH(TRY_CAST([' + @LbDateCol + N'] AS DATE));

                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
                SELECT 0, 0, COUNT(DISTINCT LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LbAccCol + N']))))
                FROM dbo.LIMSMaster
                WHERE BilledorNot = ''Billed''
                  AND TRY_CAST([' + @LbDateCol + N'] AS DATE) IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @LbAccCol + N']))), '''') IS NOT NULL;';

            EXEC sp_executesql @LbSql;
        END
    END

    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_PMS  -  R, S, T, U, V, W, X, Y, Z, Z.1, Z.2, Z.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- R  Billed – Includes all Claims Billed in AMD
        SELECT p.ESYear, p.ESMonth, 'R' AS RoleID,
               'Billed - Includes all Claims Billed in AMD' AS Description,
               COUNT(DISTINCT CASE WHEN b.BillStatus = 'Billed' THEN b.ClaimID END) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  Billed Mismatches – Non Diagnose LIS Samples
        --    = PMS Billed Claims (R) - LIS Billed Samples (LIMSMaster BilledorNot='Billed')
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S',
               'Billed Mismatches - Non Diagnose LIS Samples',
               COUNT(DISTINCT CASE WHEN b.BillStatus='Billed' THEN b.ClaimID END)
               - ISNULL(MAX(lb.BilledCount), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        LEFT JOIN #LisBilled lb ON lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth
        GROUP BY p.ESYear, p.ESMonth

        -- T  Unbilled – Entered to AMD – Yet to be released to Payer
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T',
               'Unbilled - Entered to AMD - Yet to be released to Payer',
               COUNT(DISTINCT CASE WHEN b.BillStatus = 'UnBilled' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Fully Paid – Insurance Pay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Fully Paid - Insurance Pay',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- V  Fully Adjusted
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Fully Adjusted',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Adjusted' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W  Patient Responsibility
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Patient Responsibility',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Pat Responsibility' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X  Partially Paid
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X', 'Partially Paid',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partial Paid' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Y  Patient Payment
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Y', 'Patient Payment',
               COUNT(DISTINCT CASE WHEN b.PatientPayment > 0 THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z  Insurance Balance
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z', 'Insurance Balance',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied') THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z.1  Fully Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.1', '  Fully Denied',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Denied' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z.2  No Response
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.2', '  No Response',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'No Response' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z.3  Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.3', '  Partially Denied',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Partially Denied' THEN b.ClaimID END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) pms;

    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_Cash  -  AA through AJ
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeAmount, GETDATE()
    FROM
    (
        -- AA  Total Billed ($)
        SELECT p.ESYear, p.ESMonth, 'AA' AS RoleID, 'Total Billed ($)' AS Description,
               SUM(CASE WHEN b.BillStatus = 'Billed' THEN b.ChargeAmount ELSE 0 END) AS ChargeAmount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AB  Unbilled ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AB', 'Unbilled ($)',
               SUM(CASE WHEN b.BillStatus = 'UnBilled' THEN b.ChargeAmount ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AC  Insurance Payment (fully paid) ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AC', 'Insurance Payment (fully paid) ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' AND b.InsurancePayment > 0 THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AD  Partially Paid ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AD', 'Partially Paid ($)',
               SUM(CASE WHEN b.ClaimStatus = 'Partial Paid' THEN b.InsurancePayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AE  Patient Payment ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AE', 'Patient Payment ($)',
               SUM(CASE WHEN b.PatientPayment > 0 THEN b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AF  Fully Adjusted (Complete W/O)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AF', 'Fully Adjusted (Complete W/O)',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Adjusted'
                        THEN b.InsuranceAdjustments + b.PatientAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AG  Contractual Obligation W/O
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AG', 'Contractual Obligation W/O',
               SUM(CASE WHEN b.InsuranceAdjustments > 0 THEN b.InsuranceAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AH  Patient Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AH', 'Patient Balance ($)',
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.PatientBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AI  Patient WO
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AI', 'Patient WO',
               SUM(CASE WHEN b.PatientAdjustments > 0 THEN b.PatientAdjustments ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AJ  Insurance Balance ($)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AJ', 'Insurance Balance ($)',
               SUM(CASE WHEN b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied')
                        THEN b.InsuranceBalance ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) cash;

    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_Avg  -  AK, AL, AM
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- AK  Average Payment ($) - Total Pay / Billed Claims
        SELECT p.ESYear, p.ESMonth, 'AK' AS RoleID,
               'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               COUNT(DISTINCT CASE WHEN b.BillStatus='Billed' THEN b.ClaimID END) AS ClaimCount,
               SUM(CASE WHEN b.BillStatus='Billed' THEN b.InsurancePayment + b.PatientPayment ELSE 0 END) AS PayTotal
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AL  Average Payment ($) - Total Pay / Paid Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AL',
               'Average Payment ($) - Total Pay/Paid Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.ClaimID END),
               SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- AM  Average Payment ($) - Total Pay / Adjudicated Claims
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AM',
               'Average Payment ($) - Total Pay/Adjudicated Claims',
               COUNT(DISTINCT CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.ClaimID END),
               SUM(CASE WHEN b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') THEN b.InsurancePayment + b.PatientPayment ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) avgrows;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshBT_ExecutiveSummary completed.';
END;
GO

PRINT '16_BeechTree_ExecutiveSummary_Aggregate.sql completed.';
GO

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
--   V      Fully Adjusted                                  COUNT(DISTINCT ClaimID) from BTWOSummary
--     V.1..Vn  One sub-row per TransactionCodeCombined     SUM(MatchingCount) from BTWOSummary
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
    -- Period filters (NULL = no restriction)
    @YearFrom   INT            = NULL,
    @YearTo     INT            = NULL,
    @MonthFrom  INT            = NULL,
    @MonthTo    INT            = NULL,
    -- Dimension filters — comma-separated values, NULL = all
    @Panels     NVARCHAR(MAX)  = NULL,
    @Clinics    NVARCHAR(MAX)  = NULL,
    @Providers  NVARCHAR(MAX)  = NULL,
    @Reps       NVARCHAR(MAX)  = NULL
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
        ISNULL(LTRIM(RTRIM(BilledUnbilled)),    '')  AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)),       '')  AS ClaimStatus,
        ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance,
        -- Dimension columns (used for filter matching)
        ISNULL(LTRIM(RTRIM(Panelname)),         '')  AS Panelname,
        ISNULL(LTRIM(RTRIM(ClinicName)),        '')  AS ClinicName,
        ISNULL(LTRIM(RTRIM(ReferringProvider)), '')  AS ReferringProvider,
        ISNULL(LTRIM(RTRIM(SalesRepname)),      '')  AS SalesRepname
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      -- ── Year / Month filters ────────────────────────────────────────────
      AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
      -- ── Dimension filters (comma-separated; NULL = no restriction) ──────
      AND (@Panels    IS NULL OR EXISTS (
              SELECT 1 FROM STRING_SPLIT(@Panels,    ',') s
              WHERE LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(Panelname))))
      AND (@Clinics   IS NULL OR EXISTS (
              SELECT 1 FROM STRING_SPLIT(@Clinics,   ',') s
              WHERE LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(ClinicName))))
      AND (@Providers IS NULL OR EXISTS (
              SELECT 1 FROM STRING_SPLIT(@Providers, ',') s
              WHERE LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(ReferringProvider))))
      AND (@Reps      IS NULL OR EXISTS (
              SELECT 1 FROM STRING_SPLIT(@Reps,      ',') s
              WHERE LTRIM(RTRIM(s.value)) = LTRIM(RTRIM(SalesRepname))));

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
                    COUNT(*)
                FROM dbo.LIMSMaster
                WHERE BilledorNot = ''Billed''
                  AND TRY_CAST([' + @LbDateCol + N'] AS DATE) IS NOT NULL
                GROUP BY
                    YEAR (TRY_CAST([' + @LbDateCol + N'] AS DATE)),
                    MONTH(TRY_CAST([' + @LbDateCol + N'] AS DATE));

                INSERT INTO #LisBilled (ESYear, ESMonth, BilledCount)
                SELECT 0, 0, COUNT(*)
                FROM dbo.LIMSMaster
                WHERE BilledorNot = ''Billed''
                  AND TRY_CAST([' + @LbDateCol + N'] AS DATE) IS NOT NULL;';

            EXEC sp_executesql @LbSql;
        END
    END

    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_PMS  -  R, S, T, U, V, V.1..Vn (BTWOSummary), W, X, Y, Z, Z.1, Z.2, Z.3
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- R  Billed – Includes all Claims Billed in AMD
        SELECT p.ESYear, p.ESMonth, 'R' AS RoleID,
               'Billed - Includes all Claims Billed in AMD' AS Description,
               SUM(CASE WHEN b.BillStatus = 'Billed' THEN 1 ELSE 0 END) AS ClaimCount
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- S  Billed Mismatches – Non Diagnose LIS Samples
        --    = PMS Billed Claims (R) - LIS Billed Samples (LIMSMaster BilledorNot='Billed')
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'S',
               'Billed Mismatches - Non Diagnose LIS Samples',
               SUM(CASE WHEN b.BillStatus='Billed' THEN 1 ELSE 0 END)
               - ISNULL(MAX(lb.BilledCount), 0)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        LEFT JOIN #LisBilled lb ON lb.ESYear=p.ESYear AND lb.ESMonth=p.ESMonth
        GROUP BY p.ESYear, p.ESMonth

        -- T  Unbilled – Entered to AMD – Yet to be released to Payer
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'T',
               'Unbilled - Entered to AMD - Yet to be released to Payer',
               SUM(CASE WHEN b.BillStatus = 'UnBilled' THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- U  Fully Paid – Insurance Pay
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'U', 'Fully Paid - Insurance Pay',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- V  Fully Adjusted – SUM(MatchingCount) from BTWOSummary so the parent
        --    total equals the sum of its V.n sub-rows.  Bucketed by
        --    BTWOSummary.DateofService to avoid double-counting.
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'V', 'Fully Adjusted',
               ISNULL(SUM(ws.MatchingCount), 0)
        FROM #Periods p
        LEFT JOIN (
            SELECT
                ws2.MatchingCount,
                ISNULL(YEAR (TRY_CAST(ws2.DateofService AS DATE)), 0) AS WOYear,
                ISNULL(MONTH(TRY_CAST(ws2.DateofService AS DATE)), 0) AS WOMonth
            FROM   dbo.BTWOSummary ws2
            INNER JOIN #Base b
                ON LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
                 = LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
            WHERE  TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
        ) ws ON (p.ESYear = 0 OR (ws.WOYear = p.ESYear AND ws.WOMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- W  Patient Responsibility
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'W', 'Patient Responsibility',
               SUM(CASE WHEN b.ClaimStatus = 'Pat Responsibility' THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- X  Partially Paid
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'X', 'Partially Paid',
               SUM(CASE WHEN b.ClaimStatus = 'Partial Paid' THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Y  Patient Payment
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Y', 'Patient Payment',
               SUM(CASE WHEN b.PatientPayment > 0 THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z  Insurance Balance
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z', 'Insurance Balance',
               SUM(CASE WHEN b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied') THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z.1  Fully Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.1', '  Fully Denied',
               SUM(CASE WHEN b.ClaimStatus = 'Fully Denied' THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z.2  No Response
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.2', '  No Response',
               SUM(CASE WHEN b.ClaimStatus = 'No Response' THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- Z.3  Partially Denied
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'Z.3', '  Partially Denied',
               SUM(CASE WHEN b.ClaimStatus = 'Partially Denied' THEN 1 ELSE 0 END)
        FROM #Periods p
        LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth
    ) pms;

    -- ────────────────────────────────────────────────────────────────────
    --  BeechTree_ES_PMS  -  V.n  Fully Adjusted sub-rows (BTWOSummary)
    --  One row per TransactionCodeCombined per period, ordered A-Z.
    --  RoleID generated as V.1, V.2, ... per period bucket.
    -- ────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.BeechTree_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT
        'V.' + CAST(ROW_NUMBER() OVER (PARTITION BY agg.ESYear, agg.ESMonth
                                       ORDER BY     agg.TransactionCodeCombined) AS NVARCHAR(10)) AS RoleID,
        '  ' + agg.TransactionCodeCombined                                                         AS Description,
        agg.ESYear,
        agg.ESMonth,
        agg.MatchingCount  AS ESMonthClaimCount,
        0                  AS ESMonthChargeAmount,
        GETDATE()          AS RefreshedAt
    FROM (
        SELECT
            p.ESYear,
            p.ESMonth,
            ws.TransactionCodeCombined,
            SUM(ws.MatchingCount)  AS MatchingCount
        FROM #Periods p
        JOIN (
            -- Period bucketed from BTWOSummary.DateofService (not #Base) to avoid
            -- double-counting ClaimIDs that appear in multiple months in ClaimLevelData.
            SELECT
                ws2.TransactionCodeCombined,
                ws2.MatchingCount,
                ISNULL(YEAR (TRY_CAST(ws2.DateofService AS DATE)), 0) AS WOYear,
                ISNULL(MONTH(TRY_CAST(ws2.DateofService AS DATE)), 0) AS WOMonth
            FROM   dbo.BTWOSummary ws2
            INNER JOIN #Base b
                ON LTRIM(RTRIM(CAST(ws2.ClaimID AS NVARCHAR(50))))
                 = LTRIM(RTRIM(CAST(b.ClaimID   AS NVARCHAR(50))))
            WHERE  ws2.TransactionCodeCombined IS NOT NULL
              AND  TRY_CAST(ws2.DateofService AS DATE) IS NOT NULL
        ) ws ON (p.ESYear = 0 OR (ws.WOYear = p.ESYear AND ws.WOMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, ws.TransactionCodeCombined
    ) agg;

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
    --
    --  Per confirmed spec, the numerator for all three rows is the SAME:
    --  SUM of BeechTree_ES_Cash rows AC (Insurance Payment - fully paid) +
    --  AD (Partially Paid) + AE (Patient Payment). Only the denominator
    --  (claim count) differs, pulled from specific BeechTree_ES_PMS RoleIDs:
    --    AK = SUM(AC,AD,AE) / PMS 'R'                       (Billed)
    --    AL = SUM(AC,AD,AE) / SUM(PMS 'U','X','Y')          (Paid)
    --    AM = SUM(AC,AD,AE) / SUM(PMS 'U','V','W','X','Y','Z.1','Z.3') (Adjudicated)
    --  Sourced from the BeechTree_ES_PMS / BeechTree_ES_Cash rows this same
    --  refresh just inserted above (not re-derived from #Base), so Avg always
    --  reconciles exactly to what the PMS/Cash breakdowns show.
    -- ────────────────────────────────────────────────────────────────────
    ;WITH CashTotal AS (
        SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS PayTotal
        FROM dbo.BeechTree_ES_Cash
        WHERE RoleID IN ('AC','AD','AE')
        GROUP BY ESYear, ESMonth
    ),
    PMS_R AS (
        SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS ClaimCount
        FROM dbo.BeechTree_ES_PMS
        WHERE RoleID = 'R'
        GROUP BY ESYear, ESMonth
    ),
    PMS_UXY AS (
        SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS ClaimCount
        FROM dbo.BeechTree_ES_PMS
        WHERE RoleID IN ('U','X','Y')
        GROUP BY ESYear, ESMonth
    ),
    PMS_Adjudicated AS (
        SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS ClaimCount
        FROM dbo.BeechTree_ES_PMS
        WHERE RoleID IN ('U','V','W','X','Y','Z.1','Z.3')
        GROUP BY ESYear, ESMonth
    )
    INSERT INTO dbo.BeechTree_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount,
           CASE WHEN ClaimCount > 0 THEN PayTotal / ClaimCount ELSE 0 END, GETDATE()
    FROM
    (
        -- AK  Average Payment ($) - Total Pay/Billed Claims = SUM(AC,AD,AE) / R
        SELECT p.ESYear, p.ESMonth, 'AK' AS RoleID,
               'Average Payment ($) - Total Pay/Billed Claims' AS Description,
               ISNULL(r.ClaimCount, 0)  AS ClaimCount,
               ISNULL(ct.PayTotal, 0)   AS PayTotal
        FROM #Periods p
        LEFT JOIN CashTotal ct ON ct.ESYear = p.ESYear AND ct.ESMonth = p.ESMonth
        LEFT JOIN PMS_R      r ON r.ESYear  = p.ESYear AND r.ESMonth  = p.ESMonth

        -- AL  Average Payment ($) - Total Pay/Paid Claims = SUM(AC,AD,AE) / SUM(U,X,Y)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AL',
               'Average Payment ($) - Total Pay/Paid Claims',
               ISNULL(uxy.ClaimCount, 0),
               ISNULL(ct.PayTotal, 0)
        FROM #Periods p
        LEFT JOIN CashTotal ct  ON ct.ESYear  = p.ESYear AND ct.ESMonth  = p.ESMonth
        LEFT JOIN PMS_UXY   uxy ON uxy.ESYear = p.ESYear AND uxy.ESMonth = p.ESMonth

        -- AM  Average Payment ($) - Total Pay/Adjudicated Claims
        --     = SUM(AC,AD,AE) / SUM(U,V,W,X,Y,Z.1,Z.3)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'AM',
               'Average Payment ($) - Total Pay/Adjudicated Claims',
               ISNULL(adj.ClaimCount, 0),
               ISNULL(ct.PayTotal, 0)
        FROM #Periods p
        LEFT JOIN CashTotal       ct  ON ct.ESYear  = p.ESYear AND ct.ESMonth  = p.ESMonth
        LEFT JOIN PMS_Adjudicated adj ON adj.ESYear = p.ESYear AND adj.ESMonth = p.ESMonth
    ) avgrows;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;

    PRINT 'usp_RefreshBT_ExecutiveSummary completed.';
END;
GO

PRINT '16_BeechTree_ExecutiveSummary_Aggregate.sql completed.';
GO

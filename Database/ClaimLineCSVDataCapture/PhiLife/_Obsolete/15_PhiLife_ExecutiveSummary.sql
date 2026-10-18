-- ============================================================
-- PhiLife – Executive Summary Read SP
-- File : 15_PhiLife_ExecutiveSummary.sql
-- DB   : PhiLife_LRN
--
-- Pattern (mirrors Collection Summary):
--   No filters  → reads Phi_ES_Data aggregate table (instant)
--   Any filter  → live query on ClaimLevelData
--
-- Run 16_PhiLife_ExecutiveSummary_Aggregate.sql first to create
-- the Phi_ES_Data table and usp_RefreshPhi_ExecutiveSummary.
--
-- RoleID scheme (per updated logic spec):
--   LIS  : Total / A (+A.<Panelname> dynamic) / A1-A8 (+ sub-rows A1.1, A2.1-A2.3, A4.1-A4.2,
--          A5.1-A5.2, A6.1-A6.2, A7.1-A7.2) / B / B1-B5 (+ sub-rows B1.1-B1.2)
--   PMS  : Q, R (Billed Mismatches – cross-table), S, T, U, V, W, X, Y (+ Y.1-Y.3)
--   Cash : Z, AA-AH, AF, AI (+ AI.1-AI.3)
--   Avg  : AJ, AK, AL (unchanged)
--
-- 'R' (Billed Mismatches) compares Billed counts in #Base vs. dbo.LIMSMaster.
-- PhiLife currently has no dbo.LIMSMaster table, so R degenerates to R = Q
-- (same documented fallback used for PCRLOA's analogous 'J' row).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_ExecutiveSummary
(
    @YearFrom  INT = NULL,
    @YearTo    INT = NULL,
    @MonthFrom INT = NULL,
    @MonthTo   INT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- ── No-filter path: serve from pre-computed aggregate table (if populated) ─
    IF @YearFrom IS NULL AND @YearTo IS NULL AND @MonthFrom IS NULL AND @MonthTo IS NULL
       AND EXISTS (SELECT 1 FROM dbo.Phi_ES_Data)
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
        FROM   dbo.Phi_ES_Data
        ORDER  BY BillYear, BillMonth, RowCode;
        RETURN;
    END;
    -- Phi_ES_Data is empty (refresh not yet run) → fall through to live query

    -- ── Filtered path: live query on ClaimLevelData ──────────────────────────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        YEAR (TRY_CAST(DateofService AS DATE))  AS BillYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS BillMonth,
        ISNULL(BilledUnbilled, '')              AS BilledUnbilled,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(Panelname,  '')                  AS Panelname,
        ISNULL(PayerType,  '')                  AS PayerType,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        CASE
            WHEN FirstBilledDate IS NOT NULL THEN 1
            WHEN ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> '' THEN 1
            ELSE 0
        END AS IsResulted
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo);

    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT BillYear, BillMonth INTO #Periods FROM #Base
    UNION ALL SELECT 0, 0;

    -- ── 'R' Billed-Mismatch support: pre-aggregate Billed counts ─────────────
    DROP TABLE IF EXISTS #BaseBilledCount;
    SELECT BillYear, BillMonth, COUNT(DISTINCT AccessionNumber) AS BilledCount
    INTO #BaseBilledCount
    FROM #Base
    WHERE BilledUnbilled = 'Billed'
    GROUP BY BillYear, BillMonth
    UNION ALL
    SELECT 0, 0, COUNT(DISTINCT AccessionNumber) FROM #Base WHERE BilledUnbilled = 'Billed';

    DROP TABLE IF EXISTS #LisBilled;
    CREATE TABLE #LisBilled
    (
        Accession      NVARCHAR(100) NOT NULL,
        BilledUnbilled NVARCHAR(50)  NOT NULL,
        BillYear       INT           NOT NULL,
        BillMonth      INT           NOT NULL
    );

    IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
    BEGIN
        INSERT INTO #LisBilled (Accession, BilledUnbilled, BillYear, BillMonth)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))),
            LTRIM(RTRIM(ISNULL(BilledorNot, ''))),
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE))
        FROM dbo.LIMSMaster
        WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
          AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(RequestCollectDate AS DATE)) >= @YearFrom)
          AND (@YearTo    IS NULL OR YEAR (TRY_CAST(RequestCollectDate AS DATE)) <= @YearTo)
          AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(RequestCollectDate AS DATE)) >= @MonthFrom)
          AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(RequestCollectDate AS DATE)) <= @MonthTo);
    END

    DROP TABLE IF EXISTS #LisBilledCount;
    SELECT BillYear, BillMonth, COUNT(DISTINCT Accession) AS BilledCount
    INTO #LisBilledCount
    FROM #LisBilled
    WHERE BilledUnbilled = 'Billed'
    GROUP BY BillYear, BillMonth
    UNION ALL
    SELECT 0, 0, COUNT(DISTINCT Accession) FROM #LisBilled WHERE BilledUnbilled = 'Billed';

    ;WITH Metrics AS
    (
        -- ── LIS Breakdown ────────────────────────────────────────────────
        SELECT p.BillYear,p.BillMonth,'Total' AS RowCode,'LIS' AS Category,'Total Samples' AS Description,CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A','LIS','Billable Samples - Resulted',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 GROUP BY p.BillYear,p.BillMonth
        -- A sub-panels: dynamic – one row per distinct Panelname
        -- RowCode = 'A.' + Panelname so rows sort directly under 'A'
        UNION ALL
        SELECT
            p.BillYear, p.BillMonth,
            'A.' + LTRIM(RTRIM(b.Panelname))  AS RowCode,
            'LIS'                              AS Category,
            '  ' + LTRIM(RTRIM(b.Panelname))  AS Description,
            CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue
        FROM #Periods p
        LEFT JOIN #Base b
             ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth))
             AND b.IsResulted=1
             AND b.Panelname <> ''
        GROUP BY p.BillYear, p.BillMonth, LTRIM(RTRIM(b.Panelname))
        UNION ALL SELECT p.BillYear,p.BillMonth,'A1','LIS','Billed to Insurance',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Billed' AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A1.1','LIS','  Billed in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Billed' AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A2','LIS','Not Entered in AMD (Insurance Unbilled)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Not Entered in AMD' AND b.BilledUnbilled='Unbilled' AND b.PayerType='Insurance' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A2.1','LIS','  Received',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.BilledUnbilled='Unbilled' AND b.PayerType='Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD') GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A2.2','LIS','  Billing Review Required',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.BilledUnbilled='Unbilled' AND b.PayerType='Insurance' AND b.ClaimStatus='Billing Review Required' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A2.3','LIS','  Collected',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.BilledUnbilled='Unbilled' AND b.PayerType='Insurance' AND b.ClaimStatus='Collected' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A3','LIS','Unbilled Not Released to Payer (EDI Hold)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.BilledUnbilled='Unbilled' AND b.ClaimStatus='Entered' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A4','LIS','Client Bill',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Client Bill' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A4.1','LIS','  Not Entered in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Client Bill' AND b.ClaimStatus='Not Entered in AMD' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A4.2','LIS','  Billed',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Client Bill' AND b.ClaimStatus='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A5','LIS','Self Pay',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Self Pay' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A5.1','LIS','  Billed',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Self Pay' AND b.ClaimStatus='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A5.2','LIS','  Not Entered in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Self Pay' AND b.ClaimStatus='Not Entered in AMD' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A6','LIS','Test Entries',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType<>'No Bill' AND b.ClaimStatus='Test Entries' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A6.1','LIS','  Not Entered in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType<>'No Bill' AND b.ClaimStatus='Not Entered in AMD' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A6.2','LIS','  Billed',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType<>'No Bill' AND b.ClaimStatus='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A7','LIS','Rejected Sample',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Rejected' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A7.1','LIS','  Not Entered in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Not Entered in AMD' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A7.2','LIS','  Billed (Rejected)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'A8','LIS','Payment Method No Bill',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='No Bill' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B','LIS','Not Resulted',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B1','LIS','Not Entered in AMD (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.ClaimStatus='Not Entered in AMD' AND b.PayerType='Insurance' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B1.1','LIS','  Received',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD') GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B1.2','LIS','  Collected',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Insurance' AND b.ClaimStatus='Collected' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B2','LIS','Client Bill (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Client Bill' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B3','LIS','Test Entries (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Insurance' AND b.ClaimStatus='Test Entries' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B4','LIS','Rejected Sample (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Insurance' AND b.ClaimStatus='Rejected' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B5','LIS','Payment Method No Bill (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='No Bill' GROUP BY p.BillYear,p.BillMonth
        -- ── PMS Breakdown ────────────────────────────────────────────────
        UNION ALL SELECT p.BillYear,p.BillMonth,'Q','PMS','Billed - Includes all Claims Billed in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'R','PMS','Billed Mismatches - Non Diagnose LIS Samples', ISNULL(bb.BilledCount,0) - ISNULL(ll.BilledCount,0) FROM #Periods p LEFT JOIN #BaseBilledCount bb ON bb.BillYear=p.BillYear AND bb.BillMonth=p.BillMonth LEFT JOIN #LisBilledCount ll ON ll.BillYear=p.BillYear AND ll.BillMonth=p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'S','PMS','Unbilled - Entered to AMD - Yet to be released to Payer',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Unbilled' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'T','PMS','Fully Paid - Insurance Pay',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Paid' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'U','PMS','Fully Adjusted (Complete W/O)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Complete W/O' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'V','PMS','Patient Responsibility',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Patient Responsibility' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'W','PMS','Partially Paid',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Paid' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'X','PMS','Patient Payment',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Patient Payment' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'Y','PMS','Insurance Balance',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied') GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'Y.1','PMS','  Fully Denied',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'Y.2','PMS','  No Response',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'Y.3','PMS','  Partially Denied',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied') GROUP BY p.BillYear,p.BillMonth
        -- ── Cash Breakdown ───────────────────────────────────────────────
        UNION ALL SELECT p.BillYear,p.BillMonth,'Z','Cash','Total Billed ($)',ISNULL(SUM(b.ChargeAmount),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AA','Cash','Unbilled ($)',ISNULL(SUM(b.ChargeAmount),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Unbilled' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AB','Cash','Insurance Payment (Fully Paid) ($)',ISNULL(SUM(b.InsurancePayment),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Paid' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AC','Cash','Partially Paid ($)',ISNULL(SUM(b.InsurancePayment),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Partially Paid' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AD','Cash','Patient Payment ($)',ISNULL(SUM(b.PatientPayment),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AE','Cash','Fully Adjusted (Complete W/O) ($)',ISNULL(SUM(b.InsuranceAdjustments),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Complete W/O' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AF','Cash','Contractual Obligation W/O ($)',ISNULL(SUM(b.InsuranceAdjustments),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus<>'Complete W/O' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AG','Cash','Patient Balance ($)',ISNULL(SUM(b.PatientBalance),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AH','Cash','Patient WO ($)',ISNULL(SUM(b.PatientAdjustments),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AI','Cash','Insurance Balance ($)',ISNULL(SUM(b.InsuranceBalance),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AI.1','Cash','  Fully Denied ($)',ISNULL(SUM(b.InsuranceBalance),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='Fully Denied' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AI.2','Cash','  No Response ($)',ISNULL(SUM(b.InsuranceBalance),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus='No Response' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AI.3','Cash','  Partially Denied ($)',ISNULL(SUM(b.InsuranceBalance),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' AND b.ClaimStatus NOT IN ('No Response','Fully Denied') GROUP BY p.BillYear,p.BillMonth
        -- ── Averages ─────────────────────────────────────────────────────
        UNION ALL SELECT p.BillYear,p.BillMonth,'AJ','Avg','Avg Payment ($) Total Pay / Billed Claims',ISNULL(ROUND(SUM(CASE WHEN b.BilledUnbilled='Billed' THEN b.InsurancePayment ELSE 0 END)/NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled='Billed' THEN b.AccessionNumber END),0),2),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AK','Avg','Avg Payment ($) Total Pay / Paid Claims',ISNULL(ROUND(SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Partially Paid') THEN b.InsurancePayment ELSE 0 END)/NULLIF(COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Partially Paid') THEN b.AccessionNumber END),0),2),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AL','Avg','Avg Payment ($) Total Pay / Adjudicated Claims',ISNULL(ROUND(SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted','Fully Denied','Denied','Partially Adjusted','Partially Denied','Patient Responsibility') THEN b.InsurancePayment ELSE 0 END)/NULLIF(COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted','Fully Denied','Denied','Partially Adjusted','Partially Denied','Patient Responsibility') THEN b.AccessionNumber END),0),2),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) GROUP BY p.BillYear,p.BillMonth
    )
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
    FROM Metrics
    ORDER BY BillYear, BillMonth, RowCode;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #LisBilled;
    DROP TABLE IF EXISTS #BaseBilledCount;
    DROP TABLE IF EXISTS #LisBilledCount;
END;
GO

PRINT '15_PhiLife_ExecutiveSummary.sql completed.';
GO

-- ============================================================
-- Certus – Executive Summary PMS / Cash Detail-Rows SP (generic name)
-- File : 21_Certus_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : Certus_LRN
--
-- Mirrors Augustus\21_Augustus_ExecutiveSummaryDetailRows_PMSCash.sql.
-- Uses the GENERIC (non lab-prefixed) procedure name
-- dbo.usp_GetExecutiveSummaryDetail_PMSCash, called by
-- ExecutiveSummaryController.Detail for ANY lab's 'PMS'/'Cash' categories.
-- Each lab DB has its own copy of this SP.
--
-- Returns the underlying dbo.ClaimLevelData rows that drive a given
-- PMS RowCode (F,G,H,I,J,K,L,M,N,O,P,P.1,P.2) or
-- Cash RowCode (Q,R,S,T,U,V,W,X,X.1,X.2,X.3) or
-- Avg RowCode (Y,Z,AA) from the Executive Summary.
--
-- Same predicates as 16_Certus_ExecutiveSummary_Aggregate.sql /
-- 17_Certus_ExecutiveSummary_Read.sql / 18_Certus_ExecutiveSummary_Detail.sql.
--
-- Certus PMS RowCodes:
--   F    No. of Billed Claims
--   G    Unbilled Claims
--   H    Billed Mismatches (PMS billed side)
--   I    No. of Fully Paid Claims
--   J    No. of Patient Responsibility Claims
--   K    No. of Patient Paid Claims
--   L    No. of Adjusted/Written Off Claims
--   M    Test Patients
--   N    No. of Partially Adjusted Claims
--   O    No. of Partially Paid Claims
--   P    No. of Insurance Balance Claims
--   P.1  No. of Fully Denied Claims
--   P.2  No. of No Response from Payor Claims
--
-- Certus Cash RowCodes:
--   Q    Total Billed ($)
--   R    Unbilled Claims ($)
--   S    Insurance Payment ($)
--   T    Patient Responsibility ($)
--   U    Adjustments / Write Off ($)
--   V    Patient Paid ($)
--   W    Partially Paid ($)
--   X    Insurance Balance ($)
--   X.1  Denials
--   X.2  Partially Denied
--   X.3  No Response from Payor
--
-- @Year/@Month: 0 = all years / all months (matches grand-total period)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PMSCash
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
        ISNULL(LTRIM(RTRIM(Panelname)), '')         AS Panelname,
        LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
        LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
        DateofService,
        FirstBilledDate,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')        AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(PayerType)), '')          AS PayerType,
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
        b.ClaimStatus,
        b.PayerType,
        b.ChargeAmount,
        b.InsurancePayment,
        b.PatientPayment,
        b.InsuranceBalance,
        b.PatientBalance,
        b.InsuranceAdjustments,
        b.PatientAdjustments
    FROM #Base b
    WHERE
        -- ── PMS ──────────────────────────────────────────────────────────────
           (@RowCode = 'F'    AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'G'    AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'H'    AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'I'    AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'J'    AND b.ClaimStatus='Patient Responsibility')
        OR (@RowCode = 'K'    AND b.ClaimStatus='Patient Paid')
        OR (@RowCode = 'L'    AND b.ClaimStatus='Fully Adjusted')
        OR (@RowCode = 'M'    AND b.ClaimStatus='Test')
        OR (@RowCode = 'N'    AND b.ClaimStatus='Partially Adjusted')
        OR (@RowCode = 'O'    AND b.ClaimStatus='Partial Paid')
        OR (@RowCode = 'P'    AND b.ClaimStatus IN ('Fully Denied','No Response'))
        OR (@RowCode = 'P.1'  AND b.ClaimStatus='Fully Denied')
        OR (@RowCode = 'P.2'  AND b.ClaimStatus='No Response')
        -- ── Cash ─────────────────────────────────────────────────────────────
        OR (@RowCode = 'Q'    AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'R'    AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'S'    AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'T'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
        OR (@RowCode = 'U'    AND 1=1)   -- all rows have adjustment amounts
        OR (@RowCode = 'V'    AND b.PatientPayment > 0)
        OR (@RowCode = 'W'    AND b.ClaimStatus='Partial Paid')
        OR (@RowCode = 'X'    AND 1=1)   -- full insurance balance
        OR (@RowCode = 'X.1'  AND b.ClaimStatus='Fully Denied')
        OR (@RowCode = 'X.2'  AND b.ClaimStatus='Partially Denied')
        OR (@RowCode = 'X.3'  AND b.ClaimStatus='No Response')
        -- ── Avg (reference rows) ─────────────────────────────────────────────
        OR (@RowCode = 'Y'    AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'Z'    AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'AA'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
    ORDER BY b.DateofService, b.AccessionNumber;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '21_Certus_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO

-- ============================================================
-- Augustus – Executive Summary PMS / Cash Detail-Rows SP (generic name)
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
        -- ── PMS ──────────────────────────────────────────────────────────────
           (@RowCode = 'F'    AND b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'F.1'  AND b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM')
        OR (@RowCode = 'F.2'  AND b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq')
        OR (@RowCode = 'G'    AND (b.BillStatus='' OR b.BillStatus IS NULL) AND b.ClaimStatus<>'Billed amount 0')
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
        -- ── Cash ─────────────────────────────────────────────────────────────
        OR (@RowCode = 'P'    AND b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'P.1'  AND b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='IRCM')
        OR (@RowCode = 'P.2'  AND b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0' AND b.Source='Daq')
        OR (@RowCode = 'Q'    AND (b.BillStatus='' OR b.BillStatus IS NULL) AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'R'    AND b.InsurancePayment > 0 AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'S'    AND b.ClaimStatus='Partial Paid')
        OR (@RowCode = 'T'    AND b.PatientPayment > 0)
        OR (@RowCode = 'U'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
        OR (@RowCode = 'U.1'  AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND b.Source='Daq')
        OR (@RowCode = 'U.2'  AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB') AND b.Source='IRCM')
        OR (@RowCode = 'V'    AND 1=1)   -- all rows have adjustment amounts
        OR (@RowCode = 'W'    AND b.InsurancePayment > 0)
        OR (@RowCode = 'X'    AND 1=1)   -- full insurance balance
        OR (@RowCode = 'X.1'  AND b.ClaimStatus='Fully Denied')
        OR (@RowCode = 'X.2'  AND b.ClaimStatus='Partially Denied')
        OR (@RowCode = 'X.3'  AND b.ClaimStatus='No Response')
        -- ── Avg (reference rows) ─────────────────────────────────────────────
        OR (@RowCode = 'Y'    AND b.BillStatus='Billed' AND b.ClaimStatus<>'Billed amount 0')
        OR (@RowCode = 'Z'    AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'AA'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
    ORDER BY b.DateofService, b.AccessionNumber;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '21_Augustus_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO

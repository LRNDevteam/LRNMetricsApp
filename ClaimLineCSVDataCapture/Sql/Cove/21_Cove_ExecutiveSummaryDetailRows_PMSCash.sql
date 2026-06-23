-- ============================================================
-- Cove – Executive Summary PMS / Cash Detail-Rows SP (generic name)
-- File : 21_Cove_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : Cove_LRN
--
-- Mirrors Elixir\21_Elixir_ExecutiveSummaryDetailRows_PMSCash.sql.
-- Uses the GENERIC (non lab-prefixed) procedure name
-- dbo.usp_GetExecutiveSummaryDetail_PMSCash, called by
-- ExecutiveSummaryController.Detail for ANY lab's 'PMS'/'Cash' categories.
--
-- Returns the underlying dbo.ClaimLevelData rows that drive a given
-- PMS RowCode (F, G, H, I, J, K, L, M, N, N.1-N.3) or
-- Cash RowCode (O, P, Q, R, S, T, U, U.1-U.3) from the Executive
-- Summary — same predicates as 16_Cove_ExecutiveSummary_Aggregate.sql /
-- 17_Cove_ExecutiveSummary_Read.sql / 18_Cove_ExecutiveSummary_Detail.sql,
-- re-exposed under the generic name that ExecutiveSummaryController.Detail
-- actually invokes.
--
-- 'G' (Billed Mismatches - Accessions NA / Other Sample) is a cross-table
-- COUNT difference (ClaimLevelData vs LIMSMaster), not a drillable claim
-- list. It degenerates to the same row set as 'F' (Billed claims),
-- mirroring PhiLife's degenerate 'R' -> 'Q' and Elixir's 'I' -> 'F'
-- fallback.
--
-- PMS and Cash RowCodes do not overlap, so @Category is not needed to
-- disambiguate the WHERE clause (kept as a parameter for interface
-- compatibility with the generic controller call).
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
        ISNULL(LTRIM(RTRIM(BillStatus)),  '')      AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')      AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(PayerType)), '')        AS PayerType,
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
        b.ChargeAmount,
        b.InsurancePayment,
        b.PatientPayment,
        b.InsuranceBalance,
        b.PatientBalance,
        b.InsuranceAdjustments,
        b.PatientAdjustments
    FROM #Base b
    WHERE
        -- ── PMS ──────────────────────────────────────────────────────────
           (@RowCode = 'F'    AND b.BillStatus IN ('Billed','Billed-Client'))
        OR (@RowCode = 'G'    AND b.BillStatus IN ('Billed','Billed-Client'))  -- degenerate fallback: G = F (cross-table count, not a row list)
        OR (@RowCode = 'H'    AND b.ClaimStatus IN ('Fully Paid','Paid-Client'))
        OR (@RowCode = 'I'    AND b.ClaimStatus = 'Patient Responsibility')
        OR (@RowCode = 'J'    AND b.ClaimStatus = 'Fully Adjusted')
        OR (@RowCode = 'K'    AND b.ClaimStatus = 'Partially Adjusted')
        OR (@RowCode = 'L'    AND b.ClaimStatus = 'Partially Paid')
        OR (@RowCode = 'M'    AND b.ClaimStatus = 'Patient Payment')
        OR (@RowCode = 'N'    AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response','No Response-Client'))
        OR (@RowCode = 'N.1'  AND b.ClaimStatus = 'Fully Denied')
        OR (@RowCode = 'N.2'  AND b.ClaimStatus = 'Partially Denied')
        OR (@RowCode = 'N.3'  AND b.ClaimStatus IN ('No Response','No Response-Client'))
        -- ── Cash ─────────────────────────────────────────────────────────
        OR (@RowCode = 'O'    AND b.BillStatus IN ('Billed','Billed-Client'))
        OR (@RowCode = 'P'    AND b.ClaimStatus IN ('Fully Paid','Paid-Client'))
        OR (@RowCode = 'Q'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB','No Response','No Response-Client'))
        OR (@RowCode = 'R'    AND b.PatientPayment > 0)
        OR (@RowCode = 'S'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
        OR (@RowCode = 'T'    AND b.ClaimStatus = 'Partially Paid')
        OR (@RowCode = 'U'    AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
        OR (@RowCode = 'U.1'  AND b.ClaimStatus = 'Fully Denied')
        OR (@RowCode = 'U.2'  AND b.ClaimStatus IN ('Partially Denied','Partially Adjusted','Partially Paid','Patient Payment','Patient Responsibility'))
        OR (@RowCode = 'U.3'  AND b.ClaimStatus IN ('No Response','No Response-Client'))
    ORDER BY b.DateofService, b.AccessionNumber;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '21_Cove_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO

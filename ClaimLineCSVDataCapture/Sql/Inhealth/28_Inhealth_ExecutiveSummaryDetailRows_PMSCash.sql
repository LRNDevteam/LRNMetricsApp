-- ============================================================
-- Inhealth – Executive Summary PMS / Cash Detail-Rows SP (generic name)
-- File : 28_Inhealth_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : Inhealth_LRN
--
-- Mirrors Augustus\21_Augustus_ExecutiveSummaryDetailRows_PMSCash.sql.
-- Uses the GENERIC procedure name dbo.usp_GetExecutiveSummaryDetail_PMSCash,
-- called by ExecutiveSummaryController.Detail for ANY lab's 'PMS'/'Cash' categories.
-- Each lab DB has its own copy of this SP.
--
-- Returns underlying dbo.ClaimLevelData rows for a given Inhealth RowCode.
--
-- Inhealth PMS RowCodes (uses BillStatus column):
--   F    No. of Billed Claims               -> BillStatus='Billed'
--   G    Billed Mismatches                  -> BillStatus='Billed' (PMS side)
--   H    No. of UnBilled Claims             -> BillStatus='Unbilled'
--   H.1  Unbilled                           -> BillStatus='Unbilled' AND ClaimStatus='Unbilled'
--   H.2  Unbilled - Patient Balance         -> BillStatus='Unbilled' AND ClaimStatus='Unbilled - Patient Balance'
--   I    No. of Fully Paid Claims           -> BillStatus='Billed' AND ClaimStatus='Fully Paid'
--   J    No. of Patient Responsibility      -> BillStatus='Billed' AND ClaimStatus='Patient Responsibility'
--   K    No. of Fully Adjusted Claims       -> BillStatus='Billed' AND ClaimStatus='Complete W/O'
--   L    No. of Partially Adjusted Claims   -> BillStatus='Billed' AND ClaimStatus='Partially Adjusted'
--   M    No. of Patient Payments Claims     -> BillStatus='Billed' AND ClaimStatus='Patient Payment'
--   N    No. of Partially Paid Claims       -> BillStatus='Billed' AND ClaimStatus='Partially Paid'
--   O    No. of Insurance Balance Claims    -> BillStatus='Billed' AND ClaimStatus IN ('FullyDenied','Partially Denied','No Response')
--   O.1  No. of Denied Claims              -> BillStatus='Billed' AND ClaimStatus='FullyDenied'
--   O.2  No. of Partially Denied Claims    -> BillStatus='Billed' AND ClaimStatus='Partially Denied'
--   O.3  No. of No Response from Payor     -> BillStatus='Billed' AND ClaimStatus='No Response'
--
-- Inhealth Cash RowCodes:
--   P    Total Billed ($)                   -> BillStatus='Billed'
--   Q    Total Unbilled ($)                 -> BillStatus='Unbilled'
--   Q.1  Unbilled                           -> BillStatus='Unbilled' AND ClaimStatus='Unbilled'
--   Q.2  Unbilled - Patient Balance         -> BillStatus='Unbilled' AND ClaimStatus='Unbilled - Patient Balance'
--   R    Insurance Payment ($)              -> BillStatus='Billed' AND ClaimStatus='Fully Paid'
--   S    Patient Payments ($)               -> BillStatus='Billed'
--   T    Partially Paid ($)                 -> BillStatus='Billed' AND ClaimStatus='Partially Paid'
--   U    Patient Responsibility ($)         -> BillStatus='Billed'
--   V    Total Adjustments ($)              -> BillStatus='Billed'
--   W    Insurance Balance ($)              -> BillStatus='Billed'
--   W.1  Denials                            -> BillStatus='Billed' AND ClaimStatus='FullyDenied'
--   W.2  Partially Denied                   -> BillStatus='Billed' AND ClaimStatus='Partially Denied'
--   W.3  No Response from Payor             -> BillStatus='Billed' AND ClaimStatus='No Response'
--
-- Inhealth Avg RowCodes:
--   X    Average Payment ($) - Total Pay/Billed Claims    -> BillStatus='Billed'
--   Y    Average Payment ($) - Fully Paid/Paid Claims     -> BillStatus='Billed' AND ClaimStatus='Fully Paid'
--   Z    Average Payment ($) - Total Pay/Adjudicated      -> BillStatus='Billed' AND ClaimStatus IN (adjudicated set)
--
-- @Year/@Month: 0 = all years / all months.
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
        ISNULL(LTRIM(RTRIM(BillStatus)),  '')       AS BillStatus,
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
        -- ── PMS ──────────────────────────────────────────────────────────────
           (@RowCode = 'F'    AND b.BillStatus='Billed')
        OR (@RowCode = 'G'    AND b.BillStatus='Billed')   -- PMS billed side of mismatch
        OR (@RowCode = 'H'    AND b.BillStatus='Unbilled')
        OR (@RowCode = 'H.1'  AND b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled')
        OR (@RowCode = 'H.2'  AND b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled - Patient Balance')
        OR (@RowCode = 'I'    AND b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'J'    AND b.BillStatus='Billed' AND b.ClaimStatus='Patient Responsibility')
        OR (@RowCode = 'K'    AND b.BillStatus='Billed' AND b.ClaimStatus='Complete W/O')
        OR (@RowCode = 'L'    AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Adjusted')
        OR (@RowCode = 'M'    AND b.BillStatus='Billed' AND b.ClaimStatus='Patient Payment')
        OR (@RowCode = 'N'    AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Paid')
        OR (@RowCode = 'O'    AND b.BillStatus='Billed' AND b.ClaimStatus IN ('FullyDenied','Partially Denied','No Response'))
        OR (@RowCode = 'O.1'  AND b.BillStatus='Billed' AND b.ClaimStatus='FullyDenied')
        OR (@RowCode = 'O.2'  AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Denied')
        OR (@RowCode = 'O.3'  AND b.BillStatus='Billed' AND b.ClaimStatus='No Response')
        -- ── Cash ─────────────────────────────────────────────────────────────
        OR (@RowCode = 'P'    AND b.BillStatus='Billed')
        OR (@RowCode = 'Q'    AND b.BillStatus='Unbilled')
        OR (@RowCode = 'Q.1'  AND b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled')
        OR (@RowCode = 'Q.2'  AND b.BillStatus='Unbilled' AND b.ClaimStatus='Unbilled - Patient Balance')
        OR (@RowCode = 'R'    AND b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'S'    AND b.BillStatus='Billed')
        OR (@RowCode = 'T'    AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Paid')
        OR (@RowCode = 'U'    AND b.BillStatus='Billed')
        OR (@RowCode = 'V'    AND b.BillStatus='Billed')
        OR (@RowCode = 'W'    AND b.BillStatus='Billed')
        OR (@RowCode = 'W.1'  AND b.BillStatus='Billed' AND b.ClaimStatus='FullyDenied')
        OR (@RowCode = 'W.2'  AND b.BillStatus='Billed' AND b.ClaimStatus='Partially Denied')
        OR (@RowCode = 'W.3'  AND b.BillStatus='Billed' AND b.ClaimStatus='No Response')
        -- ── Avg ──────────────────────────────────────────────────────────────
        OR (@RowCode = 'X'    AND b.BillStatus='Billed')
        OR (@RowCode = 'Y'    AND b.BillStatus='Billed' AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'Z'    AND b.BillStatus='Billed'
                              AND b.ClaimStatus IN ('Fully Paid','Complete W/O','Patient Responsibility',
                                                    'Partially Paid','Patient Payment','FullyDenied','Partially Denied'))
    ORDER BY b.DateofService, b.AccessionNumber;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '28_Inhealth_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO

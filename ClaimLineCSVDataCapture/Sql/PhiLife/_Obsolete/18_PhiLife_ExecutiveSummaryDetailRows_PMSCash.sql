-- ============================================================
-- PhiLife – Executive Summary PMS / Cash Detail-Rows SP
-- File : 18_PhiLife_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : PhiLife_LRN
--
-- Returns the underlying ClaimLevelData rows that drive a given
-- PMS RowCode (Q, R, S, T, U, V, W, X, Y, Y.1-Y.3) or
-- Cash RowCode (Z, AA-AH, AF, AI, AI.1-AI.3) from the Executive Summary.
--
-- 'R' (Billed Mismatches – cross-table LIS check) has no separate
-- detail set for PhiLife (no dbo.LIMSMaster); it degenerates to the
-- same Billed rows as 'Q' (documented fallback, consistent with the
-- aggregate SPs in 15/16).
--
-- @Year/@Month: 0 = all years / all months (matches grand-total period)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_ExecutiveSummaryDetail_PMSCash
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
        PatientName,
        PayerName,
        ISNULL(Panelname, '')                   AS Panelname,
        ClinicName,
        BillingProvider,
        DateofService,
        FirstBilledDate,
        ISNULL(BilledUnbilled, '')               AS BilledUnbilled,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')    AS ClaimStatus,
        ISNULL(PayerType,  '')                   AS PayerType,
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
      AND (@Year=0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
      AND (@Month=0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

    SELECT
        b.AccessionNumber AS VisitNumber,
        b.PatientName,
        b.PayerName,
        b.Panelname        AS PanelName,
        b.ClinicName,
        b.BillingProvider,
        b.DateofService,
        b.FirstBilledDate,
        b.BilledUnbilled,
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
           (@RowCode = 'Q'    AND b.BilledUnbilled = 'Billed')
        OR (@RowCode = 'R'    AND b.BilledUnbilled = 'Billed')   -- degenerate fallback: R = Q (no LIMSMaster)
        OR (@RowCode = 'S'    AND b.BilledUnbilled = 'Unbilled')
        OR (@RowCode = 'T'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
        OR (@RowCode = 'U'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Complete W/O')
        OR (@RowCode = 'V'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility')
        OR (@RowCode = 'W'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
        OR (@RowCode = 'X'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment')
        OR (@RowCode = 'Y'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied'))
        OR (@RowCode = 'Y.1'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Denied')
        OR (@RowCode = 'Y.2'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
        OR (@RowCode = 'Y.3'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied'))
        -- ── Cash ─────────────────────────────────────────────────────────
        OR (@RowCode = 'Z'    AND b.BilledUnbilled = 'Billed')
        OR (@RowCode = 'AA'   AND b.BilledUnbilled = 'Unbilled')
        OR (@RowCode = 'AB'   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
        OR (@RowCode = 'AC'   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
        OR (@RowCode = 'AD'   AND b.BilledUnbilled = 'Billed')
        OR (@RowCode = 'AE'   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Complete W/O')
        OR (@RowCode = 'AF'   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus <> 'Complete W/O')
        OR (@RowCode = 'AG'   AND b.BilledUnbilled = 'Billed')
        OR (@RowCode = 'AH'   AND b.BilledUnbilled = 'Billed')
        OR (@RowCode = 'AI'   AND b.BilledUnbilled = 'Billed')
        OR (@RowCode = 'AI.1' AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Denied')
        OR (@RowCode = 'AI.2' AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
        OR (@RowCode = 'AI.3' AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('No Response','Fully Denied'))
    ORDER BY b.AccessionNumber;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '18_PhiLife_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO

-- ============================================================
-- BeechTree – Generic Executive Summary PMS/Cash Detail Rows SP
-- File : 21_BeechTree_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : BeechTree_LRN
--
-- Mirrors Augustus\21_Augustus_ExecutiveSummaryDetailRows_PMSCash.sql.
-- Deployed per-lab DB with BeechTree-specific PMS/Cash filter logic.
-- Called by C# ExecutiveSummaryController with (@Category, @RowCode, @Year, @Month).
--
-- Source: dbo.ClaimLevelData
--   Distinct key : ClaimID
--   Billed flag  : BilledUnbilled column
--
-- RowCode → filter mapping:
--
--   PMS:
--   R      Billed – Includes all Claims Billed in AMD  (BilledUnbilled='Billed')
--   S      Billed Mismatches – Non Diagnose LIS Samples
--   T      Unbilled – Entered to AMD                   (BilledUnbilled='UnBilled')
--   U      Fully Paid – Insurance Pay                  (ClaimStatus='Fully Paid')
--   V      Fully Adjusted                              (ClaimStatus='Fully Adjusted')
--   W      Patient Responsibility                      (ClaimStatus='Pat Responsibility')
--   X      Partially Paid                              (ClaimStatus='Partial Paid')
--   Y      Patient Payment                             (PatientPayment > 0)
--   Z      Insurance Balance                           (ClaimStatus IN ('Fully Denied','No Response','Partially Denied'))
--   Z.1    Fully Denied
--   Z.2    No Response
--   Z.3    Partially Denied
--
--   Cash:
--   AA     Total Billed ($)                            BilledUnbilled='Billed'
--   AB     Unbilled ($)                                BilledUnbilled='UnBilled'
--   AC     Insurance Payment (fully paid) ($)          ClaimStatus='Fully Paid' AND InsurancePayment>0
--   AD     Partially Paid ($)                          ClaimStatus='Partial Paid'
--   AE     Patient Payment ($)                         PatientPayment>0
--   AF     Fully Adjusted (Complete W/O)               ClaimStatus='Fully Adjusted'
--   AG     Contractual Obligation W/O                  InsuranceAdjustments>0
--   AH     Patient Balance ($)                         ClaimStatus NOT IN ('Unbilled','Unbilled - PB')
--   AI     Patient WO                                  PatientAdjustments>0
--   AJ     Insurance Balance ($)                       ClaimStatus IN ('Fully Denied','No Response','Partially Denied')
--
--   Avg:
--   AK     Average Payment – Total Pay/Billed Claims   BilledUnbilled='Billed'
--   AL     Average Payment – Total Pay/Paid Claims     ClaimStatus='Fully Paid'
--   AM     Average Payment – Total Pay/Adjudicated     ClaimStatus NOT IN ('Unbilled','Unbilled - PB')
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PMSCash
(
    @Category NVARCHAR(10),
    @RowCode  NVARCHAR(10),
    @Year     INT = 0,
    @Month    INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS #Base;

    SELECT
        ClaimID,
        LTRIM(RTRIM(ISNULL(PatientName,     '')))  AS PatientName,
        LTRIM(RTRIM(ISNULL(PayerName,       '')))  AS PayerName,
        ISNULL(LTRIM(RTRIM(Panelname)), '')        AS Panelname,
        LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
        LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
        DateofService,
        FirstBilledDate,
        ISNULL(LTRIM(RTRIM(BilledUnbilled)), '')   AS BillStatus,
        ISNULL(LTRIM(RTRIM(ClaimStatus)),    '')   AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(PayerType)),      '')   AS PayerType,
        ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance,
        ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(CONVERT(NVARCHAR(50), ClaimID), '') IS NOT NULL
      AND (@Year=0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
      AND (@Month=0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

    SELECT DISTINCT
        b.ClaimID        AS ClaimNumber,
        b.PatientName,
        b.PayerName,
        b.Panelname      AS PanelName,
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
           (@RowCode = 'R'    AND b.BillStatus='Billed')
        OR (@RowCode = 'S'    AND b.BillStatus='Billed' AND b.ClaimStatus='Billed amount 0')
        OR (@RowCode = 'T'    AND b.BillStatus='UnBilled')
        OR (@RowCode = 'U'    AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'V'    AND b.ClaimStatus='Fully Adjusted')
        OR (@RowCode = 'W'    AND b.ClaimStatus='Pat Responsibility')
        OR (@RowCode = 'X'    AND b.ClaimStatus='Partial Paid')
        OR (@RowCode = 'Y'    AND b.PatientPayment > 0)
        OR (@RowCode = 'Z'    AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied'))
        OR (@RowCode = 'Z.1'  AND b.ClaimStatus='Fully Denied')
        OR (@RowCode = 'Z.2'  AND b.ClaimStatus='No Response')
        OR (@RowCode = 'Z.3'  AND b.ClaimStatus='Partially Denied')
        -- ── Cash ─────────────────────────────────────────────────────────────
        OR (@RowCode = 'AA'   AND b.BillStatus='Billed')
        OR (@RowCode = 'AB'   AND b.BillStatus='UnBilled')
        OR (@RowCode = 'AC'   AND b.ClaimStatus='Fully Paid' AND b.InsurancePayment>0)
        OR (@RowCode = 'AD'   AND b.ClaimStatus='Partial Paid')
        OR (@RowCode = 'AE'   AND b.PatientPayment>0)
        OR (@RowCode = 'AF'   AND b.ClaimStatus='Fully Adjusted')
        OR (@RowCode = 'AG'   AND b.InsuranceAdjustments>0)
        OR (@RowCode = 'AH'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
        OR (@RowCode = 'AI'   AND b.PatientAdjustments>0)
        OR (@RowCode = 'AJ'   AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied'))
        -- ── Avg (return reference rows) ──────────────────────────────────────
        OR (@RowCode = 'AK'   AND b.BillStatus='Billed')
        OR (@RowCode = 'AL'   AND b.ClaimStatus='Fully Paid')
        OR (@RowCode = 'AM'   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB'))
    ORDER BY b.DateofService, b.ClaimID;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '21_BeechTree_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO

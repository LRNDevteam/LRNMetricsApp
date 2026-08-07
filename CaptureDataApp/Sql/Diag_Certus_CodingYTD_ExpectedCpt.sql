/* =============================================================================
   Diag_Certus_CodingYTD_ExpectedCpt.sql   (READ-ONLY diagnostic — run on CERTUS DB)
   -----------------------------------------------------------------------------
   Reproduces the YTD Summary window logic from usp_RefreshCodingAggregates and
   shows, per panel for a chosen year, the claim count + total billed charges
   BEFORE and AFTER the "Expected CPT <> blank" filter — so you can reconcile
   against the client's "Correct Value" column before/after deploying patch 08.

   Nothing is written. Change @Year if you need a year other than 2026.
   ============================================================================= */
SET NOCOUNT ON;

DECLARE @Year INT = 2026;

-- Same WTD window derivation as the proc (latest 2 Fri->Thu billed-date weeks).
DECLARE @WtdWeeks INT = 2;
DECLARE @MaxBill DATE =
    (SELECT MAX(TRY_CAST(FirstBillDate AS DATE))
     FROM dbo.CodingValidation
     WHERE PanelName IS NOT NULL AND PanelName <> '');
DECLARE @WtdEnd  DATE = DATEADD(DAY, (3 - (DATEDIFF(DAY, '19000101', @MaxBill) % 7) + 7) % 7, @MaxBill);
DECLARE @WtdStart DATE = DATEADD(DAY, -(7 * @WtdWeeks - 1), @WtdEnd);

IF OBJECT_ID('tempdb..#cv') IS NOT NULL DROP TABLE #cv;
SELECT
    cv.PanelName,
    cv.VisitNumber,
    cv.ExpectedCPTCode,
    cv.TotalCharge,
    b.BillDate,
    BillYear = YEAR(b.BillDate),
    Scope = CASE WHEN b.BillDate BETWEEN @WtdStart AND @WtdEnd THEN 'WTD'
                 WHEN b.BillDate < @WtdStart                   THEN 'YTD' END
INTO #cv
FROM dbo.CodingValidation cv
CROSS APPLY (SELECT BillDate = TRY_CAST(cv.FirstBillDate AS DATE)) b
WHERE cv.PanelName IS NOT NULL AND cv.PanelName <> ''
  AND b.BillDate IS NOT NULL;

-- Per-panel YTD totals: current (no filter) vs fixed (Expected CPT <> blank).
SELECT
    BillYear = @Year,
    PanelName,
    Claims_Current      = COUNT(DISTINCT VisitNumber),
    Claims_Fixed        = COUNT(DISTINCT CASE WHEN NULLIF(LTRIM(RTRIM(ExpectedCPTCode)), '') IS NOT NULL
                                              THEN VisitNumber END),
    Charges_Current     = SUM(TRY_CAST(TotalCharge AS DECIMAL(18,2))),
    Charges_Fixed       = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ExpectedCPTCode)), '') IS NOT NULL
                                   THEN TRY_CAST(TotalCharge AS DECIMAL(18,2)) END)
FROM #cv
WHERE Scope = 'YTD' AND BillYear = @Year
GROUP BY PanelName
ORDER BY PanelName;

DROP TABLE #cv;

/* =====================================================================
   Sample — NorthWest ARIA "last 30 days" (DOS cohort + Max FirstBilledDate)
   ---------------------------------------------------------------------
   Spec:
     1) Filter DateOfService to the month column (YEAR/MONTH — not a blind
        calendar date range; missing DOS days are OK)
     2) Within that DOS cohort (Fully Denied / No Response as applicable),
        AsOf = MAX(FirstBilledDate)
     3) Submitted     = FirstBilledDate age 0..30 vs AsOf (same cohort)
     4) Not submitted = same cohort excluding the 30-day window
     5) Submitted + NotSubmitted = Fully Denied (S.1) / No Response (S.3)

   Example July DOS:
     ~8000 Fully Denied rows → Max FirstBill = 2026-07-06
     → window back 30 days → count Submitted (~5600)
   ===================================================================== */

DECLARE @ESYear  int = 2026;
DECLARE @ESMonth int = 7;   -- change to 5/6/etc. to check other months

;WITH cohort AS (
    SELECT
        ClaimStatus      = ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
        ClaimType        = ISNULL(LTRIM(RTRIM(ClaimType)), ''),
        AccessionNumber  = LTRIM(RTRIM(ISNULL(AccessionNumber, ''))),
        FirstBilledDate  = TRY_CAST(FirstBilledDate AS date),
        InsuranceBalance = ISNULL(TRY_CAST(InsuranceBalance AS decimal(18,2)), 0),
        BilledFlag = CASE
            WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(50), FirstBilledDate), ''))), '') IS NOT NULL
              OR NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(50), EmedixSubmissionDate), ''))), '') IS NOT NULL
            THEN 'Billed' ELSE 'Unbilled' END
    FROM dbo.ClaimLevelData WITH (NOLOCK)
    WHERE YEAR(TRY_CAST(DateofService AS date))  = @ESYear
      AND MONTH(TRY_CAST(DateofService AS date)) = @ESMonth
      AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber, ''))), '') IS NOT NULL
),
fd AS (
    SELECT *
    FROM cohort
    WHERE ClaimType NOT IN ('ADCS - Invoice', 'Test Patient Entries')
      AND ClaimStatus = 'Fully Denied'
),
asof AS (
    SELECT AsOfDate = MAX(FirstBilledDate) FROM fd WHERE FirstBilledDate IS NOT NULL
)
SELECT
    DosYearMonth       = CONCAT(@ESYear, '-', RIGHT('0' + CAST(@ESMonth AS varchar(2)), 2)),
    FullyDeniedTotal   = (SELECT COUNT(*) FROM fd),
    MaxFirstBilledDate = a.AsOfDate,
    WindowStart        = CASE WHEN a.AsOfDate IS NOT NULL THEN DATEADD(DAY, -30, a.AsOfDate) END,
    AriaSubmitted      = (
        SELECT COUNT(*) FROM fd f
        WHERE a.AsOfDate IS NOT NULL
          AND f.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, f.FirstBilledDate, a.AsOfDate) BETWEEN 0 AND 30),
    AriaNotSubmitted   = (
        SELECT COUNT(*) FROM fd f
        WHERE a.AsOfDate IS NULL
           OR f.FirstBilledDate IS NULL
           OR DATEDIFF(DAY, f.FirstBilledDate, a.AsOfDate) NOT BETWEEN 0 AND 30),
    Check_SumEqualsFD  = (
        SELECT COUNT(*) FROM fd f
        WHERE a.AsOfDate IS NOT NULL
          AND f.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, f.FirstBilledDate, a.AsOfDate) BETWEEN 0 AND 30)
        + (
        SELECT COUNT(*) FROM fd f
        WHERE a.AsOfDate IS NULL
           OR f.FirstBilledDate IS NULL
           OR DATEDIFF(DAY, f.FirstBilledDate, a.AsOfDate) NOT BETWEEN 0 AND 30)
FROM asof a;

-- Optional Cash (InsuranceBalance) for same month
;WITH cohort AS (
    SELECT
        ClaimStatus      = ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
        ClaimType        = ISNULL(LTRIM(RTRIM(ClaimType)), ''),
        FirstBilledDate  = TRY_CAST(FirstBilledDate AS date),
        InsuranceBalance = ISNULL(TRY_CAST(InsuranceBalance AS decimal(18,2)), 0),
        BilledFlag = CASE
            WHEN NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(50), FirstBilledDate), ''))), '') IS NOT NULL
              OR NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(nvarchar(50), EmedixSubmissionDate), ''))), '') IS NOT NULL
            THEN 'Billed' ELSE 'Unbilled' END
    FROM dbo.ClaimLevelData WITH (NOLOCK)
    WHERE YEAR(TRY_CAST(DateofService AS date))  = @ESYear
      AND MONTH(TRY_CAST(DateofService AS date)) = @ESMonth
),
fd AS (
    SELECT *
    FROM cohort
    WHERE BilledFlag IN ('Billed', 'Billed - Client')
      AND ClaimType NOT IN ('ADCS - Invoice', 'Test Patient Entries')
      AND ClaimStatus = 'Fully Denied'
),
asof AS (
    SELECT AsOfDate = MAX(FirstBilledDate) FROM fd WHERE FirstBilledDate IS NOT NULL
)
SELECT
    Metric = 'Cash Fully Denied Aria (IB)',
    AsOfDate = a.AsOfDate,
    AriaSubmitted_IB = (
        SELECT ISNULL(SUM(f.InsuranceBalance), 0) FROM fd f
        WHERE a.AsOfDate IS NOT NULL
          AND f.FirstBilledDate IS NOT NULL
          AND DATEDIFF(DAY, f.FirstBilledDate, a.AsOfDate) BETWEEN 0 AND 30),
    AriaNotSubmitted_IB = (
        SELECT ISNULL(SUM(f.InsuranceBalance), 0) FROM fd f
        WHERE a.AsOfDate IS NULL
           OR f.FirstBilledDate IS NULL
           OR DATEDIFF(DAY, f.FirstBilledDate, a.AsOfDate) NOT BETWEEN 0 AND 30)
FROM asof a;

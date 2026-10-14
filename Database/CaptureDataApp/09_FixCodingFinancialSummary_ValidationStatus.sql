-- =============================================================================
-- 09_FixCodingFinancialSummary_ValidationStatus.sql
-- Client expected Financial Dashboard / Detail Breakdown (Correct Value column).
--
-- Rule : classify claims by ValidationStatus, NOT by Missing/Additional CPT charge > 0.
--
--   Missing only      = ValidationStatus = 'Missing CPTs'
--   Additional only   = ValidationStatus = 'Additional CPTs coded'
--   Both              = ValidationStatus = 'Both Missing and Additional CPTs identified'
--
--   Revenue Loss claims / billed / Total Error  = Missing only + Both
--   Revenue at Risk claims / billed             = Additional only + Both
--   Potential Loss     = SUM(MissingCPT_AvgPaidAmount)     for Missing + Both   (unchanged)
--   Potential Recoup   = SUM(AdditionalCPT_AvgPaidAmount)  for Additional + Both (unchanged)
--
-- Run on EACH lab database. Review the PREVIEW result set, then the UPDATE.
-- =============================================================================

SET NOCOUNT ON;

-- ── 1. PREVIEW: all-data totals (should match the Correct Value column) ──────
SELECT
    Metric = N'Revenue Loss claims',
    ClientExpected = 14591,   -- example from client sheet; ignore if lab differs
    Computed       = SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) IN (N'Missing CPTs', N'Both Missing and Additional CPTs identified') THEN 1 ELSE 0 END)
FROM dbo.CodingValidation
WHERE ISNULL(AccessionNo, '') <> ''
UNION ALL
SELECT
    N'Revenue Loss billed',
    17360473.20,
    SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) IN (N'Missing CPTs', N'Both Missing and Additional CPTs identified')
             THEN TRY_CAST(TotalCharge AS DECIMAL(18,2)) ELSE 0 END)
FROM dbo.CodingValidation
WHERE ISNULL(AccessionNo, '') <> ''
UNION ALL
SELECT
    N'Revenue at Risk claims',
    26482,
    SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) IN (N'Additional CPTs coded', N'Both Missing and Additional CPTs identified') THEN 1 ELSE 0 END)
FROM dbo.CodingValidation
WHERE ISNULL(AccessionNo, '') <> ''
UNION ALL
SELECT
    N'Revenue at Risk billed',
    48049278.28,
    SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) IN (N'Additional CPTs coded', N'Both Missing and Additional CPTs identified')
             THEN TRY_CAST(TotalCharge AS DECIMAL(18,2)) ELSE 0 END)
FROM dbo.CodingValidation
WHERE ISNULL(AccessionNo, '') <> ''
UNION ALL
SELECT N'Detail Missing only',      1002,
    SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Missing CPTs' THEN 1 ELSE 0 END)
FROM dbo.CodingValidation WHERE ISNULL(AccessionNo, '') <> ''
UNION ALL
SELECT N'Detail Additional only',   12893,
    SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Additional CPTs coded' THEN 1 ELSE 0 END)
FROM dbo.CodingValidation WHERE ISNULL(AccessionNo, '') <> ''
UNION ALL
SELECT N'Detail Missing & Additional', 13589,
    SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN 1 ELSE 0 END)
FROM dbo.CodingValidation WHERE ISNULL(AccessionNo, '') <> ''
UNION ALL
SELECT N'Total Error claims', 14591,
    SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) IN (N'Missing CPTs', N'Both Missing and Additional CPTs identified') THEN 1 ELSE 0 END)
FROM dbo.CodingValidation WHERE ISNULL(AccessionNo, '') <> '';

-- ── 2. PREVIEW: current CodingFinancialSummary vs computed (by WeekFolder) ───
;WITH fin AS (
    SELECT
        cv.WeekFolder,
        MissingOnlyClaims    = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Missing CPTs' THEN 1 ELSE 0 END),
        MissingOnlyBilled    = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Missing CPTs' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0),
        AdditionalOnlyClaims = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Additional CPTs coded' THEN 1 ELSE 0 END),
        AdditionalOnlyBilled = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Additional CPTs coded' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0),
        BothClaims           = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN 1 ELSE 0 END),
        BothBilled           = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0)
    FROM dbo.CodingValidation cv
    WHERE ISNULL(cv.AccessionNo, '') <> ''
    GROUP BY cv.WeekFolder
)
SELECT
    f.SummaryId,
    f.WeekFolder,
    Current_LossClaims       = f.RevenueLoss_Claims,
    New_LossClaims           = fin.MissingOnlyClaims + fin.BothClaims,
    Current_LossBilled       = f.RevenueLoss_ActualBilled,
    New_LossBilled           = fin.MissingOnlyBilled + fin.BothBilled,
    Current_AtRiskClaims     = f.RevenueAtRisk_Claims,
    New_AtRiskClaims         = fin.AdditionalOnlyClaims + fin.BothClaims,
    Current_AtRiskBilled     = f.RevenueAtRisk_ActualBilled,
    New_AtRiskBilled         = fin.AdditionalOnlyBilled + fin.BothBilled,
    Current_MissingOnly      = f.ClaimsWithMissingCPTs,
    New_MissingOnly          = fin.MissingOnlyClaims,
    Current_AdditionalOnly   = f.ClaimsWithAdditionalCPTs,
    New_AdditionalOnly       = fin.AdditionalOnlyClaims,
    Current_Both             = f.ClaimsWithBothMissingAndAdditional,
    New_Both                 = fin.BothClaims,
    Current_TotalError       = f.TotalErrorClaims,
    New_TotalError           = fin.MissingOnlyClaims + fin.BothClaims
FROM dbo.CodingFinancialSummary f
INNER JOIN fin ON fin.WeekFolder = f.WeekFolder
ORDER BY f.InsertedDateTime DESC;

-- ── 3. UPDATE per WeekFolder (KPI card reads usp_GetCodingFinancialSummary) ──
;WITH fin AS (
    SELECT
        cv.WeekFolder,
        MissingOnlyClaims    = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Missing CPTs' THEN 1 ELSE 0 END),
        MissingOnlyBilled    = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Missing CPTs' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0),
        AdditionalOnlyClaims = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Additional CPTs coded' THEN 1 ELSE 0 END),
        AdditionalOnlyBilled = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Additional CPTs coded' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0),
        BothClaims           = SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN 1 ELSE 0 END),
        BothBilled           = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(cv.ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN TRY_CAST(cv.TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0)
    FROM dbo.CodingValidation cv
    WHERE ISNULL(cv.AccessionNo, '') <> ''
    GROUP BY cv.WeekFolder
)
UPDATE f
SET f.RevenueLoss_Claims                 = fin.MissingOnlyClaims + fin.BothClaims,
    f.RevenueLoss_ActualBilled           = fin.MissingOnlyBilled + fin.BothBilled,
    f.RevenueAtRisk_Claims               = fin.AdditionalOnlyClaims + fin.BothClaims,
    f.RevenueAtRisk_ActualBilled         = fin.AdditionalOnlyBilled + fin.BothBilled,
    f.ClaimsWithMissingCPTs              = fin.MissingOnlyClaims,
    f.ClaimsWithAdditionalCPTs           = fin.AdditionalOnlyClaims,
    f.ClaimsWithBothMissingAndAdditional = fin.BothClaims,
    f.TotalErrorClaims                   = fin.MissingOnlyClaims + fin.BothClaims,
    f.InsertedDateTime                   = GETDATE()
FROM dbo.CodingFinancialSummary f
INNER JOIN fin ON fin.WeekFolder = f.WeekFolder;

PRINT CONCAT('WeekFolder rows updated: ', @@ROWCOUNT);

-- ── 4. If the latest Financial Dashboard row is a FULL-file snapshot (one
--       report covering every CodingValidation row, Total Claims like 33,476)
--       and WeekFolder did not join, stamp that latest row from ALL data.
IF NOT EXISTS (
    SELECT 1
    FROM dbo.CodingFinancialSummary f
    INNER JOIN dbo.CodingValidation cv ON cv.WeekFolder = f.WeekFolder
    WHERE f.SummaryId = (SELECT TOP 1 SummaryId FROM dbo.CodingFinancialSummary ORDER BY InsertedDateTime DESC)
)
BEGIN
    ;WITH fin AS (
        SELECT
            MissingOnlyClaims    = SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Missing CPTs' THEN 1 ELSE 0 END),
            MissingOnlyBilled    = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Missing CPTs' THEN TRY_CAST(TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0),
            AdditionalOnlyClaims = SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Additional CPTs coded' THEN 1 ELSE 0 END),
            AdditionalOnlyBilled = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Additional CPTs coded' THEN TRY_CAST(TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0),
            BothClaims           = SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN 1 ELSE 0 END),
            BothBilled           = ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ValidationStatus)) = N'Both Missing and Additional CPTs identified' THEN TRY_CAST(TotalCharge AS DECIMAL(18,2)) ELSE 0 END), 0)
        FROM dbo.CodingValidation
        WHERE ISNULL(AccessionNo, '') <> ''
    )
    UPDATE f
    SET f.RevenueLoss_Claims                 = fin.MissingOnlyClaims + fin.BothClaims,
        f.RevenueLoss_ActualBilled           = fin.MissingOnlyBilled + fin.BothBilled,
        f.RevenueAtRisk_Claims               = fin.AdditionalOnlyClaims + fin.BothClaims,
        f.RevenueAtRisk_ActualBilled         = fin.AdditionalOnlyBilled + fin.BothBilled,
        f.ClaimsWithMissingCPTs              = fin.MissingOnlyClaims,
        f.ClaimsWithAdditionalCPTs           = fin.AdditionalOnlyClaims,
        f.ClaimsWithBothMissingAndAdditional = fin.BothClaims,
        f.TotalErrorClaims                   = fin.MissingOnlyClaims + fin.BothClaims,
        f.InsertedDateTime                   = GETDATE()
    FROM dbo.CodingFinancialSummary f
    CROSS JOIN fin
    WHERE f.SummaryId = (
        SELECT TOP 1 SummaryId
        FROM dbo.CodingFinancialSummary
        ORDER BY InsertedDateTime DESC
    );

    PRINT 'Latest CodingFinancialSummary row updated from ALL CodingValidation rows (no WeekFolder match).';
END

-- ── 5. Confirm latest KPI card values ────────────────────────────────────────
SELECT TOP 1
    SummaryId,
    WeekFolder,
    RevenueLoss_Claims,
    RevenueLoss_ActualBilled,
    RevenueAtRisk_Claims,
    RevenueAtRisk_ActualBilled,
    ClaimsWithMissingCPTs,
    ClaimsWithAdditionalCPTs,
    ClaimsWithBothMissingAndAdditional,
    TotalErrorClaims
FROM dbo.CodingFinancialSummary
ORDER BY InsertedDateTime DESC;
GO

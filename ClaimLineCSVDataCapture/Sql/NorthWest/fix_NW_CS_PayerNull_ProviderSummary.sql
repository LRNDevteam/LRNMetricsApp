/* =====================================================================
   Hotfix — 3 failing NW Collection Summary refresh SPs (from live defs)
   DB: NWL_LRN

   Bugs in the SPs you pasted:
   1) InsuranceVsAging / InsuranceVsPaymentPct
      LTRIM(RTRIM(PayerName_Raw)) stays NULL when PayerName_Raw is NULL
      → INSERT fails on NOT NULL PayerName

   2) ProviderSummary
      #out has column InsurancePayment
      INSERT SELECT still uses ProcTotalPayment  ← typo / stale column name
      → Invalid column name 'ProcTotalPayment' (and related compile errors)

   Run this on NWL_LRN, then EXEC the 3 SPs (script does that at the end).
   ===================================================================== */
SET NOCOUNT ON;
GO

-- If snapshot table still has ProcTotalPayment, rename to InsurancePayment
-- (matches usp_GetNW_CS_ProviderSummary which reads InsurancePayment).
IF OBJECT_ID('dbo.NW_CS_ProviderSummary','U') IS NOT NULL
   AND COL_LENGTH('dbo.NW_CS_ProviderSummary', 'InsurancePayment') IS NULL
   AND COL_LENGTH('dbo.NW_CS_ProviderSummary', 'ProcTotalPayment') IS NOT NULL
BEGIN
    EXEC sp_rename 'dbo.NW_CS_ProviderSummary.ProcTotalPayment', 'InsurancePayment', 'COLUMN';
END
GO

-- 7. Insurance vs Aging
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.NW_CS_InsuranceVsAging;

    INSERT INTO dbo.NW_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Aging)), ''), '(blank)')))         AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))                         AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)              AS InsuranceBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Aging)), ''), '(blank)')));

    PRINT 'usp_RefreshNW_CS_InsuranceVsAging completed.';
END
GO

-- 10. Insurance vs Payment %
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
            LTRIM(RTRIM(ISNULL(Panelname, ''))) AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay,
            TRY_CAST(PaymentPercent AS DECIMAL(9,4)) AS PayPct,
            CheckDateValue =
                COALESCE(
                    TRY_CONVERT(DATE, CheckDate, 101),
                    TRY_CONVERT(DATE, CheckDate, 120),
                    TRY_CONVERT(DATE, CheckDate)
                )
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
    ),
    filtered AS
    (
        SELECT PayerName, PanelName, InsPay, PayPct
        FROM base
    ),
    agg AS
    (
        SELECT
            PayerName,
            COUNT(*) AS PanelGroupCount,
            ISNULL(SUM(InsPay), 0) AS InsurancePayment,
            ROUND(ISNULL(AVG(PayPct), 0) * 100, 0) AS PaymentPct
        FROM filtered
        GROUP BY PayerName
    ),
    grand AS
    (
        SELECT NULLIF(SUM(InsurancePayment), 0) AS Total
        FROM agg
    )
    SELECT
        a.PayerName,
        a.PanelGroupCount,
        a.InsurancePayment,
        a.PaymentPct
    INTO #out
    FROM agg a
    CROSS JOIN grand g;

    TRUNCATE TABLE dbo.NW_CS_InsuranceVsPaymentPct;

    INSERT INTO dbo.NW_CS_InsuranceVsPaymentPct
        (PayerName, NoOfPaidClaims, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT
        PayerName,
        PanelGroupCount,
        InsurancePayment,
        PaymentPct,
        GETDATE()
    FROM #out
    ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshNW_CS_InsuranceVsPaymentPct completed.';
END
GO

-- 13. Provider Summary
-- FIX: INSERT must select InsurancePayment from #out (not ProcTotalPayment).
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_ProviderSummary
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ReferringProvider))                              AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL
          AND LTRIM(RTRIM(ReferringProvider)) <> ''
        GROUP BY LTRIM(RTRIM(ReferringProvider))
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS ProviderRank,
        ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
    INTO #out
    FROM agg;

    TRUNCATE TABLE dbo.NW_CS_ProviderSummary;

    INSERT INTO dbo.NW_CS_ProviderSummary
        (ProviderRank, ReferringProvider, NoOfClaims,
         InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ProviderRank, ReferringProvider, NoOfClaims,
        InsurancePayment,   -- was ProcTotalPayment (invalid — not in #out)
        InsuranceBalance, PatientBalance, GETDATE()
    FROM #out
    ORDER BY ProviderRank;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshNW_CS_ProviderSummary completed.';
END
GO

EXEC dbo.usp_RefreshNW_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshNW_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshNW_CS_ProviderSummary;

SELECT 'NW_CS_InsuranceVsAging' AS [Table], COUNT(*) AS Rows, MAX(RefreshedAt) AS LastRun
FROM dbo.NW_CS_InsuranceVsAging
UNION ALL
SELECT 'NW_CS_InsuranceVsPaymentPct', COUNT(*), MAX(RefreshedAt)
FROM dbo.NW_CS_InsuranceVsPaymentPct
UNION ALL
SELECT 'NW_CS_ProviderSummary', COUNT(*), MAX(RefreshedAt)
FROM dbo.NW_CS_ProviderSummary;
GO

-- =====================================================================
-- Read SP used by LabMetricsDashboard DownloadExcel / Provider tab.
-- Aggregate path calls usp_GetNW_CS_ProviderSummary (NOT the Refresh SP).
-- Old live defs still selected ProcTotalPayment → Excel "Invalid column name".
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_ProviderSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ProviderRank, ReferringProvider, NoOfClaims,
               InsurancePayment AS InsurancePayments,
               InsuranceBalance, PatientBalance
        FROM   dbo.NW_CS_ProviderSummary
        ORDER  BY ProviderRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ReferringProvider))                              AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayments,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL
          AND LTRIM(RTRIM(ReferringProvider)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelType,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(ReferringProvider))
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS ProviderRank,
        ReferringProvider, NoOfClaims, InsurancePayments, InsuranceBalance, PatientBalance
    FROM agg
    ORDER BY ProviderRank;
END
GO

PRINT 'Fix_NW_CS completed (includes usp_GetNW_CS_ProviderSummary for Excel).';
GO

-- Excel path smoke test:
-- EXEC dbo.usp_GetNW_CS_ProviderSummary;

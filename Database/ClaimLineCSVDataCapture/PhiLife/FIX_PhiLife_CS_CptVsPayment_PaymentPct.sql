-- ============================================================
-- PhiLife — Fix CPT vs Payment % showing 0.00%
-- Root cause: ClaimStatus filter ('Fully Paid','Partially Paid')
--             returns no rows for PhiLife status values.
-- Fix: use InsurancePayment > 0 as the paid indicator instead.
-- Run on PhiLife_LRN database.
-- ============================================================

SET NOCOUNT ON;
GO

-- ── Fix usp_RefreshPhi_CS_CptVsPaymentPct ────────────────────────────────────
PRINT 'Recreating usp_RefreshPhi_CS_CptVsPaymentPct...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(CPTCode))                                        AS CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)             AS SumUnits,
            ISNULL(SUM(
                CASE WHEN ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                     THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END
            ), 0)                                                         AS PaidIns,
            ISNULL(SUM(
                CASE WHEN ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                     THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END
            ), 0)                                                         AS PaidChg
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg,
           CAST(CASE WHEN PaidChg > 0 THEN PaidIns * 100.0 / PaidChg ELSE 0 END AS DECIMAL(9,4)) AS PaymentPct
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.Phi_CS_CptVsPaymentPct;
    INSERT INTO dbo.Phi_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_CptVsPaymentPct completed.';
END
GO


-- ── Fix usp_GetPhi_CS_CptVsPaymentPct (live/filtered path) ───────────────────
PRINT 'Recreating usp_GetPhi_CS_CptVsPaymentPct...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_CS_CptVsPaymentPct
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
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
        SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct
        FROM   dbo.Phi_CS_CptVsPaymentPct
        ORDER  BY SumUnits DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(CPTCode))                                        AS CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)             AS SumUnits,
            ISNULL(SUM(
                CASE WHEN ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                     THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END
            ), 0)                                                         AS PaidIns,
            ISNULL(SUM(
                CASE WHEN ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                     THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END
            ), 0)                                                         AS PaidChg
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT
        CPTCode, SumUnits,
        PaidIns AS PaidInsurancePayment,
        PaidChg AS PaidChargeAmount,
        CAST(CASE WHEN PaidChg > 0 THEN PaidIns * 100.0 / PaidChg ELSE 0 END AS DECIMAL(9,4)) AS PaymentPct
    FROM agg
    ORDER BY SumUnits DESC;
END
GO


-- ── Repopulate snapshot ───────────────────────────────────────────────────────
EXEC dbo.usp_RefreshPhi_CS_CptVsPaymentPct;
PRINT 'FIX_PhiLife_CS_CptVsPayment_PaymentPct.sql completed.';
GO

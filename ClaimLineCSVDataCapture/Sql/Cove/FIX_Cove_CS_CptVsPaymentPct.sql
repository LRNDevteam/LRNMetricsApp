-- ============================================================
-- Cove — CPT vs Payment % showing 0%
-- Date: 2026-09-08
-- Run on the Cove lab database (the one with dbo.LineLevelData).
--
-- Root cause: usp_RefreshCove_CS_CptVsPaymentPct was never created,
-- so dbo.Cove_CS_CptVsPaymentPct.PaymentPct stayed at the table default (0).
-- Excel then averaged those zeros.
--
-- This script:
--   1. Ensures the snapshot table exists
--   2. Creates/replaces the refresh SP
--   3. Creates/replaces the read SP (no-filter = snapshot; filters = live)
--   4. Refreshes the snapshot and prints a spot-check
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Cove_CS_CptVsPaymentPct')
CREATE TABLE dbo.Cove_CS_CptVsPaymentPct
(
    SummaryId            INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode              NVARCHAR(50)    NOT NULL,
    SumUnits             DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaidInsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaidChargeAmount     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaymentPct           DECIMAL(9,4)    NOT NULL DEFAULT 0,
    RefreshedAt          DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

PRINT 'Creating usp_RefreshCove_CS_CptVsPaymentPct...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(CPTCode))                                      AS CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)           AS SumUnits,
            ISNULL(SUM(CASE
                WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                     OR ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidIns,
            ISNULL(SUM(CASE
                WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                     OR ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChg
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg,
           CASE WHEN PaidChg > 0
                THEN CAST(PaidIns * 100.0 / PaidChg AS DECIMAL(9,4))
                ELSE 0 END AS PaymentPct
    INTO #out
    FROM agg;

    TRUNCATE TABLE dbo.Cove_CS_CptVsPaymentPct;
    INSERT INTO dbo.Cove_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out
    ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshCove_CS_CptVsPaymentPct completed.';
END
GO

PRINT 'Creating usp_GetCove_CS_CptVsPaymentPct...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_CptVsPaymentPct
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
        SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct
        FROM   dbo.Cove_CS_CptVsPaymentPct
        ORDER  BY SumUnits DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(CPTCode))                                                    AS CPTCode,
        ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)                        AS SumUnits,
        ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                              OR ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                        THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidInsurancePayment,
        ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                              OR ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                        THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChargeAmount,
        CAST(CASE
            WHEN ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                                      OR ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                                 THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END), 0) = 0
            THEN 0
            ELSE ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                                      OR ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                                 THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0)
                 * 100.0
                 / NULLIF(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                                        OR ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                                   THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END), 0)
        END AS DECIMAL(9,4)) AS PaymentPct
    FROM dbo.LineLevelData
    WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(CPTCode))
    ORDER BY SumUnits DESC;
END
GO

PRINT 'Refreshing Cove_CS_CptVsPaymentPct...';
EXEC dbo.usp_RefreshCove_CS_CptVsPaymentPct;
GO

SELECT TOP 20
    CPTCode,
    SumUnits,
    PaidInsurancePayment,
    PaidChargeAmount,
    PaymentPct,
    RefreshedAt
FROM dbo.Cove_CS_CptVsPaymentPct
ORDER BY SumUnits DESC;

SELECT COUNT(*) AS CptRows,
       SUM(CASE WHEN PaymentPct = 0 THEN 1 ELSE 0 END) AS ZeroPctRows,
       MAX(RefreshedAt) AS LastRefresh
FROM dbo.Cove_CS_CptVsPaymentPct;
GO

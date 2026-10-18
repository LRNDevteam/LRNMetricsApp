-- =====================================================================
-- RisingTides - Collection Summary "CPT vs Payment (%)"  (client logic)
-- Run in the Rising Tides lab database.
-- Used by LabMetricsDashboard Collection Summary tab + Excel export
-- (web ExportExcel and LRN.ReportWorker CollectionReportGenerator).
--
-- Client pivot:
--   Filter  : InsurancePayment > 0
--   Rows    : CPT
--   Values  : Count   = Count of CPT (lines)
--             Average = Average of Payment %
--                       (line Payment % = InsurancePayment / ChargeAmount)
--   Grand Total Average = average over every line (not an average of CPT averages).
--
-- Source: dbo.LineLevelData.
--
-- Output columns are unchanged, so the app needs no code change:
--   SumUnits             = Count of CPT lines           (shown as the count column)
--   PaidInsurancePayment = SUM(line Payment %) in points (x100)
--   PaidChargeAmount     = lines with a Payment % x 100
--   PaymentPct           = AVG(line Payment %) in points
-- The app shows PaidInsurancePayment / PaidChargeAmount x 100 = AVG(line Payment %),
-- and its Grand Total (sum / sum) is the all-lines average, as in the client pivot.
--
-- Changes:
--   usp_RefreshRT_CS_CptVsPaymentPct : rebuilds dbo.RT_CS_CptVsPaymentPct (no-filter tab)
--   usp_GetRT_CS_CptVsPaymentPct     : filtered branch uses the same logic
-- Rollback: 36_RisingTides_CS_CptVsPaymentPct_ClientLogic_ROLLBACK.sql
-- =====================================================================

SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(CPTCode)) AS CPTCode,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))
              / NULLIF(TRY_CAST(ChargeAmount AS DECIMAL(18,2)), 0) * 100.0 AS LinePct
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
    )
    SELECT
        CPTCode,
        CAST(COUNT(*) AS DECIMAL(18,2))                          AS SumUnits,
        CAST(ISNULL(SUM(LinePct), 0) AS DECIMAL(18,2))           AS PaidIns,
        CAST(COUNT(LinePct) * 100 AS DECIMAL(18,2))              AS PaidChg,
        CAST(ISNULL(AVG(LinePct), 0) AS DECIMAL(9,4))            AS PaymentPct
    INTO #out
    FROM src
    GROUP BY CPTCode;

    TRUNCATE TABLE dbo.RT_CS_CptVsPaymentPct;
    INSERT INTO dbo.RT_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out
    ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshRT_CS_CptVsPaymentPct completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_CS_CptVsPaymentPct
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
        FROM   dbo.RT_CS_CptVsPaymentPct
        ORDER  BY SumUnits DESC, CPTCode;
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

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(CPTCode)) AS CPTCode,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))
              / NULLIF(TRY_CAST(ChargeAmount AS DECIMAL(18,2)), 0) * 100.0 AS LinePct
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        CPTCode,
        CAST(COUNT(*) AS DECIMAL(18,2))                          AS SumUnits,
        CAST(ISNULL(SUM(LinePct), 0) AS DECIMAL(18,2))           AS PaidInsurancePayment,
        CAST(COUNT(LinePct) * 100 AS DECIMAL(18,2))              AS PaidChargeAmount,
        CAST(ISNULL(AVG(LinePct), 0) AS DECIMAL(9,4))            AS PaymentPct
    FROM src
    GROUP BY CPTCode
    ORDER BY SumUnits DESC, CPTCode;
END
GO

EXEC dbo.usp_RefreshRT_CS_CptVsPaymentPct;
GO

-- Check: top CPTs and the Grand Total (Count of CPT, Average of Payment %)
SELECT TOP 15 CPTCode, CAST(SumUnits AS INT) AS [Count], CAST(PaymentPct AS DECIMAL(9,2)) AS [Average Payment %]
FROM dbo.RT_CS_CptVsPaymentPct
ORDER BY SumUnits DESC, CPTCode;

SELECT COUNT(*) AS CptRows,
       CAST(SUM(SumUnits) AS INT) AS [Grand Total Count],
       CAST(SUM(PaidInsurancePayment) / NULLIF(SUM(PaidChargeAmount), 0) * 100 AS DECIMAL(9,2)) AS [Grand Total Average %],
       MAX(RefreshedAt) AS RefreshedAt
FROM dbo.RT_CS_CptVsPaymentPct;
GO

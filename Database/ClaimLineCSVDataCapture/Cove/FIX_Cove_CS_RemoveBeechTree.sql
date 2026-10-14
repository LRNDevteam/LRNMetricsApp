-- ============================================================
-- Cove Collection — remove BeechTree SPs that were mixed into 12
-- Date: 2026-09-08
-- Run on CoveLRN. Do NOT re-run 12_Cove_CollectionSummary.sql
-- (that script DROPs Collection snapshot tables).
--
-- Errors this replaces:
--   Cannot find dbo.BT_CS_PanelAverages
--   Incorrect syntax near OR / #out already exists
--     in usp_RefreshBT_CS_PanelAverages
--   Invalid column name BilledUnbilled
--     in usp_RefreshBT_CS_InsuranceVsPaymentPct
--
-- Cove has Has BilledUnbilled = False. These SPs use Cove columns only.
-- ============================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.usp_RefreshBT_CS_PanelAverages', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_RefreshBT_CS_PanelAverages;
IF OBJECT_ID('dbo.usp_RefreshBT_CS_InsuranceVsPaymentPct', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_RefreshBT_CS_InsuranceVsPaymentPct;
GO

IF COL_LENGTH('dbo.Cove_CS_PanelAverages', 'AdjudicatedCount') IS NULL
    ALTER TABLE dbo.Cove_CS_PanelAverages ADD AdjudicatedCount INT NOT NULL CONSTRAINT DF_Cove_CS_PA_AdjCnt DEFAULT 0;
IF COL_LENGTH('dbo.Cove_CS_PanelAverages', 'AdjudicatedAmount') IS NULL
    ALTER TABLE dbo.Cove_CS_PanelAverages ADD AdjudicatedAmount DECIMAL(18,2) NOT NULL CONSTRAINT DF_Cove_CS_PA_AdjAmt DEFAULT 0;
IF COL_LENGTH('dbo.Cove_CS_PanelAverages', 'AvgAdjudicated') IS NULL
    ALTER TABLE dbo.Cove_CS_PanelAverages ADD AvgAdjudicated DECIMAL(18,2) NOT NULL CONSTRAINT DF_Cove_CS_PA_AvgAdj DEFAULT 0;
IF COL_LENGTH('dbo.Cove_CS_PanelAverages', 'ClaimCount') IS NULL
    ALTER TABLE dbo.Cove_CS_PanelAverages ADD ClaimCount INT NOT NULL CONSTRAINT DF_Cove_CS_PA_ClaimCount DEFAULT 0;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID))) AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                   AS ClaimStatus,
            LTRIM(RTRIM(FullyPaidCount))                AS FullyPaidFlag,
            TRY_CAST(FullyPaidAmount AS DECIMAL(18,2))  AS FullyPaidAmt,
            LTRIM(RTRIM(AdjucticatedCount))             AS AdjFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2)) AS AdjAmt,
            LTRIM(RTRIM(Bucket30Count))                 AS Bucket30Flag,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))   AS Bucket30Amt,
            LTRIM(RTRIM(Bucket60Count))                 AS Bucket60Flag,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))   AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) <= CAST(GETDATE() AS DATE)
          AND NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
    )
    SELECT
        PanelName,
        PayerName,
        COUNT(DISTINCT CASE WHEN ClaimStatus <> 'No Response' THEN VisitKey END)              AS ClaimCount,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN Chg    ELSE 0 END), 0)         AS TotalCharges,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN InsPay ELSE 0 END), 0)         AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN FullyPaidFlag = 'Fully Paid' THEN VisitKey END)              AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FullyPaidFlag = 'Fully Paid' THEN FullyPaidAmt ELSE 0 END), 0)   AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN AdjFlag = 'Adjucticated' THEN VisitKey END)                  AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjFlag = 'Adjucticated' THEN AdjAmt ELSE 0 END), 0)             AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Bucket30Flag = '30+' THEN VisitKey END)                      AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30Flag = '30+' THEN Bucket30Amt ELSE 0 END), 0)            AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Bucket60Flag = '60+' THEN VisitKey END)                      AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60Flag = '60+' THEN Bucket60Amt ELSE 0 END), 0)            AS Days60Amount
    INTO #out
    FROM src
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.Cove_CS_PanelAverages;

    INSERT INTO dbo.Cove_CS_PanelAverages
        (PanelName, PayerName,
         NoOfClaims, ClaimCount, TotalCharges, CarrierPayment, AvgCarrierPayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Days30Count, Days30Amount, AvgDays30,
         Days60Count, Days60Amount, AvgDays60,
         RefreshedAt)
    SELECT
        PanelName, PayerName,
        ClaimCount, ClaimCount, TotalCharges, CarrierPayment,
        CASE WHEN ClaimCount > 0 THEN CarrierPayment / ClaimCount ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count, Days30Amount,
        CASE WHEN Days30Count > 0 THEN Days30Amount / Days30Count ELSE 0 END,
        Days60Count, Days60Amount,
        CASE WHEN Days60Count > 0 THEN Days60Amount / Days60Count ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerName;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshCove_CS_PanelAverages completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))     AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    )
    SELECT
        PayerName,
        COUNT(PanelName)                       AS PanelGroupCount,
        ISNULL(SUM(InsPay), 0)                 AS InsurancePayment,
        ROUND(ISNULL(AVG(PayPct), 0) * 100, 0) AS PaymentPct
    INTO #out
    FROM base
    GROUP BY PayerName;

    TRUNCATE TABLE dbo.Cove_CS_InsuranceVsPaymentPct;
    INSERT INTO dbo.Cove_CS_InsuranceVsPaymentPct
        (PayerName, PanelGroupCount, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct, GETDATE()
    FROM #out
    ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshCove_CS_InsuranceVsPaymentPct completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelAverages
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
        SELECT  PanelName, PayerName,
                NoOfClaims,
                NoOfClaims        AS ClaimCount,
                TotalCharges,     CarrierPayment,
                FullyPaidCount,   FullyPaidAmount,
                AdjudicatedCount, AdjudicatedAmount,
                Days30Count,      Days30Amount,
                Days60Count,      Days60Amount
        FROM    dbo.Cove_CS_PanelAverages
        ORDER BY PanelName, PayerName;
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
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID))) AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))      AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))      AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                        AS ClaimStatus,
            LTRIM(RTRIM(FullyPaidCount))                     AS FullyPaidFlag,
            TRY_CAST(FullyPaidAmount    AS DECIMAL(18,2))    AS FullyPaidAmt,
            LTRIM(RTRIM(AdjucticatedCount))                  AS AdjFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))    AS AdjAmt,
            LTRIM(RTRIM(Bucket30Count))                      AS Bucket30Flag,
            TRY_CAST(Bucket30Amount     AS DECIMAL(18,2))    AS Bucket30Amt,
            LTRIM(RTRIM(Bucket60Count))                      AS Bucket60Flag,
            TRY_CAST(Bucket60Amount     AS DECIMAL(18,2))    AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
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
        PanelName, PayerName,
        COUNT(DISTINCT CASE WHEN ClaimStatus <> 'No Response' THEN VisitKey END)                  AS NoOfClaims,
        COUNT(DISTINCT CASE WHEN ClaimStatus <> 'No Response' THEN VisitKey END)                  AS ClaimCount,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN Chg    ELSE 0 END), 0)             AS TotalCharges,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN InsPay ELSE 0 END), 0)             AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN FullyPaidFlag = 'Fully Paid'   THEN VisitKey END)                AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FullyPaidFlag = 'Fully Paid'   THEN FullyPaidAmt ELSE 0 END), 0)     AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN AdjFlag      = 'Adjucticated'  THEN VisitKey END)                AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjFlag      = 'Adjucticated'  THEN AdjAmt       ELSE 0 END), 0)     AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Bucket30Flag  = '30+'           THEN VisitKey END)               AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30Flag  = '30+'           THEN Bucket30Amt  ELSE 0 END), 0)    AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Bucket60Flag  = '60+'           THEN VisitKey END)               AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60Flag  = '60+'           THEN Bucket60Amt  ELSE 0 END), 0)    AS Days60Amount
    FROM src
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, PayerName;
END
GO

PRINT 'Refreshing Cove Panel Averages and Insurance vs Payment %...';
EXEC dbo.usp_RefreshCove_CS_PanelAverages;
EXEC dbo.usp_RefreshCove_CS_InsuranceVsPaymentPct;

SELECT 'Cove_CS_PanelAverages' AS [Table], COUNT(*) AS Rows, MAX(RefreshedAt) AS LastRun
FROM dbo.Cove_CS_PanelAverages
UNION ALL
SELECT 'Cove_CS_InsuranceVsPaymentPct', COUNT(*), MAX(RefreshedAt)
FROM dbo.Cove_CS_InsuranceVsPaymentPct;
GO

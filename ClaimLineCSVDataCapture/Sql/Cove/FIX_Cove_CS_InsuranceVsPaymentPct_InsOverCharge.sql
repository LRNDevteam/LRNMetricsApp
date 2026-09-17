-- Cove Collection Summary — Insurance Vs Payment %
-- Payment % = SUM(InsurancePayment) / SUM(ChargeAmount) × 100
-- (same as Reimbursement Rate). Do not AVG file PaymentPercent.
-- Run on CoveLRN.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_InsuranceVsPaymentPct
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

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))    AS ChgAmt,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')              AS ClaimID
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
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
        PayerName,
        COUNT(DISTINCT ClaimID)                                           AS NoOfClaims,
        ISNULL(SUM(InsPay), 0)                                            AS InsurancePayment,
        ISNULL(SUM(ChgAmt), 0)                                            AS PaidChargeAmount,
        CAST(
            CASE WHEN ISNULL(SUM(ChgAmt), 0) = 0 THEN 0
                 ELSE ROUND(SUM(InsPay) * 100.0 / SUM(ChgAmt), 2)
            END AS DECIMAL(9,4)
        )                                                                 AS PaymentPct
    FROM base
    GROUP BY PayerName
    ORDER BY InsurancePayment DESC;
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
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))    AS ChgAmt
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    )
    SELECT
        PayerName,
        COUNT(PanelName)                       AS PanelGroupCount,
        ISNULL(SUM(InsPay), 0)                 AS InsurancePayment,
        CAST(
            CASE WHEN ISNULL(SUM(ChgAmt), 0) = 0 THEN 0
                 ELSE ROUND(SUM(InsPay) * 100.0 / SUM(ChgAmt), 2)
            END AS DECIMAL(9,4)
        )                                      AS PaymentPct
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
END
GO

EXEC dbo.usp_RefreshCove_CS_InsuranceVsPaymentPct;
GO

-- ============================================================
-- Cove Collection — Insurance Vs Payments (Correct Logic)
-- Date: 2026-09-16
-- Run on CoveLRN. Safe to re-run.
--
-- Correct Logic:
--   Filter : InsurancePayment > 0  ONLY
--   Row    : PayerName_Raw
--   Values : Claim Count = Count(ClaimID) — NOT DISTINCT
--            Insurance Payment = Sum(InsurancePayment)
--
-- NOTE: For Cove UI (payer-flat, no month columns) use
--       FIX_Cove_CS_InsuranceVsPayment_PayerFlat.sql instead.
--       This file delegates refresh/get to the payer-flat logic.
-- ============================================================
SET NOCOUNT ON;
GO

PRINT 'Creating usp_RefreshCove_CS_InsuranceVsPayment (Correct Logic = payer-flat)...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_InsuranceVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                     AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))
    ),
    grand AS
    (
        SELECT NULLIF(SUM(InsurancePayment), 0) AS TotalInsurancePayment
        FROM agg
    )
    SELECT
        a.PayerName,
        CAST(0 AS SMALLINT) AS BillYear,
        CAST(0 AS TINYINT)  AS BillMonth,
        a.NoOfPaidClaims,
        a.InsurancePayment,
        CAST(
            a.InsurancePayment * 100.0 /
            ISNULL(g.TotalInsurancePayment, 1)
            AS DECIMAL(9,4)
        ) AS PaymentPct
    INTO #out
    FROM agg a
    CROSS JOIN grand g;

    TRUNCATE TABLE dbo.Cove_CS_InsuranceVsPayment;

    INSERT INTO dbo.Cove_CS_InsuranceVsPayment
    (
        PayerName, BillYear, BillMonth,
        NoOfPaidClaims, InsurancePayment, PaymentPct, RefreshedAt
    )
    SELECT
        PayerName, BillYear, BillMonth,
        NoOfPaidClaims, InsurancePayment, PaymentPct, GETDATE()
    FROM #out
    ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;

    PRINT 'usp_RefreshCove_CS_InsuranceVsPayment completed.';
END
GO

PRINT 'Creating usp_GetCove_CS_InsuranceVsPayment (Correct Logic = payer-flat)...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_InsuranceVsPayment
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
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct
        FROM dbo.Cove_CS_InsuranceVsPayment
        ORDER BY InsurancePayment DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))
    ),
    grand AS
    (
        SELECT NULLIF(SUM(InsurancePayment), 0) AS Total
        FROM agg
    )
    SELECT
        a.PayerName,
        CAST(0 AS INT)     AS BillYear,
        CAST(0 AS TINYINT) AS BillMonth,
        a.NoOfPaidClaims,
        a.InsurancePayment,
        CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    CROSS JOIN grand g
    ORDER BY a.InsurancePayment DESC;
END
GO

PRINT 'FIX_Cove_CS_InsuranceVsPayment_CorrectLogic complete.';
GO

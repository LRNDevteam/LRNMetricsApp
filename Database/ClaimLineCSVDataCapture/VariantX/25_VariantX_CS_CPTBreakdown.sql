/* =============================================================================
   VariantX – Collection Summary CPT Breakdown (replaces CPT vs Payment %)
   Database : VariantX_LRN

   Sheet rule:
     Source  : LineLevelData
     Filter  : N/A
     Rows    : CPTCode
     Values  : Sum of Units, Sum of Charge Amount
     Sort    : Claim Count DESC (COUNT DISTINCT ClaimID)

   Keeps table/SP names for app compatibility:
     SumUnits         = SUM(Units)
     PaidChargeAmount = SUM(ChargeAmount)  (also returned as ChargeAmount)
     PaidInsurancePayment / PaymentPct = 0
   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT
            LTRIM(RTRIM(CPTCode)) AS CPTCode,
            CAST(ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS SumUnits,
            CAST(ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS TotalCharges,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT CPTCode, SumUnits, TotalCharges, ClaimCount
    INTO #out
    FROM agg;

    TRUNCATE TABLE dbo.VarX_CS_CptVsPaymentPct;

    INSERT INTO dbo.VarX_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, 0, TotalCharges, 0, GETDATE()
    FROM #out
    ORDER BY ClaimCount DESC, SumUnits DESC, CPTCode;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshVarX_CS_CptVsPaymentPct completed (CPT Breakdown).';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_CS_CptVsPaymentPct
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

    -- Always LineLevelData. Filter N/A by default; optional UI filters still apply.
    SELECT
        LTRIM(RTRIM(CPTCode)) AS CPTCode,
        CAST(ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS SumUnits,
        CAST(0 AS DECIMAL(18,2)) AS PaidInsurancePayment,
        CAST(ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS ChargeAmount,
        CAST(ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS PaidChargeAmount,
        CAST(0 AS DECIMAL(10,2)) AS PaymentPct,
        CAST(1 AS BIT) AS IsCptBreakdown
    FROM dbo.LineLevelData
    WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(CPTCode))
    ORDER BY COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) DESC,
             SUM(TRY_CAST(Units AS DECIMAL(18,2))) DESC,
             LTRIM(RTRIM(CPTCode));
END
GO

EXEC dbo.usp_RefreshVarX_CS_CptVsPaymentPct;
GO

PRINT '25_VariantX_CS_CPTBreakdown.sql completed.';
GO

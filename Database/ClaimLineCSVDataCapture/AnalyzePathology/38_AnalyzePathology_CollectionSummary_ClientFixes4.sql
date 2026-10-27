/* =============================================================================
   Analyze Pathology - Collection Summary client fixes (2026-10-27, part 2)
   Database: AnalyzePathology. Run after script 37.

   1. Monthly Summary        InsurancePayment > 0 (was <> 0) AND Posted Date in 2026.
   2. CPT vs Payment (%)     InsurancePayment > 0 (was every claim); adds Sum of
                             InsurancePayment per panel / CPT. AnP_CS2_CptVsPaymentPct
                             gains InsurancePayment. CPT rows = CPTCodeXUnitsXModifier
                             (CPTCodeList is blank on every Analyze Pathology claim);
                             fn_AnP_CS_Claims.CPTCode falls back to it.
   3. Insurance vs Payment   logic unchanged; its snapshot was last rebuilt 2026-10-08
                             because the capture app did not refresh it. Rebuilt here and
                             added to the capture app's Analyze Pathology refresh list.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'AnalyzePathology'
BEGIN
    RAISERROR('Run 38_AnalyzePathology_CollectionSummary_ClientFixes4.sql on the AnalyzePathology database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_AnP_CS_Claims
(
    @PayerNames    NVARCHAR(MAX),
    @PanelNames    NVARCHAR(MAX),
    @DosFrom       DATE,
    @DosTo         DATE,
    @FirstBillFrom DATE,
    @FirstBillTo   DATE,
    @CheckDateFrom DATE,
    @CheckDateTo   DATE
)
RETURNS TABLE
AS
RETURN
    SELECT
        ClaimKey        = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        PayerName       = n.PayerName,
        PanelName       = n.PanelName,
        ClaimStatus     = LTRIM(RTRIM(c.ClaimStatus)),
        BilledStatus    = LTRIM(RTRIM(c.BilledStatus)),
        Adjudicated     = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30        = LTRIM(RTRIM(c.Bucket30)),
        Bucket60        = LTRIM(RTRIM(c.Bucket60)),
        CheckDt         = n.CheckDt,
        ClaimCheckDt    = n.ClaimCheckDt,
        FirstBillDt     = n.FirstBill,
        ReferNo         = NULLIF(LTRIM(RTRIM(JSON_VALUE(c.AdditionalFields, N'$."Refer No"'))), N''),
        InsPay          = ISNULL(TRY_CAST(c.InsurancePayment      AS DECIMAL(18,2)), 0),
        ChargeAmt       = ISNULL(TRY_CAST(c.ChargeAmount          AS DECIMAL(18,2)), 0),
        PaymentPct      = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance      = ISNULL(TRY_CAST(c.InsuranceBalance      AS DECIMAL(18,2)), 0),
        TotalInsBalance = ISNULL(TRY_CAST(c.TotalInsuranceBalance AS DECIMAL(18,2)), 0),
        AgingDOS        = NULLIF(LTRIM(RTRIM(c.AgingDOS)), N''),
        CPTCode         = COALESCE(NULLIF(LTRIM(RTRIM(c.CPTCodeList)), N''),
                                   NULLIF(LTRIM(RTRIM(c.CPTCodeXUnitsXModifier)), N''),
                                   N'(blank)')
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName = ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)),     N''), N'Unknown'),
        CheckDt   = COALESCE(TRY_CONVERT(DATE, c.PaymentPostedDate, 101), TRY_CAST(c.PaymentPostedDate AS DATE)),
        ClaimCheckDt = COALESCE(TRY_CONVERT(DATE, c.CheckDate, 101), TRY_CAST(c.CheckDate AS DATE)),
        Dos       = TRY_CAST(c.DateOfService   AS DATE),
        FirstBill = TRY_CAST(c.FirstBilledDate AS DATE)) n
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR n.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR n.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR n.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR n.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR n.FirstBill <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR n.CheckDt   >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR n.CheckDt   <= @CheckDateTo);
GO

IF COL_LENGTH(N'dbo.AnP_CS2_CptVsPaymentPct', N'InsurancePayment') IS NULL
    ALTER TABLE dbo.AnP_CS2_CptVsPaymentPct
        ADD InsurancePayment DECIMAL(18,2) NOT NULL
            CONSTRAINT DF_AnP_CS2_CptVsPaymentPct_InsurancePayment DEFAULT (0);
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_MonthlyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Year INT = 2026;

    WITH agg AS (
        SELECT PanelName, PayerName,
               YEAR(CheckDt)            AS BillYear,
               MONTH(CheckDt)           AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND YEAR(CheckDt) = @Year
        GROUP BY PanelName, PayerName, YEAR(CheckDt), MONTH(CheckDt)
    ),
    payer AS (
        SELECT PanelName, PayerName,
               SUM(NoOfClaims)       AS PayerClaims,
               SUM(InsurancePayment) AS PayerPay
        FROM agg
        GROUP BY PanelName, PayerName
    ),
    ranked AS (
        SELECT PanelName, PayerName,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY PayerClaims DESC, PayerPay DESC, PayerName) AS PayerRank,
               SUM(PayerClaims) OVER (PARTITION BY PanelName)                         AS PanelClaims
        FROM payer
    )
    SELECT a.PanelName,
           a.PayerName,
           CAST(r.PayerRank AS INT)                                            AS PayerRank,
           a.BillYear,
           a.BillMonth,
           a.NoOfClaims,
           CAST(a.InsurancePayment AS DECIMAL(18,2))                           AS InsurancePayment,
           CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount,
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelClaims DESC, a.PanelName, r.PayerRank,
                                            a.BillYear, a.BillMonth) AS INT)   AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   CPT vs Payment % (InsurancePayment > 0; Panel -> CPTCodeList)
   RowType P = panel subtotal, C = CPT under that panel.
   TotalPaymentPct = Average(PaymentPercent) over every claim in the result.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_CptVsPaymentPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PanelName, CPTCode, ClaimKey, PaymentPct, InsPay
    INTO #b
    FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE InsPay > 0;

    DECLARE @TotalPct DECIMAL(38,6) = (SELECT AVG(PaymentPct) FROM #b);

    WITH panel AS (
        SELECT PanelName,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment,
               AVG(PaymentPct)          AS AvgPct,
               ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, PanelName) AS PanelOrd
        FROM #b
        GROUP BY PanelName
    ),
    cpt AS (
        SELECT PanelName, CPTCode,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment,
               AVG(PaymentPct)          AS AvgPct,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY COUNT(DISTINCT ClaimKey) DESC, CPTCode) AS CptOrd
        FROM #b
        GROUP BY PanelName, CPTCode
    ),
    rowsOut AS (
        SELECT CAST('P' AS CHAR(1)) AS RowType, p.PanelName, CAST(NULL AS NVARCHAR(500)) AS CPTCode,
               p.NoOfClaims, p.InsurancePayment, p.AvgPct, p.PanelOrd, CAST(0 AS BIGINT) AS CptOrd
        FROM panel p
        UNION ALL
        SELECT CAST('C' AS CHAR(1)), c.PanelName, c.CPTCode,
               c.NoOfClaims, c.InsurancePayment, c.AvgPct, p.PanelOrd, c.CptOrd
        FROM cpt c
        JOIN panel p ON p.PanelName = c.PanelName
    )
    SELECT RowType,
           PanelName,
           CPTCode,
           NoOfClaims,
           CAST(InsurancePayment AS DECIMAL(18,2))              AS InsurancePayment,
           CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2))    AS AvgPaymentPct,
           CAST(ROUND(ISNULL(@TotalPct, 0), 2) AS DECIMAL(9,2)) AS TotalPaymentPct,
           CAST(ROW_NUMBER() OVER (ORDER BY PanelOrd, CptOrd) AS INT) AS SortOrder
    FROM rowsOut
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.AnP_CS2_CptVsPaymentPct;
    INSERT INTO dbo.AnP_CS2_CptVsPaymentPct
        (RowType, PanelName, CPTCode, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder)
    EXEC dbo.usp_AnP_CS_CptVsPaymentPct_Compute;
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_CptVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_CptVsPaymentPct)
    BEGIN
        SELECT RowType, PanelName, CPTCode, NoOfClaims, InsurancePayment, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.AnP_CS2_CptVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_CptVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

EXEC dbo.usp_RefreshAnP_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshAnP_CS_CptVsPaymentPct;
EXEC dbo.usp_RefreshAnP_CS_InsuranceVsPayment;
EXEC dbo.usp_RefreshAnP_CS_InsuranceVsPaymentPct;
GO

PRINT '38_AnalyzePathology_CollectionSummary_ClientFixes4.sql completed.';
GO

SET NOEXEC OFF;
GO

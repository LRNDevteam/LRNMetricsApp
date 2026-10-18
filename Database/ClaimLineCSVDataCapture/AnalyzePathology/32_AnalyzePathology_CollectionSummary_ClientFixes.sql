/* =============================================================================
   Analyze Pathology - Collection Summary client fixes (2026-10-08)
   Database: AnalyzePathology. Same definitions as script 28; run this instead of
   re-running 28 (28 drops and rebuilds every snapshot table).

   1. Top 5 Reimbursement %  Top 5 payers by claim count (was Sum(InsurancePayment)).
   2. Top 5 Total Payments   Top 5 payers by claim count (was Sum(InsurancePayment)).
   3. Insurance vs Aging     InsuranceBalance > 0 AND ClaimStatus = No Response
                             (was TotalInsuranceBalance > 0).
   4. Panel vs Payment       Columns and current-year filter use CheckDate
                             (was PaymentPostedDate). fn_AnP_CS_Claims gains ClaimCheckDt.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'AnalyzePathology'
BEGIN
    RAISERROR('Run 32_AnalyzePathology_CollectionSummary_ClientFixes.sql on the AnalyzePathology database.', 16, 1);
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
        InsPay          = ISNULL(TRY_CAST(c.InsurancePayment      AS DECIMAL(18,2)), 0),
        ChargeAmt       = ISNULL(TRY_CAST(c.ChargeAmount          AS DECIMAL(18,2)), 0),
        PaymentPct      = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance      = ISNULL(TRY_CAST(c.InsuranceBalance      AS DECIMAL(18,2)), 0),
        TotalInsBalance = ISNULL(TRY_CAST(c.TotalInsuranceBalance AS DECIMAL(18,2)), 0),
        AgingDOS        = NULLIF(LTRIM(RTRIM(c.AgingDOS)), N''),
        CPTCode         = ISNULL(NULLIF(LTRIM(RTRIM(c.CPTCodeList)), N''), N'(blank)')
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

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_Top5ReimbursementPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               COUNT(DISTINCT ClaimKey) AS Claims,
               SUM(InsPay)              AS InsPay,
               SUM(ChargeAmt)           AS Charge,
               AVG(PaymentPct)          AS AvgPct,
               SUM(PaymentPct)          AS PctSum,
               COUNT(PaymentPct)        AS PctCnt
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimStatus IN (N'Fully Paid', N'Partially Paid')
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY Claims DESC, InsPay DESC, PayerName
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY Claims DESC, InsPay DESC, PayerName) AS INT) AS PayerRank,
           PayerName,
           CAST(InsPay AS DECIMAL(18,2))                                     AS SumInsurancePayment,
           CAST(Charge AS DECIMAL(18,2))                                     AS SumChargeAmount,
           Claims                                                            AS UniqueVisitCount,
           CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2))                 AS AvgPaymentPct,
           CAST(ROUND(ISNULL(SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0), 0), 2)
                AS DECIMAL(9,2))                                             AS TotalPaymentPct
    FROM top5
    ORDER BY PayerRank;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_Top5ReimbursementPay_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               COUNT(DISTINCT ClaimKey) AS Claims,
               SUM(InsPay)              AS InsPay
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE ClaimStatus IN (N'Fully Paid', N'Partially Paid')
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY Claims DESC, InsPay DESC, PayerName
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY Claims DESC, InsPay DESC, PayerName) AS INT) AS PayerRank,
           PayerName,
           CAST(InsPay AS DECIMAL(18,2)) AS TotalPayments,
           Claims                        AS UniqueVisitCount
    FROM top5
    ORDER BY PayerRank;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_InsuranceVsAging_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PayerName,
               ISNULL(AgingDOS, N'(blank)') AS AgingBucket,
               COUNT(DISTINCT ClaimKey)     AS VisitCount,
               SUM(InsBalance)              AS InsuranceBalance
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsBalance > 0
          AND ClaimStatus = N'No Response'
        GROUP BY PayerName, ISNULL(AgingDOS, N'(blank)')
    ),
    payer AS (
        SELECT PayerName,
               SUM(VisitCount)       AS PayerClaims,
               SUM(InsuranceBalance) AS PayerBalance
        FROM agg
        GROUP BY PayerName
    )
    SELECT a.PayerName,
           a.AgingBucket,
           a.VisitCount,
           CAST(a.InsuranceBalance AS DECIMAL(18,2)) AS InsuranceBalance,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerClaims DESC, p.PayerBalance DESC, a.PayerName,
                CASE a.AgingBucket WHEN N'Current' THEN 1 WHEN N'30+' THEN 2 WHEN N'60+' THEN 3
                                   WHEN N'90+' THEN 4 WHEN N'120+' THEN 5 ELSE 6 END) AS INT) AS SortOrder
    FROM agg a
    JOIN payer p ON p.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_PanelVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Year INT = YEAR(GETDATE());

    WITH agg AS (
        SELECT PanelName,
               YEAR(ClaimCheckDt)       AS BillYear,
               MONTH(ClaimCheckDt)      AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayments
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND YEAR(ClaimCheckDt) = @Year
        GROUP BY PanelName, YEAR(ClaimCheckDt), MONTH(ClaimCheckDt)
    ),
    panel AS (
        SELECT PanelName,
               SUM(NoOfClaims)        AS PanelClaims,
               SUM(InsurancePayments) AS PanelPay
        FROM agg
        GROUP BY PanelName
    )
    SELECT a.PanelName,
           a.BillYear,
           a.BillMonth,
           a.NoOfClaims,
           CAST(a.InsurancePayments AS DECIMAL(18,2)) AS InsurancePayments,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PanelClaims DESC, p.PanelPay DESC, a.PanelName,
                                            a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN panel p ON p.PanelName = a.PanelName
    ORDER BY SortOrder;
END
GO

EXEC dbo.usp_RefreshAnP_CS_Top5ReimbursementPct;
EXEC dbo.usp_RefreshAnP_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshAnP_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshAnP_CS_PanelVsPayment;
GO

SET NOEXEC OFF;
GO

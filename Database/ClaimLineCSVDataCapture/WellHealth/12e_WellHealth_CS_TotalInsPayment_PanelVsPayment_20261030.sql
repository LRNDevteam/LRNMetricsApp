/* =============================================================================
   WellHealth - Collection Summary client logic (2026-10-30, validation file)
   Database : WellHealth        Run after 12_WellHealth_CollectionSummary.sql / 12c / 12d

     7  Total Insurance Payment  InsurancePayment > 0 (client Grand Total); rows PayerName_Raw;
                                 Count(unique ClaimID), Sum(InsurancePayment) (was
                                 Sum(TotalPayments)), Average(Payment %); sorted by
                                 Insurance Payment (was Total Payment)
     9  Panel Vs Payment         InsurancePayment > 0 AND PaymentPostedDate not blank;
                                 rows Panel name, PaymentPostedDate month columns;
                                 Count(unique ClaimID), Sum(InsurancePayment) (was
                                 Sum(TotalPayments)); sorted by Insurance Payment
   Result contracts are unchanged (InsurancePayment / InsurancePayments columns).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'WellHealth'
BEGIN
    RAISERROR('Run 12e_WellHealth_CS_TotalInsPayment_PanelVsPayment_20261030.sql on the WellHealth database.', 16, 1);
    SET NOEXEC ON;
END
GO

/* =============================================================================
   7. Total Insurance Payment (InsurancePayment > 0; sorted by Insurance Payment)
      InsurancePayment = Sum(InsurancePayment); PaymentPct = Average(Payment %).
      (Until 2026-10-30: Sum(TotalPayments), sorted by Total Payment, see 12e.)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_InsuranceVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH p AS (
        SELECT PayerName,
               COUNT(DISTINCT ClaimKey) AS NoOfPaidClaims,
               SUM(InsPay)              AS InsurancePayment,
               AVG(PaymentPct)          AS AvgPct,
               SUM(PaymentPct)          AS PctSum,
               COUNT(PaymentPct)        AS PctCnt
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    )
    SELECT PayerName,
           0                                                 AS BillYear,
           0                                                 AS BillMonth,
           NoOfPaidClaims,
           CAST(InsurancePayment AS DECIMAL(18,2))           AS InsurancePayment,
           CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2)) AS PaymentPct,
           CAST(ROUND(ISNULL(SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0), 0), 2)
                AS DECIMAL(9,2))                             AS TotalPaymentPct,
           CAST(ROW_NUMBER() OVER (ORDER BY InsurancePayment DESC, NoOfPaidClaims DESC, PayerName) AS INT) AS SortOrder
    FROM p
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   9. Panel Vs Payment (InsurancePayment > 0 AND PaymentPostedDate not blank; Posted Date month)
      InsurancePayments = Sum(InsurancePayment) (until 2026-10-30 Sum(TotalPayments), see 12e);
      panels sorted by Insurance Payment.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_PanelVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PanelName,
               YEAR(PostedDt)           AS BillYear,
               MONTH(PostedDt)          AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND PostedDt IS NOT NULL
        GROUP BY PanelName, YEAR(PostedDt), MONTH(PostedDt)
    ),
    panel AS (
        SELECT PanelName,
               SUM(InsurancePayment) AS PanelInsPay,
               SUM(NoOfClaims)       AS PanelClaims
        FROM agg
        GROUP BY PanelName
    )
    SELECT a.PanelName,
           a.BillYear,
           a.BillMonth,
           a.NoOfClaims,
           CAST(a.InsurancePayment AS DECIMAL(18,2)) AS InsurancePayments,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PanelInsPay DESC, p.PanelClaims DESC,
                                            a.PanelName, a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN panel p ON p.PanelName = a.PanelName
    ORDER BY SortOrder;
END
GO

EXEC dbo.usp_RefreshWH_CS_InsuranceVsPayment;
EXEC dbo.usp_RefreshWH_CS_PanelVsPayment;
GO

PRINT '12e_WellHealth_CS_TotalInsPayment_PanelVsPayment_20261030.sql completed.';
GO

SET NOEXEC OFF;
GO

/* =============================================================================
   WellHealth - Collection Summary: Top 5 Reimbursement % (fix)
   Database : WellHealth        Requires : 12_WellHealth_CollectionSummary.sql

   Client pivot: Filter InsurancePayment > 0; Rows PayerName_Raw;
   Top 5 insurance by Sum of InsurancePayment, sorted by Insurance Payment;
   Payment % = Average(Payment %).

   Re-creates usp_WH_CS_Top5ReimbursementPct_Compute (same body as the
   12_WellHealth_CollectionSummary.sql section 3) and rebuilds the no-filter
   snapshot WH_CS2_Top5ReimbursementPct. Safe to re-run.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'WellHealth'
BEGIN
    RAISERROR('Run 12b_WellHealth_CS_Top5ReimbursementPct_ByInsurancePayment.sql on the WellHealth database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_Top5ReimbursementPct_Compute
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
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
        GROUP BY PayerName
    ),
    top5 AS (
        SELECT TOP 5 *
        FROM p
        ORDER BY InsPay DESC, Claims DESC, PayerName
    )
    SELECT CAST(ROW_NUMBER() OVER (ORDER BY InsPay DESC, Claims DESC, PayerName) AS INT) AS PayerRank,
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

EXEC dbo.usp_RefreshWH_CS_Top5ReimbursementPct;
GO

EXEC dbo.usp_GetWH_CS_Top5ReimbursementPct;
GO

SET NOEXEC OFF;
PRINT '12b_WellHealth_CS_Top5ReimbursementPct_ByInsurancePayment.sql completed.';
GO

/* =============================================================================
   TexasDiagnostic - Collection Summary - Insurance Vs Payments by Check Date
   File     : 13_TexasDiagnostic_CS_InsuranceVsPayment_CheckDate.sql
   Database : TexasDiagnostic        Prefix : TD
   Requires : 12_TexasDiagnostic_CollectionSummary.sql

   Filter  : InsurancePayment > 0 (CheckDate a valid date - every paid claim has one)
   Rows    : PayerName_Raw, sorted by Claim Count DESC, then Insurance Payment
   Columns : CheckDate year / month (was payer totals with BillYear = BillMonth = 0)
   Values  : Claim Count        = Count of unique ClaimID
             Insurance Payments = Sum of InsurancePayment
   PaymentPct / TotalPaymentPct (Average of Payment %) stay per payer / overall.
   Same result columns, so usp_GetTD_CS_InsuranceVsPayment, the refresh SP and
   TD_CS2_InsuranceVsPayment are unchanged.
   ============================================================================= */

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
    RAISERROR('Run 13_TexasDiagnostic_CS_InsuranceVsPayment_CheckDate.sql on the TexasDiagnostic database.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_TD_CS_InsuranceVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PayerName, ClaimKey, InsPay, PaymentPct, CheckDt
    INTO #c
    FROM dbo.fn_TD_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE InsPay > 0
      AND CheckDt IS NOT NULL;

    WITH p AS (
        SELECT PayerName,
               COUNT(DISTINCT ClaimKey) AS NoOfPaidClaims,
               SUM(InsPay)              AS InsurancePayment,
               AVG(PaymentPct)          AS AvgPct,
               SUM(PaymentPct)          AS PctSum,
               COUNT(PaymentPct)        AS PctCnt
        FROM #c
        GROUP BY PayerName
    ),
    r AS (
        SELECT PayerName, AvgPct,
               ROW_NUMBER() OVER (ORDER BY NoOfPaidClaims DESC, InsurancePayment DESC, PayerName) AS PayerRank,
               SUM(PctSum) OVER () / NULLIF(SUM(PctCnt) OVER (), 0)                               AS TotalPct
        FROM p
    ),
    m AS (
        SELECT PayerName,
               YEAR(CheckDt)            AS BillYear,
               MONTH(CheckDt)           AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfPaidClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM #c
        GROUP BY PayerName, YEAR(CheckDt), MONTH(CheckDt)
    )
    SELECT m.PayerName,
           m.BillYear,
           m.BillMonth,
           m.NoOfPaidClaims,
           CAST(m.InsurancePayment AS DECIMAL(18,2))           AS InsurancePayment,
           CAST(ROUND(ISNULL(r.AvgPct, 0), 2) AS DECIMAL(9,2))   AS PaymentPct,
           CAST(ROUND(ISNULL(r.TotalPct, 0), 2) AS DECIMAL(9,2)) AS TotalPaymentPct,
           CAST(ROW_NUMBER() OVER (ORDER BY r.PayerRank, m.BillYear, m.BillMonth) AS INT) AS SortOrder
    FROM m
    JOIN r ON r.PayerName = m.PayerName
    ORDER BY SortOrder;
END
GO

EXEC dbo.usp_RefreshTD_CS_InsuranceVsPayment;
GO

SET NOEXEC OFF;
GO

PRINT '13_TexasDiagnostic_CS_InsuranceVsPayment_CheckDate.sql completed.';
GO

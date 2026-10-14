/* =============================================================================
   WellHealth - Collection Summary fixes (13 Oct 2026)

   Panel vs Payment   InsurancePayment > 0 AND PaymentPostedDate not blank;
                      columns = PaymentPostedDate month (was CheckDate).
   Insurance vs Aging TotalInsuranceBalance > 0; value = Sum(TotalInsuranceBalance)
                      (was InsuranceBalance).

   fn_WH_CS_Claims gains TotalInsBalance (TotalInsuranceBalance, $ and , removed);
   every other column is unchanged. Same code as 12_WellHealth_CollectionSummary.sql.
   Safe to rerun.
   ============================================================================= */
IF DB_NAME() <> N'WellHealth'
BEGIN
    RAISERROR(N'Run this script on the WellHealth database.', 16, 1);
    SET NOEXEC ON;
END;
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER FUNCTION dbo.fn_WH_CS_Claims
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
        ClaimKey          = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        PayerName         = n.PayerName,
        PanelName         = n.PanelName,
        ClaimStatus       = LTRIM(RTRIM(c.ClaimStatus)),
        BilledStatus      = LTRIM(RTRIM(c.BilledStatus)),
        FirstBilledDate   = NULLIF(LTRIM(RTRIM(c.FirstBilledDate)), N''),
        Adjudicated       = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30          = LTRIM(RTRIM(c.Bucket30)),
        Bucket60          = LTRIM(RTRIM(c.Bucket60)),
        Dos               = n.Dos,
        PostedDt          = n.PostedDt,
        CheckDt           = n.CheckDt,
        InsPay            = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0),
        TotalPay          = ISNULL(TRY_CAST(c.TotalPayments    AS DECIMAL(18,2)), 0),
        ChargeAmt         = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        PaymentPct        = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance        = ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0),
        TotalInsBalance   = ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(
                                CONVERT(NVARCHAR(100), c.TotalInsuranceBalance))), N'$', N''), N',', N'')), 0),
        PatientBalance    = ISNULL(TRY_CAST(c.PatientBalance   AS DECIMAL(18,2)), 0),
        AgingDOS          = NULLIF(LTRIM(RTRIM(c.AgingDOS)), N''),
        CptCode           = ISNULL(NULLIF(LTRIM(RTRIM(c.CPTCodeXUnitsXModifier)), N''), N'(blank)'),
        ReferringProvider = NULLIF(LTRIM(RTRIM(c.ReferringProvider)), N''),
        SalesRep          = NULLIF(LTRIM(RTRIM(c.SalesRepname)), N'')
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName = ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)),     N''), N'Unknown'),
        PostedDt  = COALESCE(TRY_CONVERT(DATE, c.PaymentPostedDate, 101), TRY_CAST(c.PaymentPostedDate AS DATE)),
        CheckDt   = COALESCE(TRY_CONVERT(DATE, c.CheckDate,         101), TRY_CAST(c.CheckDate         AS DATE)),
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateofService,     101), TRY_CAST(c.DateofService     AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate,   101), TRY_CAST(c.FirstBilledDate   AS DATE))) n
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR n.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR n.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR n.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR n.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR n.FirstBill <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR n.PostedDt  >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR n.PostedDt  <= @CheckDateTo);
GO

CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_InsuranceVsAging_Compute
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
               SUM(TotalInsBalance)         AS InsuranceBalance
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE TotalInsBalance > 0
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
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerBalance DESC, p.PayerClaims DESC, a.PayerName,
                CASE a.AgingBucket WHEN N'Current' THEN 1 WHEN N'30+' THEN 2 WHEN N'60+' THEN 3
                                   WHEN N'90+' THEN 4 WHEN N'120+' THEN 5 ELSE 6 END) AS INT) AS SortOrder
    FROM agg a
    JOIN payer p ON p.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

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
               SUM(TotalPay)            AS TotalPayments,
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
               SUM(TotalPayments)    AS PanelTotalPay,
               SUM(NoOfClaims)       AS PanelClaims
        FROM agg
        GROUP BY PanelName
    )
    SELECT a.PanelName,
           a.BillYear,
           a.BillMonth,
           a.NoOfClaims,
           CAST(a.TotalPayments AS DECIMAL(18,2)) AS InsurancePayments,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PanelInsPay DESC, p.PanelTotalPay DESC, p.PanelClaims DESC,
                                            a.PanelName, a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN panel p ON p.PanelName = a.PanelName
    ORDER BY SortOrder;
END
GO

EXEC dbo.usp_RefreshWH_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshWH_CS_PanelVsPayment;
GO

SET NOEXEC OFF;
GO

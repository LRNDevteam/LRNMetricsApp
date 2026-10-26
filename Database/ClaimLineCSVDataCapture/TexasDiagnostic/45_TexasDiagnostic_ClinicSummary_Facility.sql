/* =============================================================================
   TexasDiagnostic - Clinic Summary: Facility Production / Facility Collection
   Database : TexasDiagnostic        Prefix : TD

   Client sheet (Claim Level Data; sorted by claim count):
     1  Facility Production   FirstBilledDate is a date
                              Rows   : ClinicName
                              Columns: ChargeEnteredDate month / year / total
                              Values : Count of unique ClaimID, Sum of ChargeAmount
     2  Facility Collection   InsurancePayment > 0 AND PostedDate (PaymentPostedDate) is a date
                              Rows   : ClinicName > Panelname
                              Columns: PostedDate month / year / total
                              Values : Count of unique ClaimID, Sum of InsurancePayment

   Both read SPs return one row per clinic (and panel) x month; the page and the
   Excel export add the year / grand totals. A claim has one month and one panel,
   so summing month counts gives the unique-claim totals.

   Result contract: ClinicName, PanelName, DateYear, DateMonth, ClaimCount, Amount
   (PanelName is '' for Facility Production.)
   Filters: the Clinic Summary page filters (Clinic, Sales Rep, Payer, Panel, DOS, First Bill).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
    RAISERROR('Run 45_TexasDiagnostic_ClinicSummary_Facility.sql on the TexasDiagnostic database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_TD_CLS_Claims
(
    @ClinicNames   NVARCHAR(MAX),
    @SalesRepNames NVARCHAR(MAX),
    @PayerNames    NVARCHAR(MAX),
    @PanelNames    NVARCHAR(MAX),
    @DosFrom       DATE,
    @DosTo         DATE,
    @FirstBillFrom DATE,
    @FirstBillTo   DATE
)
RETURNS TABLE
AS
RETURN
    SELECT
        ClaimKey        = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        n.ClinicName,
        n.PanelName,
        n.FirstBill,
        n.ChargeEnteredDt,
        n.PostedDt,
        ChargeAmt       = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        InsPay          = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0)
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        ClinicName      = ISNULL(NULLIF(LTRIM(RTRIM(c.ClinicName)), N''), N'(Blank)'),
        PanelName       = ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)),  N''), N'(Blank)'),
        Dos             = COALESCE(TRY_CONVERT(DATE, c.DateofService,     101), TRY_CAST(c.DateofService     AS DATE)),
        FirstBill       = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate,   101), TRY_CAST(c.FirstBilledDate   AS DATE)),
        ChargeEnteredDt = COALESCE(TRY_CONVERT(DATE, c.ChargeEnteredDate, 101), TRY_CAST(c.ChargeEnteredDate AS DATE)),
        PostedDt        = COALESCE(TRY_CONVERT(DATE, c.PaymentPostedDate, 101), TRY_CAST(c.PaymentPostedDate AS DATE))) n
    WHERE (NULLIF(LTRIM(RTRIM(@ClinicNames)), N'') IS NULL
           OR n.ClinicName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@ClinicNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@SalesRepNames)), N'') IS NULL
           OR LTRIM(RTRIM(c.SalesRepname)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@SalesRepNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR LTRIM(RTRIM(c.PayerName_Raw)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|'))
           OR LTRIM(RTRIM(c.PayerName))     IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR n.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR n.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR n.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR n.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR n.FirstBill <= @FirstBillTo);
GO

/* =============================================================================
   1. Facility Production (FirstBilledDate is a date; ChargeEnteredDate months)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_GetTD_CLS_FacilityProduction
    @ClinicNames   NVARCHAR(MAX) = NULL,
    @SalesRepNames NVARCHAR(MAX) = NULL,
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(ClinicName AS NVARCHAR(500))  AS ClinicName,
           CAST(N'' AS NVARCHAR(500))          AS PanelName,
           YEAR(ChargeEnteredDt)               AS DateYear,
           MONTH(ChargeEnteredDt)              AS DateMonth,
           COUNT(DISTINCT ClaimKey)            AS ClaimCount,
           CAST(SUM(ChargeAmt) AS DECIMAL(18,2)) AS Amount
    FROM dbo.fn_TD_CLS_Claims(@ClinicNames, @SalesRepNames, @PayerNames, @PanelNames,
                              @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo)
    WHERE FirstBill IS NOT NULL
      AND ChargeEnteredDt IS NOT NULL
    GROUP BY ClinicName, YEAR(ChargeEnteredDt), MONTH(ChargeEnteredDt)
    ORDER BY SUM(COUNT(DISTINCT ClaimKey)) OVER (PARTITION BY ClinicName) DESC,
             ClinicName, DateYear, DateMonth;
END
GO

/* =============================================================================
   2. Facility Collection (InsurancePayment > 0, PostedDate is a date; PostedDate months)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_GetTD_CLS_FacilityCollection
    @ClinicNames   NVARCHAR(MAX) = NULL,
    @SalesRepNames NVARCHAR(MAX) = NULL,
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(ClinicName AS NVARCHAR(500))  AS ClinicName,
           CAST(PanelName  AS NVARCHAR(500))  AS PanelName,
           YEAR(PostedDt)                      AS DateYear,
           MONTH(PostedDt)                     AS DateMonth,
           COUNT(DISTINCT ClaimKey)            AS ClaimCount,
           CAST(SUM(InsPay) AS DECIMAL(18,2))  AS Amount
    FROM dbo.fn_TD_CLS_Claims(@ClinicNames, @SalesRepNames, @PayerNames, @PanelNames,
                              @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo)
    WHERE InsPay > 0
      AND PostedDt IS NOT NULL
    GROUP BY ClinicName, PanelName, YEAR(PostedDt), MONTH(PostedDt)
    ORDER BY SUM(COUNT(DISTINCT ClaimKey)) OVER (PARTITION BY ClinicName) DESC,
             ClinicName,
             SUM(COUNT(DISTINCT ClaimKey)) OVER (PARTITION BY ClinicName, PanelName) DESC,
             PanelName, DateYear, DateMonth;
END
GO

PRINT '45_TexasDiagnostic_ClinicSummary_Facility.sql completed.';
GO

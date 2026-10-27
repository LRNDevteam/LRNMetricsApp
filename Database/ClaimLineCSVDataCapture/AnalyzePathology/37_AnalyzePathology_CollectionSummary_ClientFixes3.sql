/* =============================================================================
   Analyze Pathology - Collection Summary client fixes (2026-10-27)
   Database: AnalyzePathology. Run after script 36; same result shapes, so the
   snapshot tables and read SPs are unchanged.

   The year is fixed to 2026 (@Year in each procedure), per the client sheet.

   1. Monthly Summary   adds Posted Date (PaymentPostedDate) in 2026.
                        Still InsurancePayment <> 0; Count unique ClaimID, Sum InsurancePayment.
   2. Panel vs Payment  adds BilledStatus NOT IN (Unbilled, Unbilled - Self Pay),
                        Billed Date (FirstBilledDate) in 2026 and
                        Posted Date (PaymentPostedDate) in 2026.
                        Still InsurancePayment > 0; columns = Posted Date month.
   fn_AnP_CS_Claims gains FirstBillDt.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'AnalyzePathology'
BEGIN
    RAISERROR('Run 37_AnalyzePathology_CollectionSummary_ClientFixes3.sql on the AnalyzePathology database.', 16, 1);
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
        WHERE InsPay <> 0
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

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_PanelVsPayment_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Year INT = 2026;

    WITH lis AS (
        SELECT Accession, LisPanel
        FROM (
            SELECT Accession = LTRIM(RTRIM(l.Accession)),
                   LisPanel  = p.LisPanel,
                   rn        = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(l.Accession))
                                                  ORDER BY CASE WHEN p.LisPanel IS NULL THEN 1 ELSE 0 END,
                                                           l.CreatedOn DESC, l.%%physloc%%)
            FROM dbo.LIMSMaster l
            CROSS APPLY (SELECT LisPanel = NULLIF(NULLIF(REPLACE(LTRIM(RTRIM(l.PanelName)), N'GIPanel', N'GI Panel'),
                                                         N''), N'UnabletoLocate')) p
            WHERE NULLIF(LTRIM(RTRIM(l.Accession)), N'') IS NOT NULL
        ) z
        WHERE rn = 1
    ),
    src AS (
        SELECT f.ClaimKey, f.CheckDt, f.InsPay,
               PanelName = COALESCE(lis.LisPanel,
                                    CASE f.PanelName
                                        WHEN N'WH Panel/Male STI Panel' THEN N'STI'
                                        WHEN N'STI Panel'               THEN N'STI'
                                        WHEN N'UTI Panel'               THEN N'UTI'
                                        WHEN N'RPP Panel'               THEN N'RespiratoryPanel'
                                        WHEN N'Infectious Disease'      THEN N'InfectiousDisease'
                                        WHEN N'Blood + ID'              THEN N'Blood'
                                        ELSE f.PanelName
                                    END)
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) f
        LEFT JOIN lis ON lis.Accession = f.ReferNo
        WHERE ISNULL(f.BilledStatus, N'') NOT IN (N'Unbilled', N'Unbilled - Self Pay')
          AND YEAR(f.FirstBillDt) = @Year
          AND f.InsPay > 0
          AND YEAR(f.CheckDt) = @Year
    ),
    agg AS (
        SELECT PanelName,
               YEAR(CheckDt)            AS BillYear,
               MONTH(CheckDt)           AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayments
        FROM src
        GROUP BY PanelName, YEAR(CheckDt), MONTH(CheckDt)
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

EXEC dbo.usp_RefreshAnP_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshAnP_CS_PanelVsPayment;
GO

PRINT '37_AnalyzePathology_CollectionSummary_ClientFixes3.sql completed.';
GO

SET NOEXEC OFF;
GO

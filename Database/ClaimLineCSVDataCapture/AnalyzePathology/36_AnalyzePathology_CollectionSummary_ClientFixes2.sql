/* =============================================================================
   Analyze Pathology - Collection Summary client fixes (2026-10-12)
   Database: AnalyzePathology. Same definitions as script 28; run this instead of
   re-running 28 (28 drops and rebuilds every snapshot table). Needs script 34
   (fn_AnP_CS_Claims with CheckDt / TotalInsBalance / ReferNo).

   1. Monthly / Weekly       InsurancePayment <> 0 (was ClaimStatus IN (Fully Paid, Partially Paid)).
   2. Top 5 Reimbursement %  InsurancePayment > 0  (was ClaimStatus IN (Fully Paid, Partially Paid)).
   3. Top 5 Total Payments   InsurancePayment > 0  (was ClaimStatus IN (Fully Paid, Partially Paid)).
   4. Insurance vs Aging     TotalInsuranceBalance > 0
                             (was InsuranceBalance > 0 AND ClaimStatus = No Response).
   5. Panel vs Payment       PaymentPostedDate not blank; columns = PaymentPostedDate month
                             (was CheckDate in the current year; CheckDate month).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'AnalyzePathology'
BEGIN
    RAISERROR('Run 36_AnalyzePathology_CollectionSummary_ClientFixes2.sql on the AnalyzePathology database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_MonthlyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PanelName, PayerName,
               YEAR(CheckDt)            AS BillYear,
               MONTH(CheckDt)           AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                  @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay <> 0
          AND CheckDt IS NOT NULL
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

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_WeeklyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT PanelName, PayerName, ClaimKey, CheckDt, InsPay
    INTO #paid
    FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE InsPay <> 0
      AND CheckDt IS NOT NULL
      AND CheckDt <= @Today;

    -- A week counts as completed when it ends on or before today and the CheckDate-To filter.
    DECLARE @Cutoff DATE = CASE WHEN @CheckDateTo < @Today THEN @CheckDateTo ELSE @Today END;
    DECLARE @MaxCheck DATE = (SELECT MAX(CheckDt) FROM #paid);
    -- 1900-01-01 was a Monday.
    DECLARE @LastStart DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @MaxCheck) % 7), @MaxCheck);
    IF DATEADD(DAY, 6, @LastStart) > @Cutoff
        SET @LastStart = DATEADD(DAY, -7, @LastStart);
    DECLARE @FirstStart DATE = DATEADD(DAY, -21, @LastStart);
    DECLARE @LastEnd    DATE = DATEADD(DAY, 6, @LastStart);

    WITH wk AS (
        SELECT PanelName, PayerName, ClaimKey, InsPay,
               DATEDIFF(DAY, @FirstStart, CheckDt) / 7 + 1 AS WeekKey
        FROM #paid
        WHERE CheckDt BETWEEN @FirstStart AND @LastEnd
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM wk
        GROUP BY PanelName, PayerName, WeekKey
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
           CAST(a.WeekKey AS INT)                                              AS WeekKey,
           DATEADD(DAY, 7 * (a.WeekKey - 1),     @FirstStart)                  AS WeekStart,
           DATEADD(DAY, 7 * (a.WeekKey - 1) + 6, @FirstStart)                  AS WeekEnd,
           a.NoOfClaims,
           CAST(a.InsurancePayment AS DECIMAL(18,2))                           AS InsurancePayment,
           CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount,
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelClaims DESC, a.PanelName, r.PayerRank,
                                            a.WeekKey) AS INT)                 AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
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
        WHERE InsPay > 0
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
        WHERE InsPay > 0
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
        WHERE f.InsPay > 0
          AND f.CheckDt IS NOT NULL
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
EXEC dbo.usp_RefreshAnP_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshAnP_CS_Top5ReimbursementPct;
EXEC dbo.usp_RefreshAnP_CS_Top5ReimbursementPay;
EXEC dbo.usp_RefreshAnP_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshAnP_CS_PanelVsPayment;
GO

SET NOEXEC OFF;
GO

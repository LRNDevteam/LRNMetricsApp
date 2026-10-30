/* =============================================================================
   WellHealth - Collection Summary client logic (2026-10-30)
   Database : WellHealth        Run after 12_WellHealth_CollectionSummary.sql

     1  Monthly Summary   InsurancePayment > 0 (was <> 0)
     2  Weekly Summary    InsurancePayment > 0 (was <> 0)
    10  CPT vs Payment %  Line Level Data; FirstBilledDate not blank (was no filter);
                          rows Panel (the line's claim) -> CPT Code (was CPT Code only);
                          Sum(Units), Sum(ChargeAmount) (was claim count, Average Payment %);
                          sorted by claim count
   WH_CS2_CptVsPaymentPct is rebuilt with the new columns
   (RowType, PanelName, CPTCode, NoOfClaims, SumUnits, ChargeAmount, SortOrder).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'WellHealth'
BEGIN
    RAISERROR('Run 12d_WellHealth_CS_ClientLogic_20261030.sql on the WellHealth database.', 16, 1);
    SET NOEXEC ON;
END
GO

DROP TABLE IF EXISTS dbo.WH_CS2_CptVsPaymentPct;
CREATE TABLE dbo.WH_CS2_CptVsPaymentPct (
    RowType CHAR(1) NOT NULL, PanelName NVARCHAR(500) NULL, CPTCode NVARCHAR(500) NULL, NoOfClaims INT NOT NULL,
    SumUnits DECIMAL(18,2) NOT NULL, ChargeAmount DECIMAL(18,2) NOT NULL, SortOrder INT NOT NULL);
GO

/* =============================================================================
   1. Monthly Summary (Posted Date month)
      Panels sorted by Insurance Payment; payers ranked by claim count (top 3 shown).
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_MonthlyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    WITH agg AS (
        SELECT PanelName, PayerName,
               YEAR(PostedDt)           AS BillYear,
               MONTH(PostedDt)          AS BillMonth,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(InsPay)              AS InsurancePayment
        FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND PostedDt IS NOT NULL
        GROUP BY PanelName, PayerName, YEAR(PostedDt), MONTH(PostedDt)
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
               SUM(PayerClaims) OVER (PARTITION BY PanelName)                         AS PanelClaims,
               SUM(PayerPay)    OVER (PARTITION BY PanelName)                         AS PanelPay
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
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelPay DESC, r.PanelClaims DESC, a.PanelName,
                                            r.PayerRank, a.BillYear, a.BillMonth) AS INT) AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   2. Weekly Summary (Posted Date, Monday-Sunday weeks,
      last 4 completed weeks up to the latest Posted Date on or before today)
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_WeeklyClaimVolume_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);

    SELECT PanelName, PayerName, ClaimKey, PostedDt, InsPay
    INTO #paid
    FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE InsPay > 0
      AND PostedDt IS NOT NULL
      AND PostedDt <= @Today;

    -- A week counts as completed when it ends on or before today and the Posted Date-To filter.
    DECLARE @Cutoff DATE = CASE WHEN @CheckDateTo < @Today THEN @CheckDateTo ELSE @Today END;
    DECLARE @MaxPosted DATE = (SELECT MAX(PostedDt) FROM #paid);
    -- 1900-01-01 was a Monday.
    DECLARE @LastStart DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @MaxPosted) % 7), @MaxPosted);
    IF DATEADD(DAY, 6, @LastStart) > @Cutoff
        SET @LastStart = DATEADD(DAY, -7, @LastStart);
    DECLARE @FirstStart DATE = DATEADD(DAY, -21, @LastStart);
    DECLARE @LastEnd    DATE = DATEADD(DAY, 6, @LastStart);

    WITH wk AS (
        SELECT PanelName, PayerName, ClaimKey, InsPay,
               DATEDIFF(DAY, @FirstStart, PostedDt) / 7 + 1 AS WeekKey
        FROM #paid
        WHERE PostedDt BETWEEN @FirstStart AND @LastEnd
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
               SUM(PayerClaims) OVER (PARTITION BY PanelName)                         AS PanelClaims,
               SUM(PayerPay)    OVER (PARTITION BY PanelName)                         AS PanelPay
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
           CAST(ROW_NUMBER() OVER (ORDER BY r.PanelPay DESC, r.PanelClaims DESC, a.PanelName,
                                            r.PayerRank, a.WeekKey) AS INT)    AS SortOrder
    FROM agg a
    JOIN ranked r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY SortOrder;
END
GO

/* =============================================================================
   10. CPT vs Payment % (Line Level Data; FirstBilledDate not blank)
       Rows Panel (RowType P; Panelname of the line's claim, LineLevelData.Panelname is
       blank) -> CPT Code (RowType C). Values Sum(Units), Sum(ChargeAmount).
       Panels and their CPT codes sorted by Count of unique ClaimID DESC.
       Dashboard filters apply through the line's claim.
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_WH_CS_CptVsPaymentPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #k (ClaimKey NVARCHAR(450) NOT NULL PRIMARY KEY, PanelName NVARCHAR(500) NOT NULL);
    INSERT INTO #k (ClaimKey, PanelName)
    SELECT LEFT(ClaimKey, 450), MIN(PanelName)
    FROM dbo.fn_WH_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE ClaimKey IS NOT NULL
    GROUP BY LEFT(ClaimKey, 450);

    SELECT k.ClaimKey,
           k.PanelName,
           CPTCode   = ISNULL(NULLIF(LTRIM(RTRIM(l.CPTCode)), N''), N'(blank)'),
           Units     = ISNULL(TRY_CAST(l.Units AS DECIMAL(18,2)), 0),
           ChargeAmt = ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(
                           CONVERT(NVARCHAR(100), l.ChargeAmount))), N'$', N''), N',', N'')), 0)
    INTO #l
    FROM dbo.LineLevelData l
    JOIN #k k ON k.ClaimKey = LEFT(LTRIM(RTRIM(l.ClaimID)), 450)
    WHERE NULLIF(LTRIM(RTRIM(l.FirstBilledDate)), N'') IS NOT NULL;

    WITH g AS (
        SELECT CASE WHEN GROUPING(CPTCode) = 1 THEN 'P' ELSE 'C' END AS RowType,
               PanelName, CPTCode,
               COUNT(DISTINCT ClaimKey) AS NoOfClaims,
               SUM(Units)               AS SumUnits,
               SUM(ChargeAmt)           AS ChargeAmount
        FROM #l
        GROUP BY GROUPING SETS ((PanelName, CPTCode), (PanelName))
    ),
    pnl AS (
        SELECT PanelName, NoOfClaims AS PanelClaims, ChargeAmount AS PanelCharge
        FROM g
        WHERE RowType = 'P'
    )
    SELECT CAST(g.RowType AS CHAR(1))                         AS RowType,
           g.PanelName,
           CASE WHEN g.RowType = 'C' THEN g.CPTCode END       AS CPTCode,
           g.NoOfClaims,
           CAST(g.SumUnits     AS DECIMAL(18,2))              AS SumUnits,
           CAST(g.ChargeAmount AS DECIMAL(18,2))              AS ChargeAmount,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PanelClaims DESC, p.PanelCharge DESC, g.PanelName,
                                            CASE WHEN g.RowType = 'P' THEN 0 ELSE 1 END,
                                            g.NoOfClaims DESC, g.ChargeAmount DESC, g.CPTCode) AS INT) AS SortOrder
    FROM g
    JOIN pnl p ON p.PanelName = g.PanelName
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CS_CptVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_WH_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.WH_CS2_CptVsPaymentPct)
    BEGIN
        SELECT RowType, PanelName, CPTCode, NoOfClaims, SumUnits, ChargeAmount, SortOrder
        FROM dbo.WH_CS2_CptVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_WH_CS_CptVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames, @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRAN;
    DELETE FROM dbo.WH_CS2_CptVsPaymentPct;
    INSERT INTO dbo.WH_CS2_CptVsPaymentPct (RowType, PanelName, CPTCode, NoOfClaims, SumUnits, ChargeAmount, SortOrder)
    EXEC dbo.usp_WH_CS_CptVsPaymentPct_Compute;
    COMMIT;
END
GO

EXEC dbo.usp_RefreshWH_CS_MonthlyClaimVolume;
EXEC dbo.usp_RefreshWH_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshWH_CS_CptVsPaymentPct;
GO

PRINT '12d_WellHealth_CS_ClientLogic_20261030.sql completed.';
GO

SET NOEXEC OFF;
GO

-- =====================================================================
-- InHealthDTR - Collection Summary READ Stored Procedures (all 13 tabs)
-- Used by LabMetricsDashboard Collection Summary page.
--
-- Pattern (every SP):
--   No filters  -> read pre-aggregated dbo.IHD_CS_* snapshot table.
--   Any filter  -> aggregate live from source table (ClaimLevelData
--                  or LineLevelData, per source-routing notes below).
--
-- Source routing (InHealthDTR):
--   ClaimLevelData : Top5ReimbursementPct, MonthlyClaimVolume,
--                    WeeklyClaimVolume, AvgPayments, PanelVsPayment,
--                    RepVsPayment, CptVsPaymentPct, ProviderSummary,
--                    InsuranceVsAging, InsuranceVsPaymentPct, PanelAverages
--   LineLevelData  : Top5ReimbursementPay, StatusSummary
--
-- Date column : CheckDate (NOT PaymentPostedDate)
-- Panel column: Panelname
-- BilledUnbilled filter:
--   NOT (ClaimStatus='No Response' AND BilledUnbilled='Unbilled')
--
-- Filter parameters (all SPs, pipe-delimited lists):
--   @PayerNames, @PanelNames, @DosFrom/To, @FirstBillFrom/To,
--   @CheckDateFrom/To
-- =====================================================================

SET NOCOUNT ON;
GO


-- =====================================================================
-- 1. Top 5 Insurances | Reimbursement % (vs Billed Charge)
--    Snapshot : dbo.IHD_CS_Top5ReimbursementPct
--    Live     : dbo.ClaimLevelData
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_Top5ReimbursementPct
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount
        FROM   dbo.IHD_CS_Top5ReimbursementPct
        ORDER  BY PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS SumIns,
            ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0)  AS SumChg,
            COUNT(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))             AS Visits
        FROM dbo.ClaimLevelData
        WHERE NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, SumIns, SumChg, Visits,
               CAST(ROW_NUMBER() OVER (ORDER BY SumIns DESC) AS TINYINT) AS PayerRank
        FROM agg ORDER BY SumIns DESC
    )
    SELECT PayerRank, PayerName,
           SumIns AS SumInsurancePayment, SumChg AS SumChargeAmount, Visits AS UniqueVisitCount
    FROM ranked ORDER BY PayerRank;
END
GO


-- =====================================================================
-- 2. Top 5 Insurances | Reimbursement Payments
--    Snapshot : dbo.IHD_CS_Top5ReimbursementPay
--    Live     : dbo.LineLevelData
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_Top5ReimbursementPay
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount
        FROM   dbo.IHD_CS_Top5ReimbursementPay
        ORDER  BY PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS TotalPay,
            COUNT(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))             AS Visits
        FROM dbo.LineLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, TotalPay, Visits,
               CAST(ROW_NUMBER() OVER (ORDER BY TotalPay DESC) AS TINYINT) AS PayerRank
        FROM agg ORDER BY TotalPay DESC
    )
    SELECT PayerRank, PayerName, TotalPay AS TotalPayments, Visits AS UniqueVisitCount
    FROM ranked ORDER BY PayerRank;
END
GO


-- =====================================================================
-- 3. Monthly Claim Volume
--    Snapshot : dbo.IHD_CS_MonthlyClaimVolume
--    Live     : dbo.ClaimLevelData  (CheckDate)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_MonthlyClaimVolume
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName, PayerRank, BillYear, BillMonth,
                NoOfClaims, InsurancePayment,
                CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM    dbo.IHD_CS_MonthlyClaimVolume
        ORDER   BY PanelName, PayerRank, BillYear, BillMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))              AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
            YEAR (TRY_CAST(CheckDate AS DATE))                          AS BillYear,
            MONTH(TRY_CAST(CheckDate AS DATE))                          AS BillMonth,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(CheckDate)) <> ''
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            YEAR (TRY_CAST(CheckDate AS DATE)),
            MONTH(TRY_CAST(CheckDate AS DATE))
    ),
    Ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM Agg GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName, a.PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
        a.BillYear, CAST(a.BillMonth AS TINYINT) AS BillMonth,
        a.NoOfClaims, a.InsurancePayment,
        CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a
    JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.BillYear, a.BillMonth;
END
GO


-- =====================================================================
-- 4. Weekly Claim Volume  (Thu-Wed weeks, last 4 complete)
--    Snapshot : dbo.IHD_CS_WeeklyClaimVolume
--    Live     : dbo.ClaimLevelData  (CheckDate)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_WeeklyClaimVolume
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
                NoOfClaims, InsurancePayment,
                CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM    dbo.IHD_CS_WeeklyClaimVolume
        ORDER   BY PanelName, PayerRank, WeekKey;
        RETURN;
    END;

    -- ── Resolve 4 rolling Thu-Wed weeks anchored on max CheckDate ───────────
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MaxCheckDate DATE;

    SELECT @MaxCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND TRY_CAST(CheckDate AS DATE) <= @Today
      AND LTRIM(RTRIM(CheckDate)) <> '';

    IF @MaxCheckDate IS NULL
    BEGIN
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
               NoOfClaims, InsurancePayment, CAST(0 AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM dbo.IHD_CS_WeeklyClaimVolume WHERE 1 = 0;
        RETURN;
    END;

    -- Thu-Wed week; 1900-01-04 is Thursday
    DECLARE @WkMaxStart DATE =
        DATEADD(DAY, -(DATEDIFF(DAY, '19000104', @MaxCheckDate) % 7), @MaxCheckDate);
    DECLARE @WkMaxEnd   DATE = DATEADD(DAY, 6, @WkMaxStart);

    DECLARE @W4Start DATE = CASE WHEN @WkMaxEnd <= @Today THEN @WkMaxStart
                                 ELSE DATEADD(DAY, -7, @WkMaxStart) END;
    DECLARE @W4End   DATE = DATEADD(DAY,  6, @W4Start);
    DECLARE @W3Start DATE = DATEADD(DAY, -7, @W4Start); DECLARE @W3End DATE = DATEADD(DAY, 6, @W3Start);
    DECLARE @W2Start DATE = DATEADD(DAY, -7, @W3Start); DECLARE @W2End DATE = DATEADD(DAY, 6, @W2Start);
    DECLARE @W1Start DATE = DATEADD(DAY, -7, @W2Start); DECLARE @W1End DATE = DATEADD(DAY, 6, @W1Start);

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CASE
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(CheckDate)) <> ''
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
               ISNULL(SUM(InsPay), 0)                   AS InsurancePayment
        FROM src WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName, a.PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,
        CAST(a.WeekKey AS TINYINT) AS WeekKey,
        CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start WHEN 3 THEN @W3Start WHEN 4 THEN @W4Start END AS WeekStart,
        CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End   WHEN 3 THEN @W3End   WHEN 4 THEN @W4End   END AS WeekEnd,
        a.NoOfClaims, a.InsurancePayment,
        CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END
GO


-- =====================================================================
-- 5. Panel Averages
--    Snapshot : dbo.IHD_CS_PanelAverages
--    Live     : dbo.ClaimLevelData  (FullyPaidCount, AdjudicatedCount,
--               Days30Count/Days60Count columns; CheckDate rolling 180 days)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_PanelAverages
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName,
                NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
                FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
                AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
                Days30Count, Days30Amount, AvgDays30,
                Days60Count, Days60Amount, AvgDays60
        FROM    dbo.IHD_CS_PanelAverages
        ORDER   BY PanelName, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- When no CheckDate filter supplied, replicate the 180-day rolling window from the refresh SP.
    DECLARE @CheckFrom DATE = ISNULL(@CheckDateFrom, DATEADD(DAY, -180, CAST(GETDATE() AS DATE)));
    DECLARE @CheckTo   DATE = ISNULL(@CheckDateTo,   CAST(GETDATE() AS DATE));

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))  AS PayerName,
            LTRIM(RTRIM(ClaimID))                           AS VisitKey,
            TRY_CAST(ChargeAmount      AS DECIMAL(18,2))    AS Chg,
            TRY_CAST(InsurancePayment  AS DECIMAL(18,2))    AS InsPay,
            LTRIM(RTRIM(ISNULL(FullyPaidCount, '')))        AS FPC,
            TRY_CAST(FullyPaidAmount   AS DECIMAL(18,2))    AS FullyPaidAmt,
            LTRIM(RTRIM(ISNULL([AdjudicatedCount], '')))    AS AdjFlag,
            TRY_CAST([AdjudicatedAmount] AS DECIMAL(18,2))  AS AdjAmt,
            LTRIM(RTRIM(ISNULL(Days30Count, '')))           AS Bucket30Flag,
            TRY_CAST([Days30Amount] AS DECIMAL(18,2))       AS Bucket30Amt,
            LTRIM(RTRIM(ISNULL(Days60Count, '')))           AS Bucket60Flag,
            TRY_CAST([Days60Amount] AS DECIMAL(18,2))       AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
          AND Panelname IS NOT NULL AND LEN(LTRIM(RTRIM(Panelname))) > 0
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @CheckFrom AND @CheckTo
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
    ),
    agg AS (
        SELECT
            PanelName, PayerName,
            COUNT(VisitKey)                                                                    AS NoOfClaims,
            ISNULL(SUM(Chg),    0)                                                             AS TotalCharges,
            ISNULL(SUM(InsPay), 0)                                                             AS CarrierPayment,
            COUNT(CASE WHEN FPC IN ('Fully Paid', 'Fully Paid Count')
                       THEN VisitKey END)                                                      AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FPC IN ('Fully Paid', 'Fully Paid Count')
                            THEN FullyPaidAmt ELSE 0 END), 0)                                 AS FullyPaidAmount,
            COUNT(CASE WHEN AdjFlag IN ('Adjudicated', 'Adjudicated Count')
                       THEN VisitKey END)                                                      AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjFlag IN ('Adjudicated', 'Adjudicated Count')
                            THEN AdjAmt ELSE 0 END), 0)                                       AS AdjudicatedAmount,
            COUNT(CASE WHEN Bucket30Flag IN ('30 Bucket', '30 Days Count')
                       THEN VisitKey END)                                                      AS Days30Count,
            ISNULL(SUM(CASE WHEN Bucket30Flag IN ('30 Bucket', '30 Days Count')
                            THEN Bucket30Amt ELSE 0 END), 0)                                  AS Days30Amount,
            COUNT(CASE WHEN Bucket60Flag IN ('60 Bucket', '60 Days Count')
                       THEN VisitKey END)                                                      AS Days60Count,
            ISNULL(SUM(CASE WHEN Bucket60Flag IN ('60 Bucket', '60 Days Count')
                            THEN Bucket60Amt ELSE 0 END), 0)                                  AS Days60Amount
        FROM src GROUP BY PanelName, PayerName
    )
    SELECT
        PanelName, PayerName,
        NoOfClaims, TotalCharges, CarrierPayment,
        CAST(CASE WHEN NoOfClaims       > 0 THEN CarrierPayment    / NoOfClaims       ELSE 0 END AS DECIMAL(18,2)) AS AvgCarrierPayment,
        FullyPaidCount, FullyPaidAmount,
        CAST(CASE WHEN FullyPaidCount   > 0 THEN FullyPaidAmount   / FullyPaidCount   ELSE 0 END AS DECIMAL(18,2)) AS AvgFullyPaid,
        AdjudicatedCount, AdjudicatedAmount,
        CAST(CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END AS DECIMAL(18,2)) AS AvgAdjudicated,
        Days30Count, Days30Amount,
        CAST(CASE WHEN Days30Count      > 0 THEN Days30Amount      / Days30Count      ELSE 0 END AS DECIMAL(18,2)) AS AvgDays30,
        Days60Count, Days60Amount,
        CAST(CASE WHEN Days60Count      > 0 THEN Days60Amount      / Days60Count      ELSE 0 END AS DECIMAL(18,2)) AS AvgDays60
    FROM agg
    ORDER BY PanelName, PayerName;
END
GO


-- =====================================================================
-- 6. Avg Payments  (last 6 months by CheckDate, top 3 payers per panel)
--    Snapshot : dbo.IHD_CS_AvgPayments
--    Live     : dbo.ClaimLevelData  (CheckDate)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_AvgPayments
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName, PayerRank,
                NoOfClaims, TotalCharges, AvgCharges,
                CarrierPayment, AvgCarrierPayment,
                FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
                AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
                Days30Count, Days30Amount, AvgDays30,
                Days60Count, Days60Amount, AvgDays60
        FROM    dbo.IHD_CS_AvgPayments
        ORDER   BY PanelName, PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @Cutoff   DATE = ISNULL(@CheckDateFrom, DATEADD(MONTH, -6, CAST(GETDATE() AS DATE)));
    DECLARE @CutoffTo DATE = ISNULL(@CheckDateTo,   CAST(GETDATE() AS DATE));

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))    AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                      AS Status,
            ISNULL(TRY_CAST(DaystoDOS AS INT), 9999)       AS Days
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @Cutoff AND @CutoffTo
          AND Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
    ),
    agg AS (
        SELECT PanelName, PayerName,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))                                     AS NoOfClaims,
               ISNULL(SUM(Chg),    0)                                                               AS TotalCharges,
               ISNULL(SUM(InsPay), 0)                                                               AS CarrierPayment,
               COUNT(DISTINCT CASE WHEN Status = 'Fully Paid' THEN ClaimID END)                    AS FullyPaidCount,
               ISNULL(SUM(CASE WHEN Status = 'Fully Paid' THEN InsPay ELSE 0 END), 0)              AS FullyPaidAmount,
               COUNT(DISTINCT CASE WHEN Status IN ('Fully Paid','Partially Paid','Complete W/O',
                   'Fully Adjusted','Fully Denied','Denied','Partially Denied',
                   'Partially Adjusted','Patient Responsibility') THEN ClaimID END)                 AS AdjudicatedCount,
               ISNULL(SUM(CASE WHEN Status IN ('Fully Paid','Partially Paid','Complete W/O',
                   'Fully Adjusted','Fully Denied','Denied','Partially Denied',
                   'Partially Adjusted','Patient Responsibility') THEN InsPay ELSE 0 END), 0)       AS AdjudicatedAmount,
               COUNT(DISTINCT CASE WHEN Days <= 30 THEN ClaimID END)                               AS Days30Count,
               ISNULL(SUM(CASE WHEN Days <= 30 THEN InsPay ELSE 0 END), 0)                         AS Days30Amount,
               COUNT(DISTINCT CASE WHEN Days <= 60 THEN ClaimID END)                               AS Days60Count,
               ISNULL(SUM(CASE WHEN Days <= 60 THEN InsPay ELSE 0 END), 0)                         AS Days60Amount
        FROM base GROUP BY PanelName, PayerName
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               CAST(DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY NoOfClaims DESC) AS TINYINT) AS PayerRank
        FROM agg
    )
    SELECT
        a.PanelName, a.PayerName, r.PayerRank,
        a.NoOfClaims, a.TotalCharges,
        CAST(CASE WHEN a.NoOfClaims       > 0 THEN a.TotalCharges      / a.NoOfClaims       ELSE 0 END AS DECIMAL(18,2)) AS AvgCharges,
        a.CarrierPayment,
        CAST(CASE WHEN a.NoOfClaims       > 0 THEN a.CarrierPayment    / a.NoOfClaims       ELSE 0 END AS DECIMAL(18,2)) AS AvgCarrierPayment,
        a.FullyPaidCount, a.FullyPaidAmount,
        CAST(CASE WHEN a.FullyPaidCount   > 0 THEN a.FullyPaidAmount   / a.FullyPaidCount   ELSE 0 END AS DECIMAL(18,2)) AS AvgFullyPaid,
        a.AdjudicatedCount, a.AdjudicatedAmount,
        CAST(CASE WHEN a.AdjudicatedCount > 0 THEN a.AdjudicatedAmount / a.AdjudicatedCount ELSE 0 END AS DECIMAL(18,2)) AS AvgAdjudicated,
        a.Days30Count, a.Days30Amount,
        CAST(CASE WHEN a.Days30Count      > 0 THEN a.Days30Amount      / a.Days30Count      ELSE 0 END AS DECIMAL(18,2)) AS AvgDays30,
        a.Days60Count, a.Days60Amount,
        CAST(CASE WHEN a.Days60Count      > 0 THEN a.Days60Amount      / a.Days60Count      ELSE 0 END AS DECIMAL(18,2)) AS AvgDays60
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 3
    ORDER BY a.PanelName, r.PayerRank;
END
GO


-- =====================================================================
-- 7. Insurance vs Aging
--    Snapshot : dbo.IHD_CS_InsuranceVsAging
--    Live     : dbo.ClaimLevelData  (AgingBucket, InsuranceBalance — InHealthDTR has these on ClaimLevel)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_InsuranceVsAging
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance
        FROM   dbo.IHD_CS_InsuranceVsAging
        ORDER  BY PayerName, AgingBucket;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
        LTRIM(RTRIM(ISNULL(AgingBucket, '(blank)')))                 AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                     AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(PayerName_Raw)), LTRIM(RTRIM(ISNULL(AgingBucket, '(blank)')))
    ORDER BY PayerName, AgingBucket;
END
GO


-- =====================================================================
-- 8. Panel vs Payment
--    Snapshot : dbo.IHD_CS_PanelVsPayment
--    Live     : dbo.ClaimLevelData  (CheckDate)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_PanelVsPayment
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment
        FROM   dbo.IHD_CS_PanelVsPayment
        ORDER  BY PanelName, BilledYear, BilledMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(Panelname))                                        AS PanelName,
        YEAR (TRY_CAST(CheckDate AS DATE))                             AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)            AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))              AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)    AS InsurancePayment
    FROM dbo.ClaimLevelData
    WHERE Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''
      AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(Panelname)),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE))
    ORDER BY PanelName, BilledYear, BilledMonth;
END
GO


-- =====================================================================
-- 9. Rep vs Payment
--    Snapshot : dbo.IHD_CS_RepVsPayment
--    Live     : dbo.ClaimLevelData  (CheckDate, SalesRepname)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_RepVsPayment
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
        FROM   dbo.IHD_CS_RepVsPayment
        ORDER  BY SalesRepName, CheckYear, CheckMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(SalesRepname))                                   AS SalesRepName,
        YEAR (TRY_CAST(CheckDate AS DATE))                           AS CheckYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)          AS CheckMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND SalesRepname IS NOT NULL AND LTRIM(RTRIM(SalesRepname)) <> ''
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(SalesRepname)),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE))
    ORDER BY SalesRepName, CheckYear, CheckMonth;
END
GO


-- =====================================================================
-- 10. Insurance vs Payment %
--     Snapshot : dbo.IHD_CS_InsuranceVsPaymentPct
--     Live     : dbo.ClaimLevelData  (PaymentPercent, InsurancePayment — InHealthDTR has these on ClaimLevel)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_InsuranceVsPaymentPct
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct
        FROM   dbo.IHD_CS_InsuranceVsPaymentPct
        ORDER  BY InsurancePayment DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(PayerName_Raw))                  AS PayerName,
            LTRIM(RTRIM(Panelname))                      AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))  AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))   AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
          AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PayerName,
        COUNT(PanelName)                        AS PanelGroupCount,
        ISNULL(SUM(InsPay), 0)                  AS InsurancePayment,
        ROUND(ISNULL(AVG(PayPct), 0) * 100, 0)  AS PaymentPct
    FROM base
    GROUP BY PayerName
    ORDER BY SUM(InsPay) DESC;
END
GO


-- =====================================================================
-- 11. CPT vs Payment %
--     Snapshot : dbo.IHD_CS_CptVsPaymentPct
--     Live     : dbo.ClaimLevelData  (CPTCodeXUnitsXModifier parsed)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_CptVsPaymentPct
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct
        FROM   dbo.IHD_CS_CptVsPaymentPct
        ORDER  BY SumUnits DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH parsed AS (
        SELECT
            LTRIM(RTRIM(
                CASE
                    WHEN CHARINDEX(' x ', CPTCodeXUnitsXModifier) > 0
                    THEN LEFT(CPTCodeXUnitsXModifier, CHARINDEX(' x ', CPTCodeXUnitsXModifier) - 1)
                    ELSE CPTCodeXUnitsXModifier
                END
            )) AS CPTCode,
            CASE
                WHEN CHARINDEX(' x ', CPTCodeXUnitsXModifier) > 0
                     AND CHARINDEX(' x ', CPTCodeXUnitsXModifier, CHARINDEX(' x ', CPTCodeXUnitsXModifier) + 3) > 0
                THEN SUBSTRING(
                    CPTCodeXUnitsXModifier,
                    CHARINDEX(' x ', CPTCodeXUnitsXModifier) + 3,
                    CHARINDEX(' x ', CPTCodeXUnitsXModifier, CHARINDEX(' x ', CPTCodeXUnitsXModifier) + 3)
                        - (CHARINDEX(' x ', CPTCodeXUnitsXModifier) + 3)
                )
                WHEN CHARINDEX(' x ', CPTCodeXUnitsXModifier) > 0
                THEN SUBSTRING(
                    CPTCodeXUnitsXModifier,
                    CHARINDEX(' x ', CPTCodeXUnitsXModifier) + 3,
                    LEN(CPTCodeXUnitsXModifier)
                )
                ELSE '1'
            END AS Units,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) AS ChgAmt,
            LTRIM(RTRIM(ClaimStatus))                   AS ClaimStatus
        FROM dbo.ClaimLevelData
        WHERE CPTCodeXUnitsXModifier IS NOT NULL
          AND LTRIM(RTRIM(CPTCodeXUnitsXModifier)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    agg AS (
        SELECT
            CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)                     AS SumUnits,
            ISNULL(SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Partially Paid')
                            THEN InsPay ELSE 0 END), 0)                           AS PaidIns,
            ISNULL(SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Partially Paid')
                            THEN ChgAmt ELSE 0 END), 0)                           AS PaidChg
        FROM parsed
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
        GROUP BY CPTCode
    )
    SELECT
        CPTCode, SumUnits,
        PaidIns AS PaidInsurancePayment,
        PaidChg AS PaidChargeAmount,
        CAST(CASE WHEN PaidChg > 0 THEN PaidIns * 100.0 / PaidChg ELSE 0 END AS DECIMAL(9,4)) AS PaymentPct
    FROM agg
    ORDER BY SumUnits DESC;
END
GO


-- =====================================================================
-- 12. Status Summary
--     Snapshot : dbo.IHD_CS_StatusSummary
--     Live     : dbo.LineLevelData  (CPTCode/Units/Modifier as CptCode — InHealthDTR has separate columns)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_StatusSummary
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ClaimStatus, PanelName, CptCode, PayerName,
               NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
        FROM   dbo.IHD_CS_StatusSummary
        ORDER  BY ClaimStatus, PanelName, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),              '(blank)') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Panelname)),                '(blank)') AS PanelName,
        ISNULL(LTRIM(RTRIM(
            CONCAT(ISNULL(CPTCode,''), ' x ', ISNULL(CAST(Units AS NVARCHAR(50)),''), ' x ', ISNULL(Modifier,''))
        )), '(blank)')                                               AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),            '(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0) AS PatientBalance
    FROM dbo.LineLevelData
    WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(Panelname)),
        LTRIM(RTRIM(CONCAT(ISNULL(CPTCode,''), ' x ', ISNULL(CAST(Units AS NVARCHAR(50)),''), ' x ', ISNULL(Modifier,'')))),
        LTRIM(RTRIM(PayerName_Raw))
    ORDER BY ClaimStatus, PanelName, PayerName;
END
GO


-- =====================================================================
-- 13. Provider Summary
--     Snapshot : dbo.IHD_CS_ProviderSummary
--     Live     : dbo.ClaimLevelData  (ReferringProvider)
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_ProviderSummary
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ProviderRank, ReferringProvider,
               NoOfClaims, InsurancePayments, InsuranceBalance, PatientBalance
        FROM   dbo.IHD_CS_ProviderSummary
        ORDER  BY ProviderRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ReferringProvider))                              AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL AND LTRIM(RTRIM(ReferringProvider)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(ReferringProvider))
    )
    SELECT
        CAST(ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS INT) AS ProviderRank,
        ReferringProvider, NoOfClaims, InsurancePayment AS InsurancePayments, InsuranceBalance, PatientBalance
    FROM agg
    ORDER BY ProviderRank;
END
GO

PRINT '13_InHealthDTR_CollectionSummary_ReadSPs.sql completed -- 13 Read SPs.';
GO

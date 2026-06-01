-- =====================================================================
-- 14_Cove_CollectionSummary_ReadSPs.sql
-- Cove Collection Summary READ Stored Procedures
--
-- Pattern (mirrors NorthWest 15_NorthWest_CollectionSummary_ReadSPs.sql):
--   No filters  -> read pre-aggregated dbo.Cove_CS_* snapshot tables.
--   Any filter  -> aggregate live from dbo.ClaimLevelData / dbo.LineLevelData.
--
-- Filter parameters (all optional, '|'-delimited lists):
--   @PayerNames, @PanelNames, @DosFrom/@DosTo,
--   @FirstBillFrom/@FirstBillTo, @CheckDateFrom/@CheckDateTo
-- =====================================================================
SET NOCOUNT ON;
GO

-- =====================================================================
-- Shared filter-list split helper macro
-- (inlined in each SP to avoid cross-SP dependencies)
-- =====================================================================

-- =====================================================================
-- 1. Monthly Claim Volume
-- Source: dbo.LineLevelData / dbo.Cove_CS_MonthlyClaimVolume
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_MonthlyClaimVolume
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName, PayerRank,
                BillYear, BillMonth, NoOfClaims, InsurancePayment,
                CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM    dbo.Cove_CS_MonthlyClaimVolume
        ORDER BY PanelName, PayerRank, BillYear, BillMonth;
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
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            YEAR (TRY_CAST(CheckDate AS DATE))             AS BillYear,
            MONTH(TRY_CAST(CheckDate AS DATE))             AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.LineLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
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
    SELECT  a.PanelName, a.PayerName,
            CAST(r.PayerRank AS TINYINT) AS PayerRank,
            a.BillYear, CAST(a.BillMonth AS TINYINT) AS BillMonth,
            a.NoOfClaims, a.InsurancePayment,
            CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.BillYear, a.BillMonth;
END
GO

-- =====================================================================
-- 2. Weekly Claim Volume
-- Source: dbo.LineLevelData / dbo.Cove_CS_WeeklyClaimVolume
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_WeeklyClaimVolume
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName, PayerRank,
                WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment,
                CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM    dbo.Cove_CS_WeeklyClaimVolume
        ORDER BY PanelName, PayerRank, WeekKey;
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

    DECLARE @LatestCheckDate DATE;
    SELECT @LatestCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
    FROM dbo.LineLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo);

    IF @LatestCheckDate IS NULL
    BEGIN
        SELECT CAST(NULL AS NVARCHAR(500)) AS PanelName, CAST(NULL AS NVARCHAR(500)) AS PayerName,
               CAST(NULL AS TINYINT) AS PayerRank, CAST(NULL AS TINYINT) AS WeekKey,
               CAST(NULL AS DATE) AS WeekStart, CAST(NULL AS DATE) AS WeekEnd,
               CAST(NULL AS INT) AS NoOfClaims, CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment,
               CAST(NULL AS DECIMAL(18,2)) AS AveragePaidAmount
        WHERE 1 = 0;
        RETURN;
    END;

    DECLARE @DaysSinceSun INT = ((DATEDIFF(DAY, '1900-01-07', @LatestCheckDate) % 7) + 7) % 7;
    DECLARE @W4End   DATE = DATEADD(DAY,  6 - @DaysSinceSun, @LatestCheckDate);
    DECLARE @W4Start DATE = DATEADD(DAY, -6,  @W4End);
    DECLARE @W3End   DATE = DATEADD(DAY, -7,  @W4End), @W3Start DATE = DATEADD(DAY, -13, @W4End);
    DECLARE @W2End   DATE = DATEADD(DAY, -14, @W4End), @W2Start DATE = DATEADD(DAY, -20, @W4End);
    DECLARE @W1End   DATE = DATEADD(DAY, -21, @W4End), @W1Start DATE = DATEADD(DAY, -27, @W4End);

    ;WITH Src AS (
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
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsurancePayment
        FROM dbo.LineLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    Agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
               ISNULL(SUM(InsurancePayment), 0) AS InsurancePayment
        FROM Src WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    Ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM Agg GROUP BY PanelName, PayerName
    )
    SELECT  a.PanelName, a.PayerName,
            CAST(r.PayerRank AS TINYINT) AS PayerRank,
            CAST(a.WeekKey   AS TINYINT) AS WeekKey,
            CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start WHEN 3 THEN @W3Start WHEN 4 THEN @W4Start END AS WeekStart,
            CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End   WHEN 3 THEN @W3End   WHEN 4 THEN @W4End   END AS WeekEnd,
            a.NoOfClaims, a.InsurancePayment,
            CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END
GO

-- =====================================================================
-- 3. Top 5 Insurances | Reimbursement % (vs Billed Charge)
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_Top5ReimbursementPct
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_Top5ReimbursementPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount
        FROM   dbo.Cove_CS_Top5ReimbursementPct
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

    -- ReimbursementPct = SUM(InsurancePayment) / UniqueVisitCount * 100
    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID))) AS VisitKey,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) AS Chg
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    agg AS (
        SELECT PayerName,
               ISNULL(SUM(InsPay), 0) AS SumInsurancePayment,
               ISNULL(SUM(Chg),    0) AS SumChargeAmount,
               COUNT(DISTINCT NULLIF(VisitKey, '')) AS UniqueVisitCount
        FROM base GROUP BY PayerName
    )
    SELECT TOP 5
        CAST(ROW_NUMBER() OVER (ORDER BY SumInsurancePayment DESC) AS TINYINT) AS PayerRank,
        PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount
    FROM agg
    ORDER BY PayerRank;
END
GO

-- =====================================================================
-- 4. Top 5 Insurances | Total Payments
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_Top5ReimbursementPay
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_Top5ReimbursementPay
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerRank, PayerName, TotalPayments, UniqueVisitCount
        FROM   dbo.Cove_CS_Top5ReimbursementPay
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

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID))) AS VisitKey,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    agg AS (
        SELECT PayerName,
               ISNULL(SUM(InsPay), 0) AS TotalPayments,
               COUNT(DISTINCT NULLIF(VisitKey, '')) AS UniqueVisitCount
        FROM base GROUP BY PayerName
    )
    SELECT TOP 5
        CAST(ROW_NUMBER() OVER (ORDER BY TotalPayments DESC) AS TINYINT) AS PayerRank,
        PayerName, TotalPayments, UniqueVisitCount
    FROM agg
    ORDER BY PayerRank;
END
GO

-- =====================================================================
-- 5. Panel Averages
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_PanelAverages
-- No-filter:  reads snapshot (ClaimCount aliased to NoOfClaims).
-- With filter: re-aggregates live using Cove's direct bucket columns.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelAverages
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName,
                ClaimCount        AS NoOfClaims,
                TotalCharges,     CarrierPayment,
                FullyPaidCount,   FullyPaidAmount,
                AdjudicatedCount, AdjudicatedAmount,
                Days30Count,      Days30Amount,
                Days60Count,      Days60Amount
        FROM    dbo.Cove_CS_PanelAverages
        ORDER BY PanelName, PayerName;
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

    -- Cove stores bucket flags as direct columns: FullyPaidCount, AdjucticatedCount,
    -- Bucket30Count, Bucket60Count (note the intentional typo in the source column name).
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID))) AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))      AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))      AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                        AS ClaimStatus,
            LTRIM(RTRIM(FullyPaidCount))                     AS FullyPaidFlag,
            TRY_CAST(FullyPaidAmount    AS DECIMAL(18,2))    AS FullyPaidAmt,
            LTRIM(RTRIM(AdjucticatedCount))                  AS AdjFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))    AS AdjAmt,
            LTRIM(RTRIM(Bucket30Count))                      AS Bucket30Flag,
            TRY_CAST(Bucket30Amount     AS DECIMAL(18,2))    AS Bucket30Amt,
            LTRIM(RTRIM(Bucket60Count))                      AS Bucket60Flag,
            TRY_CAST(Bucket60Amount     AS DECIMAL(18,2))    AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PanelName, PayerName,
        COUNT(DISTINCT CASE WHEN ClaimStatus <> 'No Response' THEN VisitKey END)                  AS NoOfClaims,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN Chg    ELSE 0 END), 0)             AS TotalCharges,
        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN InsPay ELSE 0 END), 0)             AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN FullyPaidFlag = 'Fully Paid'   THEN VisitKey END)                AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FullyPaidFlag = 'Fully Paid'   THEN FullyPaidAmt ELSE 0 END), 0)     AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN AdjFlag      = 'Adjucticated'  THEN VisitKey END)                AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjFlag      = 'Adjucticated'  THEN AdjAmt       ELSE 0 END), 0)     AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Bucket30Flag  = '30+'           THEN VisitKey END)               AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30Flag  = '30+'           THEN Bucket30Amt  ELSE 0 END), 0)    AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Bucket60Flag  = '60+'           THEN VisitKey END)               AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60Flag  = '60+'           THEN Bucket60Amt  ELSE 0 END), 0)    AS Days60Amount
    FROM src
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, PayerName;
END
GO

-- =====================================================================
-- 6. Average Payments (last 6 months)
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_AvgPayments
-- Aliases: ClaimCount->NoOfClaims, InsurancePayment->CarrierPayment,
--          Over30/60->Days30/60 (to match C# reader).
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_AvgPayments
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName,
                ClaimCount       AS NoOfClaims,
                TotalCharges,
                InsurancePayment AS CarrierPayment,
                FullyPaidCount,   FullyPaidAmount,
                AdjudicatedCount, AdjudicatedAmount,
                Over30Count      AS Days30Count, Over30Amount AS Days30Amount,
                Over60Count      AS Days60Count, Over60Amount AS Days60Amount
        FROM    dbo.Cove_CS_AvgPayments
        ORDER BY PanelName, PayerName;
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

    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                   AS Status,
            ISNULL(TRY_CAST(DaystoDOS AS INT), 9999)    AS Days
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND Panelname IS NOT NULL AND LTRIM(RTRIM(Panelname)) <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PanelName, PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                       AS NoOfClaims,
        ISNULL(SUM(Chg),    0)                                                  AS TotalCharges,
        ISNULL(SUM(InsPay), 0)                                                  AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN Status = 'Fully Paid' THEN ClaimID END)        AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN Status = 'Fully Paid' THEN InsPay ELSE 0 END), 0)  AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN Status IN (
            'Fully Paid','Partially Paid','Complete W/O','Fully Adjusted',
            'Fully Denied','Denied','Partially Denied','Partially Adjusted',
            'Patient Responsibility') THEN ClaimID END)                         AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN Status IN (
            'Fully Paid','Partially Paid','Complete W/O','Fully Adjusted',
            'Fully Denied','Denied','Partially Denied','Partially Adjusted',
            'Patient Responsibility') THEN InsPay ELSE 0 END), 0)               AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Days <= 30 THEN ClaimID END)                   AS Days30Count,
        ISNULL(SUM(CASE WHEN Days <= 30 THEN InsPay ELSE 0 END), 0)             AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Days <= 60 THEN ClaimID END)                   AS Days60Count,
        ISNULL(SUM(CASE WHEN Days <= 60 THEN InsPay ELSE 0 END), 0)             AS Days60Amount
    FROM base
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, PayerName;
END
GO

-- =====================================================================
-- 7. Insurance vs Aging
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_InsuranceVsAging
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_InsuranceVsAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance
        FROM   dbo.Cove_CS_InsuranceVsAging
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
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                       AS PayerName,
        CASE
            WHEN ISNULL(TRY_CAST(DaystoDOS AS INT), -1) < 0  THEN '(blank)'
            WHEN TRY_CAST(DaystoDOS AS INT) < 30              THEN 'Current'
            WHEN TRY_CAST(DaystoDOS AS INT) < 60              THEN '30 Days'
            WHEN TRY_CAST(DaystoDOS AS INT) < 90              THEN '60 Days'
            WHEN TRY_CAST(DaystoDOS AS INT) < 120             THEN '90 Days'
            ELSE '120+ Days'
        END                                                                   AS AgingBucket,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))             AS Cnt,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)          AS InsuranceBalance
    FROM dbo.ClaimLevelData
    WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND LTRIM(RTRIM(ClaimStatus)) <> 'No Response'
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        CASE
            WHEN ISNULL(TRY_CAST(DaystoDOS AS INT), -1) < 0  THEN '(blank)'
            WHEN TRY_CAST(DaystoDOS AS INT) < 30              THEN 'Current'
            WHEN TRY_CAST(DaystoDOS AS INT) < 60              THEN '30 Days'
            WHEN TRY_CAST(DaystoDOS AS INT) < 90              THEN '60 Days'
            WHEN TRY_CAST(DaystoDOS AS INT) < 120             THEN '90 Days'
            ELSE '120+ Days'
        END
    ORDER BY PayerName, AgingBucket;
END
GO

-- =====================================================================
-- 8. Panel vs Payment
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_PanelVsPayment
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName,
                BilledYear,
                BilledMonth,
                SUM(NoOfClaims)       AS NoOfClaims,
                SUM(InsurancePayment) AS InsurancePayments
        FROM    dbo.Cove_CS_PanelVsPayment
        GROUP BY PanelName, BilledYear, BilledMonth
        ORDER BY PanelName, BilledYear, BilledMonth;
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
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))                          AS PanelName,
        YEAR (TRY_CAST(CheckDate AS DATE))                                   AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)                  AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)         AS InsurancePayments
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL AND CheckDate <> ''
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE))
    ORDER BY PanelName, BilledYear, BilledMonth;
END
GO

-- =====================================================================
-- 9. Rep vs Payment
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_RepVsPayment
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_RepVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
        FROM   dbo.Cove_CS_RepVsPayment
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
        LTRIM(RTRIM(SalesRepname))                                          AS SalesRepName,
        CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT)                     AS CheckYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT)                     AS CheckMonth,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)        AS InsurancePayment
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(SalesRepname)),
        CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT),
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT)
    ORDER BY SalesRepName, CheckYear, CheckMonth;
END
GO

-- =====================================================================
-- 10. Insurance vs Payment %
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_InsuranceVsPaymentPct
-- No-filter returns PanelGroupCount AS NoOfClaims (snapshot column).
-- Filter re-aggregates using AVG(PaymentPercent) * 100 (matches refresh SP).
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_InsuranceVsPaymentPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PayerName,
                PanelGroupCount AS NoOfClaims,
                InsurancePayment,
                PaymentPct
        FROM    dbo.Cove_CS_InsuranceVsPaymentPct
        ORDER BY InsurancePayment DESC;
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
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))     AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PayerName,
        COUNT(PanelName)                              AS NoOfClaims,
        ISNULL(SUM(InsPay), 0)                        AS InsurancePayment,
        ROUND(ISNULL(AVG(PayPct), 0) * 100, 0)        AS PaymentPct
    FROM base
    GROUP BY PayerName
    ORDER BY InsurancePayment DESC;
END
GO

-- =====================================================================
-- 11. CPT vs Payment %
-- Source: dbo.LineLevelData / dbo.Cove_CS_CptVsPaymentPct
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_CptVsPaymentPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct
        FROM   dbo.Cove_CS_CptVsPaymentPct
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

    SELECT
        LTRIM(RTRIM(CPTCode))                                                    AS CPTCode,
        ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)                        AS SumUnits,
        ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                        THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidInsurancePayment,
        ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                        THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChargeAmount
    FROM dbo.LineLevelData
    WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(CPTCode))
    ORDER BY SumUnits DESC;
END
GO

-- =====================================================================
-- 12. Status Summary
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_StatusSummary
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_StatusSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ClaimStatus, PanelName, CptCode, PayerName,
               NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
        FROM   dbo.Cove_CS_StatusSummary;
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
        ISNULL(LTRIM(RTRIM(ClaimStatus)),            '(blank)') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Panelname)),              '(blank)') AS PanelName,
        ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), '(blank)') AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),          '(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)         AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)         AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)         AS PatientBalance
    FROM dbo.ClaimLevelData
    WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(Panelname)),
        LTRIM(RTRIM(CPTCodeXUnitsXModifier)),
        LTRIM(RTRIM(PayerName_Raw));
END
GO

-- =====================================================================
-- 13. Provider Summary
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_ProviderSummary
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_ProviderSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ProviderRank, ReferringProvider, NoOfClaims,
               InsurancePayment AS InsurancePayments,
               InsuranceBalance, PatientBalance
        FROM   dbo.Cove_CS_ProviderSummary
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
            LTRIM(RTRIM(ReferringProvider))                             AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))           AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayments,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0) AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL AND LTRIM(RTRIM(ReferringProvider)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
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
        ReferringProvider, NoOfClaims,
        InsurancePayments, InsuranceBalance, PatientBalance
    FROM agg
    ORDER BY ProviderRank;
END
GO

-- =====================================================================
-- 14. Insurance vs Payment (Payer x Year/Month)
-- Source: dbo.ClaimLevelData / dbo.Cove_CS_InsuranceVsPayment
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_InsuranceVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct
        FROM   dbo.Cove_CS_InsuranceVsPayment
        ORDER  BY BillYear, BillMonth, InsurancePayment DESC;
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
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))           AS PayerName,
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT)           AS BillYear,
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)       AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))         AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL AND CheckDate <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT),
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)
    ),
    grand AS (
        SELECT BillYear, BillMonth,
               NULLIF(SUM(InsurancePayment), 0) AS Total
        FROM agg GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName, a.BillYear, a.BillMonth, a.NoOfPaidClaims,
           a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    INNER JOIN grand g ON a.BillYear = g.BillYear AND a.BillMonth = g.BillMonth
    ORDER BY a.BillYear, a.BillMonth, a.InsurancePayment DESC;
END
GO

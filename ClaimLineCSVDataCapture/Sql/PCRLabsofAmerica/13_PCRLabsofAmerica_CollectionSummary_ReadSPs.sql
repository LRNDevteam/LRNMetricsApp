-- =====================================================================
-- PCRLabsofAmerica - Collection Summary READ Stored Procedures
-- Used by LabMetricsDashboard Collection Summary page (Monthly + Weekly
-- Claim Volume tabs) and the related Excel export.
--
-- Pattern mirrors dbo.usp_GetNW_CS_MonthlyClaimVolume / WeeklyClaimVolume:
--   1) No filters  -> read pre-aggregated dbo.PCR_CS_* snapshot tables.
--   2) Any filters -> aggregate live from dbo.LineLevelData.
--
-- List parameters use '|' delimiter.
-- =====================================================================

SET NOCOUNT ON;
GO

-- =====================================================================
-- Monthly Claim Volume - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_MonthlyClaimVolume
-- Filter: InsurancePayment > 0, valid PostingDate
-- Rows: Panelname, PayerName_Raw with PayerRank
-- Columns: Year/Month from PostingDate
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_MonthlyClaimVolume
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
                PayerName,
                PayerRank,
                BillYear,
                BillMonth,
                NoOfClaims,
                InsurancePayment,
                CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM    dbo.PCR_CS_MonthlyClaimVolume
        ORDER BY PanelName, PayerRank, BillYear, BillMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            YEAR (TRY_CAST(PostingDate AS DATE))             AS BillYear,
            MONTH(TRY_CAST(PostingDate AS DATE))             AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.LineLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(PostingDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(PostingDate AS DATE)) > 1900
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(PostingDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(PostingDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            YEAR (TRY_CAST(PostingDate AS DATE)),
            MONTH(TRY_CAST(PostingDate AS DATE))
    ),
    Ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM Agg
        GROUP BY PanelName, PayerName
    )
    SELECT  a.PanelName,
            a.PayerName,
            CAST(r.PayerRank AS INT) AS PayerRank,
            a.BillYear,
            CAST(a.BillMonth AS TINYINT) AS BillMonth,
            a.NoOfClaims,
            a.InsurancePayment,
            CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a
    JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.BillYear, a.BillMonth;
END
GO

-- =====================================================================
-- Weekly Claim Volume - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_WeeklyClaimVolume
-- Filter: InsurancePayment > 0, valid PostingDate
-- No-filter path reads aggregate values.
-- Filter path calculates last 4 weeks from latest PostingDate in filtered data.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_WeeklyClaimVolume
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
                PayerName,
                PayerRank,
                WeekKey,
                WeekStart,
                WeekEnd,
                NoOfClaims,
                InsurancePayment,
                CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM    dbo.PCR_CS_WeeklyClaimVolume
        ORDER BY PanelName, PayerRank, WeekKey;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @LatestCheckDate DATE;

    SELECT @LatestCheckDate = MAX(TRY_CAST(PostingDate AS DATE))
    FROM dbo.LineLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(PostingDate AS DATE) IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(PostingDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(PostingDate       AS DATE) <= @CheckDateTo);

    IF @LatestCheckDate IS NULL
    BEGIN
        SELECT  CAST(NULL AS NVARCHAR(500)) AS PanelName,
                CAST(NULL AS NVARCHAR(500)) AS PayerName,
                CAST(NULL AS INT) AS PayerRank,
                CAST(NULL AS TINYINT)       AS WeekKey,
                CAST(NULL AS DATE)          AS WeekStart,
                CAST(NULL AS DATE)          AS WeekEnd,
                CAST(NULL AS INT)           AS NoOfClaims,
                CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment,
                CAST(NULL AS DECIMAL(18,2)) AS AveragePaidAmount
        WHERE 1 = 0;
        RETURN;
    END;

    -- Sunday-ending weeks, with Week 4 ending on the latest data point's week end.
    DECLARE @DaysSinceSun INT = ((DATEDIFF(DAY, '1900-01-07', @LatestCheckDate) % 7) + 7) % 7;
    DECLARE @W4End DATE = DATEADD(DAY, 6 - @DaysSinceSun, @LatestCheckDate);
    DECLARE @W4Start DATE = DATEADD(DAY, -6, @W4End);
    DECLARE @W3End DATE = DATEADD(DAY, -7, @W4End),  @W3Start DATE = DATEADD(DAY, -13, @W4End);
    DECLARE @W2End DATE = DATEADD(DAY,-14, @W4End),  @W2Start DATE = DATEADD(DAY, -20, @W4End);
    DECLARE @W1End DATE = DATEADD(DAY,-21, @W4End),  @W1Start DATE = DATEADD(DAY, -27, @W4End);

    ;WITH Src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CASE
                WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
                WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
                WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
                WHEN TRY_CAST(PostingDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsurancePayment
        FROM dbo.LineLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(PostingDate AS DATE) BETWEEN @W1Start AND @W4End
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(PostingDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(PostingDate       AS DATE) <= @CheckDateTo)
    ),
    Agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
               ISNULL(SUM(InsurancePayment), 0) AS InsurancePayment
        FROM Src
        WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    Ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM Agg
        GROUP BY PanelName, PayerName
    )
    SELECT  a.PanelName,
            a.PayerName,
            CAST(r.PayerRank AS INT) AS PayerRank,
            CAST(a.WeekKey AS TINYINT) AS WeekKey,
            CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start WHEN 3 THEN @W3Start WHEN 4 THEN @W4Start END AS WeekStart,
            CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End   WHEN 3 THEN @W3End   WHEN 4 THEN @W4End   END AS WeekEnd,
            a.NoOfClaims,
            a.InsurancePayment,
            CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a
    JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END
GO

-- =====================================================================
-- Top 5 Reimbursement Percentage - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_Top5ReimbursementPct
-- Filter: InsurancePayment > 0, exclude No Response/Unbilled
-- Calculation: PaymentPct column or (SumInsurancePayment / SumChargeAmount)
-- =====================================================================


CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_Top5ReimbursementPct
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
        SELECT  PayerRank,
                PayerName,
                SumInsurancePayment,
                SumChargeAmount,
                UniqueVisitCount,
                PaymentPct
        FROM    dbo.PCR_CS_Top5ReimbursementPct
        ORDER BY PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))               AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS SumIns,
            ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0) AS SumChg,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))    AS Visits
        FROM dbo.ClaimLevelData
        WHERE NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate     AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, SumIns, SumChg, Visits,
               CAST(ROW_NUMBER() OVER (ORDER BY SumIns DESC) AS INT) AS PayerRank
        FROM agg ORDER BY SumIns DESC
    )
    SELECT  PayerRank,
            PayerName,
            SumIns AS SumInsurancePayment,
            SumChg AS SumChargeAmount,
            Visits AS UniqueVisitCount,
            CAST(CASE WHEN SumChg = 0 THEN 0 ELSE (SumIns / SumChg) * 100 END AS DECIMAL(18,2)) AS PaymentPct
    FROM ranked
    ORDER BY PayerRank;
END
GO


-- =====================================================================
-- Top 5 Reimbursement Payments - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_Top5ReimbursementPay
-- Filter: InsurancePayment > 0, exclude No Response/Unbilled
-- =====================================================================


CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_Top5ReimbursementPay
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
        SELECT  PayerRank,
                PayerName,
                TotalPayments,
                UniqueVisitCount
        FROM    dbo.PCR_CS_Top5ReimbursementPay
        ORDER BY PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))               AS PayerName,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS TotalIns,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))    AS Visits
        FROM dbo.ClaimLevelData
        WHERE NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate     AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate     AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))
    ),
    ranked AS (
        SELECT TOP 5 PayerName, TotalIns, Visits,
               CAST(ROW_NUMBER() OVER (ORDER BY TotalIns DESC) AS INT) AS PayerRank
        FROM agg ORDER BY TotalIns DESC
    )
    SELECT  PayerRank,
            PayerName,
            TotalIns AS TotalPayments,
            Visits   AS UniqueVisitCount
    FROM ranked
    ORDER BY PayerRank;
END
GO


-- =====================================================================
-- Panel Averages - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_PanelAverages
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_PanelAverages
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

    -- No filter -> serve snapshot (instant). Column names are aliased to the
    -- dashboard contract (AdjudicatedCount/AdjudicatedAmount) even though the
    -- snapshot table stores the legacy misspelled AdjucticatedCount columns.
    IF @HasFilter = 0
    BEGIN
        SELECT
            PanelName,
            PayerName,
            NoOfClaims,
            TotalCharges,
            CarrierPayment,
            AvgCarrierPayment,
            FullyPaidCount,
            FullyPaidAmount,
            AvgFullyPaid,
            AdjucticatedCount   AS AdjudicatedCount,
            AdjucticatedAmount  AS AdjudicatedAmount,
            AvgAdjudicated,
            Days30Count,
            Days30Amount,
            AvgDays30,
            Days60Count,
            Days60Amount,
            AvgDays60,
            RefreshedAt
        FROM  dbo.PCR_CS_PanelAverages
        ORDER BY PanelName, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- When no CheckDate filter supplied, use same 6-month rolling window as Refresh SP
    DECLARE @CheckFrom DATE = ISNULL(@CheckDateFrom, DATEADD(MONTH, -6, CAST(GETDATE() AS DATE)));
    DECLARE @CheckTo   DATE = ISNULL(@CheckDateTo,   CAST(GETDATE() AS DATE));

    -- Live query from ClaimLevelData (mirrors usp_RefreshPCR_CS_PanelAverages)
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,       'Unknown')))  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw,   'Unknown')))  AS PayerName,
            COALESCE(
                NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                LTRIM(RTRIM(ClaimID))
            )                                                  AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))       AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))       AS InsPay,
            LTRIM(RTRIM(ISNULL(FullyPaidCount,      '')))     AS FPC,
            TRY_CAST(FullyPaidAmount  AS DECIMAL(18,2))       AS FullyPaidAmt,
            -- PCR uses AdjucticatedCount (note spelling)
            LTRIM(RTRIM(ISNULL(AdjucticatedCount,   '')))     AS AdjC,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))     AS AdjAmt,
            LTRIM(RTRIM(ISNULL(AgingBucket,          '')))    AS Bucket
        FROM dbo.ClaimLevelData
        WHERE Panelname IS NOT NULL
          AND LEN(LTRIM(RTRIM(Panelname))) > 0
          AND NOT (
                LTRIM(RTRIM(ClaimStatus))    = 'No Response'
            AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled'
          )
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @CheckFrom AND @CheckTo
          AND (@HasPayerFilter = 0
               OR LTRIM(RTRIM(ISNULL(PayerName_Raw, ''))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0
               OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
    ),
    agg AS (
        SELECT
            PanelName,
            PayerName,
            COUNT(DISTINCT VisitKey)                                                       AS NoOfClaims,
            ISNULL(SUM(Chg),    0)                                                         AS TotalCharges,
            ISNULL(SUM(InsPay), 0)                                                         AS CarrierPayment,
            COUNT(DISTINCT CASE WHEN FPC  = 'Fully Paid Count' THEN VisitKey END)          AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FPC  = 'Fully Paid Count'
                            THEN FullyPaidAmt ELSE 0 END), 0)                              AS FullyPaidAmount,
            COUNT(DISTINCT CASE WHEN AdjC IS NOT NULL
                                 AND AdjC <> ''         THEN VisitKey END)                 AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjC IS NOT NULL
                             AND AdjC <> ''
                            THEN AdjAmt ELSE 0 END), 0)                                    AS AdjudicatedAmount,
            COUNT(DISTINCT CASE WHEN Bucket IN ('30+','60+','90+','120+')
                                THEN VisitKey END)                                         AS Days30Count,
            ISNULL(SUM(CASE WHEN Bucket IN ('30+','60+','90+','120+')
                            THEN InsPay ELSE 0 END), 0)                                    AS Days30Amount,
            COUNT(DISTINCT CASE WHEN Bucket IN ('60+','90+','120+')
                                THEN VisitKey END)                                         AS Days60Count,
            ISNULL(SUM(CASE WHEN Bucket IN ('60+','90+','120+')
                            THEN InsPay ELSE 0 END), 0)                                    AS Days60Amount
        FROM src
        GROUP BY PanelName, PayerName
    )
    SELECT
        PanelName,
        PayerName,
        NoOfClaims,
        TotalCharges,
        CarrierPayment,
        CAST(CASE WHEN NoOfClaims        > 0 THEN CarrierPayment    / NoOfClaims        ELSE 0 END AS DECIMAL(18,2)) AS AvgCarrierPayment,
        FullyPaidCount,
        FullyPaidAmount,
        CAST(CASE WHEN FullyPaidCount    > 0 THEN FullyPaidAmount   / FullyPaidCount    ELSE 0 END AS DECIMAL(18,2)) AS AvgFullyPaid,
        AdjudicatedCount,
        AdjudicatedAmount,
        CAST(CASE WHEN AdjudicatedCount  > 0 THEN AdjudicatedAmount / AdjudicatedCount  ELSE 0 END AS DECIMAL(18,2)) AS AvgAdjudicated,
        Days30Count,
        Days30Amount,
        CAST(CASE WHEN Days30Count       > 0 THEN Days30Amount      / Days30Count       ELSE 0 END AS DECIMAL(18,2)) AS AvgDays30,
        Days60Count,
        Days60Amount,
        CAST(CASE WHEN Days60Count       > 0 THEN Days60Amount      / Days60Count       ELSE 0 END AS DECIMAL(18,2)) AS AvgDays60
    FROM agg
    ORDER BY PanelName, PayerName;
END
GO

-- =====================================================================
-- Average Payments - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_AvgPayments
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_AvgPayments
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
        SELECT  AvgChargeAmount,
                AvgInsurancePayment,
                AvgReimbursementPct
        FROM    dbo.PCR_CS_AvgPayments;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        CAST(AVG(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))) AS DECIMAL(18,2))                                     AS AvgChargeAmount,
        CAST(AVG(TRY_CAST(InsurancePayment AS DECIMAL(18,2))) AS DECIMAL(18,2))                                     AS AvgInsurancePayment,
        CAST(AVG(TRY_CAST(InsurancePayment AS DECIMAL(18,2)) / NULLIF(TRY_CAST(ChargeAmount AS DECIMAL(18,2)), 0) * 100) AS DECIMAL(18,2)) AS AvgReimbursementPct
    FROM dbo.LineLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(PostingDate     AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(PostingDate     AS DATE) <= @CheckDateTo);
END
GO

-- =====================================================================
-- Insurance vs Aging - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_InsuranceVsAging
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_InsuranceVsAging
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
                [Current],
                [30],
                [60],
                [90],
                [120]
        FROM    dbo.PCR_CS_InsuranceVsAging
        ORDER BY PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        SUM(CASE WHEN TRY_CAST(AgingDays AS INT) BETWEEN   0 AND  29 THEN TRY_CAST(InsuranceBalance AS DECIMAL(18,2)) ELSE 0 END) AS [Current],
        SUM(CASE WHEN TRY_CAST(AgingDays AS INT) BETWEEN  30 AND  59 THEN TRY_CAST(InsuranceBalance AS DECIMAL(18,2)) ELSE 0 END) AS [30],
        SUM(CASE WHEN TRY_CAST(AgingDays AS INT) BETWEEN  60 AND  89 THEN TRY_CAST(InsuranceBalance AS DECIMAL(18,2)) ELSE 0 END) AS [60],
        SUM(CASE WHEN TRY_CAST(AgingDays AS INT) BETWEEN  90 AND 119 THEN TRY_CAST(InsuranceBalance AS DECIMAL(18,2)) ELSE 0 END) AS [90],
        SUM(CASE WHEN TRY_CAST(AgingDays AS INT) >= 120               THEN TRY_CAST(InsuranceBalance AS DECIMAL(18,2)) ELSE 0 END) AS [120]
    FROM dbo.LineLevelData
    WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(PostingDate     AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(PostingDate     AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))
    ORDER BY PayerName;
END
GO

-- =====================================================================
-- Panel vs Payment - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_PanelVsPayment
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_PanelVsPayment
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
                NoOfClaims,
                InsurancePayment AS InsurancePayments
        FROM    dbo.PCR_CS_PanelVsPayment
        ORDER BY InsurancePayments DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))                          AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                   AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)        AS InsurancePayments
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
    GROUP BY LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))
    ORDER BY InsurancePayments DESC;
END
GO

-- =====================================================================
-- Rep vs Payment - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_RepVsPayment
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_RepVsPayment
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
        SELECT  RepName,
                TotalPayments
        FROM    dbo.PCR_CS_RepVsPayment
        ORDER BY RepName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(RepName, 'Unknown')))                         AS RepName,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)     AS TotalPayments
    FROM dbo.LineLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(PostingDate     AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(PostingDate     AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(ISNULL(RepName, 'Unknown')))
    ORDER BY RepName;
END
GO

-- =====================================================================
-- Insurance vs Payment Percentage - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_InsuranceVsPaymentPct
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_InsuranceVsPaymentPct
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
                PanelGroupCount,
                InsurancePayment,
                PaymentPct
        FROM    dbo.PCR_CS_InsuranceVsPaymentPct
        ORDER BY InsurancePayment DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))               AS PayerName,
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))               AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))                  AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate     AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate     AS DATE) <= @CheckDateTo)
    ),
    Agg AS (
        SELECT
            PayerName,
            COUNT(DISTINCT PanelName)             AS PanelGroupCount,
            ISNULL(SUM(InsPay), 0)                AS InsurancePayment
        FROM Base
        GROUP BY PayerName
    ),
    Grand AS (
        SELECT NULLIF(SUM(InsurancePayment), 0) AS GrandTotal FROM Agg
    )
    SELECT
        a.PayerName,
        a.PanelGroupCount,
        a.InsurancePayment,
        CAST(a.InsurancePayment * 100.0 / ISNULL(g.GrandTotal, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM Agg a
    CROSS JOIN Grand g
    ORDER BY a.InsurancePayment DESC;
END
GO

-- =====================================================================
-- CPT vs Payment Percentage - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_CptVsPaymentPct
-- =====================================================================
/****** Object:  StoredProcedure [dbo].[usp_GetPcr_CS_CptVsPaymentPct]    Script Date: 6/4/2026 2:56:08 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_GetPcr_CS_CptVsPaymentPct]
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
        FROM   dbo.Pcr_CS_CptVsPaymentPct
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

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(CPTCode))                                        AS CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)             AS SumUnits,
            ISNULL(SUM(
                CASE WHEN ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                     THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END
            ), 0)                                                         AS PaidIns,
            ISNULL(SUM(
                CASE WHEN ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                     THEN TRY_CAST(ChargeAmount AS DECIMAL(18,2)) ELSE 0 END
            ), 0)                                                         AS PaidChg
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(CPTCode))
    )
    SELECT
        CPTCode, SumUnits,
        PaidIns AS PaidInsurancePayment,
        PaidChg AS PaidChargeAmount,
        CAST(CASE WHEN PaidChg > 0 THEN PaidIns * 100.0 / PaidChg ELSE 0 END AS DECIMAL(9,4)) AS PaymentPct
    FROM agg
    ORDER BY SumUnits DESC;
END
go
-- =====================================================================
-- Status Summary - Collection Summary
-- Source: dbo.LineLevelData / dbo.PCR_CS_StatusSummary
-- =====================================================================

/****** Object:  StoredProcedure [dbo].[usp_RefreshPcr_CS_StatusSummary]    Script Date: 6/4/2026 3:11:04 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_RefreshPcr_CS_StatusSummary]
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Pcr_CS_StatusSummary;

    ;WITH base AS (
        SELECT
            ISNULL(LTRIM(RTRIM(ClaimStatus)),  '(blank)')  AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(Panelname)),    '(blank)')  AS PanelName,
            ISNULL(NULLIF(LTRIM(RTRIM(
                ISNULL(LTRIM(RTRIM(CPTCode)), '') +
                CASE WHEN NULLIF(LTRIM(RTRIM(Units)),    '') IS NOT NULL
                     THEN ' x ' + LTRIM(RTRIM(Units))    ELSE '' END +
                CASE WHEN NULLIF(LTRIM(RTRIM(Modifier)), '') IS NOT NULL
                     THEN ' x ' + LTRIM(RTRIM(Modifier)) ELSE '' END
            )), ''), '(blank)')                            AS CptCode,
            ISNULL(LTRIM(RTRIM(PayerName_Raw)),'(blank)')  AS PayerName,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(InsuranceBalance AS DECIMAL(18,2))    AS InsBalance,
            TRY_CAST(PatientBalance   AS DECIMAL(18,2))    AS PtBalance
        FROM dbo.LineLevelData
    )
    INSERT INTO dbo.Pcr_CS_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName,
         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ClaimStatus, PanelName, CptCode, PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))  AS NoOfClaims,
        ISNULL(SUM(InsPay),      0)                        AS InsurancePayment,
        ISNULL(SUM(InsBalance),  0)                        AS InsuranceBalance,
        ISNULL(SUM(PtBalance),   0)                        AS PatientBalance,
        GETDATE()
    FROM base
    GROUP BY ClaimStatus, PanelName, CptCode, PayerName;

    PRINT 'usp_RefreshPcr_CS_StatusSummary completed.';
END

/****** Object:  StoredProcedure [dbo].[usp_GetPcr_CS_StatusSummary]    Script Date: 6/4/2026 3:12:57 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

create or ALTER   PROCEDURE [dbo].[usp_GetPcr_CS_StatusSummary]
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
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    -- No-filter: serve from snapshot
    IF @HasFilter = 0
    BEGIN
        SELECT ClaimStatus, PanelName, CptCode, PayerName,
               NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
        FROM   dbo.Pcr_CS_StatusSummary
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

    ;WITH base AS (
        SELECT
            ISNULL(LTRIM(RTRIM(ClaimStatus)),  '(blank)')  AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(Panelname)),    '(blank)')  AS PanelName,
            ISNULL(NULLIF(LTRIM(RTRIM(
                ISNULL(LTRIM(RTRIM(CPTCode)), '') +
                CASE WHEN NULLIF(LTRIM(RTRIM(Units)),    '') IS NOT NULL
                     THEN ' x ' + LTRIM(RTRIM(Units))    ELSE '' END +
                CASE WHEN NULLIF(LTRIM(RTRIM(Modifier)), '') IS NOT NULL
                     THEN ' x ' + LTRIM(RTRIM(Modifier)) ELSE '' END
            )), ''), '(blank)')                            AS CptCode,
            ISNULL(LTRIM(RTRIM(PayerName_Raw)),'(blank)')  AS PayerName,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(InsuranceBalance AS DECIMAL(18,2))    AS InsBalance,
            TRY_CAST(PatientBalance   AS DECIMAL(18,2))    AS PtBalance
        FROM dbo.LineLevelData
        WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        ClaimStatus, PanelName, CptCode, PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))  AS NoOfClaims,
        ISNULL(SUM(InsPay),      0)                        AS InsurancePayment,
        ISNULL(SUM(InsBalance),  0)                        AS InsuranceBalance,
        ISNULL(SUM(PtBalance),   0)                        AS PatientBalance
    FROM base
    GROUP BY ClaimStatus, PanelName, CptCode, PayerName
    ORDER BY ClaimStatus, PanelName, PayerName;
END
go

---


CREATE OR ALTER PROCEDURE dbo.usp_GetPcr_CS_InsuranceVsPayment
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

    -- No-filter: serve pre-computed snapshot.
    IF @HasFilter = 0
    BEGIN
        SELECT  PayerName,
                BillYear,
                BillMonth,
                NoOfPaidClaims,
                InsurancePayment,
                PaymentPct
        FROM    dbo.Pcr_CS_InsuranceVsPayment
        ORDER BY BillYear, BillMonth, InsurancePayment DESC;
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

    -- Filter path: live aggregation matching the refresh SP filter logic.
    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS SMALLINT)        AS BillYear,
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)         AS BillMonth,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                     AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
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
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS SMALLINT),
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

----


/****** Object:  StoredProcedure [dbo].[usp_GetPcr_CS_ProviderSummary]    Script Date: 6/4/2026 3:30:01 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER   PROCEDURE [dbo].[usp_GetPcr_CS_ProviderSummary]
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
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ProviderRank, ReferringProvider,
               NoOfClaims, InsurancePayment as InsurancePayments, InsuranceBalance, PatientBalance
        FROM   dbo.Pcr_CS_ProviderSummary
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
        ReferringProvider, NoOfClaims,
        InsurancePayment AS InsurancePayments,
        InsuranceBalance, PatientBalance
    FROM agg
    ORDER BY ProviderRank;
END
GO
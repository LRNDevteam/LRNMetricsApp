-- =====================================================================
-- InHealth DTR - Collection Summary client logic
-- Run in the InHealthDTRLRN database.
-- Used by LabMetricsDashboard Collection Summary tabs + Excel export
-- (web ExportExcel and LRN.ReportWorker CollectionReportGenerator).
--
-- InHealth data notes:
--   ClaimLevelData.Panelname   is NULL  -> rows use PanelNameBasedOnCPT
--   ClaimLevelData.AgingBucket is blank -> aging uses AgingDOS
--   ClaimLevelData.CPTCode     is blank -> CPT tab uses LineLevelData
--   PaymentPercent is a 0..1 fraction
--
-- 1) Weekly Summary
--      Filter : InsurancePayment > 0
--      Rows   : PanelNameBasedOnCPT, PayerName_Raw
--      Cols   : CheckDate in the last 4 Tue-Mon weeks (OR DODWeek not blank),
--               Count of ClaimID, Sum of InsurancePayment
--      Weeks end on the billed week-range end (latest LineClaimFileLogs.WeekFolder,
--      e.g. '09.15.2026 - 09.21.2026'); without one, the last complete Tue-Mon
--      week on or before the latest CheckDate.
-- 2) Insurance vs Payment %
--      Filter : InsurancePayment > 0, PayerName_Raw not blank
--      Rows   : PayerName_Raw
--      Cols   : Count of ClaimID, Sum of InsurancePayment, Average of PaymentPercent
--      PaymentPct is returned as the 0..1 average; the app shows it x 100.
-- 3) Insurance vs Aging
--      Filter : InsuranceBalance > 0, PayerName_Raw not blank
--      Rows   : PayerName_Raw
--      Cols   : AgingDOS, Count of ClaimID, Sum of InsuranceBalance
-- 4) CPT vs Payment %
--      Rows   : LineLevelData.CPTCode
--      Cols   : Count of ClaimID, Average of PaymentPercent
--      Output columns (unchanged contract, same as Rising Tides script 36):
--        SumUnits             = Count of ClaimID
--        PaidInsurancePayment = SUM(PaymentPercent) in points (x100)
--        PaidChargeAmount     = lines with a PaymentPercent x 100
--        PaymentPct           = AVG(PaymentPercent) in points
-- 5) Insurance Vs Payments
--      Filter : InsurancePayment > 0, PayerName_Raw not blank
--      Rows   : PayerName_Raw
--      Cols   : Sum of InsurancePayment (payer total, no month columns;
--               BillYear / BillMonth are returned as 0)
-- 6) Genetics vs ID Avg (new, Rising Tides shape)
--      a) ClaimStatus = 'Fully Paid'   b) ClaimStatus <> 'No Response'
--      Rows   : PanelNameBasedOnCPT
--      Cols   : Count of ClaimID, Sum of InsurancePayment, Average of PaymentPercent
-- 7) Avg Payments by DOS / by CheckDate (new, Rising Tides logic)
--      usp_GetIHD_CS_AvgPayments_ClientLogic @DateBasis = 'DOS' | 'CheckDate'
--      InHealth leaves FullyPaidCount / AdjudicatedCount NULL, so a claim counts
--      when the Count OR the matching Amount column is not blank.
--
-- Rollback: 39_InHealthDTR_CS_ClientLogic_ROLLBACK.sql
-- =====================================================================

USE InHealthDTRLRN;
GO

SET NOCOUNT ON;
GO

-- ---------------------------------------------------------------------
-- 1) Weekly Summary
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @WeekFolder NVARCHAR(200), @FolderEnd DATE, @MaxCheckDate DATE, @W4End DATE;

    IF OBJECT_ID(N'dbo.LineClaimFileLogs', N'U') IS NOT NULL
        SELECT TOP 1 @WeekFolder = LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200))))
        FROM dbo.LineClaimFileLogs
        WHERE CHARINDEX('-', ISNULL(CAST(WeekFolder AS NVARCHAR(200)), '')) > 0
        ORDER BY FileLogId DESC;

    IF CHARINDEX('-', ISNULL(@WeekFolder, '')) > 0
        SET @FolderEnd = TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(RIGHT(@WeekFolder, CHARINDEX('-', REVERSE(@WeekFolder)) - 1))), '.', '/'), 101);

    -- Tue-Mon weeks: 1900-01-01 is a Monday, 1900-01-02 a Tuesday
    IF @FolderEnd IS NOT NULL
        SET @W4End = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @FolderEnd) % 7), @FolderEnd);
    ELSE
    BEGIN
        SELECT @MaxCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) <= @Today;

        IF @MaxCheckDate IS NULL
        BEGIN
            RAISERROR('No valid CheckDate <= today found in ClaimLevelData.', 16, 1);
            RETURN;
        END;

        SET @W4End = DATEADD(DAY, 6 - (DATEDIFF(DAY, '19000102', @MaxCheckDate) % 7), @MaxCheckDate);
        IF @W4End > @Today SET @W4End = DATEADD(DAY, -7, @W4End);
    END;

    DECLARE @W1Start DATE = DATEADD(DAY, -27, @W4End);

    ;WITH src AS (
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(PanelNameBasedOnCPT)), ''), '(blank)') AS PanelName,
            ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)),       ''), '(blank)') AS PayerName,
            TRY_CAST(CheckDate AS DATE)                                      AS Ckd,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                                AS ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))                      AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End
               OR NULLIF(LTRIM(RTRIM(DODWeek)), '') IS NOT NULL)
    ),
    wk AS (
        SELECT PanelName, PayerName, ClaimID, InsPay,
               4 - DATEDIFF(DAY, Ckd, @W4End) / 7 AS WeekKey
        FROM src
        WHERE Ckd BETWEEN @W1Start AND @W4End
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(ClaimID)         AS NoOfClaims,
               ISNULL(SUM(InsPay), 0) AS InsurancePayment
        FROM wk
        GROUP BY PanelName, PayerName, WeekKey
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName, a.PayerName,
        CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT) AS PayerRank,
        CAST(a.WeekKey AS TINYINT)                                   AS WeekKey,
        DATEADD(DAY, (a.WeekKey - 1) * 7, @W1Start)                  AS WeekStart,
        DATEADD(DAY, (a.WeekKey - 1) * 7 + 6, @W1Start)              AS WeekEnd,
        a.NoOfClaims, a.InsurancePayment
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.IHD_CS_WeeklyClaimVolume;
        INSERT INTO dbo.IHD_CS_WeeklyClaimVolume
            (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, RefreshedAt)
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, GETDATE()
        FROM #out
        ORDER BY PanelName, PayerRank, WeekKey;
    COMMIT;

    DROP TABLE IF EXISTS #out;
    PRINT CONCAT('usp_RefreshIHD_CS_WeeklyClaimVolume completed: ',
                 CONVERT(VARCHAR(10), @W1Start, 101), ' - ', CONVERT(VARCHAR(10), @W4End, 101));
END
GO

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

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @WeekFolder NVARCHAR(200), @FolderEnd DATE, @MaxCheckDate DATE, @W4End DATE;

    IF OBJECT_ID(N'dbo.LineClaimFileLogs', N'U') IS NOT NULL
        SELECT TOP 1 @WeekFolder = LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200))))
        FROM dbo.LineClaimFileLogs
        WHERE CHARINDEX('-', ISNULL(CAST(WeekFolder AS NVARCHAR(200)), '')) > 0
        ORDER BY FileLogId DESC;

    IF CHARINDEX('-', ISNULL(@WeekFolder, '')) > 0
        SET @FolderEnd = TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(RIGHT(@WeekFolder, CHARINDEX('-', REVERSE(@WeekFolder)) - 1))), '.', '/'), 101);

    -- Tue-Mon weeks: 1900-01-01 is a Monday, 1900-01-02 a Tuesday
    IF @FolderEnd IS NOT NULL
        SET @W4End = DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @FolderEnd) % 7), @FolderEnd);
    ELSE
    BEGIN
        SELECT @MaxCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) <= @Today;

        IF @MaxCheckDate IS NULL
        BEGIN
            SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
                   NoOfClaims, InsurancePayment, CAST(0 AS DECIMAL(18,2)) AS AveragePaidAmount
            FROM dbo.IHD_CS_WeeklyClaimVolume WHERE 1 = 0;
            RETURN;
        END;

        SET @W4End = DATEADD(DAY, 6 - (DATEDIFF(DAY, '19000102', @MaxCheckDate) % 7), @MaxCheckDate);
        IF @W4End > @Today SET @W4End = DATEADD(DAY, -7, @W4End);
    END;

    DECLARE @W1Start DATE = DATEADD(DAY, -27, @W4End);

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL);
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
            ISNULL(NULLIF(LTRIM(RTRIM(PanelNameBasedOnCPT)), ''), '(blank)') AS PanelName,
            ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)),       ''), '(blank)') AS PayerName,
            TRY_CAST(CheckDate AS DATE)                                      AS Ckd,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                                AS ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))                      AS InsPay
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND (TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End
               OR NULLIF(LTRIM(RTRIM(DODWeek)), '') IS NOT NULL)
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(PanelNameBasedOnCPT)) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    wk AS (
        SELECT PanelName, PayerName, ClaimID, InsPay,
               4 - DATEDIFF(DAY, Ckd, @W4End) / 7 AS WeekKey
        FROM src
        WHERE Ckd BETWEEN @W1Start AND @W4End
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(ClaimID)         AS NoOfClaims,
               ISNULL(SUM(InsPay), 0) AS InsurancePayment
        FROM wk
        GROUP BY PanelName, PayerName, WeekKey
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName, a.PayerName,
        CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT) AS PayerRank,
        CAST(a.WeekKey AS TINYINT)                                   AS WeekKey,
        DATEADD(DAY, (a.WeekKey - 1) * 7, @W1Start)                  AS WeekStart,
        DATEADD(DAY, (a.WeekKey - 1) * 7 + 6, @W1Start)              AS WeekEnd,
        a.NoOfClaims, a.InsurancePayment,
        CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END
GO

-- ---------------------------------------------------------------------
-- 2) Insurance vs Payment %
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                            AS PayerName,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                               AS PanelGroupCount,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS InsurancePayment,
        CAST(ISNULL(AVG(TRY_CAST(PaymentPercent AS DECIMAL(18,6))), 0) AS DECIMAL(9,4)) AS PaymentPct
    INTO #out
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(PayerName_Raw));

    BEGIN TRAN;
        TRUNCATE TABLE dbo.IHD_CS_InsuranceVsPaymentPct;
        INSERT INTO dbo.IHD_CS_InsuranceVsPaymentPct
            (PayerName, PanelGroupCount, InsurancePayment, PaymentPct, RefreshedAt)
        SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct, GETDATE()
        FROM #out ORDER BY InsurancePayment DESC;
    COMMIT;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_InsuranceVsPaymentPct completed.';
END
GO

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

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                            AS PayerName,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                               AS PanelGroupCount,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS InsurancePayment,
        CAST(ISNULL(AVG(TRY_CAST(PaymentPercent AS DECIMAL(18,6))), 0) AS DECIMAL(9,4)) AS PaymentPct
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(PanelNameBasedOnCPT)) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(PayerName_Raw))
    ORDER BY SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))) DESC;
END
GO

-- ---------------------------------------------------------------------
-- 3) Insurance vs Aging
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
        ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), '(blank)')        AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                     AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance
    INTO #out
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) > 0
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(PayerName_Raw)), ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), '(blank)');

    BEGIN TRAN;
        TRUNCATE TABLE dbo.IHD_CS_InsuranceVsAging;
        INSERT INTO dbo.IHD_CS_InsuranceVsAging
            (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance, GETDATE()
        FROM #out;
    COMMIT;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_InsuranceVsAging completed.';
END
GO

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

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL);
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
        ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), '(blank)')        AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                     AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) > 0
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(PanelNameBasedOnCPT)) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(PayerName_Raw)), ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), '(blank)')
    ORDER BY PayerName, AgingBucket;
END
GO

-- ---------------------------------------------------------------------
-- 4) CPT vs Payment %
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH src AS (
        SELECT
            LEFT(LTRIM(RTRIM(CPTCode)), 50)                              AS CPTCode,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                            AS ClaimID,
            TRY_CAST(PaymentPercent AS DECIMAL(18,6)) * 100.0            AS LinePct
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
    )
    SELECT
        CPTCode,
        CAST(COUNT(ClaimID) AS DECIMAL(18,2))                AS SumUnits,
        CAST(ISNULL(SUM(LinePct), 0) AS DECIMAL(18,2))       AS PaidIns,
        CAST(COUNT(LinePct) * 100 AS DECIMAL(18,2))          AS PaidChg,
        CAST(ISNULL(AVG(LinePct), 0) AS DECIMAL(9,4))        AS PaymentPct
    INTO #out
    FROM src
    GROUP BY CPTCode;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.IHD_CS_CptVsPaymentPct;
        INSERT INTO dbo.IHD_CS_CptVsPaymentPct
            (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
        SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
        FROM #out ORDER BY SumUnits DESC;
    COMMIT;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_CptVsPaymentPct completed.';
END
GO

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
        ORDER  BY SumUnits DESC, CPTCode;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL);
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
            LEFT(LTRIM(RTRIM(CPTCode)), 50)                              AS CPTCode,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                            AS ClaimID,
            TRY_CAST(PaymentPercent AS DECIMAL(18,6)) * 100.0            AS LinePct
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(Panelname))     IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        CPTCode,
        CAST(COUNT(ClaimID) AS DECIMAL(18,2))                AS SumUnits,
        CAST(ISNULL(SUM(LinePct), 0) AS DECIMAL(18,2))       AS PaidInsurancePayment,
        CAST(COUNT(LinePct) * 100 AS DECIMAL(18,2))          AS PaidChargeAmount,
        CAST(ISNULL(AVG(LinePct), 0) AS DECIMAL(9,4))        AS PaymentPct
    FROM src
    GROUP BY CPTCode
    ORDER BY SumUnits DESC, CPTCode;
END
GO

-- ---------------------------------------------------------------------
-- 5) Insurance Vs Payments (payer total; the app reads this SP directly)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_InsuranceVsPayment
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

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL);
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
            LTRIM(RTRIM(PayerName_Raw))                                 AS PayerName,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(PanelNameBasedOnCPT)) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(PayerName_Raw))
    )
    SELECT a.PayerName,
           CAST(0 AS INT)     AS BillYear,
           CAST(0 AS TINYINT) AS BillMonth,
           a.NoOfPaidClaims,
           a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / NULLIF(SUM(a.InsurancePayment) OVER (), 0) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    ORDER BY a.InsurancePayment DESC;
END
GO

-- ---------------------------------------------------------------------
-- 6) Genetics vs ID Avg
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_GeneticsVsIdAvg
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

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL);
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
            ISNULL(NULLIF(LTRIM(RTRIM(PanelNameBasedOnCPT)), ''), '(blank)') AS PanelName,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                                AS ClaimID,
            ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0)           AS InsPay,
            TRY_CAST(PaymentPercent AS DECIMAL(18,6))                        AS PayPct,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), '')                            AS ClaimStatus
        FROM dbo.ClaimLevelData
        WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(PanelNameBasedOnCPT)) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    tagged AS (
        SELECT CAST('FullyPaid' AS VARCHAR(20)) AS SummaryType, PanelName, ClaimID, InsPay, PayPct
        FROM src
        WHERE ClaimStatus = 'Fully Paid'
        UNION ALL
        SELECT CAST('ExclNoResponse' AS VARCHAR(20)), PanelName, ClaimID, InsPay, PayPct
        FROM src
        WHERE ClaimStatus <> 'No Response'
    )
    SELECT
        SummaryType,
        PanelName,
        CAST(COUNT(ClaimID) AS INT)                                    AS ClaimCount,
        CAST(SUM(InsPay) AS DECIMAL(18,2))                             AS CarrierPayment,
        CAST(SUM(InsPay) / NULLIF(COUNT(ClaimID), 0) AS DECIMAL(18,2)) AS AveragePayment,
        CAST(ISNULL(AVG(PayPct), 0) * 100 AS DECIMAL(9,4))             AS AvgPaymentPct
    FROM tagged
    GROUP BY SummaryType, PanelName
    ORDER BY SummaryType, CarrierPayment DESC, PanelName;
END
GO

-- ---------------------------------------------------------------------
-- 7) Avg Payments by DOS / by CheckDate
--    6 calendar months back from the latest date in that column on or before
--    the billed week-range end (latest LineClaimFileLogs.WeekFolder).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_AvgPayments_ClientLogic
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL,
    @DateBasis       VARCHAR(10)   = 'DOS',
    @LastMonths      INT           = 6
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UseCheckDate BIT = CASE WHEN @DateBasis = 'CheckDate' THEN 1 ELSE 0 END;
    IF @LastMonths IS NULL OR @LastMonths < 1 SET @LastMonths = 6;

    DECLARE @WeekFolder NVARCHAR(200), @WeekEnd DATE;
    IF OBJECT_ID(N'dbo.LineClaimFileLogs', N'U') IS NOT NULL
        SELECT TOP 1 @WeekFolder = LTRIM(RTRIM(CAST(WeekFolder AS NVARCHAR(200))))
        FROM dbo.LineClaimFileLogs
        WHERE NULLIF(LTRIM(RTRIM(CAST(RunId AS NVARCHAR(50)))), '') IS NOT NULL
        ORDER BY FileLogId DESC;

    IF CHARINDEX('-', ISNULL(@WeekFolder, '')) > 0
        SET @WeekEnd = TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(RIGHT(@WeekFolder, CHARINDEX('-', REVERSE(@WeekFolder)) - 1))), '.', '/'), 101);

    DECLARE @WindowTo DATE =
        CASE WHEN @UseCheckDate = 1
            THEN (SELECT MAX(TRY_CAST(CheckDate AS DATE)) FROM dbo.ClaimLevelData
                  WHERE @WeekEnd IS NULL OR TRY_CAST(CheckDate AS DATE) <= @WeekEnd)
            ELSE (SELECT MAX(TRY_CAST(DateofService AS DATE)) FROM dbo.ClaimLevelData
                  WHERE @WeekEnd IS NULL OR TRY_CAST(DateofService AS DATE) <= @WeekEnd)
        END;
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, DATEADD(MONTH, -@LastMonths, @WindowTo));

    CREATE TABLE #PayerList (Value NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    -- 30/60-day columns are Bucket30*/Bucket60* on live and Days30*/Days60* on older copies.
    DECLARE @B NVARCHAR(10) =
        CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'Bucket30Count') IS NOT NULL THEN N'Bucket' ELSE N'Days' END;

    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH src AS (
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(PanelNameBasedOnCPT)), ''''), ''(blank)'') AS PanelName,
            ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)),       ''''), ''(blank)'') AS PayerName,
            NULLIF(LTRIM(RTRIM(ClaimID)), '''')                                  AS ClaimID,
            TRY_CAST(ChargeAmount      AS DECIMAL(18,2))                         AS Chg,
            TRY_CAST(InsurancePayment  AS DECIMAL(18,2))                         AS InsPay,
            COALESCE(NULLIF(LTRIM(RTRIM(FullyPaidCount)),   ''''),
                     NULLIF(LTRIM(RTRIM(FullyPaidAmount)),  ''''))               AS FpFlag,
            TRY_CAST(FullyPaidAmount   AS DECIMAL(18,2))                         AS FpAmt,
            COALESCE(NULLIF(LTRIM(RTRIM(AdjudicatedCount)), ''''),
                     NULLIF(LTRIM(RTRIM(AdjudicatedAmount)),''''))               AS AdjFlag,
            TRY_CAST(AdjudicatedAmount AS DECIMAL(18,2))                         AS AdjAmt,
            COALESCE(NULLIF(LTRIM(RTRIM({B}30Count)),       ''''),
                     NULLIF(LTRIM(RTRIM({B}30Amount)),      ''''))               AS B30Flag,
            TRY_CAST({B}30Amount       AS DECIMAL(18,2))                         AS B30Amt,
            COALESCE(NULLIF(LTRIM(RTRIM({B}60Count)),       ''''),
                     NULLIF(LTRIM(RTRIM({B}60Amount)),      ''''))               AS B60Flag,
            TRY_CAST({B}60Amount       AS DECIMAL(18,2))                         AS B60Amt
        FROM dbo.ClaimLevelData
        WHERE CASE WHEN @UseCheckDate = 1 THEN TRY_CAST(CheckDate AS DATE)
                   ELSE TRY_CAST(DateofService AS DATE) END BETWEEN @WindowFrom AND @WindowTo
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(PanelNameBasedOnCPT)) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PanelName,
        PayerName,
        CAST(COUNT(ClaimID) AS INT)                                              AS NoOfClaims,
        ISNULL(SUM(Chg), 0)                                                      AS TotalCharges,
        ISNULL(SUM(InsPay), 0)                                                   AS CarrierPayment,
        CAST(COUNT(CASE WHEN FpFlag  IS NOT NULL THEN ClaimID END) AS INT)       AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FpFlag  IS NOT NULL THEN FpAmt  END), 0)            AS FullyPaidAmount,
        CAST(COUNT(CASE WHEN AdjFlag IS NOT NULL THEN ClaimID END) AS INT)       AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjFlag IS NOT NULL THEN AdjAmt END), 0)            AS AdjudicatedAmount,
        CAST(COUNT(CASE WHEN B30Flag IS NOT NULL THEN ClaimID END) AS INT)       AS Days30Count,
        ISNULL(SUM(CASE WHEN B30Flag IS NOT NULL THEN B30Amt END), 0)            AS Days30Amount,
        CAST(COUNT(CASE WHEN B60Flag IS NOT NULL THEN ClaimID END) AS INT)       AS Days60Count,
        ISNULL(SUM(CASE WHEN B60Flag IS NOT NULL THEN B60Amt END), 0)            AS Days60Amount,
        @WindowFrom                                                              AS WindowFrom,
        @WindowTo                                                                AS WindowTo
    FROM src
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, PayerName;';

    SET @sql = REPLACE(@sql, N'{B}', @B);

    EXEC sys.sp_executesql @sql,
        N'@UseCheckDate BIT, @WindowFrom DATE, @WindowTo DATE, @HasPayerFilter BIT, @HasPanelFilter BIT,
          @DosFrom DATE, @DosTo DATE, @FirstBillFrom DATE, @FirstBillTo DATE, @CheckDateFrom DATE, @CheckDateTo DATE',
        @UseCheckDate, @WindowFrom, @WindowTo, @HasPayerFilter, @HasPanelFilter,
        @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo;
END
GO

-- ---------------------------------------------------------------------
-- Rebuild the no-filter snapshots
-- ---------------------------------------------------------------------
EXEC dbo.usp_RefreshIHD_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshIHD_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshIHD_CS_CptVsPaymentPct;
GO

-- Checks
SELECT WeekKey, MIN(WeekStart) AS WeekStart, MAX(WeekEnd) AS WeekEnd,
       SUM(NoOfClaims) AS [Count of ClaimID], SUM(InsurancePayment) AS [Sum of InsurancePayment]
FROM dbo.IHD_CS_WeeklyClaimVolume GROUP BY WeekKey ORDER BY WeekKey;

SELECT COUNT(*) AS Payers, SUM(PanelGroupCount) AS [Count of ClaimID], SUM(InsurancePayment) AS [Sum of InsurancePayment],
       CAST(SUM(PaymentPct * PanelGroupCount) / NULLIF(SUM(PanelGroupCount), 0) * 100 AS DECIMAL(9,2)) AS [Average of PaymentPercent %]
FROM dbo.IHD_CS_InsuranceVsPaymentPct;

SELECT AgingBucket, SUM(VisitCount) AS [Count of ClaimID], SUM(InsuranceBalance) AS [Sum of InsuranceBalance]
FROM dbo.IHD_CS_InsuranceVsAging GROUP BY AgingBucket ORDER BY AgingBucket;

SELECT COUNT(*) AS CptRows, CAST(SUM(SumUnits) AS INT) AS [Count of ClaimID],
       CAST(SUM(PaidInsurancePayment) / NULLIF(SUM(PaidChargeAmount), 0) * 100 AS DECIMAL(9,2)) AS [Average of PaymentPercent %]
FROM dbo.IHD_CS_CptVsPaymentPct;
GO

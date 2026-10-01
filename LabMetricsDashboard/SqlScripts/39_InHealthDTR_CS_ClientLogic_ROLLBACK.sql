-- =====================================================================
-- ROLLBACK for 39_InHealthDTR_CS_ClientLogic.sql (run in InHealthDTRLRN)
-- Restores the IHD Collection Summary SPs exactly as they were on live,
-- drops the two new SPs and rebuilds the snapshots.
-- Also redeploy the previous app build (LabCollectionPrefix lists IHD for
-- Genetics vs ID Avg / Avg Payments by DOS + CheckDate).
-- =====================================================================
USE InHealthDTRLRN;
GO

SET NOCOUNT ON;
GO
-- 4. Weekly Claim Volume

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_WeeklyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MaxCheckDate DATE;
    DECLARE @WeekContainingMaxStart DATE;
    DECLARE @WeekContainingMaxEnd   DATE;
    DECLARE @LatestCompletedWeekStart DATE;
    DECLARE @LatestCompletedWeekEnd   DATE;
    SELECT @MaxCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND TRY_CAST(CheckDate AS DATE) <= @Today
      AND LTRIM(RTRIM(CheckDate)) <> '';
    IF @MaxCheckDate IS NULL
    BEGIN
        RAISERROR('No valid CheckDate <= today found in ClaimLevelData.', 16, 1);
        RETURN;
    END;
    -- Thu-Wed week; 1900-01-04 is Thursday
    SET @WeekContainingMaxStart =
        DATEADD(DAY, -(DATEDIFF(DAY, '19000104', @MaxCheckDate) % 7), @MaxCheckDate);
    SET @WeekContainingMaxEnd = DATEADD(DAY, 6, @WeekContainingMaxStart);
    IF @WeekContainingMaxEnd <= @Today
    BEGIN
        SET @LatestCompletedWeekStart = @WeekContainingMaxStart;
        SET @LatestCompletedWeekEnd   = @WeekContainingMaxEnd;
    END
    ELSE
    BEGIN
        SET @LatestCompletedWeekStart = DATEADD(DAY, -7, @WeekContainingMaxStart);
        SET @LatestCompletedWeekEnd   = DATEADD(DAY,  6, @LatestCompletedWeekStart);
    END;
    DECLARE @W4Start DATE = @LatestCompletedWeekStart;
    DECLARE @W4End   DATE = @LatestCompletedWeekEnd;
    DECLARE @W3Start DATE = DATEADD(DAY, -7, @W4Start);  DECLARE @W3End DATE = DATEADD(DAY, 6, @W3Start);
    DECLARE @W2Start DATE = DATEADD(DAY, -7, @W3Start);  DECLARE @W2End DATE = DATEADD(DAY, 6, @W2Start);
    DECLARE @W1Start DATE = DATEADD(DAY, -7, @W2Start);  DECLARE @W1End DATE = DATEADD(DAY, 6, @W1Start);
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown'))) AS PanelName,
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
    ),
    agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))  AS NoOfClaims,
               ISNULL(SUM(InsPay), 0)                    AS InsurancePayment
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
        a.NoOfClaims, a.InsurancePayment
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName;
    TRUNCATE TABLE dbo.IHD_CS_WeeklyClaimVolume;
    INSERT INTO dbo.IHD_CS_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank, WeekKey;
    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_WeeklyClaimVolume completed.';
    print @W1Start 
    print @W4End

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
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
            LTRIM(RTRIM(ISNULL(Panelname, '')))                                      AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))                              AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))                               AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
          AND NOT (LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
                   AND LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))) = 'Unbilled')
    ),
    agg AS (
        SELECT PayerName,
               COUNT(PanelName)                        AS PanelGroupCount,
               ISNULL(SUM(InsPay), 0)                  AS InsurancePayment,
               ROUND(ISNULL(AVG(PayPct), 0) * 100, 0)  AS PaymentPct
        FROM base GROUP BY PayerName
    )
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.IHD_CS_InsuranceVsPaymentPct;
    INSERT INTO dbo.IHD_CS_InsuranceVsPaymentPct
        (PayerName, PanelGroupCount, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct, GETDATE()
    FROM #out ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_InsuranceVsPaymentPct completed.';
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
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.IHD_CS_InsuranceVsAging;

    INSERT INTO dbo.IHD_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')))   AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                  AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)               AS InsuranceBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND NOT (LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
               AND LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))) = 'Unbilled')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')));

    PRINT 'usp_RefreshIHD_CS_InsuranceVsAging completed.';
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
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LEFT(LTRIM(RTRIM(CPTCode)), 50)                            AS CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)           AS SumUnits,
            ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidIns,
            ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChg
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
        GROUP BY LEFT(LTRIM(RTRIM(CPTCode)), 50)
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg,
           CASE WHEN PaidChg > 0
                THEN CAST(PaidIns * 100.0 / PaidChg AS DECIMAL(9,4))
                ELSE 0 END AS PaymentPct
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.IHD_CS_CptVsPaymentPct;
    INSERT INTO dbo.IHD_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_CptVsPaymentPct completed.';
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

    -- This SP has no snapshot path: there is no IHD_CS_InsuranceVsPayment table.
    -- It always aggregates live from ClaimLevelData.

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
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))             AS PayerName,
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT)            AS BillYear,
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)        AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))           AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL AND CheckDate <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,      'Unknown'))) IN (SELECT Value FROM @PanelList))
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
        FROM agg
        GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName, a.BillYear, a.BillMonth, a.NoOfPaidClaims,
           a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    INNER JOIN grand g ON a.BillYear = g.BillYear AND a.BillMonth = g.BillMonth
    ORDER BY a.BillYear, a.BillMonth, a.InsurancePayment DESC;
END
GO
DROP PROCEDURE IF EXISTS dbo.usp_GetIHD_CS_GeneticsVsIdAvg;
DROP PROCEDURE IF EXISTS dbo.usp_GetIHD_CS_AvgPayments_ClientLogic;
GO
EXEC dbo.usp_RefreshIHD_CS_WeeklyClaimVolume;
EXEC dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshIHD_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshIHD_CS_CptVsPaymentPct;
GO

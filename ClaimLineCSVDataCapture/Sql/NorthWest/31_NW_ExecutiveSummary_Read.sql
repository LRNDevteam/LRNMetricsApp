-- ============================================================
-- NorthWest – Executive Summary Read SP
-- File : 31_NW_ExecutiveSummary_Read.sql
-- DB   : NorthWest_LRN
--
-- usp_GetNW_ExecutiveSummary(@YearFrom,@YearTo,@MonthFrom,@MonthTo)
--   @HasFilter = 0  → fast read from 4 NW_ES_ aggregate tables.
--   @HasFilter = 1  → live re-aggregate from LIMSMaster + ClaimLevelData.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ExecutiveSummary
(
    @YearFrom     INT           = 0,
    @YearTo       INT           = 0,
    @MonthFrom    INT           = 0,
    @MonthTo      INT           = 0,
    @DosFrom      DATE          = NULL,
    @DosTo        DATE          = NULL,
    @ReceivedFrom DATE          = NULL,
    @ReceivedTo   DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    @PostedFrom   DATE          = NULL,
    @PostedTo     DATE          = NULL,
    @Panels       NVARCHAR(MAX) = NULL,
    @Clinics      NVARCHAR(MAX) = NULL,
    @Providers    NVARCHAR(MAX) = NULL,
    @Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT = CASE
        WHEN ISNULL(@YearFrom,  0) <> 0 THEN 1
        WHEN ISNULL(@YearTo,    0) <> 0 THEN 1
        WHEN ISNULL(@MonthFrom, 0) <> 0 THEN 1
        WHEN ISNULL(@MonthTo,   0) <> 0 THEN 1
        WHEN @DosFrom      IS NOT NULL THEN 1
        WHEN @DosTo        IS NOT NULL THEN 1
        WHEN @ReceivedFrom IS NOT NULL THEN 1
        WHEN @ReceivedTo   IS NOT NULL THEN 1
        WHEN @BilledFrom   IS NOT NULL THEN 1
        WHEN @BilledTo     IS NOT NULL THEN 1
        WHEN @PostedFrom   IS NOT NULL THEN 1
        WHEN @PostedTo     IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL THEN 1
        WHEN NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL THEN 1
        ELSE 0
    END;

    -- ════════════════════════════════════════════════════════════════════
    --  NO FILTER  –  fast read from the 4 aggregate tables
    -- ════════════════════════════════════════════════════════════════════
    IF @HasFilter = 0
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS'  AS Category, Description,
                   ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue,
                   1 AS CatOrder, Id AS SortId
            FROM dbo.NW_ES_LIS

            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)), 2, Id
            FROM dbo.NW_ES_PMS

            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
                   ESMonthChargeAmount, 3, Id
            FROM dbo.NW_ES_Cash

            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
                   ESMonthChargeAmount, 4, Id
            FROM dbo.NW_ES_Avg
        ) x
        ORDER BY BillYear, BillMonth, CatOrder, SortId;
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  FILTERED  –  live re-aggregate for date-range slice
    -- ════════════════════════════════════════════════════════════════════

    -- Dimension filter staging tables
    CREATE TABLE #FilterPanels   (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterClinics  (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterProviders(Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #FilterReps     (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL
        INSERT INTO #FilterPanels(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Panels, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL
        INSERT INTO #FilterClinics(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Clinics, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL
        INSERT INTO #FilterProviders(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Providers, ',') WHERE LTRIM(RTRIM(value)) <> '';
    IF NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL
        INSERT INTO #FilterReps(Val)
        SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Reps, ',') WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @HasPanelFilter    BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterPanels)    THEN 1 ELSE 0 END;
    DECLARE @HasClinicFilter   BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterClinics)   THEN 1 ELSE 0 END;
    DECLARE @HasProviderFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterProviders) THEN 1 ELSE 0 END;
    DECLARE @HasRepFilter      BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterReps)      THEN 1 ELSE 0 END;

    -- ── LIS: read from aggregate table with period filter ────────────────
    SELECT RoleID AS RowCode, 'LIS' AS Category, Description,
           ESYear AS BillYear, ESMonth AS BillMonth,
           CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue
    INTO #LisRows
    FROM dbo.NW_ES_LIS
    WHERE (@YearFrom=0  OR ESYear  >= @YearFrom)
      AND (@YearTo=0    OR ESYear  <= @YearTo)
      AND (@MonthFrom=0 OR ESMonth >= @MonthFrom)
      AND (@MonthTo=0   OR ESMonth <= @MonthTo)
      AND ESYear<>0;

    -- ── ClaimLevelData column detection ──────────────────────────────────
    DECLARE @BilledCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('Billed','BillStatus','BillingStatus','BilledStatus')
        ORDER BY CASE name WHEN 'Billed' THEN 0 WHEN 'BillStatus' THEN 1 WHEN 'BillingStatus' THEN 2 ELSE 3 END);

    DECLARE @ClaimTypeCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('ClaimType','ClaimCategory')
        ORDER BY CASE name WHEN 'ClaimType' THEN 0 ELSE 1 END);

    DECLARE @ActualPayCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('ActualPayment','ActualPay')
        ORDER BY CASE name WHEN 'ActualPayment' THEN 0 ELSE 1 END);

    DECLARE @DupPayCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
          AND name IN ('DuplicatePayment','DuplicatePay')
        ORDER BY CASE name WHEN 'DuplicatePayment' THEN 0 ELSE 1 END);

    -- Build #Base for filtered path
    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        AccessionNumber  NVARCHAR(100) NOT NULL,
        ESYear           INT NOT NULL, ESMonth INT NOT NULL,
        Billed           NVARCHAR(50)  NOT NULL,
        ClaimType        NVARCHAR(200) NOT NULL,
        ClaimStatus      NVARCHAR(200) NOT NULL,
        ChargeAmount     DECIMAL(18,2) NOT NULL,
        InsurancePayment DECIMAL(18,2) NOT NULL,
        ActualPayment    DECIMAL(18,2) NOT NULL,
        DuplicatePayment DECIMAL(18,2) NOT NULL,
        PatientPayment   DECIMAL(18,2) NOT NULL,
        InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientAdjustments   DECIMAL(18,2) NOT NULL,
        InsuranceBalance DECIMAL(18,2) NOT NULL,
        PatientBalance   DECIMAL(18,2) NOT NULL
    );

    IF @BilledCol IS NOT NULL AND @ClaimTypeCol IS NOT NULL
    BEGIN
        DECLARE @ActExpr NVARCHAR(300) = CASE WHEN @ActualPayCol IS NOT NULL
            THEN N'ISNULL(TRY_CAST([' + @ActualPayCol + N'] AS DECIMAL(18,2)),0)' ELSE N'0' END;
        DECLARE @DupExpr NVARCHAR(300) = CASE WHEN @DupPayCol IS NOT NULL
            THEN N'ISNULL(TRY_CAST([' + @DupPayCol + N'] AS DECIMAL(18,2)),0)' ELSE N'0' END;

        DECLARE @BaseSql NVARCHAR(MAX) = N'
            INSERT INTO #Base SELECT
                LTRIM(RTRIM(ISNULL(AccessionNumber,''''))),
                YEAR(TRY_CAST(DateofService AS DATE)), MONTH(TRY_CAST(DateofService AS DATE)),
                ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),''''),
                ISNULL(LTRIM(RTRIM([' + @ClaimTypeCol + N'])),''''),
                ISNULL(LTRIM(RTRIM(ClaimStatus)),''''),
                ISNULL(TRY_CAST(ChargeAmount AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0),
                ' + @ActExpr + N', ' + @DupExpr + N',
                ISNULL(TRY_CAST(PatientPayment AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(PatientAdjustments AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)),0),
                ISNULL(TRY_CAST(PatientBalance AS DECIMAL(18,2)),0)
            FROM dbo.ClaimLevelData
            WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(ISNULL(AccessionNumber,''''))),'''') IS NOT NULL
              AND (ISNULL(@yf,0)=0 OR YEAR(TRY_CAST(DateofService AS DATE))>=@yf)
              AND (ISNULL(@yt,0)=0 OR YEAR(TRY_CAST(DateofService AS DATE))<=@yt)
              AND (ISNULL(@mf,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE))>=@mf)
              AND (ISNULL(@mt,0)=0 OR MONTH(TRY_CAST(DateofService AS DATE))<=@mt)
              AND (@df IS NULL OR TRY_CAST(DateofService   AS DATE) >= @df)
              AND (@dt IS NULL OR TRY_CAST(DateofService   AS DATE) <= @dt)
              AND (@bf IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @bf)
              AND (@bt IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @bt)
              AND (@pf IS NULL OR TRY_CAST(PostedDate      AS DATE) >= @pf)
              AND (@pt IS NULL OR TRY_CAST(PostedDate      AS DATE) <= @pt)
              AND (@hpf=0 OR LTRIM(RTRIM(ISNULL(PanelType,        ''''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterPanels))
              AND (@hcf=0 OR LTRIM(RTRIM(ISNULL(ClinicName,       ''''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterClinics))
              AND (@hpvf=0 OR LTRIM(RTRIM(ISNULL(ReferringProvider,''''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterProviders))
              AND (@hrf=0 OR LTRIM(RTRIM(ISNULL(SalesRepname,     ''''))) COLLATE DATABASE_DEFAULT IN (SELECT Val FROM #FilterReps));';
        EXEC sp_executesql @BaseSql,
             N'@yf INT,@yt INT,@mf INT,@mt INT,@df DATE,@dt DATE,@bf DATE,@bt DATE,@pf DATE,@pt DATE,@hpf BIT,@hcf BIT,@hpvf BIT,@hrf BIT',
             @yf=@YearFrom, @yt=@YearTo, @mf=@MonthFrom, @mt=@MonthTo,
             @df=@DosFrom, @dt=@DosTo,
             @bf=@BilledFrom, @bt=@BilledTo,
             @pf=@PostedFrom, @pt=@PostedTo,
             @hpf=@HasPanelFilter, @hcf=@HasClinicFilter, @hpvf=@HasProviderFilter, @hrf=@HasRepFilter;
    END

    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base;

    -- Combine LIS (from aggregate table) + PMS/Cash/Avg (live) + Avg sentinel
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue FROM #LisRows

    UNION ALL
    -- PMS: G, H, M-S
    SELECT 'G','PMS','No. of Billed Claims',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'H','PMS','No. of Unbilled Claims',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'J','PMS','Test Patient Entries',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.ClaimType='Test Patient Entries' THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'K','PMS','ADCS Claims',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.ClaimType='ADCS - Invoice' THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'M','PMS','No. of Fully Paid Claims',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus='Fully Paid' THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'S','PMS','No. of Insurance Balance Claims',b.ESYear,b.ESMonth,
           COUNT(DISTINCT CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus IN ('Fully Denied','Partially Denied','No Response') THEN b.AccessionNumber END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth

    UNION ALL
    -- Cash: T, U, X, AA, AC
    SELECT 'T','Cash','Total Billed ($)',b.ESYear,b.ESMonth,
           SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.ChargeAmount ELSE 0 END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'U','Cash','Total Unbilled ($)',b.ESYear,b.ESMonth,
           SUM(CASE WHEN ISNULL(b.Billed,'') IN ('','Unbilled') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') THEN b.ChargeAmount ELSE 0 END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'X','Cash','Insurance Payment ($)',b.ESYear,b.ESMonth,
           SUM(CASE WHEN b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus='Fully Paid' THEN b.InsurancePayment ELSE 0 END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth
    UNION ALL
    SELECT 'AC','Cash','Insurance Balance ($)',b.ESYear,b.ESMonth,
           SUM(CASE WHEN b.Billed IN ('Billed','Billed - Client') AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') THEN b.InsuranceBalance ELSE 0 END)
    FROM #Base b GROUP BY b.ESYear, b.ESMonth

    UNION ALL
    -- Avg: AD, AE, AF (computed inline)
    SELECT 'AD','Avg','Average Payment ($) - Total Pay/Billed Claims',b.ESYear,b.ESMonth,
           CASE WHEN COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)>0
                THEN SUM(CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.InsurancePayment+b.PatientPayment ELSE 0 END)
                   / COUNT(DISTINCT CASE WHEN b.Billed='Billed' AND b.ClaimType NOT IN ('ADCS - Invoice','Test Patient Entries') AND b.ClaimStatus<>'Billed Amount 0' THEN b.AccessionNumber END)
                ELSE 0 END
    FROM #Base b GROUP BY b.ESYear, b.ESMonth

    ORDER BY BillYear, BillMonth, Category, RowCode;

    DROP TABLE IF EXISTS #LisRows;
    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
END;
GO

PRINT '31_NW_ExecutiveSummary_Read.sql completed.';
GO

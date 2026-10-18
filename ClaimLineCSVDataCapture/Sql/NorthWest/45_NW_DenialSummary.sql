/* =============================================================================
   NorthWest - Denial Summary (Denial Analysis Report)
   File     : 45_NW_DenialSummary.sql
   Database : NWL_LRN        Prefix : NW_
   Source   : dbo.ClaimLevelData (Claim Level)
   Mirrors  : AnalyzePathology/30_AnalyzePathology_DenialSummary.sql (SP / result
              contracts, so SqlDenialSummaryRepository works unchanged), with the
              NorthWest client rules below.

   COMMON DENIAL FILTER (tabs 1 - 5)
     DenialCode not blank (LTRIM/RTRIM)
     InsuranceBalance > 0 (TRY_CAST after stripping '$' and ',')
     Date axis : CheckDate (NOT DenialDate)  ->  @DenialFrom / @DenialTo filter CheckDate
     Values    : COUNT(DISTINCT ClaimID), SUM(InsuranceBalance)
                 (balance is exposed as TotalInsuranceBalance for the UI contract)

   TABS
     1. Monthly        period = month of CheckDate; Top 10 PayerName_Raw by Claim Count
                       then balance; Top 3 DenialCode per payer; year totals + grand total.
                       usp_GetNW_DenialMonthly  (same columns as usp_GetAnP_DenialMonthly)
     2. Weekly         Week = Thursday-Wednesday on CheckDate. When PostedWeek is not blank,
                       PostedWeek is the week bucket / label for that claim. The 4 most recent
                       buckets (by max CheckDate in each bucket) are the columns.
                       usp_GetNW_DenialWeekly   (same columns as AnP weekly)
     3. Denial List    DenialCode -> PayerName_Raw, sorted by Claim Count DESC then balance.
                       usp_GetNW_DenialList     (RowType D / I / T, as AnP)
     4. Payor vs Payer usp_GetNW_DenialPlanType     (RowType D / T, by PayerType - AnP contract)
                       usp_GetNW_DenialPayorVsPayer (RowType P payer / C denial / T total)
     5. Facility wise  usp_GetNW_DenialByFacility   (RowType F clinic / D denial / T total)
     6. Denial vs Facility %
                       usp_GetNW_DenialFacilityPct  Filter BilledUnbilled = 'Billed' only
                       (no denial-code filter). Per ClinicName:
                         ClaimsBilled       = distinct ClaimID, BilledStatus = 'Billed'
                         AdjudicatedClaims  = distinct ClaimID, Adjudicated  = 'Adjudicated'
                         DeniedClaims       = distinct ClaimID, DeniedStatus = 'Denied'
                         DeniedPct          = DeniedClaims * 1.0 / NULLIF(AdjudicatedClaims, 0)
                       Sorted by ClaimsBilled DESC.

   Thu-Wed week math: 1900-01-04 is a Thursday.
     WeekStart = DATEADD(DAY, -(DATEDIFF(DAY,'19000104',CheckDate) % 7), CheckDate)
     WeekEnd   = DATEADD(DAY, 6, WeekStart)

   Objects
     vw_NW_DenialClaims / fn_NW_DenialClaims / fn_NW_DenialSummaryClaims
     fn_NW_PayerKey, fn_NW_DenialRowLabel
     usp_NW_DenialAnalysis_Compute (@Grain M/W), usp_NW_DenialSummaryTiles_Compute
     usp_GetNW_DenialMonthly / Weekly / List / PlanType / PayorVsPayer / ByFacility /
                    FacilityPct / SummaryTiles / FilterOptions
     usp_RefreshNW_DenialMonthly (also tiles) / Weekly / List / PlanType / PayorVsPayer /
                    ByFacility / FacilityPct / SummaryTiles
     NW_DenialMonthlySummary, NW_DenialWeeklySummary, NW_DenialSummaryTiles, NW_DenialList,
     NW_DenialPlanType, NW_DenialPayorVsPayer, NW_DenialByFacility, NW_DenialFacilityPct

   Filter parameters (read SPs): @PayerNames / @PayerTypes / @DenialCodes ('|' lists),
   @DenialFrom / @DenialTo (CheckDate range). With no filter the read SPs return the
   snapshot table filled by the refresh SPs; any filter (or @ForceLive = 1) aggregates live.

   Run 40_NW_ClaimLevelData_BilledUnbilled.sql first so BilledUnbilled is populated.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'45_NW_DenialSummary.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------------
   Source columns used by this package (no-ops when they already exist)
   --------------------------------------------------------------------------- */
IF COL_LENGTH(N'dbo.ClaimLevelData', N'PostedWeek')     IS NULL ALTER TABLE dbo.ClaimLevelData ADD PostedWeek     NVARCHAR(500) NULL;
IF COL_LENGTH(N'dbo.ClaimLevelData', N'BilledStatus')   IS NULL ALTER TABLE dbo.ClaimLevelData ADD BilledStatus   NVARCHAR(MAX) NULL;
IF COL_LENGTH(N'dbo.ClaimLevelData', N'Adjudicated')    IS NULL ALTER TABLE dbo.ClaimLevelData ADD Adjudicated    NVARCHAR(500) NULL;
IF COL_LENGTH(N'dbo.ClaimLevelData', N'DeniedStatus')   IS NULL ALTER TABLE dbo.ClaimLevelData ADD DeniedStatus   NVARCHAR(500) NULL;
IF COL_LENGTH(N'dbo.ClaimLevelData', N'BilledUnbilled') IS NULL ALTER TABLE dbo.ClaimLevelData ADD BilledUnbilled NVARCHAR(250) NULL;
GO

/* ---------------------------------------------------------------------------
   Base view / filter function
   One typed row per ClaimLevelData row. Tabs 1 - 5 add: DenialCode IS NOT NULL
   AND TotalInsuranceBalance > 0.
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_NW_DenialClaims
AS
SELECT
    CAST(NULLIF(LTRIM(RTRIM(c.ClaimID)), '') AS NVARCHAR(200))                          AS ClaimID,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), ''), 'Unknown') AS NVARCHAR(500)) AS PayerName,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.PayerType)), ''), 'Unknown') AS NVARCHAR(200))     AS PayerType,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.ClinicName)), ''), '(Blank)') AS NVARCHAR(500))    AS ClinicName,
    CAST(NULLIF(LTRIM(RTRIM(c.DenialCode)), '') AS NVARCHAR(400))                       AS DenialCode,
    TRY_CAST(NULLIF(LTRIM(RTRIM(c.CheckDate)), '') AS DATE)                             AS CheckDate,
    CAST(NULLIF(LTRIM(RTRIM(c.PostedWeek)), '') AS NVARCHAR(500))                       AS PostedWeek,
    ISNULL(TRY_CAST(REPLACE(REPLACE(LTRIM(RTRIM(c.InsuranceBalance)), '$', ''), ',', '')
                    AS DECIMAL(18,2)), 0)                                               AS TotalInsuranceBalance
FROM dbo.ClaimLevelData c;
GO

CREATE OR ALTER FUNCTION dbo.fn_NW_DenialClaims
(
    @PayerNames  NVARCHAR(MAX),
    @PayerTypes  NVARCHAR(MAX),
    @DenialCodes NVARCHAR(MAX),
    @DenialFrom  DATE,
    @DenialTo    DATE
)
RETURNS TABLE
AS
RETURN
    SELECT d.*
    FROM dbo.vw_NW_DenialClaims d
    WHERE d.ClaimID IS NOT NULL
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR d.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
           OR d.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
           OR ISNULL(d.DenialCode, N'(Blank)') IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DenialCodes, N'|')))
      AND (@DenialFrom IS NULL OR d.CheckDate >= @DenialFrom)
      AND (@DenialTo   IS NULL OR d.CheckDate <= @DenialTo);
GO

/* ---------------------------------------------------------------------------
   Monthly / Weekly / tiles claim rows: one row per claim that passes the common
   denial filter (DenialCode not blank, InsuranceBalance > 0). CheckDate and
   PostedWeek drive the period axes.
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_DenialSummaryClaims()
RETURNS TABLE
AS
RETURN
    SELECT d.ClaimID                 AS ClaimKey,
           d.PayerName,
           d.PayerType,
           d.ClinicName,
           d.DenialCode,
           d.CheckDate,
           d.PostedWeek,
           d.TotalInsuranceBalance   AS Bal
    FROM   dbo.vw_NW_DenialClaims d
    WHERE  d.ClaimID IS NOT NULL
      AND  d.DenialCode IS NOT NULL
      AND  d.TotalInsuranceBalance > 0;
GO

/* Payer grouping key: letters and digits only, upper case
   ("UNITED-HEALTHCARE" = "United Healthcare"). */
CREATE OR ALTER FUNCTION dbo.fn_NW_PayerKey (@Name NVARCHAR(500))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @r NVARCHAR(500) = N'', @i INT = 1, @n INT = LEN(@Name), @c NCHAR(1);
    WHILE @i <= @n
    BEGIN
        SET @c = SUBSTRING(@Name, @i, 1);
        IF @c LIKE N'[0-9A-Za-z]' SET @r += UPPER(@c);
        SET @i += 1;
    END;
    RETURN @r;
END
GO

/* Denial row label "code - description". */
CREATE OR ALTER FUNCTION dbo.fn_NW_DenialRowLabel (@Code NVARCHAR(400), @Description NVARCHAR(4000))
RETURNS NVARCHAR(4000)
AS
BEGIN
    SET @Code = LTRIM(RTRIM(ISNULL(@Code, N'')));
    SET @Description = LTRIM(RTRIM(ISNULL(@Description, N'')));

    IF @Code = N'' RETURN CASE WHEN @Description = N'' THEN N'(no denial code)' ELSE @Description END;
    IF @Description = N'' RETURN @Code;
    IF LEFT(@Description, LEN(@Code)) = @Code RETURN @Description;

    IF @Code LIKE N'%[;,]%'
    BEGIN
        DECLARE @first NVARCHAR(400) = LTRIM(RTRIM(LEFT(@Code, PATINDEX(N'%[;,]%', @Code) - 1)));
        IF LEFT(@Description, LEN(@first) + 3) = @first + N' - '
           AND NOT EXISTS (SELECT 1
                           FROM   STRING_SPLIT(REPLACE(@Code, N';', N','), N',') s
                           WHERE  LTRIM(RTRIM(s.value)) <> N''
                             AND  CHARINDEX(LTRIM(RTRIM(s.value)) + N' - ', @Description) = 0)
            RETURN @Description;
    END;

    RETURN @Code + N' - ' + @Description;
END
GO

/* ---------------------------------------------------------------------------
   Aggregate tables (snapshots, refilled by the refresh SPs below)
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.NW_DenialMonthlySummary', N'U') IS NULL
CREATE TABLE dbo.NW_DenialMonthlySummary
(
    SummaryId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowType               CHAR(1)        NOT NULL,
    PayerName             NVARCHAR(500)  NOT NULL,
    DenialCode            NVARCHAR(400)  NOT NULL,
    PayerRank             INT            NOT NULL,
    CodeRank              INT            NOT NULL,
    PeriodType            CHAR(1)        NOT NULL,
    PeriodKey             VARCHAR(10)    NOT NULL,
    PeriodYear            INT            NULL,
    PeriodStart           DATE           NULL,
    PeriodEnd             DATE           NULL,
    PeriodLabel           NVARCHAR(40)   NOT NULL,
    ClaimCount            INT            NOT NULL,
    TotalInsuranceBalance DECIMAL(18,2)  NOT NULL,
    SortOrder             INT            NOT NULL,
    PeriodOrder           INT            NOT NULL,
    IndexLabel            VARCHAR(10)    NOT NULL,
    RowLabel              NVARCHAR(4000) NOT NULL,
    CoveragePct           DECIMAL(9,2)   NOT NULL,
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.NW_DenialWeeklySummary', N'U') IS NULL
CREATE TABLE dbo.NW_DenialWeeklySummary
(
    SummaryId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowType               CHAR(1)        NOT NULL,
    PayerName             NVARCHAR(500)  NOT NULL,
    DenialCode            NVARCHAR(400)  NOT NULL,
    PayerRank             INT            NOT NULL,
    CodeRank              INT            NOT NULL,
    PeriodType            CHAR(1)        NOT NULL,
    PeriodKey             VARCHAR(10)    NOT NULL,
    PeriodYear            INT            NULL,
    PeriodStart           DATE           NULL,
    PeriodEnd             DATE           NULL,
    PeriodLabel           NVARCHAR(40)   NOT NULL,
    ClaimCount            INT            NOT NULL,
    TotalInsuranceBalance DECIMAL(18,2)  NOT NULL,
    SortOrder             INT            NOT NULL,
    PeriodOrder           INT            NOT NULL,
    IndexLabel            VARCHAR(10)    NOT NULL,
    RowLabel              NVARCHAR(4000) NOT NULL,
    CoveragePct           DECIMAL(9,2)   NOT NULL,
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.NW_DenialSummaryTiles', N'U') IS NULL
CREATE TABLE dbo.NW_DenialSummaryTiles
(
    DeniedClaims          INT            NOT NULL,
    InsuranceBalance      DECIMAL(18,2)  NOT NULL,
    DenialCodes           INT            NOT NULL,   -- distinct denial codes
    Insurances            INT            NOT NULL,   -- distinct PayerName_Raw
    UndatedGroups         INT            NOT NULL,   -- insurance / code groups with no CheckDate
    LoadedThrough         DATE           NULL,       -- end of the newest WeekFolder (else max CheckDate)
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.NW_DenialList', N'U') IS NULL
CREATE TABLE dbo.NW_DenialList
(
    SummaryId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowType               CHAR(1)        NOT NULL,   -- D denial code, I insurance, T total
    DenialCode            NVARCHAR(400)  NOT NULL,
    PayerName             NVARCHAR(500)  NOT NULL,
    CodeRank              INT            NOT NULL,
    PayerRank             INT            NOT NULL,
    ClaimCount            INT            NOT NULL,
    TotalInsuranceBalance DECIMAL(18,2)  NOT NULL,
    SortOrder             INT            NOT NULL,
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.NW_DenialPlanType', N'U') IS NULL
CREATE TABLE dbo.NW_DenialPlanType
(
    SummaryId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowType               CHAR(1)        NOT NULL,   -- D plan type, T total
    PayerType             NVARCHAR(200)  NOT NULL,
    ClaimCount            INT            NOT NULL,
    TotalInsuranceBalance DECIMAL(18,2)  NOT NULL,
    SortOrder             INT            NOT NULL,
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.NW_DenialPayorVsPayer', N'U') IS NULL
CREATE TABLE dbo.NW_DenialPayorVsPayer
(
    SummaryId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowType               CHAR(1)        NOT NULL,   -- P payer, C denial under payer, T total
    PayerName             NVARCHAR(500)  NOT NULL,
    DenialCode            NVARCHAR(400)  NOT NULL,
    PayerType             NVARCHAR(200)  NOT NULL,
    ClaimCount            INT            NOT NULL,
    TotalInsuranceBalance DECIMAL(18,2)  NOT NULL,
    SortOrder             INT            NOT NULL,
    PayerRank             INT            NOT NULL,
    CodeRank              INT            NOT NULL,
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.NW_DenialByFacility', N'U') IS NULL
CREATE TABLE dbo.NW_DenialByFacility
(
    SummaryId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowType               CHAR(1)        NOT NULL,   -- F clinic, D denial under clinic, T total
    ClinicName            NVARCHAR(500)  NOT NULL,
    DenialCode            NVARCHAR(400)  NOT NULL,
    ClaimCount            INT            NOT NULL,
    TotalInsuranceBalance DECIMAL(18,2)  NOT NULL,
    SortOrder             INT            NOT NULL,
    ClinicRank            INT            NOT NULL,
    CodeRank              INT            NOT NULL,
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.NW_DenialFacilityPct', N'U') IS NULL
CREATE TABLE dbo.NW_DenialFacilityPct
(
    SummaryId             INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowType               CHAR(1)        NOT NULL,   -- F clinic, T total
    ClinicName            NVARCHAR(500)  NOT NULL,
    ClaimsBilled          INT            NOT NULL,
    AdjudicatedClaims     INT            NOT NULL,
    DeniedClaims          INT            NOT NULL,
    DeniedPct             DECIMAL(18,6)  NULL,       -- DeniedClaims / NULLIF(AdjudicatedClaims, 0)
    SortOrder             INT            NOT NULL,
    ClinicRank            INT            NOT NULL,
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------------
   Monthly / Weekly engine
   @Grain 'M' = every CheckDate month, with a total per year
          'W' = the 4 most recent week buckets:
                 - PostedWeek (when not blank) is the bucket / label for that claim
                 - otherwise the Thursday-Wednesday week of CheckDate
                 Recency = max CheckDate in the bucket.
   Rows, ranks, labels, cells, totals and both orders are produced here; the page
   and the Excel export lay the rows out as returned.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_NW_DenialAnalysis_Compute
    @Grain       CHAR(1),
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Grain NOT IN ('M', 'W')
    BEGIN
        RAISERROR('usp_NW_DenialAnalysis_Compute: @Grain must be M or W.', 16, 1);
        RETURN;
    END;

    DECLARE @TopPayers INT = 10, @TopCodes INT = 3, @Weeks INT = 4;

    SELECT d.ClaimKey, d.PayerName, d.DenialCode, d.CheckDate, d.PostedWeek, d.Bal
    INTO   #c
    FROM   dbo.fn_NW_DenialSummaryClaims() d
    WHERE  (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
            OR d.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
            OR d.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
            OR d.DenialCode IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DenialCodes, N'|')))
      AND  (@DenialFrom IS NULL OR d.CheckDate >= @DenialFrom)
      AND  (@DenialTo   IS NULL OR d.CheckDate <= @DenialTo);

    /* Bucket of every claim */
    SELECT c.ClaimKey, c.PayerName, c.DenialCode, c.Bal, c.CheckDate, c.PostedWeek, ws.WeekStart,
           CAST(CASE WHEN @Grain = 'M'
                     THEN CASE WHEN c.CheckDate IS NOT NULL
                               THEN CONVERT(CHAR(10), DATEFROMPARTS(YEAR(c.CheckDate), MONTH(c.CheckDate), 1), 120) END
                     WHEN c.PostedWeek IS NOT NULL
                     THEN N'P|' + UPPER(c.PostedWeek)
                     WHEN c.CheckDate IS NOT NULL
                     THEN N'C|' + CONVERT(CHAR(10), ws.WeekStart, 120)
                END AS NVARCHAR(520)) AS BucketKey
    INTO   #cb
    FROM   #c c
    CROSS  APPLY (SELECT CASE WHEN c.CheckDate IS NOT NULL
                              THEN DATEADD(DAY, -(((DATEDIFF(DAY, '19000104', c.CheckDate) % 7) + 7) % 7), c.CheckDate)
                         END AS WeekStart) ws;

    DELETE FROM #cb WHERE BucketKey IS NULL;

    /* Period columns */
    CREATE TABLE #per
    (
        BucketKey   NVARCHAR(520) NOT NULL,
        PeriodType  CHAR(1)       NOT NULL,
        PeriodKey   VARCHAR(10)   NOT NULL,
        PeriodLabel NVARCHAR(40)  NOT NULL,
        PeriodStart DATE          NULL,
        PeriodEnd   DATE          NULL,
        PeriodYear  INT           NULL,
        SortKey     INT           NOT NULL
    );

    IF @Grain = 'M'
    BEGIN
        INSERT INTO #per (BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear, SortKey)
        SELECT CONVERT(NVARCHAR(520), CONVERT(CHAR(10), m.MonthStart, 120)),
               'M',
               CONVERT(VARCHAR(10), m.MonthStart, 120),
               CAST(FORMAT(m.MonthStart, 'MMM', 'en-US') AS NVARCHAR(40)),
               m.MonthStart,
               EOMONTH(m.MonthStart),
               YEAR(m.MonthStart),
               DATEDIFF(DAY, '19000101', m.MonthStart)
        FROM  (SELECT DISTINCT DATEFROMPARTS(YEAR(CheckDate), MONTH(CheckDate), 1) AS MonthStart
               FROM   #cb
               WHERE  CheckDate IS NOT NULL) m;
    END
    ELSE
    BEGIN
        ;WITH w AS
        (
            SELECT x.BucketKey,
                   MIN(x.PostedWeek) AS PostedWeek,
                   MIN(x.WeekStart)  AS WeekStart,
                   MIN(x.CheckDate)  AS MinCheck,
                   MAX(x.CheckDate)  AS MaxCheck
            FROM   #cb x
            GROUP  BY x.BucketKey
        ),
        p AS
        (
            SELECT w.BucketKey, w.PostedWeek, w.WeekStart, w.MaxCheck,
                   CASE WHEN w.PostedWeek IS NULL THEN w.WeekStart
                        ELSE COALESCE(TRY_CONVERT(DATE, REPLACE(LTRIM(RTRIM(
                                 LEFT(w.PostedWeek, NULLIF(CHARINDEX(N'-', w.PostedWeek), 0) - 1))), N'.', N'/'), 101),
                                 w.MinCheck) END AS ps,
                   CASE WHEN w.PostedWeek IS NULL THEN DATEADD(DAY, 6, w.WeekStart)
                        ELSE COALESCE(TRY_CONVERT(DATE, REPLACE(LTRIM(RTRIM(
                                 SUBSTRING(w.PostedWeek, NULLIF(CHARINDEX(N'-', w.PostedWeek), 0) + 1, 500))), N'.', N'/'), 101),
                                 w.MaxCheck) END AS pe
            FROM   w
        )
        INSERT INTO #per (BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear, SortKey)
        SELECT t.BucketKey, 'W',
               CAST(CASE WHEN t.PostedWeek IS NULL
                         THEN CONVERT(VARCHAR(10), t.WeekStart, 120)
                         ELSE 'pw' + RIGHT(CONVERT(VARCHAR(8), CONVERT(VARBINARY(4), CHECKSUM(UPPER(t.PostedWeek))), 2), 8)
                    END AS VARCHAR(10)),
               CAST(CASE WHEN t.PostedWeek IS NULL
                         THEN FORMAT(t.ps, 'dd MMM', 'en-US') + N' - ' + FORMAT(t.pe, 'dd MMM', 'en-US')
                         ELSE LEFT(t.PostedWeek, 40)
                    END AS NVARCHAR(40)),
               t.ps, t.pe, YEAR(t.ps),
               CAST(ROW_NUMBER() OVER (ORDER BY t.RankDate, t.ps, t.BucketKey) AS INT)
        FROM  (SELECT TOP (@Weeks) p.*, COALESCE(p.MaxCheck, p.pe, p.ps) AS RankDate
               FROM   p
               ORDER  BY COALESCE(p.MaxCheck, p.pe, p.ps) DESC, p.ps DESC, p.BucketKey) t;
    END;

    SELECT CAST(BucketKey AS NVARCHAR(520)) AS BucketKey, PeriodType, PeriodKey, PeriodLabel,
           PeriodStart, PeriodEnd, PeriodYear, SortKey
    INTO   #col0
    FROM   #per
    UNION ALL
    SELECT N'', 'Y', CAST('total-' + CAST(PeriodYear AS VARCHAR(4)) AS VARCHAR(10)),
           CAST(CAST(PeriodYear AS VARCHAR(4)) + ' | Total' AS NVARCHAR(40)),
           MIN(PeriodStart), MAX(PeriodEnd), PeriodYear, 0
    FROM   #per
    WHERE  @Grain = 'M'
    GROUP  BY PeriodYear
    UNION ALL
    SELECT N'', 'A', CAST('' AS VARCHAR(10)), CAST(N'Grand Total' AS NVARCHAR(40)), NULL, NULL, NULL, 0;

    SELECT BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN PeriodType = 'A' THEN 1 ELSE 0 END,
                                       CASE WHEN @Grain = 'M' THEN PeriodYear END,
                                       CASE WHEN PeriodType = 'Y' THEN 1 ELSE 0 END,
                                       SortKey) AS ColOrder
    INTO   #col
    FROM   #col0;

    /* Claims the columns hold; totals, ranks and coverage describe these only */
    SELECT n.PayerName, dbo.fn_NW_PayerKey(n.PayerName) AS PayerKey
    INTO   #pk
    FROM  (SELECT DISTINCT PayerName FROM #cb) n;

    SELECT c.ClaimKey, c.PayerName, k.PayerKey, c.DenialCode, c.Bal, p.BucketKey, p.PeriodYear
    INTO   #b
    FROM   #cb c
    JOIN   #per p ON p.BucketKey = c.BucketKey
    JOIN   #pk k  ON k.PayerName = c.PayerName;

    /* Payers by No. of Claims, then balance */
    SELECT PayerKey,
           ISNULL(MIN(NULLIF(PayerName, N'')), N'(no payer)') AS PayerLabel,
           SUM(Bal) AS Bal,
           ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, SUM(Bal) DESC, PayerKey) AS PayerRank
    INTO   #pr
    FROM   #b
    GROUP  BY PayerKey;

    DECLARE @Coverage DECIMAL(9,2) = ISNULL(
        (SELECT CASE WHEN SUM(Bal) > 0
                     THEN ROUND(SUM(CASE WHEN PayerRank <= @TopPayers THEN Bal ELSE 0 END) * 100.0 / SUM(Bal), 0)
                     ELSE 0 END
         FROM   #pr), 0);

    /* Top 3 denial codes per listed payer, by No. of Claims, then balance */
    SELECT b.PayerKey, b.DenialCode,
           ROW_NUMBER() OVER (PARTITION BY b.PayerKey
                              ORDER BY COUNT(DISTINCT b.ClaimKey) DESC, SUM(b.Bal) DESC, b.DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b b
    JOIN   #pr p ON p.PayerKey = b.PayerKey AND p.PayerRank <= @TopPayers
    GROUP  BY b.PayerKey, b.DenialCode;

    DELETE FROM #cr WHERE CodeRank > @TopCodes;

    /* Rows: payer A..J, its codes numbered down the whole table, Grand Total last */
    SELECT 'P' AS RowType, p.PayerKey, CAST(N'' AS NVARCHAR(400)) AS DenialCode, p.PayerRank, 0 AS CodeRank,
           p.PayerRank * 10 AS RowSeq,
           CAST(CHAR(64 + p.PayerRank) AS VARCHAR(10)) AS IndexLabel,
           CAST(p.PayerLabel AS NVARCHAR(4000)) AS RowLabel,
           p.PayerLabel
    INTO   #r
    FROM   #pr p
    WHERE  p.PayerRank <= @TopPayers
    UNION ALL
    SELECT 'C', c.PayerKey, c.DenialCode, p.PayerRank, c.CodeRank,
           p.PayerRank * 10 + c.CodeRank,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerRank, c.CodeRank) AS VARCHAR(10)),
           dbo.fn_NW_DenialRowLabel(c.DenialCode, NULL),
           p.PayerLabel
    FROM   #cr c
    JOIN   #pr p ON p.PayerKey = c.PayerKey
    UNION ALL
    SELECT 'T', N'', N'', 0, 0, 2147483647, '', N'Grand Total', N'Grand Total';

    /* Cells: period, year subtotal (Monthly) and grand total of every row */
    ;WITH m AS
    (
        SELECT r.RowSeq, b.ClaimKey, b.Bal, b.BucketKey, b.PeriodYear
        FROM   #b b
        JOIN   #r r ON r.RowType IN ('P', 'C') AND r.PayerKey = b.PayerKey
                   AND (r.RowType = 'P' OR r.DenialCode = b.DenialCode)
        UNION ALL
        SELECT 2147483647, b.ClaimKey, b.Bal, b.BucketKey, b.PeriodYear
        FROM   #b b
    )
    SELECT RowSeq,
           CAST(CASE WHEN GROUPING(BucketKey) = 0 THEN @Grain
                     WHEN GROUPING(PeriodYear) = 0 THEN 'Y'
                     ELSE 'A' END AS CHAR(1)) AS PeriodType,
           BucketKey, PeriodYear,
           COUNT(DISTINCT ClaimKey) AS ClaimCount,
           SUM(Bal)                 AS Bal
    INTO   #cell
    FROM   m
    GROUP  BY GROUPING SETS ((RowSeq, PeriodYear, BucketKey), (RowSeq, PeriodYear), (RowSeq));

    ;WITH grid AS
    (
        SELECT r.RowType, r.DenialCode, r.PayerRank, r.CodeRank, r.RowSeq, r.IndexLabel, r.RowLabel, r.PayerLabel,
               k.PeriodType, k.PeriodKey, k.PeriodLabel, k.ColOrder,
               k.PeriodStart AS ColStart, k.PeriodEnd AS ColEnd, k.PeriodYear AS ColYear,
               x.ClaimCount, x.Bal
        FROM   #r r
        CROSS  JOIN #col k
        LEFT   JOIN #cell x ON x.RowSeq = r.RowSeq
                           AND x.PeriodType = k.PeriodType
                           AND (   k.PeriodType = 'A'
                                OR (k.PeriodType = 'Y' AND x.PeriodYear = k.PeriodYear)
                                OR (k.PeriodType IN ('M', 'W') AND x.BucketKey = k.BucketKey))
        WHERE  r.RowType = 'T' OR x.RowSeq IS NOT NULL
    )
    SELECT CAST(RowType AS CHAR(1))                  AS RowType,
           CAST(PayerLabel AS NVARCHAR(500))         AS PayerName,
           CAST(DenialCode AS NVARCHAR(400))         AS DenialCode,
           PayerRank, CodeRank,
           PeriodType,
           PeriodKey,
           ColYear  AS PeriodYear,
           ColStart AS PeriodStart,
           ColEnd   AS PeriodEnd,
           PeriodLabel,
           ISNULL(ClaimCount, 0)                 AS ClaimCount,
           CAST(ISNULL(Bal, 0) AS DECIMAL(18,2)) AS TotalInsuranceBalance,
           DENSE_RANK() OVER (ORDER BY RowSeq)   AS SortOrder,
           DENSE_RANK() OVER (ORDER BY ColOrder) AS PeriodOrder,
           IndexLabel,
           RowLabel,
           @Coverage AS CoveragePct
    FROM   grid
    ORDER  BY SortOrder, PeriodOrder;
END
GO

/* ---------------------------------------------------------------------------
   Read SPs - Monthly / Weekly
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialMonthly
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL,
    @ForceLive   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialMonthlySummary)
    BEGIN
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank,
               PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel,
               ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct
        FROM   dbo.NW_DenialMonthlySummary
        ORDER  BY SortOrder, PeriodOrder;
        RETURN;
    END;

    EXEC dbo.usp_NW_DenialAnalysis_Compute
         @Grain = 'M', @PayerNames = @PayerNames, @PayerTypes = @PayerTypes,
         @DenialCodes = @DenialCodes, @DenialFrom = @DenialFrom, @DenialTo = @DenialTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialWeekly
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL,
    @ForceLive   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialWeeklySummary)
    BEGIN
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank,
               PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel,
               ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct
        FROM   dbo.NW_DenialWeeklySummary
        ORDER  BY SortOrder, PeriodOrder;
        RETURN;
    END;

    EXEC dbo.usp_NW_DenialAnalysis_Compute
         @Grain = 'W', @PayerNames = @PayerNames, @PayerTypes = @PayerTypes,
         @DenialCodes = @DenialCodes, @DenialFrom = @DenialFrom, @DenialTo = @DenialTo;
END
GO

/* ---------------------------------------------------------------------------
   Tiles - Denied Claims, Insurance Balance, Denial Codes, Insurances: every claim
   of fn_NW_DenialSummaryClaims, whatever its CheckDate
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_NW_DenialSummaryTiles_Compute
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ClaimKey, PayerName, DenialCode, CheckDate, Bal
    INTO   #c
    FROM   dbo.fn_NW_DenialSummaryClaims();

    DECLARE @WeekFolderEnd DATE =
    (
        SELECT MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
        FROM   dbo.ClaimLevelData
        WHERE  WeekFolder IS NOT NULL
    );

    SELECT COUNT(DISTINCT ClaimKey)                       AS DeniedClaims,
           CAST(ISNULL(SUM(Bal), 0) AS DECIMAL(18,2))     AS InsuranceBalance,
           COUNT(DISTINCT DenialCode)                     AS DenialCodes,
           COUNT(DISTINCT NULLIF(PayerName, N''))         AS Insurances,
           (SELECT COUNT(*)
            FROM  (SELECT DISTINCT PayerName, DenialCode
                   FROM   #c
                   WHERE  CheckDate IS NULL) u)           AS UndatedGroups,
           COALESCE(@WeekFolderEnd, MAX(CheckDate))       AS LoadedThrough,
           GETDATE()                                      AS RefreshedAt
    FROM   #c;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialSummaryTiles
    @ForceLive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0 AND EXISTS (SELECT 1 FROM dbo.NW_DenialSummaryTiles)
    BEGIN
        SELECT TOP (1) DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, RefreshedAt
        FROM   dbo.NW_DenialSummaryTiles
        ORDER  BY RefreshedAt DESC;
        RETURN;
    END;

    EXEC dbo.usp_NW_DenialSummaryTiles_Compute;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Denial List
   RowType 'D' denial code, 'I' payer under DenialCode, 'T' grand total.
   Sorted by Claim Count DESC, then balance.
   @DenialCodeSearch : optional whole-code search (see AnP): every searched code must
                       equal one of the row's codes (split on commas / spaces).
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialList
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PayerTypes       NVARCHAR(MAX) = NULL,
    @DenialCodes      NVARCHAR(MAX) = NULL,
    @DenialFrom       DATE          = NULL,
    @DenialTo         DATE          = NULL,
    @ForceLive        BIT           = 0,
    @DenialCodeSearch NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @DenialCodeSearch = NULLIF(LTRIM(RTRIM(@DenialCodeSearch)), N'');

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND @DenialCodeSearch IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialList)
    BEGIN
        SELECT RowType, DenialCode, PayerName, CodeRank, PayerRank,
               ClaimCount, TotalInsuranceBalance, SortOrder
        FROM   dbo.NW_DenialList
        ORDER  BY SortOrder;
        RETURN;
    END;

    SELECT d.ClaimID,
           d.DenialCode,
           d.PayerName,
           d.TotalInsuranceBalance AS Bal
    INTO   #b
    FROM   dbo.fn_NW_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
    WHERE  d.TotalInsuranceBalance > 0
      AND  d.DenialCode IS NOT NULL
      AND  (@DenialCodeSearch IS NULL
            OR NOT EXISTS (SELECT 1
                           FROM   STRING_SPLIT(REPLACE(@DenialCodeSearch, N',', N' '), N' ') s
                           WHERE  s.value <> N''
                             AND  NOT EXISTS (SELECT 1
                                              FROM   STRING_SPLIT(REPLACE(d.DenialCode, N',', N' '), N' ') t
                                              WHERE  t.value = s.value)));

    SELECT DenialCode,
           ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(Bal) DESC, DenialCode) AS CodeRank
    INTO   #dr
    FROM   #b
    GROUP  BY DenialCode;

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(b.DenialCode) = 1 THEN 'T'
                    WHEN GROUPING(b.PayerName)  = 1 THEN 'D'
                    ELSE 'I' END                               AS RowType,
               ISNULL(b.DenialCode, N'Grand Total')            AS DenialCode,
               ISNULL(b.PayerName, N'')                        AS PayerName,
               COUNT(DISTINCT b.ClaimID)                       AS ClaimCount,
               CAST(ISNULL(SUM(b.Bal), 0) AS DECIMAL(18,2))    AS TotalInsuranceBalance
        FROM   #b b
        GROUP  BY GROUPING SETS ((b.DenialCode, b.PayerName), (b.DenialCode), ())
    ),
    ranked AS
    (
        SELECT g.*,
               ISNULL(dr.CodeRank, 0) AS CodeRank,
               CASE WHEN g.RowType = 'I'
                    THEN ROW_NUMBER() OVER (PARTITION BY g.RowType, g.DenialCode
                                            ORDER BY g.ClaimCount DESC, g.TotalInsuranceBalance DESC, g.PayerName)
                    ELSE 0 END        AS PayerRank
        FROM   g
        LEFT   JOIN #dr dr ON dr.DenialCode = g.DenialCode AND g.RowType <> 'T'
    )
    SELECT RowType, DenialCode, PayerName, CodeRank, PayerRank,
           ClaimCount, TotalInsuranceBalance,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                       CodeRank,
                                       CASE WHEN RowType = 'D' THEN 0 ELSE 1 END,
                                       PayerRank) AS SortOrder
    FROM   ranked
    ORDER  BY SortOrder;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Denial List - Plan Type (AnP contract)
   RowType 'D' one row per PayerType, 'T' grand total. Sorted by Claim Count.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialPlanType
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL,
    @ForceLive   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialPlanType)
    BEGIN
        SELECT RowType, PayerType, ClaimCount, TotalInsuranceBalance, SortOrder
        FROM   dbo.NW_DenialPlanType
        ORDER  BY SortOrder;
        RETURN;
    END;

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(d.PayerType) = 1 THEN 'T' ELSE 'D' END AS RowType,
               ISNULL(d.PayerType, N'Grand Total')                       AS PayerType,
               COUNT(DISTINCT d.ClaimID)                                 AS ClaimCount,
               CAST(ISNULL(SUM(d.TotalInsuranceBalance), 0) AS DECIMAL(18,2)) AS TotalInsuranceBalance
        FROM   dbo.fn_NW_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
        WHERE  d.TotalInsuranceBalance > 0
          AND  d.DenialCode IS NOT NULL
        GROUP  BY GROUPING SETS ((d.PayerType), ())
    )
    SELECT RowType, PayerType, ClaimCount, TotalInsuranceBalance,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                       ClaimCount DESC, TotalInsuranceBalance DESC, PayerType) AS SortOrder
    FROM   g
    ORDER  BY SortOrder;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Payor vs Payer
   RowType 'P' payer (PayerName_Raw), 'C' denial code under the payer, 'T' grand total.
   PayerType = the payer's most frequent PayerType. Sorted by Claim Count, then balance.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialPayorVsPayer
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL,
    @ForceLive   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialPayorVsPayer)
    BEGIN
        SELECT RowType, PayerName, DenialCode, PayerType, ClaimCount, TotalInsuranceBalance,
               SortOrder, PayerRank, CodeRank
        FROM   dbo.NW_DenialPayorVsPayer
        ORDER  BY SortOrder;
        RETURN;
    END;

    SELECT d.ClaimID, d.PayerName, d.PayerType, d.DenialCode, d.TotalInsuranceBalance AS Bal
    INTO   #b
    FROM   dbo.fn_NW_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
    WHERE  d.TotalInsuranceBalance > 0
      AND  d.DenialCode IS NOT NULL;

    ;WITH t AS
    (
        SELECT PayerName, PayerType,
               ROW_NUMBER() OVER (PARTITION BY PayerName
                                  ORDER BY COUNT(DISTINCT ClaimID) DESC, PayerType) AS rn
        FROM   #b
        GROUP  BY PayerName, PayerType
    )
    SELECT PayerName, PayerType
    INTO   #pt
    FROM   t
    WHERE  rn = 1;

    SELECT PayerName,
           ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(Bal) DESC, PayerName) AS PayerRank
    INTO   #pr
    FROM   #b
    GROUP  BY PayerName;

    SELECT PayerName, DenialCode,
           ROW_NUMBER() OVER (PARTITION BY PayerName
                              ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(Bal) DESC, DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b
    GROUP  BY PayerName, DenialCode;

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(b.PayerName)  = 1 THEN 'T'
                    WHEN GROUPING(b.DenialCode) = 1 THEN 'P'
                    ELSE 'C' END                               AS RowType,
               ISNULL(b.PayerName,  N'Grand Total')            AS PayerName,
               ISNULL(b.DenialCode, N'')                       AS DenialCode,
               COUNT(DISTINCT b.ClaimID)                       AS ClaimCount,
               CAST(ISNULL(SUM(b.Bal), 0) AS DECIMAL(18,2))    AS TotalInsuranceBalance
        FROM   #b b
        GROUP  BY GROUPING SETS ((b.PayerName, b.DenialCode), (b.PayerName), ())
    ),
    ranked AS
    (
        SELECT g.RowType, g.PayerName, g.DenialCode,
               CAST(ISNULL(pt.PayerType, N'') AS NVARCHAR(200)) AS PayerType,
               g.ClaimCount, g.TotalInsuranceBalance,
               ISNULL(pr.PayerRank, 0) AS PayerRank,
               ISNULL(cr.CodeRank, 0)  AS CodeRank
        FROM   g
        LEFT   JOIN #pt pt ON pt.PayerName = g.PayerName AND g.RowType <> 'T'
        LEFT   JOIN #pr pr ON pr.PayerName = g.PayerName AND g.RowType <> 'T'
        LEFT   JOIN #cr cr ON cr.PayerName = g.PayerName AND cr.DenialCode = g.DenialCode AND g.RowType = 'C'
    )
    SELECT CAST(RowType AS CHAR(1)) AS RowType, PayerName, DenialCode, PayerType, ClaimCount, TotalInsuranceBalance,
           CAST(ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                            PayerRank,
                                            CASE WHEN RowType = 'P' THEN 0 ELSE 1 END,
                                            CodeRank) AS INT) AS SortOrder,
           PayerRank, CodeRank
    FROM   ranked
    ORDER  BY SortOrder;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Facility wise
   RowType 'F' clinic (ClinicName), 'D' denial code under the clinic, 'T' grand total.
   Sorted by Claim Count, then balance.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialByFacility
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL,
    @ForceLive   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'')  IS NULL
       AND NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialByFacility)
    BEGIN
        SELECT RowType, ClinicName, DenialCode, ClaimCount, TotalInsuranceBalance,
               SortOrder, ClinicRank, CodeRank
        FROM   dbo.NW_DenialByFacility
        ORDER  BY SortOrder;
        RETURN;
    END;

    SELECT d.ClaimID, d.ClinicName, d.DenialCode, d.TotalInsuranceBalance AS Bal
    INTO   #b
    FROM   dbo.fn_NW_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
    WHERE  d.TotalInsuranceBalance > 0
      AND  d.DenialCode IS NOT NULL;

    SELECT ClinicName,
           ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(Bal) DESC, ClinicName) AS ClinicRank
    INTO   #fr
    FROM   #b
    GROUP  BY ClinicName;

    SELECT ClinicName, DenialCode,
           ROW_NUMBER() OVER (PARTITION BY ClinicName
                              ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(Bal) DESC, DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b
    GROUP  BY ClinicName, DenialCode;

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(b.ClinicName) = 1 THEN 'T'
                    WHEN GROUPING(b.DenialCode) = 1 THEN 'F'
                    ELSE 'D' END                               AS RowType,
               ISNULL(b.ClinicName, N'Grand Total')            AS ClinicName,
               ISNULL(b.DenialCode, N'')                       AS DenialCode,
               COUNT(DISTINCT b.ClaimID)                       AS ClaimCount,
               CAST(ISNULL(SUM(b.Bal), 0) AS DECIMAL(18,2))    AS TotalInsuranceBalance
        FROM   #b b
        GROUP  BY GROUPING SETS ((b.ClinicName, b.DenialCode), (b.ClinicName), ())
    ),
    ranked AS
    (
        SELECT g.RowType, g.ClinicName, g.DenialCode, g.ClaimCount, g.TotalInsuranceBalance,
               ISNULL(fr.ClinicRank, 0) AS ClinicRank,
               ISNULL(cr.CodeRank, 0)   AS CodeRank
        FROM   g
        LEFT   JOIN #fr fr ON fr.ClinicName = g.ClinicName AND g.RowType <> 'T'
        LEFT   JOIN #cr cr ON cr.ClinicName = g.ClinicName AND cr.DenialCode = g.DenialCode AND g.RowType = 'D'
    )
    SELECT CAST(RowType AS CHAR(1)) AS RowType, ClinicName, DenialCode, ClaimCount, TotalInsuranceBalance,
           CAST(ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                            ClinicRank,
                                            CASE WHEN RowType = 'F' THEN 0 ELSE 1 END,
                                            CodeRank) AS INT) AS SortOrder,
           ClinicRank, CodeRank
    FROM   ranked
    ORDER  BY SortOrder;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Denial vs Facility %
   Filter : BilledUnbilled = 'Billed' only (no denial-code filter).
   RowType 'F' clinic, 'T' grand total. Sorted by ClaimsBilled DESC.
   @PayerNames / @PayerTypes / @DenialFrom / @DenialTo (CheckDate) are optional;
   @DenialCodes is accepted for contract parity and ignored.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialFacilityPct
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL,
    @ForceLive   BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
       AND COALESCE(@DenialFrom, @DenialTo) IS NULL
       AND EXISTS (SELECT 1 FROM dbo.NW_DenialFacilityPct)
    BEGIN
        SELECT RowType, ClinicName, ClaimsBilled, AdjudicatedClaims, DeniedClaims, DeniedPct,
               SortOrder, ClinicRank
        FROM   dbo.NW_DenialFacilityPct
        ORDER  BY SortOrder;
        RETURN;
    END;

    SELECT n.ClaimKey,
           n.ClinicName,
           CASE WHEN LTRIM(RTRIM(ISNULL(c.BilledStatus, N'')))  = N'Billed'       THEN 1 ELSE 0 END AS IsBilled,
           CASE WHEN LTRIM(RTRIM(ISNULL(c.Adjudicated, N'')))   = N'Adjudicated'  THEN 1 ELSE 0 END AS IsAdjudicated,
           CASE WHEN LTRIM(RTRIM(ISNULL(c.DeniedStatus, N'')))  = N'Denied'       THEN 1 ELSE 0 END AS IsDenied
    INTO   #f
    FROM   dbo.ClaimLevelData c
    CROSS  APPLY (SELECT NULLIF(LTRIM(RTRIM(c.ClaimID)), N'')                                        AS ClaimKey,
                         ISNULL(NULLIF(LTRIM(RTRIM(c.ClinicName)), N''), N'(Blank)')                 AS ClinicName,
                         ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown')              AS PayerName,
                         ISNULL(NULLIF(LTRIM(RTRIM(c.PayerType)), N''), N'Unknown')                  AS PayerType,
                         TRY_CAST(NULLIF(LTRIM(RTRIM(c.CheckDate)), N'') AS DATE)                    AS CheckDt) n
    WHERE  LTRIM(RTRIM(ISNULL(c.BilledUnbilled, N''))) = N'Billed'
      AND  n.ClaimKey IS NOT NULL
      AND  (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
            OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
            OR n.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND  (@DenialFrom IS NULL OR n.CheckDt >= @DenialFrom)
      AND  (@DenialTo   IS NULL OR n.CheckDt <= @DenialTo);

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(ClinicName) = 1 THEN 'T' ELSE 'F' END AS RowType,
               ISNULL(ClinicName, N'Grand Total')                      AS ClinicName,
               COUNT(DISTINCT CASE WHEN IsBilled      = 1 THEN ClaimKey END) AS ClaimsBilled,
               COUNT(DISTINCT CASE WHEN IsAdjudicated = 1 THEN ClaimKey END) AS AdjudicatedClaims,
               COUNT(DISTINCT CASE WHEN IsDenied      = 1 THEN ClaimKey END) AS DeniedClaims
        FROM   #f
        GROUP  BY GROUPING SETS ((ClinicName), ())
    ),
    ranked AS
    (
        SELECT g.RowType, g.ClinicName, g.ClaimsBilled, g.AdjudicatedClaims, g.DeniedClaims,
               CAST(g.DeniedClaims * 1.0 / NULLIF(g.AdjudicatedClaims, 0) AS DECIMAL(18,6)) AS DeniedPct,
               CASE WHEN g.RowType = 'F'
                    THEN ROW_NUMBER() OVER (PARTITION BY g.RowType ORDER BY g.ClaimsBilled DESC, g.ClinicName)
                    ELSE 0 END AS ClinicRank
        FROM   g
    )
    SELECT CAST(RowType AS CHAR(1)) AS RowType, ClinicName, ClaimsBilled, AdjudicatedClaims, DeniedClaims, DeniedPct,
           CAST(ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                            ClaimsBilled DESC, ClinicName) AS INT) AS SortOrder,
           ClinicRank
    FROM   ranked
    ORDER  BY SortOrder;
END
GO

/* ---------------------------------------------------------------------------
   Filter options
   Result sets: 1 payer names, 2 payer types, 3 denial codes,
                4 CheckDate range + last refresh time
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_DenialFilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT PayerName AS Value
    FROM   dbo.fn_NW_DenialSummaryClaims()
    ORDER  BY Value;

    SELECT DISTINCT PayerType AS Value
    FROM   dbo.fn_NW_DenialSummaryClaims()
    ORDER  BY Value;

    SELECT DISTINCT DenialCode AS Value
    FROM   dbo.fn_NW_DenialSummaryClaims()
    ORDER  BY Value;

    SELECT MIN(CheckDate) AS MinDenialDate,
           MAX(CheckDate) AS MaxDenialDate,
           (SELECT MAX(RefreshedAt) FROM dbo.NW_DenialMonthlySummary) AS RefreshedAt
    FROM   dbo.fn_NW_DenialSummaryClaims();
END
GO

/* ---------------------------------------------------------------------------
   Refresh SPs (run by ClaimLineCSVDataCapture when a new claim file lands)
   usp_RefreshNW_DenialMonthly also refreshes the tiles.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_DenialSummaryTiles
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #t
    (
        DeniedClaims INT, InsuranceBalance DECIMAL(18,2), DenialCodes INT, Insurances INT,
        UndatedGroups INT, LoadedThrough DATE, RefreshedAt DATETIME
    );

    INSERT INTO #t
    EXEC dbo.usp_NW_DenialSummaryTiles_Compute;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_DenialSummaryTiles;
        INSERT INTO dbo.NW_DenialSummaryTiles
              (DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, RefreshedAt)
        SELECT DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, GETDATE()
        FROM   #t;
    COMMIT;

    PRINT 'usp_RefreshNW_DenialSummaryTiles completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_DenialMonthly
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), PayerName NVARCHAR(500), DenialCode NVARCHAR(400), PayerRank INT, CodeRank INT,
        PeriodType CHAR(1), PeriodKey VARCHAR(10), PeriodYear INT, PeriodStart DATE, PeriodEnd DATE,
        PeriodLabel NVARCHAR(40), ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2),
        SortOrder INT, PeriodOrder INT, IndexLabel VARCHAR(10), RowLabel NVARCHAR(4000), CoveragePct DECIMAL(9,2)
    );

    INSERT INTO #r
    EXEC dbo.usp_NW_DenialAnalysis_Compute @Grain = 'M';

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_DenialMonthlySummary;
        INSERT INTO dbo.NW_DenialMonthlySummary
              (RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshNW_DenialMonthly completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';

    EXEC dbo.usp_RefreshNW_DenialSummaryTiles;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_DenialWeekly
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), PayerName NVARCHAR(500), DenialCode NVARCHAR(400), PayerRank INT, CodeRank INT,
        PeriodType CHAR(1), PeriodKey VARCHAR(10), PeriodYear INT, PeriodStart DATE, PeriodEnd DATE,
        PeriodLabel NVARCHAR(40), ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2),
        SortOrder INT, PeriodOrder INT, IndexLabel VARCHAR(10), RowLabel NVARCHAR(4000), CoveragePct DECIMAL(9,2)
    );

    INSERT INTO #r
    EXEC dbo.usp_NW_DenialAnalysis_Compute @Grain = 'W';

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_DenialWeeklySummary;
        INSERT INTO dbo.NW_DenialWeeklySummary
              (RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshNW_DenialWeekly completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_DenialList
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), DenialCode NVARCHAR(400), PayerName NVARCHAR(500), CodeRank INT, PayerRank INT,
        ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2), SortOrder INT
    );

    INSERT INTO #r
    EXEC dbo.usp_GetNW_DenialList @ForceLive = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_DenialList;
        INSERT INTO dbo.NW_DenialList
              (RowType, DenialCode, PayerName, CodeRank, PayerRank, ClaimCount, TotalInsuranceBalance, SortOrder, RefreshedAt)
        SELECT RowType, DenialCode, PayerName, CodeRank, PayerRank, ClaimCount, TotalInsuranceBalance, SortOrder, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshNW_DenialList completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_DenialPlanType
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), PayerType NVARCHAR(200), ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2), SortOrder INT
    );

    INSERT INTO #r
    EXEC dbo.usp_GetNW_DenialPlanType @ForceLive = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_DenialPlanType;
        INSERT INTO dbo.NW_DenialPlanType (RowType, PayerType, ClaimCount, TotalInsuranceBalance, SortOrder, RefreshedAt)
        SELECT RowType, PayerType, ClaimCount, TotalInsuranceBalance, SortOrder, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshNW_DenialPlanType completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_DenialPayorVsPayer
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), PayerName NVARCHAR(500), DenialCode NVARCHAR(400), PayerType NVARCHAR(200),
        ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2), SortOrder INT, PayerRank INT, CodeRank INT
    );

    INSERT INTO #r
    EXEC dbo.usp_GetNW_DenialPayorVsPayer @ForceLive = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_DenialPayorVsPayer;
        INSERT INTO dbo.NW_DenialPayorVsPayer
              (RowType, PayerName, DenialCode, PayerType, ClaimCount, TotalInsuranceBalance,
               SortOrder, PayerRank, CodeRank, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerType, ClaimCount, TotalInsuranceBalance,
               SortOrder, PayerRank, CodeRank, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshNW_DenialPayorVsPayer completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_DenialByFacility
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), ClinicName NVARCHAR(500), DenialCode NVARCHAR(400),
        ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2), SortOrder INT, ClinicRank INT, CodeRank INT
    );

    INSERT INTO #r
    EXEC dbo.usp_GetNW_DenialByFacility @ForceLive = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_DenialByFacility;
        INSERT INTO dbo.NW_DenialByFacility
              (RowType, ClinicName, DenialCode, ClaimCount, TotalInsuranceBalance,
               SortOrder, ClinicRank, CodeRank, RefreshedAt)
        SELECT RowType, ClinicName, DenialCode, ClaimCount, TotalInsuranceBalance,
               SortOrder, ClinicRank, CodeRank, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshNW_DenialByFacility completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_DenialFacilityPct
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), ClinicName NVARCHAR(500), ClaimsBilled INT, AdjudicatedClaims INT,
        DeniedClaims INT, DeniedPct DECIMAL(18,6), SortOrder INT, ClinicRank INT
    );

    INSERT INTO #r
    EXEC dbo.usp_GetNW_DenialFacilityPct @ForceLive = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_DenialFacilityPct;
        INSERT INTO dbo.NW_DenialFacilityPct
              (RowType, ClinicName, ClaimsBilled, AdjudicatedClaims, DeniedClaims, DeniedPct,
               SortOrder, ClinicRank, RefreshedAt)
        SELECT RowType, ClinicName, ClaimsBilled, AdjudicatedClaims, DeniedClaims, DeniedPct,
               SortOrder, ClinicRank, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshNW_DenialFacilityPct completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

/* ---------------------------------------------------------------------------
   Populate every aggregate (Monthly also refreshes the tiles)
   --------------------------------------------------------------------------- */
EXEC dbo.usp_RefreshNW_DenialMonthly;
GO
EXEC dbo.usp_RefreshNW_DenialWeekly;
GO
EXEC dbo.usp_RefreshNW_DenialList;
GO
EXEC dbo.usp_RefreshNW_DenialPlanType;
GO
EXEC dbo.usp_RefreshNW_DenialPayorVsPayer;
GO
EXEC dbo.usp_RefreshNW_DenialByFacility;
GO
EXEC dbo.usp_RefreshNW_DenialFacilityPct;
GO

SET NOEXEC OFF;
GO

PRINT '45_NW_DenialSummary.sql completed.';

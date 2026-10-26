/* =============================================================================
   TexasDiagnostic - Denial Summary (Denial Analysis Report)
   Database : TexasDiagnostic        Prefix : TD_
   Source   : dbo.ClaimLevelData (Claim Level)

   Client sheet (Texas Diagnostic Denial Summary):
     Denial Code = ClaimLevelData.DenialCodeNormalized ("197"), labelled with its
                   DenialDescription. A claim is denied when DenialCode is not blank.
     Balance     = ClaimLevelData.InsuranceBalance; shown as Total Insurance Balance.
     1. Monthly
          Filter  : DenialCode not blank
          Columns : Denial Month = DenialDate month, every month up to the end of the
                    newest ClaimLevelData WeekFolder, a "yyyy | Total" per year, Grand Total
          Rows    : PayerName_Raw by total claim count, each drilled down to its
                    Top 3 DenialCodeNormalized by claim count
          Values  : No. of Claims = COUNT(DISTINCT ClaimID),
                    Total Insurance Balance = SUM(InsuranceBalance)
     2. Weekly - as Monthly; Denial Week = the 4 Friday-Thursday DenialDate weeks ending
                 with the week of the newest WeekFolder end date (= DeniedWeek Week 1-4)
     3. Denial List (not on the client sheet; the page always shows it)
          Filter  : DenialCode not blank
          Rows    : DenialCodeNormalized, drill down to Insurance (PayerName_Raw)
          Values  : No. of Claims, Total Insurance Balance; sorted by claim count DESC

   Result contracts are the same as the WH_ / AnP_ / CB_ Denial Summary SPs, so the page
   and Excel render the rows as returned. Plan Type is not on the Texas sheet.

   Filter parameters (all read SPs):
     @PayerNames / @PayerTypes / @DenialCodes : '|' separated lists
     @DenialFrom / @DenialTo                  : Denial Date (DenialDate) range
   With no filter the read SPs return the snapshot table filled at ingest; any
   filter (or @ForceLive = 1) aggregates live through the same logic.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
    RAISERROR('Run 30_TexasDiagnostic_DenialSummary.sql on the TexasDiagnostic database.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------------------
   Base view / filter function (Denial List, filter options)
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_TD_DenialClaims
AS
SELECT
    CAST(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), '') AS NVARCHAR(200))            AS ClaimID,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), c.PayerName_Raw))), ''), 'Unknown') AS NVARCHAR(500)) AS PayerName,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.PayerType))), ''), 'Unknown') AS NVARCHAR(200))     AS PayerType,
    CAST(CASE WHEN NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.DenialCode))), '') IS NOT NULL
              THEN COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.DenialCodeNormalized))), ''),
                            LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.DenialCode)))) END AS NVARCHAR(400)) AS DenialCode,
    COALESCE(TRY_CONVERT(DATE, c.DenialDate, 101), TRY_CAST(c.DenialDate AS DATE))                AS DenialDate,
    ISNULL(TRY_CONVERT(DECIMAL(18,2),
                       REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), '$', ''), ',', '')), 0)
                                                                                                  AS TotalInsuranceBalance
FROM dbo.ClaimLevelData c;
GO

CREATE OR ALTER FUNCTION dbo.fn_TD_DenialClaims
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
    FROM dbo.vw_TD_DenialClaims d
    WHERE d.ClaimID IS NOT NULL
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR d.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
           OR d.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
           OR ISNULL(d.DenialCode, N'(Blank)') IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DenialCodes, N'|')))
      AND (@DenialFrom IS NULL OR d.DenialDate >= @DenialFrom)
      AND (@DenialTo   IS NULL OR d.DenialDate <= @DenialTo);
GO

/* ---------------------------------------------------------------------------
   Monthly / Weekly / tiles claim rows: one row per claim whose DenialCode is not
   blank. Denial Code = DenialCodeNormalized, Denial Date = DenialDate.
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_TD_DenialSummaryClaims()
RETURNS TABLE
AS
RETURN
    SELECT NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'')                AS ClaimKey,
           CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), c.PayerName_Raw), N''))) AS NVARCHAR(500)) AS PayerName,
           CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.PayerType), N''))) AS NVARCHAR(200))     AS PayerType,
           CAST(COALESCE(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.DenialCodeNormalized))), N''),
                         LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.DenialCode)))) AS NVARCHAR(400)) AS DenialCode,
           LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(4000), c.DenialDescription), N'')))     AS DenialDescription,
           COALESCE(TRY_CONVERT(DATE, c.DenialDate, 101), TRY_CAST(c.DenialDate AS DATE)) AS DenialDate,
           ISNULL(b.Bal, 0)                                                             AS Bal
    FROM   dbo.ClaimLevelData c
    CROSS  APPLY (SELECT TRY_CONVERT(DECIMAL(18,2),
                         REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), N'$', N''), N',', N'')) AS Bal) b
    WHERE  LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(400), c.DenialCode), N''))) <> N'';
GO

/* Insurance grouping key: letters and digits only, upper case
   ("UNITED-HEALTHCARE" = "United Healthcare"). */
CREATE OR ALTER FUNCTION dbo.fn_TD_PayerKey (@Name NVARCHAR(500))
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

/* One denial code without punctuation, upper case: "CO-97" -> "CO97", "97" -> "97". */
CREATE OR ALTER FUNCTION dbo.fn_TD_DenialCodeKey (@Code NVARCHAR(200))
RETURNS NVARCHAR(200)
WITH SCHEMABINDING
AS
BEGIN
    RETURN UPPER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(@Code, N''))), N'-', N''), N' ', N''));
END
GO

/* Denial row label "code - description". A description already prefixed with its
   code is used as it stands. */
CREATE OR ALTER FUNCTION dbo.fn_TD_DenialRowLabel (@Code NVARCHAR(400), @Description NVARCHAR(4000))
RETURNS NVARCHAR(4000)
AS
BEGIN
    SET @Code = LTRIM(RTRIM(ISNULL(@Code, N'')));
    SET @Description = LTRIM(RTRIM(ISNULL(@Description, N'')));

    IF @Code = N'' RETURN CASE WHEN @Description = N'' THEN N'(no denial code)' ELSE @Description END;
    IF @Description = N'' RETURN @Code;
    IF LEFT(@Description, LEN(@Code)) = @Code RETURN @Description;
    RETURN @Code + N' - ' + @Description;
END
GO

/* ---------------------------------------------------------------------------
   Aggregate tables (snapshots, refilled by the refresh SPs below)
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.TD_DenialMonthlySummary', N'U') IS NULL
CREATE TABLE dbo.TD_DenialMonthlySummary
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

IF OBJECT_ID(N'dbo.TD_DenialWeeklySummary', N'U') IS NULL
CREATE TABLE dbo.TD_DenialWeeklySummary
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

IF OBJECT_ID(N'dbo.TD_DenialSummaryTiles', N'U') IS NULL
CREATE TABLE dbo.TD_DenialSummaryTiles
(
    DeniedClaims          INT            NOT NULL,
    InsuranceBalance      DECIMAL(18,2)  NOT NULL,
    DenialCodes           INT            NOT NULL,
    Insurances            INT            NOT NULL,
    UndatedGroups         INT            NOT NULL,
    LoadedThrough         DATE           NULL,
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.TD_DenialList', N'U') IS NULL
CREATE TABLE dbo.TD_DenialList
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

/* ---------------------------------------------------------------------------
   Monthly / Weekly engine
   @Grain 'M' = every Denial Month up to the loaded week, with a total per year
          'W' = the 4 Friday-Thursday weeks ending with the week of the newest
                WeekFolder end date
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_TD_DenialAnalysis_Compute
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
        RAISERROR('usp_TD_DenialAnalysis_Compute: @Grain must be M or W.', 16, 1);
        RETURN;
    END;

    DECLARE @TopPayers INT = 2147483647, @TopCodes INT = 3, @Weeks INT = 4;
    -- 2026-09-18 was a Friday; ((n % 7) + 7) % 7 keeps the offset positive.
    DECLARE @Friday DATE = '20260918';

    -- End date of the newest WeekFolder ("10.14.2026 - 10.20.2026" -> 2026-10-20).
    DECLARE @LoadedThrough DATE =
    (
        SELECT MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
        FROM   dbo.ClaimLevelData
        WHERE  WeekFolder IS NOT NULL
    );

    SELECT d.ClaimKey, d.PayerName, d.DenialCode, d.DenialDescription, d.DenialDate, d.Bal
    INTO   #c
    FROM   dbo.fn_TD_DenialSummaryClaims() d
    WHERE  d.ClaimKey IS NOT NULL
      AND  (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
            OR d.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
            OR d.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
            OR d.DenialCode IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DenialCodes, N'|')))
      AND  (@DenialFrom IS NULL OR d.DenialDate >= @DenialFrom)
      AND  (@DenialTo   IS NULL OR d.DenialDate <= @DenialTo);

    /* Columns */
    CREATE TABLE #per (PeriodType CHAR(1) NOT NULL, PeriodStart DATE NOT NULL, PeriodEnd DATE NOT NULL, PeriodYear INT NOT NULL);

    IF @Grain = 'M'
    BEGIN
        DECLARE @Cutoff DATE =
            CASE WHEN @LoadedThrough IS NOT NULL
                      AND EXISTS (SELECT 1 FROM #c WHERE DenialDate <= @LoadedThrough)
                 THEN @LoadedThrough END;

        INSERT INTO #per (PeriodType, PeriodStart, PeriodEnd, PeriodYear)
        SELECT DISTINCT 'M', DATEFROMPARTS(YEAR(DenialDate), MONTH(DenialDate), 1), EOMONTH(DenialDate), YEAR(DenialDate)
        FROM   #c
        WHERE  DenialDate IS NOT NULL
          AND  (@Cutoff IS NULL OR DenialDate <= @Cutoff);
    END
    ELSE
    BEGIN
        DECLARE @Anchor DATE = ISNULL(@LoadedThrough, (SELECT MAX(DenialDate) FROM #c));
        DECLARE @LastFri DATE = DATEADD(DAY, -((DATEDIFF(DAY, @Friday, @Anchor) % 7 + 7) % 7), @Anchor);

        INSERT INTO #per (PeriodType, PeriodStart, PeriodEnd, PeriodYear)
        SELECT 'W', DATEADD(DAY, -7 * v.n, @LastFri), DATEADD(DAY, 6 - 7 * v.n, @LastFri),
               YEAR(DATEADD(DAY, -7 * v.n, @LastFri))
        FROM   (VALUES (0), (1), (2), (3)) v(n)
        WHERE  v.n < @Weeks AND @LastFri IS NOT NULL;
    END;

    SELECT PeriodType, PeriodStart, PeriodEnd, PeriodYear
    INTO   #col
    FROM   #per
    UNION ALL
    SELECT 'Y', MIN(PeriodStart), MAX(PeriodEnd), PeriodYear
    FROM   #per
    WHERE  @Grain = 'M'
    GROUP  BY PeriodYear
    UNION ALL
    SELECT 'A', NULL, NULL, NULL;

    /* Claims the columns hold; totals, ranks and coverage describe these only */
    SELECT n.PayerName, dbo.fn_TD_PayerKey(n.PayerName) AS PayerKey
    INTO   #pk
    FROM  (SELECT DISTINCT PayerName FROM #c) n;

    SELECT c.ClaimKey, c.PayerName, k.PayerKey, c.DenialCode, c.DenialDescription, c.Bal,
           p.PeriodStart, p.PeriodYear
    INTO   #b
    FROM   #c c
    JOIN   #per p ON c.DenialDate BETWEEN p.PeriodStart AND p.PeriodEnd
    JOIN   #pk k  ON k.PayerName = c.PayerName;

    /* Insurances by No. of Claims, then Total Insurance Balance */
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

    /* Top 3 Denial Codes per insurance, by No. of Claims, then Total Insurance Balance */
    SELECT b.PayerKey, b.DenialCode,
           ISNULL(MIN(NULLIF(b.DenialDescription, N'')), N'') AS DenialDescription,
           ROW_NUMBER() OVER (PARTITION BY b.PayerKey
                              ORDER BY COUNT(DISTINCT b.ClaimKey) DESC, SUM(b.Bal) DESC, b.DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b b
    JOIN   #pr p ON p.PayerKey = b.PayerKey AND p.PayerRank <= @TopPayers
    GROUP  BY b.PayerKey, b.DenialCode;

    DELETE FROM #cr WHERE CodeRank > @TopCodes;

    /* Rows: insurance A..Z, AA.., its codes numbered down the whole table, Grand Total last */
    SELECT 'P' AS RowType, p.PayerKey, CAST(N'' AS NVARCHAR(400)) AS DenialCode, p.PayerRank, 0 AS CodeRank,
           p.PayerRank * 10 AS RowSeq,
           CASE WHEN p.PayerRank <= 26 THEN CAST(CHAR(64 + p.PayerRank) AS VARCHAR(10))
                ELSE CAST(CHAR(64 + (p.PayerRank - 1) / 26) AS VARCHAR(10)) + CHAR(65 + (p.PayerRank - 1) % 26) END AS IndexLabel,
           CAST(p.PayerLabel AS NVARCHAR(4000)) AS RowLabel,
           p.PayerLabel
    INTO   #r
    FROM   #pr p
    WHERE  p.PayerRank <= @TopPayers
    UNION ALL
    SELECT 'C', c.PayerKey, c.DenialCode, p.PayerRank, c.CodeRank,
           p.PayerRank * 10 + c.CodeRank,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerRank, c.CodeRank) AS VARCHAR(10)),
           dbo.fn_TD_DenialRowLabel(c.DenialCode, c.DenialDescription),
           p.PayerLabel
    FROM   #cr c
    JOIN   #pr p ON p.PayerKey = c.PayerKey
    UNION ALL
    SELECT 'T', N'', N'', 0, 0, 2147483647, '', N'Grand Total', N'Grand Total';

    /* Cells: period, year subtotal (Monthly) and grand total of every row */
    ;WITH m AS
    (
        SELECT r.RowSeq, b.ClaimKey, b.Bal, b.PeriodStart, b.PeriodYear
        FROM   #b b
        JOIN   #r r ON r.RowType IN ('P', 'C') AND r.PayerKey = b.PayerKey
                   AND (r.RowType = 'P' OR r.DenialCode = b.DenialCode)
        UNION ALL
        SELECT 2147483647, b.ClaimKey, b.Bal, b.PeriodStart, b.PeriodYear
        FROM   #b b
    )
    SELECT RowSeq,
           CAST(CASE WHEN GROUPING(PeriodStart) = 0 THEN @Grain
                     WHEN GROUPING(PeriodYear)  = 0 THEN 'Y'
                     ELSE 'A' END AS CHAR(1)) AS PeriodType,
           PeriodStart, PeriodYear,
           COUNT(DISTINCT ClaimKey) AS ClaimCount,
           SUM(Bal)                 AS Bal
    INTO   #cell
    FROM   m
    GROUP  BY GROUPING SETS ((RowSeq, PeriodYear, PeriodStart), (RowSeq, PeriodYear), (RowSeq));

    ;WITH grid AS
    (
        SELECT r.RowType, r.DenialCode, r.PayerRank, r.CodeRank, r.RowSeq, r.IndexLabel, r.RowLabel, r.PayerLabel,
               k.PeriodType, k.PeriodStart AS ColStart, k.PeriodEnd AS ColEnd, k.PeriodYear AS ColYear,
               x.ClaimCount, x.Bal
        FROM   #r r
        CROSS  JOIN #col k
        LEFT   JOIN #cell x ON x.RowSeq = r.RowSeq
                           AND x.PeriodType = k.PeriodType
                           AND (k.PeriodType = 'A' OR x.PeriodYear = k.PeriodYear)
                           AND (k.PeriodType IN ('Y', 'A') OR x.PeriodStart = k.PeriodStart)
        WHERE  r.RowType = 'T' OR x.RowSeq IS NOT NULL
    )
    SELECT RowType,
           PayerLabel AS PayerName,
           DenialCode, PayerRank, CodeRank,
           PeriodType,
           CAST(CASE PeriodType WHEN 'Y' THEN 'total-' + CAST(ColYear AS VARCHAR(4))
                                WHEN 'A' THEN ''
                                ELSE CONVERT(CHAR(10), ColStart, 120) END AS VARCHAR(10)) AS PeriodKey,
           ColYear  AS PeriodYear,
           ColStart AS PeriodStart,
           ColEnd   AS PeriodEnd,
           CAST(CASE PeriodType WHEN 'M' THEN FORMAT(ColStart, 'MMM', 'en-US')
                                WHEN 'W' THEN FORMAT(ColStart, 'dd MMM', 'en-US') + N' - ' + FORMAT(ColEnd, 'dd MMM', 'en-US')
                                WHEN 'Y' THEN CAST(ColYear AS VARCHAR(4)) + ' | Total'
                                ELSE 'Grand Total' END AS NVARCHAR(40)) AS PeriodLabel,
           ISNULL(ClaimCount, 0)                 AS ClaimCount,
           CAST(ISNULL(Bal, 0) AS DECIMAL(18,2)) AS TotalInsuranceBalance,
           DENSE_RANK() OVER (ORDER BY RowSeq)   AS SortOrder,
           DENSE_RANK() OVER (ORDER BY CASE WHEN PeriodType = 'A' THEN 1 ELSE 0 END, ColYear,
                                       CASE WHEN PeriodType = 'Y' THEN 1 ELSE 0 END, ColStart) AS PeriodOrder,
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
CREATE OR ALTER PROCEDURE dbo.usp_GetTD_DenialMonthly
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
       AND EXISTS (SELECT 1 FROM dbo.TD_DenialMonthlySummary)
    BEGIN
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank,
               PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel,
               ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct
        FROM   dbo.TD_DenialMonthlySummary
        ORDER  BY SortOrder, PeriodOrder;
        RETURN;
    END;

    EXEC dbo.usp_TD_DenialAnalysis_Compute
         @Grain = 'M', @PayerNames = @PayerNames, @PayerTypes = @PayerTypes,
         @DenialCodes = @DenialCodes, @DenialFrom = @DenialFrom, @DenialTo = @DenialTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetTD_DenialWeekly
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
       AND EXISTS (SELECT 1 FROM dbo.TD_DenialWeeklySummary)
    BEGIN
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank,
               PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel,
               ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct
        FROM   dbo.TD_DenialWeeklySummary
        ORDER  BY SortOrder, PeriodOrder;
        RETURN;
    END;

    EXEC dbo.usp_TD_DenialAnalysis_Compute
         @Grain = 'W', @PayerNames = @PayerNames, @PayerTypes = @PayerTypes,
         @DenialCodes = @DenialCodes, @DenialFrom = @DenialFrom, @DenialTo = @DenialTo;
END
GO

/* ---------------------------------------------------------------------------
   Tiles - Denied Claims, Insurance Balance, Denial Codes, Insurances: every claim
   of fn_TD_DenialSummaryClaims, whatever its Denial Date
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_TD_DenialSummaryTiles_Compute
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ClaimKey, PayerName, DenialCode, DenialDescription, DenialDate, Bal
    INTO   #c
    FROM   dbo.fn_TD_DenialSummaryClaims()
    WHERE  ClaimKey IS NOT NULL;

    SELECT COUNT(DISTINCT ClaimKey)                       AS DeniedClaims,
           CAST(ISNULL(SUM(Bal), 0) AS DECIMAL(18,2))     AS InsuranceBalance,
           COUNT(DISTINCT DenialCode)                     AS DenialCodes,
           COUNT(DISTINCT NULLIF(PayerName, N''))         AS Insurances,
           (SELECT COUNT(*)
            FROM  (SELECT DISTINCT PayerName, DenialCode, DenialDescription
                   FROM   #c
                   WHERE  DenialDate IS NULL) u)          AS UndatedGroups,
           (SELECT MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
            FROM   dbo.ClaimLevelData
            WHERE  WeekFolder IS NOT NULL)                AS LoadedThrough,
           GETDATE()                                      AS RefreshedAt
    FROM   #c;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetTD_DenialSummaryTiles
    @ForceLive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0 AND EXISTS (SELECT 1 FROM dbo.TD_DenialSummaryTiles)
    BEGIN
        SELECT TOP (1) DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, RefreshedAt
        FROM   dbo.TD_DenialSummaryTiles
        ORDER  BY RefreshedAt DESC;
        RETURN;
    END;

    EXEC dbo.usp_TD_DenialSummaryTiles_Compute;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Denial List
   RowType 'D' denial code (as written on the claim), 'I' insurance under it,
   'T' grand total.
   @DenialCodeSearch : optional; the Denial List tab search box. Each searched code
                       ("CO-16", "CO16" or "16") must equal one of the claim's codes,
                       with or without its group prefix.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetTD_DenialList
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
       AND EXISTS (SELECT 1 FROM dbo.TD_DenialList)
    BEGIN
        SELECT RowType, DenialCode, PayerName, CodeRank, PayerRank,
               ClaimCount, TotalInsuranceBalance, SortOrder
        FROM   dbo.TD_DenialList
        ORDER  BY SortOrder;
        RETURN;
    END;

    SELECT d.ClaimID,
           d.DenialCode,
           d.PayerName,
           d.TotalInsuranceBalance AS Bal
    INTO   #b
    FROM   dbo.fn_TD_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
    WHERE  d.DenialCode IS NOT NULL
      AND  (@DenialCodeSearch IS NULL
            OR NOT EXISTS (SELECT 1
                           FROM   STRING_SPLIT(REPLACE(@DenialCodeSearch, N',', N' '), N' ') s
                           WHERE  s.value <> N''
                             AND  NOT EXISTS (SELECT 1
                                              FROM   STRING_SPLIT(REPLACE(d.DenialCode, N';', N','), N',') t
                                              WHERE  dbo.fn_TD_DenialCodeKey(t.value) = dbo.fn_TD_DenialCodeKey(s.value)
                                                 OR  SUBSTRING(dbo.fn_TD_DenialCodeKey(t.value), 3, 200) = dbo.fn_TD_DenialCodeKey(s.value)
                                                 OR  dbo.fn_TD_DenialCodeKey(t.value) = SUBSTRING(dbo.fn_TD_DenialCodeKey(s.value), 3, 200))));

    SELECT DenialCode,
           ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(Bal) DESC, DenialCode) AS CodeRank
    INTO   #dr
    FROM   #b
    GROUP  BY DenialCode;

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(b.PayerName) = 1 THEN 'D' ELSE 'I' END AS RowType,
               b.DenialCode,
               ISNULL(b.PayerName, N'')                        AS PayerName,
               COUNT(DISTINCT b.ClaimID)                       AS ClaimCount,
               CAST(ISNULL(SUM(b.Bal), 0) AS DECIMAL(18,2))    AS TotalInsuranceBalance
        FROM   #b b
        GROUP  BY GROUPING SETS ((b.DenialCode, b.PayerName), (b.DenialCode))
        UNION  ALL
        SELECT 'T', N'Grand Total', N'',
               COUNT(DISTINCT b.ClaimID),
               CAST(ISNULL(SUM(b.Bal), 0) AS DECIMAL(18,2))
        FROM   #b b
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
   Filter options
   Result sets: 1 payer names, 2 payer types, 3 denial codes,
                4 denial date range + last refresh time
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetTD_DenialFilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT PayerName AS Value
    FROM   dbo.vw_TD_DenialClaims
    WHERE  ClaimID IS NOT NULL AND (DenialCode IS NOT NULL OR TotalInsuranceBalance > 0)
    ORDER  BY Value;

    SELECT DISTINCT PayerType AS Value
    FROM   dbo.vw_TD_DenialClaims
    WHERE  ClaimID IS NOT NULL AND (DenialCode IS NOT NULL OR TotalInsuranceBalance > 0)
    ORDER  BY Value;

    SELECT DISTINCT DenialCode AS Value
    FROM   dbo.vw_TD_DenialClaims
    WHERE  ClaimID IS NOT NULL AND DenialCode IS NOT NULL
    ORDER  BY Value;

    SELECT MIN(DenialDate) AS MinDenialDate,
           MAX(DenialDate) AS MaxDenialDate,
           (SELECT MAX(RefreshedAt) FROM dbo.TD_DenialMonthlySummary) AS RefreshedAt
    FROM   dbo.vw_TD_DenialClaims
    WHERE  ClaimID IS NOT NULL AND DenialCode IS NOT NULL;
END
GO

/* ---------------------------------------------------------------------------
   Refresh SPs (run by ClaimLineCSVDataCapture when a new claim file lands)
   usp_RefreshTD_DenialMonthly also refreshes the tiles.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_DenialSummaryTiles
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #t
    (
        DeniedClaims INT, InsuranceBalance DECIMAL(18,2), DenialCodes INT, Insurances INT,
        UndatedGroups INT, LoadedThrough DATE, RefreshedAt DATETIME
    );

    INSERT INTO #t
    EXEC dbo.usp_TD_DenialSummaryTiles_Compute;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.TD_DenialSummaryTiles;
        INSERT INTO dbo.TD_DenialSummaryTiles
              (DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, RefreshedAt)
        SELECT DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, GETDATE()
        FROM   #t;
    COMMIT;

    PRINT 'usp_RefreshTD_DenialSummaryTiles completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_DenialMonthly
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
    EXEC dbo.usp_TD_DenialAnalysis_Compute @Grain = 'M';

    BEGIN TRAN;
        TRUNCATE TABLE dbo.TD_DenialMonthlySummary;
        INSERT INTO dbo.TD_DenialMonthlySummary
              (RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshTD_DenialMonthly completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';

    EXEC dbo.usp_RefreshTD_DenialSummaryTiles;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_DenialWeekly
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
    EXEC dbo.usp_TD_DenialAnalysis_Compute @Grain = 'W';

    BEGIN TRAN;
        TRUNCATE TABLE dbo.TD_DenialWeeklySummary;
        INSERT INTO dbo.TD_DenialWeeklySummary
              (RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshTD_DenialWeekly completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_DenialList
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), DenialCode NVARCHAR(400), PayerName NVARCHAR(500), CodeRank INT, PayerRank INT,
        ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2), SortOrder INT
    );

    INSERT INTO #r
    EXEC dbo.usp_GetTD_DenialList @ForceLive = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.TD_DenialList;
        INSERT INTO dbo.TD_DenialList
              (RowType, DenialCode, PayerName, CodeRank, PayerRank, ClaimCount, TotalInsuranceBalance, SortOrder, RefreshedAt)
        SELECT RowType, DenialCode, PayerName, CodeRank, PayerRank, ClaimCount, TotalInsuranceBalance, SortOrder, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshTD_DenialList completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshTD_DenialMonthly;
EXEC dbo.usp_RefreshTD_DenialWeekly;
EXEC dbo.usp_RefreshTD_DenialList;
GO

PRINT '30_TexasDiagnostic_DenialSummary.sql completed.';
GO

/* =============================================================================
   Analyze Pathology - Denial Summary (Denial Analysis Report)
   Database : AnalyzePathology        Prefix : AnP_
   Source   : dbo.ClaimLevelData (Claim Level)

   Client logic (Denial Analysis Report - Requirements):
     1. Monthly Summary (Denial Summary page, Monthly tab)
          Filter  : Total Insurance Balance > 0, Denial Code not blank and
                    DenialCodeNormalized not blank (CO45 / PI45 / PR45 -> 45)
          Date    : ClaimLevelData.DenialDate, else the latest DenialDate of the
                    claim's denied lines in LineLevelData
          Columns : every Denial Month up to the end of the newest ClaimLevelData
                    WeekFolder, a "yyyy | Total" column per year, Grand Total
          Rows    : Top 10 insurances (PayerName_Raw, case / punctuation ignored)
                    by No. of Claims then balance, each with its Top 3 normalized
                    denial codes by No. of Claims then balance
          Values  : No. of Claims = COUNT(DISTINCT ClaimID),
                    Total Insurance Balance = SUM(TotalInsuranceBalance)
          Totals  : every insurance in the shown months (not only the Top 10)
     2. Weekly Summary - as Monthly, columns = the 4 seven-day weeks ending on the
                         newest WeekFolder end date, no year columns
     Monthly / Weekly / tiles are computed at claim-file ingest into
     AnP_DenialMonthlySummary, AnP_DenialWeeklySummary and AnP_DenialSummaryTiles.
     3. Denial List
          Filter  : Total Insurance Balance > 0 and Denial Code is not blank
                    (blank removed per client feedback 10/07/2026);
                    optional Denial Code search (contains)
          Rows    : Denial Code, drill down to Insurance (Payer Name_Raw)
                    by Total Insurance Balance
          Values  : No. of Claims, Total Insurance Balance; sort balance DESC
     4. Denial List - Plan Type
          Filter  : Total Insurance Balance > 0 and Denial Code is not blank
          Rows    : PayerType; values / sort as Denial List

   Every calculation, ranking, total and sort order is produced here. The UI and
   the Excel export render the rows as returned.

   Objects
     vw_AnP_DenialClaims / fn_AnP_DenialClaims   typed + filtered claim rows (lists)
     fn_AnP_DenialSummaryClaims                  Monthly / Weekly / tiles claim rows
     fn_AnP_PayerKey, fn_AnP_DenialRowLabel      insurance grouping key, code label
     usp_AnP_DenialAnalysis_Compute              Monthly / Weekly engine
     usp_AnP_DenialSummaryTiles_Compute          Denied Claims / Balance / Codes / Insurances
     usp_GetAnP_DenialMonthly / _DenialWeekly    read SPs (snapshot or live)
     usp_GetAnP_DenialSummaryTiles               read SP (snapshot or live)
     usp_GetAnP_DenialList / _DenialPlanType     read SPs (snapshot or live)
     usp_GetAnP_DenialFilterOptions              filter dropdown values
     usp_RefreshAnP_Denial*                      snapshot refresh (ingest)
     AnP_DenialMonthlySummary, AnP_DenialWeeklySummary, AnP_DenialSummaryTiles,
     AnP_DenialList, AnP_DenialPlanType          aggregate tables

   Filter parameters (all read SPs):
     @PayerNames / @PayerTypes / @DenialCodes : '|' separated lists
     @DenialFrom / @DenialTo                  : Denial Date range
   With no filter the read SPs return the snapshot table filled at ingest; any
   filter (or @ForceLive = 1) aggregates live through the same logic.

   Monthly / Weekly result contract (one row per row x period that has claims;
   the T row carries every period, so it also lists the columns):
     RowType      'P' insurance, 'C' top-3 denial code under PayerName, 'T' grand total
     PayerName    insurance label; DenialCode = normalized code on C rows
     PayerRank    insurance position by No. of Claims then balance (0 on T)
     CodeRank     1-3 on C rows (0 otherwise)
     PeriodType   'M' month / 'W' week / 'Y' year total (Monthly only) / 'A' grand total
     PeriodKey    'yyyy-MM-dd' (period start) / 'total-yyyy' / ''
     PeriodYear, PeriodStart, PeriodEnd, PeriodLabel ('Jan', '07 Sep - 13 Sep', '2026 | Total')
     ClaimCount, TotalInsuranceBalance
     SortOrder    row position (P, its C rows, ..., T last)
     PeriodOrder  column position (months, year total per year, grand total last)
     IndexLabel   'A'..'J' on P rows, 1..n down the table on C rows
     RowLabel     insurance name / "code - description"
     CoveragePct  share of the balance the Top 10 insurances hold (whole %)
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   Base view / filter function
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_AnP_DenialClaims
AS
SELECT
    CAST(NULLIF(LTRIM(RTRIM(c.ClaimID)), '') AS NVARCHAR(200))                   AS ClaimID,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), ''), 'Unknown') AS NVARCHAR(500)) AS PayerName,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.PayerType)), ''), 'Unknown') AS NVARCHAR(200))     AS PayerType,
    CAST(NULLIF(LTRIM(RTRIM(c.DenialCode)), '') AS NVARCHAR(400))                AS DenialCode,
    TRY_CAST(NULLIF(LTRIM(RTRIM(c.DenialDate)), '') AS DATE)                     AS DenialDate,
    ISNULL(TRY_CAST(REPLACE(REPLACE(LTRIM(RTRIM(c.TotalInsuranceBalance)), '$', ''), ',', '')
                    AS DECIMAL(18,2)), 0)                                         AS TotalInsuranceBalance
FROM dbo.ClaimLevelData c;
GO

CREATE OR ALTER FUNCTION dbo.fn_AnP_DenialClaims
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
    FROM dbo.vw_AnP_DenialClaims d
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
   Monthly / Weekly / tiles claim rows: one row per denied claim with a Total
   Insurance Balance, a Denial Code and a normalized code. DenialDate falls back
   to the latest DenialDate of the claim's denied lines.
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_AnP_DenialSummaryClaims()
RETURNS TABLE
AS
RETURN
    WITH ld AS
    (
        SELECT LTRIM(RTRIM(CONVERT(NVARCHAR(255), l.ClaimID))) AS ClaimKey,
               MAX(TRY_CONVERT(DATE, l.DenialDate))            AS LineDenialDate
        FROM   dbo.LineLevelData l
        WHERE  TRY_CONVERT(DATE, l.DenialDate) IS NOT NULL
          AND  LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), l.DenialCode), N''))) <> N''
        GROUP  BY LTRIM(RTRIM(CONVERT(NVARCHAR(255), l.ClaimID)))
    )
    SELECT NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'')                AS ClaimKey,
           CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), c.PayerName_Raw), N''))) AS NVARCHAR(500)) AS PayerName,
           CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.PayerType), N''))) AS NVARCHAR(200))     AS PayerType,
           CAST(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.DenialCodeNormalized))) AS NVARCHAR(400))       AS DenialCode,
           LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(4000), c.DenialDescription), N'')))     AS DenialDescription,
           COALESCE(TRY_CONVERT(DATE, c.DenialDate), ld.LineDenialDate)                 AS DenialDate,
           b.Bal
    FROM   dbo.ClaimLevelData c
    CROSS  APPLY (SELECT TRY_CONVERT(DECIMAL(18,2),
                         REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.TotalInsuranceBalance))), N'$', N''), N',', N'')) AS Bal) b
    LEFT   JOIN ld ON ld.ClaimKey = LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID)))
    WHERE  LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), c.DenialCode), N''))) <> N''
      AND  LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(400), c.DenialCodeNormalized), N''))) <> N''
      AND  b.Bal > 0;
GO

/* Insurance grouping key: letters and digits only, upper case
   ("UNITED-HEALTHCARE" = "United Healthcare"). */
CREATE OR ALTER FUNCTION dbo.fn_AnP_PayerKey (@Name NVARCHAR(500))
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

/* Denial row label "code - description". The Master File Processor already prefixes
   the description with its code(s); such a description is used as it stands. */
CREATE OR ALTER FUNCTION dbo.fn_AnP_DenialRowLabel (@Code NVARCHAR(400), @Description NVARCHAR(4000))
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
   Aggregate tables
   (Monthly / Weekly are rebuilt when their columns are older than this script;
    they are snapshots, refilled by the refresh SPs below.)
   --------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.AnP_DenialMonthlySummary', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.AnP_DenialMonthlySummary', N'RowLabel') IS NULL
    DROP TABLE dbo.AnP_DenialMonthlySummary;
IF OBJECT_ID(N'dbo.AnP_DenialWeeklySummary', N'U') IS NOT NULL
   AND COL_LENGTH(N'dbo.AnP_DenialWeeklySummary', N'RowLabel') IS NULL
    DROP TABLE dbo.AnP_DenialWeeklySummary;
GO

IF OBJECT_ID(N'dbo.AnP_DenialMonthlySummary', N'U') IS NULL
CREATE TABLE dbo.AnP_DenialMonthlySummary
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

IF OBJECT_ID(N'dbo.AnP_DenialWeeklySummary', N'U') IS NULL
CREATE TABLE dbo.AnP_DenialWeeklySummary
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

IF OBJECT_ID(N'dbo.AnP_DenialSummaryTiles', N'U') IS NULL
CREATE TABLE dbo.AnP_DenialSummaryTiles
(
    DeniedClaims          INT            NOT NULL,   -- every claim of fn_AnP_DenialSummaryClaims, all dates
    InsuranceBalance      DECIMAL(18,2)  NOT NULL,
    DenialCodes           INT            NOT NULL,   -- distinct normalized codes
    Insurances            INT            NOT NULL,   -- distinct PayerName_Raw
    UndatedGroups         INT            NOT NULL,   -- insurance / code / description groups with no Denial Date
    LoadedThrough         DATE           NULL,       -- end of the newest ClaimLevelData WeekFolder
    RefreshedAt           DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.AnP_DenialList', N'U') IS NULL
CREATE TABLE dbo.AnP_DenialList
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

IF OBJECT_ID(N'dbo.AnP_DenialPlanType', N'U') IS NULL
CREATE TABLE dbo.AnP_DenialPlanType
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

/* ---------------------------------------------------------------------------
   Monthly / Weekly engine
   @Grain 'M' = every Denial Month up to the loaded week, with a total per year
          'W' = the 4 seven-day weeks ending on the newest WeekFolder end date
   Rows, ranks, labels, cells, totals and both orders are produced here; the page
   and the Excel export lay the rows out as returned.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_DenialAnalysis_Compute
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
        RAISERROR('usp_AnP_DenialAnalysis_Compute: @Grain must be M or W.', 16, 1);
        RETURN;
    END;

    DECLARE @TopPayers INT = 10, @TopCodes INT = 3, @Weeks INT = 4;

    -- End date of the newest WeekFolder ("09.28.2026 - 10.04.2026" -> 2026-10-04).
    DECLARE @LoadedThrough DATE =
    (
        SELECT MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
        FROM   dbo.ClaimLevelData
        WHERE  WeekFolder IS NOT NULL
    );

    SELECT d.ClaimKey, d.PayerName, d.DenialCode, d.DenialDescription, d.DenialDate, d.Bal
    INTO   #c
    FROM   dbo.fn_AnP_DenialSummaryClaims() d
    WHERE  (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
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
        -- Months holding a claim denied on or before the loaded-through date; every dated
        -- month when there is no WeekFolder or nothing is that old.
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
    ELSE IF @LoadedThrough IS NOT NULL
    BEGIN
        INSERT INTO #per (PeriodType, PeriodStart, PeriodEnd, PeriodYear)
        SELECT 'W', DATEADD(DAY, -6 - 7 * v.n, @LoadedThrough), DATEADD(DAY, -7 * v.n, @LoadedThrough),
               YEAR(DATEADD(DAY, -6 - 7 * v.n, @LoadedThrough))
        FROM   (VALUES (0), (1), (2), (3)) v(n)
        WHERE  v.n < @Weeks;
    END
    ELSE
    BEGIN
        -- No WeekFolder: the newest 4 Wednesday-Tuesday weeks the denial dates fall in.
        -- 1900-01-01 is a Monday, so (offset + 5) % 7 is the distance back to Wednesday
        -- whatever SET DATEFIRST says.
        INSERT INTO #per (PeriodType, PeriodStart, PeriodEnd, PeriodYear)
        SELECT TOP (@Weeks) 'W', s.WeekStart, DATEADD(DAY, 6, s.WeekStart), YEAR(s.WeekStart)
        FROM  (SELECT DISTINCT DATEADD(DAY, -((DATEDIFF(DAY, '19000101', DenialDate) + 5) % 7), DenialDate) AS WeekStart
               FROM   #c
               WHERE  DenialDate IS NOT NULL) s
        ORDER  BY s.WeekStart DESC;
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
    SELECT n.PayerName, dbo.fn_AnP_PayerKey(n.PayerName) AS PayerKey
    INTO   #pk
    FROM  (SELECT DISTINCT PayerName FROM #c) n;

    SELECT c.ClaimKey, c.PayerName, k.PayerKey, c.DenialCode, c.DenialDescription, c.Bal,
           p.PeriodStart, p.PeriodYear
    INTO   #b
    FROM   #c c
    JOIN   #per p ON c.DenialDate BETWEEN p.PeriodStart AND p.PeriodEnd
    JOIN   #pk k  ON k.PayerName = c.PayerName;

    /* Insurances by No. of Claims, then balance */
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

    /* Top 3 normalized codes per listed insurance, by No. of Claims, then balance */
    SELECT b.PayerKey, b.DenialCode,
           ISNULL(MIN(NULLIF(b.DenialDescription, N'')), N'') AS DenialDescription,
           ROW_NUMBER() OVER (PARTITION BY b.PayerKey
                              ORDER BY COUNT(DISTINCT b.ClaimKey) DESC, SUM(b.Bal) DESC, b.DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b b
    JOIN   #pr p ON p.PayerKey = b.PayerKey AND p.PayerRank <= @TopPayers
    GROUP  BY b.PayerKey, b.DenialCode;

    DELETE FROM #cr WHERE CodeRank > @TopCodes;

    /* Rows: insurance A..J, its codes numbered down the whole table, Grand Total last */
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
           dbo.fn_AnP_DenialRowLabel(c.DenialCode, c.DenialDescription),
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
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_DenialMonthly
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
       AND EXISTS (SELECT 1 FROM dbo.AnP_DenialMonthlySummary)
    BEGIN
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank,
               PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel,
               ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct
        FROM   dbo.AnP_DenialMonthlySummary
        ORDER  BY SortOrder, PeriodOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_DenialAnalysis_Compute
         @Grain = 'M', @PayerNames = @PayerNames, @PayerTypes = @PayerTypes,
         @DenialCodes = @DenialCodes, @DenialFrom = @DenialFrom, @DenialTo = @DenialTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_DenialWeekly
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
       AND EXISTS (SELECT 1 FROM dbo.AnP_DenialWeeklySummary)
    BEGIN
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank,
               PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel,
               ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct
        FROM   dbo.AnP_DenialWeeklySummary
        ORDER  BY SortOrder, PeriodOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_DenialAnalysis_Compute
         @Grain = 'W', @PayerNames = @PayerNames, @PayerTypes = @PayerTypes,
         @DenialCodes = @DenialCodes, @DenialFrom = @DenialFrom, @DenialTo = @DenialTo;
END
GO

/* ---------------------------------------------------------------------------
   Tiles - Denied Claims, Insurance Balance, Denial Codes, Insurances: every claim
   of fn_AnP_DenialSummaryClaims, whatever its Denial Date
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_DenialSummaryTiles_Compute
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ClaimKey, PayerName, DenialCode, DenialDescription, DenialDate, Bal
    INTO   #c
    FROM   dbo.fn_AnP_DenialSummaryClaims();

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

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_DenialSummaryTiles
    @ForceLive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0 AND EXISTS (SELECT 1 FROM dbo.AnP_DenialSummaryTiles)
    BEGIN
        SELECT TOP (1) DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, RefreshedAt
        FROM   dbo.AnP_DenialSummaryTiles
        ORDER  BY RefreshedAt DESC;
        RETURN;
    END;

    EXEC dbo.usp_AnP_DenialSummaryTiles_Compute;
END
GO

/* ---------------------------------------------------------------------------
   Read SP - Denial List
   RowType 'D' denial code, 'I' insurance under DenialCode, 'T' grand total.
   Claims with a blank Denial Code are excluded (client feedback 10/07/2026).
   @DenialCodeSearch : optional; the Denial List tab search box. Matches whole codes:
                       a row's Denial Code is split on commas / spaces ("CO-16, CO-252",
                       "CO-131 CO-P12") and is kept when every searched code equals one of
                       its codes, so "CO-16" finds "CO-16" and "CO-16, CO-252" but not
                       "CO-167". Totals cover the matching rows.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_DenialList
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
       AND EXISTS (SELECT 1 FROM dbo.AnP_DenialList)
    BEGIN
        SELECT RowType, DenialCode, PayerName, CodeRank, PayerRank,
               ClaimCount, TotalInsuranceBalance, SortOrder
        FROM   dbo.AnP_DenialList
        ORDER  BY SortOrder;
        RETURN;
    END;

    SELECT d.ClaimID,
           d.DenialCode,
           d.PayerName,
           d.TotalInsuranceBalance AS Bal
    INTO   #b
    FROM   dbo.fn_AnP_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
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
           ROW_NUMBER() OVER (ORDER BY SUM(Bal) DESC, COUNT(DISTINCT ClaimID) DESC, DenialCode) AS CodeRank
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
                                            ORDER BY g.TotalInsuranceBalance DESC, g.ClaimCount DESC, g.PayerName)
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
   Read SP - Denial List - Plan Type
   RowType 'D' one row per PayerType, 'T' grand total.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_DenialPlanType
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
       AND EXISTS (SELECT 1 FROM dbo.AnP_DenialPlanType)
    BEGIN
        SELECT RowType, PayerType, ClaimCount, TotalInsuranceBalance, SortOrder
        FROM   dbo.AnP_DenialPlanType
        ORDER  BY SortOrder;
        RETURN;
    END;

    ;WITH g AS
    (
        SELECT CASE WHEN GROUPING(d.PayerType) = 1 THEN 'T' ELSE 'D' END AS RowType,
               ISNULL(d.PayerType, N'Grand Total')                       AS PayerType,
               COUNT(DISTINCT d.ClaimID)                                 AS ClaimCount,
               CAST(ISNULL(SUM(d.TotalInsuranceBalance), 0) AS DECIMAL(18,2)) AS TotalInsuranceBalance
        FROM   dbo.fn_AnP_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
        WHERE  d.TotalInsuranceBalance > 0
          AND  d.DenialCode IS NOT NULL
        GROUP  BY GROUPING SETS ((d.PayerType), ())
    )
    SELECT RowType, PayerType, ClaimCount, TotalInsuranceBalance,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                       TotalInsuranceBalance DESC, ClaimCount DESC, PayerType) AS SortOrder
    FROM   g
    ORDER  BY SortOrder;
END
GO

/* ---------------------------------------------------------------------------
   Filter options
   Result sets: 1 payer names, 2 payer types, 3 denial codes,
                4 denial date range + last refresh time
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_DenialFilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT PayerName AS Value
    FROM   dbo.vw_AnP_DenialClaims
    WHERE  ClaimID IS NOT NULL AND (DenialCode IS NOT NULL OR TotalInsuranceBalance > 0)
    ORDER  BY Value;

    SELECT DISTINCT PayerType AS Value
    FROM   dbo.vw_AnP_DenialClaims
    WHERE  ClaimID IS NOT NULL AND (DenialCode IS NOT NULL OR TotalInsuranceBalance > 0)
    ORDER  BY Value;

    SELECT DISTINCT DenialCode AS Value
    FROM   dbo.vw_AnP_DenialClaims
    WHERE  ClaimID IS NOT NULL AND DenialCode IS NOT NULL
    ORDER  BY Value;

    SELECT MIN(DenialDate) AS MinDenialDate,
           MAX(DenialDate) AS MaxDenialDate,
           (SELECT MAX(RefreshedAt) FROM dbo.AnP_DenialMonthlySummary) AS RefreshedAt
    FROM   dbo.vw_AnP_DenialClaims
    WHERE  ClaimID IS NOT NULL AND DenialCode IS NOT NULL;
END
GO

/* ---------------------------------------------------------------------------
   Refresh SPs (run by ClaimLineCSVDataCapture when a new claim file lands)
   usp_RefreshAnP_DenialMonthly also refreshes the tiles, so the ingest list
   (Monthly, Weekly, List, Plan Type) needs no new entry.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_DenialSummaryTiles
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #t
    (
        DeniedClaims INT, InsuranceBalance DECIMAL(18,2), DenialCodes INT, Insurances INT,
        UndatedGroups INT, LoadedThrough DATE, RefreshedAt DATETIME
    );

    INSERT INTO #t
    EXEC dbo.usp_AnP_DenialSummaryTiles_Compute;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.AnP_DenialSummaryTiles;
        INSERT INTO dbo.AnP_DenialSummaryTiles
              (DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, RefreshedAt)
        SELECT DeniedClaims, InsuranceBalance, DenialCodes, Insurances, UndatedGroups, LoadedThrough, GETDATE()
        FROM   #t;
    COMMIT;

    PRINT 'usp_RefreshAnP_DenialSummaryTiles completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_DenialMonthly
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
    EXEC dbo.usp_AnP_DenialAnalysis_Compute @Grain = 'M';

    BEGIN TRAN;
        TRUNCATE TABLE dbo.AnP_DenialMonthlySummary;
        INSERT INTO dbo.AnP_DenialMonthlySummary
              (RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshAnP_DenialMonthly completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';

    EXEC dbo.usp_RefreshAnP_DenialSummaryTiles;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_DenialWeekly
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
    EXEC dbo.usp_AnP_DenialAnalysis_Compute @Grain = 'W';

    BEGIN TRAN;
        TRUNCATE TABLE dbo.AnP_DenialWeeklySummary;
        INSERT INTO dbo.AnP_DenialWeeklySummary
              (RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder,
               IndexLabel, RowLabel, CoveragePct, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshAnP_DenialWeekly completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_DenialList
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), DenialCode NVARCHAR(400), PayerName NVARCHAR(500), CodeRank INT, PayerRank INT,
        ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2), SortOrder INT
    );

    INSERT INTO #r
    EXEC dbo.usp_GetAnP_DenialList @ForceLive = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.AnP_DenialList;
        INSERT INTO dbo.AnP_DenialList
              (RowType, DenialCode, PayerName, CodeRank, PayerRank, ClaimCount, TotalInsuranceBalance, SortOrder, RefreshedAt)
        SELECT RowType, DenialCode, PayerName, CodeRank, PayerRank, ClaimCount, TotalInsuranceBalance, SortOrder, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshAnP_DenialList completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_DenialPlanType
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), PayerType NVARCHAR(200), ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2), SortOrder INT
    );

    INSERT INTO #r
    EXEC dbo.usp_GetAnP_DenialPlanType @ForceLive = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.AnP_DenialPlanType;
        INSERT INTO dbo.AnP_DenialPlanType (RowType, PayerType, ClaimCount, TotalInsuranceBalance, SortOrder, RefreshedAt)
        SELECT RowType, PayerType, ClaimCount, TotalInsuranceBalance, SortOrder, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshAnP_DenialPlanType completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '30_AnalyzePathology_DenialSummary.sql completed.';

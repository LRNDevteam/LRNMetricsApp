/* =============================================================================
   Analyze Pathology - Denial Summary (Denial Analysis Report)
   Database : AnalyzePathology        Prefix : AnP_
   Source   : dbo.ClaimLevelData (Claim Level)

   Client logic (Denial Analysis Report - Requirements):
     1. Monthly Denial Analysis
          Filter  : Denial Code is not blank
          Rows    : Payer Name_Raw, drill down to its Top 3 Denial Codes
                    by Total Insurance Balance
          Columns : Denial Month (from Denial Date)
          Values  : No. of Claims = COUNT(DISTINCT ClaimID),
                    Total Insurance Balance = SUM(TotalInsuranceBalance)
          Sort    : Total Insurance Balance DESC
     2. Weekly Denial Analysis  - as Monthly, columns = Denial Week
                                  (Monday-Sunday ranges of the Denial Date)
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
     vw_AnP_DenialClaims / fn_AnP_DenialClaims   typed + filtered claim rows
     usp_AnP_DenialAnalysis_Compute              Monthly / Weekly engine
     usp_GetAnP_DenialMonthly / _DenialWeekly    read SPs (snapshot or live)
     usp_GetAnP_DenialList / _DenialPlanType     read SPs (snapshot or live)
     usp_GetAnP_DenialFilterOptions              filter dropdown values
     usp_RefreshAnP_Denial*                      snapshot refresh (ingest)
     AnP_DenialMonthlySummary, AnP_DenialWeeklySummary,
     AnP_DenialList, AnP_DenialPlanType          aggregate tables

   Filter parameters (all read SPs):
     @PayerNames / @PayerTypes / @DenialCodes : '|' separated lists
     @DenialFrom / @DenialTo                  : Denial Date range
   With no filter the read SPs return the snapshot table filled at ingest; any
   filter (or @ForceLive = 1) aggregates live through the same logic.

   Monthly / Weekly result contract (one row per row x period):
     RowType      'P' payer, 'C' top-3 denial code under PayerName, 'T' grand total
     PayerName, DenialCode
     PayerRank    payer position by Total Insurance Balance (0 on T)
     CodeRank     1-3 on C rows (0 otherwise)
     PeriodType   'M' month / 'W' week / 'Y' year total (Monthly only) / 'A' all periods
     PeriodKey    'yyyy-MM' / 'yyyy-MM-dd' (week start) / 'yyyy' / ''
     PeriodYear, PeriodStart, PeriodEnd, PeriodLabel
     ClaimCount, TotalInsuranceBalance
     SortOrder    row position (P, its C rows, ..., T last)
     PeriodOrder  column position (months, year total per year, grand total last)
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
   Aggregate tables
   --------------------------------------------------------------------------- */
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
   @Grain 'M' = Denial Month (with year totals), 'W' = Monday-Sunday Denial Week
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

    -- 1900-01-01 is a Monday, so the day offset modulo 7 is the distance back to Monday
    -- regardless of SET DATEFIRST.
    SELECT d.ClaimID,
           d.PayerName,
           d.DenialCode,
           d.TotalInsuranceBalance AS Bal,
           p.PeriodStart,
           YEAR(p.PeriodStart)     AS PeriodYear
    INTO   #b
    FROM   dbo.fn_AnP_DenialClaims(@PayerNames, @PayerTypes, @DenialCodes, @DenialFrom, @DenialTo) d
    CROSS APPLY (SELECT CASE WHEN @Grain = 'W'
                             THEN DATEADD(DAY, -(DATEDIFF(DAY, '19000101', d.DenialDate) % 7), d.DenialDate)
                             ELSE DATEFROMPARTS(YEAR(d.DenialDate), MONTH(d.DenialDate), 1)
                        END AS PeriodStart) p
    WHERE  d.DenialCode IS NOT NULL
      AND  d.DenialDate IS NOT NULL;

    SELECT PayerName,
           ROW_NUMBER() OVER (ORDER BY SUM(Bal) DESC, COUNT(DISTINCT ClaimID) DESC, PayerName) AS PayerRank
    INTO   #pr
    FROM   #b
    GROUP  BY PayerName;

    SELECT PayerName, DenialCode, CodeRank
    INTO   #cr
    FROM  (SELECT PayerName, DenialCode,
                  ROW_NUMBER() OVER (PARTITION BY PayerName
                                     ORDER BY SUM(Bal) DESC, COUNT(DISTINCT ClaimID) DESC, DenialCode) AS CodeRank
           FROM   #b
           GROUP  BY PayerName, DenialCode) r
    WHERE  CodeRank <= 3;

    ;WITH agg AS
    (
        SELECT 'P' AS RowType, b.PayerName, CAST(N'' AS NVARCHAR(400)) AS DenialCode,
               b.PeriodStart, b.PeriodYear,
               GROUPING(b.PeriodStart) AS gP, GROUPING(b.PeriodYear) AS gY,
               COUNT(DISTINCT b.ClaimID) AS ClaimCount, SUM(b.Bal) AS Bal
        FROM   #b b
        GROUP  BY GROUPING SETS ((b.PayerName, b.PeriodYear, b.PeriodStart), (b.PayerName, b.PeriodYear), (b.PayerName))

        UNION ALL

        SELECT 'C', b.PayerName, b.DenialCode,
               b.PeriodStart, b.PeriodYear,
               GROUPING(b.PeriodStart), GROUPING(b.PeriodYear),
               COUNT(DISTINCT b.ClaimID), SUM(b.Bal)
        FROM   #b b
        JOIN   #cr c ON c.PayerName = b.PayerName AND c.DenialCode = b.DenialCode
        GROUP  BY GROUPING SETS ((b.PayerName, b.DenialCode, b.PeriodYear, b.PeriodStart),
                                 (b.PayerName, b.DenialCode, b.PeriodYear),
                                 (b.PayerName, b.DenialCode))

        UNION ALL

        SELECT 'T', N'Grand Total', N'',
               b.PeriodStart, b.PeriodYear,
               GROUPING(b.PeriodStart), GROUPING(b.PeriodYear),
               COUNT(DISTINCT b.ClaimID), SUM(b.Bal)
        FROM   #b b
        GROUP  BY GROUPING SETS ((b.PeriodYear, b.PeriodStart), (b.PeriodYear), ())
    ),
    typed AS
    (
        SELECT a.*,
               CASE WHEN a.gP = 0 THEN @Grain WHEN a.gY = 0 THEN 'Y' ELSE 'A' END AS PeriodType
        FROM   agg a
    ),
    shaped AS
    (
        SELECT t.RowType,
               t.PayerName,
               t.DenialCode,
               ISNULL(pr.PayerRank, 0) AS PayerRank,
               ISNULL(cr.CodeRank, 0)  AS CodeRank,
               t.PeriodType,
               CAST(CASE t.PeriodType
                        WHEN 'M' THEN CONVERT(CHAR(7),  t.PeriodStart, 120)
                        WHEN 'W' THEN CONVERT(CHAR(10), t.PeriodStart, 120)
                        WHEN 'Y' THEN CAST(t.PeriodYear AS VARCHAR(4))
                        ELSE '' END AS VARCHAR(10)) AS PeriodKey,
               CASE WHEN t.PeriodType = 'A' THEN NULL ELSE t.PeriodYear END AS PeriodYear,
               CASE t.PeriodType
                    WHEN 'Y' THEN DATEFROMPARTS(t.PeriodYear, 1, 1)
                    WHEN 'A' THEN NULL
                    ELSE t.PeriodStart END AS PeriodStart,
               CASE t.PeriodType
                    WHEN 'M' THEN EOMONTH(t.PeriodStart)
                    WHEN 'W' THEN DATEADD(DAY, 6, t.PeriodStart)
                    WHEN 'Y' THEN DATEFROMPARTS(t.PeriodYear, 12, 31)
                    ELSE NULL END AS PeriodEnd,
               CAST(CASE t.PeriodType
                        WHEN 'M' THEN LEFT(DATENAME(MONTH, t.PeriodStart), 3)
                        WHEN 'W' THEN CONVERT(VARCHAR(10), t.PeriodStart, 101) + ' - '
                                    + CONVERT(VARCHAR(10), DATEADD(DAY, 6, t.PeriodStart), 101)
                        WHEN 'Y' THEN CAST(t.PeriodYear AS VARCHAR(4)) + ' Total'
                        ELSE 'Grand Total' END AS NVARCHAR(40)) AS PeriodLabel,
               t.ClaimCount,
               CAST(ISNULL(t.Bal, 0) AS DECIMAL(18,2)) AS TotalInsuranceBalance,
               CASE t.RowType
                    WHEN 'T' THEN 2147483647
                    WHEN 'P' THEN pr.PayerRank * 10
                    ELSE pr.PayerRank * 10 + cr.CodeRank END AS RowSeq,
               CASE t.PeriodType WHEN 'Y' THEN 1 WHEN 'A' THEN 2 ELSE 0 END AS PeriodTypeOrder,
               CASE WHEN t.PeriodType = 'A' THEN 9999
                    WHEN @Grain = 'W' THEN 0
                    ELSE t.PeriodYear END AS PeriodYearOrder
        FROM   typed t
        LEFT   JOIN #pr pr ON pr.PayerName = t.PayerName AND t.RowType <> 'T'
        LEFT   JOIN #cr cr ON cr.PayerName = t.PayerName AND cr.DenialCode = t.DenialCode AND t.RowType = 'C'
        WHERE  NOT (@Grain = 'W' AND t.PeriodType = 'Y')
    )
    SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank,
           PeriodType, PeriodKey, PeriodYear, PeriodStart, PeriodEnd, PeriodLabel,
           ClaimCount, TotalInsuranceBalance,
           DENSE_RANK() OVER (ORDER BY RowSeq)                                         AS SortOrder,
           DENSE_RANK() OVER (ORDER BY PeriodYearOrder, PeriodTypeOrder, PeriodStart)  AS PeriodOrder
    FROM   shaped
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
               ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder
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
               ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder
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
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_DenialMonthly
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), PayerName NVARCHAR(500), DenialCode NVARCHAR(400), PayerRank INT, CodeRank INT,
        PeriodType CHAR(1), PeriodKey VARCHAR(10), PeriodYear INT, PeriodStart DATE, PeriodEnd DATE,
        PeriodLabel NVARCHAR(40), ClaimCount INT, TotalInsuranceBalance DECIMAL(18,2),
        SortOrder INT, PeriodOrder INT
    );

    INSERT INTO #r
    EXEC dbo.usp_AnP_DenialAnalysis_Compute @Grain = 'M';

    BEGIN TRAN;
        TRUNCATE TABLE dbo.AnP_DenialMonthlySummary;
        INSERT INTO dbo.AnP_DenialMonthlySummary
              (RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder, GETDATE()
        FROM   #r;
    COMMIT;

    DECLARE @n INT = (SELECT COUNT(*) FROM #r);
    PRINT 'usp_RefreshAnP_DenialMonthly completed - ' + CAST(@n AS NVARCHAR(20)) + ' rows.';
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
        SortOrder INT, PeriodOrder INT
    );

    INSERT INTO #r
    EXEC dbo.usp_AnP_DenialAnalysis_Compute @Grain = 'W';

    BEGIN TRAN;
        TRUNCATE TABLE dbo.AnP_DenialWeeklySummary;
        INSERT INTO dbo.AnP_DenialWeeklySummary
              (RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder, RefreshedAt)
        SELECT RowType, PayerName, DenialCode, PayerRank, CodeRank, PeriodType, PeriodKey, PeriodYear,
               PeriodStart, PeriodEnd, PeriodLabel, ClaimCount, TotalInsuranceBalance, SortOrder, PeriodOrder, GETDATE()
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

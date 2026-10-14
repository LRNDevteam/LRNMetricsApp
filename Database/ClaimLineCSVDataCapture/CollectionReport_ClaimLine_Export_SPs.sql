/* =============================================================================
   CollectionReport_ClaimLine_Export_SPs.sql
   -----------------------------------------------------------------------------
   Claim / Line raw-sheet export stored procedures for the COLLECTION (Summary)
   Report download. These are Collection-specific CLONES of the Production report
   export SPs (ProductionReport_ClaimLine_Export_SPs.sql / usp_Get{Claim,Line}
   LevelExport{Buckets,DataByDateRange}).

   Why a clone instead of reusing the Production SPs (decision 2026-07-31):
     • The Collection report filters by CheckDate, which the Production SPs do not
       support — adding a param there would touch a proc shared by the Production
       report, the dashboard download and ClaimLineCSVDataCapture snapshots.
     • Collection filters Payer/Panel on the SAME columns its filter dropdown is
       built from: Payer = PayerName_Raw, Panel = a lab-specific column
       (PanelType for NorthWest, PanelName for every other lab). The panel column
       is therefore passed in as @PanelColumn (dynamic SQL) rather than hardcoded.

   Filters supported (all existing Collection filters):
     @PayerNames     -> PayerName_Raw          (pipe-delimited, e.g. 'A|B|C')
     @PanelNames     -> @PanelColumn            (pipe-delimited)
     @PanelColumn    -> lab-specific panel column; defaults to PanelName
     @DosFrom/@DosTo -> DateOfService
     @FirstBilledFrom/@FirstBilledTo -> FirstBilledDate   (Collection "First Bill")
     @CheckDateFrom/@CheckDateTo      -> CheckDate         (NEW vs Production)

   Sheet bucketing is identical to the Production export: split purely for sheet
   separation by FirstBilledDate, the UNION of all buckets == the full filtered
   set (small -> single 'All_*' sheet; large -> year/month sheets + an
   'Undated_*' sheet for rows with no usable FirstBilledDate).

   DEPLOY TO: every lab database whose Collection Report includes Claim/Line raw
              sheets (each lab has its own DB, so run once per lab DB).
   Idempotent: all four are CREATE OR ALTER — safe to re-run.

   NOTE: the C# side (LRN.ProductionReports.SqlProductionReportRepository
         .AppendSpExportSheetsToFileAsync) must be deployed too — it now threads
         @CheckDateFrom/@CheckDateTo and @PanelColumn through, and excludes the
         RecordId / FileLogId columns from the written sheet.
   ============================================================================= */

SET NOCOUNT ON;
GO

/* ---- 1) Collection ClaimLevel Buckets ----------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetCollectionClaimLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @PanelColumn      SYSNAME       = N'PanelName',
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,   -- ChargeEnteredDate; unused by Collection, kept for C# param compat
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @CheckDateFrom    DATE          = NULL,
    @CheckDateTo      DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@PanelColumn)), '') IS NULL SET @PanelColumn = N'PanelName';

    -- Temp tables (not table variables) so the dynamic panel-column SELECT can see them.
    -- COLLATE DATABASE_DEFAULT: temp tables otherwise take tempdb's collation, which can differ
    -- from the lab DB's column collation and cause "Cannot resolve the collation conflict" in the
    -- IN (...) comparisons below. DATABASE_DEFAULT forces the lab DB's collation to match the columns.
    CREATE TABLE #PayerList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    -- Full filtered set (INCLUDES rows with a NULL/blank/unparseable FirstBilledDate so
    -- the sheet split never drops them). Panel predicate uses the lab-specific column,
    -- hence dynamic SQL. #Base / #PayerList / #PanelList are visible inside sp_executesql.
    CREATE TABLE #Base (FirstBilledDate DATE NULL, ClaimId NVARCHAR(100) NULL);

    DECLARE @sql NVARCHAR(MAX) = N'
        INSERT INTO #Base (FirstBilledDate, ClaimId)
        SELECT TRY_CAST(FirstBilledDate AS DATE), CAST(ClaimID AS NVARCHAR(100))
        FROM dbo.ClaimLevelData
        WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@PanelColumn) + N',''Unknown''))),200) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
          AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
          AND (@CheckDateFrom   IS NULL OR TRY_CAST(CheckDate         AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo     IS NULL OR TRY_CAST(CheckDate         AS DATE) <= @CheckDateTo);';

    EXEC sp_executesql @sql,
        N'@HasPayerFilter BIT, @HasPanelFilter BIT, @DosFrom DATE, @DosTo DATE,
          @CEDFrom DATE, @CEDTo DATE, @FirstBilledFrom DATE, @FirstBilledTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @HasPayerFilter, @HasPanelFilter, @DosFrom, @DosTo,
        @CEDFrom, @CEDTo, @FirstBilledFrom, @FirstBilledTo, @CheckDateFrom, @CheckDateTo;

    DECLARE @cntClaim   INT = 0;
    DECLARE @cntUndated INT = 0;
    SELECT @cntClaim   = COUNT(*) FROM #Base;
    SELECT @cntUndated = COUNT(*) FROM #Base WHERE FirstBilledDate IS NULL;

    CREATE TABLE #Buckets
    (
        BucketType   VARCHAR(20),
        YearNo       INT           NULL,
        MonthNo      INT           NULL,
        FromDate     DATE          NULL,
        ToDate       DATE          NULL,
        RecordCount  INT,
        SheetName    NVARCHAR(50)
    );

    IF (@cntClaim <= @Threshold)
    BEGIN
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntClaim, 'All_Claim');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Claim'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
            HAVING COUNT(*) > @Threshold
        ),
        MonthCounts AS
        (
            SELECT YEAR(b.FirstBilledDate) AS YearNo,
                   MONTH(b.FirstBilledDate) AS MonthNo,
                   COUNT(*) AS RecordCount
            FROM #Base b
            INNER JOIN LargeYears y ON YEAR(b.FirstBilledDate) = y.YearNo
            GROUP BY YEAR(b.FirstBilledDate), MONTH(b.FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'MONTH', mc.YearNo, mc.MonthNo,
               DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1),
               EOMONTH(DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)),
               mc.RecordCount,
               LEFT(DATENAME(MONTH, DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)), 3)
                   + CAST(mc.YearNo AS VARCHAR(4)) + '_Claim'
        FROM MonthCounts mc;

        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Claim');
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END
GO

/* ---- 2) Collection ClaimLevel Data By Date Range ------------------------ */
CREATE OR ALTER PROCEDURE dbo.usp_GetCollectionClaimLevelExportDataByDateRange
    @FromDate         DATE          = NULL,
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @PanelColumn      SYSNAME       = N'PanelName',
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,   -- ChargeEnteredDate; unused by Collection, kept for C# param compat
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @CheckDateFrom    DATE          = NULL,
    @CheckDateTo      DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'  -- 'ALL' = every row, 'UNDATED' = null-date rows, else date range
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@PanelColumn)), '') IS NULL SET @PanelColumn = N'PanelName';

    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
    BEGIN
        RETURN;   -- backward-compat: no dates + a non-ALL/UNDATED bucket -> empty set, not an error
    END;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;

    -- COLLATE DATABASE_DEFAULT: temp tables otherwise take tempdb's collation, which can differ
    -- from the lab DB's column collation and cause "Cannot resolve the collation conflict" in the
    -- IN (...) comparisons below. DATABASE_DEFAULT forces the lab DB's collation to match the columns.
    CREATE TABLE #PayerList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    -- SELECT * (every column); the C# writer drops RecordId / FileLogId from the sheet.
    -- Panel predicate uses the lab-specific column -> dynamic SQL.
    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT *
        FROM dbo.ClaimLevelData
        WHERE (
                  @BucketType = ''ALL''
               OR (@BucketType = ''UNDATED'' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
               OR (@BucketType NOT IN (''ALL'',''UNDATED'')
                   AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
                   AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
              )
          AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@PanelColumn) + N',''Unknown''))),200) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
          AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
          AND (@CheckDateFrom   IS NULL OR TRY_CAST(CheckDate         AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo     IS NULL OR TRY_CAST(CheckDate         AS DATE) <= @CheckDateTo)
        ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimID;';

    EXEC sp_executesql @sql,
        N'@BucketType VARCHAR(20), @FromDate DATE, @ToDate DATE,
          @HasPayerFilter BIT, @HasPanelFilter BIT, @DosFrom DATE, @DosTo DATE,
          @CEDFrom DATE, @CEDTo DATE, @FirstBilledFrom DATE, @FirstBilledTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @BucketType, @FromDate, @ToDate,
        @HasPayerFilter, @HasPanelFilter, @DosFrom, @DosTo,
        @CEDFrom, @CEDTo, @FirstBilledFrom, @FirstBilledTo, @CheckDateFrom, @CheckDateTo;
END
GO

/* ---- 3) Collection LineLevel Buckets ------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.usp_GetCollectionLineLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @PanelColumn      SYSNAME       = N'PanelName',   -- line table uses Panelname for every lab
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,   -- ChargeEnteredDate; unused by Collection, kept for C# param compat
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @CheckDateFrom    DATE          = NULL,
    @CheckDateTo      DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@PanelColumn)), '') IS NULL SET @PanelColumn = N'PanelName';

    -- COLLATE DATABASE_DEFAULT: temp tables otherwise take tempdb's collation, which can differ
    -- from the lab DB's column collation and cause "Cannot resolve the collation conflict" in the
    -- IN (...) comparisons below. DATABASE_DEFAULT forces the lab DB's collation to match the columns.
    CREATE TABLE #PayerList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    CREATE TABLE #Base (FirstBilledDate DATE NULL, ClaimId NVARCHAR(100) NULL);

    DECLARE @sql NVARCHAR(MAX) = N'
        INSERT INTO #Base (FirstBilledDate, ClaimId)
        SELECT TRY_CAST(FirstBilledDate AS DATE), CAST(ClaimID AS NVARCHAR(100))
        FROM dbo.LineLevelData
        WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@PanelColumn) + N',''Unknown''))),200) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
          AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
          AND (@CheckDateFrom   IS NULL OR TRY_CAST(CheckDate         AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo     IS NULL OR TRY_CAST(CheckDate         AS DATE) <= @CheckDateTo);';

    EXEC sp_executesql @sql,
        N'@HasPayerFilter BIT, @HasPanelFilter BIT, @DosFrom DATE, @DosTo DATE,
          @CEDFrom DATE, @CEDTo DATE, @FirstBilledFrom DATE, @FirstBilledTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @HasPayerFilter, @HasPanelFilter, @DosFrom, @DosTo,
        @CEDFrom, @CEDTo, @FirstBilledFrom, @FirstBilledTo, @CheckDateFrom, @CheckDateTo;

    DECLARE @cntLine    INT = 0;
    DECLARE @cntUndated INT = 0;
    SELECT @cntLine    = COUNT(*) FROM #Base;
    SELECT @cntUndated = COUNT(*) FROM #Base WHERE FirstBilledDate IS NULL;

    CREATE TABLE #Buckets
    (
        BucketType   VARCHAR(20),
        YearNo       INT           NULL,
        MonthNo      INT           NULL,
        FromDate     DATE          NULL,
        ToDate       DATE          NULL,
        RecordCount  INT,
        SheetName    NVARCHAR(50)
    );

    IF (@cntLine <= @Threshold)
    BEGIN
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntLine, 'All_Line');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Line'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
            HAVING COUNT(*) > @Threshold
        ),
        MonthCounts AS
        (
            SELECT YEAR(b.FirstBilledDate) AS YearNo,
                   MONTH(b.FirstBilledDate) AS MonthNo,
                   COUNT(*) AS RecordCount
            FROM #Base b
            INNER JOIN LargeYears y ON YEAR(b.FirstBilledDate) = y.YearNo
            GROUP BY YEAR(b.FirstBilledDate), MONTH(b.FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'MONTH', mc.YearNo, mc.MonthNo,
               DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1),
               EOMONTH(DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)),
               mc.RecordCount,
               LEFT(DATENAME(MONTH, DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)), 3)
                   + CAST(mc.YearNo AS VARCHAR(4)) + '_Line'
        FROM MonthCounts mc;

        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Line');
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END
GO

/* ---- 4) Collection LineLevel Data By Date Range ------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetCollectionLineLevelExportDataByDateRange
    @FromDate         DATE          = NULL,
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @PanelColumn      SYSNAME       = N'PanelName',
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,   -- ChargeEnteredDate; unused by Collection, kept for C# param compat
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @CheckDateFrom    DATE          = NULL,
    @CheckDateTo      DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@PanelColumn)), '') IS NULL SET @PanelColumn = N'PanelName';

    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
    BEGIN
        RETURN;
    END;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;

    -- COLLATE DATABASE_DEFAULT: temp tables otherwise take tempdb's collation, which can differ
    -- from the lab DB's column collation and cause "Cannot resolve the collation conflict" in the
    -- IN (...) comparisons below. DATABASE_DEFAULT forces the lab DB's collation to match the columns.
    CREATE TABLE #PayerList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT *
        FROM dbo.LineLevelData
        WHERE (
                  @BucketType = ''ALL''
               OR (@BucketType = ''UNDATED'' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
               OR (@BucketType NOT IN (''ALL'',''UNDATED'')
                   AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
                   AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
              )
          AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@PanelColumn) + N',''Unknown''))),200) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
          AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
          AND (@CheckDateFrom   IS NULL OR TRY_CAST(CheckDate         AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo     IS NULL OR TRY_CAST(CheckDate         AS DATE) <= @CheckDateTo)
        ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimID;';

    EXEC sp_executesql @sql,
        N'@BucketType VARCHAR(20), @FromDate DATE, @ToDate DATE,
          @HasPayerFilter BIT, @HasPanelFilter BIT, @DosFrom DATE, @DosTo DATE,
          @CEDFrom DATE, @CEDTo DATE, @FirstBilledFrom DATE, @FirstBilledTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @BucketType, @FromDate, @ToDate,
        @HasPayerFilter, @HasPanelFilter, @DosFrom, @DosTo,
        @CEDFrom, @CEDTo, @FirstBilledFrom, @FirstBilledTo, @CheckDateFrom, @CheckDateTo;
END
GO

PRINT 'CollectionReport_ClaimLine_Export_SPs.sql completed (4 procedures created/altered).';
GO

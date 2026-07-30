/* =============================================================================
   ProductionReport_ClaimLine_Export_SPs.sql
   -----------------------------------------------------------------------------
   Generic Claim/Line export stored procedures for the Production (Summary) Report
   download. These are NOT NorthWest-specific — they run against dbo.ClaimLevelData
   / dbo.LineLevelData and are used by the standard + Augustus report paths, the
   dashboard download, and ClaimLineCSVDataCapture's snapshot generation.

   DEPLOY TO: EVERY lab database that produces a Production Report with Claim/Line
              sheets (each lab has its own DB, so run this once per lab DB).

   Idempotent: all four are CREATE OR ALTER — safe to re-run.

   ---------------------------------------------------------------------------
   FIX (tag: CVEXP-ALL, 2026-07-27)
   ---------------------------------------------------------------------------
   Bug: the export split the data into sheets by FirstBilledDate, and that split
        was also FILTERING. Rows with a NULL / blank / unparseable (or future)
        FirstBilledDate landed in no bucket and were silently dropped from the
        downloaded Excel.

   Fix: the split is now purely for sheet separation — the union of all buckets
        always equals the full table.
          • Buckets include undated rows.
          • Small dataset  -> a single 'ALL' sheet that returns EVERY row.
          • Large dataset  -> year/month sheets for dated rows PLUS an
                              'Undated_Claim' / 'Undated_Line' sheet.
          • Data SP gains @BucketType: 'ALL' = every row, 'UNDATED' = null-date
                              rows, otherwise the normal date-range slice.
          • Backward compatible: a pre-fix caller that receives the new UNDATED
                              bucket (null dates, no @BucketType) gets an empty
                              set instead of an error — so deploying this script
                              cannot disturb an un-rebuilt ClaimLineCSVDataCapture.

   NOTE: the C# side (LRN.ProductionReports.SqlProductionReportRepository) must
         also be deployed for the download to fetch the ALL/UNDATED buckets —
         i.e. redeploy LRN.ReportWorker and LabMetricsDashboard alongside this.

   This file is a surgical extract of the four procedures from
   ClaimLineCSVDataCapture\Sql\NorthWest\14_NorthWest_ReadSPs.sql; the other 10
   procedures in that file were NOT changed.
   ============================================================================= */

SET NOCOUNT ON;
GO

/* ---- 1) ClaimLevel Buckets -------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- >>> CVEXP-ALL (2026-07-27): claim/line export must write EVERY row; the buckets are only
    --     for splitting into sheets. #Base now INCLUDES rows with a NULL/blank/unparseable
    --     FirstBilledDate (previously excluded, which silently dropped those claims).
    --     REVERT: restore FirstBilledDate DATE NOT NULL + the "WHERE ... IS NOT NULL" line.
    CREATE TABLE #Base
    (
        FirstBilledDate DATE          NULL,   -- CVEXP-ALL: was NOT NULL
        ClaimId         NVARCHAR(100) NULL
    );

    INSERT INTO #Base (FirstBilledDate, ClaimId)
    SELECT
        TRY_CAST(FirstBilledDate AS DATE),
        CAST(ClaimId AS NVARCHAR(100))
    FROM dbo.ClaimLevelData
    WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PanelType,'Unknown'))),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo);
    -- <<< END CVEXP-ALL

    DECLARE @cntClaim   INT = 0;
    DECLARE @cntUndated INT = 0;   -- CVEXP-ALL: rows with no usable FirstBilledDate
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
        -- CVEXP-ALL: single sheet holds EVERYTHING (dated + undated); data SP returns all rows for 'ALL'.
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntClaim, 'All_Claim');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL   -- CVEXP-ALL: undated rows handled by the UNDATED bucket below
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               -- CVEXP-ALL: placeholder/garbage dates that parse to year 1900 are labelled 'Other_' instead of '1900_'.
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Claim'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL   -- CVEXP-ALL
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

        -- >>> CVEXP-ALL (2026-07-27): dedicated sheet for rows with no usable FirstBilledDate,
        --     so the split path never drops them. REVERT: delete this IF block.
        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Claim');
        -- <<< END CVEXP-ALL
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END
GO

/* ---- 2) ClaimLevel Data By Date Range -------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelExportDataByDateRange
    @FromDate         DATE          = NULL,   -- CVEXP-ALL: nullable now (ALL/UNDATED buckets pass no dates)
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'  -- CVEXP-ALL: 'ALL' = every row, 'UNDATED' = null-date rows, else date range
AS
BEGIN
    SET NOCOUNT ON;

    -- >>> CVEXP-ALL (2026-07-27): only the date-RANGE buckets need From/To. ALL and UNDATED
    --     buckets deliberately pass no dates. REVERT: restore the unconditional NULL check.
    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
    BEGIN
        -- CVEXP-ALL: backward-compat — a pre-fix caller (e.g. an un-rebuilt ClaimLineCSVDataCapture)
        -- that receives the new UNDATED bucket passes null dates without @BucketType. Return an
        -- empty set instead of raising, so deploying these SPs never disturbs that app.
        RETURN;
    END;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;
    -- <<< END CVEXP-ALL

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT *
    FROM dbo.ClaimLevelData
    -- >>> CVEXP-ALL (2026-07-27): row inclusion by bucket type.
    --     ALL     -> every row (no FirstBilledDate filter)
    --     UNDATED -> only rows with no usable FirstBilledDate
    --     RANGE   -> original date-range slice
    --     REVERT: restore the two-line FirstBilledDate BETWEEN predicate.
    WHERE (
              @BucketType = 'ALL'
           OR (@BucketType = 'UNDATED' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
           OR (@BucketType NOT IN ('ALL','UNDATED')
               AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
               AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
          )
    -- <<< END CVEXP-ALL
      AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PanelType,'Unknown'))),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimId;
END
GO

/* ---- 3) LineLevel Buckets --------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- >>> CVEXP-ALL (2026-07-27): include rows with NULL/blank/unparseable FirstBilledDate so no line is dropped.
    --     REVERT: restore FirstBilledDate DATE NOT NULL + the "WHERE ... IS NOT NULL" line.
    CREATE TABLE #Base
    (
        FirstBilledDate DATE          NULL,   -- CVEXP-ALL: was NOT NULL
        ClaimId         NVARCHAR(100) NULL
    );

    INSERT INTO #Base (FirstBilledDate, ClaimId)
    SELECT
        TRY_CAST(FirstBilledDate AS DATE),
        CAST(ClaimId AS NVARCHAR(100))
    FROM dbo.LineLevelData
    WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo);
    -- <<< END CVEXP-ALL

    DECLARE @cntLine    INT = 0;
    DECLARE @cntUndated INT = 0;   -- CVEXP-ALL
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
        -- CVEXP-ALL: single sheet holds EVERYTHING (dated + undated); data SP returns all rows for 'ALL'.
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntLine, 'All_Line');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL   -- CVEXP-ALL: undated rows handled by the UNDATED bucket below
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               -- CVEXP-ALL: placeholder/garbage dates that parse to year 1900 are labelled 'Other_' instead of '1900_'.
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Line'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL   -- CVEXP-ALL
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

        -- >>> CVEXP-ALL (2026-07-27): dedicated sheet for rows with no usable FirstBilledDate.
        --     REVERT: delete this IF block.
        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Line');
        -- <<< END CVEXP-ALL
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END
GO

/* ---- 4) LineLevel Data By Date Range --------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelExportDataByDateRange
    @FromDate         DATE          = NULL,   -- CVEXP-ALL: nullable now (ALL/UNDATED buckets pass no dates)
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'  -- CVEXP-ALL: 'ALL' = every row, 'UNDATED' = null-date rows, else date range
AS
BEGIN
    SET NOCOUNT ON;

    -- >>> CVEXP-ALL (2026-07-27): only date-RANGE buckets need From/To. REVERT: restore unconditional NULL check.
    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
    BEGIN
        -- CVEXP-ALL: backward-compat — a pre-fix caller (e.g. an un-rebuilt ClaimLineCSVDataCapture)
        -- that receives the new UNDATED bucket passes null dates without @BucketType. Return an
        -- empty set instead of raising, so deploying these SPs never disturbs that app.
        RETURN;
    END;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;
    -- <<< END CVEXP-ALL

    DECLARE @PayerList TABLE (Value NVARCHAR(200) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(200) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT *
    FROM dbo.LineLevelData
    -- >>> CVEXP-ALL (2026-07-27): ALL = every row, UNDATED = null-date rows, RANGE = date slice.
    --     REVERT: restore the two-line FirstBilledDate BETWEEN predicate.
    WHERE (
              @BucketType = 'ALL'
           OR (@BucketType = 'UNDATED' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
           OR (@BucketType NOT IN ('ALL','UNDATED')
               AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
               AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
          )
    -- <<< END CVEXP-ALL
      AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),200) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))),200) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
      AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimId;
END
GO

PRINT 'ProductionReport_ClaimLine_Export_SPs.sql completed (4 procedures created/altered).';
GO

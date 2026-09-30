/*
   LabDemo / LRNDemoLab — FIX regen NW Panel + CPT (schema-safe)
   ---------------------------------------------------------------
   Fixes from prior run:
     - Invalid column PanelType on LineLevelData
     - Refresh rows=0 (filters too strict / wrong date columns)
     - Table-var PK 1000-byte warnings

   Target DB name observed: LRNDemoLab
*/

USE LRNDemoLab;   -- change if needed
GO

SET NOCOUNT ON;
PRINT '=== FIX Regen NW Panel + CPT on ' + DB_NAME() + ' ===';

/* ---------- 0) Schema + data diagnostics ---------- */
PRINT '--- ClaimLevelData ---';
IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NULL
    PRINT 'MISSING ClaimLevelData';
ELSE
BEGIN
    DECLARE @c NVARCHAR(MAX) = N'
    SELECT COUNT(*) AS ClaimRows,
           SUM(CASE WHEN TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL THEN 1 ELSE 0 END) AS HasChargeEntered
    FROM dbo.ClaimLevelData;
    SELECT TOP 5 ChargeEnteredDate, FirstBilledDate
    FROM dbo.ClaimLevelData;';
    EXEC sys.sp_executesql @c;
END

PRINT '--- LineLevelData ---';
IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NULL
    PRINT 'MISSING LineLevelData';
ELSE
BEGIN
    DECLARE @l NVARCHAR(MAX) = N'
    SELECT COUNT(*) AS LineRows,
           SUM(CASE WHEN TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL THEN 1 ELSE 0 END) AS HasChargeEntered,
           SUM(CASE WHEN NULLIF(LTRIM(RTRIM(CPTCode)),'''') IS NOT NULL THEN 1 ELSE 0 END) AS HasCpt
    FROM dbo.LineLevelData;
    SELECT TOP 5 LEFT(CPTCode,20) AS CPTCode, ChargeEnteredDate, FirstBilledDate
    FROM dbo.LineLevelData;';
    EXEC sys.sp_executesql @l;
END
GO

/* ---------- helpers: resolve panel expression per table ---------- */
-- ClaimLevelData panel: prefer Panelname, else PanelType, else Unknown
-- LineLevelData panel: Panelname only (no PanelType on Cove/LabDemo)

/* =====================================================================
   A) Panel Breakdown With Payers
   ===================================================================== */
IF OBJECT_ID(N'dbo.NW_PanelBreakdownWithPayers', N'SN') IS NOT NULL
    DROP SYNONYM dbo.NW_PanelBreakdownWithPayers;

IF OBJECT_ID(N'dbo.NW_PanelBreakdownWithPayers', N'U') IS NULL
CREATE TABLE dbo.NW_PanelBreakdownWithPayers
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName       NVARCHAR(500)   NOT NULL,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PanelBreakdownWithPayers
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NULL
    BEGIN
        RAISERROR('ClaimLevelData missing', 16, 1);
        RETURN;
    END

    DECLARE @HasPanelname BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','Panelname') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPanelType BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','PanelType') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPayerRaw  BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','PayerName_Raw') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPayer     BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','PayerName') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasClaimId   BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','ClaimID') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasStatus    BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','ClaimStatus') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @PanelExpr NVARCHAR(400) =
        CASE
            WHEN @HasPanelname = 1 AND @HasPanelType = 1
                THEN N'COALESCE(NULLIF(LTRIM(RTRIM(Panelname)),''''), NULLIF(LTRIM(RTRIM(PanelType)),''''), N''Unknown'')'
            WHEN @HasPanelname = 1
                THEN N'COALESCE(NULLIF(LTRIM(RTRIM(Panelname)),''''), N''Unknown'')'
            WHEN @HasPanelType = 1
                THEN N'COALESCE(NULLIF(LTRIM(RTRIM(PanelType)),''''), N''Unknown'')'
            ELSE N'N''Unknown'''
        END;

    DECLARE @PayerExpr NVARCHAR(300) =
        CASE
            WHEN @HasPayerRaw = 1 THEN N'LTRIM(RTRIM(ISNULL(PayerName_Raw, ''Unknown'')))'
            WHEN @HasPayer = 1    THEN N'LTRIM(RTRIM(ISNULL(PayerName, ''Unknown'')))'
            ELSE N'N''Unknown'''
        END;

    DECLARE @ClaimExpr NVARCHAR(200) =
        CASE WHEN @HasClaimId = 1 THEN N'NULLIF(LTRIM(RTRIM(ClaimID)), '''')' ELSE N'NULL' END;

    -- Prefer ChargeEnteredDate month; require a parseable charge-entered date.
    -- FirstBilledDate preferred when present, but DO NOT require it (demo often blank).
    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH Base AS
    (
        SELECT
            ' + @PanelExpr + N' AS PanelName,
            ' + @PayerExpr + N' AS PayerName,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            ' + @ClaimExpr + N' AS ClaimKey,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2)) AS ChargeAmountValue
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(ChargeEnteredDate, ''''))) <> ''''
    )
    SELECT PanelName, PayerName, BilledYearMonth,
           COUNT(DISTINCT ClaimKey) AS ClaimCount,
           ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    INTO #Raw
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) BETWEEN ''2018'' AND ''2099''
    GROUP BY PanelName, PayerName, BilledYearMonth;

    TRUNCATE TABLE dbo.NW_PanelBreakdownWithPayers;
    INSERT INTO dbo.NW_PanelBreakdownWithPayers
        (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY BilledYearMonth, PanelName, PayerName;
    DROP TABLE IF EXISTS #Raw;
    ';

    EXEC sys.sp_executesql @sql;
    DECLARE @n INT = (SELECT COUNT(*) FROM dbo.NW_PanelBreakdownWithPayers);
    PRINT 'usp_RefreshNW_PanelBreakdownWithPayers rows=' + CAST(@n AS NVARCHAR(20));
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PanelBreakdownWithPayers
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.NW_PanelBreakdownWithPayers)
            EXEC dbo.usp_RefreshNW_PanelBreakdownWithPayers;

        SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.NW_PanelBreakdownWithPayers
        ORDER BY PanelName, PayerName, BilledYearMonth;
        RETURN;
    END

    -- Filtered path: live, schema-safe
    DECLARE @HasPanelname BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','Panelname') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPanelType BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','PanelType') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPayerRaw  BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','PayerName_Raw') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPayer     BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','PayerName') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasClaimId   BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','ClaimID') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasDos       BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','DateOfService') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasFb        BIT = CASE WHEN COL_LENGTH('dbo.ClaimLevelData','FirstBilledDate') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @PanelExpr NVARCHAR(400) =
        CASE
            WHEN @HasPanelname = 1 AND @HasPanelType = 1
                THEN N'COALESCE(NULLIF(LTRIM(RTRIM(Panelname)),''''), NULLIF(LTRIM(RTRIM(PanelType)),''''), N''Unknown'')'
            WHEN @HasPanelname = 1 THEN N'COALESCE(NULLIF(LTRIM(RTRIM(Panelname)),''''), N''Unknown'')'
            WHEN @HasPanelType = 1 THEN N'COALESCE(NULLIF(LTRIM(RTRIM(PanelType)),''''), N''Unknown'')'
            ELSE N'N''Unknown'''
        END;
    DECLARE @PayerExpr NVARCHAR(300) =
        CASE WHEN @HasPayerRaw = 1 THEN N'LTRIM(RTRIM(ISNULL(PayerName_Raw, ''Unknown'')))'
             WHEN @HasPayer = 1 THEN N'LTRIM(RTRIM(ISNULL(PayerName, ''Unknown'')))'
             ELSE N'N''Unknown''' END;
    DECLARE @ClaimExpr NVARCHAR(200) =
        CASE WHEN @HasClaimId = 1 THEN N'NULLIF(LTRIM(RTRIM(ClaimID)), '''')' ELSE N'NULL' END;

    DECLARE @sql NVARCHAR(MAX) = N'
    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '''') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450)
        FROM STRING_SPLIT(@PayerNames, ''|'')
        WHERE NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '''') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450)
        FROM STRING_SPLIT(@PanelNames, ''|'')
        WHERE NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Base AS
    (
        SELECT
            ' + @PanelExpr + N' AS PanelName,
            ' + @PayerExpr + N' AS PayerName,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            ' + @ClaimExpr + N' AS ClaimKey,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2)) AS ChargeAmountValue
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND (@HasPayerFilter = 0 OR ' + @PayerExpr + N' IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR ' + @PanelExpr + N' IN (SELECT Value FROM @PanelList))
          ' + CASE WHEN @HasDos = 1 THEN N'
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)' ELSE N'' END + N'
          AND (@FirstBillFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          ' + CASE WHEN @HasFb = 1 THEN N'
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)' ELSE N'' END + N'
    )
    SELECT PanelName, PayerName, BilledYearMonth,
           COUNT(DISTINCT ClaimKey) AS ClaimCount,
           ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) BETWEEN ''2018'' AND ''2099''
    GROUP BY PanelName, PayerName, BilledYearMonth
    ORDER BY PanelName, PayerName, BilledYearMonth;
    ';

    EXEC sys.sp_executesql @sql,
        N'@PayerNames NVARCHAR(MAX), @PanelNames NVARCHAR(MAX),
          @DosFrom DATE, @DosTo DATE, @FirstBillFrom DATE, @FirstBillTo DATE,
          @FirstBilledFrom DATE, @FirstBilledTo DATE',
        @PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo,
        @FirstBilledFrom, @FirstBilledTo;
END
GO

/* =====================================================================
   B) CPT Breakdown By Source — NO PanelType on LineLevelData
   ===================================================================== */
IF OBJECT_ID(N'dbo.NW_CPTBreakdownBySource', N'SN') IS NOT NULL
    DROP SYNONYM dbo.NW_CPTBreakdownBySource;

IF OBJECT_ID(N'dbo.NW_CPTBreakdownBySource', N'U') IS NULL
CREATE TABLE dbo.NW_CPTBreakdownBySource
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    SourceName      NVARCHAR(20)    NOT NULL,
    CPTCode         NVARCHAR(50)    NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    CPTCount        INT             NOT NULL DEFAULT 0,
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CPTBreakdownBySource
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NULL
    BEGIN
        PRINT 'SKIP CPT refresh — LineLevelData missing';
        RETURN;
    END

    DECLARE @HasSource BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','Source') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasUnits  BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','Units') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasCharge BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','ChargeAmount') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasFb     BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','FirstBilledDate') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasCe     BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','ChargeEnteredDate') IS NOT NULL THEN 1 ELSE 0 END;

    IF @HasCe = 0
    BEGIN
        PRINT 'SKIP CPT refresh — ChargeEnteredDate missing on LineLevelData';
        RETURN;
    END

    DECLARE @SourceExpr NVARCHAR(400) =
        CASE WHEN @HasSource = 1 THEN N'
            CASE
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '''')))) LIKE ''WEBPM%'' THEN N''WebPM''
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '''')))) LIKE ''DAQ%''   THEN N''DAQ''
                ELSE N''All''
            END'
        ELSE N'N''All''' END;

    DECLARE @UnitsExpr NVARCHAR(200) =
        CASE WHEN @HasUnits = 1 THEN N'TRY_CAST(Units AS DECIMAL(18,2))' ELSE N'CAST(1 AS DECIMAL(18,2))' END;
    DECLARE @ChargeExpr NVARCHAR(200) =
        CASE WHEN @HasCharge = 1 THEN N'TRY_CAST(ChargeAmount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END;

    -- Prefer billed lines; if that yields nothing, fall back to all lines with ChargeEnteredDate
    -- Demo: do not require FirstBilledDate (often blank on restored Cove demo data).
    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH Base AS
    (
        SELECT
            ' + @SourceExpr + N' AS SourceName,
            LTRIM(RTRIM(ISNULL(CPTCode, ''Unknown''))) AS CPTCode,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            ' + @UnitsExpr + N' AS UnitsValue,
            ' + @ChargeExpr + N' AS ChargeAmountValue
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '''') IS NOT NULL
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
    )
    SELECT SourceName, CPTCode, BilledYearMonth,
           COUNT(*) AS CPTCount,
           ISNULL(SUM(UnitsValue), 0) AS BilledUnits,
           ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    INTO #Raw
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) BETWEEN ''2018'' AND ''2099''
    GROUP BY SourceName, CPTCode, BilledYearMonth;

    TRUNCATE TABLE dbo.NW_CPTBreakdownBySource;
    INSERT INTO dbo.NW_CPTBreakdownBySource
        (SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw;
    DROP TABLE IF EXISTS #Raw;
    ';

    EXEC sys.sp_executesql @sql;
    DECLARE @n INT = (SELECT COUNT(*) FROM dbo.NW_CPTBreakdownBySource);
    PRINT 'usp_RefreshNW_CPTBreakdownBySource rows=' + CAST(@n AS NVARCHAR(20));
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CPTBreakdownBySource
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.NW_CPTBreakdownBySource)
            EXEC dbo.usp_RefreshNW_CPTBreakdownBySource;

        SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM dbo.NW_CPTBreakdownBySource
        ORDER BY SourceName, CPTCode, BilledYearMonth;
        RETURN;
    END

    IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NULL
    BEGIN
        SELECT CAST(NULL AS NVARCHAR(20)) AS SourceName, CAST(NULL AS NVARCHAR(50)) AS CPTCode,
               CAST(NULL AS NVARCHAR(7)) AS BilledYearMonth, CAST(0 AS INT) AS CPTCount,
               CAST(0 AS DECIMAL(18,2)) AS BilledUnits, CAST(0 AS DECIMAL(18,2)) AS TotalCharges
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @HasSource    BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','Source') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasUnits     BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','Units') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasCharge    BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','ChargeAmount') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasFb        BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','FirstBilledDate') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasDos       BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','DateOfService') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPanelname BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','Panelname') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPayerRaw  BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','PayerName_Raw') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPayer     BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','PayerName') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @SourceExpr NVARCHAR(400) =
        CASE WHEN @HasSource = 1 THEN N'
            CASE
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '''')))) LIKE ''WEBPM%'' THEN N''WebPM''
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '''')))) LIKE ''DAQ%''   THEN N''DAQ''
                ELSE N''All''
            END' ELSE N'N''All''' END;
    DECLARE @UnitsExpr NVARCHAR(200) =
        CASE WHEN @HasUnits = 1 THEN N'TRY_CAST(Units AS DECIMAL(18,2))' ELSE N'CAST(1 AS DECIMAL(18,2))' END;
    DECLARE @ChargeExpr NVARCHAR(200) =
        CASE WHEN @HasCharge = 1 THEN N'TRY_CAST(ChargeAmount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END;
    DECLARE @PanelExpr NVARCHAR(300) =
        CASE WHEN @HasPanelname = 1 THEN N'COALESCE(NULLIF(LTRIM(RTRIM(Panelname)),''''), N''Unknown'')' ELSE N'N''Unknown''' END;
    DECLARE @PayerExpr NVARCHAR(300) =
        CASE WHEN @HasPayerRaw = 1 THEN N'LTRIM(RTRIM(ISNULL(PayerName_Raw, ''Unknown'')))'
             WHEN @HasPayer = 1 THEN N'LTRIM(RTRIM(ISNULL(PayerName, ''Unknown'')))'
             ELSE N'N''Unknown''' END;

    DECLARE @sql NVARCHAR(MAX) = N'
    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '''') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450)
        FROM STRING_SPLIT(@PayerNames, ''|'') WHERE NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '''') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450)
        FROM STRING_SPLIT(@PanelNames, ''|'') WHERE NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Base AS
    (
        SELECT
            ' + @SourceExpr + N' AS SourceName,
            LTRIM(RTRIM(ISNULL(CPTCode, ''Unknown''))) AS CPTCode,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            ' + @UnitsExpr + N' AS UnitsValue,
            ' + @ChargeExpr + N' AS ChargeAmountValue
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '''') IS NOT NULL
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND (@HasPayerFilter = 0 OR ' + @PayerExpr + N' IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR ' + @PanelExpr + N' IN (SELECT Value FROM @PanelList))
          ' + CASE WHEN @HasDos = 1 THEN N'
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)' ELSE N'' END + N'
          AND (@FirstBillFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          ' + CASE WHEN @HasFb = 1 THEN N'
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)' ELSE N'' END + N'
    )
    SELECT SourceName, CPTCode, BilledYearMonth,
           COUNT(*) AS CPTCount,
           ISNULL(SUM(UnitsValue), 0) AS BilledUnits,
           ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) BETWEEN ''2018'' AND ''2099''
    GROUP BY SourceName, CPTCode, BilledYearMonth
    ORDER BY SourceName, CPTCode, BilledYearMonth;
    ';

    EXEC sys.sp_executesql @sql,
        N'@PayerNames NVARCHAR(MAX), @PanelNames NVARCHAR(MAX),
          @DosFrom DATE, @DosTo DATE, @FirstBillFrom DATE, @FirstBillTo DATE,
          @FirstBilledFrom DATE, @FirstBilledTo DATE',
        @PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo,
        @FirstBilledFrom, @FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CPTBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetNW_CPTBreakdownBySource
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
END
GO

/* ---------- Refresh + smoke ---------- */
EXEC dbo.usp_RefreshNW_PanelBreakdownWithPayers;
EXEC dbo.usp_RefreshNW_CPTBreakdownBySource;
GO

SELECT 'Panel' AS Kind, COUNT(*) AS Rows FROM dbo.NW_PanelBreakdownWithPayers
UNION ALL
SELECT 'CPT', COUNT(*) FROM dbo.NW_CPTBreakdownBySource;

SELECT TOP 15 BilledYearMonth, COUNT(*) AS RowCnt, SUM(ClaimCount) AS Claims
FROM dbo.NW_PanelBreakdownWithPayers
GROUP BY BilledYearMonth
ORDER BY BilledYearMonth;

SELECT TOP 15 SourceName, COUNT(*) AS RowCnt, SUM(CPTCount) AS CptLines
FROM dbo.NW_CPTBreakdownBySource
GROUP BY SourceName;

EXEC dbo.usp_GetNW_PanelBreakdownWithPayers;
EXEC dbo.usp_GetNW_CPTBreakdownBySource;
GO

PRINT '=== FIX complete. If both counts are still 0, ClaimLevelData/LineLevelData have no usable ChargeEnteredDate rows. ===';
GO

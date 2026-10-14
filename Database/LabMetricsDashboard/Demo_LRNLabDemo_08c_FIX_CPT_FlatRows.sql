/*
   LRNDemoLab — FIX CPT Breakdown flat rows (SQL only)
   ----------------------------------------------------
   Symptom: CPT tab shows a single row "All" + Grand Total, no CPT codes.

   Cause: LabDemo uses NW GetCptBreakdown SP (Source → CPT hierarchy), but the
   UI only expands DAQ/WebPM children when IsNorthWestLab=true. For LRNLabDemo
   it renders CptBreakdownRows flat — so only the Source parent ("All") appears.

   Fix: return SourceName = CPTCode so each CPT becomes a top-level row in the
   NW reader (and therefore appears in the flat table).

   Run on LRNDemoLab. Safe to re-run.
*/

USE LRNDemoLab;
GO

SET NOCOUNT ON;
PRINT '=== FIX CPT flat rows on ' + DB_NAME() + ' ===';

IF OBJECT_ID(N'dbo.NW_CPTBreakdownBySource', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.NW_CPTBreakdownBySource
    (
        SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
        SourceName      NVARCHAR(50)    NOT NULL,  -- stores CPTCode for LabDemo flat UI
        CPTCode         NVARCHAR(50)    NOT NULL,
        BilledYearMonth NVARCHAR(7)     NOT NULL,
        CPTCount        INT             NOT NULL DEFAULT 0,
        BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
        TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
        RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
    );
END
GO

-- Widen SourceName if older table used NVARCHAR(20)
IF COL_LENGTH('dbo.NW_CPTBreakdownBySource', 'SourceName') IS NOT NULL
   AND COL_LENGTH('dbo.NW_CPTBreakdownBySource', 'SourceName') < 100
BEGIN
    ALTER TABLE dbo.NW_CPTBreakdownBySource ALTER COLUMN SourceName NVARCHAR(50) NOT NULL;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CPTBreakdownBySource
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NULL
    BEGIN
        PRINT 'SKIP — LineLevelData missing';
        RETURN;
    END

    DECLARE @HasUnits  BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','Units') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasCharge BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','ChargeAmount') IS NOT NULL THEN 1 ELSE 0 END;

    DECLARE @UnitsExpr NVARCHAR(200) =
        CASE WHEN @HasUnits = 1 THEN N'TRY_CAST(Units AS DECIMAL(18,2))' ELSE N'CAST(1 AS DECIMAL(18,2))' END;
    DECLARE @ChargeExpr NVARCHAR(200) =
        CASE WHEN @HasCharge = 1 THEN N'TRY_CAST(ChargeAmount AS DECIMAL(18,2))' ELSE N'CAST(0 AS DECIMAL(18,2))' END;

    -- SourceName intentionally = CPTCode (LabDemo flat CPT UI)
    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH Base AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(CPTCode, ''Unknown''))) AS CPTCode,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            ' + @UnitsExpr + N' AS UnitsValue,
            ' + @ChargeExpr + N' AS ChargeAmountValue
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '''') IS NOT NULL
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
    )
    SELECT
        CPTCode AS SourceName,
        CPTCode,
        BilledYearMonth,
        COUNT(*) AS CPTCount,
        ISNULL(SUM(UnitsValue), 0) AS BilledUnits,
        ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    INTO #Raw
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) BETWEEN ''2018'' AND ''2099''
    GROUP BY CPTCode, BilledYearMonth;

    TRUNCATE TABLE dbo.NW_CPTBreakdownBySource;
    INSERT INTO dbo.NW_CPTBreakdownBySource
        (SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw;
    DROP TABLE IF EXISTS #Raw;
    ';

    EXEC sys.sp_executesql @sql;

    DECLARE @RowCnt INT = (SELECT COUNT(*) FROM dbo.NW_CPTBreakdownBySource);
    DECLARE @CptCnt INT = (SELECT COUNT(DISTINCT CPTCode) FROM dbo.NW_CPTBreakdownBySource);
    PRINT 'Refresh CPT rows=' + CAST(@RowCnt AS NVARCHAR(20));
    PRINT 'Distinct CPT codes=' + CAST(@CptCnt AS NVARCHAR(20));
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

        -- SourceName = CPTCode so flat UI lists each CPT
        SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM dbo.NW_CPTBreakdownBySource
        ORDER BY CPTCode, BilledYearMonth;
        RETURN;
    END

    IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NULL
    BEGIN
        SELECT CAST(NULL AS NVARCHAR(50)) AS SourceName, CAST(NULL AS NVARCHAR(50)) AS CPTCode,
               CAST(NULL AS NVARCHAR(7)) AS BilledYearMonth, CAST(0 AS INT) AS CPTCount,
               CAST(0 AS DECIMAL(18,2)) AS BilledUnits, CAST(0 AS DECIMAL(18,2)) AS TotalCharges
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @HasUnits     BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','Units') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasCharge    BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','ChargeAmount') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasFb        BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','FirstBilledDate') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasDos       BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','DateOfService') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPanelname BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','Panelname') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPayerRaw  BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','PayerName_Raw') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @HasPayer     BIT = CASE WHEN COL_LENGTH('dbo.LineLevelData','PayerName') IS NOT NULL THEN 1 ELSE 0 END;

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
    SELECT
        CPTCode AS SourceName,
        CPTCode,
        BilledYearMonth,
        COUNT(*) AS CPTCount,
        ISNULL(SUM(UnitsValue), 0) AS BilledUnits,
        ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) BETWEEN ''2018'' AND ''2099''
    GROUP BY CPTCode, BilledYearMonth
    ORDER BY CPTCode, BilledYearMonth;
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
    @PayerNames NVARCHAR(MAX)=NULL, @PanelNames NVARCHAR(MAX)=NULL,
    @DosFrom DATE=NULL, @DosTo DATE=NULL,
    @FirstBillFrom DATE=NULL, @FirstBillTo DATE=NULL,
    @FirstBilledFrom DATE=NULL, @FirstBilledTo DATE=NULL
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

EXEC dbo.usp_RefreshNW_CPTBreakdownBySource;
GO

PRINT '--- distinct CPT codes (should be many, not 1) ---';
SELECT COUNT(DISTINCT CPTCode) AS DistinctCpts, COUNT(*) AS Rows
FROM dbo.NW_CPTBreakdownBySource;

SELECT TOP 20 SourceName, CPTCode, BilledYearMonth, CPTCount, TotalCharges
FROM dbo.NW_CPTBreakdownBySource
ORDER BY CPTCode, BilledYearMonth;

PRINT '=== Done. Ctrl+F5 CPT Breakdown — CPT codes should list as rows. ===';
GO

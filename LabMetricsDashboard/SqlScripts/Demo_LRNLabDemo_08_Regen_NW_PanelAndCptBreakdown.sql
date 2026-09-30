/*
   LabDemo — regenerate Production Summary CPT + Panel Breakdown (SQL only)
   -----------------------------------------------------------------------
   LRNLabDemo falls through to NorthWest Production Summary repos, which call:
     dbo.usp_GetNW_PanelBreakdownWithPayers
     dbo.usp_GetNW_CPTBreakdownBySource

   Problems on a Cove-restored LabDemo:
     1) Panel: NW logic keys PanelType → often blank on Cove → "Unknown" + messy months
     2) CPT:  NW filters Source LIKE WEBPM%/DAQ% → Cove lines often have no such Source
               → empty tab ("No billed line-level data found")

   This script recreates both NW objects using Cove-friendly column logic:
     Panel  = COALESCE(Panelname, PanelType, 'Unknown')
     Month  = CONVERT(char(7), ChargeEnteredDate, 120)   -- always yyyy-MM
     CPT    = all billed LineLevelData (Source bucketed; blank Source → 'All')

   Run on LabDemo. Safe to re-run.
*/

USE LabDemo;   -- or: USE LRNLabDemo;
GO

SET NOCOUNT ON;
PRINT '=== Regen NW Panel + CPT for LabDemo on ' + DB_NAME() + ' ===';

/* =====================================================================
   A) Panel Breakdown With Payers
   ===================================================================== */
IF OBJECT_ID(N'dbo.NW_PanelBreakdownWithPayers', N'SN') IS NOT NULL
    DROP SYNONYM dbo.NW_PanelBreakdownWithPayers;
IF OBJECT_ID(N'dbo.NW_PanelBreakdownWithPayers', N'U') IS NULL
BEGIN
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
END
ELSE
    TRUNCATE TABLE dbo.NW_PanelBreakdownWithPayers;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_PanelBreakdownWithPayers
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Base AS
    (
        SELECT
            COALESCE(
                NULLIF(LTRIM(RTRIM(Panelname)), ''),
                NULLIF(LTRIM(RTRIM(PanelType)), ''),
                N'Unknown')                                          AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))           AS PayerName,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                        AS ClaimKey,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))                  AS ChargeAmountValue
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
          AND (
                LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = ''
             OR LTRIM(RTRIM(ClaimStatus)) NOT IN (
                    N'Unbilled in Daq', N'Unbilled in Daq - PR',
                    N'Unbilled in Webpm', N'Unbilled in Webpm - PR',
                    N'Billed amount 0')
              )
    )
    SELECT
        PanelName,
        PayerName,
        BilledYearMonth,
        COUNT(DISTINCT ClaimKey)                AS ClaimCount,
        ISNULL(SUM(ChargeAmountValue), 0)       AS TotalCharges
    INTO #Raw
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) NOT IN ('1900', '0001')
    GROUP BY PanelName, PayerName, BilledYearMonth;

    TRUNCATE TABLE dbo.NW_PanelBreakdownWithPayers;
    INSERT INTO dbo.NW_PanelBreakdownWithPayers
        (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY PanelName, PayerName, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;
    PRINT 'usp_RefreshNW_PanelBreakdownWithPayers rows=' + CAST(@@ROWCOUNT AS NVARCHAR(20));
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
        SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.NW_PanelBreakdownWithPayers
        ORDER BY PanelName, PayerName, BilledYearMonth;
        RETURN;
    END

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

    ;WITH Base AS
    (
        SELECT
            COALESCE(
                NULLIF(LTRIM(RTRIM(Panelname)), ''),
                NULLIF(LTRIM(RTRIM(PanelType)), ''),
                N'Unknown')                                          AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))           AS PayerName,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                        AS ClaimKey,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))                  AS ChargeAmountValue
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
          AND (
                LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = ''
             OR LTRIM(RTRIM(ClaimStatus)) NOT IN (
                    N'Unbilled in Daq', N'Unbilled in Daq - PR',
                    N'Unbilled in Webpm', N'Unbilled in Webpm - PR',
                    N'Billed amount 0')
              )
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR COALESCE(
                NULLIF(LTRIM(RTRIM(Panelname)), ''),
                NULLIF(LTRIM(RTRIM(PanelType)), ''),
                N'Unknown') IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    )
    SELECT
        PanelName,
        PayerName,
        BilledYearMonth,
        COUNT(DISTINCT ClaimKey)          AS ClaimCount,
        ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) NOT IN ('1900', '0001')
    GROUP BY PanelName, PayerName, BilledYearMonth
    ORDER BY PanelName, PayerName, BilledYearMonth;
END
GO

/* =====================================================================
   B) CPT Breakdown By Source (Cove-friendly — do not require WEBPM/DAQ)
   ===================================================================== */
IF OBJECT_ID(N'dbo.NW_CPTBreakdownBySource', N'SN') IS NOT NULL
    DROP SYNONYM dbo.NW_CPTBreakdownBySource;
IF OBJECT_ID(N'dbo.NW_CPTBreakdownBySource', N'U') IS NULL
BEGIN
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
END
ELSE
    TRUNCATE TABLE dbo.NW_CPTBreakdownBySource;
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

    ;WITH Base AS
    (
        SELECT
            CASE
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'WEBPM%' THEN N'WebPM'
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'DAQ%'   THEN N'DAQ'
                WHEN NULLIF(LTRIM(RTRIM(Source)), '') IS NULL               THEN N'All'
                ELSE N'All'
            END AS SourceName,
            LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))) AS CPTCode,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            TRY_CAST(Units AS DECIMAL(18,2)) AS UnitsValue,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2)) AS ChargeAmountValue
        FROM dbo.LineLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
          AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
    )
    SELECT
        SourceName,
        CPTCode,
        BilledYearMonth,
        COUNT(*)                          AS CPTCount,
        ISNULL(SUM(UnitsValue), 0)        AS BilledUnits,
        ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    INTO #Raw
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) NOT IN ('1900', '0001')
    GROUP BY SourceName, CPTCode, BilledYearMonth;

    TRUNCATE TABLE dbo.NW_CPTBreakdownBySource;
    INSERT INTO dbo.NW_CPTBreakdownBySource
        (SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw;

    DROP TABLE IF EXISTS #Raw;
    PRINT 'usp_RefreshNW_CPTBreakdownBySource rows=' + CAST(@@ROWCOUNT AS NVARCHAR(20));
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
        SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM dbo.NW_CPTBreakdownBySource
        ORDER BY SourceName, CPTCode, BilledYearMonth;
        RETURN;
    END

    IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NULL
    BEGIN
        SELECT CAST(NULL AS NVARCHAR(20)) AS SourceName,
               CAST(NULL AS NVARCHAR(50)) AS CPTCode,
               CAST(NULL AS NVARCHAR(7))  AS BilledYearMonth,
               CAST(0 AS INT)             AS CPTCount,
               CAST(0 AS DECIMAL(18,2))   AS BilledUnits,
               CAST(0 AS DECIMAL(18,2))   AS TotalCharges
        WHERE 1 = 0;
        RETURN;
    END

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

    ;WITH Base AS
    (
        SELECT
            CASE
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'WEBPM%' THEN N'WebPM'
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'DAQ%'   THEN N'DAQ'
                ELSE N'All'
            END AS SourceName,
            LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))) AS CPTCode,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            TRY_CAST(Units AS DECIMAL(18,2)) AS UnitsValue,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2)) AS ChargeAmountValue
        FROM dbo.LineLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
          AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR COALESCE(
                NULLIF(LTRIM(RTRIM(Panelname)), ''),
                NULLIF(LTRIM(RTRIM(PanelType)), ''),
                N'Unknown') IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    )
    SELECT
        SourceName,
        CPTCode,
        BilledYearMonth,
        COUNT(*)                          AS CPTCount,
        ISNULL(SUM(UnitsValue), 0)        AS BilledUnits,
        ISNULL(SUM(ChargeAmountValue), 0) AS TotalCharges
    FROM Base
    WHERE BilledYearMonth IS NOT NULL
      AND LEFT(BilledYearMonth, 4) NOT IN ('1900', '0001')
    GROUP BY SourceName, CPTCode, BilledYearMonth
    ORDER BY SourceName, CPTCode, BilledYearMonth;
END
GO

/* Also keep simple usp_GetNW_CPTBreakdown pointing at BySource All bucket for older callers */
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

/* =====================================================================
   C) Refresh + smoke
   ===================================================================== */
EXEC dbo.usp_RefreshNW_PanelBreakdownWithPayers;
EXEC dbo.usp_RefreshNW_CPTBreakdownBySource;
GO

PRINT '--- Panel sample (months should be yyyy-MM sorted) ---';
SELECT TOP 20 PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.NW_PanelBreakdownWithPayers
ORDER BY BilledYearMonth, PanelName;

PRINT '--- Panel month keys ---';
SELECT BilledYearMonth, COUNT(*) AS Rows, SUM(ClaimCount) AS Claims
FROM dbo.NW_PanelBreakdownWithPayers
GROUP BY BilledYearMonth
ORDER BY BilledYearMonth;

PRINT '--- CPT sample ---';
SELECT TOP 20 SourceName, CPTCode, BilledYearMonth, CPTCount, TotalCharges
FROM dbo.NW_CPTBreakdownBySource
ORDER BY SourceName, CPTCode, BilledYearMonth;

PRINT '--- LineLevelData billed line check ---';
IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NOT NULL
    SELECT
        COUNT(*) AS LineRows,
        SUM(CASE WHEN TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL THEN 1 ELSE 0 END) AS BilledLines,
        SUM(CASE WHEN NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL THEN 1 ELSE 0 END) AS WithCpt
    FROM dbo.LineLevelData;
ELSE
    PRINT 'LineLevelData MISSING — CPT tab cannot populate until line data is loaded.';

PRINT '=== Done. Hard-refresh Production Summary CPT + Panel tabs (Ctrl+F5). ===';
GO

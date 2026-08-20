/* =====================================================================
   Standalone SP — CPT Breakdown grouped by Source (WebPM / DAQ)
   DB  : NWL_LRN

   Do NOT change 09_NorthWest_CPTBreakdown.sql or fix_NW_CPTBreakdown_CountUnits.sql.

   Matches the client LineLevelData pivot:
     Row    : LineLevelData.CPTCode
     Column : ChargeEnteredDate year/month (yyyy-MM)
     Filter : FirstBilledDate present AND Source = DAQ / WEBPM
     Values : COUNT(*) line rows, SUM(Units), SUM(ChargeAmount)

   No ClaimLevelData join and no ClaimStatus exclusion.

   Objects:
     dbo.NW_CPTBreakdownBySource
     dbo.usp_RefreshNW_CPTBreakdownBySource
     dbo.usp_GetNW_CPTBreakdownBySource

   Result shape:
     SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
   ===================================================================== */
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.NW_CPTBreakdownBySource', 'U') IS NULL
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

    ;WITH Base AS
    (
        SELECT
            CASE
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'WEBPM%' THEN N'WebPM'
                WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'DAQ%'   THEN N'DAQ'
                ELSE N'Other'
            END                                                     AS SourceName,
            LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                AS CPTCode,
            CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120) AS BilledYearMonth,
            TRY_CAST(Units AS DECIMAL(18,2))                        AS UnitsValue,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))                 AS ChargeAmountValue
        FROM dbo.LineLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
          AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND (
                  UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'WEBPM%'
               OR UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'DAQ%'
              )
    )
    SELECT
        SourceName,
        CPTCode,
        BilledYearMonth,
        COUNT(*)                                                AS CPTCount,
        ISNULL(SUM(UnitsValue), 0)                              AS BilledUnits,
        ISNULL(SUM(ChargeAmountValue), 0)                       AS TotalCharges
    INTO #Raw
    FROM Base
    WHERE SourceName <> N'Other'
    GROUP BY SourceName, CPTCode, BilledYearMonth;

    TRUNCATE TABLE dbo.NW_CPTBreakdownBySource;

    INSERT INTO dbo.NW_CPTBreakdownBySource
        (SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_CPTBreakdownBySource completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
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
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM    dbo.NW_CPTBreakdownBySource
        ORDER BY SourceName, CPTCode, BilledYearMonth;
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

    SELECT
        CASE
            WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'WEBPM%' THEN N'WebPM'
            WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'DAQ%'   THEN N'DAQ'
            ELSE N'Other'
        END                                                             AS SourceName,
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                        AS CPTCode,
        CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120)      AS BilledYearMonth,
        COUNT(*)                                                        AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)                AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
      AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND (
              UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'WEBPM%'
           OR UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'DAQ%'
          )
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)),''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    GROUP BY
        CASE
            WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'WEBPM%' THEN N'WebPM'
            WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'DAQ%'   THEN N'DAQ'
            ELSE N'Other'
        END,
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        CONVERT(char(7), TRY_CAST(ChargeEnteredDate AS date), 120)
    HAVING
        CASE
            WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'WEBPM%' THEN N'WebPM'
            WHEN UPPER(LTRIM(RTRIM(ISNULL(Source, '')))) LIKE 'DAQ%'   THEN N'DAQ'
            ELSE N'Other'
        END <> N'Other'
    ORDER BY SourceName, CPTCode, BilledYearMonth;
END
GO

PRINT 'Created dbo.NW_CPTBreakdownBySource / usp_RefreshNW_CPTBreakdownBySource / usp_GetNW_CPTBreakdownBySource';
PRINT 'Next: EXEC dbo.usp_RefreshNW_CPTBreakdownBySource';
GO

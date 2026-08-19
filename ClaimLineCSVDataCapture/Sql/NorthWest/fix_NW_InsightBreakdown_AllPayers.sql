/* =====================================================================
   Standalone SP — Insight Daq / WebPM with ALL-payer Grand Total
   DB  : NWL_LRN

   Do NOT change fix_NW_InsightBreakdown.sql (that snapshot is Top 10 only).

   Display   : Top 10 payers (applied in the app)
   Grand Total: sum of ALL payers for that Source (Daq / Webpm)

   Objects:
     dbo.NW_InsightBreakdownAllPayers
     dbo.usp_RefreshNW_InsightBreakdownAllPayers
     dbo.usp_GetNW_InsightBreakdownAllPayers  (@Source = 'Daq' | 'Webpm')

   Result shape (same as usp_GetNW_InsightBreakdown, but every payer):
     PayerName, BilledYearMonth, ClaimCount, TotalCharges
   ===================================================================== */
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.NW_InsightBreakdownAllPayers', 'U') IS NULL
CREATE TABLE dbo.NW_InsightBreakdownAllPayers
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    SourceName      NVARCHAR(20)    NOT NULL,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_InsightBreakdownAllPayers
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Base AS
    (
        SELECT
            CASE
                WHEN UPPER(src.SourceValue) LIKE 'DAQ%'   THEN N'Daq'
                WHEN UPPER(src.SourceValue) LIKE 'WEBPM%' THEN N'Webpm'
            END AS SourceName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
            NULLIF(LTRIM(RTRIM(ClaimID)), '') AS ClaimID,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2)) AS ChargeAmount
        FROM dbo.ClaimLevelData
        CROSS APPLY (
            SELECT LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(AdditionalFields, 'Source'), ''))) AS SourceValue
        ) src
        WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
                  'Unbilled in Daq','Unbilled in Daq - PR',
                  'Unbilled in Webpm','Unbilled in Webpm - PR',
                  'Billed amount 0')
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND (
                  (TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
                   AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> '')
               OR TRY_CAST(EmedixSubmissionDate AS DATE) IS NOT NULL
              )
          AND (
                  UPPER(src.SourceValue) LIKE 'DAQ%'
               OR UPPER(src.SourceValue) LIKE 'WEBPM%'
              )
    )
    SELECT SourceName, PayerName, BilledYearMonth,
           COUNT(DISTINCT ClaimID) AS ClaimCount,
           ISNULL(SUM(ChargeAmount), 0) AS TotalCharges
    INTO #Raw
    FROM Base
    WHERE SourceName IS NOT NULL
    GROUP BY SourceName, PayerName, BilledYearMonth;

    TRUNCATE TABLE dbo.NW_InsightBreakdownAllPayers;

    INSERT INTO dbo.NW_InsightBreakdownAllPayers
        (SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY SourceName, PayerName, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_InsightBreakdownAllPayers completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_InsightBreakdownAllPayers
    @Source          NVARCHAR(20),
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

    DECLARE @SourceName NVARCHAR(20) =
        CASE
            WHEN UPPER(LTRIM(RTRIM(@Source))) LIKE 'WEBPM%' THEN N'Webpm'
            ELSE N'Daq'
        END;

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
        SELECT  PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM    dbo.NW_InsightBreakdownAllPayers
        WHERE   SourceName = @SourceName
        ORDER BY PayerName, BilledYearMonth;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL);

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
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM dbo.ClaimLevelData
    CROSS APPLY (
        SELECT LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(AdditionalFields, 'Source'), ''))) AS SourceValue
    ) src
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq','Unbilled in Daq - PR',
              'Unbilled in Webpm','Unbilled in Webpm - PR',
              'Billed amount 0')
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND (
              (TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
               AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> '')
           OR TRY_CAST(EmedixSubmissionDate AS DATE) IS NOT NULL
          )
      AND (
              (@SourceName = N'Daq'   AND UPPER(src.SourceValue) LIKE 'DAQ%')
           OR (@SourceName = N'Webpm' AND UPPER(src.SourceValue) LIKE 'WEBPM%')
          )
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY PayerName, BilledYearMonth;
END
GO

PRINT 'Created dbo.NW_InsightBreakdownAllPayers / usp_RefreshNW_InsightBreakdownAllPayers / usp_GetNW_InsightBreakdownAllPayers';
PRINT 'Next: EXEC dbo.usp_RefreshNW_InsightBreakdownAllPayers';
GO

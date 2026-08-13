/* =====================================================================
   Standalone SP — Highest Payer Breakdown (new Production Summary tab)
   DB  : NWL_LRN

   Do NOT change 07 / 14.

   Row    : Source (Daq / WebPM) then PayerName_Raw under each source
   Column : ChargeEnteredDate year/month
   Values : COUNT(DISTINCT ClaimID), SUM(ChargeAmount)
   Sort   : Grand Total (applied in the app)
   Filter : same as Payer/Panel
            - ClaimStatus not unbilled / billed-amount-0
            - FirstBilledDate is a date, or if blank EmedixSubmissionDate is a date
            - ChargeEnteredDate is a date
   Source : dbo.GetAdditionalField(AdditionalFields, 'Source')
            Daq% → Daq, Webpm% → WebPM

   Objects:
     dbo.NW_HighestPayerBreakdown
     dbo.usp_RefreshNW_HighestPayerBreakdown
     dbo.usp_GetNW_HighestPayerBreakdown

   Result: SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
   ===================================================================== */
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.NW_HighestPayerBreakdown', 'U') IS NULL
CREATE TABLE dbo.NW_HighestPayerBreakdown
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_HighestPayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        CASE
            WHEN UPPER(src.SourceValue) LIKE 'DAQ%'   THEN N'Daq'
            WHEN UPPER(src.SourceValue) LIKE 'WEBPM%' THEN N'WebPM'
        END AS SourceName,
        ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), N'* none *') AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #Raw
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
    GROUP BY
        CASE
            WHEN UPPER(src.SourceValue) LIKE 'DAQ%'   THEN N'Daq'
            WHEN UPPER(src.SourceValue) LIKE 'WEBPM%' THEN N'WebPM'
        END,
        ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), N'* none *'),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.NW_HighestPayerBreakdown;

    INSERT INTO dbo.NW_HighestPayerBreakdown
        (SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    WHERE SourceName IS NOT NULL
    ORDER BY SourceName, PayerName, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_HighestPayerBreakdown completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_HighestPayerBreakdown
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
        SELECT  SourceName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM    dbo.NW_HighestPayerBreakdown
        ORDER BY SourceName, PayerName, BilledYearMonth;
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
        CASE
            WHEN UPPER(src.SourceValue) LIKE 'DAQ%'   THEN N'Daq'
            WHEN UPPER(src.SourceValue) LIKE 'WEBPM%' THEN N'WebPM'
        END AS SourceName,
        ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), N'* none *') AS PayerName,
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
              UPPER(src.SourceValue) LIKE 'DAQ%'
           OR UPPER(src.SourceValue) LIKE 'WEBPM%'
          )
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList)
           OR ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), N'* none *') IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
      AND (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
      AND (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
    GROUP BY
        CASE
            WHEN UPPER(src.SourceValue) LIKE 'DAQ%'   THEN N'Daq'
            WHEN UPPER(src.SourceValue) LIKE 'WEBPM%' THEN N'WebPM'
        END,
        ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), N'* none *'),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY SourceName, PayerName, BilledYearMonth;
END
GO

PRINT 'Created dbo.NW_HighestPayerBreakdown / usp_RefreshNW_HighestPayerBreakdown / usp_GetNW_HighestPayerBreakdown';
PRINT 'Next: EXEC dbo.usp_RefreshNW_HighestPayerBreakdown';
GO

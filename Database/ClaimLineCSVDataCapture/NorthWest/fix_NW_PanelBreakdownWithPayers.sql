/* =====================================================================
   Standalone SP — Panel Breakdown with payer drill-down (Production Summary)
   DB  : NWL_LRN

   Do NOT change fix_NW_PanelBreakdown.sql or 14_NorthWest_ReadSPs.sql.

   Parent row : ClaimLevelData.PanelType
   Child row  : ClaimLevelData.PayerName_Raw
   Column     : ChargeEnteredDate year/month (yyyy-MM)
   Values     : COUNT(DISTINCT ClaimID), SUM(ChargeAmount)
   Filter     : same as Payer / Panel Breakdown live path

   Objects:
     dbo.NW_PanelBreakdownWithPayers
     dbo.usp_RefreshNW_PanelBreakdownWithPayers
     dbo.usp_GetNW_PanelBreakdownWithPayers

   Result shape:
     PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
   ===================================================================== */
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.NW_PanelBreakdownWithPayers', 'U') IS NULL
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

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)), ''), 'Unknown'))) AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                       AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')               AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)              AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ClaimStatus)) NOT IN (
              'Unbilled in Daq',
              'Unbilled in Daq - PR',
              'Unbilled in Webpm',
              'Unbilled in Webpm - PR',
              'Billed amount 0')
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND (
              (TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
               AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> '')
           OR TRY_CAST(EmedixSubmissionDate AS DATE) IS NOT NULL
          )
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)), ''), 'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.NW_PanelBreakdownWithPayers;

    INSERT INTO dbo.NW_PanelBreakdownWithPayers
        (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY PanelName, PayerName, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_PanelBreakdownWithPayers completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
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
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM    dbo.NW_PanelBreakdownWithPayers
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

    ;WITH Agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)), ''), 'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                       AS PayerName,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')               AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)              AS TotalCharges
        FROM dbo.ClaimLevelData
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
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)),''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom          IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo            IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@FirstBillFrom    IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo      IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelType)), ''), 'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    )
    SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
    FROM Agg
    ORDER BY PanelName, PayerName, BilledYearMonth;
END
GO

PRINT 'Created dbo.NW_PanelBreakdownWithPayers / usp_RefreshNW_PanelBreakdownWithPayers / usp_GetNW_PanelBreakdownWithPayers';
PRINT 'Next: EXEC dbo.usp_RefreshNW_PanelBreakdownWithPayers';
GO

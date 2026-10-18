-- ============================================================
-- Cove Collection — Rep vs Payment refresh NULL SalesRepName
-- Date: 2026-09-15
-- Run on the live Cove lab database (CoveLRN). Safe to re-run.
-- Do NOT re-run 12_Cove_CollectionSummary.sql just for this.
--
-- Symptom (job log):
--   [COVE CS] dbo.usp_RefreshCove_CS_RepVsPayment — FAILED:
--   Cannot insert the value NULL into column 'SalesRepName',
--   table 'CoveLRN.dbo.Cove_CS_RepVsPayment'; column does not allow nulls.
--
-- Cause:
--   Paid ClaimLevelData rows often have NULL / blank SalesRepname.
--   The NOT-NULL exclude filter was commented out, and the INSERT used
--   LTRIM(RTRIM(SalesRepname)) which stays NULL. Panel vs Payment already
--   coalesces to 'Unknown'; this SP did not.
-- ============================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.Cove_CS_RepVsPayment', 'U') IS NULL
CREATE TABLE dbo.Cove_CS_RepVsPayment
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    SalesRepName     NVARCHAR(500)   NOT NULL,
    CheckYear        INT             NOT NULL,
    CheckMonth       TINYINT         NOT NULL,
    NoOfClaims       INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

PRINT 'Creating usp_RefreshCove_CS_RepVsPayment...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_RepVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Cove_CS_RepVsPayment;

    INSERT INTO dbo.Cove_CS_RepVsPayment
        (SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(SalesRepname)), ''), 'Unknown'))) AS SalesRepName,
        YEAR (TRY_CAST(CheckDate AS DATE))                           AS CheckYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)          AS CheckMonth,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                     AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(CheckDate, ''))) <> ''
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(SalesRepname)), ''), 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    PRINT 'usp_RefreshCove_CS_RepVsPayment completed — '
        + CAST(@@ROWCOUNT AS VARCHAR(20)) + ' rows.';
END
GO

PRINT 'Creating usp_GetCove_CS_RepVsPayment (filter path aligned)...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_RepVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
        FROM   dbo.Cove_CS_RepVsPayment
        ORDER  BY SalesRepName, CheckYear, CheckMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(SalesRepname)), ''), 'Unknown'))) AS SalesRepName,
        CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT)                     AS CheckYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT)                     AS CheckMonth,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)         AS InsurancePayment
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(CheckDate, ''))) <> ''
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(SalesRepname)), ''), 'Unknown'))),
        CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT),
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS INT)
    ORDER BY SalesRepName, CheckYear, CheckMonth;
END
GO

PRINT 'Refreshing Cove_CS_RepVsPayment...';
EXEC dbo.usp_RefreshCove_CS_RepVsPayment;
GO

SELECT
    COUNT(*)                     AS TotalRows,
    COUNT(DISTINCT SalesRepName) AS DistinctReps,
    MAX(RefreshedAt)             AS RefreshedAt
FROM dbo.Cove_CS_RepVsPayment;

SELECT TOP 20
    SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
FROM dbo.Cove_CS_RepVsPayment
ORDER BY InsurancePayment DESC;
GO

PRINT 'FIX_Cove_CS_RepVsPayment complete.';
GO

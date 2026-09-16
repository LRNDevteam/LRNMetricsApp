-- ============================================================
-- Cove Collection — Insurance Vs Payments + Rep Vs Payment
-- Date: 2026-09-16
-- Run on the Cove lab database (CoveLRN). Safe to re-run.
-- Do NOT re-run 12_Cove_CollectionSummary.sql / 14_* just for this.
--
-- Correct Logic (Insurance Vs Payments):
--   Filter : InsurancePayment > 0
--   Row    : PayerName_Raw
--   Grain  : CheckDate year / month (columns)
--   Values : Count[ClaimID]  = COUNT(DISTINCT ClaimID)
--            Insurance Payment = SUM(InsurancePayment)
--
-- Rep Vs Payment (already CheckDate / InsPay>0):
--   Align Claim Count to COUNT(DISTINCT ClaimID)
-- ============================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.Cove_CS_InsuranceVsPayment', 'U') IS NULL
CREATE TABLE dbo.Cove_CS_InsuranceVsPayment
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName        NVARCHAR(500)   NOT NULL,
    BillYear         SMALLINT        NOT NULL,
    BillMonth        TINYINT         NOT NULL,
    NoOfPaidClaims   INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PaymentPct       DECIMAL(9,4)    NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
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

PRINT 'Creating usp_RefreshCove_CS_InsuranceVsPayment...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_InsuranceVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
            YEAR (TRY_CAST(CheckDate AS DATE))                          AS BillYear,
            MONTH(TRY_CAST(CheckDate AS DATE))                          AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(CheckDate, ''))) <> ''
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            YEAR (TRY_CAST(CheckDate AS DATE)),
            MONTH(TRY_CAST(CheckDate AS DATE))
    ),
    grand AS
    (
        SELECT
            BillYear,
            BillMonth,
            NULLIF(SUM(InsurancePayment), 0) AS TotalInsurancePayment
        FROM agg
        GROUP BY BillYear, BillMonth
    )
    SELECT
        a.PayerName,
        CAST(a.BillYear  AS SMALLINT)  AS BillYear,
        CAST(a.BillMonth AS TINYINT)   AS BillMonth,
        a.NoOfPaidClaims,
        a.InsurancePayment,
        CAST(
            a.InsurancePayment * 100.0 /
            ISNULL(g.TotalInsurancePayment, 1)
            AS DECIMAL(9,4)
        ) AS PaymentPct
    INTO #out
    FROM agg a
    INNER JOIN grand g
        ON  a.BillYear  = g.BillYear
        AND a.BillMonth = g.BillMonth;

    TRUNCATE TABLE dbo.Cove_CS_InsuranceVsPayment;

    INSERT INTO dbo.Cove_CS_InsuranceVsPayment
    (
        PayerName, BillYear, BillMonth,
        NoOfPaidClaims, InsurancePayment, PaymentPct, RefreshedAt
    )
    SELECT
        PayerName, BillYear, BillMonth,
        NoOfPaidClaims, InsurancePayment, PaymentPct, GETDATE()
    FROM #out
    ORDER BY BillYear, BillMonth, InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;

    PRINT 'usp_RefreshCove_CS_InsuranceVsPayment completed — '
        + CAST(@@ROWCOUNT AS VARCHAR(20)) + ' rows.';
END
GO

PRINT 'Creating usp_GetCove_CS_InsuranceVsPayment...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_InsuranceVsPayment
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
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct
        FROM   dbo.Cove_CS_InsuranceVsPayment
        ORDER  BY BillYear, BillMonth, InsurancePayment DESC;
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

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT)              AS BillYear,
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)          AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment
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
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            CAST(YEAR (TRY_CAST(CheckDate AS DATE)) AS INT),
            CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)
    ),
    grand AS (
        SELECT BillYear, BillMonth,
               NULLIF(SUM(InsurancePayment), 0) AS Total
        FROM agg GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName, a.BillYear, a.BillMonth, a.NoOfPaidClaims,
           a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    INNER JOIN grand g ON a.BillYear = g.BillYear AND a.BillMonth = g.BillMonth
    ORDER BY a.BillYear, a.BillMonth, a.InsurancePayment DESC;
END
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
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
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

PRINT 'Creating usp_GetCove_CS_RepVsPayment...';
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
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                   AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)        AS InsurancePayment
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

PRINT 'Refreshing Cove Insurance Vs Payments + Rep Vs Payment...';
EXEC dbo.usp_RefreshCove_CS_InsuranceVsPayment;
EXEC dbo.usp_RefreshCove_CS_RepVsPayment;
GO

SELECT 'IVP' AS Report, COUNT(*) AS Rows, MIN(BillYear) AS MinY, MAX(BillYear) AS MaxY,
       SUM(CASE WHEN InsurancePayment <= 0 THEN 1 ELSE 0 END) AS NonPosPay
FROM dbo.Cove_CS_InsuranceVsPayment
UNION ALL
SELECT 'REP', COUNT(*), MIN(CheckYear), MAX(CheckYear),
       SUM(CASE WHEN InsurancePayment <= 0 THEN 1 ELSE 0 END)
FROM dbo.Cove_CS_RepVsPayment;

SELECT TOP 10 PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment
FROM dbo.Cove_CS_InsuranceVsPayment
ORDER BY InsurancePayment DESC;

SELECT TOP 10 SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
FROM dbo.Cove_CS_RepVsPayment
ORDER BY InsurancePayment DESC;
GO

PRINT 'FIX_Cove_CS_InsuranceVsPayment_RepVsPayment_CheckDate complete.';
GO

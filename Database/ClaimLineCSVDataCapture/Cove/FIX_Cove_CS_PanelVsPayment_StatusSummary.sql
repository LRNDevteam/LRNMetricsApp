-- ============================================================
-- Cove Collection — Panel vs Payment + Status Summary empty
-- Date: 2026-09-08 (rev 2 — also deploys Get SPs)
-- Run on the live Cove lab database. Do NOT re-run 12_Cove_CollectionSummary.sql.
--
-- 12 DROPped dbo.Cove_CS_PanelVsPayment and dbo.Cove_CS_StatusSummary
-- then never EXECed the refresh SPs (the EXEC block at the bottom of 12
-- is commented). Localhost still had earlier snapshot rows; live did not.
--
-- Rev 2: snapshot row counts are not enough. The website uses
-- usp_GetCove_CS_PanelVsPayment / usp_GetCove_CS_StatusSummary whenever
-- any filter is on the URL (or EnableCollectionSummaryReport is off).
-- If 14 was never run, those Get SPs are missing and the tabs stay empty.
-- Safe to re-run this script; it does not DROP the snapshot tables.
-- ============================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.Cove_CS_PanelVsPayment', 'U') IS NULL
CREATE TABLE dbo.Cove_CS_PanelVsPayment
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName        NVARCHAR(500)   NOT NULL,
    BilledYear       INT             NOT NULL,
    BilledMonth      TINYINT         NOT NULL,
    NoOfClaims       INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID('dbo.Cove_CS_StatusSummary', 'U') IS NULL
CREATE TABLE dbo.Cove_CS_StatusSummary
(
    SummaryId        INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ClaimStatus      NVARCHAR(200)   NOT NULL,
    PanelName        NVARCHAR(500)   NOT NULL,
    CptCode          NVARCHAR(400)   NOT NULL,
    PayerName        NVARCHAR(500)   NOT NULL,
    NoOfClaims       INT             NOT NULL DEFAULT 0,
    InsurancePayment DECIMAL(18,2)   NOT NULL DEFAULT 0,
    InsuranceBalance DECIMAL(18,2)   NOT NULL DEFAULT 0,
    PatientBalance   DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt      DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Cove_CS_PanelVsPayment;

    INSERT INTO dbo.Cove_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))                    AS PanelName,
        YEAR (TRY_CAST(CheckDate AS DATE))                            AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)           AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))             AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)   AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(CheckDate, ''))) <> ''
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    PRINT 'usp_RefreshCove_CS_PanelVsPayment completed — '
        + CAST(@@ROWCOUNT AS VARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Cove_CS_StatusSummary;

    INSERT INTO dbo.Cove_CS_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName,
         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ISNULL(LEFT(LTRIM(RTRIM(ClaimStatus)), 200), '(blank)') AS ClaimStatus,
        ISNULL(LEFT(LTRIM(RTRIM(Panelname)), 500), '(blank)')   AS PanelName,
        ISNULL(LEFT(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), 400), '(blank)') AS CptCode,
        ISNULL(LEFT(LTRIM(RTRIM(PayerName_Raw)), 500), '(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0) AS PatientBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    GROUP BY
        ISNULL(LEFT(LTRIM(RTRIM(ClaimStatus)), 200), '(blank)'),
        ISNULL(LEFT(LTRIM(RTRIM(Panelname)), 500), '(blank)'),
        ISNULL(LEFT(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), 400), '(blank)'),
        ISNULL(LEFT(LTRIM(RTRIM(PayerName_Raw)), 500), '(blank)');

    PRINT 'usp_RefreshCove_CS_StatusSummary completed — '
        + CAST(@@ROWCOUNT AS VARCHAR(20)) + ' rows.';
END
GO

-- Get SPs (same as 14). Website uses these when any filter is on the Collection URL.
CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelVsPayment
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
        SELECT  PanelName,
                BilledYear,
                BilledMonth,
                SUM(NoOfClaims)       AS NoOfClaims,
                SUM(InsurancePayment) AS InsurancePayments
        FROM    dbo.Cove_CS_PanelVsPayment
        GROUP BY PanelName, BilledYear, BilledMonth
        ORDER BY PanelName, BilledYear, BilledMonth;
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
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))                          AS PanelName,
        YEAR (TRY_CAST(CheckDate AS DATE))                                   AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)                  AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)         AS InsurancePayments
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL AND CheckDate <> ''
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
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE))
    ORDER BY PanelName, BilledYear, BilledMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_StatusSummary
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
        SELECT ClaimStatus, PanelName,
               CAST(CptCode AS NVARCHAR(400)) AS CptCode,
               PayerName,
               NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
        FROM   dbo.Cove_CS_StatusSummary;
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
        ISNULL(LEFT(LTRIM(RTRIM(ClaimStatus)), 200), '(blank)') AS ClaimStatus,
        ISNULL(LEFT(LTRIM(RTRIM(Panelname)), 500), '(blank)')   AS PanelName,
        ISNULL(LEFT(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), 400), '(blank)') AS CptCode,
        ISNULL(LEFT(LTRIM(RTRIM(PayerName_Raw)), 500), '(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)         AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)         AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)         AS PatientBalance
    FROM dbo.ClaimLevelData
    WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        ISNULL(LEFT(LTRIM(RTRIM(ClaimStatus)), 200), '(blank)'),
        ISNULL(LEFT(LTRIM(RTRIM(Panelname)), 500), '(blank)'),
        ISNULL(LEFT(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), 400), '(blank)'),
        ISNULL(LEFT(LTRIM(RTRIM(PayerName_Raw)), 500), '(blank)');
END
GO

PRINT 'Refreshing Panel vs Payment and Status Summary...';
EXEC dbo.usp_RefreshCove_CS_PanelVsPayment;
EXEC dbo.usp_RefreshCove_CS_StatusSummary;

SELECT DB_NAME() AS CurrentDatabase;

SELECT 'Cove_CS_PanelVsPayment' AS [Table], COUNT(*) AS Rows, MAX(RefreshedAt) AS LastRun
FROM dbo.Cove_CS_PanelVsPayment
UNION ALL
SELECT 'Cove_CS_StatusSummary', COUNT(*), MAX(RefreshedAt)
FROM dbo.Cove_CS_StatusSummary;

SELECT CASE WHEN OBJECT_ID('dbo.usp_GetCove_CS_PanelVsPayment','P') IS NOT NULL THEN 'OK' ELSE 'MISSING' END AS GetPanelVsPayment,
       CASE WHEN OBJECT_ID('dbo.usp_GetCove_CS_StatusSummary','P') IS NOT NULL THEN 'OK' ELSE 'MISSING' END AS GetStatusSummary;
GO

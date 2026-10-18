-- PCRLabsofAmerica — Payer Breakdown  +  Payer × Panel
--
-- Filter (both SPs):
--   TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL  (payer not blank)
--
-- Table 1 – PCR_PayerBreakdown  (Payer × ChargeEnteredDate Month)
--   Row: PayerName_Raw
--   Col: ChargeEnteredDate yyyy-MM | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   ? feeds Payer Breakdown tab
--
-- Table 2 – PCR_PayerByPanel  (Payer × Panelname)
--   Row: PayerName_Raw
--   Col: Panelname | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   ? feeds Payer X Panel tab
--   UI query: SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
--             FROM dbo.PCR_PayerByPanel ORDER BY PayerName, PanelName
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1a: PCR_PayerBreakdown  (Payer × Month)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_PayerBreakdown')
CREATE TABLE dbo.PCR_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from ChargeEnteredDate
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 1b: PCR_PayerByPanel  (Payer × Panelname)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_PayerByPanel')
CREATE TABLE dbo.PCR_PayerByPanel
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    PanelType    NVARCHAR(MAX)   NOT NULL,   -- stores Panelname; aliased PanelName when queried
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2a: Stored procedure — Payer × Month
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    -- Column pivot on ChargeEnteredDate month/year.
    -- Filter: FirstBilledDate valid AND payer not blank.
    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                     AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))               AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #RawPM
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) != ''
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.PCR_PayerBreakdown;

    INSERT INTO dbo.PCR_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPM
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #RawPM;

    PRINT 'usp_RefreshPCR_PayerBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Step 2b: Stored procedure — Payer × Panelname
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                                      AS PayerName_Raw,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))      AS Panelname,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
    INTO #RawPP
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) != ''
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')));

    TRUNCATE TABLE dbo.PCR_PayerByPanel;

    INSERT INTO dbo.PCR_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, Panelname, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP
    ORDER BY PayerName_Raw, Panelname;

    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshPCR_PayerByPanel completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.PCR_PayerBreakdown ORDER BY PayerName, BilledYearMonth;

SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
FROM dbo.PCR_PayerByPanel ORDER BY PayerName, PanelType;
*/

-- ============================================================
-- Step 3a: Read stored procedure - Payer x Month
-- Called by LabMetricsDashboard.SqlLabProductionSummaryRepository.
-- See usp_GetPCR_MonthlyBilledProductionSummary header for the parameter
-- contract (no params -> snapshot table; any param -> live aggregate).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_PayerBreakdown
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
        SELECT  PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM    dbo.PCR_PayerBreakdown
        ORDER BY PayerName, BilledYearMonth;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                            AS PayerName,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  TRY_CAST(FirstBilledDate    AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  PayerName_Raw IS NOT NULL
      AND  LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND  TRY_CAST(ChargeEnteredDate  AS DATE) IS NOT NULL
      AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY PayerName, BilledYearMonth;
END
GO

-- ============================================================
-- Step 3b: Read stored procedure - Payer x Panel
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_PayerByPanel
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
        SELECT  PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
        FROM    dbo.PCR_PayerByPanel
        ORDER BY PayerName, PanelName;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                                  AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                            AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)                       AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  PayerName_Raw IS NOT NULL
      AND  LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))
    ORDER BY PayerName, PanelName;
END
GO

PRINT '08_PCRLabsofAmerica_PayerBreakdown.sql completed.';

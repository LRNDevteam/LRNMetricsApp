/* =====================================================================
   COVE Production Summary — Monthly ChargeEntered + Payor×Panel All Claims
   DB  : CoveLRN

   NEW FILE ONLY — does not edit 06_*, 07_*, 13_*, or FIX_Cove_ProductionSummary_Breakdowns.sql.
   Redeploys (CREATE OR ALTER) the live SPs that UI + Excel / ReportWorker already call.

   1) Monthly Claim Volume
      usp_RefreshCove_MonthlyBilledProductionSummary
      usp_GetCove_MonthlyBilledProductionSummary
      → snapshot dbo.Cove_MonthlyBilledProductionSummary
      Columns (BilledYearMonth) = ChargeEnteredDate yyyy-MM
      Population filter: FirstBilledDate present (billed claims) AND ChargeEnteredDate valid
      Rank: COUNT(DISTINCT ClaimID) per Panelname × PayerName_Raw

   2) Payor × Panel  (client logic: ClaimLevelData [All])
      usp_RefreshCove_PayerByPanel_FullClaims
      usp_GetCove_PayerByPanel_FullClaims
      → snapshot dbo.Cove_PayerByPanel
      Rows    = PayerName_Raw  (blank → Unknown)
      Columns = Panelname      (blank → (No Panelname))
      Values  = COUNT(DISTINCT ClaimID), SUM(ChargeAmount)
      NO FirstBilledDate-not-blank gate (full claim-level set)

   After deploy on CoveLRN:
      EXEC dbo.usp_RefreshCove_MonthlyBilledProductionSummary;
      EXEC dbo.usp_RefreshCove_PayerByPanel_FullClaims;

   UI/Excel: Cove uses lab-specific ChargeEnteredDate Monthly logic (IsCoveLab),
   not ProductionSummary.Rule. Leave Cove.json Rule unchanged.
   ===================================================================== */
SET NOCOUNT ON;
GO

/* ---------- Ensure snapshot tables exist ---------- */
IF OBJECT_ID('dbo.Cove_MonthlyBilledProductionSummary', 'U') IS NULL
CREATE TABLE dbo.Cove_MonthlyBilledProductionSummary
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(MAX)   NOT NULL,
    PayerName       NVARCHAR(500)   NOT NULL,
    PayerRank       TINYINT         NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID('dbo.Cove_PayerByPanel', 'U') IS NULL
CREATE TABLE dbo.Cove_PayerByPanel
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    PanelType    NVARCHAR(MAX)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

/* =====================================================================
   1) Monthly — ChargeEnteredDate month/year
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- Month axis = ChargeEnteredDate. Keep billed population (FirstBilledDate present).
    SELECT
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))         AS Panelname,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    SELECT
        Panelname,
        PayerName_Raw,
        DENSE_RANK() OVER (
            PARTITION BY Panelname
            ORDER BY SUM(ClaimCount) DESC
        ) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY Panelname, PayerName_Raw;

    -- Panel totals (PayerRank = 0) + every payer month row
    SELECT
        b.Panelname,
        CAST(N'' AS NVARCHAR(500)) AS PayerName_Raw,
        CAST(0 AS TINYINT)         AS PayerRank,
        b.BilledYearMonth,
        SUM(b.ClaimCount)          AS ClaimCount,
        SUM(b.TotalCharges)        AS TotalCharges
    INTO #Out
    FROM #BilledRaw b
    GROUP BY b.Panelname, b.BilledYearMonth;

    INSERT INTO #Out (Panelname, PayerName_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges)
    SELECT
        b.Panelname,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT),
        b.BilledYearMonth,
        b.ClaimCount,
        b.TotalCharges
    FROM #BilledRaw b
    JOIN #PayerRanks r
      ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw;

    TRUNCATE TABLE dbo.Cove_MonthlyBilledProductionSummary;

    INSERT INTO dbo.Cove_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, PayerName_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Out
    ORDER BY Panelname, PayerRank, BilledYearMonth;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Out;

    PRINT 'usp_RefreshCove_MonthlyBilledProductionSummary (ChargeEnteredDate) completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_MonthlyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,  -- ChargeEnteredDate filter (Rule1 UI label)
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
        SELECT PanelType AS PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.Cove_MonthlyBilledProductionSummary
        ORDER BY PanelName, BilledYearMonth, PayerRank;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))         AS Panelname,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
            ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
          AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          -- Rule1 UI: FirstBill* params map to ChargeEnteredDate
          AND (@FirstBillFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),
            FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ),
    Ranks AS (
        SELECT Panelname, PayerName_Raw,
               DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM Agg GROUP BY Panelname, PayerName_Raw
    ),
    PanelTotal AS (
        SELECT Panelname, BilledYearMonth, SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
        FROM Agg GROUP BY Panelname, BilledYearMonth
    )
    SELECT PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
    FROM (
        SELECT pt.Panelname AS PanelName, N'' AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
               pt.BilledYearMonth, pt.ClaimCount, pt.TotalCharges
        FROM PanelTotal pt
        UNION ALL
        SELECT a.Panelname, a.PayerName_Raw, CAST(r.PayerRank AS TINYINT),
               a.BilledYearMonth, a.ClaimCount, a.TotalCharges
        FROM Agg a
        JOIN Ranks r ON r.Panelname = a.Panelname AND r.PayerName_Raw = a.PayerName_Raw
    ) x
    ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO

/* =====================================================================
   2) Payor × Panel — ClaimLevelData [All] (no FirstBilled blank gate)
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_PayerByPanel_FullClaims
AS
BEGIN
    SET NOCOUNT ON;

    -- Full ClaimLevelData: every claim row. Blank payer → Unknown.
    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #RawPP
    FROM dbo.ClaimLevelData
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')));

    TRUNCATE TABLE dbo.Cove_PayerByPanel;
    INSERT INTO dbo.Cove_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, PanelName, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP
    ORDER BY PayerName, PanelName;
    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshCove_PayerByPanel_FullClaims (All Claims) completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_PayerByPanel_FullClaims
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
        SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
        FROM dbo.Cove_PayerByPanel
        ORDER BY PayerName, PanelName;
        RETURN;
    END

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- Live path: still full ClaimLevelData; optional filters only when supplied.
    -- FirstBill* (Rule1) → ChargeEnteredDate; FirstBilled* → FirstBilledDate.
    -- Blank FirstBilledDate rows remain when those date filters are NULL.
    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)),''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))
    ORDER BY PayerName, PanelName;
END
GO

PRINT 'FIX_Cove_Monthly_ChargeEntered_PayerByPanel_AllClaims deployed.';
PRINT 'Run: EXEC dbo.usp_RefreshCove_MonthlyBilledProductionSummary;';
PRINT 'Run: EXEC dbo.usp_RefreshCove_PayerByPanel_FullClaims;';
GO

/* =====================================================================
   COVE Production Summary fixes (NOT Northwest)
   DB  : CoveLRN

   New SPs only — does not ALTER legacy usp_RefreshCove_* / usp_GetCove_*
   names except where noted (writes shared snapshot tables).

   1) CPT Breakdown — Count of CPT (not SUM(Units))
      usp_RefreshCove_CPTBreakdown_CountCpt
      usp_GetCove_CPTBreakdown_CountCpt
      → writes dbo.Cove_CPTBreakdown
      Month = FirstBilledDate yyyy-MM (client pivot; NOT ChargeEnteredDate)

   2) Payer Breakdown — Charge Amount always; no blank-payer gate
      usp_RefreshCove_PayerBreakdown_FullCharges
      usp_GetCove_PayerBreakdown_FullCharges
      → writes dbo.Cove_PayerBreakdown
      Month = FirstBilledDate yyyy-MM (matches Cove client)

   3) Payer × Panel — full claim-level (blank payer → Unknown)
      usp_RefreshCove_PayerByPanel_FullClaims
      usp_GetCove_PayerByPanel_FullClaims
      → writes dbo.Cove_PayerByPanel
      Panel = Panelname

   4) Panel Breakdown — FirstBilledDate year/month columns
      dbo.Cove_PanelBreakdown_FirstBilled
      usp_RefreshCove_PanelBreakdown_FirstBilled
      usp_GetCove_PanelBreakdown_FirstBilled
      Filter: FirstBilledDate + ChargeEnteredDate not blank
      Values: COUNT(DISTINCT ClaimID), SUM(ChargeAmount)
   ===================================================================== */
SET NOCOUNT ON;
GO

/* ---------- 1) CPT Count of CPT ---------- */
IF OBJECT_ID('dbo.Cove_CPTBreakdown', 'U') IS NULL
CREATE TABLE dbo.Cove_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    CPTCount        INT             NOT NULL DEFAULT 0,
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CPTBreakdown_CountCpt
AS
BEGIN
    SET NOCOUNT ON;

    -- Count of CPT = COUNT(line rows). Month = FirstBilledDate (client workbook).
    -- BilledUnits column stores the same count (never SUM(Units)) for legacy readers.
    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))               AS CPTCode,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')   AS BilledYearMonth,
        COUNT(*)                                               AS CPTCount,
        CAST(COUNT(*) AS DECIMAL(18,2))                        AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #Raw
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
      AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.Cove_CPTBreakdown;
    INSERT INTO dbo.Cove_CPTBreakdown
        (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw ORDER BY CPTCode, BilledYearMonth;
    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshCove_CPTBreakdown_CountCpt completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CPTBreakdown_CountCpt
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
        SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM dbo.Cove_CPTBreakdown
        ORDER BY CPTCode, BilledYearMonth;
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

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))               AS CPTCode,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')   AS BilledYearMonth,
        COUNT(*)                                               AS CPTCount,
        CAST(COUNT(*) AS DECIMAL(18,2))                        AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
      AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)),''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')
    ORDER BY CPTCode, BilledYearMonth;
END
GO

/* ---------- 2) Payer Breakdown Full Charges ---------- */
IF OBJECT_ID('dbo.Cove_PayerBreakdown', 'U') IS NULL
CREATE TABLE dbo.Cove_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_PayerBreakdown_FullCharges
AS
BEGIN
    SET NOCOUNT ON;

    -- FirstBilledDate month; blank payer → Unknown; always SUM(ChargeAmount).
    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')   AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #RawPM
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.Cove_PayerBreakdown;
    INSERT INTO dbo.Cove_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPM ORDER BY PayerName, BilledYearMonth;
    DROP TABLE IF EXISTS #RawPM;

    PRINT 'usp_RefreshCove_PayerBreakdown_FullCharges completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_PayerBreakdown_FullCharges
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
        SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM dbo.Cove_PayerBreakdown
        ORDER BY PayerName, BilledYearMonth;
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

    -- No blank-payer exclude. ChargeAmount always summed. Month = FirstBilledDate.
    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')   AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)),''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')
    ORDER BY PayerName, BilledYearMonth;
END
GO

/* ---------- 3) Payer × Panel Full Claims ---------- */
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_PayerByPanel_FullClaims
AS
BEGIN
    SET NOCOUNT ON;

    -- Full ClaimLevelData: blank payer → Unknown (do NOT exclude).
    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #RawPP
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')));

    TRUNCATE TABLE dbo.Cove_PayerByPanel;
    INSERT INTO dbo.Cove_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, PanelName, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP ORDER BY PayerName, PanelName;
    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshCove_PayerByPanel_FullClaims completed — '
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

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)),''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))
    ORDER BY PayerName, PanelName;
END
GO

/* ---------- 4) Panel Breakdown FirstBilled ---------- */
IF OBJECT_ID('dbo.Cove_PanelBreakdown_FirstBilled', 'U') IS NULL
CREATE TABLE dbo.Cove_PanelBreakdown_FirstBilled
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_PanelBreakdown_FirstBilled
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.Cove_PanelBreakdown_FirstBilled;
    INSERT INTO dbo.Cove_PanelBreakdown_FirstBilled
        (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw ORDER BY PanelName, PayerName, BilledYearMonth;
    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshCove_PanelBreakdown_FirstBilled completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_PanelBreakdown_FirstBilled
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
        FROM dbo.Cove_PanelBreakdown_FirstBilled
        ORDER BY PanelName, PayerName, BilledYearMonth;
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

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(FirstBilledDate, ''))) <> ''
      AND TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)),''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')
    ORDER BY PanelName, PayerName, BilledYearMonth;
END
GO

PRINT 'FIX_Cove_ProductionSummary_Breakdowns.sql completed.';
PRINT 'Next: EXEC the four RefreshCove_* procs, then redeploy ClaimLineCSVDataCapture + LabMetricsDashboard.';

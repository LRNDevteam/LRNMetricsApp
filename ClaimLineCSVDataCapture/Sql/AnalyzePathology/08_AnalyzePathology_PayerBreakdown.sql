/* =============================================================================
   Analyze Pathology - Payer Breakdown  +  Panel X Payer
   Database : AnalyzePathology        Requires : 05_AnalyzePathology_ProductionBase.sql

   Client logic (sheet "Production Summary"):
     Report 6 - Payer Breakdown  -> AnP_PayerBreakdown / usp_GetAnP_PayerBreakdown
       Rows    : Payer Name (PayerName_Raw)
       Columns : Date of Service month (yyyy-MM)
     Report 3 - Panel X Payer    -> AnP_PayerByPanel / usp_GetAnP_PayerByPanel
       Rows    : Payer Name (PayerName_Raw)
       Columns : Panel Name
     Both:
       Source  : Claim Level
       Filter  : Bill Status not in (Unbilled, Unbilled - Self Pay)
       Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   BilledYearMonth keeps the column name the dashboard reads; for Analyze
   Pathology it holds the Date of Service month.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.AnP_PayerBreakdown', N'U') IS NULL
CREATE TABLE dbo.AnP_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- yyyy-MM of DateofService
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.AnP_PayerByPanel', N'U') IS NULL
CREATE TABLE dbo.AnP_PayerByPanel
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    PanelType    NVARCHAR(MAX)   NOT NULL,   -- Panelname; read back as PanelName
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Payer Breakdown (Payer x Date of Service month)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_PayerBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @ForceLive       BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM   dbo.AnP_PayerBreakdown
        ORDER  BY PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT PayerName,
           FORMAT(DateOfService, 'yyyy-MM') AS BilledYearMonth,
           COUNT(DISTINCT ClaimID)          AS ClaimCount,
           SUM(ChargeAmount)                AS TotalCharges
    FROM   dbo.fn_AnP_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  DateOfService IS NOT NULL
    GROUP  BY PayerName, FORMAT(DateOfService, 'yyyy-MM')
    ORDER  BY PayerName, BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PayerName NVARCHAR(500), BilledYearMonth NVARCHAR(7), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetAnP_PayerBreakdown @ForceLive = 1;

    TRUNCATE TABLE dbo.AnP_PayerBreakdown;

    INSERT INTO dbo.AnP_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshAnP_PayerBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Panel X Payer (Payer x Panel)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_PayerByPanel
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @ForceLive       BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PayerName, PanelType AS PanelName, ClaimCount, TotalCharges
        FROM   dbo.AnP_PayerByPanel
        ORDER  BY PayerName, PanelName;
        RETURN;
    END;

    SELECT PayerName,
           PanelName,
           COUNT(DISTINCT ClaimID) AS ClaimCount,
           SUM(ChargeAmount)       AS TotalCharges
    FROM   dbo.fn_AnP_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
    GROUP  BY PayerName, PanelName
    ORDER  BY PayerName, PanelName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PayerName NVARCHAR(500), PanelName NVARCHAR(MAX), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetAnP_PayerByPanel @ForceLive = 1;

    TRUNCATE TABLE dbo.AnP_PayerByPanel;

    INSERT INTO dbo.AnP_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, PanelName, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshAnP_PayerByPanel completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '08_AnalyzePathology_PayerBreakdown.sql completed.';

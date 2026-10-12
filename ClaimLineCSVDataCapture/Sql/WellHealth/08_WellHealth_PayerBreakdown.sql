/* =============================================================================
   WellHealth - Payer Breakdown  +  Panel X Payer
   Database : WellHealth        Requires : 05_WellHealth_ProductionBase.sql

   Client logic (Production Summary):
     Report 6 - Payer Breakdown  -> WH_PayerBreakdown / usp_GetWH_PayerBreakdown
       Source  : Claim Level
       Filter  : First Billed Date not blank
       Rows    : Payer Name (PayerName_Raw)
       Columns : First Billed Date month (yyyy-MM)
     Report 3 - Panel X Payer    -> WH_PayerByPanel / usp_GetWH_PayerByPanel
       Source  : Claim Level
       Filter  : none (billed and unbilled claims)
       Rows    : Payer Name (PayerName_Raw)
       Columns : Panel Name
     Both: Values COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   BilledYearMonth keeps the column name the dashboard reads.
   Rows come back with payers in display order (payer claim count DESC, then payer
   charges DESC); the dashboard's stable claim-count sort keeps that order for
   payers with the same claim count.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.WH_PayerBreakdown', N'U') IS NULL
CREATE TABLE dbo.WH_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- yyyy-MM of FirstBilledDate
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.WH_PayerByPanel', N'U') IS NULL
CREATE TABLE dbo.WH_PayerByPanel
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
-- Payer Breakdown (Payer x First Billed Date month)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetWH_PayerBreakdown
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
        FROM   dbo.WH_PayerBreakdown
        ORDER  BY SUM(ClaimCount)   OVER (PARTITION BY PayerName) DESC,
                  SUM(TotalCharges) OVER (PARTITION BY PayerName) DESC,
                  PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT PayerName,
           FORMAT(FirstBilledDate, 'yyyy-MM') AS BilledYearMonth,
           COUNT(DISTINCT ClaimID)            AS ClaimCount,
           SUM(ChargeAmount)                  AS TotalCharges
    FROM   dbo.fn_WH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                      @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  FirstBilledDate IS NOT NULL
    GROUP  BY PayerName, FORMAT(FirstBilledDate, 'yyyy-MM')
    ORDER  BY SUM(COUNT(DISTINCT ClaimID)) OVER (PARTITION BY PayerName) DESC,
              SUM(SUM(ChargeAmount))       OVER (PARTITION BY PayerName) DESC,
              PayerName, BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PayerName NVARCHAR(500), BilledYearMonth NVARCHAR(7), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetWH_PayerBreakdown @ForceLive = 1;

    TRUNCATE TABLE dbo.WH_PayerBreakdown;

    INSERT INTO dbo.WH_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshWH_PayerBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- ============================================================
-- Panel X Payer (Payer x Panel)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetWH_PayerByPanel
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
        ;WITH s AS
        (
            SELECT PayerName, CAST(PanelType AS NVARCHAR(1000)) AS PanelName, ClaimCount, TotalCharges
            FROM   dbo.WH_PayerByPanel
        )
        SELECT PayerName, PanelName, ClaimCount, TotalCharges
        FROM   s
        ORDER  BY SUM(ClaimCount)   OVER (PARTITION BY PayerName) DESC,
                  SUM(TotalCharges) OVER (PARTITION BY PayerName) DESC,
                  PayerName, PanelName;
        RETURN;
    END;

    SELECT PayerName,
           PanelName,
           COUNT(DISTINCT ClaimID) AS ClaimCount,
           SUM(ChargeAmount)       AS TotalCharges
    FROM   dbo.fn_WH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                      @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    GROUP  BY PayerName, PanelName
    ORDER  BY SUM(COUNT(DISTINCT ClaimID)) OVER (PARTITION BY PayerName) DESC,
              SUM(SUM(ChargeAmount))       OVER (PARTITION BY PayerName) DESC,
              PayerName, PanelName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PayerName NVARCHAR(500), PanelName NVARCHAR(MAX), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetWH_PayerByPanel @ForceLive = 1;

    TRUNCATE TABLE dbo.WH_PayerByPanel;

    INSERT INTO dbo.WH_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, PanelName, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshWH_PayerByPanel completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '08_WellHealth_PayerBreakdown.sql completed.';

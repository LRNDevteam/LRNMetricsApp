/* =============================================================================
   PNC - Payer Breakdown  +  Panel X Payer
   Database : PNC        Requires : 05_PNC_ProductionBase.sql

   Payer Breakdown:
     Filter  : FirstBilledDate is a date
     Rows    : PayerName_Raw
     Columns : ChargeEnteredDate month
     Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Panel X Payer:
     Filter  : FirstBilledDate is a date
     Rows    : PayerName_Raw
     Columns : Panelname
     Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'PNC'
BEGIN
	RAISERROR('Run 08_PNC_PayerBreakdown.sql on the PNC database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.PNC_PayerBreakdown', N'U') IS NULL
CREATE TABLE dbo.PNC_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.PNC_PayerByPanel', N'U') IS NULL
CREATE TABLE dbo.PNC_PayerByPanel
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    PanelType    NVARCHAR(MAX)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_PayerBreakdown
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
        FROM   dbo.PNC_PayerBreakdown
        ORDER  BY SUM(ClaimCount)   OVER (PARTITION BY PayerName) DESC,
                  SUM(TotalCharges) OVER (PARTITION BY PayerName) DESC,
                  PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT PayerName,
           FORMAT(ChargeEnteredDate, 'yyyy-MM') AS BilledYearMonth,
           COUNT(DISTINCT ClaimID)              AS ClaimCount,
           SUM(ChargeAmount)                    AS TotalCharges
    FROM   dbo.fn_PNC_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  ChargeEnteredDate IS NOT NULL
    GROUP  BY PayerName, FORMAT(ChargeEnteredDate, 'yyyy-MM')
    ORDER  BY SUM(COUNT(DISTINCT ClaimID)) OVER (PARTITION BY PayerName) DESC,
              SUM(SUM(ChargeAmount))       OVER (PARTITION BY PayerName) DESC,
              PayerName, BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PayerName NVARCHAR(500), BilledYearMonth NVARCHAR(7), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetPNC_PayerBreakdown @ForceLive = 1;

    TRUNCATE TABLE dbo.PNC_PayerBreakdown;

    INSERT INTO dbo.PNC_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshPNC_PayerBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_PayerByPanel
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
        FROM   dbo.PNC_PayerByPanel
        ORDER  BY ClaimCount DESC, TotalCharges DESC, PayerName, PanelName;
        RETURN;
    END;

    SELECT PayerName,
           PanelName,
           COUNT(DISTINCT ClaimID) AS ClaimCount,
           SUM(ChargeAmount)       AS TotalCharges
    FROM   dbo.fn_PNC_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
    GROUP  BY PayerName, PanelName
    ORDER  BY SUM(COUNT(DISTINCT ClaimID)) OVER (PARTITION BY PayerName) DESC,
              PayerName, PanelName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PayerName NVARCHAR(500), PanelName NVARCHAR(MAX), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetPNC_PayerByPanel @ForceLive = 1;

    TRUNCATE TABLE dbo.PNC_PayerByPanel;

    INSERT INTO dbo.PNC_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, PanelName, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshPNC_PayerByPanel completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshPNC_PayerBreakdown;
EXEC dbo.usp_RefreshPNC_PayerByPanel;
GO

PRINT '08_PNC_PayerBreakdown.sql completed.';
GO

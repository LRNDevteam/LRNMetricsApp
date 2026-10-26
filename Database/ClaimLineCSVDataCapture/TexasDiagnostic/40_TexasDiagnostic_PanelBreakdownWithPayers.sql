/* =============================================================================
   TexasDiagnostic - Panel Breakdown
   Database : TexasDiagnostic        Requires : 05_TexasDiagnostic_ProductionBase.sql

   Filter  : FirstBilledDate is a date
   Rows    : Panelname (payers under each panel)
   Columns : ChargeEnteredDate month
   Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract: PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
	RAISERROR('Run 40_TexasDiagnostic_PanelBreakdownWithPayers.sql on the TexasDiagnostic database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.TD_PanelBreakdownWithPayers', N'U') IS NULL
CREATE TABLE dbo.TD_PanelBreakdownWithPayers
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

CREATE OR ALTER PROCEDURE dbo.usp_GetTD_PanelBreakdownWithPayers
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
        SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
        FROM   dbo.TD_PanelBreakdownWithPayers
        ORDER  BY SUM(ClaimCount)   OVER (PARTITION BY PanelName) DESC,
                  SUM(TotalCharges) OVER (PARTITION BY PanelName) DESC,
                  PanelName, PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT CAST(PanelName AS NVARCHAR(500))     AS PanelName,
           CAST(PayerName AS NVARCHAR(500))     AS PayerName,
           FORMAT(ChargeEnteredDate, 'yyyy-MM') AS BilledYearMonth,
           COUNT(DISTINCT ClaimID)              AS ClaimCount,
           SUM(ChargeAmount)                    AS TotalCharges
    FROM   dbo.fn_TD_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  ChargeEnteredDate IS NOT NULL
    GROUP  BY PanelName, PayerName, FORMAT(ChargeEnteredDate, 'yyyy-MM')
    ORDER  BY SUM(COUNT(DISTINCT ClaimID)) OVER (PARTITION BY PanelName) DESC,
              SUM(SUM(ChargeAmount))       OVER (PARTITION BY PanelName) DESC,
              PanelName, PayerName, BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_PanelBreakdownWithPayers
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName NVARCHAR(500), PayerName NVARCHAR(500), BilledYearMonth NVARCHAR(7),
        ClaimCount INT, TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetTD_PanelBreakdownWithPayers @ForceLive = 1;

    TRUNCATE TABLE dbo.TD_PanelBreakdownWithPayers;

    INSERT INTO dbo.TD_PanelBreakdownWithPayers (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshTD_PanelBreakdownWithPayers completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshTD_PanelBreakdownWithPayers;
GO

PRINT '40_TexasDiagnostic_PanelBreakdownWithPayers.sql completed.';
GO

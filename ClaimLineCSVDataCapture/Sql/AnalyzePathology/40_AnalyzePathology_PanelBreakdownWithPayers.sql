/* =============================================================================
   Analyze Pathology - Panel Breakdown (payer drill-down)
   Database : AnalyzePathology        Requires : 05_AnalyzePathology_ProductionBase.sql

   Use this instead of Sql/40_AllLabs_PanelBreakdownWithPayers.sql, which
   buckets by the billed month; the client wants Date of Service here.

   Client logic (sheet "Production Summary", report 4):
     Source  : Claim Level
     Filter  : Bill Status not in (Unbilled, Unbilled - Self Pay)
     Rows    : Panel Name (payers listed under each panel)
     Columns : Date of Service month (yyyy-MM)
     Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract (SqlLabProductionSummaryRepository.GetPanelBreakdownAsync):
     PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges
     The dashboard sums the payer rows into the panel row; ClaimLevelData holds
     one row per claim, so that sum is the panel's distinct claim count.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.AnP_PanelBreakdownWithPayers', N'U') IS NULL
CREATE TABLE dbo.AnP_PanelBreakdownWithPayers
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName       NVARCHAR(500)   NOT NULL,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- yyyy-MM of DateofService
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_PanelBreakdownWithPayers
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
        FROM   dbo.AnP_PanelBreakdownWithPayers
        ORDER  BY PanelName, PayerName, BilledYearMonth;
        RETURN;
    END;

    SELECT CAST(PanelName AS NVARCHAR(500)) AS PanelName,
           CAST(PayerName AS NVARCHAR(500)) AS PayerName,
           FORMAT(DateOfService, 'yyyy-MM') AS BilledYearMonth,
           COUNT(DISTINCT ClaimID)          AS ClaimCount,
           SUM(ChargeAmount)                AS TotalCharges
    FROM   dbo.fn_AnP_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 1
      AND  DateOfService IS NOT NULL
    GROUP  BY PanelName, PayerName, FORMAT(DateOfService, 'yyyy-MM')
    ORDER  BY PanelName, PayerName, BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_PanelBreakdownWithPayers
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName NVARCHAR(500), PayerName NVARCHAR(500), BilledYearMonth NVARCHAR(7),
        ClaimCount INT, TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetAnP_PanelBreakdownWithPayers @ForceLive = 1;

    TRUNCATE TABLE dbo.AnP_PanelBreakdownWithPayers;

    INSERT INTO dbo.AnP_PanelBreakdownWithPayers (PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshAnP_PanelBreakdownWithPayers completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '40_AnalyzePathology_PanelBreakdownWithPayers.sql completed.';

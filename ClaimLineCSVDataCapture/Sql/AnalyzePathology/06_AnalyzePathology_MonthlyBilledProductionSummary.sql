/* =============================================================================
   Analyze Pathology - Monthly Claim Production Summary
   Database : AnalyzePathology        Requires : 05_AnalyzePathology_ProductionBase.sql

   Client logic (sheet "Production Summary", report 1):
     Source  : Claim Level
     Filter  : Bill Status not in (Unbilled, Unbilled - Self Pay)
     Rows    : Panel Name, then Top 3 Insurance by claim count within the panel
     Columns : First Billed Date month (yyyy-MM)
     Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract (SqlLabProductionSummaryRepository.GetMonthlyAsync):
     PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
     PayerRank 0 = panel total across all payers, 1-3 = top payers.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.AnP_MonthlyBilledProductionSummary', N'U') IS NULL
CREATE TABLE dbo.AnP_MonthlyBilledProductionSummary
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(MAX)   NOT NULL,   -- Panelname
    PayerName       NVARCHAR(500)   NOT NULL,   -- '' on the PayerRank 0 panel-total row
    PayerRank       TINYINT         NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- yyyy-MM of FirstBilledDate
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_MonthlyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @ForceLive       BIT           = 0      -- 1 = ignore the snapshot (used by the refresh SP)
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PanelType AS PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
        FROM   dbo.AnP_MonthlyBilledProductionSummary
        ORDER  BY PanelName, BilledYearMonth, PayerRank;
        RETURN;
    END;

    ;WITH Base AS
    (
        SELECT PanelName, PayerName, ClaimID, ChargeAmount,
               FORMAT(FirstBilledDate, 'yyyy-MM') AS BilledYearMonth
        FROM   dbo.fn_AnP_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                           @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
        WHERE  IsBilled = 1
          AND  FirstBilledDate IS NOT NULL
    ),
    PayerRanks AS
    (
        SELECT PanelName, PayerName,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(ChargeAmount) DESC, PayerName) AS PayerRank
        FROM   Base
        GROUP  BY PanelName, PayerName
    ),
    PanelMonth AS
    (
        SELECT PanelName, BilledYearMonth,
               COUNT(DISTINCT ClaimID) AS ClaimCount, SUM(ChargeAmount) AS TotalCharges
        FROM   Base
        GROUP  BY PanelName, BilledYearMonth
    ),
    PayerMonth AS
    (
        SELECT PanelName, PayerName, BilledYearMonth,
               COUNT(DISTINCT ClaimID) AS ClaimCount, SUM(ChargeAmount) AS TotalCharges
        FROM   Base
        GROUP  BY PanelName, PayerName, BilledYearMonth
    )
    SELECT PanelName, CAST(N'' AS NVARCHAR(500)) AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
           BilledYearMonth, ClaimCount, TotalCharges
    FROM   PanelMonth
    UNION ALL
    SELECT pm.PanelName, pm.PayerName, CAST(r.PayerRank AS TINYINT),
           pm.BilledYearMonth, pm.ClaimCount, pm.TotalCharges
    FROM   PayerMonth pm
    JOIN   PayerRanks r ON r.PanelName = pm.PanelName AND r.PayerName = pm.PayerName
    WHERE  r.PayerRank <= 3
    ORDER  BY PanelName, BilledYearMonth, PayerRank;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName       NVARCHAR(MAX), PayerName NVARCHAR(500), PayerRank TINYINT,
        BilledYearMonth NVARCHAR(7),   ClaimCount INT,          TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetAnP_MonthlyBilledProductionSummary @ForceLive = 1;

    TRUNCATE TABLE dbo.AnP_MonthlyBilledProductionSummary;

    INSERT INTO dbo.AnP_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshAnP_MonthlyBilledProductionSummary completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '06_AnalyzePathology_MonthlyBilledProductionSummary.sql completed.';

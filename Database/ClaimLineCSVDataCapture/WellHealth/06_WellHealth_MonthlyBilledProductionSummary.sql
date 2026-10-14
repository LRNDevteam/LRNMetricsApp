/* =============================================================================
   WellHealth - Monthly Claim Production Summary
   Database : WellHealth        Requires : 05_WellHealth_ProductionBase.sql

   Client logic (Production Summary, report 1):
     Source  : Claim Level
     Filter  : First Billed Date not blank
     Rows    : Panel Name, then Top 3 Insurance by claim count within the panel
     Columns : First Billed Date month (yyyy-MM)
     Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract (SqlLabProductionSummaryRepository.GetMonthlyAsync):
     PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
     PayerRank 0 = panel total across all payers, 1-3 = top payers.
     Rows come back in display order: panel claim count DESC, then panel charges
     DESC, then PayerRank. The dashboard's sort by claim count is stable, so panels
     with the same claim count keep the higher-charge panel first.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.WH_MonthlyBilledProductionSummary', N'U') IS NULL
CREATE TABLE dbo.WH_MonthlyBilledProductionSummary
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

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_MonthlyBilledProductionSummary
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
        ;WITH s AS
        (
            SELECT CAST(PanelType AS NVARCHAR(1000)) AS PanelName, PayerName, PayerRank,
                   BilledYearMonth, ClaimCount, TotalCharges
            FROM   dbo.WH_MonthlyBilledProductionSummary
        )
        SELECT PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
        FROM   s
        ORDER  BY SUM(CASE WHEN PayerRank = 0 THEN ClaimCount   ELSE 0 END) OVER (PARTITION BY PanelName) DESC,
                  SUM(CASE WHEN PayerRank = 0 THEN TotalCharges ELSE 0 END) OVER (PARTITION BY PanelName) DESC,
                  PanelName, PayerRank, BilledYearMonth;
        RETURN;
    END;

    ;WITH Base AS
    (
        SELECT PanelName, PayerName, ClaimID, ChargeAmount,
               FORMAT(FirstBilledDate, 'yyyy-MM') AS BilledYearMonth
        FROM   dbo.fn_WH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
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
    ),
    PanelTotals AS
    (
        SELECT PanelName, COUNT(DISTINCT ClaimID) AS PanelClaims, SUM(ChargeAmount) AS PanelCharges
        FROM   Base
        GROUP  BY PanelName
    ),
    OutRows AS
    (
        SELECT PanelName, CAST(N'' AS NVARCHAR(500)) AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
               BilledYearMonth, ClaimCount, TotalCharges
        FROM   PanelMonth
        UNION ALL
        SELECT pm.PanelName, pm.PayerName, CAST(r.PayerRank AS TINYINT),
               pm.BilledYearMonth, pm.ClaimCount, pm.TotalCharges
        FROM   PayerMonth pm
        JOIN   PayerRanks r ON r.PanelName = pm.PanelName AND r.PayerName = pm.PayerName
        WHERE  r.PayerRank <= 3
    )
    SELECT x.PanelName, x.PayerName, x.PayerRank, x.BilledYearMonth, x.ClaimCount, x.TotalCharges
    FROM   OutRows x
    JOIN   PanelTotals t ON t.PanelName = x.PanelName
    ORDER  BY t.PanelClaims DESC, t.PanelCharges DESC, x.PanelName, x.PayerRank, x.BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName       NVARCHAR(MAX), PayerName NVARCHAR(500), PayerRank TINYINT,
        BilledYearMonth NVARCHAR(7),   ClaimCount INT,          TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetWH_MonthlyBilledProductionSummary @ForceLive = 1;

    TRUNCATE TABLE dbo.WH_MonthlyBilledProductionSummary;

    INSERT INTO dbo.WH_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshWH_MonthlyBilledProductionSummary completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '06_WellHealth_MonthlyBilledProductionSummary.sql completed.';

/* =============================================================================
   TexasDiagnostic - Monthly Claim Production Summary
   Database : TexasDiagnostic        Requires : 05_TexasDiagnostic_ProductionBase.sql

   Filter  : FirstBilledDate is a date
   Rows    : Panelname, then Top 5 PayerName_Raw by claim count
   Columns : ChargeEnteredDate month (yyyy-MM), plus year and grand total on the page
   Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract: PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
   PayerRank 0 = panel total. 1-5 = top payers.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
	RAISERROR('Run 06_TexasDiagnostic_MonthlyBilledProductionSummary.sql on the TexasDiagnostic database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.TD_MonthlyBilledProductionSummary', N'U') IS NULL
CREATE TABLE dbo.TD_MonthlyBilledProductionSummary
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

CREATE OR ALTER PROCEDURE dbo.usp_GetTD_MonthlyBilledProductionSummary
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
            SELECT CAST(PanelType AS NVARCHAR(1000)) AS PanelName, PayerName, PayerRank,
                   BilledYearMonth, ClaimCount, TotalCharges
            FROM   dbo.TD_MonthlyBilledProductionSummary
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
               FORMAT(ChargeEnteredDate, 'yyyy-MM') AS BilledYearMonth
        FROM   dbo.fn_TD_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                           @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
        WHERE  IsBilled = 1
          AND  ChargeEnteredDate IS NOT NULL
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
        WHERE  r.PayerRank <= 5
    )
    SELECT x.PanelName, x.PayerName, x.PayerRank, x.BilledYearMonth, x.ClaimCount, x.TotalCharges
    FROM   OutRows x
    JOIN   PanelTotals t ON t.PanelName = x.PanelName
    ORDER  BY t.PanelClaims DESC, t.PanelCharges DESC, x.PanelName, x.PayerRank, x.BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName       NVARCHAR(MAX), PayerName NVARCHAR(500), PayerRank TINYINT,
        BilledYearMonth NVARCHAR(7),   ClaimCount INT,          TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetTD_MonthlyBilledProductionSummary @ForceLive = 1;

    TRUNCATE TABLE dbo.TD_MonthlyBilledProductionSummary;

    INSERT INTO dbo.TD_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshTD_MonthlyBilledProductionSummary completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshTD_MonthlyBilledProductionSummary;
GO

PRINT '06_TexasDiagnostic_MonthlyBilledProductionSummary.sql completed.';
GO

/* =============================================================================
   WellHealth - Unbilled X Aging
   Database : WellHealth        Requires : 05_WellHealth_ProductionBase.sql

   Client logic (Production Summary, report 5):
     Source  : Claim Level
     Filter  : First Billed Date blank
     Rows    : Panel Name
     Columns : Aging DOS (AgingDOS: Current / 30+ / 60+ / 90+ / 120+)
     Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract (SqlLabProductionSummaryRepository.GetUnbilledAgingAsync):
     PanelName, AgingBucket, ClaimCount, TotalCharges
     Rows come back with panels in display order (panel claim count DESC, then
     panel charges DESC).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.WH_UnbilledAging', N'U') IS NULL
CREATE TABLE dbo.WH_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500)   NOT NULL,   -- Panelname
    AgingBucket  NVARCHAR(100)   NOT NULL,   -- AgingDOS
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_UnbilledAging
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
        SELECT PanelName, AgingBucket, ClaimCount, TotalCharges
        FROM   dbo.WH_UnbilledAging
        ORDER  BY SUM(ClaimCount)   OVER (PARTITION BY PanelName) DESC,
                  SUM(TotalCharges) OVER (PARTITION BY PanelName) DESC,
                  PanelName, AgingBucket;
        RETURN;
    END;

    SELECT CAST(PanelName AS NVARCHAR(500)) AS PanelName,
           CAST(AgingDOS  AS NVARCHAR(100)) AS AgingBucket,
           COUNT(DISTINCT ClaimID)          AS ClaimCount,
           SUM(ChargeAmount)                AS TotalCharges
    FROM   dbo.fn_WH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                      @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 0
    GROUP  BY PanelName, AgingDOS
    ORDER  BY SUM(COUNT(DISTINCT ClaimID)) OVER (PARTITION BY PanelName) DESC,
              SUM(SUM(ChargeAmount))       OVER (PARTITION BY PanelName) DESC,
              PanelName, AgingBucket;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PanelName NVARCHAR(500), AgingBucket NVARCHAR(100), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetWH_UnbilledAging @ForceLive = 1;

    TRUNCATE TABLE dbo.WH_UnbilledAging;

    INSERT INTO dbo.WH_UnbilledAging (PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshWH_UnbilledAging completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '09_WellHealth_UnbilledAging.sql completed.';

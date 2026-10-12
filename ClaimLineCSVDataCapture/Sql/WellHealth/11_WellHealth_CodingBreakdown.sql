/* =============================================================================
   WellHealth - Coding (Unbilled) Breakdown
   Database : WellHealth        Requires : 05_WellHealth_ProductionBase.sql

   Not part of the client's Production Summary requirement - same shape as
   Analyze Pathology so the dashboard's Coding tab has data:
     Source    : Claim Level, unbilled claims (First Billed Date blank)
     Row       : Panel Name
     Drilldown : CPTCodeXUnitsXModifier within the panel
     Values    : COUNT(DISTINCT AccessionNumber, falling back to ClaimID), SUM(ChargeAmount)

   Result contract (SqlLabProductionSummaryRepository.GetCodingAsync), two result sets:
     1) PanelName, ClaimCount, TotalCharges
     2) PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.WH_CodingPanelSummary', N'U') IS NULL
CREATE TABLE dbo.WH_CodingPanelSummary
(
    SummaryId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500) NOT NULL,
    ClaimCount   INT           NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2) NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME      NOT NULL DEFAULT GETDATE()
);
GO

IF OBJECT_ID(N'dbo.WH_CodingCPTDetail', N'U') IS NULL
CREATE TABLE dbo.WH_CodingCPTDetail
(
    DetailId               INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName              NVARCHAR(500)  NOT NULL,
    CPTCodeXUnitsXModifier NVARCHAR(MAX)  NOT NULL,
    ClaimCount             INT            NOT NULL DEFAULT 0,
    TotalCharges           DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt            DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_CodingBreakdown
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

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PanelName, ClaimCount, TotalCharges
        FROM   dbo.WH_CodingPanelSummary
        ORDER  BY TotalCharges DESC;

        SELECT PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
        FROM   dbo.WH_CodingCPTDetail
        ORDER  BY PanelName, TotalCharges DESC;
        RETURN;
    END;

    SELECT PanelName, VisitKey, ChargeAmount, CPTCodeXUnitsXModifier
    INTO   #Unbilled
    FROM   dbo.fn_WH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                      @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 0;

    SELECT PanelName, COUNT(DISTINCT VisitKey) AS ClaimCount, SUM(ChargeAmount) AS TotalCharges
    FROM   #Unbilled
    GROUP  BY PanelName
    ORDER  BY TotalCharges DESC;

    SELECT PanelName, CPTCodeXUnitsXModifier, COUNT(DISTINCT VisitKey) AS ClaimCount, SUM(ChargeAmount) AS TotalCharges
    FROM   #Unbilled
    WHERE  CPTCodeXUnitsXModifier <> ''
    GROUP  BY PanelName, CPTCodeXUnitsXModifier
    ORDER  BY PanelName, TotalCharges DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_CodingBreakdown_Unbilled
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PanelName, VisitKey, ChargeAmount, CPTCodeXUnitsXModifier
    INTO   #Unbilled
    FROM   dbo.vw_WH_ProductionClaims
    WHERE  IsBilled = 0;

    TRUNCATE TABLE dbo.WH_CodingPanelSummary;
    INSERT INTO dbo.WH_CodingPanelSummary (PanelName, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, COUNT(DISTINCT VisitKey), SUM(ChargeAmount), GETDATE()
    FROM   #Unbilled
    GROUP  BY PanelName;

    TRUNCATE TABLE dbo.WH_CodingCPTDetail;
    INSERT INTO dbo.WH_CodingCPTDetail (PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, CPTCodeXUnitsXModifier, COUNT(DISTINCT VisitKey), SUM(ChargeAmount), GETDATE()
    FROM   #Unbilled
    WHERE  CPTCodeXUnitsXModifier <> ''
    GROUP  BY PanelName, CPTCodeXUnitsXModifier;

    PRINT 'usp_RefreshWH_CodingBreakdown_Unbilled completed.';
END
GO

PRINT '11_WellHealth_CodingBreakdown.sql completed.';

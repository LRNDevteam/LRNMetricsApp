/* =============================================================================
   TexasDiagnostic - CPT Breakdown
   Database : TexasDiagnostic        Requires : 05_TexasDiagnostic_ProductionBase.sql

   Source  : Line Level
   Filter  : none
   Rows    : CPT Code, sorted by claim count
   Columns : ChargeEnteredDate month (yyyy-MM), plus year and grand total on the page
   Values  : COUNT(ClaimID) (every line, not distinct), SUM(ChargeAmount)

   Result contract: CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
   The page shows BilledUnits as the count column, so it carries COUNT(ClaimID) too.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
	RAISERROR('Run 10_TexasDiagnostic_CPTBreakdown.sql on the TexasDiagnostic database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.TD_CPTBreakdown', N'U') IS NULL
CREATE TABLE dbo.TD_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    CPTCount        INT             NOT NULL DEFAULT 0,
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetTD_CPTBreakdown
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
        SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM   dbo.TD_CPTBreakdown
        ORDER  BY CPTCode, BilledYearMonth;
        RETURN;
    END;

    SELECT CAST(CPTCode AS NVARCHAR(200))                    AS CPTCode,
           FORMAT(ChargeEnteredDate, 'yyyy-MM')              AS BilledYearMonth,
           COUNT(ClaimID)                                    AS CPTCount,
           CAST(COUNT(ClaimID) AS DECIMAL(18,2))             AS BilledUnits,
           CAST(ISNULL(SUM(ChargeAmount), 0) AS DECIMAL(18,2)) AS TotalCharges
    FROM   dbo.fn_TD_ProductionLines(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                      @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  ChargeEnteredDate IS NOT NULL
    GROUP  BY CPTCode, FORMAT(ChargeEnteredDate, 'yyyy-MM')
    ORDER  BY CPTCode, BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        CPTCode NVARCHAR(200), BilledYearMonth NVARCHAR(7), CPTCount INT,
        BilledUnits DECIMAL(18,2), TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetTD_CPTBreakdown @ForceLive = 1;

    TRUNCATE TABLE dbo.TD_CPTBreakdown;

    INSERT INTO dbo.TD_CPTBreakdown (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshTD_CPTBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshTD_CPTBreakdown;
GO

PRINT '10_TexasDiagnostic_CPTBreakdown.sql completed.';
GO

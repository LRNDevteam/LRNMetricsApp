/* =============================================================================
   CoreBio - CPT Breakdown
   Database : CoreBio        Requires : 05_CoreBio_ProductionBase.sql

   Source  : Line Level
   Filter  : none
   Rows    : CPT Code, sorted by claim count
   Values  : COUNT(DISTINCT ClaimID), SUM(Units), SUM(ChargeAmount)

   usp_GetCB_CPTBreakdownTotals is what the page reads:
     RowType, CPTCode, ClaimCount, TotalCharges, SortOrder, TotalUnits
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'CoreBio'
BEGIN
	RAISERROR('Run 10_CoreBio_CPTBreakdown.sql on the CoreBio database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.CB_CPTBreakdown', N'U') IS NULL
CREATE TABLE dbo.CB_CPTBreakdown
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

CREATE OR ALTER PROCEDURE dbo.usp_GetCB_CPTBreakdown
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
        FROM   dbo.CB_CPTBreakdown
        ORDER  BY CPTCode, BilledYearMonth;
        RETURN;
    END;

    SELECT CAST(CPTCode AS NVARCHAR(200))   AS CPTCode,
           FORMAT(DateOfService, 'yyyy-MM') AS BilledYearMonth,
           COUNT(DISTINCT ClaimID)          AS CPTCount,
           SUM(Units)                       AS BilledUnits,
           SUM(ChargeAmount)                AS TotalCharges
    FROM   dbo.fn_CB_ProductionLines(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                      @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  DateOfService IS NOT NULL
    GROUP  BY CPTCode, FORMAT(DateOfService, 'yyyy-MM')
    ORDER  BY CPTCode, BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCB_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        CPTCode NVARCHAR(200), BilledYearMonth NVARCHAR(7), CPTCount INT,
        BilledUnits DECIMAL(18,2), TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetCB_CPTBreakdown @ForceLive = 1;

    TRUNCATE TABLE dbo.CB_CPTBreakdown;

    INSERT INTO dbo.CB_CPTBreakdown (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshCB_CPTBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCB_CPTBreakdownTotals
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

    ;WITH d AS
    (
        SELECT CAST(CPTCode AS NVARCHAR(200))                        AS CPTCode,
               COUNT(DISTINCT ClaimID)                               AS ClaimCount,
               CAST(ISNULL(SUM(Units), 0) AS DECIMAL(18,2))          AS TotalUnits,
               CAST(ISNULL(SUM(ChargeAmount), 0) AS DECIMAL(18,2))   AS TotalCharges
        FROM   dbo.fn_CB_ProductionLines(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                          @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
        GROUP  BY CPTCode
    ),
    g AS
    (
        SELECT 'D' AS RowType, CPTCode, ClaimCount, TotalUnits, TotalCharges FROM d
        UNION ALL
        SELECT 'T', N'',
               ISNULL(SUM(ClaimCount), 0),
               CAST(ISNULL(SUM(TotalUnits), 0) AS DECIMAL(18,2)),
               CAST(ISNULL(SUM(TotalCharges), 0) AS DECIMAL(18,2))
        FROM d
    )
    SELECT RowType,
           CASE WHEN RowType = 'T' THEN N'Grand Total' ELSE CPTCode END AS CPTCode,
           ClaimCount,
           TotalCharges,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                       ClaimCount DESC, TotalCharges DESC, CPTCode) AS SortOrder,
           TotalUnits
    FROM   g
    ORDER  BY SortOrder;
END
GO

EXEC dbo.usp_RefreshCB_CPTBreakdown;
GO

PRINT '10_CoreBio_CPTBreakdown.sql completed.';
GO

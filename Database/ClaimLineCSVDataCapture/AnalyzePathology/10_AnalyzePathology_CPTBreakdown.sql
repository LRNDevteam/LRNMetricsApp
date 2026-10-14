/* =============================================================================
   Analyze Pathology - CPT Breakdown
   Database : AnalyzePathology        Requires : 05_AnalyzePathology_ProductionBase.sql

   Client logic (sheet "Production Summary", report 7):
     Source  : Line Level
     Filter  : none (billed and unbilled lines)
     Rows    : CPT Code
     Values  : Claim Count = COUNT(DISTINCT ClaimID), Charge Amount = SUM(ChargeAmount)
               sorted by claim count

   The CPT Breakdown tab / Excel sheet show totals only (client feedback):
   usp_GetAnP_CPTBreakdownTotals returns one row per CPT code, sorted by claim
   count, plus the Grand Total row. usp_GetAnP_CPTBreakdown (by Date of Service
   month) is kept for the snapshot table and any month-level consumers.

   Result contract (SqlLabProductionSummaryRepository.GetCptBreakdownAsync):
     CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
     CPTCount    = COUNT(DISTINCT ClaimID)
     BilledUnits = SUM(Units)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.AnP_CPTBreakdown', N'U') IS NULL
CREATE TABLE dbo.AnP_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- yyyy-MM of DateofService
    CPTCount        INT             NOT NULL DEFAULT 0,   -- COUNT(DISTINCT ClaimID)
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CPTBreakdown
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
        FROM   dbo.AnP_CPTBreakdown
        ORDER  BY CPTCode, BilledYearMonth;
        RETURN;
    END;

    SELECT CAST(CPTCode AS NVARCHAR(200))   AS CPTCode,
           FORMAT(DateOfService, 'yyyy-MM') AS BilledYearMonth,
           COUNT(DISTINCT ClaimID)          AS CPTCount,
           SUM(Units)                       AS BilledUnits,
           SUM(ChargeAmount)                AS TotalCharges
    FROM   dbo.fn_AnP_ProductionLines(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                      @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  DateOfService IS NOT NULL
    GROUP  BY CPTCode, FORMAT(DateOfService, 'yyyy-MM')
    ORDER  BY CPTCode, BilledYearMonth;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        CPTCode NVARCHAR(200), BilledYearMonth NVARCHAR(7), CPTCount INT,
        BilledUnits DECIMAL(18,2), TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetAnP_CPTBreakdown @ForceLive = 1;

    TRUNCATE TABLE dbo.AnP_CPTBreakdown;

    INSERT INTO dbo.AnP_CPTBreakdown (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshAnP_CPTBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/* -----------------------------------------------------------------------------
   usp_GetAnP_CPTBreakdownTotals - the CPT Breakdown tab and Excel sheet
   (totals only, no month/year columns, per client feedback).

   Result contract (SqlLabProductionSummaryRepository, CptTotalsOnly labs):
     RowType      'D' = one row per CPT code, 'T' = Grand Total (last row)
     CPTCode      CPT code ('Grand Total' on the T row)
     ClaimCount   COUNT(DISTINCT ClaimID) per CPT code; on the T row it is the SUM
                  of the per-CPT counts (client validation 10/07/2026), so a claim
                  billed with several CPT codes is counted once per code
     TotalCharges SUM(ChargeAmount)
     SortOrder    D rows by ClaimCount DESC, TotalCharges DESC, CPTCode; T last
   Always aggregates live (fast on line-level data); no snapshot table.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CPTBreakdownTotals
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
               CAST(ISNULL(SUM(ChargeAmount), 0) AS DECIMAL(18,2))   AS TotalCharges
        FROM   dbo.fn_AnP_ProductionLines(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                          @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
        GROUP  BY CPTCode
    ),
    g AS
    (
        SELECT 'D' AS RowType, CPTCode, ClaimCount, TotalCharges FROM d
        UNION ALL
        SELECT 'T', N'', ISNULL(SUM(ClaimCount), 0), CAST(ISNULL(SUM(TotalCharges), 0) AS DECIMAL(18,2)) FROM d
    )
    SELECT RowType,
           CASE WHEN RowType = 'T' THEN N'Grand Total' ELSE CPTCode END AS CPTCode,
           ClaimCount,
           TotalCharges,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                                       ClaimCount DESC, TotalCharges DESC, CPTCode) AS SortOrder
    FROM   g
    ORDER  BY SortOrder;
END
GO

PRINT '10_AnalyzePathology_CPTBreakdown.sql completed.';

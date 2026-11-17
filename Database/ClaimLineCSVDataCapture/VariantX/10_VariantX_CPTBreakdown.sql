/* =============================================================================
   VariantX – CPT Breakdown (client Production sheet S.No 10)
   Database : VariantX_LRN

   Source  : LineLevelData
   Filter  : N/A (no default date/payer filter; UI filters still apply when set)
   Rows    : CPTCode
   Values  : SUM(Units), SUM(ChargeAmount)   — totals only (no month-wise)
   Sort    : Claim Count DESC  (COUNT DISTINCT ClaimID)

   Page reads usp_GetVarX_CPTBreakdownTotals:
     RowType, CPTCode, ClaimCount, TotalCharges, SortOrder, TotalUnits
   Display columns: Sum of Units + Sum of Charge Amount (Claim Count used for sort).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'VarX_CPTBreakdown')
CREATE TABLE dbo.VarX_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'TOTAL' for sheet-style totals rows
    CPTCount        INT             NOT NULL DEFAULT 0,  -- Claim Count (distinct ClaimID)
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_CPTBreakdownTotals
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

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH d AS
    (
        SELECT
            CAST(LTRIM(RTRIM(CPTCode)) AS NVARCHAR(200)) AS CPTCode,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS ClaimCount,
            CAST(ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS TotalUnits,
            CAST(ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS TotalCharges
        FROM dbo.LineLevelData
        WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, PayerName))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo     IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
        GROUP BY LTRIM(RTRIM(CPTCode))
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
           ROW_NUMBER() OVER (
               ORDER BY CASE WHEN RowType = 'T' THEN 1 ELSE 0 END,
                        ClaimCount DESC, TotalUnits DESC, TotalCharges DESC, CPTCode) AS SortOrder,
           TotalUnits
    FROM g
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_CPTBreakdown
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

    -- Legacy month-wise contract; VariantX page uses usp_GetVarX_CPTBreakdownTotals.
    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM   dbo.VarX_CPTBreakdown
        ORDER  BY CPTCount DESC, BilledUnits DESC, CPTCode, BilledYearMonth;
        RETURN;
    END;

    SELECT
        CAST(LTRIM(RTRIM(CPTCode)) AS NVARCHAR(200)) AS CPTCode,
        CAST('TOTAL' AS NVARCHAR(7)) AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS CPTCount,
        CAST(ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS BilledUnits,
        CAST(ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS TotalCharges
    FROM dbo.LineLevelData
    WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo           IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(CPTCode))
    ORDER BY CPTCount DESC, BilledUnits DESC, CPTCode;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        CAST(LTRIM(RTRIM(CPTCode)) AS NVARCHAR(200)) AS CPTCode,
        CAST('TOTAL' AS NVARCHAR(7)) AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS CPTCount,
        CAST(ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS BilledUnits,
        CAST(ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS DECIMAL(18,2)) AS TotalCharges
    INTO #Raw
    FROM dbo.LineLevelData
    WHERE NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
    GROUP BY LTRIM(RTRIM(CPTCode));

    TRUNCATE TABLE dbo.VarX_CPTBreakdown;

    INSERT INTO dbo.VarX_CPTBreakdown
        (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY CPTCount DESC, BilledUnits DESC, CPTCode;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshVarX_CPTBreakdown completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '10_VariantX_CPTBreakdown.sql completed.';
GO

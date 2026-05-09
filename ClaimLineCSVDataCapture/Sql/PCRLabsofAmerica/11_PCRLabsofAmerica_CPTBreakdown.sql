-- PCRLabsofAmerica — CPT Breakdown (line-level)
-- Rule:
--   Source  : LineLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : CPTCode
--   Columns : ChargeEnteredDate month (yyyy-MM)
--             | CPTCount (COUNT of lines — not SUM of Units)
--             | SUM(Units)
--             | SUM(ChargeAmount)
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_CPTBreakdown')
CREATE TABLE dbo.PCR_CPTBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    CPTCode         NVARCHAR(200)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from ChargeEnteredDate
    CPTCount        INT             NOT NULL DEFAULT 0,   -- COUNT of line rows per CPT per month
    BilledUnits     DECIMAL(18,2)   NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CPTBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                        AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
        COUNT(*)                                                         AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0)         AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #Raw
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.PCR_CPTBreakdown;

    INSERT INTO dbo.PCR_CPTBreakdown
        (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY CPTCode, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshPCR_CPTBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
FROM dbo.PCR_CPTBreakdown ORDER BY CPTCode, BilledYearMonth;
*/

-- ============================================================
-- Step 3: Read stored procedure
-- See usp_GetPCR_MonthlyBilledProductionSummary header for the parameter
-- contract (no params -> snapshot table; any param -> live aggregate).
-- The CPT Breakdown tab only filters on date ranges; payer/panel parameters
-- are accepted for a uniform call signature and otherwise ignored.
-- Source table: dbo.LineLevelData (one row per line item).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CPTBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,   -- accepted for signature parity; not used
    @PanelNames      NVARCHAR(MAX) = NULL,   -- accepted for signature parity; not used
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM    dbo.PCR_CPTBreakdown
        ORDER BY CPTCode, BilledYearMonth;
        RETURN;
    END

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        COUNT(*)                                                 AS CPTCount,
        ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0) AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM   dbo.LineLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY CPTCode, BilledYearMonth;
END
GO

PRINT '11_PCRLabsofAmerica_CPTBreakdown.sql completed.';

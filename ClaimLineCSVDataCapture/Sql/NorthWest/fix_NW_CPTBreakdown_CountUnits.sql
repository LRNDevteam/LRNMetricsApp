/* =====================================================================
   Standalone SP — CPT Breakdown Billed Units = COUNT(Units), not SUM(Units)
   DB  : NWL_LRN

   Do NOT run 09_NorthWest_CPTBreakdown.sql or 14_NorthWest_ReadSPs.sql
   for this change. Those files may be behind live SQL.

   This script creates NEW procedures so the live SPs stay untouched:

     dbo.usp_RefreshNW_CPTBreakdown_CountUnits
     dbo.usp_GetNW_CPTBreakdown_CountUnits

   Result shape (same as usp_GetNW_CPTBreakdown):
     CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges

     CPTCount    = COUNT(*) of line rows
     BilledUnits = COUNT(Units)          -- was SUM(Units)
     TotalCharges= SUM(ChargeAmount)

   After review:
     1) Run this script on NWL_LRN
     2) EXEC dbo.usp_RefreshNW_CPTBreakdown_CountUnits
        (writes COUNT into dbo.NW_CPTBreakdown.BilledUnits)
     3) Point the dashboard at usp_GetNW_CPTBreakdown_CountUnits
        or copy the COUNT(Units) line into the live Get/Refresh SPs.

   Review the live usp_GetNW_CPTBreakdown / usp_RefreshNW_CPTBreakdown
   before replacing them — payer/panel filters may differ from this copy.
   ===================================================================== */
SET NOCOUNT ON;
GO

-- Snapshot refresh: BilledUnits = COUNT(Units)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CPTBreakdown_CountUnits
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                        AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
        COUNT(*)                                                         AS CPTCount,
        CAST(COUNT(Units) AS DECIMAL(18,2))                             AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #Raw
    FROM dbo.LineLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND FirstBilledDate <> ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.NW_CPTBreakdown;

    INSERT INTO dbo.NW_CPTBreakdown
        (CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, RefreshedAt)
    SELECT CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY CPTCode, BilledYearMonth;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshNW_CPTBreakdown_CountUnits completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

-- Read SP: same parameters / result set as usp_GetNW_CPTBreakdown
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CPTBreakdown_CountUnits
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
        FROM    dbo.NW_CPTBreakdown
        ORDER BY CPTCode, BilledYearMonth;
        RETURN;
    END

    SELECT
        LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                AS CPTCode,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')  AS BilledYearMonth,
        COUNT(*)                                                AS CPTCount,
        CAST(COUNT(Units) AS DECIMAL(18,2))                     AS BilledUnits,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM   dbo.LineLevelData
    WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND  NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    GROUP BY LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
             FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
    ORDER BY CPTCode, BilledYearMonth;
END
GO

PRINT 'Created dbo.usp_RefreshNW_CPTBreakdown_CountUnits';
PRINT 'Created dbo.usp_GetNW_CPTBreakdown_CountUnits';
PRINT 'Next: EXEC dbo.usp_RefreshNW_CPTBreakdown_CountUnits';
GO

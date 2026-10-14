-- ============================================================
-- 14_NoResponseBreakdown_LargeLabFix.sql
-- Fixes Msg 10053 (connection aborted) on large labs (NorthWest,
-- >800K rows) when running usp_GetPredictionNoResponseBreakdown.
--
-- ROOT CAUSE
--   The previous version ran GROUP BY / COUNT(DISTINCT ...) directly
--   on NVARCHAR(MAX) expressions (PayerName, VisitNumber) across the
--   whole PayerValidationReport table. Sorting/hashing MAX-typed
--   values forces the engine to assume worst-case row width, so the
--   memory grant explodes and the sort spills massively — on Azure
--   SQL MI the session gets killed mid-result (transport error 10053).
--
-- FIX (same results, same result-set shape)
--   1. ONE scan stages only the qualifying "No Response" rows into a
--      #temp table with BOUNDED types (NVARCHAR(255)/(100), DECIMAL).
--      The No-Response subset is a small fraction of the table.
--   2. All grouping / DISTINCT then runs on the small, typed #temp —
--      tiny memory grant, no spill.
--   3. OPTION (RECOMPILE) so the catch-all (@Filter IS NULL OR ...)
--      predicates compile into a plan for the actual values.
--
-- Deploy AFTER 13_FixNoResponsePctVariance.sql (supersedes only the
-- live SP; usp_PV_ReadNoResponseBreakdown is unchanged).
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionNoResponseBreakdown
(
    @WeekStartDate                        DATE          = NULL,
    @RunId                                NVARCHAR(100) = NULL,
    @FilterPayerName                      NVARCHAR(255) = NULL,
    @FilterForecastingPayability          NVARCHAR(255) = NULL,
    @FilterPayStatus                      NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus               NVARCHAR(100) = NULL,
    @FilterPayerType                      NVARCHAR(100) = NULL,
    @FilterPanelName                      NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus            NVARCHAR(100) = NULL,
    @FilterPayability                     NVARCHAR(100) = NULL,
    @FilterCPTCode                        NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    -- ── Stage 1: single scan → small, bounded-typed temp table ──────────
    CREATE TABLE #NoResp
    (
        PayerName  NVARCHAR(255)  NOT NULL,
        AgeBucket  NVARCHAR(10)   NOT NULL,
        VisitKey   NVARCHAR(100)  NULL,
        VarAllowed DECIMAL(18,4)  NOT NULL,
        VarPaid    DECIMAL(18,4)  NOT NULL
    );

    INSERT INTO #NoResp (PayerName, AgeBucket, VisitKey, VarAllowed, VarPaid)
    SELECT
        CAST(COALESCE(NULLIF(LTRIM(RTRIM(pvr.PayerNameNormalized)), N''),
                      NULLIF(LTRIM(RTRIM(pvr.PayerName)), N''), N'Unknown') AS NVARCHAR(255)),
        CASE
            WHEN d.DaysInt <= 30  THEN N'Current'
            WHEN d.DaysInt <= 60  THEN N'30+'
            WHEN d.DaysInt <= 90  THEN N'60+'
            WHEN d.DaysInt <= 120 THEN N'90+'
            ELSE N'120+'
        END,
        CAST(NULLIF(LTRIM(RTRIM(pvr.VisitNumber)), N'') AS NVARCHAR(100)),
        ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(pvr.Variance_AllowedAmount)), N'')), 0),
        ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(pvr.Variance_PaidAmount)), N'')), 0)
    FROM dbo.PayerValidationReport pvr
    CROSS APPLY (SELECT DaysInt =
        ISNULL(TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(pvr.DaysToDOS)), N'')), 0)) d
    WHERE (@RunId IS NULL OR pvr.RunId = @RunId)
      AND LTRIM(RTRIM(ISNULL(pvr.ForecastingPayability, N''))) IN
          (N'Payable', N'Potentially Payable', N'Payable - Need Action')
      AND LTRIM(RTRIM(ISNULL(pvr.PayStatus, N''))) = N'No Response'
      AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(pvr.PayerNameNormalized)), N''),
            NULLIF(LTRIM(RTRIM(pvr.PayerName)), N''), N'Unknown') = @FilterPayerName)
      AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(pvr.ForecastingPayability)) = @FilterForecastingPayability)
      AND (@FilterPayStatus IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(pvr.PayStatus)), N''), N'(Blank)') = @FilterPayStatus)
      AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(pvr.ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
      AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(pvr.PredictionStatus)) = @FilterPredictionStatus)
      AND (@FilterPayerType IS NULL OR LTRIM(RTRIM(pvr.PayerType)) = @FilterPayerType)
      AND (@FilterPanelName IS NULL OR LTRIM(RTRIM(pvr.PanelName)) = @FilterPanelName)
      AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(pvr.FinalCoverageStatus)) = @FilterFinalCoverageStatus)
      AND (@FilterPayability IS NULL OR LTRIM(RTRIM(pvr.Payability)) = @FilterPayability)
      AND (@FilterCPTCode IS NULL OR LTRIM(RTRIM(pvr.CPTCode)) = @FilterCPTCode)
    OPTION (RECOMPILE);

    -- ── Stage 2: aggregate the small typed subset ────────────────────────
    ;WITH Agg AS
    (
        SELECT
            PayerName,
            AgeBucket,
            LineItemCount   = COUNT(DISTINCT VisitKey),
            VarianceAllowed = SUM(VarAllowed),
            VariancePaid    = SUM(VarPaid)
        FROM #NoResp
        GROUP BY PayerName, AgeBucket
    ),
    Totals AS
    (
        SELECT
            PayerName,
            TotalVarAllowed = SUM(VarianceAllowed),
            TotalVarPaid    = SUM(VariancePaid)
        FROM Agg
        GROUP BY PayerName
    )
    SELECT
        a.PayerName,
        a.AgeBucket,
        a.LineItemCount,
        a.VarianceAllowed,
        a.VariancePaid,
        -- % Var – Allowed = Sum Var – Allowed / Total Var – Allowed × 100
        PctVarianceAllowed = CASE
            WHEN t.TotalVarAllowed = 0 THEN NULL
            ELSE ROUND(
                (CAST(a.VarianceAllowed AS DECIMAL(18,4)) * 100.0)
                / CAST(t.TotalVarAllowed AS DECIMAL(18,4)), 2)
        END,
        -- % Var – Ins. Pmt = Sum Var – Paid / Total Var – Paid × 100
        PctVariancePaid = CASE
            WHEN t.TotalVarPaid = 0 THEN NULL
            ELSE ROUND(
                (CAST(a.VariancePaid AS DECIMAL(18,4)) * 100.0)
                / CAST(t.TotalVarPaid AS DECIMAL(18,4)), 2)
        END,
        TotalVarianceAllowed = t.TotalVarAllowed,
        TotalVariancePaid    = t.TotalVarPaid
    FROM Agg a
    INNER JOIN Totals t ON t.PayerName = a.PayerName
    ORDER BY a.PayerName,
        CASE a.AgeBucket WHEN N'Current' THEN 1 WHEN N'30+' THEN 2 WHEN N'60+' THEN 3
                         WHEN N'90+' THEN 4 ELSE 5 END;

    DROP TABLE #NoResp;
END
GO

/*
-- Verify on the lab DB (should return in seconds now):
EXEC dbo.usp_GetPredictionNoResponseBreakdown;

-- RECOMMENDED for NorthWest: also refresh the PV_* snapshots after each
-- ingestion (10_ChunkedAggregateRefresh_LargeLabs.sql) so the dashboard's
-- unfiltered loads read dbo.PV_NoResponseBreakdown and never touch the
-- live SP at all.
*/

-- ============================================================
-- 13_FixNoResponsePctVariance.sql
-- Deploy on each lab database (e.g. NWL_LRN, CoveLRN).
--
-- Fixes No Response aging percentages:
--   % Var – Allowed = Sum Var – Allowed / Total Var – Allowed × 100
--   % Var – Ins. Pmt = Sum Var – Paid    / Total Var – Paid    × 100
--
-- Total Var = sum of Sum Var across all age buckets for that payer.
-- Example: (-137.13 / -196.66) × 100 = 69.73
--
-- Does NOT edit scripts 03 / 06 / 10 — run THIS file alone to patch.
-- After deploy, either refresh aggregates OR rely on Read SP (recomputes %).
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- Live / refresh path: usp_GetPredictionNoResponseBreakdown
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionNoResponseBreakdown
(
    @WeekStartDate                       DATE          = NULL,
    @RunId                               NVARCHAR(100) = NULL,
    @FilterPayerName                     NVARCHAR(255) = NULL,
    @FilterForecastingPayability         NVARCHAR(255) = NULL,
    @FilterPayStatus                     NVARCHAR(100) = NULL,
    @FilterForecastingPayabilitySubstatus NVARCHAR(100) = NULL,
    @FilterPredictionStatus              NVARCHAR(100) = NULL,
    @FilterPayerType                     NVARCHAR(100) = NULL,
    @FilterPanelName                     NVARCHAR(255) = NULL,
    @FilterFinalCoverageStatus           NVARCHAR(100) = NULL,
    @FilterPayability                    NVARCHAR(100) = NULL,
    @FilterCPTCode                       NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP 1 @RunId = RunId FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL ORDER BY InsertedDateTime DESC;
    END

    ;WITH Base AS
    (
        SELECT
            PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                 NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown'),
            DaysInt = ISNULL(TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM(DaysToDOS)), N'')), 0),
            VarAllowed = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_AllowedAmount)), N'')), 0),
            VarPaid    = ISNULL(TRY_CONVERT(DECIMAL(18,4), NULLIF(LTRIM(RTRIM(Variance_PaidAmount)), N'')), 0),
            VisitKey = NULLIF(LTRIM(RTRIM(VisitNumber)), N'')
        FROM dbo.PayerValidationReport
        WHERE (@RunId IS NULL OR RunId = @RunId)
          AND LTRIM(RTRIM(ISNULL(ForecastingPayability, N''))) IN
              (N'Payable', N'Potentially Payable', N'Payable - Need Action')
          AND LTRIM(RTRIM(ISNULL(PayStatus, N''))) = N'No Response'
          AND (@FilterPayerName IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown') = @FilterPayerName)
          AND (@FilterForecastingPayability IS NULL OR LTRIM(RTRIM(ForecastingPayability)) = @FilterForecastingPayability)
          AND (@FilterPayStatus IS NULL OR COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)') = @FilterPayStatus)
          AND (@FilterForecastingPayabilitySubstatus IS NULL OR LTRIM(RTRIM(ForecastingPayabilitySubstatus)) = @FilterForecastingPayabilitySubstatus)
          AND (@FilterPredictionStatus IS NULL OR LTRIM(RTRIM(PredictionStatus)) = @FilterPredictionStatus)
          AND (@FilterPayerType IS NULL OR LTRIM(RTRIM(PayerType)) = @FilterPayerType)
          AND (@FilterPanelName IS NULL OR LTRIM(RTRIM(PanelName)) = @FilterPanelName)
          AND (@FilterFinalCoverageStatus IS NULL OR LTRIM(RTRIM(FinalCoverageStatus)) = @FilterFinalCoverageStatus)
          AND (@FilterPayability IS NULL OR LTRIM(RTRIM(Payability)) = @FilterPayability)
          AND (@FilterCPTCode IS NULL OR LTRIM(RTRIM(CPTCode)) = @FilterCPTCode)
    ),
    Filtered AS
    (
        SELECT
            PayerName,
            AgeBucket = CASE
                WHEN DaysInt <= 30  THEN N'Current'
                WHEN DaysInt <= 60  THEN N'30+'
                WHEN DaysInt <= 90  THEN N'60+'
                WHEN DaysInt <= 120 THEN N'90+'
                ELSE N'120+'
            END,
            VisitKey, VarAllowed, VarPaid
        FROM Base
    ),
    Agg AS
    (
        SELECT
            PayerName,
            AgeBucket,
            LineItemCount   = COUNT(DISTINCT VisitKey),
            VarianceAllowed = SUM(VarAllowed),
            VariancePaid    = SUM(VarPaid)
        FROM Filtered
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
END
GO

-- ------------------------------------------------------------
-- Snapshot read path: usp_PV_ReadNoResponseBreakdown
-- Recomputes % from stored Sum Var / payer Total Var
-- so UI/Excel stay correct even if PV table still has old %.
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_PV_ReadNoResponseBreakdown
(
    @WeekStartDate    DATE          = NULL,
    @FilterPayerName  NVARCHAR(255) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId NVARCHAR(100);
    SELECT TOP 1 @RunId = RunId FROM dbo.PV_NoResponseBreakdown ORDER BY RefreshedAt DESC;

    SELECT
        PayerName,
        AgeBucket,
        LineItemCount,
        VarianceAllowed,
        VariancePaid,
        PctVarianceAllowed = CASE
            WHEN SUM(VarianceAllowed) OVER (PARTITION BY PayerName) = 0 THEN NULL
            ELSE ROUND(
                (CAST(VarianceAllowed AS DECIMAL(18,4)) * 100.0)
                / CAST(SUM(VarianceAllowed) OVER (PARTITION BY PayerName) AS DECIMAL(18,4)), 2)
        END,
        PctVariancePaid = CASE
            WHEN SUM(VariancePaid) OVER (PARTITION BY PayerName) = 0 THEN NULL
            ELSE ROUND(
                (CAST(VariancePaid AS DECIMAL(18,4)) * 100.0)
                / CAST(SUM(VariancePaid) OVER (PARTITION BY PayerName) AS DECIMAL(18,4)), 2)
        END,
        TotalVarianceAllowed = SUM(VarianceAllowed) OVER (PARTITION BY PayerName),
        TotalVariancePaid    = SUM(VariancePaid)    OVER (PARTITION BY PayerName)
    FROM dbo.PV_NoResponseBreakdown
    WHERE RunId = @RunId
      AND (@FilterPayerName IS NULL OR PayerName = @FilterPayerName)
    ORDER BY PayerName, AgeBucket;
END
GO

/*
-- Optional: rewrite stored Pct columns after this script
EXEC dbo.usp_RefreshPV_NoResponseBreakdown
    @RunId = (SELECT TOP 1 RunId FROM dbo.PV_NoResponseBreakdown ORDER BY RefreshedAt DESC);

-- Or full refresh:
EXEC dbo.usp_RefreshAllPredictionAggregates;
*/

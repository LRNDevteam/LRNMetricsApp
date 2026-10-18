-- =============================================
-- Individual read stored procedures for the
-- Revenue Dashboard pre-aggregated snapshot tables.
-- These are called by SqlDashboardRepository.GetDashboardFromAggregatesAsync
-- when UseDBDashboard = true and no filters are active.
-- =============================================

-- 1. KPI Summary
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardKPI
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1
        TotalClaims,
        TotalCharges,
        TotalPayments,
        TotalBalance,
        CollectionNumerator,
        DenialNumerator,
        AdjustmentNumerator,
        OutstandingNumerator,
        TotalLines,
        LineTotalCharges,
        LineTotalPayments,
        LineTotalBalance,
        RefreshedAt
    FROM dbo.DashboardKPISummary
    ORDER BY RefreshedAt DESC;
END
GO

-- 2. Claim Status Breakdown
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardClaimStatus
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        ClaimStatus AS Status,
        Claims,
        Charges,
        Payments,
        Balance
    FROM dbo.DashboardClaimStatusBreakdown
    WHERE RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardClaimStatusBreakdown)
    ORDER BY Claims DESC;
END
GO

-- 3. Payer Type Payments
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardPayerTypePayments
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        PayerType,
        TotalPayments
    FROM dbo.DashboardPayerTypePayments
    WHERE RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardPayerTypePayments)
    ORDER BY TotalPayments DESC;
END
GO

-- 4. Insight Breakdown (all 4 types in one result; caller splits by InsightType)
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardInsights
AS
BEGIN
    SET NOCOUNT ON;
    -- PayerName insights
    SELECT InsightType, Label, Claims, Charges, Payments, Balance
    FROM dbo.DashboardInsightBreakdown
    WHERE InsightType = 'PayerName'
      AND RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardInsightBreakdown)
    ORDER BY Charges DESC;

    -- PanelType insights
    SELECT InsightType, Label, Claims, Charges, Payments, Balance
    FROM dbo.DashboardInsightBreakdown
    WHERE InsightType = 'PanelType'
      AND RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardInsightBreakdown)
    ORDER BY Charges DESC;

    -- ClinicName insights
    SELECT InsightType, Label, Claims, Charges, Payments, Balance
    FROM dbo.DashboardInsightBreakdown
    WHERE InsightType = 'ClinicName'
      AND RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardInsightBreakdown)
    ORDER BY Charges DESC;

    -- ReferringProvider insights
    SELECT InsightType, Label, Claims, Charges, Payments, Balance
    FROM dbo.DashboardInsightBreakdown
    WHERE InsightType = 'ReferringProvider'
      AND RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardInsightBreakdown)
    ORDER BY Charges DESC;
END
GO

-- 5. Monthly Trends (DOS and FirstBilledDate as two result sets)
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardMonthlyTrends
AS
BEGIN
    SET NOCOUNT ON;
    -- Date of Service trend
    SELECT Month AS Mth, ClaimCount AS Cnt
    FROM dbo.DashboardMonthlyTrends
    WHERE TrendType = 'DateOfService'
      AND RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardMonthlyTrends)
    ORDER BY Month;

    -- First Billed Date trend
    SELECT Month AS Mth, ClaimCount AS Cnt
    FROM dbo.DashboardMonthlyTrends
    WHERE TrendType = 'FirstBilledDate'
      AND RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardMonthlyTrends)
    ORDER BY Month;
END
GO

-- 6. Avg Allowed by Panel x Month
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardPanelMonthlyAllowed
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        PanelType,
        Month,
        AvgAllowed
    FROM dbo.DashboardPanelMonthlyAllowed
    WHERE RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardPanelMonthlyAllowed)
    ORDER BY PanelType, Month;
END
GO

-- 7. Top CPT
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardTopCPT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        CPTCode,
        Charges,
        AllowedAmount,
        InsuranceBalance,
        CollectionAllowed,
        DenialCharges,
        NoRespCharges
    FROM dbo.DashboardTopCPT
    WHERE RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardTopCPT)
    ORDER BY Charges DESC;
END
GO

-- 8. Pay Status Breakdown
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardPayStatus
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        PayStatus,
        ClaimCount AS Cnt
    FROM dbo.DashboardPayStatusBreakdown
    WHERE RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardPayStatusBreakdown)
    ORDER BY ClaimCount DESC;
END
GO

-- 9. Filter Lookup (distinct values per filter type)
CREATE OR ALTER PROCEDURE dbo.usp_GetDashboardFilterLookup
AS
BEGIN
    SET NOCOUNT ON;
    SELECT FilterType, FilterValue
    FROM dbo.DashboardFilterLookup
    WHERE RefreshedAt = (SELECT MAX(RefreshedAt) FROM dbo.DashboardFilterLookup)
    ORDER BY FilterType, FilterValue;
END
GO

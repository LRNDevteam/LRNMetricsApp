-- =============================================
-- Augustus Labs — PanelCategory, No Aging
-- =============================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshDashboard
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RefreshedAt DATETIME = GETDATE();
    DECLARE @LogId       INT;

    INSERT INTO dbo.DashboardRefreshLog (StartedAt, Status)
    VALUES (@RefreshedAt, 'Running');
    SET @LogId = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- =============================================
        -- #1 Filter Lookup Cache
        -- Augustus: PanelCategory
        -- =============================================
        TRUNCATE TABLE dbo.DashboardFilterLookup;

        INSERT INTO dbo.DashboardFilterLookup (FilterType, FilterValue, RefreshedAt)
        SELECT DISTINCT 'PayerName',         LTRIM(RTRIM(PayerName)),         @RefreshedAt FROM dbo.ClaimLevelData WHERE PayerName         IS NOT NULL AND PayerName         <> ''
        UNION ALL
        SELECT DISTINCT 'PayerType',         LTRIM(RTRIM(PayerType)),         @RefreshedAt FROM dbo.ClaimLevelData WHERE PayerType         IS NOT NULL AND PayerType         <> ''
        UNION ALL
        SELECT DISTINCT 'PanelName',         LTRIM(RTRIM(PanelCategory)),     @RefreshedAt FROM dbo.ClaimLevelData WHERE PanelCategory     IS NOT NULL AND PanelCategory     <> ''
        UNION ALL
        SELECT DISTINCT 'ClinicName',        LTRIM(RTRIM(ClinicName)),        @RefreshedAt FROM dbo.ClaimLevelData WHERE ClinicName        IS NOT NULL AND ClinicName        <> ''
        UNION ALL
        SELECT DISTINCT 'ReferringProvider', LTRIM(RTRIM(ReferringProvider)), @RefreshedAt FROM dbo.ClaimLevelData WHERE ReferringProvider IS NOT NULL AND ReferringProvider <> '';

        -- =============================================
        -- #2 + #8 Claim & Line KPIs (No Aging)
        -- =============================================
        TRUNCATE TABLE dbo.DashboardKPISummary;

        INSERT INTO dbo.DashboardKPISummary
        (
            TotalClaims, TotalCharges, TotalPayments, TotalBalance,
            CollectionNumerator, DenialNumerator, AdjustmentNumerator, OutstandingNumerator,
            TotalLines, LineTotalCharges, LineTotalPayments, LineTotalBalance,
            RefreshedAt
        )
        SELECT
            c.TotalClaims, c.TotalCharges, c.TotalPayments, c.TotalBalance,
            c.CollectionNumerator, c.DenialNumerator, c.AdjustmentNumerator, c.OutstandingNumerator,
            l.TotalLines, l.LineTotalCharges, l.LineTotalPayments, l.LineTotalBalance,
            @RefreshedAt
        FROM
        (
            SELECT
                COUNT(*)                                                                          AS TotalClaims,
                ISNULL(SUM(TRY_CAST(ChargeAmount      AS DECIMAL(18,2))), 0)                      AS TotalCharges,
                ISNULL(SUM(TRY_CAST(TotalPayments     AS DECIMAL(18,2))), 0)                      AS TotalPayments,
                ISNULL(SUM(TRY_CAST(TotalBalance       AS DECIMAL(18,2))), 0)                     AS TotalBalance,
                ISNULL(SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Partially Paid','Patient Responsibility','Patient Payment')
                     THEN TRY_CAST(AllowedAmount AS DECIMAL(18,2)) ELSE 0 END), 0)               AS CollectionNumerator,
                ISNULL(SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')
                     THEN TRY_CAST(ChargeAmount  AS DECIMAL(18,2)) ELSE 0 END), 0)               AS DenialNumerator,
                ISNULL(SUM(CASE WHEN ClaimStatus IN ('Complete W/O','Partially Adjusted')
                     THEN TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)) ELSE 0 END), 0)        AS AdjustmentNumerator,
                ISNULL(SUM(CASE WHEN ClaimStatus = 'No Response'
                     THEN TRY_CAST(ChargeAmount  AS DECIMAL(18,2)) ELSE 0 END), 0)               AS OutstandingNumerator
            FROM dbo.ClaimLevelData
        ) c
        CROSS JOIN
        (
            SELECT
                COUNT(*)                                                          AS TotalLines,
                ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0)          AS LineTotalCharges,
                ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0)          AS LineTotalPayments,
                ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0)         AS LineTotalBalance
            FROM dbo.LineLevelData
        ) l;

        -- =============================================
        -- #3 Claim Status Breakdown
        -- =============================================
        TRUNCATE TABLE dbo.DashboardClaimStatusBreakdown;

        INSERT INTO dbo.DashboardClaimStatusBreakdown
        (ClaimStatus, Claims, Charges, Payments, Balance, RefreshedAt)
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(ClaimStatus)),''), 'Unknown'),
            COUNT(*),
            ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(ClaimStatus)),''), 'Unknown');

        -- =============================================
        -- #4 Payer Type Payments
        -- =============================================
        TRUNCATE TABLE dbo.DashboardPayerTypePayments;

        INSERT INTO dbo.DashboardPayerTypePayments
        (PayerType, TotalPayments, RefreshedAt)
        SELECT
            LTRIM(RTRIM(PayerType)),
            ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        WHERE PayerType IS NOT NULL AND PayerType <> ''
        GROUP BY LTRIM(RTRIM(PayerType));

        -- =============================================
        -- #5 Insight Breakdown
        -- Augustus: PanelCategory
        -- =============================================
        TRUNCATE TABLE dbo.DashboardInsightBreakdown;

        INSERT INTO dbo.DashboardInsightBreakdown
        (InsightType, Label, Claims, Charges, Payments, Balance, RefreshedAt)
        SELECT TOP 15
            'PayerName',
            ISNULL(NULLIF(LTRIM(RTRIM(PayerName)),''), 'Unknown'),
            COUNT(*),
            ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(PayerName)),''), 'Unknown')
        ORDER BY SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))) DESC;

        INSERT INTO dbo.DashboardInsightBreakdown
        (InsightType, Label, Claims, Charges, Payments, Balance, RefreshedAt)
        SELECT TOP 15
            'PanelName',
            ISNULL(NULLIF(LTRIM(RTRIM(PanelCategory)),''), 'Unknown'),
            COUNT(*),
            ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(PanelCategory)),''), 'Unknown')
        ORDER BY SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))) DESC;

        INSERT INTO dbo.DashboardInsightBreakdown
        (InsightType, Label, Claims, Charges, Payments, Balance, RefreshedAt)
        SELECT TOP 15
            'ClinicName',
            ISNULL(NULLIF(LTRIM(RTRIM(ClinicName)),''), 'Unknown'),
            COUNT(*),
            ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(ClinicName)),''), 'Unknown')
        ORDER BY SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))) DESC;

        INSERT INTO dbo.DashboardInsightBreakdown
        (InsightType, Label, Claims, Charges, Payments, Balance, RefreshedAt)
        SELECT TOP 15
            'ReferringProvider',
            ISNULL(NULLIF(LTRIM(RTRIM(ReferringProvider)),''), 'Unknown'),
            COUNT(*),
            ISNULL(SUM(TRY_CAST(ChargeAmount  AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(TotalBalance   AS DECIMAL(18,2))), 0),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(ReferringProvider)),''), 'Unknown')
        ORDER BY SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))) DESC;

        -- =============================================
        -- #6 Monthly Trends
        -- =============================================
        TRUNCATE TABLE dbo.DashboardMonthlyTrends;

        INSERT INTO dbo.DashboardMonthlyTrends
        (TrendType, Month, ClaimCount, RefreshedAt)
        SELECT
            'DateOfService',
            FORMAT(TRY_CAST(DateofService AS DATE), 'yyyy-MM'),
            COUNT(*),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
        GROUP BY FORMAT(TRY_CAST(DateofService AS DATE), 'yyyy-MM');

        INSERT INTO dbo.DashboardMonthlyTrends
        (TrendType, Month, ClaimCount, RefreshedAt)
        SELECT
            'FirstBilledDate',
            FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM'),
            COUNT(*),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
        GROUP BY FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM');

        -- =============================================
        -- #7 Avg Allowed by PanelCategory x Month
        -- =============================================
        TRUNCATE TABLE dbo.DashboardPanelMonthlyAllowed;

        INSERT INTO dbo.DashboardPanelMonthlyAllowed
        (PanelType, Month, AvgAllowed, RefreshedAt)
        SELECT
            LTRIM(RTRIM(PanelCategory)),
            FORMAT(TRY_CAST(DateofService AS DATE), 'yyyy-MM'),
            AVG(TRY_CAST(AllowedAmount AS DECIMAL(18,2))),
            @RefreshedAt
        FROM dbo.ClaimLevelData
        WHERE PanelCategory IS NOT NULL AND PanelCategory <> ''
          AND TRY_CAST(DateofService AS DATE) IS NOT NULL
        GROUP BY LTRIM(RTRIM(PanelCategory)),
                 FORMAT(TRY_CAST(DateofService AS DATE), 'yyyy-MM');

        -- =============================================
        -- #9 + #11 Top CPT Detail
        -- =============================================
        TRUNCATE TABLE dbo.DashboardTopCPT;

        INSERT INTO dbo.DashboardTopCPT
        (CPTCode, Charges, AllowedAmount, InsuranceBalance,
         CollectionAllowed, DenialCharges, NoRespCharges, RefreshedAt)
        SELECT TOP 20
            LTRIM(RTRIM(CPTCode)),
            ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(AllowedAmount    AS DECIMAL(18,2))), 0),
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0),
            ISNULL(SUM(CASE WHEN PayStatus IN ('Paid','Patient Responsibility')
                 THEN TRY_CAST(AllowedAmount AS DECIMAL(18,2)) ELSE 0 END), 0),
            ISNULL(SUM(CASE WHEN PayStatus = 'Denied'
                 THEN TRY_CAST(ChargeAmount  AS DECIMAL(18,2)) ELSE 0 END), 0),
            ISNULL(SUM(CASE WHEN PayStatus = 'No Response'
                 THEN TRY_CAST(ChargeAmount  AS DECIMAL(18,2)) ELSE 0 END), 0),
            @RefreshedAt
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND CPTCode <> ''
        GROUP BY LTRIM(RTRIM(CPTCode))
        ORDER BY SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))) DESC;

        -- =============================================
        -- #10 Pay Status Breakdown
        -- =============================================
        TRUNCATE TABLE dbo.DashboardPayStatusBreakdown;

        INSERT INTO dbo.DashboardPayStatusBreakdown
        (PayStatus, ClaimCount, RefreshedAt)
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(PayStatus)),''), 'Unknown'),
            COUNT(*),
            @RefreshedAt
        FROM dbo.LineLevelData
        GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(PayStatus)),''), 'Unknown');

        COMMIT TRANSACTION;

        UPDATE dbo.DashboardRefreshLog
        SET CompletedAt = GETDATE(),
            DurationMs  = DATEDIFF(MILLISECOND, StartedAt, GETDATE()),
            Status      = 'Success'
        WHERE LogId = @LogId;

        PRINT 'Augustus dashboard refresh completed at ' + CAST(@RefreshedAt AS NVARCHAR(30));

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @ErrMsg  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrLine INT            = ERROR_LINE();

        UPDATE dbo.DashboardRefreshLog
        SET CompletedAt  = GETDATE(),
            DurationMs   = DATEDIFF(MILLISECOND, StartedAt, GETDATE()),
            Status       = 'Failed',
            ErrorMessage = CONCAT('Line ', @ErrLine, ': ', @ErrMsg)
        WHERE LogId = @LogId;

        RAISERROR('usp_RefreshDashboard failed at Line %d: %s', 16, 1, @ErrLine, @ErrMsg);
    END CATCH
END
GO

PRINT '06_Augustus_usp_RefreshDashboard_PanelCategory.sql completed.';

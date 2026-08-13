/* =====================================================================
   Hotfix — BeechTree Collection Summary NULL PayerName failures
   DB: BeechTree_LRN
   ---------------------------------------------------------------------
   Same issue as NorthWest:
     usp_RefreshBT_CS_InsuranceVsAging
     usp_RefreshBT_CS_InsuranceVsPaymentPct
   → LTRIM(RTRIM(PayerName_Raw)) stays NULL when PayerName_Raw is NULL
   → INSERT fails on NOT NULL PayerName

   Also: repo had wrongly copied Cert SP name/table for PaymentPct;
   this restores dbo.usp_RefreshBT_CS_InsuranceVsPaymentPct → BT_CS_* table.

   Deploy on BeechTree_LRN, then smoke-test below.
   ===================================================================== */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshBT_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.BT_CS_InsuranceVsAging;

    INSERT INTO dbo.BT_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')))   AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''))                          AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)               AS InsuranceBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND NOT (LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
               AND LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))) = 'Unbilled')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')));

    PRINT 'usp_RefreshBT_CS_InsuranceVsAging completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshBT_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
            LTRIM(RTRIM(ISNULL(Panelname, ''))) AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))  AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
    ),
    agg AS (
        SELECT
            PayerName,
            COUNT(PanelName) AS PanelGroupCount,
            ISNULL(SUM(InsPay), 0) AS InsurancePayment,
            ROUND(ISNULL(AVG(PayPct), 0) * 100, 0) AS PaymentPct
        FROM base
        GROUP BY PayerName
    ),
    grand AS (
        SELECT NULLIF(SUM(InsurancePayment), 0) AS Total FROM agg
    )
    SELECT
        a.PayerName,
        a.PanelGroupCount,
        a.InsurancePayment,
        a.PaymentPct
    INTO #out
    FROM agg a
    CROSS JOIN grand g;

    TRUNCATE TABLE dbo.BT_CS_InsuranceVsPaymentPct;

    INSERT INTO dbo.BT_CS_InsuranceVsPaymentPct
        (PayerName, PanelGroupCount, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT
        PayerName,
        PanelGroupCount,
        InsurancePayment,
        PaymentPct,
        GETDATE()
    FROM #out
    ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshBT_CS_InsuranceVsPaymentPct completed.';
END
GO

EXEC dbo.usp_RefreshBT_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshBT_CS_InsuranceVsPaymentPct;

SELECT 'BT_CS_InsuranceVsAging' AS [Table], COUNT(*) AS Rows, MAX(RefreshedAt) AS LastRun
FROM dbo.BT_CS_InsuranceVsAging
UNION ALL
SELECT 'BT_CS_InsuranceVsPaymentPct', COUNT(*), MAX(RefreshedAt)
FROM dbo.BT_CS_InsuranceVsPaymentPct;
GO

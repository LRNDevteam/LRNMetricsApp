/* =====================================================================
   Hotfix — InHealthDTR Collection Summary refresh failures
   DB: InHealthDTRLRN
   ---------------------------------------------------------------------
   From ClaimLineCSVDataCapture STEP 15 log:

   1) usp_RefreshIHD_CS_InsuranceVsAging
      → Cannot insert NULL into PayerName
      → LTRIM(RTRIM(PayerName_Raw)) stays NULL when source is NULL/blank

   2) usp_RefreshIHD_CS_CptVsPaymentPct
      → CPTCode truncation (NVARCHAR(50))
      → ClaimLevel CPTCodeXUnitsXModifier is a comma-joined list
        e.g. '87481*5(59,90),87500*1(90),87640*1(59,90),...'
      → Old parser looked for ' x ' and fell through to the full string
      → Fix: source LineLevelData.CPTCode / Units (same as Beech Tree)

   Also keeps InsuranceVsPaymentPct on the Unknown-payer hardening path
   so a full 12_ redeploy does not regress 19b.

   Deploy on InHealthDTRLRN, then smoke-test below.
   ===================================================================== */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.IHD_CS_InsuranceVsAging;

    INSERT INTO dbo.IHD_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')))   AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                  AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)               AS InsuranceBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND NOT (LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
               AND LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))) = 'Unbilled')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')));

    PRINT 'usp_RefreshIHD_CS_InsuranceVsAging completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
            LTRIM(RTRIM(ISNULL(Panelname, '')))                                      AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))                              AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))                               AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
          AND NOT (LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
                   AND LTRIM(RTRIM(ISNULL(BilledUnbilled, ''))) = 'Unbilled')
    ),
    agg AS (
        SELECT PayerName,
               COUNT(PanelName)                        AS PanelGroupCount,
               ISNULL(SUM(InsPay), 0)                  AS InsurancePayment,
               ROUND(ISNULL(AVG(PayPct), 0) * 100, 0)  AS PaymentPct
        FROM base GROUP BY PayerName
    )
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.IHD_CS_InsuranceVsPaymentPct;
    INSERT INTO dbo.IHD_CS_InsuranceVsPaymentPct
        (PayerName, PanelGroupCount, InsurancePayment, PaymentPct, RefreshedAt)
    SELECT PayerName, PanelGroupCount, InsurancePayment, PaymentPct, GETDATE()
    FROM #out ORDER BY InsurancePayment DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_InsuranceVsPaymentPct completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LEFT(LTRIM(RTRIM(CPTCode)), 50)                            AS CPTCode,
            ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))), 0)           AS SumUnits,
            ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidIns,
            ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChg
        FROM dbo.LineLevelData
        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
        GROUP BY LEFT(LTRIM(RTRIM(CPTCode)), 50)
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg,
           CASE WHEN PaidChg > 0
                THEN CAST(PaidIns * 100.0 / PaidChg AS DECIMAL(9,4))
                ELSE 0 END AS PaymentPct
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.IHD_CS_CptVsPaymentPct;
    INSERT INTO dbo.IHD_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshIHD_CS_CptVsPaymentPct completed.';
END
GO

PRINT 'Fix_IHD_CS_PayerNull_CptTruncation.sql completed.';
GO

/*
-- Smoke test on InHealthDTRLRN:
EXEC dbo.usp_RefreshIHD_CS_InsuranceVsAging;
EXEC dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct;
EXEC dbo.usp_RefreshIHD_CS_CptVsPaymentPct;

SELECT 'IHD_CS_InsuranceVsAging' AS [Table], COUNT(*) AS Rows, MAX(RefreshedAt) AS LastRun
FROM dbo.IHD_CS_InsuranceVsAging
UNION ALL
SELECT 'IHD_CS_InsuranceVsPaymentPct', COUNT(*), MAX(RefreshedAt) FROM dbo.IHD_CS_InsuranceVsPaymentPct
UNION ALL
SELECT 'IHD_CS_CptVsPaymentPct', COUNT(*), MAX(RefreshedAt) FROM dbo.IHD_CS_CptVsPaymentPct;

SELECT TOP 20 * FROM dbo.IHD_CS_CptVsPaymentPct ORDER BY SumUnits DESC;
SELECT TOP 20 * FROM dbo.IHD_CS_InsuranceVsAging ORDER BY InsuranceBalance DESC;
*/

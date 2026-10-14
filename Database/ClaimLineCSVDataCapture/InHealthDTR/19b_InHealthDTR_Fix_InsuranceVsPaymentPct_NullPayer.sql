-- =====================================================================
-- InHealthDTR -- Fix NULL PayerName / PanelName inserts (Msg 515)
-- Deploy on: InHealthDTRLRN
--
-- Live error after 19_ PanelNameBasedOnCPT patch:
--   Cannot insert the value NULL into column 'PayerName',
--   table 'InHealthDTRLRN.dbo.IHD_CS_InsuranceVsPaymentPct'
--
-- Root cause: usp_RefreshIHD_CS_InsuranceVsPaymentPct grouped on
-- LTRIM(RTRIM(PayerName_Raw)) without ISNULL; NULL payers violate
-- IHD_CS_InsuranceVsPaymentPct.PayerName NOT NULL.
--
-- Also hardens usp_RefreshIHD_CS_PanelVsPayment (PanelName NOT NULL).
-- Matches ISNULL(..., 'Unknown') pattern used by Monthly/Weekly/
-- PanelAverages/AvgPayments refresh SPs in script 19.
--
-- PanelNameBasedOnCPT dimension change is preserved.
-- =====================================================================

SET NOCOUNT ON;
GO


-- 8. Panel vs Payment
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.IHD_CS_PanelVsPayment;

    INSERT INTO dbo.IHD_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))            AS PanelName,
        YEAR (TRY_CAST(CheckDate AS DATE))                              AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)             AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))               AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)     AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND NOT (ClaimStatus = 'No Response' AND BilledUnbilled = 'Unbilled')
    GROUP BY
        LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    PRINT 'usp_RefreshIHD_CS_PanelVsPayment completed.';
END
GO


-- 10. Insurance vs Payment % (Panel used for PanelGroupCount)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw,       'Unknown'))) AS PayerName,
            LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown'))) AS PanelName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))          AS InsPay,
            TRY_CAST(PaymentPercent   AS DECIMAL(9,4))           AS PayPct
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) <> 0
          AND NOT (LTRIM(RTRIM(ClaimStatus)) = 'No Response' AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled')
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


PRINT '19b_InHealthDTR_Fix_InsuranceVsPaymentPct_NullPayer.sql completed.';
GO

/*
-- Re-run on InHealthDTRLRN after this script:
EXEC dbo.usp_RefreshIHD_CS_PanelVsPayment;
EXEC dbo.usp_RefreshIHD_CS_InsuranceVsPaymentPct;
*/

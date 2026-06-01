-- PhiLife — Payer Breakdown  +  Payer × Panel
--
-- Filter (both SPs):
--   TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
--
-- Table 1 — Phi_PayerBreakdown   (Payer × ChargeEnteredDate Month)
-- Table 2 — Phi_PayerByPanel     (Payer × Panelname)
-- Source  : ClaimLevelData
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_PayerBreakdown')
CREATE TABLE dbo.Phi_PayerBreakdown
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName       NVARCHAR(500)   NOT NULL,
    BilledYearMonth NVARCHAR(7)     NOT NULL,
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_PayerByPanel')
CREATE TABLE dbo.Phi_PayerByPanel
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    PanelType    NVARCHAR(MAX)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_PayerBreakdown
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                     AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))               AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
    INTO #RawPM
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    TRUNCATE TABLE dbo.Phi_PayerBreakdown;

    INSERT INTO dbo.Phi_PayerBreakdown (PayerName, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPM
    ORDER BY PayerName_Raw, BilledYearMonth;

    DROP TABLE IF EXISTS #RawPM;

    PRINT 'usp_RefreshPhi_PayerBreakdown completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_PayerByPanel
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                                      AS PayerName_Raw,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))      AS Panelname,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
    INTO #RawPP
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')));

    TRUNCATE TABLE dbo.Phi_PayerByPanel;

    INSERT INTO dbo.Phi_PayerByPanel (PayerName, PanelType, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, Panelname, ClaimCount, TotalCharges, GETDATE()
    FROM #RawPP
    ORDER BY PayerName_Raw, Panelname;

    DROP TABLE IF EXISTS #RawPP;

    PRINT 'usp_RefreshPhi_PayerByPanel completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '08_PhiLife_PayerBreakdown.sql completed.';

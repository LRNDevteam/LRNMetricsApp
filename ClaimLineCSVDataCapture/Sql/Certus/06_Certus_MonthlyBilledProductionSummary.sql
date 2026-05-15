-- Certus Labs — Monthly Claim Production Billed Summary
-- Rule:
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--             AND PayerName_Raw does not contain: None, Accu, Client, Patient
--   Rows    : Panelname  x  Top 3 Payer (by COUNT(DISTINCT ClaimID), per Panelname)
--   Columns : FirstBilledDate Year-Month (yyyy-MM) | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Cert_MonthlyBilledProductionSummary')
CREATE TABLE dbo.Cert_MonthlyBilledProductionSummary
(
    SummaryId       INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType       NVARCHAR(MAX)   NOT NULL,   -- stores Panelname value
    PayerName       NVARCHAR(500)   NOT NULL,
    PayerRank       TINYINT         NOT NULL,   -- 1 / 2 / 3 within the Panelname
    BilledYearMonth NVARCHAR(7)     NOT NULL,   -- 'yyyy-MM' from FirstBilledDate
    ClaimCount      INT             NOT NULL DEFAULT 0,
    TotalCharges    DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt     DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
-- ============================================================
-- Step 2: Stored procedure
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCert_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- Aggregate by Panelname x PayerName_Raw x FirstBilledDate month.
    -- Payer exclusions: rows where PayerName_Raw contains None, Accu, Client, or Patient are excluded.
    SELECT
        LTRIM(RTRIM(ISNULL(Panelname,      'Unknown')))                  AS Panelname,
        LTRIM(RTRIM(ISNULL(PayerName_Raw,  'Unknown')))                  AS PayerName_Raw,
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')             AS BilledYearMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)          AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(ChargeEnteredDate)) <> ''
      AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '')))) NOT LIKE '%NONE%'
      AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '')))) NOT LIKE '%ACCU%'
      AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '')))) NOT LIKE '%CLIENT%'
      AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '')))) NOT LIKE '%PATIENT%'
	 -- AND PayerName_Raw NOT IN (SELECT Payername from ExcludedPayers)
	 
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,      'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw,  'Unknown'))),
        FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM');

    -- Rank payers within each Panelname by total claim count (Top 3).
    SELECT
        Panelname,
        PayerName_Raw,
        DENSE_RANK() OVER (
            PARTITION BY Panelname
            ORDER BY SUM(ClaimCount) DESC
        ) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY Panelname, PayerName_Raw;

    SELECT
        b.Panelname,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.BilledYearMonth,
        b.ClaimCount,
        b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw
   -- WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.Cert_MonthlyBilledProductionSummary;

    INSERT INTO dbo.Cert_MonthlyBilledProductionSummary
        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, PayerName_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
    FROM #Top3
    ORDER BY Panelname, PayerRank, BilledYearMonth;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;

    PRINT 'usp_RefreshCert_MonthlyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO


--CREATE OR ALTER PROCEDURE dbo.usp_RefreshCert_MonthlyBilledProductionSummary
--AS
--BEGIN
--    SET NOCOUNT ON;

--    -- Aggregate by Panelname x PayerName_Raw x FirstBilledDate month.
--    -- Payer exclusions: rows where PayerName_Raw contains None, Accu, Client, or Patient are excluded.
--    SELECT
--        LTRIM(RTRIM(ISNULL(Panelname,      'Unknown')))                  AS Panelname,
--        LTRIM(RTRIM(ISNULL(PayerName_Raw,  'Unknown')))                  AS PayerName_Raw,
--        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM')             AS BilledYearMonth,
--        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                AS ClaimCount,
--        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)          AS TotalCharges
--    INTO #BilledRaw
--    FROM dbo.ClaimLevelData
--    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''
--      AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '')))) NOT LIKE '%NONE%'
--      AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '')))) NOT LIKE '%ACCU%'
--      AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '')))) NOT LIKE '%CLIENT%'
--      AND UPPER(LTRIM(RTRIM(ISNULL(PayerName_Raw, '')))) NOT LIKE '%PATIENT%'
--	 -- AND PayerName_Raw NOT IN (SELECT Payername from ExcludedPayers)
	 
--    GROUP BY
--        LTRIM(RTRIM(ISNULL(Panelname,      'Unknown'))),
--        LTRIM(RTRIM(ISNULL(PayerName_Raw,  'Unknown'))),
--        FORMAT(TRY_CAST(FirstBilledDate AS DATE), 'yyyy-MM');

--    -- Rank payers within each Panelname by total claim count (Top 3).
--    SELECT
--        Panelname,
--        PayerName_Raw,
--        DENSE_RANK() OVER (
--            PARTITION BY Panelname
--            ORDER BY SUM(ClaimCount) DESC
--        ) AS PayerRank
--    INTO #PayerRanks
--    FROM #BilledRaw
--    GROUP BY Panelname, PayerName_Raw;

--    SELECT
--        b.Panelname,
--        b.PayerName_Raw,
--        CAST(r.PayerRank AS TINYINT) AS PayerRank,
--        b.BilledYearMonth,
--        b.ClaimCount,
--        b.TotalCharges
--    INTO #Top3
--    FROM #BilledRaw b
--    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw
--   -- WHERE r.PayerRank <= 3;

--    TRUNCATE TABLE dbo.Cert_MonthlyBilledProductionSummary;

--    INSERT INTO dbo.Cert_MonthlyBilledProductionSummary
--        (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
--    SELECT Panelname, PayerName_Raw, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
--    FROM #Top3
--    ORDER BY Panelname, PayerRank, BilledYearMonth;

--    DROP TABLE IF EXISTS #BilledRaw;
--    DROP TABLE IF EXISTS #PayerRanks;
--    DROP TABLE IF EXISTS #Top3;

--    PRINT 'usp_RefreshCert_MonthlyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
--END
--GO

/*
SELECT PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
FROM dbo.Cert_MonthlyBilledProductionSummary
ORDER BY PanelType, PayerRank, BilledYearMonth;
*/

PRINT '06_Certus_MonthlyBilledProductionSummary.sql completed.';



-----


---- =============================================
---- Create ExcludedPayers Table
---- =============================================
--IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ExcludedPayers')
--CREATE TABLE dbo.ExcludedPayers
--(
--    ExcludeId   INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,
--    PayerName   NVARCHAR(500) NOT NULL,
--    CreatedAt   DATETIME      NOT NULL DEFAULT GETDATE()
--);
--GO

---- =============================================
---- Insert Excluded Payers
---- =============================================
--INSERT INTO dbo.ExcludedPayers (PayerName)
--VALUES
--('MISSISSIPPI HEALTH PARTNERS'),
--('BCBS NY'),
--('Starmark/Trustmark'),
--('PHCS'),
--('SISCO'),
--('CLIENT'),
--('Southern Benefit Administrators'),
--('Global Care'),
--('TEXAS CHILDREN''S HEALTH PLAN'),
--('HEALTH EZ'),
--('GEHA'),
--('WC - Workers Comp Other'),
--('COMMUNITY CARE'),
--('VETERANS AFFAIRS'),
--('TRICARE WEST REGION'),
--('Healthy Mississippi'),
--('American Health Plan of MS'),
--('INC'),
--('AmFirst Insurance Company'),
--('INSURANCE'),
--('BCBS - Alabama'),
--('Veterans Choice Program - VACAA'),
--('AETNA BETTER HEALTH OF LA'),
--('PRIORITY HEALTH'),
--('Teamcare'),
--('CHRISTUS HEALTH PLAN - US FAMILY HEALTH PLAN (USFHP)'),
--('Assyred Benefits'),
--('Advantage Care'),
--('Christus Health Medicare Advantage'),
--('Oscar'),
--('First Health/Coventry Healthcare'),
--('First Choice VIP Care'),
--('HEALTHSMART'),
--('L W P ELITE TRUCKING LLS'),
--('Champ VA Center'),
--('BENEFIT HEALTH PLAN INC'),
--('VERDEGARD ADMINISTRATORS LLC'),
--('SELECT ADMINISTRATIVE SERVICES'),
--('CAREGUARD'),
--('UNITED HEALTHCARE COMMUNITY'),
--('FRONTIER HEALTH'),
--('Nippon Life Insurance'),
--('AMERICAN FEDERATED INSURANCE'),
--('AMTRUST NOTHE AMERICA'),
--('AMERIHEALTH CARITA/LA-MEDICAID'),
--('ACCU LABS NON BILLABLE'),
--('CLIENT BILL - ELXIR LABORATORIES'),
--('CLIENT BILL - COVE DIAGNOSTICS'),
--('CLIENT BILL - GULF COAST PSYCHOTHERAPY BLOOD'),
--('CLIENT BILL GULF COAST PSYCHOTHERAPY'),
--('CLIENT BILL - INTERNAL MEDICINE CLINIC OF GRENADA'),
--('CLIENT BILL - Tallahatchie general hospital'),
--('CLIENT BILL - YALOBUSHA GENERAL HOSIPITAL'),
--('Client Bill - Costal Chronic Pain Services');
--GO

---- =============================================
---- Verify
---- =============================================
--SELECT ExcludeId, PayerName, CreatedAt
--FROM dbo.ExcludedPayers
--ORDER BY PayerName;
--GO

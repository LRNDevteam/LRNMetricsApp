-- Certus Labs — Unbilled × Aging
-- Rule:
--   Filter  : FirstBilledDate IS NULL or blank  (truly unbilled claims)
--   Row     : PayerName_Raw
--   Columns : Aging bucket | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Cert_UnbilledAging')
CREATE TABLE dbo.Cert_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,   -- stores PayerName_Raw value
    Aging        NVARCHAR(100)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCert_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName_Raw,
        ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')                      AS Aging,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)     AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        ISNULL(LTRIM(RTRIM(Aging)), 'Unknown');

    TRUNCATE TABLE dbo.Cert_UnbilledAging;

    INSERT INTO dbo.Cert_UnbilledAging (PayerName, Aging, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName_Raw, Aging, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY PayerName_Raw, Aging;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshCert_UnbilledAging completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PayerName, Aging, ClaimCount, TotalCharges
FROM dbo.Cert_UnbilledAging ORDER BY PayerName, Aging;
*/

PRINT '09_Certus_UnbilledAging.sql completed.';

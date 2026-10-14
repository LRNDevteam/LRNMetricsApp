/* =====================================================================================
   NorthWest - Collection Summary > Monthly Claim Volume (14 Oct 2026)
   Database : NWL_LRN

   usp_RefreshNW_CS_MonthlyClaimVolume failed with Msg 515 (NULL into BillYear):
   a paid claim with no CheckDate (ClaimID 489889, $6.87) gave a NULL BillYear/BillMonth.
   Paid rows without a valid CheckDate are now skipped - they have no month to land in.
   Same code as 11_NorthWest_CollectionSummary.sql. Safe to rerun.
   ===================================================================================== */
USE NWL_LRN;
GO

-- 3. Monthly Claim Volume  (ClaimLevelData, CheckDate, Top-3 payer per panel)
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PanelType,        'Unknown')))               AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))               AS PayerName,
        YEAR (TRY_CAST(CheckDate AS DATE))                           AS BillYear,
        MONTH(TRY_CAST(CheckDate AS DATE))                           AS BillMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment
    INTO #raw
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL   -- BillYear/BillMonth are NOT NULL
     -- AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
    GROUP BY
        LTRIM(RTRIM(ISNULL(PanelType,        'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    SELECT
        PanelName, PayerName,
        DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
    INTO #ranks
    FROM #raw
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.NW_CS_MonthlyClaimVolume;
    INSERT INTO dbo.NW_CS_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT r.PanelName, r.PayerName, CAST(k.PayerRank AS TINYINT),
           r.BillYear, CAST(r.BillMonth AS TINYINT), r.NoOfClaims, r.InsurancePayment, GETDATE()
    FROM #raw r
    JOIN #ranks k ON k.PanelName = r.PanelName AND k.PayerName = r.PayerName
    --WHERE k.PayerRank <= 3
    ORDER BY r.PanelName, k.PayerRank, r.BillYear, r.BillMonth;

    DROP TABLE IF EXISTS #raw;
    DROP TABLE IF EXISTS #ranks;
    PRINT 'usp_RefreshNW_CS_MonthlyClaimVolume completed.';
END
GO

EXEC dbo.usp_RefreshNW_CS_MonthlyClaimVolume;
GO

SELECT COUNT(*) AS RowsLoaded, SUM(NoOfClaims) AS Claims, SUM(InsurancePayment) AS InsurancePayment, MAX(RefreshedAt) AS RefreshedAt
FROM dbo.NW_CS_MonthlyClaimVolume;
GO

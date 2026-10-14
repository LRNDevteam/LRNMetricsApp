/* =====================================================================================
   Augustus - Collection Summary > Monthly Claim Volume (14 Oct 2026)
   Database : Augustus_LRN

   Run R20260922AUG2436 logged "12/13 SP(s) succeeded. Failed: dbo.usp_RefreshAug_CS_MonthlyClaimVolume".
   Same defect as NorthWest: a paid row with no PostingDate gives a NULL BillYear/BillMonth
   (both NOT NULL). Paid rows without a valid PostingDate are now skipped.
   Same code as 13_Augustus_CollectionSummary.sql. Safe to rerun.
   ===================================================================================== */
USE Augustus_LRN;
GO

-- Rows that made the old procedure fail (expect at least 1 before the fix)
SELECT COUNT(*) AS PaidRowsWithoutPostingDate,
       SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))) AS InsurancePayment
FROM   dbo.CollectionClaimLevelData
WHERE  ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
  AND  TRY_CAST(PostingDate AS DATE) IS NULL;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown')))              AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown')))              AS PayerName,
        YEAR (TRY_CAST(PostingDate AS DATE))                         AS BillYear,
        MONTH(TRY_CAST(PostingDate AS DATE))                         AS BillMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))           AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS InsurancePayment
    INTO #raw
    FROM dbo.CollectionClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0
      AND TRY_CAST(PostingDate AS DATE) IS NOT NULL   -- BillYear/BillMonth are NOT NULL
     GROUP BY
        LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),
        YEAR (TRY_CAST(PostingDate AS DATE)),
        MONTH(TRY_CAST(PostingDate AS DATE));
    SELECT PanelName, PayerName,
           DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
    INTO #ranks FROM #raw GROUP BY PanelName, PayerName;
    TRUNCATE TABLE dbo.Aug_CS_MonthlyClaimVolume;
    INSERT INTO dbo.Aug_CS_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT r.PanelName, r.PayerName, CAST(k.PayerRank AS TINYINT),
           r.BillYear, CAST(r.BillMonth AS TINYINT), r.NoOfClaims, r.InsurancePayment, GETDATE()
    FROM #raw r JOIN #ranks k ON k.PanelName = r.PanelName AND k.PayerName = r.PayerName
    --WHERE k.PayerRank <= 3
    ORDER BY r.PanelName, k.PayerRank, r.BillYear, r.BillMonth;
    DROP TABLE IF EXISTS #raw; DROP TABLE IF EXISTS #ranks;
    PRINT 'usp_RefreshAug_CS_MonthlyClaimVolume completed.';
END
GO

EXEC dbo.usp_RefreshAug_CS_MonthlyClaimVolume;
GO

SELECT COUNT(*) AS RowsLoaded, SUM(NoOfClaims) AS Claims, SUM(InsurancePayment) AS InsurancePayment, MAX(RefreshedAt) AS RefreshedAt
FROM dbo.Aug_CS_MonthlyClaimVolume;
GO

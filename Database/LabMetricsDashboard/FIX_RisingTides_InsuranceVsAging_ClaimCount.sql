-- =====================================================================
-- FIX: Rising Tides - Collection Summary "Insurance Vs Aging"
-- Client pivot logic:
--   Filter : InsuranceBalance <> 0
--   Row    : PayerName_Raw
--   Column : AgingBucket, Count of ClaimID, Sum of InsuranceBalance
-- Was    : COUNT(DISTINCT AccessionNumber) -> claims sharing an accession
--          counted once (e.g. Current 704 vs client 707, Total 2,618 vs 2,621).
--          Live/filter SP also excluded every 'No Response' claim and derived
--          buckets from DaystoDOS; snapshot excluded No Response + Unbilled.
-- Now    : both SPs count ClaimID rows, use AgingBucket, filter balance <> 0 only.
-- Run on : Rising_Tides database
-- =====================================================================

SET NOCOUNT ON;
GO

-- Preview (optional): claims with a non-zero balance that share an accession
-- SELECT LTRIM(RTRIM(PayerName_Raw)) AS PayerName, AgingBucket, AccessionNumber,
--        COUNT(*) AS Claims, STRING_AGG(ClaimID, ', ') AS ClaimIDs
-- FROM dbo.ClaimLevelData
-- WHERE ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
--   AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
-- GROUP BY LTRIM(RTRIM(PayerName_Raw)), AgingBucket, AccessionNumber
-- HAVING COUNT(*) > 1;
-- 7. Insurance vs Aging (client pivot)
--    Filter  : InsuranceBalance <> 0, PayerName_Raw not blank
--    Row     : PayerName_Raw
--    Column  : AgingBucket, Count of ClaimID, Sum of InsuranceBalance
--    Count is per claim row, not DISTINCT AccessionNumber: claims sharing an
--    accession are separate rows in the client pivot.
CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.RT_CS_InsuranceVsAging;

    INSERT INTO dbo.RT_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                  AS PayerName,
        ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')     AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                     AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE PayerName_Raw IS NOT NULL
      AND LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
    GROUP BY LTRIM(RTRIM(PayerName_Raw)), ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)');

    PRINT 'usp_RefreshRT_CS_InsuranceVsAging completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_CS_InsuranceVsAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance
        FROM   dbo.RT_CS_InsuranceVsAging
        ORDER  BY PayerName, AgingBucket;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- Same logic as usp_RefreshRT_CS_InsuranceVsAging (client pivot):
    -- InsuranceBalance <> 0, AgingBucket column, Count of ClaimID.
    SELECT
        LTRIM(RTRIM(PayerName_Raw))                                             AS PayerName,
        ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')                AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)            AS InsuranceBalance
    FROM dbo.ClaimLevelData
    WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) <> 0
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate      AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate      AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        ISNULL(NULLIF(LTRIM(RTRIM(AgingBucket)), ''), '(blank)')
    ORDER BY PayerName, AgingBucket;
END
GO

EXEC dbo.usp_RefreshRT_CS_InsuranceVsAging;
GO

-- Verify: expected (client) Current 707 / $617,049, 30+ 395 / $363,496,
-- 60+ 245 / $184,688, 90+ 211 / $152,734, 120+ 1,063 / $668,132, Total 2,621.
SELECT AgingBucket, SUM(VisitCount) AS Claims, SUM(InsuranceBalance) AS InsuranceBalance, MAX(RefreshedAt) AS RefreshedAt
FROM dbo.RT_CS_InsuranceVsAging
GROUP BY AgingBucket
ORDER BY AgingBucket;

SELECT SUM(VisitCount) AS TotalClaims, SUM(InsuranceBalance) AS TotalBalance
FROM dbo.RT_CS_InsuranceVsAging;

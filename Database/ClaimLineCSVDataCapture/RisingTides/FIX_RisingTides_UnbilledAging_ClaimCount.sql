-- =====================================================================
-- Rising Tides - Unbilled x Aging: count claims, not accessions
-- Date: 2026-09-29
--
-- Issue: UTI Panel / Current showed 2, client shows 3. Claims 19603645 and
-- 19603724 share AccessionNumber 8558, and the count was
-- COUNT(DISTINCT AccessionNumber, else ClaimID).
-- Fix:   COUNT(DISTINCT ClaimID, else AccessionNumber) in the refresh (snapshot)
--        and read SPs. Filter, rows, buckets and charges are unchanged.
-- Run on: Rising_Tides
-- =====================================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown')                                     AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(ClaimID)), ''),
            NULLIF(LTRIM(RTRIM(AccessionNumber)), '')
        ))                                                                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown');

    TRUNCATE TABLE dbo.RT_UnbilledAging;

    INSERT INTO dbo.RT_UnbilledAging (PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw ORDER BY Panelname, AgingBucket;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshRT_UnbilledAging completed  ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,   -- accepted for signature parity
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
            WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, AgingBucket, ClaimCount, TotalCharges
        FROM    dbo.RT_UnbilledAging
        ORDER BY PanelName, AgingBucket;
        RETURN;
    END

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown')                                 AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(ClaimID)), ''),
            NULLIF(LTRIM(RTRIM(AccessionNumber)), '')
        ))                                                                           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0)                       AS TotalCharges
    FROM   dbo.ClaimLevelData
    WHERE  (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
      AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService    AS DATE) >= @DosFrom)
      AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService    AS DATE) <= @DosTo)
      AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBillFrom)
      AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBillTo)
      AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) >= @FirstBilledFrom)
      AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate  AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown')
    ORDER BY PanelName, AgingBucket;
END
GO

EXEC dbo.usp_RefreshRT_UnbilledAging;
GO

-- Verify: UTI Panel / Current should now be 3
SELECT PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt
FROM dbo.RT_UnbilledAging
WHERE PanelName LIKE 'UTI%'
ORDER BY PanelName, AgingBucket;
GO

PRINT 'FIX_RisingTides_UnbilledAging_ClaimCount completed.';
GO

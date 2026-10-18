-- ============================================================
-- Cove — Unbilled X Aging "Total Billed Charges" empty
-- Date: 2026-09-08
-- Run on the Cove lab database (the one with dbo.ClaimLevelData).
--
-- Root cause: dbo.Cove_UnbilledAging was created with ClaimCount only.
-- usp_GetCove_UnbilledAging's no-filter (snapshot) path therefore returned
-- CAST(0 AS DECIMAL(18,2)) for TotalCharges. Production Summary Unbilled X
-- Aging uses that path on first paint, so the charge column is blank / "-".
--
-- This script:
--   1. Adds TotalCharges to dbo.Cove_UnbilledAging if missing
--   2. Replaces the refresh SP (SUM ChargeAmount)
--   3. Replaces the read SP (snapshot returns TotalCharges)
--   4. Refreshes the snapshot and prints a spot-check
-- ============================================================

SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.Cove_UnbilledAging', 'TotalCharges') IS NULL
    ALTER TABLE dbo.Cove_UnbilledAging
        ADD TotalCharges DECIMAL(18,2) NOT NULL CONSTRAINT DF_Cove_UnbilledAging_TotalCharges DEFAULT 0;
GO

PRINT 'Creating usp_RefreshCove_UnbilledAging...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown')                                        AS AgingDOS,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown');

    TRUNCATE TABLE dbo.Cove_UnbilledAging;

    INSERT INTO dbo.Cove_UnbilledAging (PanelName, AgingDOS, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, AgingDOS, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY Panelname, AgingDOS;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshCove_UnbilledAging completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT 'Creating usp_GetCove_UnbilledAging...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,
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
        SELECT  PanelName,
                AgingDOS                       AS AgingBucket,
                ClaimCount,
                ISNULL(TotalCharges, 0)        AS TotalCharges
        FROM    dbo.Cove_UnbilledAging
        ORDER BY PanelName, AgingDOS;
        RETURN;
    END

    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS PanelName,
        ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown')                                    AS AgingBucket,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                            AS ClaimCount,
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
    GROUP BY LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
             ISNULL(LTRIM(RTRIM(AgingDOS)), 'Unknown')
    ORDER BY PanelName, AgingBucket;
END
GO

PRINT 'Refreshing Cove_UnbilledAging...';
EXEC dbo.usp_RefreshCove_UnbilledAging;
GO

PRINT 'Spot-check (top 20 by charges):';
SELECT TOP 20 PanelName, AgingDOS, ClaimCount, TotalCharges, RefreshedAt
FROM   dbo.Cove_UnbilledAging
ORDER BY TotalCharges DESC, ClaimCount DESC;
GO

PRINT 'FIX_Cove_UnbilledAging_TotalCharges.sql completed.';
GO

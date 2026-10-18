-- PCRLabsofAmerica — Unbilled × Aging (by Aging column)
-- Rule:
--   Filter  : FirstBilledDate IS NULL or blank  (truly unbilled claims)
--   Row     : Panelname  (Panel Group)
--   Columns : Aging bucket | COUNT(DISTINCT visit no) | SUM(ChargeAmount)
--   Note    : PCRLabsofAmerica uses the Aging column for aging bucket.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PCR_UnbilledAging')
CREATE TABLE dbo.PCR_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName    NVARCHAR(500)   NOT NULL,   -- stores Panelname value
    AgingBucket  NVARCHAR(200)   NOT NULL,   -- sourced from Aging column
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown')                                           AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        ))                                                                                AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
    INTO #Raw
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
        ISNULL(LTRIM(RTRIM(AgingBucket)), 'Unknown');

    TRUNCATE TABLE dbo.PCR_UnbilledAging;

    INSERT INTO dbo.PCR_UnbilledAging (PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM #Raw
    ORDER BY Panelname, AgingBucket;

    DROP TABLE IF EXISTS #Raw;

    PRINT 'usp_RefreshPCR_UnbilledAging completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

/*
SELECT PanelName, AgingBucket, ClaimCount, TotalCharges
FROM dbo.PCR_UnbilledAging ORDER BY PanelName, AgingBucket;
*/

-- ============================================================
-- Step 3: Read stored procedure
-- See usp_GetPCR_MonthlyBilledProductionSummary header for the parameter
-- contract (no params -> snapshot table; any param -> live aggregate).
-- The Unbilled Aging tab only filters on PanelNames + dates; the other
-- parameters are accepted for a uniform call signature and otherwise ignored.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,   -- accepted for signature parity; not used
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
        FROM    dbo.PCR_UnbilledAging
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
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
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

PRINT '10_PCRLabsofAmerica_UnbilledAging.sql completed.';

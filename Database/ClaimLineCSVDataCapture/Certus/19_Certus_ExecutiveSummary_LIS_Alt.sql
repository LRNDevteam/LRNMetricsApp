-- ============================================================
-- Certus – Executive Summary LIS Refresh SP
-- File : 19_Certus_ExecutiveSummary_LIS_Alt.sql
-- DB   : Certus_LRN
--
-- Mirrors Augustus\19_Augustus_ExecutiveSummary_LIS_Alt.sql.
-- Owns and TRUNCATEs dbo.Certus_ES_LIS.
-- Sources from dbo.LIMSMaster using ReqCollectDate as the date column.
--
-- Certus LIS column mapping:
--   IncorrectDOS  -> IncorrectDOS / IncorrectDos / Incorrect_DOS / BadDOS  (optional)
--   BillTo        -> BillTo / BillCategory / Bill_Category / BilledorNot
--   BillingStatus -> BillingStatus / NewStatus / Status / BillStatus
--   FinalStatus   -> FinalStatus / SubStatus / Sub_Status / ClientStatus
--   PanelName     -> PanelName / Panelname / PanelType / PanelCategory / ...
--   ReqCollectDate -> ReqCollectDate (priority 0) / DateOfCollection / ...
--
-- IncorrectDOS is applied as a base filter on #Lis (rows where IncorrectDOS is
-- non-blank are excluded entirely), so every row below (A-E) is implicitly
-- "Where IncorrectDOS = Blank" per the LIS Breakdown spec. If the column isn't
-- found on LIMSMaster, no IncorrectDOS filtering is applied (graceful no-op).
--
-- Row hierarchy (B1.<PanelName>, D.<FinalStatus>, E.<BillTo> are all dynamic -
-- one row per DISTINCT value actually present in the data, no fixed/hardcoded list):
--   A     Total Samples          (IncorrectDOS = Blank)
--   B     Billable Samples       (BillTo = 'Insurance Bill')
--     B1.<PanelName>  One per DISTINCT PanelName where BillTo='Insurance Bill'
--     C     Billed     (BillTo='Insurance Bill', BillingStatus='Billed')
--     D     Unbilled   (BillTo='Insurance Bill', BillingStatus='Not Billed')
--       D.<FinalStatus>  One per DISTINCT FinalStatus where BillTo='Insurance Bill'
--                        AND BillingStatus='Not Billed' (e.g. Claim Entered in
--                        Daqbilling, Resulted yet to be billed, D/L Isomer - whatever
--                        FinalStatus values are actually present, not a fixed list)
--   E     Other Samples (BillTo <> 'Insurance Bill')
--     E.<BillTo>  One per DISTINCT BillTo <> 'Insurance Bill' (e.g. Duplicate,
--                 Client Bill, Selfpay, Yet to be Validated, Rejection, System
--                 Test - whatever BillTo values are actually present)
-- ============================================================
SET NOCOUNT ON;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_RefreshCertus_ExecutiveSummary_LIS_Alt]
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE dbo.Certus_ES_LIS;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshCertus_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
        RETURN;
    END

    -- ── Dynamic column detection ─────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

    -- ReqCollectDate is priority 0 for Certus
    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'ReqCollectDate'      THEN 0 WHEN 'RequestCollectDate' THEN 1
            WHEN 'DateOfCollection'    THEN 2 WHEN 'DateofService'      THEN 3
            WHEN 'CollectionDate'      THEN 4 WHEN 'ServiceDate'        THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

    DECLARE @BillToCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillTo','BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
        ORDER BY CASE name WHEN 'BillTo' THEN 0 WHEN 'BillCategory' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BilledorNot' THEN 4 WHEN 'BillStatus' THEN 5 ELSE 6 END);

    DECLARE @BillingStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillingStatus','NewStatus','Status','BillStatus')
        ORDER BY CASE name WHEN 'BillingStatus' THEN 0 WHEN 'NewStatus' THEN 1 WHEN 'Status' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

    DECLARE @FinalStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('FinalStatus','SubStatus','Sub_Status','ClientStatus')
        ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'SubStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

    -- PanelName: Certus uses PanelName/Panelname as priority
    DECLARE @PanelNameCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelName','Panelname','PanelType','PanelCategory','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelName'       THEN 0 WHEN 'Panelname'       THEN 1 WHEN 'PanelType'       THEN 2
            WHEN 'PanelCategory'   THEN 3 WHEN 'TestPanel'        THEN 4 WHEN 'TestPanelName'   THEN 5
            WHEN 'Panel'           THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'        THEN 8
            WHEN 'Test_Panel'      THEN 9 WHEN 'TestPanelname'    THEN 10 ELSE 11 END);

    -- IncorrectDOS: optional flag column. When present, rows where it is
    -- non-blank are excluded from #Lis entirely (base filter for all of A-E).
    DECLARE @IncorrectDOSCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('IncorrectDOS','IncorrectDos','Incorrect_DOS','BadDOS')
        ORDER BY CASE name WHEN 'IncorrectDOS' THEN 0 WHEN 'IncorrectDos' THEN 1 WHEN 'Incorrect_DOS' THEN 2 WHEN 'BadDOS' THEN 3 ELSE 4 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @BillToCol IS NULL OR @BillingStatusCol IS NULL OR @FinalStatusCol IS NULL
    BEGIN
        PRINT 'usp_RefreshCertus_ExecutiveSummary_LIS_Alt: required columns not found on dbo.LIMSMaster - skipping.';
        RETURN;
    END

    -- ── Build #Lis ───────────────────────────────────────────────────────────
    DROP TABLE IF EXISTS #Lis;
    CREATE TABLE #Lis
    (
        Accession     NVARCHAR(100) NOT NULL,
        ESYear        INT           NOT NULL,
        ESMonth       INT           NOT NULL,
        BillTo        NVARCHAR(200) NOT NULL,
        BillingStatus NVARCHAR(200) NOT NULL,
        FinalStatus   NVARCHAR(200) NOT NULL,
        PanelName     NVARCHAR(200) NOT NULL
    );

    DECLARE @PanelExpr NVARCHAR(400) = CASE WHEN @PanelNameCol IS NOT NULL
        THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @PanelNameCol + N']), '''')))'
        ELSE N'''''' END;

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #Lis (Accession, ESYear, ESMonth, BillTo, BillingStatus, FinalStatus, PanelName)
        SELECT
            LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
            YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
            MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillToCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @BillingStatusCol + N']), ''''))),
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), [' + @FinalStatusCol + N']), ''''))),
            ' + @PanelExpr + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL';
    -- IncorrectDOS = Blank base filter (applies to every row A-E). No-op if the
    -- column isn't present on this lab's LIMSMaster.
    IF @IncorrectDOSCol IS NOT NULL
        SET @LisSql += N'
          AND NULLIF(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(50), [' + @IncorrectDOSCol + N']), ''''))), '''') IS NULL';
    SET @LisSql += N';';
    EXEC sp_executesql @LisSql;

    -- LIS periods + grand-total sentinel
    DROP TABLE IF EXISTS #LisPeriods;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
    UNION ALL SELECT 0, 0;

    -- Distinct PanelName values present in LIMSMaster (where BillTo='Insurance Bill')
    -- Drives the B1.<PanelName> sub-row breakdowns dynamically.
    DROP TABLE IF EXISTS #PanelNames;
    SELECT DISTINCT PanelName
    INTO #PanelNames
    FROM #Lis
    WHERE NULLIF(PanelName, '') IS NOT NULL
      AND BillTo = 'Insurance Bill';

    -- Distinct FinalStatus values present where BillTo='Insurance Bill' AND
    -- BillingStatus='Not Billed'. Drives the D.<FinalStatus> sub-row breakdowns
    -- dynamically (e.g. Claim Entered in Daqbilling, Resulted yet to be billed,
    -- D/L Isomer - whatever values are actually in the data, no fixed list).
    DROP TABLE IF EXISTS #FinalStatuses;
    SELECT DISTINCT FinalStatus
    INTO #FinalStatuses
    FROM #Lis
    WHERE NULLIF(FinalStatus, '') IS NOT NULL
      AND BillTo = 'Insurance Bill'
      AND BillingStatus = 'Not Billed';

    -- Distinct BillTo values present where BillTo <> 'Insurance Bill'. Drives
    -- the E.<BillTo> sub-row breakdowns dynamically (e.g. Duplicate, Client
    -- Bill, Selfpay, Yet to be Validated, Rejection, System Test - whatever
    -- values are actually in the data, no fixed list).
    DROP TABLE IF EXISTS #OtherBillTo;
    SELECT DISTINCT BillTo
    INTO #OtherBillTo
    FROM #Lis
    WHERE NULLIF(BillTo, '') IS NOT NULL
      AND BillTo <> 'Insurance Bill';

    -- ────────────────────────────────────────────────────────────────────────
    --  Insert all LIS rows into Certus_ES_LIS
    -- ────────────────────────────────────────────────────────────────────────
    INSERT INTO dbo.Certus_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
    FROM
    (
        -- A  Total Samples
        SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT l.Accession) AS ClaimCount
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- B  Billable Samples (Insurance Bill)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- B1.<PanelName>  Billable Samples by Panel - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'B1.' + pn.PanelName,
               N'  ' + pn.PanelName,
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.PanelName=pn.PanelName THEN l.Accession END)
        FROM #LisPeriods p
        CROSS JOIN #PanelNames pn
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, pn.PanelName

        -- C  Billed (sub of B)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'C', '  Billed',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.BillingStatus='Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D  Unbilled (sub of B)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'D', '  Unbilled',
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- D.<FinalStatus>  Unbilled breakdown by FinalStatus - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'D.' + fs.FinalStatus,
               N'    ' + fs.FinalStatus,
               COUNT(DISTINCT CASE WHEN l.BillTo='Insurance Bill' AND l.BillingStatus='Not Billed'
                                   AND l.FinalStatus = fs.FinalStatus THEN l.Accession END)
        FROM #LisPeriods p
        CROSS JOIN #FinalStatuses fs
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, fs.FinalStatus

        -- E  Other Samples (not Insurance Bill)
        UNION ALL
        SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
               COUNT(DISTINCT CASE WHEN l.BillTo <> 'Insurance Bill' THEN l.Accession END)
        FROM #LisPeriods p
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        -- E.<BillTo>  Other Samples breakdown by BillTo - dynamic
        UNION ALL
        SELECT p.ESYear, p.ESMonth,
               N'E.' + ob.BillTo,
               N'  ' + ob.BillTo,
               COUNT(DISTINCT CASE WHEN l.BillTo = ob.BillTo THEN l.Accession END)
        FROM #LisPeriods p
        CROSS JOIN #OtherBillTo ob
        LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth, ob.BillTo
    ) lis_rows;

    DROP TABLE IF EXISTS #Lis;
    DROP TABLE IF EXISTS #LisPeriods;
    DROP TABLE IF EXISTS #PanelNames;
    DROP TABLE IF EXISTS #FinalStatuses;
    DROP TABLE IF EXISTS #OtherBillTo;

    PRINT 'usp_RefreshCertus_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '19_Certus_ExecutiveSummary_LIS_Alt.sql completed.';
GO

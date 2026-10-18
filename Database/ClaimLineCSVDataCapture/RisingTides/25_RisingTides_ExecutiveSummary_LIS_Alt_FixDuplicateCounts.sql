-- ============================================================
-- RisingTides – LIS Breakdown (Alternate / "L_" scheme) — FIX
-- File : 25_RisingTides_ExecutiveSummary_LIS_Alt_FixDuplicateCounts.sql
-- DB   : Rising_Tides
--
-- FIXES A REGRESSION introduced in a later edit of
-- dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt (originally created by
-- 19_RisingTides_ExecutiveSummary_LIS_Alt.sql):
--
--   Every  COUNT(DISTINCT l.Accession)  was changed to  COUNT(l.Accession)
--   (DISTINCT removed) across all L_A..L_N branches AND the
--   L_B.<PanelName> panel sub-row insert.
--
-- WHY THIS DOUBLES THE RESULTS:
--   #Lis2 is populated by a plain
--     INSERT INTO #Lis2 (...) SELECT ... FROM dbo.LIMSMaster WHERE ...
--   with NO GROUP BY / DISTINCT. If dbo.LIMSMaster has more than one row
--   per Accession (e.g. multiple test/CPT line items per specimen — which
--   is normal for LIMS data), that Accession appears multiple times in
--   #Lis2. COUNT(DISTINCT l.Accession) collapses those duplicates back to
--   one sample (the correct sample count). COUNT(l.Accession) instead
--   counts every duplicate row, so any Accession with N rows in LIMSMaster
--   gets counted N times — inflating (typically doubling) every L_*
--   sample count on the dashboard.
--
-- THE FIX: restore DISTINCT in every COUNT(...) call. Everything else
-- (including the extra BillingStatus column added in the later edit) is
-- preserved as-is.
--
-- ALSO FIXES a second issue confirmed via:
--   SELECT DISTINCT RessultedStatus, ClientStatus, ClaimStatus, BillingStatus,
--                    OrderStatus FROM LIMSMaster
-- which shows ClaimStatus and BillingStatus are genuinely separate columns
-- with separate value domains:
--   ClientStatus  : '', 'Client Bill', 'Billing Review Required', 'Self Pay',
--                   'Test Entries', 'Rejected Sample'   (NEVER 'Not Entered in AMD')
--   ClaimStatus   : 'Not Entered in AMD', 'Entered', 'Billed'
--   BillingStatus : 'Not Ready To Bill', 'No Bill', 'Ready To Bill', 'Billed'
--
--   - L_D ("Not Entered in AMD") checked l.ClientStatus IN ('Not Entered in AMD'),
--     which can never match (that value never appears in ClientStatus), so
--     L_D was always 0 even though its children L_D1/L_D2 were non-zero.
--     Reverted to the original logic: ClientStatus IN ('','Billing Review
--     Required') AND BilledNot = 'Unbilled' (= L_D1 + L_D2).
--   - L_J ("Billing Status No Bill") checked l.ClaimStatus = 'No Bill', but
--     'No Bill' never appears in ClaimStatus — only in BillingStatus. Fixed
--     to l.BillingStatus = 'No Bill'.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;

    -- Remove any previously-generated 'L_*' rows from this alternate breakdown
    -- (leaves the existing A..I rows from usp_RefreshRT_ExecutiveSummary alone).
    DELETE FROM dbo.RT_ES_LIS WHERE RoleID LIKE 'L\_%' ESCAPE '\';

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        PRINT 'usp_RefreshRT_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found – nothing to do.';
        RETURN;
    END

    DROP TABLE IF EXISTS #Lis2;
    CREATE TABLE #Lis2
    (
        Accession     NVARCHAR(100) NOT NULL,
        ESYear        INT           NOT NULL,
        ESMonth       INT           NOT NULL,
        ResultedNot   NVARCHAR(50)  NOT NULL,
        ClientStatus  NVARCHAR(100) NOT NULL,
        BilledNot     NVARCHAR(20)  NOT NULL,
        BillingStatus NVARCHAR(100) NOT NULL,  -- raw BillingStatus value
        ClaimStatus   NVARCHAR(100) NOT NULL,
        OrderStatus   NVARCHAR(100) NOT NULL,
        PanelName     NVARCHAR(300) NOT NULL
    );

    -- Auto-detect the panel-name column on dbo.LIMSMaster (same candidate list /
    -- priority order as 18_RisingTides_ExecutiveSummary_Detail.sql's @PanelCol).
    DECLARE @PanelCol2 SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
            WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5
            WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 ELSE 9 END);

    DECLARE @PanelExpr2 NVARCHAR(400) = ISNULL(
        'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol2 + N']), '''')))', '''''');

    DECLARE @Lis2Sql NVARCHAR(MAX) = N'
        INSERT INTO #Lis2 (Accession, ESYear, ESMonth, ResultedNot, ClientStatus, BilledNot, BillingStatus, ClaimStatus, OrderStatus, PanelName)
        SELECT
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), Accession), ''''))),
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE)),
            LTRIM(RTRIM(ISNULL(RessultedStatus, ''''))),
            LTRIM(RTRIM(ISNULL(ClientStatus,    ''''))),
            CASE WHEN LTRIM(RTRIM(ISNULL(BillingStatus, ''''))) = ''Billed'' THEN ''Billed'' ELSE ''Unbilled'' END,
            LTRIM(RTRIM(ISNULL(BillingStatus,   ''''))),
            LTRIM(RTRIM(ISNULL(ClaimStatus,     ''''))),
            LTRIM(RTRIM(ISNULL(OrderStatus,     ''''))),
            ' + @PanelExpr2 + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '''') IS NOT NULL;';

    EXEC sp_executesql @Lis2Sql;

    -- Periods: every (Year,Month) present in #Lis2 PLUS a (0,0) grand-total sentinel.
    DROP TABLE IF EXISTS #LisPeriods2;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods2 FROM #Lis2
    UNION ALL SELECT 0, 0;

    -- Distinct panel names among Resulted samples, for the L_B.<PanelName> sub-rows.
    DROP TABLE IF EXISTS #LisPanels2;
    SELECT DISTINCT PanelName INTO #LisPanels2
    FROM #Lis2
    WHERE ResultedNot = 'Resulted' AND PanelName <> '';

    INSERT INTO dbo.RT_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RoleID, Description, ESYear, ESMonth, SampleCount, 0, GETDATE()
    FROM
    (
        -- L_A  Total Samples
        SELECT p.ESYear, p.ESMonth, 'L_A' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT l.Accession) AS SampleCount
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B  Billable Samples - Resulted
        SELECT p.ESYear, p.ESMonth, 'L_B', 'Billable Samples - Resulted',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_C  Billed to Insurance (own heading row, NOT an indented sub-row of L_B —
        -- no leading spaces on Description so it renders as 'es-cat-row')
        SELECT p.ESYear, p.ESMonth, 'L_C', 'Billed to Insurance',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = '' AND l.BilledNot = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_D  Not Entered in AMD  (= D1 + D2: ClientStatus '' or 'Billing Review Required', Unbilled)
        SELECT p.ESYear, p.ESMonth, 'L_D', 'Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus IN ('', 'Billing Review Required')
              AND l.BilledNot = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_D1  Received  (D-rows where OrderStatus = 'Completed')
        SELECT p.ESYear, p.ESMonth, 'L_D1', '    Received',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus IN ('', 'Billing Review Required')
              AND l.BilledNot = 'Unbilled' AND l.OrderStatus = 'Completed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_D2  Billing Review Required  (remaining D-rows, OrderStatus <> 'Completed')
        SELECT p.ESYear, p.ESMonth, 'L_D2', '    Billing Review Required',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus IN ('', 'Billing Review Required')
              AND l.BilledNot = 'Unbilled' AND l.OrderStatus <> 'Completed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_E  Unbilled - Not released to Payer (EDI Hold)
        SELECT p.ESYear, p.ESMonth, 'L_E', 'Unbilled - Not released to Payer (EDI Hold)',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = '' AND l.BilledNot = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_F  Client Bill
        SELECT p.ESYear, p.ESMonth, 'L_F', 'Client Bill',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_F1  Client Bill - Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_F1', '    Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill'
              AND l.BilledNot = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_F2  Client Bill - Billed
        SELECT p.ESYear, p.ESMonth, 'L_F2', '    Billed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill'
              AND l.BilledNot = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_G  Self Pay  (ASSUMPTION: ClientStatus = 'Self Pay')
        SELECT p.ESYear, p.ESMonth, 'L_G', 'Self Pay',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_G1  Self Pay - Billed
        SELECT p.ESYear, p.ESMonth, 'L_G1', '    Billed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Self Pay'
              AND l.BilledNot = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_G2  Self Pay - Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_G2', '    Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Self Pay'
              AND l.BilledNot = 'Unbilled' AND l.OrderStatus = 'Completed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_G3  Entered
        SELECT p.ESYear, p.ESMonth, 'L_G3', '    Entered',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Self Pay'
              AND l.BilledNot = 'Unbilled' AND l.OrderStatus <> 'Completed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_H  Test Entries
        SELECT p.ESYear, p.ESMonth, 'L_H', 'Test Entries',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_H1  Test Entries - Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_H1', '    Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Test Entries'
              AND l.BilledNot = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_J  Billing Status  No Bill  (raw BillingStatus = 'No Bill' — 'No Bill' only ever
        -- occurs in BillingStatus, never in ClaimStatus)
        SELECT p.ESYear, p.ESMonth, 'L_J', 'Billing Status  No Bill',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_K  Not Resulted
        SELECT p.ESYear, p.ESMonth, 'L_K', 'Not Resulted',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_L  Not Resulted - Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_L', 'Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = ''
              AND l.BilledNot = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_L1  Collected
        SELECT p.ESYear, p.ESMonth, 'L_L1', '    Collected',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = ''
              AND l.BilledNot = 'Unbilled'
              AND l.OrderStatus = 'Sample(s) Collected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_M  Not Resulted - Client Bill
        SELECT p.ESYear, p.ESMonth, 'L_M', 'Client Bill',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Client Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_N  Not Resulted - Rejected Sample
        SELECT p.ESYear, p.ESMonth, 'L_N', 'Rejected Sample',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Rejected Sample'
        GROUP BY p.ESYear, p.ESMonth
    ) lis2;

    -- ── L_B.<PanelName> sub-rows (panel-wise breakdown of "Billable Samples - Resulted") ──
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_B.%' ESCAPE '\';

    INSERT INTO dbo.RT_ES_LIS_Panel (RoleID, PanelName, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT 'L_B.' + pn.PanelName, pn.PanelName, '    ' + pn.PanelName,
           p.ESYear, p.ESMonth, COUNT(DISTINCT l.Accession), 0, GETDATE()
    FROM #LisPanels2 pn
    CROSS JOIN #LisPeriods2 p
    LEFT JOIN #Lis2 l
           ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
          AND l.ResultedNot = 'Resulted'
          AND l.PanelName = pn.PanelName
    GROUP BY pn.PanelName, p.ESYear, p.ESMonth;

    DROP TABLE IF EXISTS #Lis2;
    DROP TABLE IF EXISTS #LisPeriods2;
    DROP TABLE IF EXISTS #LisPanels2;

    PRINT 'usp_RefreshRT_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '25_RisingTides_ExecutiveSummary_LIS_Alt_FixDuplicateCounts.sql completed.';
GO

-- ============================================================
-- RisingTides – LIS Breakdown (Alternate / "L_" scheme) — REDESIGN
-- File : 27_RisingTides_ExecutiveSummary_LIS_Alt_NewLogicScheme.sql
-- DB   : Rising_Tides
--
-- Supersedes 25_RisingTides_ExecutiveSummary_LIS_Alt_FixDuplicateCounts.sql.
-- Implements the new A/B logic scheme supplied by the user (image table:
-- "Total Samples" / A "Billable Samples - Resulted" (A.1-A.7) /
-- B "Not Resulted" (B.1-B.2)).
--
-- NEW #Lis2 COLUMNS:
--   PaymentMethod  – raw LIMSMaster.PaymentMethod   ('Insurance','Client Bill','Self Pay', ...)
--   SampleStatus   – raw LIMSMaster.SampleStatus    ('Collected','Received','Rejected', ...)
-- (both are real columns on dbo.LIMSMaster, confirmed via SqlLisSummaryRepository.cs)
--
-- ROLEID MAP (RT_ES_LIS, all <= 10 chars):
--   L_0    Total Samples                          (grand total, no filter)
--   L_A    Billable Samples - Resulted
--   L_A1     Billed to Insurance
--   L_A1a      Billed In AMD
--   L_A2     Not Entered in AMD
--   L_A2a      Received
--   L_A2b      Billing Review Required
--   L_A3     Unbilled
--   L_A4     Client Bill
--   L_A4a      Not Entered in AMD
--   L_A4b      Billed
--   L_A5     Self Pay
--   L_A5a      Billed
--   L_A5b      Not Entered in AMD
--   L_A5c      Entered
--   L_A6     Test Entries
--   L_A6a      Not Entered in AMD
--   L_A7     Billing Status - No Bill
--   L_B    Not Resulted
--   L_B1     Not Entered in AMD
--   L_B1a      Collected
--   L_B1b      Received
--   L_B2     Rejected Sample
--   L_A.<PanelName>   panel-wise breakdown of "Billable Samples - Resulted"
--                      (per user: "for 'Billable Samples - Resulted' alone,
--                      use the Panel subcategory" — same panel-rows feature
--                      as before, renamed from L_B.<PanelName> to L_A.<PanelName>
--                      since 'Billable Samples - Resulted' is now RoleID L_A)
--
-- KNOWN ITEMS CARRIED OVER LITERALLY FROM THE IMAGE (please confirm/correct
-- in a follow-up once you see the live counts — same pattern as the
-- ClientStatus fix in file 25):
--
--   1. A.2 "Not Entered in AMD" requires ClaimStatus='Billed' AND
--      BilledorNot='Billed' AND ClientStatus='Billing Review Required'
--      AND BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
--      — as written this is internally consistent (BillingStatus='Billed'
--      is in the allowed list) but currently returns 0 against the sample
--      26-row LIMSMaster distinct-value set (no BRR row has ClaimStatus=
--      'Billed'). Its two sub-rows (Received / Billing Review Required)
--      are IDENTICAL per the image — implemented as exact duplicates.
--
--   2. A.4a "Not Entered in AMD" (under Client Bill), A.5b "Not Entered in
--      AMD" and A.5c "Entered" (under Self Pay), and A.6 / A.6a "Test
--      Entries" / "Not Entered in AMD" all specify
--      BilledorNot = 'Unbilled' AND BillingStatus = 'Billed' simultaneously.
--      Since #Lis2.BilledNot is DERIVED as
--        CASE WHEN BillingStatus='Billed' THEN 'Billed' ELSE 'Unbilled' END,
--      these two conditions can never both be true — these branches will
--      always return 0. Implemented literally as specified; let me know if
--      the BillingStatus='Billed' clause should instead read
--      BillingStatus <> 'Billed' (or be dropped) for these rows.
--
--   3. B.1 "Collected" and "Received" sub-rows are IDENTICAL per the image
--      (both Sample Status = 'Collected') — implemented as exact duplicates,
--      per your confirmation.
--
--   4. A.6 "Test Entries" and its A.6a "Not Entered in AMD" sub-row are also
--      IDENTICAL per the image — implemented as exact duplicates.
--
-- DISTINCT(Accession) is used everywhere (per the file-25 fix) to avoid
-- double-counting LIMSMaster's multiple test/CPT rows per Accession.
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
        ClaimStatus   NVARCHAR(100) NOT NULL,  -- raw ClaimStatus value
        OrderStatus   NVARCHAR(100) NOT NULL,
        PaymentMethod NVARCHAR(100) NOT NULL,  -- raw PaymentMethod value
        SampleStatus  NVARCHAR(100) NOT NULL,  -- raw SampleStatus value
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
        INSERT INTO #Lis2 (Accession, ESYear, ESMonth, ResultedNot, ClientStatus, BilledNot, BillingStatus, ClaimStatus, OrderStatus, PaymentMethod, SampleStatus, PanelName)
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
            LTRIM(RTRIM(ISNULL(PaymentMethod,   ''''))),
            LTRIM(RTRIM(ISNULL(SampleStatus,    ''''))),
            ' + @PanelExpr2 + N'
        FROM dbo.LIMSMaster
        WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '''') IS NOT NULL;';

    EXEC sp_executesql @Lis2Sql;

    -- Periods: every (Year,Month) present in #Lis2 PLUS a (0,0) grand-total sentinel.
    DROP TABLE IF EXISTS #LisPeriods2;
    SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods2 FROM #Lis2
    UNION ALL SELECT 0, 0;

    -- Distinct panel names among Resulted samples, for the L_A.<PanelName> sub-rows.
    DROP TABLE IF EXISTS #LisPanels2;
    SELECT DISTINCT PanelName INTO #LisPanels2
    FROM #Lis2
    WHERE ResultedNot = 'Resulted' AND PanelName <> '';

    INSERT INTO dbo.RT_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT lis2.RoleID, lis2.Description, lis2.ESYear, lis2.ESMonth, lis2.SampleCount, 0, GETDATE()
    FROM
    (
        -- L_0  Total Samples
        SELECT p.ESYear, p.ESMonth, 'L_0' AS RoleID, 'Total Samples' AS Description,
               COUNT(DISTINCT l.Accession) AS SampleCount
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A  Billable Samples - Resulted
        SELECT p.ESYear, p.ESMonth, 'L_A', 'Billable Samples - Resulted',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1  Billed to Insurance
        SELECT p.ESYear, p.ESMonth, 'L_A1', 'Billed to Insurance',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1a  Billed to Insurance - Billed In AMD
        SELECT p.ESYear, p.ESMonth, 'L_A1a', '    Billed In AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2  Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2a  Not Entered in AMD - Received
        SELECT p.ESYear, p.ESMonth, 'L_A2a', '    Received',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2b  Not Entered in AMD - Billing Review Required  (identical to L_A2a per spec)
        SELECT p.ESYear, p.ESMonth, 'L_A2b', '    Billing Review Required',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A3  Unbilled
        SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Entered'
              AND l.BilledNot = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A4  Client Bill
        SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
              AND l.ClaimStatus IN ('Billed','Not Entered in AMD')
              AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A4a  Client Bill - Not Entered in AMD
        -- NOTE: spec also lists BillingStatus='Billed' here, which conflicts with
        -- BilledorNot='Unbilled' (BilledNot is derived FROM BillingStatus='Billed').
        -- Implemented WITHOUT the BillingStatus='Billed' clause so this branch is
        -- not permanently 0; flag if BillingStatus='Billed' should be kept/changed.
        SELECT p.ESYear, p.ESMonth, 'L_A4a', '    Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
              AND l.ClaimStatus = 'Not Entered in AMD' AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Client Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A4b  Client Bill - Billed
        SELECT p.ESYear, p.ESMonth, 'L_A4b', '    Billed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
              AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
              AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5  Self Pay
        SELECT p.ESYear, p.ESMonth, 'L_A5', 'Self Pay',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClientStatus = 'Self Pay'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5a  Self Pay - Billed
        SELECT p.ESYear, p.ESMonth, 'L_A5a', '    Billed',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
              AND l.ClientStatus = 'Self Pay' AND l.BillingStatus IN ('Billed','Not Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5b  Self Pay - Not Entered in AMD
        -- NOTE: same BillingStatus='Billed' vs BilledorNot='Unbilled' conflict as
        -- L_A4a above — implemented without BillingStatus='Billed'.
        SELECT p.ESYear, p.ESMonth, 'L_A5b', '    Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Not Entered in AMD' AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5c  Self Pay - Entered
        -- NOTE: same BillingStatus='Billed' vs BilledorNot='Unbilled' conflict as
        -- L_A4a above — implemented without BillingStatus='Billed'.
        SELECT p.ESYear, p.ESMonth, 'L_A5c', '    Entered',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Entered' AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6  Test Entries
        -- NOTE: spec's Test Entries logic also conflicts on BillingStatus='Billed'
        -- vs BilledorNot='Unbilled' (see header note 2) — implemented without
        -- BillingStatus='Billed'.
        SELECT p.ESYear, p.ESMonth, 'L_A6', 'Test Entries',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.BilledNot = 'Unbilled' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6a  Test Entries - Not Entered in AMD  (identical to L_A6 per spec)
        SELECT p.ESYear, p.ESMonth, 'L_A6a', '    Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.BilledNot = 'Unbilled' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7  Billing Status - No Bill
        SELECT p.ESYear, p.ESMonth, 'L_A7', 'Billing Status - No Bill',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B  Not Resulted
        SELECT p.ESYear, p.ESMonth, 'L_B', 'Not Resulted',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1  Not Resulted - Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_B1', 'Not Entered in AMD',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1a  Not Entered in AMD - Collected
        SELECT p.ESYear, p.ESMonth, 'L_B1a', '    Collected',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Collected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1b  Not Entered in AMD - Received  (identical to L_B1a per spec)
        SELECT p.ESYear, p.ESMonth, 'L_B1b', '    Received',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Collected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B2  Not Resulted - Rejected Sample
        SELECT p.ESYear, p.ESMonth, 'L_B2', 'Rejected Sample',
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth
    ) lis2;

    -- ── L_A.<PanelName> sub-rows (panel-wise breakdown of "Billable Samples - Resulted") ──
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_A.%' ESCAPE '\';
    -- Clean up legacy 'L_B.<PanelName>' rows from prior versions of this SP (file 19/25).
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_B.%' ESCAPE '\';

    INSERT INTO dbo.RT_ES_LIS_Panel (RoleID, PanelName, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT 'L_A.' + pn.PanelName, pn.PanelName, '    ' + pn.PanelName,
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

PRINT '27_RisingTides_ExecutiveSummary_LIS_Alt_NewLogicScheme.sql completed.';
GO

-- ============================================================
-- RisingTides – LIS Breakdown (Alternate / "L_" scheme)
-- File : 19_RisingTides_ExecutiveSummary_LIS_Alt.sql
-- DB   : Rising_Tides
--
-- Adds a SECOND LIS breakdown to dbo.RT_ES_LIS, using the RoleID/Description
-- layout supplied by the user (A..N, with bullet sub-rows under D, F, G, H, L).
-- Runs ALONGSIDE the existing A..I breakdown populated by
-- 16_RisingTides_ExecutiveSummary_Aggregate.sql / usp_RefreshRT_ExecutiveSummary
-- — that logic is untouched. To avoid RoleID collisions, every row here is
-- prefixed 'L_' (L_A .. L_N, with L_D1/L_D2, L_F1/L_F2, L_G1-G3, L_H1, L_L1
-- as the indented sub-rows). Description for sub-rows is prefixed with two
-- spaces ('  ') so the dashboard's es-sub-row styling applies, matching the
-- existing D1/D2/D3/etc. convention.
--
-- RoleID  Description
-- ------  ----------------------------------------------------------------
-- L_A     Total Samples
-- L_B     Billable Samples - Resulted
-- L_C     Billed to Insurance
-- L_D     Not Entered in AMD
-- L_D1      Received
-- L_D2      Billing Review Required
-- L_E     Unbilled - Not released to Payer (EDI Hold)
-- L_F     Client Bill
-- L_F1      Not Entered in AMD
-- L_F2      Billed
-- L_G     Self Pay
-- L_G1      Billed
-- L_G2      Not Entered in AMD
-- L_G3      Entered
-- L_H     Test Entries
-- L_H1      Not Entered in AMD
-- L_J     Billing Status  No Bill
-- L_K     Not Resulted
-- L_L     Not Entered in AMD
-- L_L1      Collected
-- L_M     Client Bill
-- L_N     Rejected Sample
--
-- C, D, E, F, G, H, J, K, L, M, N are top-level heading rows ('es-cat-row',
-- bold, no leading spaces). Only D1/D2, F1/F2, G1/G2/G3, H1, L1 (4-space
-- prefix) and the L_B.<PanelName> panel rows are indented sub-rows
-- ('es-sub-row', Description starts with 2+ spaces).
--
-- Also populates dbo.RT_ES_LIS_Panel with one 'L_B.<PanelName>' row per
-- distinct panel (Resulted samples only) per period, displayed as indented
-- sub-rows under L_B (panel name auto-detected on dbo.LIMSMaster the same
-- way as 18_RisingTides_ExecutiveSummary_Detail.sql's @PanelCol).
--
-- ── ASSUMPTIONS (verified against real LIMSMaster data on 2026-06-11) ──────
-- All conditions reuse the same four source fields as the existing A..I
-- breakdown (see 16_RisingTides_ExecutiveSummary_Aggregate.sql header):
--   ResultedNot  <- LIMSMaster.RessultedStatus  ('Resulted' | 'Not Resulted')
--   ClientStatus <- LIMSMaster.ClientStatus     ('', 'Client Bill',
--                    'Billing Review Required', 'Test Entries',
--                    'Rejected Sample', 'Self Pay')
--   BilledNot    <- derived: BillingStatus='Billed' -> 'Billed' else 'Unbilled'
--   ClaimStatus  <- raw LIMSMaster.BillingStatus    ('Billed', 'No Bill',
--                    'Ready To Bill', 'Not Ready To Bill')
--   OrderStatus  <- LIMSMaster.OrderStatus          ('Completed', 'Rejected',
--                    'Recollect Required', 'Sample(s) Collected')
--
-- IMPORTANT FINDING: 'Not Entered in AMD' and 'Entered' are NOT real
-- BillingStatus values (the actual values are listed above). Every condition
-- that originally checked l.ClaimStatus = 'Not Entered in AMD' / 'Entered'
-- always evaluated to FALSE, which is why L_D, L_D1, L_D2, L_E, L_F1, L_G2,
-- L_G3, L_H1, L_L always returned 0. Those conditions have been REVISED below
-- to use ClientStatus + BilledNot ('' / 'Unbilled') instead, with D1/G2/L1 vs
-- D2/G3 split on OrderStatus = 'Completed' (D1+D2=D and G2+G3=unbilled-G by
-- construction). L_L1 "Collected" now matches OrderStatus = 'Sample(s)
-- Collected' (the real value; 'Collected' alone never occurs).
--
-- Resolved guesses:
--   L_D1 "Received"            -> ClientStatus IN ('','Billing Review Required')
--                                  AND Unbilled AND OrderStatus='Completed'
--   L_D2 "Billing Review Required" -> same as D1 but OrderStatus<>'Completed'
--   L_G  "Self Pay" (+ G1-G3)   -> ClientStatus = 'Self Pay'  (confirmed real value)
--   L_J  "Billing Status No Bill"  -> raw BillingStatus = 'No Bill' (confirmed real value)
--   L_L1 "Collected"            -> OrderStatus = 'Sample(s) Collected'
--
-- Remaining open item: ~14 grand-total samples have RessultedStatus='Resulted'
-- AND ClientStatus='Rejected Sample' with BillingStatus<>'Billed'. These don't
-- fall into any of C/D/E/F/G/H/J as currently defined (L_N "Rejected Sample"
-- only covers ResultedNot='Not Resulted'). Left unbucketed for now -- flag if
-- these need to be surfaced somewhere.
-- ============================================================
SET NOCOUNT ON;
GO



Create or  ALTER   PROCEDURE [dbo].[usp_RefreshRT_ExecutiveSummary_LIS_Alt]
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
		OrderID	      NVARCHAR(100) NOT NULL,
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
        INSERT INTO #Lis2 (Accession,OrderID, ESYear, ESMonth, ResultedNot, ClientStatus, BilledNot, BillingStatus, ClaimStatus, OrderStatus, PaymentMethod, SampleStatus, PanelName)
        SELECT
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), Accession), ''''))),
			LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), OrderID), ''''))),
            YEAR (TRY_CAST(RequestCollectDate AS DATE)),
            MONTH(TRY_CAST(RequestCollectDate AS DATE)),
            LTRIM(RTRIM(ISNULL(RessultedStatus, ''''))),
            LTRIM(RTRIM(ISNULL(ClientStatus,    ''''))),
            --CASE WHEN LTRIM(RTRIM(ISNULL(BillingStatus, ''''))) = ''Billed'' THEN ''Billed'' ELSE ''Unbilled'' END,
            LTRIM(RTRIM(ISNULL(BilledorNot,   ''''))),
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
    -- Each distinct panel gets its own SortOrder slot (211, 212, 213, ...) so the
    -- panel breakdown sits right under the "Billable Samples - Resulted" header
    -- (SortOrder 200) and before A1 (SortOrder 300).
    DROP TABLE IF EXISTS #LisPanels2;
    SELECT PanelName, 210 + CAST(ROW_NUMBER() OVER (ORDER BY PanelName) AS INT) AS PanelSortOrder
    INTO #LisPanels2
    FROM (SELECT DISTINCT PanelName FROM #Lis2 WHERE ResultedNot = 'Resulted' AND PanelName <> '') AS dp;

    INSERT INTO dbo.RT_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt, SortOrder)
    SELECT lis2.RoleID, lis2.Description, lis2.ESYear, lis2.ESMonth, lis2.SampleCount, 0, GETDATE(), lis2.SortOrder
    FROM
    (
        -- L_0  Total Samples  (SortOrder 100 — always first)
        SELECT p.ESYear, p.ESMonth, 'L_0' AS RoleID, 'Total Samples' AS Description, 100 AS SortOrder,
               COUNT(DISTINCT l.Accession) AS SampleCount
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A  Billable Samples - Resulted  (SortOrder 200)
        SELECT p.ESYear, p.ESMonth, 'L_A', 'Billable Samples - Resulted', 200,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1  Billed to Insurance  (SortOrder 300)
        SELECT p.ESYear, p.ESMonth, 'L_A1', 'Billed to Insurance', 300,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1a  Billed to Insurance - Billed In AMD  (SortOrder 301)
        SELECT p.ESYear, p.ESMonth, 'L_A1a', '    Billed In AMD', 301,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A2  Not Entered in AMD  (SortOrder 310)
        --SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD', 310,
        --       COUNT(DISTINCT l.OrderID)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        --      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
        --      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        --GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A2a  Not Entered in AMD - Received  (SortOrder 311)
        --SELECT p.ESYear, p.ESMonth, 'L_A2a', '    Received', 311,
        --       COUNT(DISTINCT l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        --      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
        --      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        --      AND l.SampleStatus = 'Received'
        --GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A2b  Not Entered in AMD - Billing Review Required  (identical to L_A2a per spec) (SortOrder 312)
        --SELECT p.ESYear, p.ESMonth, 'L_A2b', '    Billing Review Required', 312,
        --       COUNT(DISTINCT l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        --      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
        --      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        --      AND l.SampleStatus = 'Received'
        --GROUP BY p.ESYear, p.ESMonth

		UNION ALL
        -- L_A2  Not Entered in AMD  (SortOrder 310)
        SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD', 310,
               COUNT(DISTINCT l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
			 
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2a  Not Entered in AMD - Received  (SortOrder 311)
        SELECT p.ESYear, p.ESMonth, 'L_A2a', '    Received', 311,
               COUNT(DISTINCT l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
             AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2b  Not Entered in AMD - Billing Review Required  (identical to L_A2a per spec) (SortOrder 312)
        SELECT p.ESYear, p.ESMonth, 'L_A2b', '    Billing Review Required', 312,
               COUNT(DISTINCT l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              --AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth


        --UNION ALL
        ---- L_A3  Unbilled  (SortOrder 320)
        --SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled', 320,
        --       COUNT(DISTINCT l.OrderID)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Entered'
        --      AND l.BilledNot = 'Unbilled'
        --GROUP BY p.ESYear, p.ESMonth

		   UNION ALL
        -- L_A3  Unbilled  (SortOrder 320)
        SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled', 320,
               COUNT(DISTINCT l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND (l.ClientStatus is NULL or ClientStatus='')
              AND l.BilledNot = 'Unbilled'
        GROUP BY p.ESYear, p.ESMonth


        --UNION ALL
        ---- L_A4  Client Bill  (SortOrder 330)
        --SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill', 330,
        --       COUNT(DISTINCT l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
        --      AND l.ClaimStatus IN ('Billed','Not Entered in AMD')
        --      AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        --GROUP BY p.ESYear, p.ESMonth

		UNION ALL
        -- L_A4  Client Bill  (SortOrder 330)
        SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill', 330,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill' 
			  AND l.BillingStatus in ('Billed','Ready to Bill')
        GROUP BY p.ESYear, p.ESMonth


        UNION ALL
        -- L_A4a  Client Bill - Not Entered in AMD  (SortOrder 331)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Client Bill, 
		--Billing Status = Billed, Ready to Bill, Claim Status = Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A4a', '    Not Entered in AMD', 331,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'  AND l.ClientStatus = 'Client Bill'   AND l.BillingStatus in ('Billed','Ready to Bill')
			  AND l.ClaimStatus = 'Not Entered in AMD' 
             
        GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A4b  Client Bill - Billed  (SortOrder 332)
        --SELECT p.ESYear, p.ESMonth, 'L_A4b', '    Billed', 332,
        --       COUNT(DISTINCT l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
        --      AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
        --      AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        --GROUP BY p.ESYear, p.ESMonth
		
        UNION ALL
        -- L_A4b  Client Bill - Billed  (SortOrder 332)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay, 
		--Billing Status NOT Equal to No BILL,
		--Claim Status = Not Entered in AMD
		--Select Distinct BillingSTatus from LIMSMaster
        SELECT p.ESYear, p.ESMonth, 'L_A4b', '    Billed', 332,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
               AND l.ResultedNot = 'Resulted'  AND l.ClientStatus = 'Self Pay'   
			   AND l.BillingStatus <>'No Bill' and ClaimStatus='Not Entered in AMD'
			  
        GROUP BY p.ESYear, p.ESMonth
		
        UNION ALL
        -- L_A5  Self Pay  (SortOrder 340)
        SELECT p.ESYear, p.ESMonth, 'L_A5', 'Self Pay', 340,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClientStatus = 'Self Pay'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5a  Self Pay - Billed  (SortOrder 341)
        SELECT p.ESYear, p.ESMonth, 'L_A5a', '    Billed', 341,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Billed' AND l.BilledNot = 'Billed'
              AND l.ClientStatus = 'Self Pay' AND l.BillingStatus IN ('Billed','Not Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5b  Self Pay - Not Entered in AMD  (SortOrder 342)
        -- NOTE: same BillingStatus='Billed' vs BilledorNot='Unbilled' conflict as
        -- L_A4a above — implemented without BillingStatus='Billed'.
        SELECT p.ESYear, p.ESMonth, 'L_A5b', '    Not Entered in AMD', 342,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Not Entered in AMD' AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5c  Self Pay - Entered  (SortOrder 343)
       -- L_A4a above — implemented without BillingStatus='Billed'.
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay,
		--Billing Status NOT Equal to No BILL, Claim Status = Entered
        SELECT p.ESYear, p.ESMonth, 'L_A5c', '    Entered', 343,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'AND l.ClaimStatus = 'Entered' 
			  AND l.BillingStatus <>'No Bill'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6  Test Entries  (SortOrder 350)
        -- Count [Order ID] WHERE Resulted / Not = Resulted,
		-- Client Status = Test Entries, Billing Status NOT Equal to No BILL
       
        SELECT p.ESYear, p.ESMonth, 'L_A6', 'Test Entries', 350,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND   l.BillingStatus <>'No Bill'
              AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6a  Test Entries - Not Entered in AMD  (identical to L_A6 per spec) (SortOrder 351)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Test Entries,
		--Billing Status NOT Equal to No BILL, Claim Status = Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A6a', '    Not Entered in AMD', 351,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.BillingStatus <>'No Bill' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7  Billing Status - No Bill  (SortOrder 360)
        SELECT p.ESYear, p.ESMonth, 'L_A7', 'Billing Status - No Bill', 360,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7a  Billing Status - No Bill - Rejected  (SortOrder 361, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7a', '    Rejected', 361,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7b  Billing Status - No Bill - Completed  (SortOrder 362, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7b', '    Completed', 362,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Completed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7c  Billing Status - No Bill - Recollect Required  (SortOrder 363, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7c', '    Recollect Required', 363,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Recollect Required'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B  Not Resulted  (SortOrder 400 — immediately follows L_A7c/363)
        SELECT p.ESYear, p.ESMonth, 'L_B', 'Not Resulted', 400,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1  Not Resulted - Not Entered in AMD  (SortOrder 410)
		--Count [Order ID] WHERE Resulted / Not = Not Resulted, Claim Status = Not Entered in AMD, 
		--Client Status = Blank
        SELECT p.ESYear, p.ESMonth, 'L_B1', 'Not Entered in AMD', 410,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			  and (ClientStatus is null or ClientStatus='')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1a  Not Entered in AMD - Collected  (SortOrder 411)
		--Count [Order ID] WHERE Resulted / Not = Not Resulted, Claim Status = Not Entered in AMD, 
		--Client Status = Blank, Sample Status = Collected

        SELECT p.ESYear, p.ESMonth, 'L_B1a', '    Collected', 411,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Collected'  and (ClientStatus is null or ClientStatus='')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1b  Not Entered in AMD - Received  (identical to L_B1a per spec) (SortOrder 412)
        SELECT p.ESYear, p.ESMonth, 'L_B1b', '    Received', 412,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Received'  and (ClientStatus is null or ClientStatus='')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B2  Not Resulted - Rejected Sample  (SortOrder 420)
        SELECT p.ESYear, p.ESMonth, 'L_B2', 'Rejected Sample', 420,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B3  Not Resulted - Client Bill  (SortOrder 430)
        -- Count [Accession] WHERE ResultedNot = 'Not Resulted', ClientStatus = 'Client Bill'
        SELECT p.ESYear, p.ESMonth, 'L_B3', '    Client Bill', 430,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Client Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B4  Not Resulted - Self Pay  (SortOrder 440)
        -- Count [Accession] WHERE ResultedNot = 'Not Resulted', ClientStatus = 'Self Pay'
        SELECT p.ESYear, p.ESMonth, 'L_B4', '    Self Pay', 440,
               COUNT(DISTINCT l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth
    ) lis2;

    -- ── L_A.<PanelName> sub-rows (panel-wise breakdown of "Billable Samples - Resulted") ──
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_A.%' ESCAPE '\';
    -- Clean up legacy 'L_B.<PanelName>' rows from prior versions of this SP (file 19/25).
    DELETE FROM dbo.RT_ES_LIS_Panel WHERE RoleID LIKE 'L\_B.%' ESCAPE '\';

    INSERT INTO dbo.RT_ES_LIS_Panel (RoleID, PanelName, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt, SortOrder)
    SELECT 'L_A.' + pn.PanelName, pn.PanelName, '    ' + pn.PanelName,
           p.ESYear, p.ESMonth, COUNT(DISTINCT l.Accession), 0, GETDATE(), pn.PanelSortOrder
    FROM #LisPanels2 pn
    CROSS JOIN #LisPeriods2 p
    LEFT JOIN #Lis2 l
           ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
          AND l.ResultedNot = 'Resulted'
          AND l.PanelName = pn.PanelName
    GROUP BY pn.PanelName, pn.PanelSortOrder, p.ESYear, p.ESMonth;

    DROP TABLE IF EXISTS #Lis2;
    DROP TABLE IF EXISTS #LisPeriods2;
    DROP TABLE IF EXISTS #LisPanels2;

    PRINT 'usp_RefreshRT_ExecutiveSummary_LIS_Alt completed.';
END;
GO

PRINT '19_RisingTides_ExecutiveSummary_LIS_Alt.sql completed.';
GO

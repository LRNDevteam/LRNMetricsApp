/*
    Rising Tides Executive Summary - LIS Breakdown client remarks (2026-09-29)

    Based on the deployed dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt; only these rows change:
      L_A2   Not Entered in AMD        Client Status = Billing Review Required OR blank   (677 -> 681)
      L_A2c    Transferred  (new)      L_A2 + Sample Status = Transferred                 (3)
      L_A2d    Collected    (new)      L_A2 + Sample Status = Collected                   (1)
      L_A3   Unbilled                  + Claim Status = Entered                            (97 -> 89)
      L_B1b    Received                Sample Status = Received (was Collected), Client Status blank (52 -> 9)
      L_B3   Test Entries              Not Resulted, Client Status = Test Entries
                                       (replaces the Not Resulted "Client Bill" row, always 0)  (1)
    Also updates the matching LisDrillRowDef rows so Year / Grand Total drill-downs agree.

    Keeps the call to dbo.usp_RT_ES_RefreshDerivedRows (script 32) at the end, so Billed
    Mismatches / Average Payment Per Claim are recalculated after this refresh.
    Safe to run before or after script 32.
*/
CREATE OR ALTER PROCEDURE [dbo].[usp_RefreshRT_ExecutiveSummary_LIS_Alt]
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
               COUNT(l.Accession) AS SampleCount
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A  Billable Samples - Resulted  (SortOrder 200)
        SELECT p.ESYear, p.ESMonth, 'L_A', 'Billable Samples - Resulted', 200,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1  Billed to Insurance  (SortOrder 300)
        SELECT p.ESYear, p.ESMonth, 'L_A1', 'Billed to Insurance', 300,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A1a  Billed to Insurance - Billed In AMD  (SortOrder 301)
        SELECT p.ESYear, p.ESMonth, 'L_A1a', '  Billed In AMD', 301,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
              AND l.BilledNot = 'Billed'
        GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A2  Not Entered in AMD  (SortOrder 310)
        --SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD', 310,
        --       COUNT(l.OrderID)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        --      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
        --      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        --GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A2a  Not Entered in AMD - Received  (SortOrder 311)
        --SELECT p.ESYear, p.ESMonth, 'L_A2a', '    Received', 311,
        --       COUNT(l.Accession)
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
        --       COUNT(l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Billed'
        --      AND l.BilledNot = 'Billed' AND l.ClientStatus = 'Billing Review Required'
        --      AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        --      AND l.SampleStatus = 'Received'
        --GROUP BY p.ESYear, p.ESMonth

		UNION ALL
        -- L_A2  Not Entered in AMD  (SortOrder 310)
        -- Resulted, Payment Method = Insurance, Claim Status = Not Entered in AMD,
        -- Client Status = Billing Review Required or blank, Billing Status = Billed / Not Ready To Bill / Ready To Bill
        SELECT p.ESYear, p.ESMonth, 'L_A2', 'Not Entered in AMD', 310,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus IN ('Billing Review Required', '')
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2a  Not Entered in AMD - Received  (SortOrder 311)
        SELECT p.ESYear, p.ESMonth, 'L_A2a', '  Received', 311,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus IN ('Billing Review Required', '')
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2b  Not Entered in AMD - Billing Review Required  (identical to L_A2a per spec) (SortOrder 312)
        SELECT p.ESYear, p.ESMonth, 'L_A2b', '  Billing Review Required', 312,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus = 'Billing Review Required'
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              --AND l.SampleStatus = 'Received'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2c  Not Entered in AMD - Transferred  (SortOrder 313)
        SELECT p.ESYear, p.ESMonth, 'L_A2c', '  Transferred', 313,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus IN ('Billing Review Required', '')
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Transferred'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A2d  Not Entered in AMD - Collected  (SortOrder 314)
        SELECT p.ESYear, p.ESMonth, 'L_A2d', '  Collected', 314,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.ClientStatus IN ('Billing Review Required', '')
              AND l.BillingStatus IN ('Billed','Not Ready To Bill','Ready To Bill')
              AND l.SampleStatus = 'Collected'
        GROUP BY p.ESYear, p.ESMonth


        --UNION ALL
        ---- L_A3  Unbilled  (SortOrder 320)
        --SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled', 320,
        --       COUNT(l.OrderID)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Insurance' AND l.ClaimStatus = 'Entered'
        --      AND l.BilledNot = 'Unbilled'
        --GROUP BY p.ESYear, p.ESMonth

		   UNION ALL
        -- L_A3  Unbilled  (SortOrder 320)
        SELECT p.ESYear, p.ESMonth, 'L_A3', 'Unbilled', 320,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND (l.ClientStatus is NULL or ClientStatus='')
              AND l.BilledNot = 'Unbilled' AND l.ClaimStatus = 'Entered'
        GROUP BY p.ESYear, p.ESMonth


        --UNION ALL
        ---- L_A4  Client Bill  (SortOrder 330)
        --SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill', 330,
        --       COUNT(l.Accession)
        --FROM #LisPeriods2 p LEFT JOIN #Lis2 l
        --       ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
        --      AND l.ResultedNot = 'Resulted' AND l.PaymentMethod = 'Client Bill'
        --      AND l.ClaimStatus IN ('Billed','Not Entered in AMD')
        --      AND l.ClientStatus = 'Client Bill' AND l.BillingStatus = 'Billed'
        --GROUP BY p.ESYear, p.ESMonth

		UNION ALL
        -- L_A4  Client Bill  (SortOrder 330)
        SELECT p.ESYear, p.ESMonth, 'L_A4', 'Client Bill', 330,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClientStatus = 'Client Bill' 
			  AND l.BillingStatus in ('Billed','Ready to Bill')
        GROUP BY p.ESYear, p.ESMonth


        UNION ALL
        -- L_A4a  Client Bill - Not Entered in AMD  (SortOrder 331)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Client Bill, 
		--Billing Status = Billed, Ready to Bill, Claim Status = Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A4a', '  Not Entered in AMD', 331,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'  AND l.ClientStatus = 'Client Bill'   AND l.BillingStatus in ('Billed','Ready to Bill')
			  AND l.ClaimStatus = 'Not Entered in AMD' 
             
        GROUP BY p.ESYear, p.ESMonth

        --UNION ALL
        ---- L_A4b  Client Bill - Billed  (SortOrder 332)
        --SELECT p.ESYear, p.ESMonth, 'L_A4b', '    Billed', 332,
        --       COUNT(l.Accession)
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
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Client Bill, Billing Status NOT Equal to No BILL, Claim Status = Billed
        SELECT p.ESYear, p.ESMonth, 'L_A4b', '  Billed', 332,
               COUNT( l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
               AND l.ResultedNot = 'Resulted'  AND l.ClientStatus = 'Client Bill'   
			   AND l.BillingStatus <>'No Bill' and ClaimStatus='Billed'
			  
        GROUP BY p.ESYear, p.ESMonth
		
        UNION ALL
        -- L_A5  Self Pay  (SortOrder 340)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay, Billing Status NOT Equal to No BILL
        SELECT p.ESYear, p.ESMonth, 'L_A5', 'Self Pay', 340,
               COUNT(l.OrderID)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'   AND l.ClientStatus = 'Self Pay' and l.BillingStatus <>'No Bill'
			
			  --AND l.PaymentMethod = 'Self Pay'
              --AND l.ClientStatus = 'Self Pay'
              --AND l.BillingStatus IN ('Billed','Not Ready To Bill')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5a  Self Pay - Billed  (SortOrder 341)
        SELECT p.ESYear, p.ESMonth, 'L_A5a', '  Billed', 341,
               COUNT(l.Accession)
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
		----Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay, 
		--Billing Status NOT Equal to No BILL, Claim Status = Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A5b', '  Not Entered in AMD', 342,
               COUNT( l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted'   AND l.BillingStatus <>'No Bill' --AND l.PaymentMethod = 'Self Pay'
              AND l.ClaimStatus = 'Not Entered in AMD' --AND l.BilledNot = 'Unbilled'
              AND l.ClientStatus = 'Self Pay'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A5c  Self Pay - Entered  (SortOrder 343)
       -- L_A4a above — implemented without BillingStatus='Billed'.
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Self Pay,
		--Billing Status NOT Equal to No BILL, Claim Status = Entered

		
        SELECT p.ESYear, p.ESMonth, 'L_A5c', '  Entered', 343,
               COUNT(l.OrderID)
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
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND   l.BillingStatus <>'No Bill'
              AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A6a  Test Entries - Not Entered in AMD  (identical to L_A6 per spec) (SortOrder 351)
		--Count [Order ID] WHERE Resulted / Not = Resulted, Client Status = Test Entries,
		--Billing Status NOT Equal to No BILL, Claim Status = Not Entered in AMD
        SELECT p.ESYear, p.ESMonth, 'L_A6a', '  Not Entered in AMD', 351,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.BillingStatus <>'No Bill' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7  Billing Status - No Bill  (SortOrder 360)
        SELECT p.ESYear, p.ESMonth, 'L_A7', 'Billing Status - No Bill', 360,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7a  Billing Status - No Bill - Rejected  (SortOrder 361, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7a', '  Rejected', 361,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7b  Billing Status - No Bill - Completed  (SortOrder 362, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7b', '  Completed', 362,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Completed'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_A7c  Billing Status - No Bill - Recollect Required  (SortOrder 363, new sub-row)
        SELECT p.ESYear, p.ESMonth, 'L_A7c', '  Recollect Required', 363,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Resulted' AND l.BillingStatus = 'No Bill'
              AND l.OrderStatus = 'Recollect Required'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B  Not Resulted  (SortOrder 400 — immediately follows L_A7c/363)
        SELECT p.ESYear, p.ESMonth, 'L_B', 'Not Resulted', 400,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1  Not Resulted - Not Entered in AMD  (SortOrder 410)
		--Count [Order ID] WHERE Resulted / Not = Not Resulted, Claim Status = Not Entered in AMD, 
		--Client Status = Blank
        SELECT p.ESYear, p.ESMonth, 'L_B1', 'Not Entered in AMD', 410,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
			  and (ClientStatus is null or ClientStatus='')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1a  Not Entered in AMD - Collected  (SortOrder 411)
		--Count [Order ID] WHERE Resulted / Not = Not Resulted, Claim Status = Not Entered in AMD, 
		--Client Status = Blank, Sample Status = Collected

        SELECT p.ESYear, p.ESMonth, 'L_B1a', '  Collected', 411,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Collected'  and (ClientStatus is null or ClientStatus='')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B1b  Not Entered in AMD - Received  (SortOrder 412)
        SELECT p.ESYear, p.ESMonth, 'L_B1b', '  Received', 412,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Received' AND (l.ClientStatus IS NULL OR l.ClientStatus = '')
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B2  Not Resulted - Rejected Sample  (SortOrder 420)
        SELECT p.ESYear, p.ESMonth, 'L_B2', 'Rejected Sample', 420,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClaimStatus = 'Not Entered in AMD'
              AND l.SampleStatus = 'Rejected'
        GROUP BY p.ESYear, p.ESMonth

		
        UNION ALL
        -- L_B3  Not Resulted - Test Entries  (SortOrder 430)
        -- Count [Accession] WHERE ResultedNot = 'Not Resulted', ClientStatus = 'Test Entries'
        SELECT p.ESYear, p.ESMonth, 'L_B3', 'Test Entries', 430,
               COUNT(l.Accession)
        FROM #LisPeriods2 p LEFT JOIN #Lis2 l
               ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
              AND l.ResultedNot = 'Not Resulted' AND l.ClientStatus = 'Test Entries'
        GROUP BY p.ESYear, p.ESMonth

        UNION ALL
        -- L_B4  Not Resulted - Self Pay  (SortOrder 440)
        -- Count [Accession] WHERE ResultedNot = 'Not Resulted', ClientStatus = 'Self Pay'
        SELECT p.ESYear, p.ESMonth, 'L_B4', '  Self Pay', 440,
               COUNT(l.Accession)
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
    SELECT 'L_A.' + pn.PanelName, pn.PanelName, '  ' + pn.PanelName,
           p.ESYear, p.ESMonth, COUNT(l.Accession), 0, GETDATE(), pn.PanelSortOrder
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

    -- Billed Mismatches (P) + Average Payment Per Claim, after LIS/PMS/Cash.
    IF OBJECT_ID('dbo.usp_RT_ES_RefreshDerivedRows', 'P') IS NOT NULL
        EXEC dbo.usp_RT_ES_RefreshDerivedRows;
END;
GO

/* Drill-down definitions for the changed rows (Year / Grand Total links). */
DELETE FROM dbo.LisDrillRowDef
WHERE LabPrefix = N'RT' AND ISNULL(Source, N'LIS') = N'LIS'
  AND RowCode IN (N'L_A2', N'L_A3', N'L_B1b', N'L_B3');

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'RT', N'L_A2',  N'Not Entered in AMD', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD',
     N'ClientStatus',N'IN',N'__BLANK__,Billing Review Required', N'BillingStatus',N'IN',N'Billed,Not Ready To Bill,Ready To Bill'),
 (N'RT', N'L_A3',  N'Unbilled', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Entered',
     N'BilledorNot',N'=',N'UnBilled', N'ClientStatus',N'=',N''),
 (N'RT', N'L_B1b', N'Received', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Not Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD',
     N'SampleStatus',N'=',N'Received', N'ClientStatus',N'=',N''),
 (N'RT', N'L_B3',  N'Test Entries', N'RequestCollectDate', N'LIS',
     N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Test Entries',
     NULL,NULL,NULL, NULL,NULL,NULL);
GO

-- Rebuild the LIS rows now (also refreshes Billed Mismatches / Average Payment when script 32 is deployed).
EXEC dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt;
GO

-- Check: expected on current data L_A2 681, L_A2a 677, L_A2b 677, L_A2c 3, L_A2d 1, L_A3 89, L_B1b 9, L_B3 1
SELECT RoleID, Description, ESMonthClaimCount
FROM dbo.RT_ES_LIS
WHERE ESYear = 0 AND ESMonth = 0
ORDER BY SortOrder;
GO


-- ============================================================
-- RisingTides – Executive Summary Detail (Drill-Down) SP
-- File : 18_RisingTides_ExecutiveSummary_Detail.sql
-- DB   : Rising_Tides
--
-- Returns the individual ClaimLevelData rows that make up
-- a single cell in the Executive Summary grid.
--
-- Parameters
--   @Category  – 'PMS' | 'Cash' | 'LIS'
--   @RowCode   – e.g. 'O','W1','AD' (PMS/Cash) or 'A'..'I5'/'B.<PanelName>' (old LIS,
--                no longer populated) or 'L_A'..'L_N'/'L_B.<PanelName>' (current LIS scheme)
--   @Year      – calendar year  (0 = all years)
--   @Month     – calendar month (0 = all months within the year)
--
-- LIS rows are sourced from dbo.LIMSMaster using the same RoleID filter logic
-- as 16_RisingTides_ExecutiveSummary_Aggregate.sql's #Lis population. Display
-- columns (PatientName, PayerName, PanelName, ClinicName, BillingProvider) are
-- auto-detected from candidate column names since exact LIMSMaster column
-- names beyond Accession/RequestCollectDate/RessultedStatus/ClientStatus/
-- BillingStatus/OrderStatus are not confirmed. LIS has no dollar amounts, so
-- ChargeAmount/InsurancePayment/PatientPayment/InsuranceBalance/PatientBalance
-- are returned as 0.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_ExecutiveSummary_Detail
(
	@Category  NVARCHAR(20),
	@RowCode   NVARCHAR(350),
	@Year      INT = 0,
	@Month     INT = 0
)
AS
BEGIN
	SET NOCOUNT ON;

	-- Build the period filter clause in temp table form for reuse.
	DROP TABLE IF EXISTS #Base;

	SELECT
		LTRIM(RTRIM(ISNULL(ClaimID,             '')))  AS VisitNumber,
		LTRIM(RTRIM(ISNULL(PatientName,         '')))  AS PatientName,
		LTRIM(RTRIM(ISNULL(PayerName,           '')))  AS PayerName,
		LTRIM(RTRIM(ISNULL(Panelname,           '')))  AS PanelName,
		LTRIM(RTRIM(ISNULL(ClinicName,          '')))  AS ClinicName,
		LTRIM(RTRIM(ISNULL(BillingProvider,     '')))  AS BillingProvider,
		TRY_CAST(DateofService    AS DATE)             AS DateofService,
		TRY_CAST(FirstBilledDate  AS DATE)             AS FirstBilledDate,
		LTRIM(RTRIM(ISNULL(BilledUnbilled,      '')))  AS BilledUnbilled,
		LTRIM(RTRIM(ISNULL(ClaimStatus,         '')))  AS ClaimStatus,
		ISNULL(TRY_CAST(ChargeAmount           AS DECIMAL(18,2)), 0) AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment       AS DECIMAL(18,2)), 0) AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment         AS DECIMAL(18,2)), 0) AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceAdjustments   AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
		ISNULL(TRY_CAST(PatientAdjustments     AS DECIMAL(18,2)), 0) AS PatientAdjustments,
		ISNULL(TRY_CAST(InsuranceBalance       AS DECIMAL(18,2)), 0) AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance         AS DECIMAL(18,2)), 0) AS PatientBalance,
		YEAR (TRY_CAST(DateofService AS DATE))         AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE))         AS ESMonth
	INTO #Base
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
	  AND (@Year  = 0 OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
	  AND (@Month = 0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

	-- ── PMS category ─────────────────────────────────────────────────────
	IF @Category = 'PMS'
	BEGIN
		SELECT DISTINCT
			b.VisitNumber,
			b.PatientName,
			b.PayerName,
			b.PanelName,
			b.ClinicName,
			b.BillingProvider,
			b.DateofService,
			b.FirstBilledDate,
			b.BilledUnbilled,
			b.ClaimStatus,
			b.ChargeAmount,
			b.InsurancePayment,
			b.PatientPayment,
			b.InsuranceBalance,
			b.PatientBalance
		FROM #Base b
		WHERE
			-- O  – Billed
			(@RowCode = 'O'  AND b.BilledUnbilled = 'Billed')
		 OR -- P  – Billed Mismatches
			(@RowCode = 'P'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Unbilled')
		 OR -- Q  – Unbilled
			(@RowCode = 'Q'  AND b.BilledUnbilled = 'Unbilled')
		 OR -- R  – Paid Client
			(@RowCode = 'R'  AND b.ClaimStatus    = 'Client Paid')
		 OR -- S  – Fully Paid
			(@RowCode = 'S'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Fully Paid')
		 OR -- T  – Fully Adjusted
			(@RowCode = 'T'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Complete W/O')
		 OR -- U  – Patient Responsibility
			(@RowCode = 'U'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Patient Responsibility')
		 OR -- V  – Partially Paid
			(@RowCode = 'V'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Partially Paid')
		 OR -- X  – Patient Payment
			(@RowCode = 'X'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Patient Payment')
		 OR -- W  – Insurance Balance (parent)
			(@RowCode = 'W'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied'))
		 OR -- W1 – Fully Denied
			(@RowCode = 'W1' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Fully Denied')
		 OR -- W2 – No Response
			(@RowCode = 'W2' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'No Response')
		 OR -- W3 – Partially Denied
			(@RowCode = 'W3' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Partially Denied')
		ORDER BY b.DateofService, b.VisitNumber;
	END

	-- ── Cash category ─────────────────────────────────────────────────────
	ELSE IF @Category = 'Cash'
	BEGIN
		SELECT DISTINCT
			b.VisitNumber,
			b.PatientName,
			b.PayerName,
			b.PanelName,
			b.ClinicName,
			b.BillingProvider,
			b.DateofService,
			b.FirstBilledDate,
			b.BilledUnbilled,
			b.ClaimStatus,
			b.ChargeAmount,
			b.InsurancePayment,
			b.PatientPayment,
			b.InsuranceAdjustments,
			b.PatientAdjustments,
			b.InsuranceBalance,
			b.PatientBalance
		FROM #Base b
		WHERE
			-- X  – Total Billed ($)
			(@RowCode = 'X'   AND b.BilledUnbilled = 'Billed')
		 OR -- Y  – Unbilled ($)
			(@RowCode = 'Y'   AND b.BilledUnbilled = 'Unbilled')
		 OR -- Z  – Insurance Payment fully paid
			(@RowCode = 'Z'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Fully Paid')
		 OR -- AA – Partially Paid
			(@RowCode = 'AA'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Partially Paid')
		 OR -- AB – Patient Payment
			(@RowCode = 'AB'  AND b.BilledUnbilled = 'Billed')
		 OR -- AC – Fully Adjusted (Complete W/O)
			(@RowCode = 'AC'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Complete W/O')
		 OR -- AD – Contractual Obligation W/O
			(@RowCode = 'AD'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus <> 'Complete W/O')
		 OR -- AE – Patient Balance
			(@RowCode = 'AE'  AND b.BilledUnbilled = 'Billed')
		 OR -- AF – Patient W/O
			(@RowCode = 'AF'  AND b.BilledUnbilled = 'Billed')
		 OR -- AG – Insurance Balance (parent)
			(@RowCode = 'AG'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Denied'))
		 OR -- AG1 – No Response
			(@RowCode = 'AG1' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'No Response')
		 OR -- AG2 – Fully Denied
			(@RowCode = 'AG2' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Fully Denied')
		 OR -- AG3 – Partially Denied
			(@RowCode = 'AG3' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Partially Denied')
		ORDER BY b.DateofService, b.VisitNumber;
	END

	-- ── LIS category ─────────────────────────────────────────────────────
	ELSE IF @Category = 'LIS'
	BEGIN
		IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
		BEGIN
			-- Auto-detect display columns on dbo.LIMSMaster (names not confirmed).
			DECLARE @PatientCol  SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('PatientName','Patient_Name','Patient') ORDER BY CASE name WHEN 'PatientName' THEN 1 WHEN 'Patient_Name' THEN 2 ELSE 3 END);
			DECLARE @PayerCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('PayerName','InsuranceName','Payer','PrimaryPayer','InsurancePayer') ORDER BY CASE name WHEN 'PayerName' THEN 1 WHEN 'InsuranceName' THEN 2 WHEN 'Payer' THEN 3 WHEN 'PrimaryPayer' THEN 4 ELSE 5 END);
			DECLARE @ClinicCol   SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('ClinicName','Clinic','FacilityName','Facility') ORDER BY CASE name WHEN 'ClinicName' THEN 1 WHEN 'Clinic' THEN 2 WHEN 'FacilityName' THEN 3 ELSE 4 END);
			DECLARE @ProviderCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('BillingProvider','Provider','OrderingProvider','RenderingProvider') ORDER BY CASE name WHEN 'BillingProvider' THEN 1 WHEN 'Provider' THEN 2 WHEN 'OrderingProvider' THEN 3 ELSE 4 END);
			DECLARE @PanelCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname') ORDER BY CASE name WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2 WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5 WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 ELSE 9 END);

			DECLARE @PatientExpr  NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol  + N']), '''')))', '''''');
			DECLARE @PayerExpr    NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol    + N']), '''')))', '''''');
			DECLARE @ClinicExpr   NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol   + N']), '''')))', '''''');
			DECLARE @ProviderExpr NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), '''')))', '''''');
			DECLARE @PanelExpr    NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol    + N']), '''')))', '''''');

			DROP TABLE IF EXISTS #LisBase;

			-- Real temp table created in this scope so it stays visible after the
			-- sp_executesql call below (tables created via SELECT...INTO inside
			-- sp_executesql are scoped to the dynamic batch and would disappear).
			CREATE TABLE #LisBase
			(
				VisitNumber      NVARCHAR(100)  NOT NULL,
				PatientName      NVARCHAR(300)  NOT NULL,
				PayerName        NVARCHAR(300)  NOT NULL,
				PanelName        NVARCHAR(300)  NOT NULL,
				ClinicName       NVARCHAR(300)  NOT NULL,
				BillingProvider  NVARCHAR(300)  NOT NULL,
				DateofService    DATE           NULL,
				FirstBilledDate  DATE           NULL,
				BilledUnbilled   NVARCHAR(20)   NOT NULL,
				ClaimStatus      NVARCHAR(100)  NOT NULL,
				ChargeAmount     DECIMAL(18,2)  NOT NULL,
				InsurancePayment DECIMAL(18,2)  NOT NULL,
				PatientPayment   DECIMAL(18,2)  NOT NULL,
				InsuranceBalance DECIMAL(18,2)  NOT NULL,
				PatientBalance   DECIMAL(18,2)  NOT NULL,
				ResultedNot      NVARCHAR(50)   NOT NULL,
				LisClientStatus  NVARCHAR(100)  NOT NULL,
				LisOrderStatus   NVARCHAR(100)  NOT NULL,
				ESYear           INT            NOT NULL,
				ESMonth          INT            NOT NULL
			);

			DECLARE @LisSql NVARCHAR(MAX) = N'
				INSERT INTO #LisBase
					(VisitNumber, PatientName, PayerName, PanelName, ClinicName, BillingProvider,
					 DateofService, FirstBilledDate, BilledUnbilled, ClaimStatus,
					 ChargeAmount, InsurancePayment, PatientPayment, InsuranceBalance, PatientBalance,
					 ResultedNot, LisClientStatus, LisOrderStatus, ESYear, ESMonth)
				SELECT
					LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), Accession), ''''))),
					' + @PatientExpr  + N',
					' + @PayerExpr    + N',
					' + @PanelExpr    + N',
					' + @ClinicExpr   + N',
					' + @ProviderExpr + N',
					TRY_CAST(RequestCollectDate AS DATE),
					TRY_CAST(RequestCollectDate AS DATE),
					CASE WHEN LTRIM(RTRIM(ISNULL(BillingStatus,''''))) = ''Billed'' THEN ''Billed'' ELSE ''Unbilled'' END,
					LTRIM(RTRIM(ISNULL(BillingStatus,''''))),
					0, 0, 0, 0, 0,
					LTRIM(RTRIM(ISNULL(RessultedStatus,''''))),
					LTRIM(RTRIM(ISNULL(ClientStatus,''''))),
					LTRIM(RTRIM(ISNULL(OrderStatus,''''))),
					YEAR (TRY_CAST(RequestCollectDate AS DATE)),
					MONTH(TRY_CAST(RequestCollectDate AS DATE))
				FROM dbo.LIMSMaster
				WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
				  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '''') IS NOT NULL
				  AND (@iYear  = 0 OR YEAR (TRY_CAST(RequestCollectDate AS DATE)) = @iYear)
				  AND (@iMonth = 0 OR MONTH(TRY_CAST(RequestCollectDate AS DATE)) = @iMonth);';

			EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear = @Year, @iMonth = @Month;

			-- 'B.<PanelName>' RowCodes drill into the panel sub-rows of 'B' (Resulted).
			DECLARE @PanelFilter NVARCHAR(300) = NULL;
			IF @RowCode LIKE 'B.%'
				SET @PanelFilter = SUBSTRING(@RowCode, 3, 300);

			-- 'L_B.<PanelName>' RowCodes drill into the panel sub-rows of 'L_B' (Resulted),
			-- current LIS scheme (mirrors usp_RefreshRT_ExecutiveSummary_LIS_Alt).
			DECLARE @LisPanelFilter NVARCHAR(300) = NULL;
			IF @RowCode LIKE 'L\_B.%' ESCAPE '\'
				SET @LisPanelFilter = SUBSTRING(@RowCode, 5, 300);

			SELECT DISTINCT
				b.VisitNumber,
				b.PatientName,
				b.PayerName,
				b.PanelName,
				b.ClinicName,
				b.BillingProvider,
				b.DateofService,
				b.FirstBilledDate,
				b.BilledUnbilled,
				b.ClaimStatus,
				b.ChargeAmount,
				b.InsurancePayment,
				b.PatientPayment,
				b.InsuranceBalance,
				b.PatientBalance
			FROM #LisBase b
			WHERE
				-- A  Total Samples
				(@RowCode = 'A')
			 OR -- B  Resulted
				(@RowCode = 'B'  AND b.ResultedNot = 'Resulted')
			 OR -- B.<PanelName>  Resulted, by panel
				(@PanelFilter IS NOT NULL AND b.ResultedNot = 'Resulted' AND b.PanelName COLLATE DATABASE_DEFAULT = @PanelFilter COLLATE DATABASE_DEFAULT)
			 OR -- C  Billed
				(@RowCode = 'C'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = '' AND b.BilledUnbilled = 'Billed')
			 OR -- D  Client Bill
				(@RowCode = 'D'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill')
			 OR -- D1  Client Bill - Billed
				(@RowCode = 'D1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.BilledUnbilled = 'Billed')
			 OR -- D2  Client Bill - Not Entered in AMD
				(@RowCode = 'D2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
			 OR -- D3  Client Bill - Entered
				(@RowCode = 'D3' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Entered')
			 OR -- E  Not Entered in AMD
				(@RowCode = 'E'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('Billing Review Required','') AND b.ClaimStatus = 'Not Entered in AMD')
			 OR -- E1  Completed
				(@RowCode = 'E1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('Billing Review Required','') AND b.ClaimStatus = 'Not Entered in AMD' AND b.LisOrderStatus = 'Completed')
			 OR -- E2  Billing Review Required
				(@RowCode = 'E2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Billing Review Required' AND b.ClaimStatus = 'Not Entered in AMD')
			 OR -- E3  In Transit
				(@RowCode = 'E3' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('Billing Review Required','') AND b.ClaimStatus = 'Not Entered in AMD' AND b.LisOrderStatus = 'In Transit')
			 OR -- F  Unbilled - Not Released to Payer (EDI Hold)
				(@RowCode = 'F'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = '' AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Entered' AND b.LisOrderStatus = 'Completed')
			 OR -- G  Test Entries
				(@RowCode = 'G'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Test Entries')
			 OR -- G1  Test Entries - Not Entered in AMD
				(@RowCode = 'G1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Test Entries' AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
			 OR -- H  Rejected Sample
				(@RowCode = 'H'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Rejected Sample')
			 OR -- H1  Rejected Sample - Not Entered in AMD
				(@RowCode = 'H1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Rejected Sample' AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
			 OR -- I  Not Resulted
				(@RowCode = 'I'  AND b.ResultedNot = 'Not Resulted')
			 OR -- I1  Not Resulted - Not Entered in AMD
				(@RowCode = 'I1' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = '' AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
			 OR -- I2  Not Resulted - Client Bill
				(@RowCode = 'I2' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Client Bill')
			 OR -- I3  Not Resulted - Test Entries
				(@RowCode = 'I3' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Test Entries')
			 OR -- I4  Not Resulted - Rejected Sample
				(@RowCode = 'I4' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Rejected Sample')
			 OR -- I5  Not Resulted - Self Pay
				(@RowCode = 'I5' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Self Pay')

			-- ── Current LIS scheme (RoleIDs 'L_A'..'L_N') ──────────────────────
			-- Mirrors dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt
			-- (19_RisingTides_ExecutiveSummary_LIS_Alt.sql) row-for-row.
			 OR -- L_A  Total Samples
				(@RowCode = 'L_A')
			 OR -- L_B  Billable Samples - Resulted
				(@RowCode = 'L_B' AND b.ResultedNot = 'Resulted')
			 OR -- L_C  Billed to Insurance
				(@RowCode = 'L_C' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = '' AND b.BilledUnbilled = 'Billed')
			 OR -- L_D  Not Entered in AMD (REVISED: ClientStatus '' or 'Billing Review
				-- Required' AND Unbilled; 'Not Entered in AMD'/'Entered' are not real
				-- BillingStatus values, so the old ClaimStatus check is dropped)
				(@RowCode = 'L_D' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('','Billing Review Required') AND b.BilledUnbilled = 'Unbilled')
			 OR -- L_D1  Received (REVISED: D-rows where OrderStatus = 'Completed')
				(@RowCode = 'L_D1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('','Billing Review Required') AND b.BilledUnbilled = 'Unbilled' AND b.LisOrderStatus = 'Completed')
			 OR -- L_D2  Billing Review Required (REVISED: D-rows where OrderStatus <> 'Completed'; D1+D2=D)
				(@RowCode = 'L_D2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('','Billing Review Required') AND b.BilledUnbilled = 'Unbilled' AND b.LisOrderStatus <> 'Completed')
			 OR -- L_E  Unbilled - Not released to Payer (EDI Hold) (REVISED: dropped dead ClaimStatus/OrderStatus checks)
				(@RowCode = 'L_E' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = '' AND b.BilledUnbilled = 'Unbilled')
			 OR -- L_F  Client Bill
				(@RowCode = 'L_F' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill')
			 OR -- L_F1  Client Bill - Not Entered in AMD (REVISED: dropped dead ClaimStatus check)
				(@RowCode = 'L_F1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.BilledUnbilled = 'Unbilled')
			 OR -- L_F2  Client Bill - Billed
				(@RowCode = 'L_F2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.BilledUnbilled = 'Billed')
			 OR -- L_G  Self Pay (confirmed: ClientStatus = 'Self Pay')
				(@RowCode = 'L_G' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Self Pay')
			 OR -- L_G1  Self Pay - Billed
				(@RowCode = 'L_G1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Self Pay' AND b.BilledUnbilled = 'Billed')
			 OR -- L_G2  Self Pay - Not Entered in AMD (REVISED: Unbilled + OrderStatus='Completed'; G2+G3=unbilled-G)
				(@RowCode = 'L_G2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Self Pay' AND b.BilledUnbilled = 'Unbilled' AND b.LisOrderStatus = 'Completed')
			 OR -- L_G3  Entered (REVISED: Unbilled + OrderStatus <> 'Completed')
				(@RowCode = 'L_G3' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Self Pay' AND b.BilledUnbilled = 'Unbilled' AND b.LisOrderStatus <> 'Completed')
			 OR -- L_H  Test Entries
				(@RowCode = 'L_H' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Test Entries')
			 OR -- L_H1  Test Entries - Not Entered in AMD (REVISED: dropped dead ClaimStatus check)
				(@RowCode = 'L_H1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Test Entries' AND b.BilledUnbilled = 'Unbilled')
			 OR -- L_J  Billing Status No Bill (confirmed: raw BillingStatus = 'No Bill')
				(@RowCode = 'L_J' AND b.ResultedNot = 'Resulted' AND b.ClaimStatus = 'No Bill')
			 OR -- L_K  Not Resulted
				(@RowCode = 'L_K' AND b.ResultedNot = 'Not Resulted')
			 OR -- L_L  Not Resulted - Not Entered in AMD (REVISED: dropped dead ClaimStatus check)
				(@RowCode = 'L_L' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = '' AND b.BilledUnbilled = 'Unbilled')
			 OR -- L_L1  Not Resulted - Collected (REVISED: real OrderStatus value is 'Sample(s) Collected')
				(@RowCode = 'L_L1' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = '' AND b.BilledUnbilled = 'Unbilled' AND b.LisOrderStatus = 'Sample(s) Collected')
			 OR -- L_M  Not Resulted - Client Bill
				(@RowCode = 'L_M' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Client Bill')
			 OR -- L_N  Not Resulted - Rejected Sample
				(@RowCode = 'L_N' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Rejected Sample')
			 OR -- L_B.<PanelName>  Resulted, by panel (current LIS scheme)
				(@LisPanelFilter IS NOT NULL AND b.ResultedNot = 'Resulted' AND b.PanelName COLLATE DATABASE_DEFAULT = @LisPanelFilter COLLATE DATABASE_DEFAULT)
			ORDER BY b.DateofService, b.VisitNumber;

			DROP TABLE IF EXISTS #LisBase;
		END
	END

	DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '18_RisingTides_ExecutiveSummary_Detail.sql completed.';
GO


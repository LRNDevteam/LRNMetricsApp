-- ============================================================
-- PCRLabsofAmerica – Executive Summary Detail Page: LIS Breakdown row-level data
-- File : 20_PCRLOA_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : PCRLabsofAmerica
--
-- Generic-named counterpart of RisingTides'
-- 22_RisingTides_ExecutiveSummaryDetailRows_LIS.sql. The Executive
-- Summary "Detail" page (LabMetricsDashboard.ExecutiveSummaryController.Detail)
-- calls dbo.usp_GetExecutiveSummaryDetail_LIS for ANY lab whose clicked cell
-- is in the 'LIS' category — this SP must therefore exist (with this exact,
-- non-prefixed name) inside the PCRLabsofAmerica database too.
--
-- Returns the LIMSMaster row(s) behind a clicked "LIS Breakdown" count on
-- the Executive Summary grid. RoleID filter logic mirrors the #Lis population
-- in 16_PCRLOA_ExecutiveSummary_Aggregate.sql (A..I5, plus 'B.<PanelName>'
-- sub-row drill-down added by 19_PCRLOA_ExecutiveSummary_LIS_Alt.sql).
--
-- Parameters
--   @RowCode  – 'A'..'I5' or 'B.<PanelName>'
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months within the year)
--
-- Period filter is based on RequestCollectDate, same as the existing
-- LIS detail/aggregate procs. Display columns (PatientName, PayerName,
-- PanelName, ClinicName, BillingProvider) are auto-detected from candidate
-- column names since LIMSMaster's confirmed columns are limited; OrderStatus
-- is auto-detected too and falls back to '' if absent.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LIS
(
	@RowCode  NVARCHAR(350),
	@Year     INT = 0,
	@Month    INT = 0
)
AS
BEGIN
	SET NOCOUNT ON;

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
	BEGIN
		SELECT TOP (0)
			CAST(NULL AS NVARCHAR(100))  AS VisitNumber,
			CAST(NULL AS NVARCHAR(300)) AS PatientName,
			CAST(NULL AS NVARCHAR(300)) AS PayerName,
			CAST(NULL AS NVARCHAR(300)) AS PanelName,
			CAST(NULL AS NVARCHAR(300)) AS ClinicName,
			CAST(NULL AS NVARCHAR(300)) AS BillingProvider,
			CAST(NULL AS DATE)         AS DateofService,
			CAST(NULL AS DATE)         AS FirstBilledDate,
			CAST(NULL AS NVARCHAR(20)) AS BilledUnbilled,
			CAST(NULL AS NVARCHAR(100)) AS ClaimStatus,
			CAST(NULL AS DECIMAL(18,2)) AS ChargeAmount,
			CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment,
			CAST(NULL AS DECIMAL(18,2)) AS PatientPayment,
			CAST(NULL AS DECIMAL(18,2)) AS InsuranceBalance,
			CAST(NULL AS DECIMAL(18,2)) AS PatientBalance
		WHERE 1 = 0;
		RETURN;
	END

	-- Auto-detect optional display columns on dbo.LIMSMaster (only
	-- RequestCollectDate/InsuranceCategory/BilledorNot/RessultedStatus/
	-- ClaimStatus/ClientStatus/Accession/SourceFile/CreatedOn confirmed;
	-- OrderStatus referenced by the LIS layout image but not confirmed,
	-- so it is auto-detected and falls back to '' if absent).
	DECLARE @PatientCol     SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('PatientName','Patient_Name','Patient') ORDER BY CASE name WHEN 'PatientName' THEN 1 WHEN 'Patient_Name' THEN 2 ELSE 3 END);
	DECLARE @PayerCol       SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('PayerName','InsuranceName','Payer','PrimaryPayer','InsurancePayer','InsuranceCategory') ORDER BY CASE name WHEN 'PayerName' THEN 1 WHEN 'InsuranceName' THEN 2 WHEN 'Payer' THEN 3 WHEN 'PrimaryPayer' THEN 4 WHEN 'InsurancePayer' THEN 5 ELSE 6 END);
	DECLARE @ClinicCol      SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('ClinicName','Clinic','FacilityName','Facility') ORDER BY CASE name WHEN 'ClinicName' THEN 1 WHEN 'Clinic' THEN 2 WHEN 'FacilityName' THEN 3 ELSE 4 END);
	DECLARE @ProviderCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('BillingProvider','Provider','OrderingProvider','RenderingProvider') ORDER BY CASE name WHEN 'BillingProvider' THEN 1 WHEN 'Provider' THEN 2 WHEN 'OrderingProvider' THEN 3 ELSE 4 END);
	DECLARE @PanelCol       SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname') ORDER BY CASE name WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2 WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5 WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 ELSE 9 END);
	DECLARE @OrderStatusCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'OrderStatus');

	DECLARE @PatientExpr     NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol     + N']), '''')))', '''''');
	DECLARE @PayerExpr       NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol       + N']), '''')))', '''''');
	DECLARE @ClinicExpr      NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol      + N']), '''')))', '''''');
	DECLARE @ProviderExpr    NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol    + N']), '''')))', '''''');
	DECLARE @PanelExpr       NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol       + N']), '''')))', '''''');
	DECLARE @OrderStatusExpr NVARCHAR(400) = ISNULL('LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @OrderStatusCol + N']), '''')))', '''''');

	DROP TABLE IF EXISTS #LisBase;

	-- Real temp table created in this scope so it stays visible after the
	-- sp_executesql call below (SELECT...INTO inside sp_executesql would be
	-- dropped on return).
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
			' + @PatientExpr     + N',
			' + @PayerExpr       + N',
			' + @PanelExpr       + N',
			' + @ClinicExpr      + N',
			' + @ProviderExpr    + N',
			TRY_CAST(RequestCollectDate AS DATE),
			TRY_CAST(RequestCollectDate AS DATE),
			LTRIM(RTRIM(ISNULL(BilledorNot,''''))),
			LTRIM(RTRIM(ISNULL(ClaimStatus,''''))),
			0, 0, 0, 0, 0,
			LTRIM(RTRIM(ISNULL(RessultedStatus,''''))),
			LTRIM(RTRIM(ISNULL(ClientStatus,''''))),
			' + @OrderStatusExpr + N',
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
		(@RowCode = 'I'  AND b.ResultedNot <> 'Resulted')
	 OR -- I1  Not Resulted - Not Entered in AMD
		(@RowCode = 'I1' AND b.ResultedNot <> 'Resulted' AND b.LisClientStatus = '' AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
	 OR -- I2  Not Resulted - Client Bill
		(@RowCode = 'I2' AND b.ResultedNot <> 'Resulted' AND b.LisClientStatus = 'Client Bill')
	 OR -- I3  Not Resulted - Test Entries
		(@RowCode = 'I3' AND b.ResultedNot <> 'Resulted' AND b.LisClientStatus = 'Test Entries')
	 OR -- I4  Not Resulted - Rejected Sample
		(@RowCode = 'I4' AND b.ResultedNot <> 'Resulted' AND b.LisClientStatus = 'Rejected Sample')
	 OR -- I5  Not Resulted - Self Pay
		(@RowCode = 'I5' AND b.ResultedNot <> 'Resulted' AND b.LisClientStatus = 'Self Pay')
	 OR -- Fallback: unrecognized RowCode -> return everything in the period
		(@RowCode NOT IN ('A','B','C','D','D1','D2','D3','E','E1','E2','E3','F','G','G1','H','H1','I','I1','I2','I3','I4','I5')
		 AND @PanelFilter IS NULL)
	ORDER BY b.DateofService, b.VisitNumber;

	DROP TABLE IF EXISTS #LisBase;
END;
GO

PRINT '20_PCRLOA_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO

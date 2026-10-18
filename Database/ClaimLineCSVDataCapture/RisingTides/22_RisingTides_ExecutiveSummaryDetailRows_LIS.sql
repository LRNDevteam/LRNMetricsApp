-- ============================================================
-- RisingTides – Executive Summary Detail Page: LIS Breakdown row-level data
-- File : 22_RisingTides_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : Rising_Tides
--
-- Returns the full LIMSMaster row(s) behind a clicked "LIS Breakdown"
-- count on the Executive Summary grid. Column list and filter logic
-- mirror the LIS branch of dbo.usp_GetRT_ExecutiveSummary_Detail
-- (18_RisingTides_ExecutiveSummary_Detail.sql) and
-- dbo.usp_RefreshRT_ExecutiveSummary_LIS_Alt
-- (19_RisingTides_ExecutiveSummary_LIS_Alt.sql), but selects the full
-- set of LIMSMaster columns requested for the Detail page grid/Excel
-- export instead of the narrow 15-column shared shape.
--
-- Parameters
--   @RowCode  – e.g. 'A','B','L_A'..'L_N','B.<PanelName>','L_B.<PanelName>'
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months within the year)
--
-- Period filter is based on RequestCollectDate, same as the existing
-- LIS detail/aggregate procs.
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
		SELECT TOP (0) CAST(NULL AS NVARCHAR(1)) AS OrderID WHERE 1 = 0;
		RETURN;
	END

	DROP TABLE IF EXISTS #LisBase;

	-- All LIMSMaster columns requested for the Detail page, plus the
	-- derived classification columns used for RowCode filtering.
	SELECT
		OrderID, Accession, PaymentMethod, Barcode, Specimen, Collector,
		OrderStatus, BillingStatus, SampleStatus,
		RequestSubmittedDate, RequestCollectDate, ReqReceivedDate, ReqReportedDate,
		RessultedStatus, ClientStatus, TimetoResult, TurnaroundTime, Facility,
		[Performing Laboratory], 
		PatientFirstName, PatientLastName, PatientDateOfBirth, VisitNumber,
		AMDDOE, AMDLBD, TimetoBill, ClaimStatus, BilledorNot, Provider,
		PrimaryInsurance, PrimaryInsuranceID, ICD10Codes, Tests, PanelCategory,
		LTRIM(RTRIM(ISNULL(RessultedStatus, ''))) AS ResultedNot,
		LTRIM(RTRIM(ISNULL(ClientStatus,    ''))) AS LisClientStatus,
		LTRIM(RTRIM(ISNULL(OrderStatus,     ''))) AS LisOrderStatus,
		CASE WHEN LTRIM(RTRIM(ISNULL(BillingStatus,''))) = 'Billed' THEN 'Billed'
		ELSE 'Unbilled' END AS DerivedBilledUnbilled, 
		LTRIM(RTRIM(ISNULL(PanelCategory, ''))) AS DerivedPanelName,
		TRY_CAST(RequestCollectDate AS DATE) AS ESDate,Results
	INTO #LisBase
	FROM dbo.LIMSMaster
	WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
	  AND (@Year  = 0 OR YEAR (TRY_CAST(RequestCollectDate AS DATE)) = @Year)
	  AND (@Month = 0 OR MONTH(TRY_CAST(RequestCollectDate AS DATE)) = @Month);

	-- 'B.<PanelName>' RowCodes drill into the panel sub-rows of 'B' (Resulted) — old scheme.
	DECLARE @PanelFilter NVARCHAR(300) = NULL;
	IF @RowCode LIKE 'B.%'
		SET @PanelFilter = SUBSTRING(@RowCode, 3, 300);

	-- 'L_B.<PanelName>' RowCodes drill into the panel sub-rows of 'L_B' (Resulted) — current scheme.
	DECLARE @LisPanelFilter NVARCHAR(300) = NULL;
	IF @RowCode LIKE 'L\_B.%' ESCAPE '\'
		SET @LisPanelFilter = SUBSTRING(@RowCode, 5, 300);

	SELECT DISTINCT
		b.OrderID, b.Accession, b.PaymentMethod, b.Barcode, b.Specimen, b.Collector,
		b.OrderStatus, b.BillingStatus, b.SampleStatus,
		b.RequestSubmittedDate, b.RequestCollectDate, b.ReqReceivedDate, b.ReqReportedDate,
		b.RessultedStatus, b.ClientStatus, b.TimetoResult, b.TurnaroundTime, b.Facility,
		b.[Performing Laboratory], b.Results,
		b.PatientFirstName, b.PatientLastName, b.PatientDateOfBirth, b.VisitNumber,
		b.AMDDOE, b.AMDLBD, b.TimetoBill, b.ClaimStatus, b.BilledorNot, b.Provider,
		b.PrimaryInsurance, b.PrimaryInsuranceID, b.ICD10Codes, b.Tests, b.PanelCategory
	FROM #LisBase b
	WHERE
		-- ── Old LIS scheme (RoleIDs 'A'..'I5', no longer populated but kept for safety) ──
		(@RowCode = 'A')
	 OR (@RowCode = 'B'  AND b.ResultedNot = 'Resulted')
	 OR (@PanelFilter IS NOT NULL AND b.ResultedNot = 'Resulted' AND b.DerivedPanelName COLLATE DATABASE_DEFAULT = @PanelFilter COLLATE DATABASE_DEFAULT)
	 OR (@RowCode = 'C'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = '' AND b.DerivedBilledUnbilled = 'Billed')
	 OR (@RowCode = 'D'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill')
	 OR (@RowCode = 'D1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.DerivedBilledUnbilled = 'Billed')
	 OR (@RowCode = 'D2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
	 OR (@RowCode = 'D3' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Entered')
	 OR (@RowCode = 'E'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('Billing Review Required','') AND b.ClaimStatus = 'Not Entered in AMD')
	 OR (@RowCode = 'E1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('Billing Review Required','') AND b.ClaimStatus = 'Not Entered in AMD' AND b.LisOrderStatus = 'Completed')
	 OR (@RowCode = 'E2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Billing Review Required' AND b.ClaimStatus = 'Not Entered in AMD')
	 OR (@RowCode = 'E3' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('Billing Review Required','') AND b.ClaimStatus = 'Not Entered in AMD' AND b.LisOrderStatus = 'In Transit')
	 OR (@RowCode = 'F'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = '' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Entered' AND b.LisOrderStatus = 'Completed')
	 OR (@RowCode = 'G'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Test Entries')
	 OR (@RowCode = 'G1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Test Entries' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
	 OR (@RowCode = 'H'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Rejected Sample')
	 OR (@RowCode = 'H1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Rejected Sample' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
	 OR (@RowCode = 'I'  AND b.ResultedNot = 'Not Resulted')
	 OR (@RowCode = 'I1' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = '' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Not Entered in AMD')
	 OR (@RowCode = 'I2' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Client Bill')
	 OR (@RowCode = 'I3' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Test Entries')
	 OR (@RowCode = 'I4' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Rejected Sample')
	 OR (@RowCode = 'I5' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Self Pay')

	-- ── Current LIS scheme (RoleIDs 'L_A'..'L_N') ──────────────────────
	 OR (@RowCode = 'L_A')
	 OR (@RowCode = 'L_B'  AND b.ResultedNot = 'Resulted')
	 OR (@RowCode = 'L_C'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = '' AND b.DerivedBilledUnbilled = 'Billed')
	 OR (@RowCode = 'L_D'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('','Billing Review Required') AND b.DerivedBilledUnbilled = 'Unbilled')
	 OR (@RowCode = 'L_D1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('','Billing Review Required') AND b.DerivedBilledUnbilled = 'Unbilled' AND b.LisOrderStatus = 'Completed')
	 OR (@RowCode = 'L_D2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus IN ('','Billing Review Required') AND b.DerivedBilledUnbilled = 'Unbilled' AND b.LisOrderStatus <> 'Completed')
	 OR (@RowCode = 'L_E'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = '' AND b.DerivedBilledUnbilled = 'Unbilled')
	 OR (@RowCode = 'L_F'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill')
	 OR (@RowCode = 'L_F1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.DerivedBilledUnbilled = 'Unbilled')
	 OR (@RowCode = 'L_F2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Client Bill' AND b.DerivedBilledUnbilled = 'Billed')
	 OR (@RowCode = 'L_G'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Self Pay')
	 OR (@RowCode = 'L_G1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Self Pay' AND b.DerivedBilledUnbilled = 'Billed')
	 OR (@RowCode = 'L_G2' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Self Pay' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.LisOrderStatus = 'Completed')
	 OR (@RowCode = 'L_G3' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Self Pay' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.LisOrderStatus <> 'Completed')
	 OR (@RowCode = 'L_H'  AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Test Entries')
	 OR (@RowCode = 'L_H1' AND b.ResultedNot = 'Resulted' AND b.LisClientStatus = 'Test Entries' AND b.DerivedBilledUnbilled = 'Unbilled')
	 OR (@RowCode = 'L_J'  AND b.ResultedNot = 'Resulted' AND b.ClaimStatus = 'No Bill')
	 OR (@RowCode = 'L_K'  AND b.ResultedNot = 'Not Resulted')
	 OR (@RowCode = 'L_L'  AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = '' AND b.DerivedBilledUnbilled = 'Unbilled')
	 OR (@RowCode = 'L_L1' AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = '' AND b.DerivedBilledUnbilled = 'Unbilled' AND b.LisOrderStatus = 'Sample(s) Collected')
	 OR (@RowCode = 'L_M'  AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Client Bill')
	 OR (@RowCode = 'L_N'  AND b.ResultedNot = 'Not Resulted' AND b.LisClientStatus = 'Rejected Sample')
	 OR (@LisPanelFilter IS NOT NULL AND b.ResultedNot = 'Resulted' AND b.DerivedPanelName COLLATE DATABASE_DEFAULT = @LisPanelFilter COLLATE DATABASE_DEFAULT)

	-- Fallback: unrecognized RowCode -> return everything in the period
	-- so the Detail page never silently shows zero rows for a non-zero count.
	 OR (@RowCode NOT IN (
			'A','B','C','D','D1','D2','D3','E','E1','E2','E3','F','G','G1','H','H1',
			'I','I1','I2','I3','I4','I5',
			'L_A','L_B','L_C','L_D','L_D1','L_D2','L_E','L_F','L_F1','L_F2',
			'L_G','L_G1','L_G2','L_G3','L_H','L_H1','L_J','L_K','L_L','L_L1','L_M','L_N')
		AND @PanelFilter IS NULL AND @LisPanelFilter IS NULL)
	ORDER BY b.RequestCollectDate, b.Accession;

	DROP TABLE IF EXISTS #LisBase;
END;
GO

PRINT '22_RisingTides_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO

-- ============================================================
-- RisingTides – Executive Summary Detail Page: "2. PMS Breakdown" →
--               "Paid - Client" (RowCode 'R') row-level data
-- File : 24_RisingTides_ExecutiveSummaryDetailRows_ClientPaidList.sql
-- DB   : Rising_Tides
-- RisingTides ONLY — dbo.ClientPaidListData is populated from the
-- RisingTides-only "ClientPaidList" master workbook
-- (20/21_RisingTides_ClientPaidList_*.sql).
--
-- The Executive Summary grid's "2. PMS Breakdown" → "Paid - Client"
-- (RowCode 'R') cell is normally a COUNT(DISTINCT ClaimID) from
-- dbo.ClaimLevelData WHERE ClaimStatus = 'Client Paid'
-- (16_RisingTides_ExecutiveSummary_Aggregate.sql). For RisingTides,
-- clicking that count should instead show the row-level
-- dbo.ClientPaidListData rows (the dedicated "Master" Paid-Client
-- list), not the ClaimLevelData rows.
--
-- Parameters
--   @Year  – calendar year  (0 = all years)
--   @Month – calendar month (0 = all months within the year)
--
-- Period filter is based on BeginDOS (begin date of service), mirroring
-- how ClaimLevelData's DateofService drives ESYear/ESMonth elsewhere.
-- BeginDOS is stored as NVARCHAR, so TRY_CAST is used; rows with an
-- unparsable/blank BeginDOS are included only when @Year = 0 (all years).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_ClientPaidList
(
	@Year  INT = 0,
	@Month INT = 0
)
AS
BEGIN
	SET NOCOUNT ON;

	IF OBJECT_ID('dbo.ClientPaidListData', 'U') IS NULL
	BEGIN
		SELECT TOP (0) CAST(NULL AS NVARCHAR(1)) AS SpecimenID WHERE 1 = 0;
		RETURN;
	END

	SELECT
		SpecimenID, VisitNum, PanelGroup, Carrier, FinancialClass, Provider,
		ReferringProvider, Facility, ChartNum, PatientName, ClinicName, DOB,
		BeginDOS, DOE, LastBillDate, BilledUnbilled, POS, TOS, ModifierField,
		PrimaryDiagnosis, CPTs, TotalCharge, TotalAllowed, CarrierPayment,
		PaymentPercent, CarrierWO, PatientPayment, PatientWO, CarrierBalance,
		PatientBalance, TotalBalance, PostedDate, Aging, AgingBucket, DenialCode,
		PaymentStatus, BilledWeek, PostedWeek, FullyPaidCount, FullyPaidAmount,
		AdjudicatedCount, AdjudicatedAmount, Bucket30Count, Bucket30Amount,
		Bucket60Count, Bucket60Amount, InsertedDateTime
	FROM dbo.ClientPaidListData
	WHERE
		(@Year  = 0 OR YEAR (TRY_CAST(BeginDOS AS DATE)) = @Year)
	  AND (@Month = 0 OR MONTH(TRY_CAST(BeginDOS AS DATE)) = @Month)
	ORDER BY TRY_CAST(BeginDOS AS DATE), SpecimenID;
END;
GO

PRINT '24_RisingTides_ExecutiveSummaryDetailRows_ClientPaidList.sql completed.';
GO

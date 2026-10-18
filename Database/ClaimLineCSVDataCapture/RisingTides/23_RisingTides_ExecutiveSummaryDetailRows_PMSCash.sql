-- ============================================================
-- RisingTides – Executive Summary Detail Page: PMS / Cash Breakdown row-level data
-- File : 23_RisingTides_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : Rising_Tides
--
-- Returns the full ClaimLevelData row(s) behind a clicked "PMS Breakdown"
-- or "Cash Breakdown" count on the Executive Summary grid. RowCode
-- filter logic mirrors dbo.usp_GetRT_ExecutiveSummary_Detail
-- (18_RisingTides_ExecutiveSummary_Detail.sql), but selects the full
-- set of ClaimLevelData columns requested for the Detail page grid/Excel
-- export instead of the narrow 15-column shared shape.
--
-- Parameters
--   @Category – 'PMS' | 'Cash'
--   @RowCode  – e.g. 'O','P','Q','R','S','T','U','V','W','W1'..'W3',
--                'X','Y','Z','AA'..'AG','AG1'..'AG3' (Cash)
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months within the year)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PMSCash
(
	@Category  NVARCHAR(20),
	@RowCode   NVARCHAR(350),
	@Year      INT = 0,
	@Month     INT = 0
)
AS
BEGIN
	SET NOCOUNT ON;

	DROP TABLE IF EXISTS #Base;

	SELECT
		ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
		PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code,
		Global_Payer_ID, PayerType, BillingProvider, ReferringProvider, ClinicName,
		SalesRepname, PatientID, PatientDOB, DateofService, ChargeEnteredDate,
		FirstBilledDate, Panelname, CPTCodeXUnitsXModifier, POS, TOS,
		ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
		InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
		InsuranceBalance, PatientBalance, TotalBalance,
		CheckDate, ClaimStatus, DenialCode, ICDCode,
		DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
		InsertedDateTime, CPTCodeXUnitsXModifierOrginal, PatientName, BilledUnbilled,
		ModifierField, PaymentPercent, Aging, AgingBucket, BilledWeek, PostedWeek,
		FullyPaidCount, FullyPaidAmount, AdjucticatedCount, AdjucticatedAmount,
		Bucket30Count, Bucket30Amount, Bucket60Count, Bucket60Amount,
		DOE_Year, DOE_Month, Facility,
		TRY_CAST(DateofService AS DATE) AS ESDate,
		YEAR (TRY_CAST(DateofService AS DATE)) AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE)) AS ESMonth
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
			b.ClaimID, b.AccessionNumber, b.SourceFileID, b.IngestedOn, b.CsvRowHash,
			b.PayerName_Raw, b.PayerName, b.Payer_Code, b.Payer_Common_Code, b.Payer_Group_Code,
			b.Global_Payer_ID, b.PayerType, b.BillingProvider, b.ReferringProvider, b.ClinicName,
			b.SalesRepname, b.PatientID, b.PatientDOB, b.DateofService, b.ChargeEnteredDate,
			b.FirstBilledDate, b.Panelname, b.CPTCodeXUnitsXModifier, b.POS, b.TOS,
			b.ChargeAmount, b.AllowedAmount, b.InsurancePayment, b.PatientPayment, b.TotalPayments,
			b.InsuranceAdjustments, b.PatientAdjustments, b.TotalAdjustments,
			b.InsuranceBalance, b.PatientBalance, b.TotalBalance,
			b.CheckDate, b.ClaimStatus, b.DenialCode, b.ICDCode,
			b.DaystoDOS, b.RollingDays, b.DaystoBill, b.DaystoPost, b.ICDPointer,
			b.InsertedDateTime, b.CPTCodeXUnitsXModifierOrginal, b.PatientName, b.BilledUnbilled,
			b.ModifierField, b.PaymentPercent, b.Aging, b.AgingBucket, b.BilledWeek, b.PostedWeek,
			b.FullyPaidCount, b.FullyPaidAmount, b.AdjucticatedCount, b.AdjucticatedAmount,
			b.Bucket30Count, b.Bucket30Amount, b.Bucket60Count, b.Bucket60Amount,
			b.DOE_Year, b.DOE_Month, b.Facility
		FROM #Base b
		WHERE
			-- O  – Billed
			(@RowCode = 'O'  AND b.BilledUnbilled = 'Billed')
		 OR -- P  – Billed Mismatches
			(@RowCode = 'P'  AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Unbilled')
		 OR -- Q  – Unbilled
			(@RowCode = 'Q'  AND b.BilledUnbilled = 'Unbilled')
		 OR -- R  – Paid Client (normally routed to ClientPaidListData instead — kept here as a fallback)
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
		 OR -- Fallback: unrecognized RowCode -> return everything in the period
			(@RowCode NOT IN ('O','P','Q','R','S','T','U','V','X','W','W1','W2','W3'))
		ORDER BY b.DateofService, b.ClaimID;
	END

	-- ── Cash category ─────────────────────────────────────────────────────
	ELSE IF @Category = 'Cash'
	BEGIN
		SELECT DISTINCT
			b.ClaimID, b.AccessionNumber, b.SourceFileID, b.IngestedOn, b.CsvRowHash,
			b.PayerName_Raw, b.PayerName, b.Payer_Code, b.Payer_Common_Code, b.Payer_Group_Code,
			b.Global_Payer_ID, b.PayerType, b.BillingProvider, b.ReferringProvider, b.ClinicName,
			b.SalesRepname, b.PatientID, b.PatientDOB, b.DateofService, b.ChargeEnteredDate,
			b.FirstBilledDate, b.Panelname, b.CPTCodeXUnitsXModifier, b.POS, b.TOS,
			b.ChargeAmount, b.AllowedAmount, b.InsurancePayment, b.PatientPayment, b.TotalPayments,
			b.InsuranceAdjustments, b.PatientAdjustments, b.TotalAdjustments,
			b.InsuranceBalance, b.PatientBalance, b.TotalBalance,
			b.CheckDate, b.ClaimStatus, b.DenialCode, b.ICDCode,
			b.DaystoDOS, b.RollingDays, b.DaystoBill, b.DaystoPost, b.ICDPointer,
			b.InsertedDateTime, b.CPTCodeXUnitsXModifierOrginal, b.PatientName, b.BilledUnbilled,
			b.ModifierField, b.PaymentPercent, b.Aging, b.AgingBucket, b.BilledWeek, b.PostedWeek,
			b.FullyPaidCount, b.FullyPaidAmount, b.AdjucticatedCount, b.AdjucticatedAmount,
			b.Bucket30Count, b.Bucket30Amount, b.Bucket60Count, b.Bucket60Amount,
			b.DOE_Year, b.DOE_Month, b.Facility
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
		 OR -- Fallback: unrecognized RowCode -> return everything in the period
			(@RowCode NOT IN ('X','Y','Z','AA','AB','AC','AD','AE','AF','AG','AG1','AG2','AG3'))
		ORDER BY b.DateofService, b.ClaimID;
	END

	DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '23_RisingTides_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO

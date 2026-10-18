-- ============================================================
-- PhiLife – Executive Summary Detail (Drill-Down) SP
-- File : 18_PhiLife_ExecutiveSummary_Detail.sql
-- DB   : PhiLife_LRN
--
-- Fresh rewrite mirroring PCRLabsofAmerica\18_PCRLOA_ExecutiveSummary_Detail.sql,
-- combining the PMS/Cash/LIS Detail branches into a single SP keyed by
-- @Category, using PhiLife's own (consistent) RoleID scheme — the same
-- scheme implemented in 16_PhiLife_ExecutiveSummary_Aggregate.sql,
-- 17_PhiLife_ExecutiveSummary_Read.sql and
-- 19_PhiLife_ExecutiveSummary_LIS_Alt.sql.
--
-- Unlike PCRLOA (LIS sourced from dbo.LIMSMaster with dynamic column
-- auto-detection), PhiLife has NO dbo.LIMSMaster — ALL THREE categories
-- (PMS, Cash, LIS) are sourced from the SAME dbo.ClaimLevelData #Base,
-- so no dynamic SQL is required here.
--
-- Parameters
--   @Category – 'PMS' | 'Cash' | 'LIS'
--   @RowCode  – PMS: Q,R,S,T,U,V,W,X,Y,Y.1-Y.3
--                Cash: Z,AA-AI,AI.1-AI.3
--                LIS: Total,A,A.<Panelname>,A1-A8 (+subs),B,B1-B5 (+subs)
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months within the year)
--
-- 'R' (Billed Mismatches – cross-table LIS check) has no separate
-- detail set for PhiLife (no dbo.LIMSMaster); it degenerates to the
-- same Billed rows as 'Q' (documented fallback, consistent with the
-- aggregate/read SPs in 16/17).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_ExecutiveSummary_Detail
(
	@Category NVARCHAR(10),
	@RowCode  NVARCHAR(20),
	@Year     INT = 0,
	@Month    INT = 0
)
AS
BEGIN
	SET NOCOUNT ON;

	-- Dynamic 'A.<Panelname>' LIS sub-rows: extract the panel name after 'A.'
	DECLARE @PanelFilter NVARCHAR(300) = NULL;
	IF @Category = 'LIS' AND @RowCode LIKE 'A.%'
		SET @PanelFilter = SUBSTRING(@RowCode, 3, 300);

	DROP TABLE IF EXISTS #Base;

	SELECT
		AccessionNumber,
		LTRIM(RTRIM(ISNULL(PatientName,     '')))  AS PatientName,
		LTRIM(RTRIM(ISNULL(PayerName,       '')))  AS PayerName,
		ISNULL(LTRIM(RTRIM(Panelname)), '')        AS Panelname,
		LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
		LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
		DateofService,
		FirstBilledDate,
		ISNULL(BilledUnbilled, '')                  AS BilledUnbilled,
		ISNULL(LTRIM(RTRIM(ClaimStatus)), '')       AS ClaimStatus,
		ISNULL(LTRIM(RTRIM(PayerType)), '')         AS PayerType,
		ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
		ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
		ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
		CASE
			WHEN FirstBilledDate IS NOT NULL THEN 1
			WHEN ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> '' THEN 1
			ELSE 0
		END AS IsResulted
	INTO #Base
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL
	  AND (@Year=0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
	  AND (@Month=0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

	-- ── PMS category ─────────────────────────────────────────────────────
	IF @Category = 'PMS'
	BEGIN
		SELECT DISTINCT
			b.AccessionNumber AS VisitNumber,
			b.PatientName,
			b.PayerName,
			b.Panelname        AS PanelName,
			b.ClinicName,
			b.BillingProvider,
			b.DateofService,
			b.FirstBilledDate,
			b.BilledUnbilled,
			b.ClaimStatus,
			b.PayerType,
			b.ChargeAmount,
			b.InsurancePayment,
			b.PatientPayment,
			b.InsuranceBalance,
			b.PatientBalance,
			b.InsuranceAdjustments,
			b.PatientAdjustments,
			b.IsResulted        AS ResultedNot
		FROM #Base b
		WHERE
			   (@RowCode = 'Q'    AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'R'    AND b.BilledUnbilled = 'Billed')   -- degenerate fallback: R = Q (no LIMSMaster)
			OR (@RowCode = 'S'    AND b.BilledUnbilled = 'Unbilled')
			OR (@RowCode = 'T'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
			OR (@RowCode = 'U'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Complete W/O')
			OR (@RowCode = 'V'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility')
			OR (@RowCode = 'W'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
			OR (@RowCode = 'X'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment')
			OR (@RowCode = 'Y'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied'))
			OR (@RowCode = 'Y.1'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Denied')
			OR (@RowCode = 'Y.2'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
			OR (@RowCode = 'Y.3'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied'))
		ORDER BY b.DateofService, b.AccessionNumber;
	END

	-- ── Cash category ────────────────────────────────────────────────────
	ELSE IF @Category = 'Cash'
	BEGIN
		SELECT DISTINCT
			b.AccessionNumber AS VisitNumber,
			b.PatientName,
			b.PayerName,
			b.Panelname        AS PanelName,
			b.ClinicName,
			b.BillingProvider,
			b.DateofService,
			b.FirstBilledDate,
			b.BilledUnbilled,
			b.ClaimStatus,
			b.PayerType,
			b.ChargeAmount,
			b.InsurancePayment,
			b.PatientPayment,
			b.InsuranceBalance,
			b.PatientBalance,
			b.InsuranceAdjustments,
			b.PatientAdjustments,
			b.IsResulted        AS ResultedNot
		FROM #Base b
		WHERE
			   (@RowCode = 'Z'    AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'AA'   AND b.BilledUnbilled = 'Unbilled')
			OR (@RowCode = 'AB'   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
			OR (@RowCode = 'AC'   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
			OR (@RowCode = 'AD'   AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'AE'   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Complete W/O')
			OR (@RowCode = 'AF'   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus <> 'Complete W/O')
			OR (@RowCode = 'AG'   AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'AH'   AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'AI'   AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'AI.1' AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Denied')
			OR (@RowCode = 'AI.2' AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
			OR (@RowCode = 'AI.3' AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('No Response','Fully Denied'))
		ORDER BY b.DateofService, b.AccessionNumber;
	END

	-- ── LIS category ─────────────────────────────────────────────────────
	ELSE IF @Category = 'LIS'
	BEGIN
		SELECT DISTINCT
			b.AccessionNumber AS VisitNumber,
			b.PatientName,
			b.PayerName,
			b.Panelname        AS PanelName,
			b.ClinicName,
			b.BillingProvider,
			b.DateofService,
			b.FirstBilledDate,
			b.BilledUnbilled,
			b.ClaimStatus,
			b.PayerType,
			b.ChargeAmount,
			b.InsurancePayment,
			b.PatientPayment,
			b.InsuranceBalance,
			b.PatientBalance,
			b.InsuranceAdjustments,
			b.PatientAdjustments,
			b.IsResulted        AS ResultedNot
		FROM #Base b
		WHERE
			   (@RowCode = 'Total')
			OR (@RowCode = 'A'    AND b.IsResulted = 1)
			OR (@PanelFilter IS NOT NULL AND b.IsResulted = 1 AND LTRIM(RTRIM(b.Panelname)) = @PanelFilter COLLATE DATABASE_DEFAULT)
			OR (@RowCode = 'A1'   AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed' AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'A1.1' AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed' AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'A2'   AND b.IsResulted = 1 AND b.ClaimStatus = 'Not Entered in AMD' AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance')
			OR (@RowCode = 'A2.1' AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD'))
			OR (@RowCode = 'A2.2' AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Billing Review Required')
			OR (@RowCode = 'A2.3' AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Collected')
			OR (@RowCode = 'A3'   AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Entered')
			OR (@RowCode = 'A4'   AND b.IsResulted = 1 AND b.PayerType = 'Client Bill')
			OR (@RowCode = 'A4.1' AND b.IsResulted = 1 AND b.PayerType = 'Client Bill' AND b.ClaimStatus = 'Not Entered in AMD')
			OR (@RowCode = 'A4.2' AND b.IsResulted = 1 AND b.PayerType = 'Client Bill' AND b.ClaimStatus = 'Billed')
			OR (@RowCode = 'A5'   AND b.IsResulted = 1 AND b.PayerType = 'Self Pay')
			OR (@RowCode = 'A5.1' AND b.IsResulted = 1 AND b.PayerType = 'Self Pay' AND b.ClaimStatus = 'Billed')
			OR (@RowCode = 'A5.2' AND b.IsResulted = 1 AND b.PayerType = 'Self Pay' AND b.ClaimStatus = 'Not Entered in AMD')
			OR (@RowCode = 'A6'   AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Test Entries')
			OR (@RowCode = 'A6.1' AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Not Entered in AMD')
			OR (@RowCode = 'A6.2' AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Billed')
			OR (@RowCode = 'A7'   AND b.IsResulted = 1 AND b.ClaimStatus = 'Rejected')
			OR (@RowCode = 'A7.1' AND b.IsResulted = 1 AND b.ClaimStatus = 'Not Entered in AMD')
			OR (@RowCode = 'A7.2' AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed')
			OR (@RowCode = 'A8'   AND b.IsResulted = 1 AND b.PayerType = 'No Bill')
			OR (@RowCode = 'B'    AND b.IsResulted = 0)
			OR (@RowCode = 'B1'   AND b.IsResulted = 0 AND b.ClaimStatus = 'Not Entered in AMD' AND b.PayerType = 'Insurance')
			OR (@RowCode = 'B1.1' AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD'))
			OR (@RowCode = 'B1.2' AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Collected')
			OR (@RowCode = 'B2'   AND b.IsResulted = 0 AND b.PayerType = 'Client Bill')
			OR (@RowCode = 'B3'   AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Test Entries')
			OR (@RowCode = 'B4'   AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Rejected')
			OR (@RowCode = 'B5'   AND b.IsResulted = 0 AND b.PayerType = 'No Bill')
		ORDER BY b.DateofService, b.AccessionNumber;
	END

	DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '18_PhiLife_ExecutiveSummary_Detail.sql completed.';
GO

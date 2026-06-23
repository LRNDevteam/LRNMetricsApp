-- ============================================================
-- PCRLabsofAmerica – Executive Summary Detail Page: PMS / Cash Breakdown row-level data
-- File : 21_PCRLOA_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : PCRLabsofAmerica
--
-- Generic-named counterpart of RisingTides'
-- 23_RisingTides_ExecutiveSummaryDetailRows_PMSCash.sql. The Executive
-- Summary "Detail" page (LabMetricsDashboard.ExecutiveSummaryController.Detail)
-- calls dbo.usp_GetExecutiveSummaryDetail_PMSCash for ANY lab whose clicked
-- cell is in the 'PMS' or 'Cash' category — this SP must therefore exist
-- (with this exact, non-prefixed name) inside the PCRLabsofAmerica database too.
--
-- Returns the ClaimLevelData row(s) behind a clicked "PMS Breakdown" /
-- "Cash Breakdown" count on the Executive Summary grid. #Base population
-- and the RoleID predicates below mirror the PMS/Cash sections of
-- 16_PCRLOA_ExecutiveSummary_Aggregate.sql, so results match the counts
-- produced there.
--
-- Parameters
--   @Category – 'PMS' or 'Cash'
--   @RowCode  – PMS:  I,J,K,L,M,N,O,P,P.1,P.2,P.3
--                Cash: Q,R,S,T,U,V,W,X,Y,Y.1,Y.2,Y.3
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months within the year)
--
-- Period filter is based on DateofService, same as the existing
-- PMS/Cash detail/aggregate procs.
--
-- 'J' (Billed Mismatch) is a cross-table delta between ClaimLevelData
-- (billed claims, by VisitNumber) and dbo.LIMSMaster (billed samples, by
-- Accession) — it is not a simple per-row classification within
-- ClaimLevelData alone. As a best-effort drill-down, 'J' returns the
-- billed ClaimLevelData rows whose VisitNumber has NO corresponding
-- 'Billed' Accession in #LisBilled (i.e. one side of the mismatch: claims
-- billed in AMD/PMS that do not appear as billed in the LIMS). If
-- dbo.LIMSMaster does not exist, #LisBilled stays empty and 'J' returns
-- all billed rows (matching the aggregate's J degenerating to equal I).
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PMSCash
(
	@Category NVARCHAR(20),
	@RowCode  NVARCHAR(350),
	@Year     INT = 0,
	@Month    INT = 0
)
AS
BEGIN
	SET NOCOUNT ON;

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

	-- #LisBilled – billed Accessions from dbo.LIMSMaster for the same
	-- period filter, used only by PMS row 'J' (Billed Mismatch) below.
	DROP TABLE IF EXISTS #LisBilled;
	CREATE TABLE #LisBilled
	(
		Accession      NVARCHAR(100) NOT NULL,
		BilledUnbilled NVARCHAR(100) NOT NULL
	);

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
	BEGIN
		INSERT INTO #LisBilled (Accession, BilledUnbilled)
		SELECT
			LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))),
			LTRIM(RTRIM(ISNULL(BilledorNot, '')))
		FROM dbo.LIMSMaster
		WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), Accession))), '') IS NOT NULL
		  AND (@Year  = 0 OR YEAR (TRY_CAST(RequestCollectDate AS DATE)) = @Year)
		  AND (@Month = 0 OR MONTH(TRY_CAST(RequestCollectDate AS DATE)) = @Month);
	END

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
			-- I  – Billed
			(@RowCode = 'I'   AND b.BilledUnbilled = 'Billed')
		 OR -- J  – Billed Mismatch (best-effort: billed in PMS, not billed per LIMS)
			(@RowCode = 'J'   AND b.BilledUnbilled = 'Billed'
			                  AND NOT EXISTS (SELECT 1 FROM #LisBilled l
			                                  WHERE l.Accession = b.VisitNumber
			                                    AND l.BilledUnbilled = 'Billed'))
		 OR -- K  – Unbilled
			(@RowCode = 'K'   AND b.BilledUnbilled = 'Unbilled')
		 OR -- L  – Fully Paid
			(@RowCode = 'L'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Fully Paid')
		 OR -- M  – Fully Adjusted (Complete W/O)
			(@RowCode = 'M'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Complete W/O')
		 OR -- N  – Patient Responsibility
			(@RowCode = 'N'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Patient Responsibility')
		 OR -- O  – Partially Paid
			(@RowCode = 'O'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Partially Paid')
		 OR -- P  – Insurance Balance (parent)
			(@RowCode = 'P'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus IN ('Fully Denied','No Response','Partially Adjusted','Partially Denied'))
		 OR -- P.1 – No Response
			(@RowCode = 'P.1' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'No Response')
		 OR -- P.2 – Fully Denied
			(@RowCode = 'P.2' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Fully Denied')
		 OR -- P.3 – Partially Denied (Partially Adjusted + Partially Denied)
			(@RowCode = 'P.3' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied'))
		 OR -- Fallback: unrecognized RowCode -> return everything in the period
			(@RowCode NOT IN ('I','J','K','L','M','N','O','P','P.1','P.2','P.3'))
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
			-- Q  – Total Billed ($)
			(@RowCode = 'Q'   AND b.BilledUnbilled = 'Billed')
		 OR -- R  – Unbilled ($)
			(@RowCode = 'R'   AND b.BilledUnbilled = 'Unbilled')
		 OR -- S  – Insurance Payment (fully paid)
			(@RowCode = 'S'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Fully Paid')
		 OR -- T  – Partially Paid
			(@RowCode = 'T'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Partially Paid')
		 OR -- U  – Fully Adjusted (Complete W/O)
			(@RowCode = 'U'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Complete W/O')
		 OR -- V  – Contractual Obligation W/O
			(@RowCode = 'V'   AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus <> 'Complete W/O')
		 OR -- W  – Patient Balance
			(@RowCode = 'W'   AND b.BilledUnbilled = 'Billed')
		 OR -- X  – Patient W/O
			(@RowCode = 'X'   AND b.BilledUnbilled = 'Billed')
		 OR -- Y  – Insurance Balance (parent; no ClaimStatus filter)
			(@RowCode = 'Y'   AND b.BilledUnbilled = 'Billed')
		 OR -- Y.1 – No Response
			(@RowCode = 'Y.1' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'No Response')
		 OR -- Y.2 – Fully Denied
			(@RowCode = 'Y.2' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus = 'Fully Denied')
		 OR -- Y.3 – Partially Denied (everything else with an Insurance Balance)
			(@RowCode = 'Y.3' AND b.BilledUnbilled = 'Billed'   AND b.ClaimStatus NOT IN ('No Response','Fully Denied'))
		 OR -- Fallback: unrecognized RowCode -> return everything in the period
			(@RowCode NOT IN ('Q','R','S','T','U','V','W','X','Y','Y.1','Y.2','Y.3'))
		ORDER BY b.DateofService, b.VisitNumber;
	END

	ELSE
	BEGIN
		-- Unknown @Category -> return everything in the period as a fallback.
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
		ORDER BY b.DateofService, b.VisitNumber;
	END

	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '21_PCRLOA_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO

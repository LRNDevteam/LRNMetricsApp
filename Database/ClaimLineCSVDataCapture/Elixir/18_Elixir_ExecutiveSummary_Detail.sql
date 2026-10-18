-- ============================================================
-- Elixir – Executive Summary Detail (Drill-Down) SP
-- File : 18_Elixir_ExecutiveSummary_Detail.sql
-- DB   : Elixir_LRN
--
-- Mirrors PhiLife\18_PhiLife_ExecutiveSummary_Detail.sql, but uses
-- Elixir's own RoleID scheme — the same scheme implemented in
-- 16_Elixir_ExecutiveSummary_Aggregate.sql and
-- 17_Elixir_ExecutiveSummary_Read.sql.
--
-- All ClaimLevelData-sourced categories (PMS, Cash) are produced from
-- the SAME #Base built from dbo.ClaimLevelData, so no dynamic SQL is
-- required here.
--
-- Parameters
--   @Category – 'PMS' | 'Cash'
--   @RowCode  – PMS : F,G,H,I,J,K,L,M,N,O,P,P.1-P.3
--                Cash: Q,R,S,T,U,V,W,X,X.1-X.3
--   @Year     – calendar year  (0 = all years)
--   @Month    – calendar month (0 = all months within the year)
--
-- NOTES
--  * Elixir's LIS Breakdown (RoleID A-E, +D.1, +E.1-E.6) is sourced from
--    dbo.LIMSMaster, NOT dbo.ClaimLevelData, and is therefore NOT handled
--    by this SP. The application's ExecutiveSummary controller routes
--    @Category='LIS' drill-downs to the GENERIC (non lab-prefixed)
--    dbo.usp_GetExecutiveSummaryDetail_LIS proc instead — see
--    20_Elixir_ExecutiveSummaryDetailRows_LIS.sql.
--  * 'I' (Billed Mismatches - LIS Accession Cannot be Matched) is a
--    cross-table COUNT difference (ClaimLevelData vs LIMSMaster), not a
--    drillable claim list. It degenerates to the same row set as 'F'
--    (Billed claims), mirroring PhiLife's degenerate 'R' -> 'Q' fallback.
--  * The Avg category (RoleID Y, Z, AA) is computed (not a row list) and
--    has no detail branch here, consistent with PhiLife's file 18.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetElix_ExecutiveSummary_Detail
(
	@Category NVARCHAR(10),
	@RowCode  NVARCHAR(20),
	@Year     INT = 0,
	@Month    INT = 0
)
AS
BEGIN
	SET NOCOUNT ON;

	DROP TABLE IF EXISTS #Base;

	SELECT
		AccessionNumber,
		LTRIM(RTRIM(ISNULL(PatientFirstName+' '+PatientLastName,     '')))  AS PatientName,
		LTRIM(RTRIM(ISNULL(PayerName,       '')))  AS PayerName,
		ISNULL(LTRIM(RTRIM(Panelname)), '')        AS Panelname,
		LTRIM(RTRIM(ISNULL(ClinicName,      '')))  AS ClinicName,
		LTRIM(RTRIM(ISNULL(BillingProvider, '')))  AS BillingProvider,
		DateofService,
		FirstBilledDate,
		ISNULL(BillStatus, '')                  AS BilledUnbilled,
		ISNULL(LTRIM(RTRIM(ClaimStatus)), '')       AS ClaimStatus,
		ISNULL(LTRIM(RTRIM(PayerType)), '')         AS PayerType,
		ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
		ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
		ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments
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
			b.PatientAdjustments
		FROM #Base b
		WHERE
			   (@RowCode = 'F'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled'))
			OR (@RowCode = 'G'    AND b.ClaimStatus IN ('Unbilled','Unbilled - PB'))
			OR (@RowCode = 'H'    AND b.ClaimStatus = 'Voided')
			OR (@RowCode = 'I'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled'))  -- degenerate fallback: I = F (cross-table count, not a row list)
			OR (@RowCode = 'J'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
			OR (@RowCode = 'K'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility')
			OR (@RowCode = 'L'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment')
			OR (@RowCode = 'M'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Adjusted')
			OR (@RowCode = 'N'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Adjusted')
			OR (@RowCode = 'O'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
			OR (@RowCode = 'P'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Denied','No Response','Partially Denied'))
			OR (@RowCode = 'P.1'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied')
			OR (@RowCode = 'P.2'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied'))
			OR (@RowCode = 'P.3'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
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
			b.InsuranceAdjustments,
			b.PatientAdjustments,
			b.InsuranceBalance,
			b.PatientBalance
		FROM #Base b
		WHERE
			   (@RowCode = 'Q'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0'))
			OR (@RowCode = 'R'    AND b.ClaimStatus = 'Unbilled')
			OR (@RowCode = 'S'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
			OR (@RowCode = 'T'    AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'U'    AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'V'    AND b.BilledUnbilled = 'Billed')
			OR (@RowCode = 'W'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
			OR (@RowCode = 'X'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0'))
			OR (@RowCode = 'X.1'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied')
			OR (@RowCode = 'X.2'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Denied','Partially Paid','Partially Adjusted','Patient Responsibility'))
			OR (@RowCode = 'X.3'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
		ORDER BY b.DateofService, b.AccessionNumber;
	END

	DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '18_Elixir_ExecutiveSummary_Detail.sql completed.';
GO

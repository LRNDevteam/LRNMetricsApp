/* =============================================================================
   VariantX Labs — Executive Summary Aggregate Refresh (PMS / Cash / Avg)
   Prefix: VarX_ / VarX_ES_
   Refresh: usp_RefreshVarX_ExecutiveSummary
   Source: dbo.ClaimLevelData (+ LIS C for mismatch G)
   =============================================================================
   Client Executive Summary sheet RoleIDs:

   PMS (population = FirstBilledDate present; month bucket = DateofService; COUNT DISTINCT ClaimID):
     F      No. of Billed Claims
     F.1   Claim Submitted in Cove         AccessionNumber IN CoveLRN.dbo.LIMSMaster.Accession
     F.2   Claim Submitted in Others       max(0, F - F.1 - F.3)
     F.3   Claim Submitted in VariantX     AccessionNumber IN dbo.LIMSMaster.Accession
     G      Billed Mismatches = F - LIS C
     H      Fully Paid
     I      Patient Responsibility
     J      Adjusted / Written Off          ClaimStatus = Fully Adjusted
                                             (sheet text copy-pasted Patient Responsibility)
     K      Partially Adjusted / Written Off
     L      Partially Paid
     M      Patient Paid                    ClaimStatus = Patient Payment
     N      Insurance Balance Claims        Denied/Fully Denied, Partially Denied, No Response
     N.1 / N.2 / N.3                        Fully Denied|Denied / Partially Denied / No Response

   Cash (same FirstBilledDate population; DateofService month bucket; dollar sums):
     O      Total Billed ($)                Sum(ChargeAmount)
     P      Insurance Payment ($)           Sum(InsurancePayment) Fully Paid
     Q      Patient Responsibility ($)      Sum(PatientBalance)
     R      Patient Payment ($)             Sum(PatientPayment)
     S      Adjustments / Write Off ($)     O - P - Q - R - T - U
     T      Partially Paid ($)              Sum(InsurancePayment) Partially Paid
     U      Insurance Balance ($)           Sum(InsuranceBalance)
     U.1 / U.2 / U.3                        Denials / Partially Denied / No Response
                                            U.2 = Sum(InsuranceBalance) where ClaimStatus
                                            NOT IN (Denied, Fully Denied, No Response)

   Avg:
     V  (P+T) / F
     W  P / H
     X  (P+T) / (H + L + J + N.1 + N.2)

   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_ExecutiveSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.VarX_ES_PMS;
	TRUNCATE TABLE dbo.VarX_ES_Cash;
	TRUNCATE TABLE dbo.VarX_ES_Avg;

	DROP TABLE IF EXISTS #Base;

	-- Population: claims with FirstBilledDate. Monthwise display: DateofService.
	SELECT
		NULLIF(LTRIM(RTRIM(ClaimID)), '') AS ClaimKey,
		NULLIF(LTRIM(RTRIM(AccessionNumber)), '') AS AccessionNumber,
		YEAR (TRY_CAST(DateofService AS DATE)) AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE)) AS ESMonth,
		ISNULL(LTRIM(RTRIM(ClaimStatus)), '') AS ClaimStatus,
		ISNULL(TRY_CAST(ChargeAmount     AS DECIMAL(18,2)), 0) AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment   AS DECIMAL(18,2)), 0) AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)), 0) AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance   AS DECIMAL(18,2)), 0) AS PatientBalance
	INTO #Base
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
	  AND TRY_CAST(DateofService AS DATE) IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL;

	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	-- G support: PMS billed claim count vs LIS C (Billable + Billed)
	DROP TABLE IF EXISTS #BaseBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT ClaimKey) AS BilledCount
	INTO #BaseBilledCount
	FROM #Base
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT ClaimKey) FROM #Base;

	DROP TABLE IF EXISTS #LisBilled;
	CREATE TABLE #LisBilled
	(
		Accession NVARCHAR(100) NOT NULL,
		ESYear    INT           NOT NULL,
		ESMonth   INT           NOT NULL
	);

	IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
	BEGIN
		DECLARE @AccCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('AccessionNumber','Accession','AccessionNo')
			ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

		DECLARE @DateCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('RequestCollectDate','DateOfCollection','CollectionDate','DateofService','ServiceDate','AccessionDate')
			ORDER BY CASE name
				WHEN 'RequestCollectDate' THEN 0 WHEN 'DateOfCollection' THEN 1
				WHEN 'CollectionDate' THEN 2 WHEN 'DateofService' THEN 3
				WHEN 'ServiceDate' THEN 4 WHEN 'AccessionDate' THEN 5 ELSE 6 END);

		DECLARE @SampleStatusCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('SampleStatus','NewStatus','Status','LRNSampleStatus')
			ORDER BY CASE name
				WHEN 'SampleStatus' THEN 0 WHEN 'LRNSampleStatus' THEN 1
				WHEN 'NewStatus' THEN 2 WHEN 'Status' THEN 3 ELSE 4 END);

		DECLARE @BillCategoryCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus','LRNBillCategory')
			ORDER BY CASE name
				WHEN 'BillCategory' THEN 0 WHEN 'LRNBillCategory' THEN 1
				WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3
				WHEN 'BillStatus' THEN 4 ELSE 5 END);

		IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @SampleStatusCol IS NOT NULL AND @BillCategoryCol IS NOT NULL
		BEGIN
			DECLARE @LisBilledSql NVARCHAR(MAX) = N'
				INSERT INTO #LisBilled (Accession, ESYear, ESMonth)
				SELECT
					LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
					YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
					MONTH(TRY_CAST([' + @DateCol + N'] AS DATE))
				FROM dbo.LIMSMaster
				WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
				  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
				  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @SampleStatusCol + N']), ''''))) = ''Billable''
				  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))) = ''Billed'';';

			EXEC sp_executesql @LisBilledSql;
		END
		ELSE
			PRINT 'usp_RefreshVarX_ExecutiveSummary: LIMSMaster columns missing - G will use F only until LIS refresh.';
	END

	DROP TABLE IF EXISTS #LisBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT Accession) AS BilledCount
	INTO #LisBilledCount
	FROM #LisBilled
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT Accession) FROM #LisBilled;

	-- Accession sets for F1 (CoveLRN LIS) / F3 (VariantX LIS). Same server three-part name.
	DROP TABLE IF EXISTS #CoveAcc;
	CREATE TABLE #CoveAcc (Acc NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
	IF DB_ID(N'CoveLRN') IS NOT NULL AND OBJECT_ID(N'CoveLRN.dbo.LIMSMaster', N'U') IS NOT NULL
	BEGIN
		INSERT INTO #CoveAcc (Acc)
		SELECT DISTINCT NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(300), Accession))), N'')
		FROM CoveLRN.dbo.LIMSMaster
		WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(300), Accession))), N'') IS NOT NULL;
	END
	ELSE
		PRINT 'usp_RefreshVarX_ExecutiveSummary: CoveLRN.dbo.LIMSMaster not reachable - F1 will be 0.';

	DROP TABLE IF EXISTS #VarAcc;
	CREATE TABLE #VarAcc (Acc NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
	IF OBJECT_ID(N'dbo.LIMSMaster', N'U') IS NOT NULL
	   AND COL_LENGTH(N'dbo.LIMSMaster', N'Accession') IS NOT NULL
	BEGIN
		INSERT INTO #VarAcc (Acc)
		SELECT DISTINCT NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(300), Accession))), N'')
		FROM dbo.LIMSMaster
		WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(300), Accession))), N'') IS NOT NULL;
	END
	ELSE
		PRINT 'usp_RefreshVarX_ExecutiveSummary: dbo.LIMSMaster.Accession missing - F3 will be 0.';

	DROP TABLE IF EXISTS #F1Count;
	SELECT ESYear, ESMonth, COUNT(DISTINCT ClaimKey) AS Cnt
	INTO #F1Count
	FROM #Base b
	WHERE b.AccessionNumber IS NOT NULL
	  AND EXISTS (SELECT 1 FROM #CoveAcc c WHERE c.Acc = b.AccessionNumber)
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT ClaimKey)
	FROM #Base b
	WHERE b.AccessionNumber IS NOT NULL
	  AND EXISTS (SELECT 1 FROM #CoveAcc c WHERE c.Acc = b.AccessionNumber);

	DROP TABLE IF EXISTS #F3Count;
	SELECT ESYear, ESMonth, COUNT(DISTINCT ClaimKey) AS Cnt
	INTO #F3Count
	FROM #Base b
	WHERE b.AccessionNumber IS NOT NULL
	  AND EXISTS (SELECT 1 FROM #VarAcc v WHERE v.Acc = b.AccessionNumber)
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT ClaimKey)
	FROM #Base b
	WHERE b.AccessionNumber IS NOT NULL
	  AND EXISTS (SELECT 1 FROM #VarAcc v WHERE v.Acc = b.AccessionNumber);

	-- ── PMS ──────────────────────────────────────────────────────────────────
	INSERT INTO dbo.VarX_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'F: No. of Billed Claims' AS Description,
			   COUNT(DISTINCT b.ClaimKey) AS ClaimCount
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'F.1', '  1) Claim Submitted in Cove',
			   ISNULL(f1.Cnt, 0)
		FROM #Periods p
		LEFT JOIN #F1Count f1 ON f1.ESYear = p.ESYear AND f1.ESMonth = p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'F.2', '  2) Claim Submitted in Others',
			   CASE WHEN ISNULL(bb.BilledCount, 0) - ISNULL(f1.Cnt, 0) - ISNULL(f3.Cnt, 0) > 0
					THEN ISNULL(bb.BilledCount, 0) - ISNULL(f1.Cnt, 0) - ISNULL(f3.Cnt, 0)
					ELSE 0 END
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear = p.ESYear AND bb.ESMonth = p.ESMonth
		LEFT JOIN #F1Count f1 ON f1.ESYear = p.ESYear AND f1.ESMonth = p.ESMonth
		LEFT JOIN #F3Count f3 ON f3.ESYear = p.ESYear AND f3.ESMonth = p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'F.3', '  3) Claim Submitted in VariantX',
			   ISNULL(f3.Cnt, 0)
		FROM #Periods p
		LEFT JOIN #F3Count f3 ON f3.ESYear = p.ESYear AND f3.ESMonth = p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G',
			   'Billed Mismatches - Accessions NA / Cove Claims billed',
			   CASE WHEN ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0) > 0
					THEN ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0)
					ELSE 0 END
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear = p.ESYear AND bb.ESMonth = p.ESMonth
		LEFT JOIN #LisBilledCount  ll ON ll.ESYear = p.ESYear AND ll.ESMonth = p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H', 'No. of Fully Paid Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I', 'No. of Patient Responsibility Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Patient Responsibility'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'J', 'No. of Adjusted/ Written Off Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Fully Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'K', 'No. of Partially Adjusted/ Written Off Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Partially Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L', 'No. of Partially Paid Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'M', 'No. of Patient Paid Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Patient Payment'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N', 'No. of Insurance Balance Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus IN ('Fully Denied','Denied','Partially Denied','No Response')
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N.1', '  No. of Fully Denied Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus IN ('Fully Denied','Denied')
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N.2', '  No. of Partially Denied Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Partially Denied'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N.3', '  No. of No Response from Payor Claims',
			   COUNT(DISTINCT b.ClaimKey)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	) pms;

	-- ── Cash ─────────────────────────────────────────────────────────────────
	INSERT INTO dbo.VarX_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeValue, GETDATE()
	FROM
	(
		SELECT p.ESYear, p.ESMonth, 'O' AS RoleID, 'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount), 0) AS ChargeValue
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P', 'Insurance Payment ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Q', 'Patient Responsibility ($)',
			   ISNULL(SUM(b.PatientBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'R', 'Patient Payment ($)',
			   ISNULL(SUM(b.PatientPayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'T', 'Partially Paid ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U', 'Insurance Balance ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U.1', '  Denials ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus IN ('Denied','Fully Denied')
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U.2', '  Partially Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus NOT IN ('Denied','Fully Denied','No Response')
		GROUP BY p.ESYear, p.ESMonth

		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U.3', '  No Response from Payor ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	) cash;

	-- S = O - P - Q - R - T - U  (table-driven after O/P/Q/R/T/U exist)
	INSERT INTO dbo.VarX_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT
		'S',
		'Adjustments / Write Off ($)',
		p.ESYear, p.ESMonth,
		0,
		ISNULL(o.ESMonthChargeAmount, 0)
		  - ISNULL(ip.ESMonthChargeAmount, 0)
		  - ISNULL(q.ESMonthChargeAmount, 0)
		  - ISNULL(r.ESMonthChargeAmount, 0)
		  - ISNULL(t.ESMonthChargeAmount, 0)
		  - ISNULL(u.ESMonthChargeAmount, 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN dbo.VarX_ES_Cash o  ON o.ESYear=p.ESYear  AND o.ESMonth=p.ESMonth  AND o.RoleID='O'
	LEFT JOIN dbo.VarX_ES_Cash ip ON ip.ESYear=p.ESYear AND ip.ESMonth=p.ESMonth AND ip.RoleID='P'
	LEFT JOIN dbo.VarX_ES_Cash q  ON q.ESYear=p.ESYear  AND q.ESMonth=p.ESMonth  AND q.RoleID='Q'
	LEFT JOIN dbo.VarX_ES_Cash r  ON r.ESYear=p.ESYear  AND r.ESMonth=p.ESMonth  AND r.RoleID='R'
	LEFT JOIN dbo.VarX_ES_Cash t  ON t.ESYear=p.ESYear  AND t.ESMonth=p.ESMonth  AND t.RoleID='T'
	LEFT JOIN dbo.VarX_ES_Cash u  ON u.ESYear=p.ESYear  AND u.ESMonth=p.ESMonth  AND u.RoleID='U';

	-- ── Avg (table-driven) ───────────────────────────────────────────────────
	;WITH
	AvgNumPT AS
	(
		SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
		FROM dbo.VarX_ES_Cash
		WHERE RoleID IN ('P','T')
		GROUP BY ESYear, ESMonth
	),
	AvgNumP AS
	(
		SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
		FROM dbo.VarX_ES_Cash
		WHERE RoleID = 'P'
		GROUP BY ESYear, ESMonth
	),
	DenF AS
	(
		SELECT ESYear, ESMonth, ESMonthClaimCount AS DenomCount
		FROM dbo.VarX_ES_PMS WHERE RoleID = 'F'
	),
	DenH AS
	(
		SELECT ESYear, ESMonth, ESMonthClaimCount AS DenomCount
		FROM dbo.VarX_ES_PMS WHERE RoleID = 'H'
	),
	DenX AS
	(
		SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenomCount
		FROM dbo.VarX_ES_PMS
		WHERE RoleID IN ('H','L','J','N.1','N.2')
		GROUP BY ESYear, ESMonth
	)
	INSERT INTO dbo.VarX_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT
		'V',
		'Average Payment ($) - Total Pay/Billed Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumPT n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenF     d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth

	UNION ALL
	SELECT
		'W',
		'Average Payment ($) - Total Pay/Paid Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumP n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenH    d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth

	UNION ALL
	SELECT
		'X',
		'Average Payment ($) - Total Pay/Adjudicated Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumPT n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenX     d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth;

	-- Weighted annual averages (never sum monthly averages)
	;WITH CashYear AS
	(
		SELECT ESYear,
			SUM(CASE WHEN RoleID IN ('P','T') THEN ESMonthChargeAmount ELSE 0 END) AS PayPlusPartial,
			SUM(CASE WHEN RoleID = 'P' THEN ESMonthChargeAmount ELSE 0 END) AS FullyPaidPayment
		FROM dbo.VarX_ES_Cash
		WHERE ESYear > 0 AND ESMonth BETWEEN 1 AND 12
		GROUP BY ESYear
	),
	PmsYear AS
	(
		SELECT ESYear,
			SUM(CASE WHEN RoleID = 'F' THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS BilledClaims,
			SUM(CASE WHEN RoleID = 'H' THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS PaidClaims,
			SUM(CASE WHEN RoleID IN ('H','L','J','N.1','N.2')
					 THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS AdjudicatedClaims
		FROM dbo.VarX_ES_PMS
		WHERE ESYear > 0 AND ESMonth BETWEEN 1 AND 12
		GROUP BY ESYear
	)
	INSERT INTO dbo.VarX_ES_Avg
		(RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT v.RoleID, v.Description, p.ESYear, 0,
		CONVERT(INT, v.Denominator),
		CONVERT(DECIMAL(18,2), CASE WHEN v.Denominator = 0 THEN 0
			ELSE ROUND(v.Numerator / v.Denominator, 2) END),
		GETDATE()
	FROM PmsYear p
	LEFT JOIN CashYear c ON c.ESYear = p.ESYear
	CROSS APPLY
	(
		VALUES
			('V', 'Average Payment ($) - Total Pay/Billed Claims',
			 CONVERT(DECIMAL(38,6), ISNULL(c.PayPlusPartial,0)), p.BilledClaims),
			('W', 'Average Payment ($) - Total Pay/Paid Claims',
			 CONVERT(DECIMAL(38,6), ISNULL(c.FullyPaidPayment,0)), p.PaidClaims),
			('X', 'Average Payment ($) - Total Pay/Adjudicated Claims',
			 CONVERT(DECIMAL(38,6), ISNULL(c.PayPlusPartial,0)), p.AdjudicatedClaims)
	) v(RoleID, Description, Numerator, Denominator);

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #LisBilledCount;

	IF OBJECT_ID('dbo.usp_VarX_ES_UpdatePmsBilledMismatch', 'P') IS NOT NULL
		EXEC dbo.usp_VarX_ES_UpdatePmsBilledMismatch;

	PRINT 'usp_RefreshVarX_ExecutiveSummary completed.';
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_VarX_ES_UpdatePmsBilledMismatch
AS
BEGIN
	SET NOCOUNT ON;

	IF OBJECT_ID('dbo.VarX_ES_PMS', 'U') IS NULL
	   OR OBJECT_ID('dbo.VarX_ES_LIS', 'U') IS NULL
		RETURN;

	UPDATE i
	SET i.ESMonthClaimCount =
		CASE WHEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(c.ESMonthClaimCount, 0) > 0
			 THEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(c.ESMonthClaimCount, 0)
			 ELSE 0 END,
		i.RefreshedAt = GETDATE()
	FROM dbo.VarX_ES_PMS i
	INNER JOIN dbo.VarX_ES_PMS f
		ON f.ESYear = i.ESYear AND f.ESMonth = i.ESMonth AND f.RoleID = 'F'
	LEFT JOIN dbo.VarX_ES_LIS c
		ON c.ESYear = i.ESYear AND c.ESMonth = i.ESMonth AND c.RoleID = 'C'
	WHERE i.RoleID = 'G';
END;
GO

PRINT '16_VariantX_ExecutiveSummary_Aggregate.sql completed.';
GO

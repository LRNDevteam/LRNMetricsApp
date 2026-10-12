/* =============================================================================
   Analyze Pathology - Executive Summary PMS Breakdown logic change (2026-10-09)
   Database: AnalyzePathology. Same definition as scripts 27 / 33 plus the PMS
   change below; run this after 33.

   F   No. of Billed Claims               Bill Status IN (Billed, Billed - Self Pay)
                                          AND Claim Status <> 0 Billed Amount
   F1    Claim Submitted in Collaborate MD  same as F
   G1    Unbilled                         Bill Status = Unbilled
                                          AND Claim Status <> 0 Billed Amount

   F also feeds PMS H (F - LIS C) and Avg X ((R + V) / F).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'AnalyzePathology'
BEGIN
    RAISERROR('Run 35_AnalyzePathology_ExecutiveSummary_PMSBilledLogic.sql on the AnalyzePathology database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnP_ES_Compute
AS
BEGIN
	SET NOCOUNT ON;

	DROP TABLE IF EXISTS #LisM;
	SELECT
		ISNULL(ESYear, 0) AS Y,
		CASE WHEN GROUPING(ESMonth) = 1 THEN 0 ELSE ESMonth END AS M,
		ISNULL(SUM(Cnt), 0) AS L_A,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' THEN Cnt END), 0) AS L_B,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' AND BillCategory = N'Billed' THEN Cnt END), 0) AS L_C,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' AND BillCategory IN (N'Unbilled', N'Not Billed') THEN Cnt END), 0) AS L_D,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' AND BillCategory IN (N'Unbilled', N'Not Billed')
						 AND SubStatus = N'Ready to Bill' THEN Cnt END), 0) AS L_D1,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' AND BillCategory IN (N'Unbilled', N'Not Billed')
						 AND SubStatus IN (N'Entered Not Submitted', N'Entered Not Billed') THEN Cnt END), 0) AS L_D2,
		ISNULL(SUM(CASE WHEN NewStatus <> N'Billable' THEN Cnt END), 0) AS L_E,
		ISNULL(SUM(CASE WHEN NewStatus IN (N'Duplicate', N'Duplicates', N'Duplicate - Sample Resulted in Spector') THEN Cnt END), 0) AS L_F,
		ISNULL(SUM(CASE WHEN NewStatus = N'System Test' THEN Cnt END), 0) AS L_G,
		ISNULL(SUM(CASE WHEN NewStatus IN (N'Yet to Be Validate', N'Yet to be validated', N'Yet be validated')
						 AND SubStatus <> N'Entered Not Submitted' THEN Cnt END), 0) AS L_H
	INTO #LisM
	FROM #EsLis
	GROUP BY GROUPING SETS ((ESYear, ESMonth), (ESYear), ());

	DROP TABLE IF EXISTS #ClmM;
	SELECT
		ISNULL(ESYear, 0) AS Y,
		CASE WHEN GROUPING(ESMonth) = 1 THEN 0 ELSE ESMonth END AS M,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay')
						 AND ClaimStatus <> N'0 Billed Amount' THEN ClaimCnt END), 0) AS P_F,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Unbilled', N'Unbilled - Self Pay') THEN ClaimCnt END), 0) AS P_G,
		ISNULL(SUM(CASE WHEN BillStatus = N'Unbilled' AND ClaimStatus <> N'0 Billed Amount' THEN ClaimCnt END), 0) AS P_G1,
		ISNULL(SUM(CASE WHEN BillStatus = N'Unbilled - Self Pay' THEN ClaimCnt END), 0) AS P_G2,
		ISNULL(SUM(CASE WHEN BillStatus = N'Billed' AND ClaimStatus = N'0 Billed Amount' THEN ClaimCnt END), 0) AS P_G3,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Fully Paid' THEN ClaimCnt END), 0) AS P_I,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Patient Responsibility' THEN ClaimCnt END), 0) AS P_J,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Fully Adjusted' THEN ClaimCnt END), 0) AS P_K,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Partially Adjusted' THEN ClaimCnt END), 0) AS P_L,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Partially Paid' THEN ClaimCnt END), 0) AS P_M,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Patient Payment' THEN ClaimCnt END), 0) AS P_N,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay')
						 AND ClaimStatus IN (N'Fully Denied', N'No Response', N'Partially Denied') THEN ClaimCnt END), 0) AS P_O,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Fully Denied' THEN ClaimCnt END), 0) AS P_O1,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Partially Denied' THEN ClaimCnt END), 0) AS P_O2,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'No Response' THEN ClaimCnt END), 0) AS P_O3,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') THEN ChargeAmount END), 0) AS C_P,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Unbilled', N'Unbilled - Self Pay') THEN ChargeAmount END), 0) AS C_Q,
		ISNULL(SUM(CASE WHEN BillStatus = N'Unbilled' THEN ChargeAmount END), 0) AS C_Q1,
		ISNULL(SUM(CASE WHEN BillStatus = N'Unbilled - Self Pay' THEN ChargeAmount END), 0) AS C_Q2,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Fully Paid' THEN InsurancePayment END), 0) AS C_R,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') THEN PatientBalance END), 0) AS C_S,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') THEN TotalAdjustments END), 0) AS C_T,
		ISNULL(SUM(CASE WHEN ClaimStatus IN (N'Fully Adjusted', N'Partially Adjusted', N'Partially Denied', N'Partially Paid')
						 THEN InsurancePayment END), 0) AS C_U,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') THEN PatientPayment END), 0) AS C_V,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') THEN TotalInsuranceBalance END), 0) AS C_W,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'Fully Denied'
						 THEN TotalInsuranceBalance END), 0) AS C_W1,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus NOT IN (N'Fully Denied', N'No Response')
						 THEN TotalInsuranceBalance END), 0) AS C_W2,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') AND ClaimStatus = N'No Response'
						 THEN TotalInsuranceBalance END), 0) AS C_W3
	INTO #ClmM
	FROM #EsClaims
	GROUP BY GROUPING SETS ((ESYear, ESMonth), (ESYear), ());

	DROP TABLE IF EXISTS #Per;
	SELECT
		COALESCE(l.Y, c.Y) AS Y, COALESCE(l.M, c.M) AS M,
		ISNULL(l.L_A, 0) L_A, ISNULL(l.L_B, 0) L_B, ISNULL(l.L_C, 0) L_C, ISNULL(l.L_D, 0) L_D,
		ISNULL(l.L_D1, 0) L_D1, ISNULL(l.L_D2, 0) L_D2, ISNULL(l.L_E, 0) L_E, ISNULL(l.L_F, 0) L_F,
		ISNULL(l.L_G, 0) L_G, ISNULL(l.L_H, 0) L_H,
		ISNULL(c.P_F, 0) P_F, ISNULL(c.P_G, 0) P_G, ISNULL(c.P_G1, 0) P_G1, ISNULL(c.P_G2, 0) P_G2,
		ISNULL(c.P_G3, 0) P_G3, ISNULL(c.P_I, 0) P_I, ISNULL(c.P_J, 0) P_J, ISNULL(c.P_K, 0) P_K,
		ISNULL(c.P_L, 0) P_L, ISNULL(c.P_M, 0) P_M, ISNULL(c.P_N, 0) P_N, ISNULL(c.P_O, 0) P_O,
		ISNULL(c.P_O1, 0) P_O1, ISNULL(c.P_O2, 0) P_O2, ISNULL(c.P_O3, 0) P_O3,
		ISNULL(c.C_P, 0) C_P, ISNULL(c.C_Q, 0) C_Q, ISNULL(c.C_Q1, 0) C_Q1, ISNULL(c.C_Q2, 0) C_Q2,
		ISNULL(c.C_R, 0) C_R, ISNULL(c.C_S, 0) C_S, ISNULL(c.C_T, 0) C_T, ISNULL(c.C_U, 0) C_U,
		ISNULL(c.C_V, 0) C_V, ISNULL(c.C_W, 0) C_W, ISNULL(c.C_W1, 0) C_W1, ISNULL(c.C_W2, 0) C_W2,
		ISNULL(c.C_W3, 0) C_W3
	INTO #Per
	FROM #LisM l
	FULL OUTER JOIN #ClmM c ON c.Y = l.Y AND c.M = l.M;

	INSERT INTO #EsOut (Category, RowCode, Description, SortOrder, ESYear, ESMonth, MetricValue, ClaimCount)
	SELECT r.Category, r.RowCode, r.Description, r.SortOrder, p.Y, p.M,
		   CAST(r.MetricValue AS DECIMAL(18,2)), r.ClaimCount
	FROM #Per p
	CROSS APPLY (
		SELECT
			CAST(p.P_I + p.P_M AS DECIMAL(38,6)) AS PaidClaims,
			CAST(p.P_I + p.P_M + p.P_J + p.P_K + p.P_L + p.P_N + p.P_O1 + p.P_O2 AS DECIMAL(38,6)) AS AdjudicatedClaims
	) d
	CROSS APPLY (VALUES
		-- LIS Breakdown
		('LIS', 'A',  N'Total Samples',                     10, CAST(p.L_A  AS DECIMAL(38,6)), p.L_A),
		('LIS', 'B',  N'Billable Samples',                  20, p.L_B,  p.L_B),
		('LIS', 'C',  N'  Billed',                          30, p.L_C,  p.L_C),
		('LIS', 'C1', N'    Billed via CMD',                40, p.L_C,  p.L_C),
		('LIS', 'D',  N'  Unbilled',                        50, p.L_D,  p.L_D),
		('LIS', 'D1', N'    Ready to bill',                 60, p.L_D1, p.L_D1),
		('LIS', 'D2', N'    Entered Not Submitted',         70, p.L_D2, p.L_D2),
		('LIS', 'E',  N'Other Samples',                     80, p.L_E,  p.L_E),
		('LIS', 'F',  N'  Duplicates',                      90, p.L_F,  p.L_F),
		('LIS', 'G',  N'  System Test',                    100, p.L_G,  p.L_G),
		('LIS', 'H',  N'  Yet to be validated',            110, p.L_H,  p.L_H),
		-- PMS Breakdown
		('PMS', 'F',  N'No. of Billed Claims',                                           210, p.P_F,  p.P_F),
		('PMS', 'F1', N'  Claim Submitted in Collaborate MD',                            220, p.P_F,  p.P_F),
		('PMS', 'G',  N'No. of Unbilled Claims',                                         230, p.P_G,  p.P_G),
		('PMS', 'G1', N'  Unbilled',                                                     240, p.P_G1, p.P_G1),
		('PMS', 'G2', N'  Unbilled - Self Pay',                                          250, p.P_G2, p.P_G2),
		('PMS', 'G3', N'  Billed amount 0',                                              260, p.P_G3, p.P_G3),
		('PMS', 'H',  N'Billed Mismatches - Other samples billed / LIS Accessions NA',   270, p.P_F - p.L_C, p.P_F - p.L_C),
		('PMS', 'I',  N'No. of Fully Paid Claims',                                       280, p.P_I,  p.P_I),
		('PMS', 'J',  N'No. of Fully Patient Responsibility Claims',                     290, p.P_J,  p.P_J),
		('PMS', 'K',  N'No. of Adjusted/Written Off Claims',                             300, p.P_K,  p.P_K),
		('PMS', 'L',  N'No. of Partially Adjusted Claim',                                310, p.P_L,  p.P_L),
		('PMS', 'M',  N'No. of Partially Paid Claims',                                   320, p.P_M,  p.P_M),
		('PMS', 'N',  N'No. of Patient Paid Claims',                                     330, p.P_N,  p.P_N),
		('PMS', 'O',  N'No. of Insurance Balance Claims',                                340, p.P_O,  p.P_O),
		('PMS', 'O1', N'  No. of Fully Denied Claims',                                   350, p.P_O1, p.P_O1),
		('PMS', 'O2', N'  No. of Partially Denied Claims',                               360, p.P_O2, p.P_O2),
		('PMS', 'O3', N'  No. of No Response from Payor Claims',                         370, p.P_O3, p.P_O3),
		('PMS', 'O4', N'    Follow up note added',                                       380, 0,      0),
		-- Cash Breakdown
		('Cash', 'P',  N'Total Billed ($)',                     410, p.C_P,  0),
		('Cash', 'P1', N'  Claim Submitted in Collaborate MD',  420, p.C_P,  0),
		('Cash', 'Q',  N'Total Unbilled ($)',                   430, p.C_Q,  0),
		('Cash', 'Q1', N'  Unbilled',                           440, p.C_Q1, 0),
		('Cash', 'Q2', N'  Unbilled - Self Pay',                450, p.C_Q2, 0),
		('Cash', 'R',  N'Insurance Payment ($)',                460, p.C_R,  0),
		('Cash', 'S',  N'Patient Responsibility ($)',           470, p.C_S,  0),
		('Cash', 'T',  N'Adjustments / Write Off ($)',          480, p.C_T,  0),
		('Cash', 'U',  N'Partially Paid ($)',                   490, p.C_U,  0),
		('Cash', 'V',  N'Patient Paid ($)',                     500, p.C_V,  0),
		('Cash', 'W',  N'Insurance Balance ($)',                510, p.C_W,  0),
		('Cash', 'W1', N'  Fully Denials',                      520, p.C_W1, 0),
		('Cash', 'W2', N'  Partially Denied',                   530, p.C_W2, 0),
		('Cash', 'W3', N'  No Response from Payor',             540, p.C_W3, 0),
		-- Average Payment Per Claim
		('Avg', 'X', N'Average Payment ($) - Total Pay/Billed Claims',      610,
			ISNULL(ROUND((p.C_R + p.C_V) / NULLIF(CAST(p.P_F AS DECIMAL(38,6)), 0), 2), 0), p.P_F),
		('Avg', 'Y', N'Average Payment ($) - Total Pay/Paid Claims',        620,
			ISNULL(ROUND((p.C_R + p.C_U) / NULLIF(d.PaidClaims, 0), 2), 0), CAST(d.PaidClaims AS INT)),
		('Avg', 'Z', N'Average Payment ($) - Total Pay/Adjudicated Claims', 630,
			ISNULL(ROUND((p.C_R + p.C_U) / NULLIF(d.AdjudicatedClaims, 0), 2), 0), CAST(d.AdjudicatedClaims AS INT))
	) r(Category, RowCode, Description, SortOrder, MetricValue, ClaimCount);
END;
GO

IF OBJECT_ID(N'dbo.LisDrillRowDef', N'U') IS NOT NULL
BEGIN
    UPDATE dbo.LisDrillRowDef SET Col2 = N'ClaimStatus', Op2 = N'<>', Val2 = N'0 Billed Amount'
    WHERE LabPrefix = N'AnP' AND Source = N'PMS' AND RowCode IN (N'F', N'F1', N'G1');
END
GO

EXEC dbo.usp_RefreshAnP_ExecutiveSummary;
GO

SET NOEXEC OFF;
GO

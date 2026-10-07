/* =============================================================================
   Analyze Pathology - Executive Summary, client logic (LIS / PMS / Cash / Avg)
   Database : AnalyzePathology
   Replaces : 16 (usp_RefreshAnP_ExecutiveSummary), 17b (usp_GetAnP_ExecutiveSummary),
              19 (usp_RefreshAnP_ExecutiveSummary_LIS_Alt)

   Every value, the row order (SortOrder), the month / year (ESMonth = 0) and grand
   (0, 0) totals and the averages are produced here. The dashboard and the Excel
   exports render the rows in SortOrder and read the SP's totals.

   Columns : Date of Service month / year
               LIS        -> LIMSMaster.RequestCollectDate (one LIMS row = one sample)
               PMS / Cash -> ClaimLevelData.DateofService  (one claim row = one claim)
   "Billed"   = ClaimLevelData.BilledStatus IN ('Billed', 'Billed - Self Pay')
   "Unbilled" = BilledStatus IN ('Unbilled', 'Unbilled - Self Pay')
                (repeated spaces in BilledStatus are collapsed: the feed sends
                 'Unbilled -  Self Pay')

   LIS Breakdown
     A  Total Samples                 all samples
     B  Billable Samples              New Status = Billable
     C    Billed                      Billable AND Bill Category = Billed
     C1     Billed via CMD            same as C
     D    Unbilled                    Billable AND Bill Category = Unbilled
     D1     Ready to bill             D AND Sub Status = Ready to Bill
     D2     Entered Not Submitted     D AND Sub Status = Entered Not Submitted
     E  Other Samples                 New Status = Other Sample(s)
     F  Duplicates                    New Status = Duplicate(s)
     G  System Test                   New Status = System Test
     H  Yet to be validated           New Status = Yet to Be Validate AND Sub Status <> Entered Not Submitted
   PMS Breakdown
     F  No. of Billed Claims          Billed
     F1   Claim Submitted in Collaborate MD   same as F
     G  No. of Unbilled Claims        Unbilled
     G1   Unbilled                    Bill Status = Unbilled
     G2   Unbilled - Self Pay         Bill Status = Unbilled - Self Pay
     G3   Billed amount 0             Bill Status = Billed AND Claim Status = 0 Billed Amount
     H  Billed Mismatches             PMS F - LIS C
     I  Fully Paid                    Billed AND Fully Paid
     J  Fully Patient Responsibility  Billed AND Patient Responsibility
     K  Adjusted/Written Off          Billed AND Fully Adjusted
     L  Partially Adjusted            Billed AND Partially Adjusted
     M  Partially Paid                Billed AND Partially Paid
     N  Patient Paid                  Billed AND Patient Payment
     O  Insurance Balance             Billed AND (Fully Denied, No Response, Partially Denied)
     O1   Fully Denied / O2 Partially Denied / O3 No Response from Payor
     O4     Follow up note added      no logic supplied -> 0
   Cash Breakdown
     P  Total Billed ($)              SUM(ChargeAmount) Billed          (P1 same)
     Q  Total Unbilled ($)            SUM(ChargeAmount) Unbilled        (Q1 Unbilled, Q2 Unbilled - Self Pay)
     R  Insurance Payment ($)         SUM(InsurancePayment) Billed AND Fully Paid
     S  Patient Responsibility ($)    SUM(PatientBalance) Billed
     T  Adjustments / Write Off ($)   SUM(TotalAdjustments) Billed
     U  Partially Paid ($)            SUM(InsurancePayment = "Charge Insurance Payments")
                                      Claim Status IN (Fully Adjusted, Partially Adjusted, Partially Denied, Partially Paid)
     V  Patient Paid ($)              SUM(PatientPayment) Billed
     W  Insurance Balance ($)         SUM(TotalInsuranceBalance) Billed
     W1   Fully Denials               W AND Fully Denied
     W2   Partially Denied            W AND Claim Status NOT IN (Fully Denied, No Response)
     W3   No Response from Payor      W AND No Response
   Average Payment Per Claim
     X  (R + V) / F
     Y  (R + U) / (I + M)
     Z  (R + U) / (I + M + J + K + L + N + O1 + O2)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.AnP_ES_LIS',  'SortOrder') IS NULL ALTER TABLE dbo.AnP_ES_LIS  ADD SortOrder INT NULL;
IF COL_LENGTH('dbo.AnP_ES_PMS',  'SortOrder') IS NULL ALTER TABLE dbo.AnP_ES_PMS  ADD SortOrder INT NULL;
IF COL_LENGTH('dbo.AnP_ES_Cash', 'SortOrder') IS NULL ALTER TABLE dbo.AnP_ES_Cash ADD SortOrder INT NULL;
IF COL_LENGTH('dbo.AnP_ES_Avg',  'SortOrder') IS NULL ALTER TABLE dbo.AnP_ES_Avg  ADD SortOrder INT NULL;
GO

/* -----------------------------------------------------------------------------
   usp_AnP_ES_Compute - the single implementation of the row logic.
   The caller creates and fills:
     #EsLis    (ESYear, ESMonth, NewStatus, BillCategory, SubStatus, Cnt)
     #EsClaims (ESYear, ESMonth, BillStatus, ClaimStatus, ClaimCnt, ChargeAmount,
                InsurancePayment, PatientPayment, PatientBalance, TotalAdjustments,
                TotalInsuranceBalance)
   and creates the empty
     #EsOut    (Category, RowCode, Description, SortOrder, ESYear, ESMonth,
                MetricValue, ClaimCount)
   ----------------------------------------------------------------------------- */
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
						 AND SubStatus = N'Entered Not Submitted' THEN Cnt END), 0) AS L_D2,
		ISNULL(SUM(CASE WHEN NewStatus IN (N'Other Sample', N'Other Samples') THEN Cnt END), 0) AS L_E,
		ISNULL(SUM(CASE WHEN NewStatus IN (N'Duplicate', N'Duplicates') THEN Cnt END), 0) AS L_F,
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
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Billed', N'Billed - Self Pay') THEN ClaimCnt END), 0) AS P_F,
		ISNULL(SUM(CASE WHEN BillStatus IN (N'Unbilled', N'Unbilled - Self Pay') THEN ClaimCnt END), 0) AS P_G,
		ISNULL(SUM(CASE WHEN BillStatus = N'Unbilled' THEN ClaimCnt END), 0) AS P_G1,
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
		('LIS', 'F',  N'Duplicates',                        90, p.L_F,  p.L_F),
		('LIS', 'G',  N'System Test',                      100, p.L_G,  p.L_G),
		('LIS', 'H',  N'Yet to be validated',              110, p.L_H,  p.L_H),
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

/* -----------------------------------------------------------------------------
   Refresh: rebuilds AnP_ES_LIS / _PMS / _Cash / _Avg (all periods, no filters).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_ExecutiveSummary
AS
BEGIN
	SET NOCOUNT ON;
	SET XACT_ABORT ON;

	CREATE TABLE #EsLis
	(
		ESYear       INT           NOT NULL,
		ESMonth      INT           NOT NULL,
		NewStatus    NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		BillCategory NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		SubStatus    NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		Cnt          INT           NOT NULL
	);
	CREATE TABLE #EsClaims
	(
		ESYear                INT           NOT NULL,
		ESMonth               INT           NOT NULL,
		BillStatus            NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
		ClaimStatus           NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
		ClaimCnt              INT           NOT NULL,
		ChargeAmount          DECIMAL(18,2) NOT NULL,
		InsurancePayment      DECIMAL(18,2) NOT NULL,
		PatientPayment        DECIMAL(18,2) NOT NULL,
		PatientBalance        DECIMAL(18,2) NOT NULL,
		TotalAdjustments      DECIMAL(18,2) NOT NULL,
		TotalInsuranceBalance DECIMAL(18,2) NOT NULL
	);
	CREATE TABLE #EsOut
	(
		Category    VARCHAR(10)   NOT NULL,
		RowCode     NVARCHAR(20)  COLLATE DATABASE_DEFAULT NOT NULL,
		Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
		SortOrder   INT           NOT NULL,
		ESYear      INT           NOT NULL,
		ESMonth     INT           NOT NULL,
		MetricValue DECIMAL(18,2) NOT NULL,
		ClaimCount  INT           NOT NULL
	);

	INSERT INTO #EsLis (ESYear, ESMonth, NewStatus, BillCategory, SubStatus, Cnt)
	SELECT YEAR(d.Dos), MONTH(d.Dos),
		   ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
		   ISNULL(LTRIM(RTRIM(l.SubStatus)), N''),
		   COUNT(*)
	FROM dbo.LIMSMaster l
	CROSS APPLY (SELECT TRY_CAST(l.RequestCollectDate AS DATE) AS Dos) d
	WHERE d.Dos IS NOT NULL
	GROUP BY YEAR(d.Dos), MONTH(d.Dos),
			 ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
			 ISNULL(LTRIM(RTRIM(l.SubStatus)), N'');

	INSERT INTO #EsClaims (ESYear, ESMonth, BillStatus, ClaimStatus, ClaimCnt, ChargeAmount, InsurancePayment,
						   PatientPayment, PatientBalance, TotalAdjustments, TotalInsuranceBalance)
	SELECT YEAR(d.Dos), MONTH(d.Dos), n.BillStatus, n.ClaimStatus, COUNT(*),
		   SUM(ISNULL(TRY_CAST(c.ChargeAmount          AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.InsurancePayment      AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.PatientPayment        AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.PatientBalance        AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.TotalAdjustments      AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.TotalInsuranceBalance AS DECIMAL(18,2)), 0))
	FROM dbo.ClaimLevelData c
	CROSS APPLY (SELECT TRY_CAST(c.DateofService AS DATE) AS Dos) d
	CROSS APPLY (SELECT
		LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(ISNULL(c.BilledStatus, N''), N'  ', N' '), N'  ', N' '), N'  ', N' '))) AS BillStatus,
		ISNULL(LTRIM(RTRIM(c.ClaimStatus)), N'') AS ClaimStatus) n
	WHERE d.Dos IS NOT NULL
	GROUP BY YEAR(d.Dos), MONTH(d.Dos), n.BillStatus, n.ClaimStatus;

	EXEC dbo.usp_AnP_ES_Compute;

	BEGIN TRANSACTION;
		TRUNCATE TABLE dbo.AnP_ES_LIS;
		TRUNCATE TABLE dbo.AnP_ES_PMS;
		TRUNCATE TABLE dbo.AnP_ES_Cash;
		TRUNCATE TABLE dbo.AnP_ES_Avg;

		INSERT INTO dbo.AnP_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
		SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, 0, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'LIS';

		INSERT INTO dbo.AnP_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
		SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, 0, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'PMS';

		INSERT INTO dbo.AnP_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
		SELECT RowCode, Description, ESYear, ESMonth, 0, MetricValue, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'Cash';

		INSERT INTO dbo.AnP_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
		SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, MetricValue, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'Avg';
	COMMIT TRANSACTION;

	/* LIS Summary aggregate (script 26) follows the same LIMSMaster load, whichever
	   process runs this refresh. */
	IF OBJECT_ID(N'dbo.usp_RefreshAnP_LISSummary', N'P') IS NOT NULL
		EXEC dbo.usp_RefreshAnP_LISSummary;

	PRINT 'usp_RefreshAnP_ExecutiveSummary completed.';
END;
GO

/* The LIS rows are rebuilt by usp_RefreshAnP_ExecutiveSummary (row H of the PMS
   breakdown needs them in the same pass). Kept for the callers that run it after
   the main refresh; it only rebuilds when the LIS table is empty. */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_ExecutiveSummary_LIS_Alt
AS
BEGIN
	SET NOCOUNT ON;
	IF NOT EXISTS (SELECT 1 FROM dbo.AnP_ES_LIS)
		EXEC dbo.usp_RefreshAnP_ExecutiveSummary;
END;
GO

/* Row codes changed: the old version rewrote PMS 'I' (now Fully Paid). */
CREATE OR ALTER PROCEDURE dbo.usp_AnP_ES_UpdatePmsBilledMismatch
AS
BEGIN
	SET NOCOUNT ON;
	RETURN;
END;
GO

/* -----------------------------------------------------------------------------
   Read SP. Result: RowCode, Category, Description, BillYear, BillMonth,
   MetricValue, SortOrder - ordered by SortOrder. BillMonth = 0 is the year total,
   (0, 0) the grand total.
   No filter  -> aggregate tables.
   Filtered   -> same usp_AnP_ES_Compute over the filtered LIMSMaster / ClaimLevelData.
     DOS mode    : LIS by RequestCollectDate, claims by DateofService.
     Billed mode : (@BilledFrom/@BilledTo without DOS dates) LIS by BilledDate,
                   claims by FirstBilledDate.
     Panels / Clinics / Providers -> LIMSMaster PanelName / ClinicName / ReferringProvider
                                     and ClaimLevelData Panelname / ClinicName / ReferringProvider.
     Reps -> ClaimLevelData.SalesRepname only (LIMSMaster has no sales rep column).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_ExecutiveSummary
(
	@YearFrom   INT           = NULL,
	@YearTo     INT           = NULL,
	@MonthFrom  INT           = NULL,
	@MonthTo    INT           = NULL,
	@DosFrom    DATE          = NULL,
	@DosTo      DATE          = NULL,
	@BilledFrom DATE          = NULL,
	@BilledTo   DATE          = NULL,
	@Panels     NVARCHAR(MAX) = NULL,
	@Clinics    NVARCHAR(MAX) = NULL,
	@Providers  NVARCHAR(MAX) = NULL,
	@Reps       NVARCHAR(MAX) = NULL
)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @Filters TABLE (Dim VARCHAR(10) NOT NULL, Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	INSERT INTO @Filters (Dim, Val)
	SELECT f.Dim, LTRIM(RTRIM(s.value))
	FROM (VALUES ('Panel', @Panels), ('Clinic', @Clinics), ('Provider', @Providers), ('Rep', @Reps)) f(Dim, Vals)
	CROSS APPLY STRING_SPLIT(ISNULL(f.Vals, N''), N',') s
	WHERE LTRIM(RTRIM(s.value)) <> N'';

	DECLARE @HasPanel    BIT = CASE WHEN EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Panel')    THEN 1 ELSE 0 END;
	DECLARE @HasClinic   BIT = CASE WHEN EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Clinic')   THEN 1 ELSE 0 END;
	DECLARE @HasProvider BIT = CASE WHEN EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Provider') THEN 1 ELSE 0 END;
	DECLARE @HasRep      BIT = CASE WHEN EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Rep')      THEN 1 ELSE 0 END;

	IF @YearFrom IS NULL AND @YearTo IS NULL AND @MonthFrom IS NULL AND @MonthTo IS NULL
	   AND @DosFrom IS NULL AND @DosTo IS NULL AND @BilledFrom IS NULL AND @BilledTo IS NULL
	   AND @HasPanel = 0 AND @HasClinic = 0 AND @HasProvider = 0 AND @HasRep = 0
	BEGIN
		SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue, SortOrder
		FROM
		(
			SELECT RoleID AS RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue, ISNULL(SortOrder, 9999) AS SortOrder
			FROM dbo.AnP_ES_LIS
			UNION ALL
			SELECT RoleID, 'PMS', Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2)), ISNULL(SortOrder, 9999)
			FROM dbo.AnP_ES_PMS
			UNION ALL
			SELECT RoleID, 'Cash', Description, ESYear, ESMonth, ESMonthChargeAmount, ISNULL(SortOrder, 9999)
			FROM dbo.AnP_ES_Cash
			UNION ALL
			SELECT RoleID, 'Avg', Description, ESYear, ESMonth, ESMonthChargeAmount, ISNULL(SortOrder, 9999)
			FROM dbo.AnP_ES_Avg
		) t
		ORDER BY SortOrder, BillYear, BillMonth;
		RETURN;
	END;

	DECLARE @UseBilledDate BIT = CASE WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
										AND @DosFrom IS NULL AND @DosTo IS NULL THEN 1 ELSE 0 END;
	DECLARE @From DATE = CASE WHEN @UseBilledDate = 1 THEN @BilledFrom ELSE @DosFrom END;
	DECLARE @To   DATE = CASE WHEN @UseBilledDate = 1 THEN @BilledTo   ELSE @DosTo   END;

	CREATE TABLE #EsLis
	(
		ESYear       INT           NOT NULL,
		ESMonth      INT           NOT NULL,
		NewStatus    NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		BillCategory NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		SubStatus    NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
		Cnt          INT           NOT NULL
	);
	CREATE TABLE #EsClaims
	(
		ESYear                INT           NOT NULL,
		ESMonth               INT           NOT NULL,
		BillStatus            NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
		ClaimStatus           NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
		ClaimCnt              INT           NOT NULL,
		ChargeAmount          DECIMAL(18,2) NOT NULL,
		InsurancePayment      DECIMAL(18,2) NOT NULL,
		PatientPayment        DECIMAL(18,2) NOT NULL,
		PatientBalance        DECIMAL(18,2) NOT NULL,
		TotalAdjustments      DECIMAL(18,2) NOT NULL,
		TotalInsuranceBalance DECIMAL(18,2) NOT NULL
	);
	CREATE TABLE #EsOut
	(
		Category    VARCHAR(10)   NOT NULL,
		RowCode     NVARCHAR(20)  COLLATE DATABASE_DEFAULT NOT NULL,
		Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
		SortOrder   INT           NOT NULL,
		ESYear      INT           NOT NULL,
		ESMonth     INT           NOT NULL,
		MetricValue DECIMAL(18,2) NOT NULL,
		ClaimCount  INT           NOT NULL
	);

	INSERT INTO #EsLis (ESYear, ESMonth, NewStatus, BillCategory, SubStatus, Cnt)
	SELECT YEAR(d.PeriodDate), MONTH(d.PeriodDate),
		   ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
		   ISNULL(LTRIM(RTRIM(l.SubStatus)), N''),
		   COUNT(*)
	FROM dbo.LIMSMaster l
	CROSS APPLY (SELECT CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(l.BilledDate AS DATE)
							 ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate) d
	WHERE d.PeriodDate IS NOT NULL
	  AND (@From      IS NULL OR d.PeriodDate >= @From)
	  AND (@To        IS NULL OR d.PeriodDate <= @To)
	  AND (@YearFrom  IS NULL OR YEAR(d.PeriodDate)  >= @YearFrom)
	  AND (@YearTo    IS NULL OR YEAR(d.PeriodDate)  <= @YearTo)
	  AND (@MonthFrom IS NULL OR MONTH(d.PeriodDate) >= @MonthFrom)
	  AND (@MonthTo   IS NULL OR MONTH(d.PeriodDate) <= @MonthTo)
	  AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(l.PanelName, N'')))         IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(l.ClinicName, N'')))        IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(l.ReferringProvider, N''))) IN (SELECT Val FROM @Filters WHERE Dim = 'Provider'))
	GROUP BY YEAR(d.PeriodDate), MONTH(d.PeriodDate),
			 ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
			 ISNULL(LTRIM(RTRIM(l.SubStatus)), N'')
	OPTION (RECOMPILE);

	INSERT INTO #EsClaims (ESYear, ESMonth, BillStatus, ClaimStatus, ClaimCnt, ChargeAmount, InsurancePayment,
						   PatientPayment, PatientBalance, TotalAdjustments, TotalInsuranceBalance)
	SELECT YEAR(d.PeriodDate), MONTH(d.PeriodDate), n.BillStatus, n.ClaimStatus, COUNT(*),
		   SUM(ISNULL(TRY_CAST(c.ChargeAmount          AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.InsurancePayment      AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.PatientPayment        AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.PatientBalance        AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.TotalAdjustments      AS DECIMAL(18,2)), 0)),
		   SUM(ISNULL(TRY_CAST(c.TotalInsuranceBalance AS DECIMAL(18,2)), 0))
	FROM dbo.ClaimLevelData c
	CROSS APPLY (SELECT CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(c.FirstBilledDate AS DATE)
							 ELSE TRY_CAST(c.DateofService AS DATE) END AS PeriodDate) d
	CROSS APPLY (SELECT
		LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(ISNULL(c.BilledStatus, N''), N'  ', N' '), N'  ', N' '), N'  ', N' '))) AS BillStatus,
		ISNULL(LTRIM(RTRIM(c.ClaimStatus)), N'') AS ClaimStatus) n
	WHERE d.PeriodDate IS NOT NULL
	  AND (@From      IS NULL OR d.PeriodDate >= @From)
	  AND (@To        IS NULL OR d.PeriodDate <= @To)
	  AND (@YearFrom  IS NULL OR YEAR(d.PeriodDate)  >= @YearFrom)
	  AND (@YearTo    IS NULL OR YEAR(d.PeriodDate)  <= @YearTo)
	  AND (@MonthFrom IS NULL OR MONTH(d.PeriodDate) >= @MonthFrom)
	  AND (@MonthTo   IS NULL OR MONTH(d.PeriodDate) <= @MonthTo)
	  AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(c.Panelname, N'')))         IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(c.ClinicName, N'')))        IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(c.ReferringProvider, N''))) IN (SELECT Val FROM @Filters WHERE Dim = 'Provider'))
	  AND (@HasRep      = 0 OR LTRIM(RTRIM(ISNULL(c.SalesRepname, N'')))      IN (SELECT Val FROM @Filters WHERE Dim = 'Rep'))
	GROUP BY YEAR(d.PeriodDate), MONTH(d.PeriodDate), n.BillStatus, n.ClaimStatus
	OPTION (RECOMPILE);

	EXEC dbo.usp_AnP_ES_Compute;

	SELECT RowCode, Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
		   CASE WHEN Category IN ('Cash', 'Avg') THEN MetricValue ELSE CAST(ClaimCount AS DECIMAL(18,2)) END AS MetricValue,
		   SortOrder
	FROM #EsOut
	ORDER BY SortOrder, ESYear, ESMonth;
END;
GO

/* -----------------------------------------------------------------------------
   Insight drill-through definitions for the new row codes (Year / Grand Total
   cells). PMS H and the averages are derived, so they have no row filter.
   ----------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.LisDrillRowDef', N'U') IS NOT NULL
BEGIN
	DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'AnP';

	INSERT INTO dbo.LisDrillRowDef
		(LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
		 Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3)
	VALUES
	-- LIS (LIMSMaster, Date of Service = RequestCollectDate)
	(N'AnP', N'A',  N'Total Samples',         N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'<>', N'', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'B',  N'Billable Samples',      N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Billable', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'C',  N'Billed',                N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Billable', N'BillCategory', N'=', N'Billed', NULL, NULL, NULL),
	(N'AnP', N'D',  N'Unbilled',              N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Billable', N'BillCategory', N'=', N'Unbilled', NULL, NULL, NULL),
	(N'AnP', N'E',  N'Other Samples',         N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'IN', N'Other Sample,Other Samples', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'F',  N'Duplicates',            N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'IN', N'Duplicate,Duplicates', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'G',  N'System Test',           N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'System Test', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'H',  N'Yet to be validated',   N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'IN', N'Yet to Be Validate,Yet to be validated', N'SubStatus', N'<>', N'Entered Not Submitted', NULL, NULL, NULL),
	-- PMS (ClaimLevelData, DateofService)
	(N'AnP', N'F',  N'No. of Billed Claims',                         N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'F1', N'Claim Submitted in Collaborate MD',            N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'G',  N'No. of Unbilled Claims',                       N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Unbilled,Unbilled - Self Pay,Unbilled -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'G1', N'Unbilled',                                     N'DateofService', N'PMS', NULL, N'BilledStatus', N'=', N'Unbilled', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'G2', N'Unbilled - Self Pay',                          N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Unbilled - Self Pay,Unbilled -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'G3', N'Billed amount 0',                              N'DateofService', N'PMS', NULL, N'BilledStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'0 Billed Amount', NULL, NULL, NULL),
	(N'AnP', N'I',  N'No. of Fully Paid Claims',                     N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Fully Paid', NULL, NULL, NULL),
	(N'AnP', N'J',  N'No. of Fully Patient Responsibility Claims',   N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Patient Responsibility', NULL, NULL, NULL),
	(N'AnP', N'K',  N'No. of Adjusted/Written Off Claims',           N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Fully Adjusted', NULL, NULL, NULL),
	(N'AnP', N'L',  N'No. of Partially Adjusted Claim',              N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Partially Adjusted', NULL, NULL, NULL),
	(N'AnP', N'M',  N'No. of Partially Paid Claims',                 N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Partially Paid', NULL, NULL, NULL),
	(N'AnP', N'N',  N'No. of Patient Paid Claims',                   N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Patient Payment', NULL, NULL, NULL),
	(N'AnP', N'O',  N'No. of Insurance Balance Claims',              N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Denied', NULL, NULL, NULL),
	(N'AnP', N'O1', N'No. of Fully Denied Claims',                   N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Fully Denied', NULL, NULL, NULL),
	(N'AnP', N'O2', N'No. of Partially Denied Claims',               N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Partially Denied', NULL, NULL, NULL),
	(N'AnP', N'O3', N'No. of No Response from Payor Claims',         N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'No Response', NULL, NULL, NULL),
	-- Cash (ClaimLevelData dollar SUM of AmountCol)
	(N'AnP', N'P',  N'Total Billed ($)',                    N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'P1', N'Claim Submitted in Collaborate MD',   N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'Q',  N'Total Unbilled ($)',                  N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Unbilled,Unbilled - Self Pay,Unbilled -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'Q1', N'Unbilled',                            N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'=', N'Unbilled', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'Q2', N'Unbilled - Self Pay',                 N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Unbilled - Self Pay,Unbilled -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'R',  N'Insurance Payment ($)',               N'DateofService', N'Cash', N'InsurancePayment',      N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Fully Paid', NULL, NULL, NULL),
	(N'AnP', N'S',  N'Patient Responsibility ($)',          N'DateofService', N'Cash', N'PatientBalance',        N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'T',  N'Adjustments / Write Off ($)',         N'DateofService', N'Cash', N'TotalAdjustments',      N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'U',  N'Partially Paid ($)',                  N'DateofService', N'Cash', N'InsurancePayment',      N'ClaimStatus', N'IN', N'Fully Adjusted,Partially Adjusted,Partially Denied,Partially Paid', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'V',  N'Patient Paid ($)',                    N'DateofService', N'Cash', N'PatientPayment',        N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'W',  N'Insurance Balance ($)',               N'DateofService', N'Cash', N'TotalInsuranceBalance', N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
	(N'AnP', N'W1', N'Fully Denials',                       N'DateofService', N'Cash', N'TotalInsuranceBalance', N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'Fully Denied', NULL, NULL, NULL),
	(N'AnP', N'W2', N'Partially Denied',                    N'DateofService', N'Cash', N'TotalInsuranceBalance', N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'NOT IN', N'Fully Denied,No Response', NULL, NULL, NULL),
	(N'AnP', N'W3', N'No Response from Payor',              N'DateofService', N'Cash', N'TotalInsuranceBalance', N'BilledStatus', N'IN', N'Billed,Billed - Self Pay', N'ClaimStatus', N'=', N'No Response', NULL, NULL, NULL);
END;
GO

EXEC dbo.usp_RefreshAnP_ExecutiveSummary;
GO

PRINT '27_AnalyzePathology_ExecutiveSummary_NewLogic.sql completed.';
GO

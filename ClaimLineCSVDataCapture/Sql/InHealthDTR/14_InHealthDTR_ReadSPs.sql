-- InHealthDTR — Read Stored Procedures for the Production Summary Report tabs.
-- Called by LabMetricsDashboard.SqlLabProductionSummaryRepository.
--
-- Each SP supports two execution paths:
--   1) NO filter parameters supplied  -> return rows from the pre-aggregated snapshot
--      table (fast path).
--   2) ANY filter parameter supplied  -> aggregate live from dbo.ClaimLevelData /
--      dbo.LineLevelData using the same filter semantics as the Refresh SPs.
--
-- List parameters use '|' as the delimiter so payer/panel names that contain
-- commas are passed safely.
--
-- Source routing notes (InHealthDTR structure):
--   ClaimLevelData : has PayerName_Raw, Panelname, FirstBilledDate,
--                    ChargeEnteredDate, ChargeAmount, ClaimID, Aging
--   LineLevelData  : has individual CPTCode/Units/Modifier,
--                    FirstBilledDate, ChargeEnteredDate, ChargeAmount
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Monthly Billed Production Summary
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_MonthlyBilledProductionSummary
	@PayerNames      NVARCHAR(MAX) = NULL,
	@PanelNames      NVARCHAR(MAX) = NULL,
	@DosFrom         DATE          = NULL,
	@DosTo           DATE          = NULL,
	@FirstBillFrom   DATE          = NULL,
	@FirstBillTo     DATE          = NULL,
	@FirstBilledFrom DATE          = NULL,
	@FirstBilledTo   DATE          = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
			WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
			WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
			WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
			ELSE 0
		END;

	IF @HasFilter = 0
	BEGIN
		SELECT  PanelType AS PanelName,
				PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges
		FROM    dbo.InH_MonthlyBilledProductionSummary
		ORDER BY PanelName, BilledYearMonth, PayerRank;
		RETURN;
	END

	DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
		INSERT INTO @PayerList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
		INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
	DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

	;WITH Agg AS (
		SELECT
			LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))         AS Panelname,
			LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))         AS PayerName_Raw,
			FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
			COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
			ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
		FROM   dbo.ClaimLevelData
		WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
		  AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
		  AND  PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
		  AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
		  AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
		  AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
		  AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
		  AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
		  AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
		  AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
		  AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
		  AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
		GROUP BY
			LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
			LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
			FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
	),
	Ranks AS (
		SELECT  Panelname, PayerName_Raw,
				DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
		FROM    Agg GROUP BY Panelname, PayerName_Raw
	),
	PanelTotal AS (
		SELECT  Panelname, BilledYearMonth, SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
		FROM    Agg GROUP BY Panelname, BilledYearMonth
	)
	SELECT
		'All Payers'      AS PayerName,
		0                 AS PayerRank,
		pt.Panelname      AS PanelName,
		pt.BilledYearMonth,
		pt.ClaimCount,
		pt.TotalCharges
	FROM   PanelTotal pt
	UNION ALL
	SELECT
		a.PayerName_Raw,
		r.PayerRank,
		a.Panelname,
		a.BilledYearMonth,
		a.ClaimCount,
		a.TotalCharges
	FROM   Agg a
	JOIN   Ranks r ON a.Panelname = r.Panelname AND a.PayerName_Raw = r.PayerName_Raw
	ORDER BY PanelName, BilledYearMonth, PayerRank;
END
GO

-- ============================================================
-- Weekly Billed Production Summary
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_WeeklyBilledProductionSummary
	@PayerNames      NVARCHAR(MAX) = NULL,
	@PanelNames      NVARCHAR(MAX) = NULL,
	@DosFrom         DATE          = NULL,
	@DosTo           DATE          = NULL,
	@FirstBillFrom   DATE          = NULL,
	@FirstBillTo     DATE          = NULL,
	@FirstBilledFrom DATE          = NULL,
	@FirstBilledTo   DATE          = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
			WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
			WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
			WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
			ELSE 0
		END;

	IF @HasFilter = 0
	BEGIN
		SELECT  PanelType AS PanelName,
				PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
		FROM    dbo.InH_WeeklyBilledProductionSummary
		ORDER BY PanelName, WeekStart, PayerRank;
		RETURN;
	END

	DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
		INSERT INTO @PayerList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
		INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
	DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

	;WITH WeeklyAgg AS (
		SELECT
			LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS Panelname,
			LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName_Raw,
			CAST(DATEADD(day,
				-(DATEDIFF(day, '1900-01-01', TRY_CAST(ChargeEnteredDate AS DATE)) % 7),
				TRY_CAST(ChargeEnteredDate AS DATE)) AS DATE) AS WeekStart,
			COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))      AS ClaimCount,
			ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
		FROM   dbo.ClaimLevelData
		WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
		  AND  LTRIM(RTRIM(FirstBilledDate)) <> ''
		  AND  TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
		  AND  PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
		  AND  (@HasPayerFilter   = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
		  AND  (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
		  AND  (@DosFrom          IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
		  AND  (@DosTo            IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
		  AND  (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
		  AND  (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
		  AND  (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
		  AND  (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
		GROUP BY
			LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))),
			LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
			CAST(DATEADD(day,
				-(DATEDIFF(day, '1900-01-01', TRY_CAST(ChargeEnteredDate AS DATE)) % 7),
				TRY_CAST(ChargeEnteredDate AS DATE)) AS DATE)
	)
	SELECT
		Panelname,
		PayerName_Raw,
		WeekStart,
		DATEADD(day, 6, WeekStart) AS WeekEnd,
		CONVERT(NVARCHAR(10), WeekStart, 23) + N' - ' + CONVERT(NVARCHAR(10), DATEADD(day, 6, WeekStart), 23) AS WeekLabel,
		ClaimCount,
		TotalCharges
	INTO #Weekly
	FROM WeeklyAgg;

	;WITH WeekRanks AS (
		SELECT  Panelname, PayerName_Raw,
				DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
		FROM    #Weekly GROUP BY Panelname, PayerName_Raw
	),
	WeekPanelTotal AS (
		SELECT  Panelname, WeekStart, WeekEnd, WeekLabel,
				SUM(ClaimCount) AS ClaimCount, SUM(TotalCharges) AS TotalCharges
		FROM    #Weekly GROUP BY Panelname, WeekStart, WeekEnd, WeekLabel
	)
	SELECT
		'All Payers'      AS PayerName,
		0                 AS PayerRank,
		wpt.Panelname     AS PanelName,
		wpt.WeekStart,
		wpt.WeekEnd,
		wpt.WeekLabel,
		wpt.ClaimCount,
		wpt.TotalCharges
	FROM   WeekPanelTotal wpt
	UNION ALL
	SELECT
		w.PayerName_Raw,
		wr.PayerRank,
		w.Panelname,
		w.WeekStart,
		w.WeekEnd,
		w.WeekLabel,
		w.ClaimCount,
		w.TotalCharges
	FROM   #Weekly w
	JOIN   WeekRanks wr ON w.Panelname = wr.Panelname AND w.PayerName_Raw = wr.PayerName_Raw
	ORDER BY PanelName, WeekStart, PayerRank;

	DROP TABLE IF EXISTS #Weekly;
END
GO

-- ============================================================
-- Payer Breakdown
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_PayerBreakdown
	@PayerNames      NVARCHAR(MAX) = NULL,
	@PanelNames      NVARCHAR(MAX) = NULL,
	@DosFrom         DATE          = NULL,
	@DosTo           DATE          = NULL,
	@FirstBillFrom   DATE          = NULL,
	@FirstBillTo     DATE          = NULL,
	@FirstBilledFrom DATE          = NULL,
	@FirstBilledTo   DATE          = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
			WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
			WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
			WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
			ELSE 0
		END;

	IF @HasFilter = 0
	BEGIN
		SELECT  PayerName, BilledYearMonth, ClaimCount, TotalCharges
		FROM    dbo.InH_PayerBreakdown
		ORDER BY PayerName, BilledYearMonth;
		RETURN;
	END

	DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
		INSERT INTO @PayerList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
		INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
	DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

	SELECT
		LTRIM(RTRIM(PayerName_Raw))                             AS PayerName_Raw,
		FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM') AS BilledYearMonth,
		COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))       AS ClaimCount,
		ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(ChargeEnteredDate)) <> ''
	  AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
	  AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
	  AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
	  AND (@DosFrom        IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
	  AND (@DosTo          IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
	  AND (@FirstBillFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
	  AND (@FirstBillTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
	  AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
	  AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
	GROUP BY
		LTRIM(RTRIM(PayerName_Raw)),
		FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
	ORDER BY PayerName_Raw, BilledYearMonth;
END
GO

-- ============================================================
-- Payer by Panel
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_PayerByPanel
	@PayerNames      NVARCHAR(MAX) = NULL,
	@PanelNames      NVARCHAR(MAX) = NULL,
	@DosFrom         DATE          = NULL,
	@DosTo           DATE          = NULL,
	@FirstBillFrom   DATE          = NULL,
	@FirstBillTo     DATE          = NULL,
	@FirstBilledFrom DATE          = NULL,
	@FirstBilledTo   DATE          = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
			WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
			WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
			WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
			ELSE 0
		END;

	IF @HasFilter = 0
	BEGIN
		SELECT  PayerName, PanelType, ClaimCount, TotalCharges
		FROM    dbo.InH_PayerByPanel
		ORDER BY PayerName, PanelType;
		RETURN;
	END

	DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
		INSERT INTO @PayerList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
		INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
	DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

	SELECT
		LTRIM(RTRIM(PayerName_Raw))                                                      AS PayerName_Raw,
		LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))      AS Panelname,
		COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                AS ClaimCount,
		ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(ChargeEnteredDate)) <> ''
	  AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
	  AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
	  AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
	  AND (@DosFrom        IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
	  AND (@DosTo          IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
	  AND (@FirstBillFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
	  AND (@FirstBillTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
	  AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
	  AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
	GROUP BY
		LTRIM(RTRIM(PayerName_Raw)),
		LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))
	ORDER BY PayerName_Raw, Panelname;
END
GO

-- ============================================================
-- Coding Breakdown
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_GetInH_CodingBreakdown
	@PayerNames      NVARCHAR(MAX) = NULL,
	@PanelNames      NVARCHAR(MAX) = NULL,
	@DosFrom         DATE          = NULL,
	@DosTo           DATE          = NULL,
	@FirstBillFrom   DATE          = NULL,
	@FirstBillTo     DATE          = NULL,
	@FirstBilledFrom DATE          = NULL,
	@FirstBilledTo   DATE          = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
			WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
			WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
			WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
			ELSE 0
		END;

	IF @HasFilter = 0
	BEGIN
		SELECT  PanelName, ClaimCount, TotalCharges
		FROM    dbo.InH_CodingPanelSummary
		ORDER BY TotalCharges DESC;

		SELECT  PanelName, CPTCode AS CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
		FROM    dbo.InH_CodingCPTDetail
		ORDER BY PanelName, TotalCharges DESC;
		RETURN;
	END

	DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
		INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

	SELECT
		LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) AS Panelname,
		LTRIM(RTRIM(ISNULL(CPTCode, '')))                                            AS CPTDetail,
		COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS VisitKey,
		TRY_CAST(ChargeAmount AS DECIMAL(18,2))                                      AS Charge
	INTO #Raw
	FROM dbo.LineLevelData
	WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
	  AND LTRIM(RTRIM(FirstBilledDate)) <> ''
	  AND (@HasPanelFilter   = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))) IN (SELECT Value FROM @PanelList))
	  AND (@DosFrom          IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
	  AND (@DosTo            IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
	  AND (@FirstBillFrom    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
	  AND (@FirstBillTo      IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
	  AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
	  AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo);

	SELECT  Panelname AS PanelName, COUNT(DISTINCT VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
	FROM    #Raw GROUP BY Panelname ORDER BY TotalCharges DESC;

	SELECT  Panelname AS PanelName, CPTDetail AS CPTCodeXUnitsXModifier,
			COUNT(DISTINCT VisitKey) AS ClaimCount, ISNULL(SUM(Charge), 0) AS TotalCharges
	FROM    #Raw WHERE CPTDetail <> '' GROUP BY Panelname, CPTDetail ORDER BY PanelName, TotalCharges DESC;

	DROP TABLE IF EXISTS #Raw;
END
GO

-- ============================================================
-- Unbilled Aging
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_UnbilledAging
	@PayerNames      NVARCHAR(MAX) = NULL,
	@PanelNames      NVARCHAR(MAX) = NULL,
	@DosFrom         DATE          = NULL,
	@DosTo           DATE          = NULL,
	@FirstBillFrom   DATE          = NULL,
	@FirstBillTo     DATE          = NULL,
	@FirstBilledFrom DATE          = NULL,
	@FirstBilledTo   DATE          = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
			WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
			WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
			WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
			ELSE 0
		END;

	IF @HasFilter = 0
	BEGIN
		SELECT  PanelName, Aging, ClaimCount, TotalCharges
		FROM    dbo.InH_UnbilledAging
		ORDER BY PanelName, Aging;
		RETURN;
	END

	DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
		INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

	SELECT
		LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)')))     AS Panelname,
		ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')                                           AS Aging,
		COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                AS ClaimCount,
		ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)                          AS TotalCharges
	FROM dbo.ClaimLevelData
	WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
	  AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
	  AND (@DosFrom        IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
	  AND (@DosTo          IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
	  AND (@FirstBillFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
	  AND (@FirstBillTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
	  AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
	  AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
	GROUP BY
		LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(No Panelname)'))),
		ISNULL(LTRIM(RTRIM(Aging)), 'Unknown')
	ORDER BY Panelname, Aging;
END
GO

-- ============================================================
-- CPT Breakdown
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_CPTBreakdown
	@PayerNames      NVARCHAR(MAX) = NULL,
	@PanelNames      NVARCHAR(MAX) = NULL,
	@DosFrom         DATE          = NULL,
	@DosTo           DATE          = NULL,
	@FirstBillFrom   DATE          = NULL,
	@FirstBillTo     DATE          = NULL,
	@FirstBilledFrom DATE          = NULL,
	@FirstBilledTo   DATE          = NULL
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
			WHEN @DosFrom         IS NOT NULL OR @DosTo         IS NOT NULL THEN 1
			WHEN @FirstBillFrom   IS NOT NULL OR @FirstBillTo   IS NOT NULL THEN 1
			WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
			ELSE 0
		END;

	IF @HasFilter = 0
	BEGIN
		SELECT  CPTCode, BilledYearMonth, LineCount, BilledUnits, TotalCharges
		FROM    dbo.InH_CPTBreakdown
		ORDER BY CPTCode, BilledYearMonth;
		RETURN;
	END

	DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
	IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
		INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
	DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

	SELECT
		LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown')))                        AS CPTCode,
		FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')          AS BilledYearMonth,
		COUNT(*)                                                         AS LineCount,
		ISNULL(SUM(TRY_CAST(Units        AS DECIMAL(18,2))), 0)         AS BilledUnits,
		ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0)         AS TotalCharges
	FROM dbo.LineLevelData
	WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''
	  AND NULLIF(LTRIM(RTRIM(CPTCode)), '') IS NOT NULL
	  AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
	  AND (@DosFrom        IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
	  AND (@DosTo          IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
	  AND (@FirstBillFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
	  AND (@FirstBillTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
	  AND (@FirstBilledFrom  IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
	  AND (@FirstBilledTo    IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
	GROUP BY
		LTRIM(RTRIM(ISNULL(CPTCode, 'Unknown'))),
		FORMAT(TRY_CAST(ChargeEnteredDate AS DATE), 'yyyy-MM')
	ORDER BY CPTCode, BilledYearMonth;
END
GO

PRINT '14_InHealthDTR_ReadSPs.sql completed.';

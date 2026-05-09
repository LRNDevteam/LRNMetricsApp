-- ============================================================
-- Augustus Labs — Weekly Claim Production Billed Summary
-- Rule:
--   Filter  : TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
--             AND TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : PanelNew  x  Top 3 Payer (by claim count, per PanelNew)
--   Columns : ChargeEnteredDate week range (Mon–Sun), last 4 complete weeks
--   Note    : No PayerName_Raw NULL exclusion.
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table  (same structure as NW; PanelType stores PanelNew value)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Aug_WeeklyBilledProductionSummary')
CREATE TABLE dbo.Aug_WeeklyBilledProductionSummary
(
    SummaryId   INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType   NVARCHAR(MAX)   NOT NULL,   -- stores PanelNew value
    PayerName   NVARCHAR(500)   NOT NULL,
    PayerRank   TINYINT         NOT NULL,   -- 1 / 2 / 3 within the PanelNew
    WeekStart   DATE            NOT NULL,   -- Monday
    WeekEnd     DATE            NOT NULL,   -- Sunday
    WeekLabel   NVARCHAR(32)    NOT NULL,   -- 'yyyy-MM-dd - yyyy-MM-dd'
    ClaimCount  INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- Week boundary: Mon–Sun.
    -- Reference Monday: 1900-01-01.
		DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
		DECLARE @ThisWeekMonStart DATE;
		DECLARE @DateFromData     DATE;

		-- ✅ Mon–Sun week anchor: 1900-01-01 is a known Monday
		SELECT
			@DateFromData      = MAX(TRY_CAST(ChargeEnteredDate AS DATE)),
			@ThisWeekMonStart  = DATEADD(day,
				-(DATEDIFF(day, '1900-01-01', ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today)) % 7),
				ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today))
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
		  AND TRY_CAST(ChargeEnteredDate AS DATE) <= @Today;

		-- ✅ If max date >= Sunday of current week → current week is complete → start from 0
		-- Otherwise current week is incomplete → start from 1 (last complete week)
		DECLARE @StartIndex INT = CASE
			WHEN @DateFromData >= DATEADD(day, 6, @ThisWeekMonStart) THEN 0   -- ← current week complete (Sun)
			ELSE 1                                                             -- ← current week incomplete
		END;

		DECLARE @i INT = @StartIndex;
		CREATE TABLE #Weeks
		(
			WeekIndex INT PRIMARY KEY,
			WeekStart DATE,
			WeekEnd   DATE,
			WeekLabel NVARCHAR(32)
		);

		WHILE @i <= @StartIndex + 3   -- ← always 4 weeks
		BEGIN
			DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekMonStart);
			DECLARE @we DATE = DATEADD(day, 6, @ws);   -- Mon + 6 = Sun
			INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
			VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
			SET @i = @i + 1;
		END
    -- Aggregate by PanelNew × PayerName_Raw × week, filtered by ChargeEnteredDate.
    SELECT
        LTRIM(RTRIM(ISNULL(cl.PanelNew,      'Unknown')))       AS PanelNew,
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))       AS PayerName_Raw,
        w.WeekStart,
        w.WeekEnd,
        w.WeekLabel,
        COUNT(*)                                                 AS ClaimCount,
        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))),0) AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData cl
    JOIN #Weeks w ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
    WHERE TRY_CAST(cl.FirstBilledDate   AS DATE) IS NOT NULL and cl.FirstBilledDate <>''
        --AND TRY_CAST(cl.ChargeEnteredDate AS DATE) IS NOT NULL
        --AND NULLIF(LTRIM(RTRIM(cl.PanelNew)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(cl.PanelNew,      'Unknown'))),
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
        w.WeekStart, w.WeekEnd, w.WeekLabel;

    -- Rank payers within each PanelNew (Top 3) across the 4-week window.
    SELECT
        PanelNew,
        PayerName_Raw,
        DENSE_RANK() OVER (PARTITION BY PanelNew ORDER BY SUM(ClaimCount) DESC) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY PanelNew, PayerName_Raw;

    SELECT
        b.PanelNew,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.WeekStart, b.WeekEnd, b.WeekLabel,
        b.ClaimCount, b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.PanelNew = b.PanelNew AND r.PayerName_Raw = b.PayerName_Raw
   -- WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.Aug_WeeklyBilledProductionSummary;

    INSERT INTO dbo.Aug_WeeklyBilledProductionSummary
        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
         ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelNew, PayerName_Raw, PayerRank,
           WeekStart, WeekEnd, WeekLabel,
           ClaimCount, TotalCharges, GETDATE()
    FROM #Top3
    ORDER BY PanelNew, PayerRank, WeekStart DESC;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshAug_WeeklyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '08_Augustus_WeeklyBilledProductionSummary.sql completed.';

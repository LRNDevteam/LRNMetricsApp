-- PhiLife — Weekly Claim Production Billed Summary
-- Rule:
--   Source  : ClaimLevelData
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : Panelname  x  All Payers (ranked by COUNT(DISTINCT ClaimID) per Panelname)
--   Columns : ChargeEnteredDate week range Thu–Wed, last 4 complete weeks
--             | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   Note    : PhiLife week runs Thursday through Wednesday (Rule1).
--             Reference Thursday anchor: 1900-01-04.
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_WeeklyBilledProductionSummary')
CREATE TABLE dbo.Phi_WeeklyBilledProductionSummary
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType    NVARCHAR(MAX)   NOT NULL,
    PayerName    NVARCHAR(500)   NOT NULL,
    PayerRank    TINYINT         NOT NULL,
    WeekStart    DATE            NOT NULL,   -- Thursday
    WeekEnd      DATE            NOT NULL,   -- Wednesday
    WeekLabel    NVARCHAR(32)    NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekThuStart DATE;
    DECLARE @DateFromData     DATE;

    -- Anchor to most recent Thursday using ChargeEnteredDate from data
    SELECT
        @DateFromData     = MAX(TRY_CAST(ChargeEnteredDate AS DATE)),
        @ThisWeekThuStart = DATEADD(day,
            -(DATEDIFF(day, '1900-01-04', ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today)) % 7),
            ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
      AND TRY_CAST(ChargeEnteredDate AS DATE) <= @Today;

    -- If max date >= Wednesday of current week → current week is complete → start from 0
    -- Otherwise current week is incomplete → start from 1 (last complete week)
    DECLARE @StartIndex INT = CASE
        WHEN @DateFromData >= DATEADD(day, 6, @ThisWeekThuStart) THEN 0
        ELSE 1
    END;

    DECLARE @i INT = @StartIndex;
    CREATE TABLE #Weeks
    (
        WeekIndex INT PRIMARY KEY,
        WeekStart DATE,
        WeekEnd   DATE,
        WeekLabel NVARCHAR(32)
    );

    WHILE @i <= @StartIndex + 3   -- always 4 weeks
    BEGIN
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekThuStart);
        DECLARE @we DATE = DATEADD(day, 6, @ws);   -- Thu + 6 = Wed
        INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i = @i + 1;
    END

    -- Drive join from #Weeks (LEFT JOIN) so every one of the 4 weeks always
    -- produces at least one row, even when zero billed claims existed that week.
    SELECT
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown')))              AS Panelname,
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))              AS PayerName_Raw,
        w.WeekStart, w.WeekEnd, w.WeekLabel,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0)     AS TotalCharges
    INTO #BilledRaw
    FROM #Weeks w
    LEFT JOIN dbo.ClaimLevelData cl
           ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
          AND TRY_CAST(cl.FirstBilledDate   AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
    GROUP BY
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
        w.WeekStart, w.WeekEnd, w.WeekLabel;

    SELECT
        Panelname,
        PayerName_Raw,
        DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw
    GROUP BY Panelname, PayerName_Raw;

    SELECT
        b.Panelname, b.PayerName_Raw, CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.WeekStart, b.WeekEnd, b.WeekLabel, b.ClaimCount, b.TotalCharges
    INTO #Final
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw;

    TRUNCATE TABLE dbo.Phi_WeeklyBilledProductionSummary;

    INSERT INTO dbo.Phi_WeeklyBilledProductionSummary
        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
         ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, PayerName_Raw, PayerRank,
           WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, GETDATE()
    FROM #Final
    ORDER BY Panelname, PayerRank, WeekStart DESC;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Final;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshPhi_WeeklyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '07_PhiLife_WeeklyBilledProductionSummary.sql completed.';

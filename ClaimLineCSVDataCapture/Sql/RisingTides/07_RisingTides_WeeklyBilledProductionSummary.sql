-- RisingTides — Weekly Claim Production Billed Summary
-- Rule:
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--   Rows    : Panelname  x  Top 3 Payer (by COUNT(DISTINCT ClaimID), per Panelname)
--   Columns : ChargeEnteredDate week range Thu–Wed, last 4 complete weeks
--             | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
--   Note    : RisingTides week runs Thursday through Wednesday.
--             Reference Thursday anchor: 1900-01-04.
-- ============================================================

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'RT_WeeklyBilledProductionSummary')
CREATE TABLE dbo.RT_WeeklyBilledProductionSummary
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshRT_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today            DATE = CAST(GETDATE() AS DATE);
    DECLARE @ThisWeekThuStart DATE = DATEADD(day, -(DATEDIFF(day, '1900-01-04', @Today) % 7), @Today);

    DECLARE @i INT = 1;
    CREATE TABLE #Weeks
    (
        WeekIndex INT PRIMARY KEY,
        WeekStart DATE,
        WeekEnd   DATE,
        WeekLabel NVARCHAR(32)
    );

    WHILE @i <= 4
    BEGIN
        DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekThuStart);
        DECLARE @we DATE = DATEADD(day, 6, @ws);
        INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
        SET @i = @i + 1;
    END

    SELECT
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown')))              AS Panelname,
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))              AS PayerName_Raw,
        w.WeekStart, w.WeekEnd, w.WeekLabel,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))           AS ClaimCount,
        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0)     AS TotalCharges
    INTO #BilledRaw
    FROM dbo.ClaimLevelData cl
    JOIN #Weeks w ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
    WHERE TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
        w.WeekStart, w.WeekEnd, w.WeekLabel;

    SELECT
        Panelname, PayerName_Raw,
        DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
    INTO #PayerRanks
    FROM #BilledRaw GROUP BY Panelname, PayerName_Raw;

    SELECT
        b.Panelname, b.PayerName_Raw, CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.WeekStart, b.WeekEnd, b.WeekLabel, b.ClaimCount, b.TotalCharges
    INTO #Top3
    FROM #BilledRaw b
    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw
    WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.RT_WeeklyBilledProductionSummary;

    INSERT INTO dbo.RT_WeeklyBilledProductionSummary
        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
         ClaimCount, TotalCharges, RefreshedAt)
    SELECT Panelname, PayerName_Raw, PayerRank,
           WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, GETDATE()
    FROM #Top3 ORDER BY Panelname, PayerRank, WeekStart DESC;

    DROP TABLE IF EXISTS #BilledRaw;
    DROP TABLE IF EXISTS #PayerRanks;
    DROP TABLE IF EXISTS #Top3;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshRT_WeeklyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '07_RisingTides_WeeklyBilledProductionSummary.sql completed.';

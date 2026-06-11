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

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @DateFromData DATE;
    DECLARE @ThisWeekMonStart DATE;
    DECLARE @StartIndex INT;

    -- Anchor from FirstBilledDate (client requirement)
    SELECT
        @DateFromData = MAX(TRY_CAST(FirstBilledDate AS DATE))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(FirstBilledDate)) <> ''
      AND TRY_CAST(FirstBilledDate AS DATE) <= @Today;

    IF @DateFromData IS NULL
    BEGIN
        RAISERROR('No valid FirstBilledDate <= today found.', 16, 1);
        RETURN;
    END;

    -- Monday of the week containing @DateFromData
    SET @ThisWeekMonStart =
        DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @DateFromData) % 7), @DateFromData);

    -- Include current week only if complete (data reached Sunday)
    SET @StartIndex =
        CASE
            WHEN @DateFromData >= DATEADD(DAY, 6, @ThisWeekMonStart) THEN 0
            ELSE 1
        END;

    CREATE TABLE #Weeks
    (
        WeekIndex INT PRIMARY KEY,
        WeekStart DATE NOT NULL,
        WeekEnd   DATE NOT NULL,
        WeekLabel NVARCHAR(32) NOT NULL
    );

    DECLARE @i INT = @StartIndex;
    WHILE @i <= @StartIndex + 3
    BEGIN
        DECLARE @ws DATE = DATEADD(WEEK, -@i, @ThisWeekMonStart);
        DECLARE @we DATE = DATEADD(DAY, 6, @ws); -- Mon-Sun

        INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
        VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));

        SET @i += 1;
    END;

    ;WITH src AS
    (
        SELECT
            Panelname     = LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown'))),
            PayerName_Raw = LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),
            w.WeekStart,
            w.WeekEnd,
            w.WeekLabel,
            ClaimID       = NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''),
            ChargeAmt     = TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))
        FROM dbo.ClaimLevelData cl
        JOIN #Weeks w
          ON TRY_CAST(cl.FirstBilledDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE TRY_CAST(cl.FirstBilledDate AS DATE) IS NOT NULL
          AND LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
    ),
    billed AS
    (
        SELECT
            Panelname,
            PayerName_Raw,
            WeekStart,
            WeekEnd,
            WeekLabel,
            COUNT(DISTINCT ClaimID) AS ClaimCount,
            ISNULL(SUM(ChargeAmt), 0) AS TotalCharges
        FROM src
        GROUP BY Panelname, PayerName_Raw, WeekStart, WeekEnd, WeekLabel
    ),
    ranks AS
    (
        SELECT
            Panelname,
            PayerName_Raw,
            DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
        FROM billed
        GROUP BY Panelname, PayerName_Raw
    )
    SELECT
        b.Panelname,
        b.PayerName_Raw,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        b.WeekStart,
        b.WeekEnd,
        b.WeekLabel,
        b.ClaimCount,
        b.TotalCharges
    INTO #Final
    FROM billed b
    JOIN ranks r
      ON r.Panelname = b.Panelname
     AND r.PayerName_Raw = b.PayerName_Raw;

    TRUNCATE TABLE dbo.Phi_WeeklyBilledProductionSummary;

    INSERT INTO dbo.Phi_WeeklyBilledProductionSummary
    (
        PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
        ClaimCount, TotalCharges, RefreshedAt
    )
    SELECT
        Panelname, PayerName_Raw, PayerRank,
        WeekStart, WeekEnd, WeekLabel,
        ClaimCount, TotalCharges, GETDATE()
    FROM #Final
    ORDER BY Panelname, PayerRank, WeekStart DESC;

    -- Debug prints
    PRINT 'Max FirstBilledDate = ' + CONVERT(VARCHAR(10), @DateFromData, 120);
    PRINT 'Anchor Monday       = ' + CONVERT(VARCHAR(10), @ThisWeekMonStart, 120);
    PRINT 'StartIndex          = ' + CAST(@StartIndex AS VARCHAR(10));

    SELECT WeekIndex, WeekStart, WeekEnd, WeekLabel
    FROM #Weeks
    ORDER BY WeekIndex;

    DROP TABLE IF EXISTS #Final;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshPhi_WeeklyBilledProductionSummary completed.';
END
GO

PRINT '07_PhiLife_WeeklyBilledProductionSummary.sql completed.';

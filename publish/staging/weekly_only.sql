CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_WeeklyClaimVolume_ClientLogic
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today         DATE = CAST(GETDATE() AS DATE);
    DECLARE @DateFromData  DATE;
    DECLARE @ThisWeekStart DATE;
    DECLARE @StartIndex    INT;
    DECLARE @i             INT;
    DECLARE @ws            DATE;
    DECLARE @we            DATE;
    DECLARE @wk            TINYINT;

    -- Same anchor as Production weekly: MAX(FirstBilledDate), Wed-Tue weeks
    SELECT
        @DateFromData  = MAX(TRY_CAST(FirstBilledDate AS DATE)),
        @ThisWeekStart = DATEADD(DAY,
            -(DATEDIFF(DAY, '19000103', ISNULL(MAX(TRY_CAST(FirstBilledDate AS DATE)), @Today)) % 7),
            ISNULL(MAX(TRY_CAST(FirstBilledDate AS DATE)), @Today))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND TRY_CAST(FirstBilledDate AS DATE) <= @Today;

    IF @DateFromData IS NULL
    BEGIN
        RAISERROR('No valid FirstBilledDate <= today found in ClaimLevelData.', 16, 1);
        RETURN;
    END;

    SET @StartIndex = CASE
        WHEN @DateFromData >= DATEADD(DAY, 6, @ThisWeekStart) THEN 0
        ELSE 1
    END;

    CREATE TABLE #Weeks
    (
        WeekKey   TINYINT NOT NULL PRIMARY KEY,
        WeekStart DATE    NOT NULL,
        WeekEnd   DATE    NOT NULL
    );

    SET @i = @StartIndex;
    WHILE @i <= @StartIndex + 3
    BEGIN
        SET @ws = DATEADD(WEEK, -@i, @ThisWeekStart);
        SET @we = DATEADD(DAY, 6, @ws);
        -- WeekKey 1 = oldest, 4 = newest
        SET @wk = CAST((@StartIndex + 3 - @i) + 1 AS TINYINT);
        INSERT INTO #Weeks (WeekKey, WeekStart, WeekEnd) VALUES (@wk, @ws, @we);
        SET @i = @i + 1;
    END;

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))) AS PayerName,
            w.WeekKey,
            w.WeekStart,
            w.WeekEnd,
            cl.ClaimID,
            TRY_CAST(cl.InsurancePayment AS DECIMAL(18,2))    AS InsPay
        FROM #Weeks w
        INNER JOIN dbo.ClaimLevelData cl
            ON TRY_CAST(cl.CheckDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
           AND ISNULL(TRY_CAST(cl.InsurancePayment AS DECIMAL(18,2)), 0) > 0
           AND TRY_CAST(cl.CheckDate AS DATE) IS NOT NULL
           AND TRY_CAST(cl.CheckDate AS DATE) <= @Today
    ),
    agg AS
    (
        SELECT
            PanelName, PayerName, WeekKey, WeekStart, WeekEnd,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
            ISNULL(SUM(InsPay), 0)                   AS InsurancePayment
        FROM src
        GROUP BY PanelName, PayerName, WeekKey, WeekStart, WeekEnd
    ),
    ranks AS
    (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg
        GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName,
        a.PayerName,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        a.WeekKey,
        a.WeekStart,
        a.WeekEnd,
        a.NoOfClaims,
        a.InsurancePayment
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName;

    TRUNCATE TABLE dbo.Cove_CS_WeeklyClaimVolume;

    INSERT INTO dbo.Cove_CS_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
         NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
           NoOfClaims, InsurancePayment, GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank, WeekKey;

    DECLARE @Rows INT = @@ROWCOUNT;
    DROP TABLE IF EXISTS #out;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshCove_CS_WeeklyClaimVolume_ClientLogic completed — '
        + CAST(@Rows AS NVARCHAR(20)) + ' rows.';
END
GO

-- Certus Labs — Weekly Claim Production Billed Summary
-- Rule:
--   Filter  : TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
--             AND PayerName_Raw does not contain: None, Accu, Client, Patient
--   Rows    : Panelname  x  Top 3 Payer (by COUNT(DISTINCT ClaimID), per Panelname)
--   Columns : FirstBilledDate week range Mon–Sun, last 4 complete weeks
--             | COUNT(DISTINCT ClaimID) | SUM(ChargeAmount)
-- ============================================================

SET NOCOUNT ON;
GO

-- ============================================================
-- Step 1: Aggregate table
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Cert_WeeklyBilledProductionSummary')
CREATE TABLE dbo.Cert_WeeklyBilledProductionSummary
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType    NVARCHAR(MAX)   NOT NULL,   -- stores Panelname value
    PayerName    NVARCHAR(500)   NOT NULL,
    PayerRank    TINYINT         NOT NULL,   -- 1 / 2 / 3 within the Panelname
    WeekStart    DATE            NOT NULL,   -- Monday
    WeekEnd      DATE            NOT NULL,   -- Sunday
    WeekLabel    NVARCHAR(32)    NOT NULL,   -- 'yyyy-MM-dd - yyyy-MM-dd'
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- ============================================================
-- Step 2: Stored procedure
-- ============================================================

CREATE or Alter   PROCEDURE dbo.usp_RefreshCert_WeeklyBilledProductionSummary 
AS  
BEGIN  
    SET NOCOUNT ON;  
  
    DECLARE @Today DATE = CAST(GETDATE() AS DATE);  
    DECLARE @DateFromData DATE;  
    DECLARE @CurrentWeekStart DATE;  
    DECLARE @i INT = 0;  
  
    /*  
      Monday-Sunday week logic  
      1900-01-01 is Monday  
    */  
    SELECT  
        @DateFromData = MAX(TRY_CAST(ChargeEnteredDate AS DATE))  
    FROM dbo.ClaimLevelData  
    WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL  
      AND TRY_CAST(ChargeEnteredDate AS DATE) <= @Today;  
  
    SET @DateFromData = ISNULL(@DateFromData, @Today);  
  
    SET @CurrentWeekStart =  
        DATEADD(DAY,  
            -(DATEDIFF(DAY, '19000101', @DateFromData) % 7),  
            @DateFromData);  
  
    CREATE TABLE #Weeks  
    (  
        WeekIndex INT PRIMARY KEY,  
        WeekStart DATE,  
        WeekEnd   DATE,  
        WeekLabel NVARCHAR(32)  
    );  
  
    /*  
      Build latest 4 Monday-Sunday weeks  
      WeekIndex 0 = latest week containing max ChargeEnteredDate  
    */  
    WHILE @i <= 3  
    BEGIN  
        DECLARE @ws DATE = DATEADD(WEEK, -@i, @CurrentWeekStart);  
        DECLARE @we DATE = DATEADD(DAY, 6, @ws);  
  
        INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)  
        VALUES  
        (  
            @i,  
            @ws,  
            @we,  
            CONVERT(VARCHAR(10), @ws, 23) + ' - ' + CONVERT(VARCHAR(10), @we, 23)  
        );  
  
        SET @i = @i + 1;  
    END;  
  
    SELECT  
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown')))         AS Panelname,  
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown')))         AS PayerName_Raw,  
        w.WeekStart,  
        w.WeekEnd,  
        w.WeekLabel,  
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))      AS ClaimCount,  
        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges  
    INTO #BilledRaw  
    FROM #Weeks w  
    LEFT JOIN dbo.ClaimLevelData cl  
        ON TRY_CAST(cl.ChargeEnteredDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd  
       AND LTRIM(RTRIM(ISNULL(cl.ChargeEnteredDate, ''))) <> ''  
       AND UPPER(LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, '')))) NOT LIKE '%NONE%'  
       AND UPPER(LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, '')))) NOT LIKE '%ACCU%'  
       AND UPPER(LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, '')))) NOT LIKE '%CLIENT%'  
       AND UPPER(LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, '')))) NOT LIKE '%PATIENT%'  
    GROUP BY  
        LTRIM(RTRIM(ISNULL(cl.Panelname,     'Unknown'))),  
        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))),  
        w.WeekStart,  
        w.WeekEnd,  
        w.WeekLabel;  
  
    SELECT  
        Panelname,  
        PayerName_Raw,  
        DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank  
    INTO #PayerRanks  
    FROM #BilledRaw  
    GROUP BY Panelname, PayerName_Raw;  
  
    SELECT  
        b.Panelname,  
        b.PayerName_Raw,  
        CAST(r.PayerRank AS TINYINT) AS PayerRank,  
        b.WeekStart,  
        b.WeekEnd,  
        b.WeekLabel,  
        b.ClaimCount,  
        b.TotalCharges  
    INTO #Top3  
    FROM #BilledRaw b  
    JOIN #PayerRanks r  
      ON r.Panelname = b.Panelname  
     AND r.PayerName_Raw = b.PayerName_Raw;  
  
    TRUNCATE TABLE dbo.Cert_WeeklyBilledProductionSummary;  
  
    INSERT INTO dbo.Cert_WeeklyBilledProductionSummary  
    (  
        PanelType,  
        PayerName,  
        PayerRank,  
        WeekStart,  
        WeekEnd,  
        WeekLabel,  
        ClaimCount,  
        TotalCharges,  
        RefreshedAt  
    )  
    SELECT  
        Panelname,  
        PayerName_Raw,  
        PayerRank,  
        WeekStart,  
        WeekEnd,  
        WeekLabel,  
        ClaimCount,  
        TotalCharges,  
        GETDATE()  
    FROM #Top3  
    ORDER BY Panelname, PayerRank, WeekStart DESC;  
  
    DROP TABLE IF EXISTS #BilledRaw;  
    DROP TABLE IF EXISTS #PayerRanks;  
    DROP TABLE IF EXISTS #Top3;  
    DROP TABLE IF EXISTS #Weeks;  
  
    PRINT 'usp_RefreshCert_WeeklyBilledProductionSummary completed.';  
END  




--CREATE OR ALTER PROCEDURE dbo.usp_RefreshCert_WeeklyBilledProductionSummary
--AS
--BEGIN
--    SET NOCOUNT ON;

--    -- Week boundary: Mon–Sun. Reference Monday: 1900-01-01.
--    --DECLARE @Today         DATE = CAST(GETDATE() AS DATE);
--    --DECLARE @ThisWeekStart DATE = DATEADD(day, -(DATEDIFF(day, '1900-01-01', @Today) % 7), @Today);

--    ---- Build last 4 complete Mon–Sun weeks (index 1 = most recent complete week).
--    --DECLARE @i INT = 1;
--    --CREATE TABLE #Weeks
--    --(
--    --    WeekIndex INT PRIMARY KEY,
--    --    WeekStart DATE,
--    --    WeekEnd   DATE,
--    --    WeekLabel NVARCHAR(32)
--    --);

--    --WHILE @i <= 4
--    --BEGIN
--    --    DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekStart);
--    --    DECLARE @we DATE = DATEADD(day, 6, @ws);   -- Mon + 6 = Sun
--    --    INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
--    --    VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));
--    --    SET @i = @i + 1;
--    --END
--	DECLARE @Today              DATE = CAST(GETDATE() AS DATE);
--	DECLARE @ThisWeekThuStart   DATE;
--	DECLARE @DateFromData       DATE;

---- Thu–Wed week anchor: 1900-01-05 is a known Friday
--	SELECT
--		@DateFromData     = MAX(TRY_CAST(ChargeEnteredDate AS DATE)),
--		@ThisWeekThuStart = DATEADD(day,
--			-(DATEDIFF(day, '1900-01-01', ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today)) % 7),
--			ISNULL(MAX(TRY_CAST(ChargeEnteredDate AS DATE)), @Today))
--	FROM dbo.ClaimLevelData
--	WHERE TRY_CAST(ChargeEnteredDate AS DATE) IS NOT NULL
--	  AND TRY_CAST(ChargeEnteredDate AS DATE) <= @Today;

--	-- If max date >= Wednesday of current Thu–Wed week,
--	-- then current week is complete, else start from last complete week
--	DECLARE @StartIndex INT = CASE
--		WHEN @DateFromData >= DATEADD(day, 6, @ThisWeekThuStart) THEN 0    -- Mon + 6 = Sun
--		ELSE 1
--	END;

--	DECLARE @i INT = @StartIndex;

--	CREATE TABLE #Weeks
--	(
--		WeekIndex INT PRIMARY KEY,
--		WeekStart DATE,
--		WeekEnd   DATE,
--		WeekLabel NVARCHAR(32)
--	);

--	WHILE @i <= @StartIndex + 3   -- always 4 weeks
--	BEGIN
--		DECLARE @ws DATE = DATEADD(week, -@i, @ThisWeekThuStart);
--		DECLARE @we DATE = DATEADD(day, 6, @ws);   -- Thu + 6 = Wed

--		INSERT INTO #Weeks (WeekIndex, WeekStart, WeekEnd, WeekLabel)
--		VALUES (@i, @ws, @we, FORMAT(@ws, 'yyyy-MM-dd') + ' - ' + FORMAT(@we, 'yyyy-MM-dd'));

--		SET @i = @i + 1;
--	END
--    -- Bug-fix: drive the join from #Weeks (LEFT JOIN) so every one of the 4 weeks
--    -- always produces at least one row in the snapshot, even when zero billed claims
--    -- existed that week. Payer exclusions: None, Accu, Client, Patient.
--    SELECT
--        LTRIM(RTRIM(ISNULL(cl.Panelname,      'Unknown')))              AS Panelname,
--        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw,  'Unknown')))              AS PayerName_Raw,
--        w.WeekStart,
--        w.WeekEnd,
--        w.WeekLabel,
--        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(cl.ClaimID)), ''))            AS ClaimCount,
--        ISNULL(SUM(TRY_CAST(cl.ChargeAmount AS DECIMAL(18,2))), 0)      AS TotalCharges
--    INTO #BilledRaw
--    FROM #Weeks w
--    LEFT JOIN dbo.ClaimLevelData cl
--           ON TRY_CAST(cl.FirstBilledDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
--          AND LTRIM(RTRIM(cl.FirstBilledDate)) <> ''
--          AND UPPER(LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, '')))) NOT LIKE '%NONE%'
--          AND UPPER(LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, '')))) NOT LIKE '%ACCU%'
--          AND UPPER(LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, '')))) NOT LIKE '%CLIENT%'
--          AND UPPER(LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, '')))) NOT LIKE '%PATIENT%'
--    GROUP BY
--        LTRIM(RTRIM(ISNULL(cl.Panelname,      'Unknown'))),
--        LTRIM(RTRIM(ISNULL(cl.PayerName_Raw,  'Unknown'))),
--        w.WeekStart, w.WeekEnd, w.WeekLabel;

--    -- Rank payers within each Panelname across the 4-week window.
--    SELECT
--        Panelname,
--        PayerName_Raw,
--        DENSE_RANK() OVER (PARTITION BY Panelname ORDER BY SUM(ClaimCount) DESC) AS PayerRank
--    INTO #PayerRanks
--    FROM #BilledRaw
--    GROUP BY Panelname, PayerName_Raw;

--    -- Keep all payers (rank filter removed) so the read SP can derive panel totals.
--    SELECT
--        b.Panelname,
--        b.PayerName_Raw,
--        CAST(r.PayerRank AS TINYINT) AS PayerRank,
--        b.WeekStart, b.WeekEnd, b.WeekLabel,
--        b.ClaimCount, b.TotalCharges
--    INTO #Top3
--    FROM #BilledRaw b
--    JOIN #PayerRanks r ON r.Panelname = b.Panelname AND r.PayerName_Raw = b.PayerName_Raw;

--    TRUNCATE TABLE dbo.Cert_WeeklyBilledProductionSummary;

--    INSERT INTO dbo.Cert_WeeklyBilledProductionSummary
--        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
--         ClaimCount, TotalCharges, RefreshedAt)
--    SELECT Panelname, PayerName_Raw, PayerRank,
--           WeekStart, WeekEnd, WeekLabel,
--           ClaimCount, TotalCharges, GETDATE()
--    FROM #Top3
--    ORDER BY Panelname, PayerRank, WeekStart DESC;

--    DROP TABLE IF EXISTS #BilledRaw;
--    DROP TABLE IF EXISTS #PayerRanks;
--    DROP TABLE IF EXISTS #Top3;
--    DROP TABLE IF EXISTS #Weeks;

--    PRINT 'usp_RefreshCert_WeeklyBilledProductionSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
--END
--GO


/*
SELECT PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
FROM dbo.Cert_WeeklyBilledProductionSummary
ORDER BY PanelType, PayerRank, WeekStart DESC;
*/

PRINT '07_Certus_WeeklyBilledProductionSummary.sql completed.';

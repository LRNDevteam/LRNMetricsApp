/* =============================================================================
   VariantX - Weekly Claim Production Summary (client logic sheet)
   Database : VariantX_LRN        Requires : the tables from 07_VariantX_WeeklyBilledProductionSummary.sql

   Replaces the refresh and the read SP from 07 / 13 with the sheet's weekly rule.
   Everything else (filter, rows, values, last four weeks) stays as it was.

   Filter  : FirstBilledDate is a date AND BilledWeek is not blank
             (the sheet's BilledWeek is the BilledWeek column: Week 1 - Week 4)
   Rows    : Panelname, then Top 3 PayerName_Raw by claim count
   Columns : FirstBilledDate in Thursday-Wednesday weeks (the BilledWeek range),
             the last four such weeks
   Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract: PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
                    ClaimCount, TotalCharges
   PayerRank 0 = panel total. 1-3 = top payers.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'VariantX_LRN'
BEGIN
	RAISERROR('Run 07b_VariantX_WeeklyBilledProductionSummary_BilledWeek.sql on the VariantX_LRN database.', 16, 1);
	SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_WeeklyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @ForceLive       BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        ;WITH s AS
        (
            SELECT CAST(PanelType AS NVARCHAR(1000)) AS PanelName, PayerName, PayerRank,
                   WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
            FROM   dbo.VarX_WeeklyBilledProductionSummary
        )
        SELECT PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
        FROM   s
        ORDER  BY SUM(CASE WHEN PayerRank = 0 THEN ClaimCount   ELSE 0 END) OVER (PARTITION BY PanelName) DESC,
                  SUM(CASE WHEN PayerRank = 0 THEN TotalCharges ELSE 0 END) OVER (PARTITION BY PanelName) DESC,
                  PanelName, PayerRank, WeekStart;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NOT NULL
        INSERT INTO @PayerList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|') WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NOT NULL
        INSERT INTO @PanelList(Value) SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|') WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- 2026-10-01 is a Thursday. Week start is independent of DATEFIRST.
    DECLARE @Thursday DATE = CONVERT(date, '20261001');

    DECLARE @LatestWeekStart DATE =
    (
        SELECT MAX(DATEADD(DAY, -((DATEDIFF(DAY, @Thursday, TRY_CAST(FirstBilledDate AS DATE)) % 7 + 7) % 7), TRY_CAST(FirstBilledDate AS DATE)))
        FROM   dbo.ClaimLevelData
        WHERE  TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
          AND  NULLIF(LTRIM(RTRIM(BilledWeek)), N'') IS NOT NULL
          AND  (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom         IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND  (@DosTo           IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND  (@FirstBillFrom   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo     IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    );

    ;WITH Weeks AS
    (
        SELECT w.WeekStart,
               DATEADD(DAY, 6, w.WeekStart) AS WeekEnd,
               CAST(CONVERT(NVARCHAR(10), w.WeekStart, 23) + N' - '
                    + CONVERT(NVARCHAR(10), DATEADD(DAY, 6, w.WeekStart), 23) AS NVARCHAR(32)) AS WeekLabel
        FROM  (VALUES (0), (1), (2), (3)) n(i)
        CROSS APPLY (SELECT DATEADD(WEEK, -n.i, @LatestWeekStart) AS WeekStart) w
        WHERE @LatestWeekStart IS NOT NULL
    ),
    Base AS
    (
        SELECT LTRIM(RTRIM(ISNULL(c.Panelname,     'Unknown'))) AS PanelName,
               LTRIM(RTRIM(ISNULL(c.PayerName_Raw, 'Unknown'))) AS PayerName,
               NULLIF(LTRIM(RTRIM(c.ClaimID)), '')              AS ClaimID,
               ISNULL(TRY_CAST(c.ChargeAmount AS DECIMAL(18,2)), 0) AS ChargeAmount,
               w.WeekStart, w.WeekEnd, w.WeekLabel
        FROM   dbo.ClaimLevelData c
        JOIN   Weeks w ON TRY_CAST(c.FirstBilledDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
        WHERE  TRY_CAST(c.FirstBilledDate AS DATE) IS NOT NULL
          AND  NULLIF(LTRIM(RTRIM(c.BilledWeek)), N'') IS NOT NULL
          AND  (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(c.PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND  (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(c.Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND  (@DosFrom         IS NULL OR TRY_CAST(c.DateOfService   AS DATE) >= @DosFrom)
          AND  (@DosTo           IS NULL OR TRY_CAST(c.DateOfService   AS DATE) <= @DosTo)
          AND  (@FirstBillFrom   IS NULL OR TRY_CAST(c.FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND  (@FirstBillTo     IS NULL OR TRY_CAST(c.FirstBilledDate AS DATE) <= @FirstBillTo)
          AND  (@FirstBilledFrom IS NULL OR TRY_CAST(c.FirstBilledDate AS DATE) >= @FirstBilledFrom)
          AND  (@FirstBilledTo   IS NULL OR TRY_CAST(c.FirstBilledDate AS DATE) <= @FirstBilledTo)
    ),
    PayerRanks AS
    (
        SELECT PanelName, PayerName,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY COUNT(DISTINCT ClaimID) DESC, SUM(ChargeAmount) DESC, PayerName) AS PayerRank
        FROM   Base
        GROUP  BY PanelName, PayerName
    ),
    PanelWeek AS
    (
        SELECT PanelName, WeekStart, WeekEnd, WeekLabel,
               COUNT(DISTINCT ClaimID) AS ClaimCount, SUM(ChargeAmount) AS TotalCharges
        FROM   Base
        GROUP  BY PanelName, WeekStart, WeekEnd, WeekLabel
    ),
    PayerWeek AS
    (
        SELECT PanelName, PayerName, WeekStart, WeekEnd, WeekLabel,
               COUNT(DISTINCT ClaimID) AS ClaimCount, SUM(ChargeAmount) AS TotalCharges
        FROM   Base
        GROUP  BY PanelName, PayerName, WeekStart, WeekEnd, WeekLabel
    ),
    PanelTotals AS
    (
        SELECT PanelName, COUNT(DISTINCT ClaimID) AS PanelClaims, SUM(ChargeAmount) AS PanelCharges
        FROM   Base
        GROUP  BY PanelName
    ),
    OutRows AS
    (
        SELECT PanelName, CAST(N'' AS NVARCHAR(500)) AS PayerName, CAST(0 AS TINYINT) AS PayerRank,
               WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
        FROM   PanelWeek
        UNION ALL
        SELECT pw.PanelName, pw.PayerName, CAST(r.PayerRank AS TINYINT),
               pw.WeekStart, pw.WeekEnd, pw.WeekLabel, pw.ClaimCount, pw.TotalCharges
        FROM   PayerWeek pw
        JOIN   PayerRanks r ON r.PanelName = pw.PanelName AND r.PayerName = pw.PayerName
        WHERE  r.PayerRank <= 3
    )
    SELECT x.PanelName, x.PayerName, x.PayerRank, x.WeekStart, x.WeekEnd, x.WeekLabel, x.ClaimCount, x.TotalCharges
    FROM   OutRows x
    JOIN   PanelTotals t ON t.PanelName = x.PanelName
    ORDER  BY t.PanelClaims DESC, t.PanelCharges DESC, x.PanelName, x.PayerRank, x.WeekStart;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName NVARCHAR(MAX), PayerName NVARCHAR(500), PayerRank TINYINT,
        WeekStart DATE, WeekEnd DATE, WeekLabel NVARCHAR(32), ClaimCount INT, TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetVarX_WeeklyBilledProductionSummary @ForceLive = 1;

    TRUNCATE TABLE dbo.VarX_WeeklyBilledProductionSummary;

    INSERT INTO dbo.VarX_WeeklyBilledProductionSummary
        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshVarX_WeeklyBilledProductionSummary completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshVarX_WeeklyBilledProductionSummary;
GO

PRINT '07b_VariantX_WeeklyBilledProductionSummary_BilledWeek.sql completed.';
GO

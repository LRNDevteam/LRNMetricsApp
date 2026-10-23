/* =============================================================================
   CoreBio - Weekly Claim Production Summary
   Database : CoreBio        Requires : 05_CoreBio_ProductionBase.sql

   Filter  : BilledStatus = Billed AND BilledWeek is not blank
   Rows    : Panelname, then Top 3 PayerName_Raw by claim count
   Columns : FirstBilledDate in Wednesday-Tuesday weeks, the last four such weeks
   Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract: PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel,
                    ClaimCount, TotalCharges
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'CoreBio'
BEGIN
	RAISERROR('Run 07_CoreBio_WeeklyBilledProductionSummary.sql on the CoreBio database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.CB_WeeklyBilledProductionSummary', N'U') IS NULL
CREATE TABLE dbo.CB_WeeklyBilledProductionSummary
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType    NVARCHAR(MAX)   NOT NULL,
    PayerName    NVARCHAR(500)   NOT NULL,
    PayerRank    TINYINT         NOT NULL,
    WeekStart    DATE            NOT NULL,   -- Wednesday
    WeekEnd      DATE            NOT NULL,   -- Tuesday
    WeekLabel    NVARCHAR(32)    NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCB_WeeklyBilledProductionSummary
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
            FROM   dbo.CB_WeeklyBilledProductionSummary
        )
        SELECT PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
        FROM   s
        ORDER  BY SUM(CASE WHEN PayerRank = 0 THEN ClaimCount   ELSE 0 END) OVER (PARTITION BY PanelName) DESC,
                  SUM(CASE WHEN PayerRank = 0 THEN TotalCharges ELSE 0 END) OVER (PARTITION BY PanelName) DESC,
                  PanelName, PayerRank, WeekStart;
        RETURN;
    END;

    -- 2026-09-16 is a Wednesday. Week start is independent of DATEFIRST.
    DECLARE @Wednesday DATE = CONVERT(date, '20260916');

    DECLARE @LatestWeekStart DATE =
    (
        SELECT MAX(DATEADD(DAY, -((DATEDIFF(DAY, @Wednesday, FirstBilledDate) % 7 + 7) % 7), FirstBilledDate))
        FROM   dbo.fn_CB_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                           @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
        WHERE  IsBilled = 1
          AND  BilledWeek IS NOT NULL
          AND  FirstBilledDate IS NOT NULL
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
        SELECT c.PanelName, c.PayerName, c.ClaimID, c.ChargeAmount, w.WeekStart, w.WeekEnd, w.WeekLabel
        FROM   dbo.fn_CB_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                           @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
        JOIN   Weeks w ON c.FirstBilledDate BETWEEN w.WeekStart AND w.WeekEnd
        WHERE  c.IsBilled = 1
          AND  c.BilledWeek IS NOT NULL
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCB_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName NVARCHAR(MAX), PayerName NVARCHAR(500), PayerRank TINYINT,
        WeekStart DATE, WeekEnd DATE, WeekLabel NVARCHAR(32), ClaimCount INT, TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetCB_WeeklyBilledProductionSummary @ForceLive = 1;

    TRUNCATE TABLE dbo.CB_WeeklyBilledProductionSummary;

    INSERT INTO dbo.CB_WeeklyBilledProductionSummary
        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshCB_WeeklyBilledProductionSummary completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshCB_WeeklyBilledProductionSummary;
GO

PRINT '07_CoreBio_WeeklyBilledProductionSummary.sql completed.';
GO

/* =============================================================================
   WellHealth - Weekly Claim Production Summary
   Database : WellHealth        Requires : 05_WellHealth_ProductionBase.sql

   Client logic (Production Summary, report 2):
     Source  : Claim Level
     Filter  : First Billed Date not blank (same as Monthly)
     Rows    : Panel Name, then Top 3 Insurance by claim count within the panel
     Columns : First Billed Date in Monday-Sunday week ranges (same weeks as the
               file's Billed Week column) - the 4 weeks ending with the week of
               the latest First Billed Date
     Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract (SqlLabProductionSummaryRepository.GetWeeklyAsync):
     PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
     PayerRank 0 = panel total across all payers, 1-3 = top payers.
     Rows come back with panels in display order (panel claim count DESC, then
     panel charges DESC).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.WH_WeeklyBilledProductionSummary', N'U') IS NULL
CREATE TABLE dbo.WH_WeeklyBilledProductionSummary
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelType    NVARCHAR(MAX)   NOT NULL,   -- Panelname
    PayerName    NVARCHAR(500)   NOT NULL,   -- '' on the PayerRank 0 panel-total row
    PayerRank    TINYINT         NOT NULL,
    WeekStart    DATE            NOT NULL,   -- Monday
    WeekEnd      DATE            NOT NULL,   -- Sunday
    WeekLabel    NVARCHAR(32)    NOT NULL,   -- 'yyyy-MM-dd - yyyy-MM-dd'
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_WeeklyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @ForceLive       BIT           = 0      -- 1 = ignore the snapshot (used by the refresh SP)
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
            FROM   dbo.WH_WeeklyBilledProductionSummary
        )
        SELECT PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges
        FROM   s
        ORDER  BY SUM(CASE WHEN PayerRank = 0 THEN ClaimCount   ELSE 0 END) OVER (PARTITION BY PanelName) DESC,
                  SUM(CASE WHEN PayerRank = 0 THEN TotalCharges ELSE 0 END) OVER (PARTITION BY PanelName) DESC,
                  PanelName, PayerRank, WeekStart;
        RETURN;
    END;

    -- Anchor to the latest First Billed Date in the (filtered) data, not GETDATE(),
    -- so a week with no billing yet does not push real weeks out of the window.
    DECLARE @MaxFirstBilled DATE =
    (
        SELECT MAX(FirstBilledDate)
        FROM   dbo.fn_WH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                          @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
        WHERE  IsBilled = 1
    );

    -- 1900-01-01 was a Monday.
    DECLARE @LatestWeekStart DATE =
        DATEADD(DAY, -(DATEDIFF(DAY, '19000101', @MaxFirstBilled) % 7), @MaxFirstBilled);

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
        FROM   dbo.fn_WH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                          @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
        JOIN   Weeks w ON c.FirstBilledDate BETWEEN w.WeekStart AND w.WeekEnd
        WHERE  c.IsBilled = 1
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

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_WeeklyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE
    (
        PanelName NVARCHAR(MAX), PayerName NVARCHAR(500), PayerRank TINYINT,
        WeekStart DATE, WeekEnd DATE, WeekLabel NVARCHAR(32), ClaimCount INT, TotalCharges DECIMAL(18,2)
    );

    INSERT INTO @Rows
    EXEC dbo.usp_GetWH_WeeklyBilledProductionSummary @ForceLive = 1;

    TRUNCATE TABLE dbo.WH_WeeklyBilledProductionSummary;

    INSERT INTO dbo.WH_WeeklyBilledProductionSummary
        (PanelType, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekStart, WeekEnd, WeekLabel, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshWH_WeeklyBilledProductionSummary completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT '07_WellHealth_WeeklyBilledProductionSummary.sql completed.';

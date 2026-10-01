/* ============================================================================================
   AR Workbench - 06 Workflow procedures
     dbo.ARWB_usp_BuildDenialInsights      Denial Analysis Report insights for a sync week (FR-DP-03..06)
     dbo.ARWB_usp_ProcessAutoAdjustments   Process Automatic Adjustments (handoff 6, FR-ADJ-02/03)
     dbo.ARWB_usp_MarkAdjustmentsPosted    "Mark as Posted" after bulk posting in the PMS (FR-ADJ-04)
     dbo.ARWB_usp_SnapshotQueues           nightly queue membership snapshot (FR-ARQ-03)
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/* --------------------------------------------------------------------------------------------
   Insights are grouped by the claim's PRIMARY denial code (never by every code on the claim)
   and built from open, unassigned claims across all payers. The claim list is frozen per week;
   dbo.ARWB_vw_DenialInsight shows the live remainder, so assigning claims reduces the insight.
   Re-running for the same week replaces that week's insights.
   -------------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.ARWB_usp_BuildDenialInsights
    @RefreshRunId   int  = NULL,
    @WeekStart      date = NULL      -- defaults to the run's sync week, else the current week (Monday)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Today date = CONVERT(date, SYSDATETIME());
    SET @WeekStart = COALESCE(@WeekStart,
                              (SELECT rr.SyncWeekStart FROM dbo.ARWB_RefreshRun rr WHERE rr.RefreshRunId = @RefreshRunId),
                              DATEADD(day, -((DATEPART(weekday, @Today) + @@DATEFIRST - 2) % 7), @Today));

    CREATE TABLE #pop
    (
        ClaimKey        bigint         NOT NULL PRIMARY KEY,
        DenialCode      nvarchar(50)   NOT NULL,
        PayerName       nvarchar(500)  NULL,
        Balance         decimal(18,2)  NOT NULL,
        DenialCategory  nvarchar(200)  NULL,
        DenialReason    nvarchar(1000) NULL,
        PanelName       nvarchar(500)  NULL
    );
    INSERT INTO #pop (ClaimKey, DenialCode, PayerName, Balance, DenialCategory, DenialReason, PanelName)
    SELECT c.ClaimKey, c.PrimaryDenialCode, c.PayerName, c.RemainingAR, c.DenialCategory, c.DenialReason, c.PanelName
    FROM dbo.ARWB_Claim c
    WHERE c.IsInCurrentSource = 1
      AND c.IsOpenInsuranceAR = 1
      AND c.PrimaryDenialCode IS NOT NULL
      AND c.WorkflowStatus = 'Unassigned'
      AND c.AssignedAgentUser IS NULL;

    CREATE TABLE #agg
    (
        DenialCode      nvarchar(50)   NOT NULL PRIMARY KEY,
        ClaimCount      int            NOT NULL,
        TotalBalance    decimal(18,2)  NOT NULL,
        Description     nvarchar(1000) NULL,
        DenialCategory  nvarchar(200)  NULL,
        TopPayer        nvarchar(500)  NULL,
        TopPayerBalance decimal(18,2)  NULL,
        TopServiceLine  nvarchar(200)  NULL
    );
    INSERT INTO #agg (DenialCode, ClaimCount, TotalBalance, Description)
    SELECT p.DenialCode, COUNT(*), SUM(p.Balance), MAX(p.DenialReason)
    FROM #pop p
    GROUP BY p.DenialCode;

    -- Most common category for the code (a manual override on some claims can differ)
    UPDATE a SET a.DenialCategory = x.DenialCategory
    FROM #agg a
    INNER JOIN (SELECT p.DenialCode, p.DenialCategory,
                       rn = ROW_NUMBER() OVER (PARTITION BY p.DenialCode ORDER BY COUNT(*) DESC, p.DenialCategory)
                FROM #pop p GROUP BY p.DenialCode, p.DenialCategory) x
            ON x.DenialCode = a.DenialCode AND x.rn = 1;

    -- Highest $ impact payer: an informational highlight, not a filter
    UPDATE a SET a.TopPayer = x.PayerName, a.TopPayerBalance = x.Balance
    FROM #agg a
    INNER JOIN (SELECT p.DenialCode, p.PayerName, Balance = SUM(p.Balance),
                       rn = ROW_NUMBER() OVER (PARTITION BY p.DenialCode ORDER BY SUM(p.Balance) DESC, p.PayerName)
                FROM #pop p GROUP BY p.DenialCode, p.PayerName) x
            ON x.DenialCode = a.DenialCode AND x.rn = 1;

    -- Service line: the CPT most often denied with this code on these claims' lines, else the panel
    UPDATE a SET a.TopServiceLine = x.ServiceLine
    FROM #agg a
    INNER JOIN (SELECT p.DenialCode, ServiceLine = cl.CPTCode,
                       rn = ROW_NUMBER() OVER (PARTITION BY p.DenialCode ORDER BY COUNT(*) DESC, cl.CPTCode)
                FROM #pop p
                INNER JOIN dbo.ARWB_ClaimLineDenial ld ON ld.ClaimKey = p.ClaimKey AND ld.DenialCode = p.DenialCode
                INNER JOIN dbo.ARWB_ClaimLine cl       ON cl.ClaimLineKey = ld.ClaimLineKey
                WHERE cl.CPTCode IS NOT NULL
                GROUP BY p.DenialCode, cl.CPTCode) x
            ON x.DenialCode = a.DenialCode AND x.rn = 1;

    UPDATE a SET a.TopServiceLine = x.PanelName
    FROM #agg a
    INNER JOIN (SELECT p.DenialCode, p.PanelName,
                       rn = ROW_NUMBER() OVER (PARTITION BY p.DenialCode ORDER BY COUNT(*) DESC, p.PanelName)
                FROM #pop p WHERE p.PanelName IS NOT NULL GROUP BY p.DenialCode, p.PanelName) x
            ON x.DenialCode = a.DenialCode AND x.rn = 1
    WHERE a.TopServiceLine IS NULL;

    BEGIN TRANSACTION;

    DELETE ic
    FROM dbo.ARWB_DenialInsightClaim ic
    INNER JOIN dbo.ARWB_DenialInsight i ON i.DenialInsightId = ic.DenialInsightId
    WHERE i.WeekStart = @WeekStart;

    DELETE FROM dbo.ARWB_DenialInsight WHERE WeekStart = @WeekStart;

    INSERT INTO dbo.ARWB_DenialInsight
        (WeekStart, RefreshRunId, DenialCode, DenialDescription, DenialCategory, CategoryTag, RecommendedAction,
         ClaimCount, TotalBalance, TopPayer, TopPayerBalance, ImpactPct, TopServiceLine, Observation)
    SELECT @WeekStart, @RefreshRunId, a.DenialCode, a.Description, a.DenialCategory,
           COALESCE(act.CategoryTag, oth.CategoryTag), COALESCE(act.RecommendedAction, oth.RecommendedAction),
           a.ClaimCount, a.TotalBalance, a.TopPayer, a.TopPayerBalance,
           CASE WHEN a.TotalBalance > 0 THEN CONVERT(decimal(9,4), a.TopPayerBalance / a.TotalBalance) END,
           a.TopServiceLine,
           N'Per review, the majority of denied claims are for ' + COALESCE(a.TopServiceLine, N'this service line') + N'.'
    FROM #agg a
    LEFT JOIN dbo.ARWB_DenialCategoryAction act ON act.DenialCategory = a.DenialCategory
    LEFT JOIN dbo.ARWB_DenialCategoryAction oth ON oth.DenialCategory = N'Other';

    INSERT INTO dbo.ARWB_DenialInsightClaim (DenialInsightId, ClaimKey)
    SELECT i.DenialInsightId, p.ClaimKey
    FROM #pop p
    INNER JOIN dbo.ARWB_DenialInsight i ON i.WeekStart = @WeekStart AND i.DenialCode = p.DenialCode;

    COMMIT TRANSACTION;

    SELECT InsightsBuilt = (SELECT COUNT(*) FROM #agg);
END;
GO

/* --------------------------------------------------------------------------------------------
   Process Automatic Adjustments. Eligible = open insurance balance and a primary denial on the
   AUTO_ADJUST_CODE list (optionally the Non-Collectible list too - AppSetting). The balance is
   nullified IN THE WORKBENCH only, a system comment is written, and the claim moves to the Auto
   Adjustments queue - NOT Completed / Closed - until the adjustment is posted in the PMS.
   @PreviewOnly = 1 returns the confirmation figures (count, $) without changing anything.
   -------------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.ARWB_usp_ProcessAutoAdjustments
    @RunBy          nvarchar(256),
    @RunByRole      varchar(20)    = NULL,
    @ClaimKeyList   nvarchar(max)  = NULL,   -- NULL = every eligible claim; else only these
    @PreviewOnly    bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now datetime2(0) = SYSUTCDATETIME();

    CREATE TABLE #target (ClaimKey bigint NOT NULL PRIMARY KEY, ClaimID nvarchar(200) NOT NULL, Amount decimal(18,2) NOT NULL,
                          ReasonCode nvarchar(50) NULL, AgentUser nvarchar(256) NULL);
    INSERT INTO #target (ClaimKey, ClaimID, Amount, ReasonCode, AgentUser)
    SELECT c.ClaimKey, c.ClaimID, c.RemainingAR, c.PrimaryDenialCode, c.AssignedAgentUser
    FROM dbo.ARWB_Claim c
    WHERE c.IsAutoAdjustEligible = 1
      AND (@ClaimKeyList IS NULL OR c.ClaimKey IN (SELECT k.ClaimKey FROM dbo.ARWB_tvf_ParseKeyList(@ClaimKeyList) k));

    IF @PreviewOnly = 1
    BEGIN
        SELECT ClaimCount = COUNT(*), TotalAmount = ISNULL(SUM(Amount), 0) FROM #target;
        RETURN;
    END;

    BEGIN TRANSACTION;

    UPDATE c
    SET c.IsAutoAdjusted        = 1,
        c.AutoAdjustedOn        = @Now,
        c.AutoAdjustedBy        = @RunBy,
        c.AutoAdjustReasonCode  = t.ReasonCode,
        c.AutoAdjustAmount      = t.Amount,
        c.IsPmsPostedConfirmed  = 0,
        c.PmsPostedOn           = NULL,
        c.PmsPostedBy           = NULL,
        c.IsAdjustmentNotPosted = 0,
        c.UpdatedOn             = @Now,
        c.UpdatedBy             = @RunBy
    FROM dbo.ARWB_Claim c
    INNER JOIN #target t ON t.ClaimKey = c.ClaimKey;

    INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, IsSystem)
    SELECT t.ClaimKey, @Now, N'Automatic Adjustment',
           LEFT(N'System comment: insurance balance ' + CONVERT(nvarchar(30), t.Amount) + N' adjusted automatically for denial '
                + ISNULL(t.ReasonCode, N'-') + N' (run by ' + @RunBy + N'). Post the adjustment in the PMS.', 2000),
           CONVERT(nvarchar(30), t.Amount), N'0.00', N'System / Automation', 'Automation', 1
    FROM #target t;

    INSERT INTO dbo.ARWB_Notification (ClaimKey, RecipientUser, NotificationType, Message, CreatedOn)
    SELECT t.ClaimKey, t.AgentUser, 'AutoAdjusted',
           N'Claim ' + t.ClaimID + N' was auto-adjusted and moved to Auto Adjustments.', @Now
    FROM #target t
    WHERE t.AgentUser IS NOT NULL;

    COMMIT TRANSACTION;

    DECLARE @List nvarchar(max) = STUFF((SELECT N',' + CONVERT(nvarchar(20), t.ClaimKey) FROM #target t FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'');
    IF @List IS NOT NULL
    BEGIN
        CREATE TABLE #recalc (UpdatedClaims int);
        INSERT INTO #recalc EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKeyList = @List;
    END;

    SELECT ClaimCount = COUNT(*), TotalAmount = ISNULL(SUM(Amount), 0) FROM #target;
END;
GO

/* --------------------------------------------------------------------------------------------
   Mark as Posted: the AR Manager / TL (auto-adjustments) or the agent (approved write-offs)
   confirms the adjustment was posted in the PMS. The next sync double-checks it: a claim still
   open in the master is flagged "Adjustment not posted" again.
   -------------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.ARWB_usp_MarkAdjustmentsPosted
    @ClaimKeyList   nvarchar(max),
    @RunBy          nvarchar(256),
    @RunByRole      varchar(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now datetime2(0) = SYSUTCDATETIME();
    CREATE TABLE #done (ClaimKey bigint NOT NULL PRIMARY KEY);

    BEGIN TRANSACTION;

    UPDATE c
    SET c.IsPmsPostedConfirmed  = 1,
        c.PmsPostedOn           = @Now,
        c.PmsPostedBy           = @RunBy,
        c.IsAdjustmentNotPosted = 0,
        c.UpdatedOn             = @Now,
        c.UpdatedBy             = @RunBy
    OUTPUT inserted.ClaimKey INTO #done (ClaimKey)
    FROM dbo.ARWB_Claim c
    WHERE c.ClaimKey IN (SELECT k.ClaimKey FROM dbo.ARWB_tvf_ParseKeyList(@ClaimKeyList) k)
      AND (c.IsAutoAdjusted = 1 OR c.IsWriteOffApproved = 1)
      AND (c.IsPmsPostedConfirmed = 0 OR c.IsAdjustmentNotPosted = 1);

    INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, UserName, RoleCode, IsSystem)
    SELECT d.ClaimKey, @Now, N'Adjustment Marked as Posted', N'Adjustment / write-off posted in the PMS.', @RunBy, @RunByRole, 0
    FROM #done d;

    COMMIT TRANSACTION;

    DECLARE @List nvarchar(max) = STUFF((SELECT N',' + CONVERT(nvarchar(20), d.ClaimKey) FROM #done d FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'');
    IF @List IS NOT NULL
    BEGIN
        CREATE TABLE #recalc (UpdatedClaims int);
        INSERT INTO #recalc EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKeyList = @List;
    END;

    SELECT PostedClaims = (SELECT COUNT(*) FROM #done);
END;
GO

/* --------------------------------------------------------------------------------------------
   Nightly: recalculate (calendar-driven rules), then snapshot queue membership per claim.
   Schedule:  EXEC dbo.ARWB_usp_SnapshotQueues;
   -------------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.ARWB_usp_SnapshotQueues
    @SnapshotDate   date = NULL,
    @Recalculate    bit  = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @SnapshotDate = COALESCE(@SnapshotDate, CONVERT(date, SYSDATETIME()));
    DECLARE @Retention int = COALESCE(TRY_CONVERT(int, (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('QueueSnapshotRetentionDays', N'400'))), 400);

    IF @Recalculate = 1
    BEGIN
        CREATE TABLE #recalc (UpdatedClaims int);
        INSERT INTO #recalc EXEC dbo.ARWB_usp_RecalculateClaimState @AsOfDate = @SnapshotDate;
    END;

    BEGIN TRANSACTION;

    DELETE FROM dbo.ARWB_QueueSnapshot WHERE SnapshotDate = @SnapshotDate;

    INSERT INTO dbo.ARWB_QueueSnapshot
        (SnapshotDate, ClaimKey, ArQueueId, ArSubQueueId, WorkflowStatus, AssignedAgentUser,
         InsuranceBalance, PatientBalance, RemainingAR, RecoveredAmount)
    SELECT @SnapshotDate, c.ClaimKey, c.ArQueueId, c.ArSubQueueId, c.WorkflowStatus, c.AssignedAgentUser,
           c.InsuranceBalance, c.PatientBalance, c.RemainingAR, c.RecoveredAmount
    FROM dbo.ARWB_Claim c
    WHERE c.IsInCurrentSource = 1;

    DELETE FROM dbo.ARWB_QueueSnapshot WHERE SnapshotDate < DATEADD(day, -@Retention, @SnapshotDate);

    COMMIT TRANSACTION;

    SELECT SnapshotRows = (SELECT COUNT(*) FROM dbo.ARWB_QueueSnapshot WHERE SnapshotDate = @SnapshotDate);
END;
GO

PRINT 'AR Workbench 06: workflow procedures ready.';
GO

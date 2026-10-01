/* ============================================================================================
   AR Workbench - 05 dbo.ARWB_usp_LoadClaimsFromSource  (Data Processing: the weekly sync)

   Copies the FULL claim-level master and ALL of its line-level rows into the workbench:
     dbo.ClaimLevelData  -> dbo.ARWB_Claim           every claim, denied or not
     dbo.LineLevelData   -> dbo.ARWB_ClaimLine       every line of those claims, denied or not
                         -> dbo.ARWB_ClaimLineDenial one row per denial code on a line
   The queue engine (dbo.ARWB_usp_RecalculateClaimState) then places every claim in exactly one
   AR queue. Which claims are "denied" is decided by the curated ClaimLevelData.DenialCode column.

   Steps
     1  Latest ClaimLevelData row per ClaimID (InsertedDateTime DESC, RecordId DESC), typed.
     2  Latest line file per claim from LineLevelData (FileLogId DESC), typed.
     3  One transaction:
          3a claims: insert new (Initial* frozen), update changed (hash), stamp unchanged,
             flag dropped-out claims IsInCurrentSource = 0. Workflow state is never overwritten.
          3b financial history + "Claim Identified" / "Source Data Updated" activity
          3c lines: reload only claims whose line set changed (checksum); split line denial codes
          3d primary denial: normalized first code of the curated DenialCode column (CARC prefix
             stripped, RARC kept); category, template and reason from the masters
          3e weekly re-sync rules (handoff section 5):
               - assigned, not yet worked, new primary denial is Non-Collectible
                   -> removed from the agent's queue (Unassigned), agent notified
               - already worked (Submitted for QA / QA Rejected / Completed), new denial
                   -> NewDenialSinceWork = 1; once Completed it shows in
                      Re-Follow-Up Required - New Denials, unassigned; history kept
               - auto-adjusted / write-off approved but the master still shows a balance
                   -> IsAdjustmentNotPosted = 1, back to Auto Adjustments, agent + manager notified
               - adjustment now visible in the master -> posting auto-confirmed
               - every denial change writes an audit entry (System / ETL)
          3f Revenue Expectation for the reloaded lines (dbo.ARWB_usp_PriceClaimLines)
     4  dbo.ARWB_usp_RecalculateClaimState for every claim.
     5  Denial Analysis insights for the sync week (dbo.ARWB_usp_BuildDenialInsights).
     6  Run summary in dbo.ARWB_RefreshRun.

   Idempotent per week: re-running changes nothing that has not changed in the source, and the
   week's insights are rebuilt in place. Source columns are probed with COL_LENGTH, so a lab
   missing an optional column loads NULL for it instead of failing.

   Usage:   EXEC dbo.ARWB_usp_LoadClaimsFromSource @RunBy = N'jdoe', @Note = N'Weekly sync';
            EXEC dbo.ARWB_usp_LoadClaimsFromSource @ReprocessAll = 1;   -- after master-data changes
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.ARWB_usp_LoadClaimsFromSource
    @RunBy          nvarchar(256)  = N'System',
    @Note           nvarchar(1000) = NULL,
    @ReprocessAll   bit            = 0      -- 1 = re-derive denials and re-price lines for EVERY claim (after master-data changes)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NULL
        THROW 51001, 'dbo.ClaimLevelData does not exist in this database. Run the AR Workbench scripts in the lab database.', 1;
    IF COL_LENGTH(N'dbo.ClaimLevelData', N'ClaimID') IS NULL OR COL_LENGTH(N'dbo.ClaimLevelData', N'DenialCode') IS NULL
        THROW 51002, 'dbo.ClaimLevelData must have ClaimID and DenialCode columns.', 1;
    -- An empty feed (e.g. mid-import) would otherwise flag every claim as "no longer in source".
    IF NOT EXISTS (SELECT TOP (1) 1 FROM dbo.ClaimLevelData)
        THROW 51004, 'dbo.ClaimLevelData is empty. Sync skipped so existing claims are not flagged as removed.', 1;

    -- One sync at a time per lab database.
    DECLARE @Lock int;
    EXEC @Lock = sp_getapplock @Resource = N'dbo.ARWB_usp_LoadClaimsFromSource', @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0;
    IF @Lock < 0
        THROW 51003, 'An AR Workbench sync is already running for this lab.', 1;

    DECLARE @Now       datetime2(0) = SYSUTCDATETIME();
    DECLARE @Today     date         = CONVERT(date, SYSDATETIME());
    DECLARE @WeekStart date         = DATEADD(day, -((DATEPART(weekday, @Today) + @@DATEFIRST - 2) % 7), @Today);   -- Monday

    DECLARE @RunId int;
    INSERT INTO dbo.ARWB_RefreshRun (RunBy, Note, SyncWeekStart, StartedOn) VALUES (@RunBy, @Note, @WeekStart, @Now);
    SET @RunId = CONVERT(int, SCOPE_IDENTITY());

    BEGIN TRY
        DECLARE @Sql nvarchar(max), @Cols nvarchar(max), @Exprs nvarchar(max), @OrderBy nvarchar(400), @Rank nvarchar(400);
        DECLARE @Eps          decimal(9,4) = COALESCE(TRY_CONVERT(decimal(9,4), (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('BalanceEpsilon', N'0.005'))), 0.005);
        DECLARE @UseRanking   bit = CASE WHEN (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('PrimaryDenialSource', N'CuratedColumn')) = N'Ranking' THEN 1 ELSE 0 END;
        DECLARE @LineFallback bit = CASE WHEN (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('PrimaryDenialFallbackToLine', N'0')) = N'1' THEN 1 ELSE 0 END;

        /* ------------------------------------------------------------------------------------
           0. Denial descriptions from the lab's existing dbo.DenialCodeMaster (read-only), keyed
              by normalized code. Nothing in the Denial Workflow master is changed.
           ------------------------------------------------------------------------------------ */
        CREATE TABLE #dcm (DenialCode nvarchar(50) NOT NULL PRIMARY KEY, DenialDescription nvarchar(1000) NULL);
        IF OBJECT_ID(N'dbo.DenialCodeMaster', N'U') IS NOT NULL
           AND COL_LENGTH(N'dbo.DenialCodeMaster', N'DenialCode') IS NOT NULL
           AND COL_LENGTH(N'dbo.DenialCodeMaster', N'DenialDescription') IS NOT NULL
            EXEC sys.sp_executesql N'
INSERT INTO #dcm (DenialCode, DenialDescription)
SELECT n.DenialCode, MAX(LEFT(dm.DenialDescription, 1000))
FROM dbo.DenialCodeMaster dm
CROSS APPLY dbo.ARWB_tvf_NormalizeDenialCode(CONVERT(nvarchar(200), dm.DenialCode)) n
WHERE dm.DenialDescription IS NOT NULL AND n.DenialCode IS NOT NULL
GROUP BY n.DenialCode;';

        /* ------------------------------------------------------------------------------------
           1. Latest claim-level row per ClaimID, typed - EVERY claim, denied or not
           ------------------------------------------------------------------------------------ */
        CREATE TABLE #src
        (
            ClaimID                 nvarchar(200)  NOT NULL PRIMARY KEY,
            SourceRecordId          int            NULL,
            SourceRunId             nvarchar(500)  NULL,
            SourceFileName          nvarchar(500)  NULL,
            SourceWeekFolder        nvarchar(500)  NULL,
            LabId                   int            NULL,
            LabName                 nvarchar(500)  NULL,
            AccessionNumber         nvarchar(200)  NULL,
            PatientID               nvarchar(200)  NULL,
            PatientName             nvarchar(1000) NULL,
            PatientDOB              date           NULL,
            SubscriberId            nvarchar(200)  NULL,
            PayerName               nvarchar(500)  NULL,
            PayerNameRaw            nvarchar(500)  NULL,
            PayerCode               nvarchar(200)  NULL,
            PayerType               nvarchar(200)  NULL,
            ClaimType               nvarchar(200)  NULL,
            BillingProvider         nvarchar(500)  NULL,
            ReferringProvider       nvarchar(500)  NULL,
            ClinicName              nvarchar(500)  NULL,
            SalesRepName            nvarchar(500)  NULL,
            PanelName               nvarchar(500)  NULL,
            PanelType               nvarchar(500)  NULL,
            PanelNameAlt1           nvarchar(500)  NULL,      -- fallbacks when Panelname is blank (labs name it differently)
            PanelNameAlt2           nvarchar(500)  NULL,
            DateOfService           date           NULL,
            ChargeEnteredDate       date           NULL,
            FirstBilledDate         date           NULL,
            CheckDate               date           NULL,
            SourceLastActivityDate  date           NULL,
            CptSummary              nvarchar(max)  NULL,
            ICDCode                 nvarchar(1000) NULL,
            SourceClaimStatus       nvarchar(200)  NULL,
            DeniedStatus            nvarchar(200)  NULL,
            DenialCode              nvarchar(1000) NULL,
            ChargeAmount            decimal(18,2)  NOT NULL DEFAULT (0),
            AllowedAmount           decimal(18,2)  NOT NULL DEFAULT (0),
            InsurancePayment        decimal(18,2)  NOT NULL DEFAULT (0),
            PatientPayment          decimal(18,2)  NOT NULL DEFAULT (0),
            TotalPayments           decimal(18,2)  NOT NULL DEFAULT (0),
            InsuranceAdjustments    decimal(18,2)  NOT NULL DEFAULT (0),
            PatientAdjustments      decimal(18,2)  NOT NULL DEFAULT (0),
            TotalAdjustments        decimal(18,2)  NOT NULL DEFAULT (0),
            InsuranceBalance        decimal(18,2)  NOT NULL DEFAULT (0),
            PatientBalance          decimal(18,2)  NOT NULL DEFAULT (0),
            TotalBalance            decimal(18,2)  NOT NULL DEFAULT (0),
            -- computed in later steps
            RowHash                 nvarchar(64)   NULL,
            ClaimKey                bigint         NULL,
            ChangeKind              varchar(10)    NULL      -- New | Changed | Same
        );

        DECLARE @ClaimMap TABLE (Ord int IDENTITY(1,1), TargetCol sysname, SourceCol sysname, Kind char(1), MaxLen int);
        -- Kind: T text (MaxLen, -1 = max) | M money | D date | I int
        INSERT INTO @ClaimMap (TargetCol, SourceCol, Kind, MaxLen) VALUES
            (N'ClaimID', N'ClaimID', 'T', 200),
            (N'SourceRecordId', N'RecordId', 'I', 0),
            (N'SourceRunId', N'RunId', 'T', 500),
            (N'SourceFileName', N'FileName', 'T', 500),
            (N'SourceWeekFolder', N'WeekFolder', 'T', 500),
            (N'LabId', N'LabID', 'I', 0),
            (N'LabName', N'LabName', 'T', 500),
            (N'AccessionNumber', N'AccessionNumber', 'T', 200),
            (N'PatientID', N'PatientID', 'T', 200),
            (N'PatientName', N'PatientName', 'T', 1000),
            (N'PatientDOB', N'PatientDOB', 'D', 0),
            (N'SubscriberId', N'SubscriberId', 'T', 200),
            (N'PayerName', N'PayerName', 'T', 500),
            (N'PayerNameRaw', N'PayerName_Raw', 'T', 500),
            (N'PayerCode', N'Payer_Code', 'T', 200),
            (N'PayerType', N'PayerType', 'T', 200),
            (N'ClaimType', N'ClaimType', 'T', 200),
            (N'BillingProvider', N'BillingProvider', 'T', 500),
            (N'ReferringProvider', N'ReferringProvider', 'T', 500),
            (N'ClinicName', N'ClinicName', 'T', 500),
            (N'SalesRepName', N'SalesRepname', 'T', 500),
            (N'PanelName', N'Panelname', 'T', 500),
            (N'PanelType', N'PanelType', 'T', 500),
            (N'PanelNameAlt1', N'PanelNameBasedOnCPT', 'T', 500),
            (N'PanelNameAlt2', N'PanelNameLIS', 'T', 500),
            (N'DateOfService', N'DateofService', 'D', 0),
            (N'ChargeEnteredDate', N'ChargeEnteredDate', 'D', 0),
            (N'FirstBilledDate', N'FirstBilledDate', 'D', 0),
            (N'CheckDate', N'CheckDate', 'D', 0),
            (N'SourceLastActivityDate', N'LastActivityDate', 'D', 0),
            (N'CptSummary', N'CPTCodeXUnitsXModifier', 'T', -1),
            (N'ICDCode', N'ICDCode', 'T', 1000),
            (N'SourceClaimStatus', N'ClaimStatus', 'T', 200),
            (N'DeniedStatus', N'DeniedStatus', 'T', 200),
            (N'DenialCode', N'DenialCode', 'T', 1000),
            (N'ChargeAmount', N'ChargeAmount', 'M', 0),
            (N'AllowedAmount', N'AllowedAmount', 'M', 0),
            (N'InsurancePayment', N'InsurancePayment', 'M', 0),
            (N'PatientPayment', N'PatientPayment', 'M', 0),
            (N'TotalPayments', N'TotalPayments', 'M', 0),
            (N'InsuranceAdjustments', N'InsuranceAdjustments', 'M', 0),
            (N'PatientAdjustments', N'PatientAdjustments', 'M', 0),
            (N'TotalAdjustments', N'TotalAdjustments', 'M', 0),
            (N'InsuranceBalance', N'InsuranceBalance', 'M', 0),
            (N'PatientBalance', N'PatientBalance', 'M', 0),
            (N'TotalBalance', N'TotalBalance', 'M', 0);

        SELECT @Cols = STUFF((
                SELECT N', ' + QUOTENAME(m.TargetCol) FROM @ClaimMap m ORDER BY m.Ord
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
               @Exprs = STUFF((
                SELECT N', ' +
                    CASE
                        WHEN COL_LENGTH(N'dbo.ClaimLevelData', m.SourceCol) IS NULL THEN CASE m.Kind WHEN 'M' THEN N'0' ELSE N'NULL' END
                        WHEN m.Kind = 'T' AND m.MaxLen = -1 THEN N'NULLIF(NULLIF(LTRIM(RTRIM(r.' + QUOTENAME(m.SourceCol) + N')), N''''), N''NULL'')'
                        WHEN m.Kind = 'T' THEN N'LEFT(NULLIF(NULLIF(LTRIM(RTRIM(r.' + QUOTENAME(m.SourceCol) + N')), N''''), N''NULL''), ' + CONVERT(nvarchar(10), m.MaxLen) + N')'
                        WHEN m.Kind = 'M' THEN N'ISNULL((SELECT x.Amount FROM dbo.ARWB_tvf_ParseMoney(r.' + QUOTENAME(m.SourceCol) + N') x), 0)'
                        WHEN m.Kind = 'D' THEN N'(SELECT x.DateValue FROM dbo.ARWB_tvf_ParseDate(r.' + QUOTENAME(m.SourceCol) + N') x)'
                        WHEN m.Kind = 'I' THEN N'TRY_CONVERT(int, r.' + QUOTENAME(m.SourceCol) + N')'
                    END
                FROM @ClaimMap m ORDER BY m.Ord
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

        SET @OrderBy =
            CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'InsertedDateTime') IS NOT NULL THEN N'r.InsertedDateTime DESC, ' ELSE N'' END
            + CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'RecordId') IS NOT NULL THEN N'r.RecordId DESC' ELSE N'(SELECT NULL)' END;

        -- No denial filter: the whole claim-level master is synced.
        SET @Sql = N'
;WITH ranked AS
(
    SELECT r.*, arwb_rn = ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(r.ClaimID)) ORDER BY ' + @OrderBy + N')
    FROM dbo.ClaimLevelData r
    WHERE NULLIF(LTRIM(RTRIM(r.ClaimID)), N'''') IS NOT NULL
      AND LEN(LTRIM(RTRIM(r.ClaimID))) <= 200
)
INSERT INTO #src (' + @Cols + N')
SELECT ' + @Exprs + N'
FROM ranked r
WHERE r.arwb_rn = 1;';

        EXEC sys.sp_executesql @Sql;

        -- Labs fill different columns: PayerName is blank for some (e.g. InHealth) where PayerName_Raw
        -- is set, and the panel can sit in PanelNameBasedOnCPT / PanelNameLIS instead of Panelname.
        UPDATE #src
        SET PayerName = COALESCE(PayerName, PayerNameRaw),
            PanelName = COALESCE(PanelName, PanelNameAlt1, PanelNameAlt2)
        WHERE PayerName IS NULL OR PanelName IS NULL;

        UPDATE #src
        SET RowHash =CONVERT(nvarchar(64), HASHBYTES('SHA2_256', CONCAT(
                ClaimID, N'|', DenialCode, N'|', SourceClaimStatus, N'|', DeniedStatus, N'|', PayerName, N'|', PayerType, N'|',
                ClinicName, N'|', ReferringProvider, N'|', BillingProvider, N'|', PanelName, N'|', PanelType, N'|',
                CONVERT(nvarchar(10), DateOfService, 23), N'|', CONVERT(nvarchar(10), FirstBilledDate, 23), N'|', CONVERT(nvarchar(10), CheckDate, 23), N'|',
                ChargeAmount, N'|', AllowedAmount, N'|', InsurancePayment, N'|', PatientPayment, N'|', TotalPayments, N'|',
                InsuranceAdjustments, N'|', PatientAdjustments, N'|', TotalAdjustments, N'|',
                InsuranceBalance, N'|', PatientBalance, N'|', TotalBalance, N'|', AccessionNumber, N'|', PatientName, N'|', ICDCode, N'|',
                SubscriberId, N'|', ClaimType, N'|', CONVERT(nvarchar(10), SourceLastActivityDate, 23))), 2);

        UPDATE s
        SET s.ClaimKey   = c.ClaimKey,
            s.ChangeKind = CASE WHEN c.SourceRowHash = s.RowHash THEN 'Same' ELSE 'Changed' END
        FROM #src s
        INNER JOIN dbo.ARWB_Claim c ON c.ClaimID = s.ClaimID;

        UPDATE #src SET ChangeKind = 'New' WHERE ClaimKey IS NULL;

        /* ------------------------------------------------------------------------------------
           2. Latest line file per claim from dbo.LineLevelData - EVERY line, denied or not
           ------------------------------------------------------------------------------------ */
        DECLARE @SourceLineRows int = 0, @SourceDeniedLines int = 0, @LineOnlyClaims int = 0, @ClaimsLinesReloaded int = 0;
        DECLARE @HasLines bit = CASE WHEN OBJECT_ID(N'dbo.LineLevelData', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.LineLevelData', N'ClaimID') IS NOT NULL THEN 1 ELSE 0 END;

        CREATE TABLE #line
        (
            LineRowId               int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
            ClaimID                 nvarchar(200)  NOT NULL,
            SourceRecordId          int            NULL,
            CPTCode                 nvarchar(50)   NULL,
            CPTDescription          nvarchar(500)  NULL,
            Units                   decimal(9,2)   NULL,
            Modifier                nvarchar(100)  NULL,
            POS                     nvarchar(50)   NULL,
            TOS                     nvarchar(50)   NULL,
            ChargeAmount            decimal(18,2)  NOT NULL DEFAULT (0),
            AllowedAmount           decimal(18,2)  NOT NULL DEFAULT (0),
            InsurancePayment        decimal(18,2)  NOT NULL DEFAULT (0),
            PatientPayment          decimal(18,2)  NOT NULL DEFAULT (0),
            TotalPayments           decimal(18,2)  NOT NULL DEFAULT (0),
            InsuranceAdjustments    decimal(18,2)  NOT NULL DEFAULT (0),
            PatientAdjustments      decimal(18,2)  NOT NULL DEFAULT (0),
            TotalAdjustments        decimal(18,2)  NOT NULL DEFAULT (0),
            InsuranceBalance        decimal(18,2)  NOT NULL DEFAULT (0),
            PatientBalance          decimal(18,2)  NOT NULL DEFAULT (0),
            TotalBalance            decimal(18,2)  NOT NULL DEFAULT (0),
            LineClaimStatus         nvarchar(200)  NULL,
            PayStatus               nvarchar(200)  NULL,
            DenialCode              nvarchar(1000) NULL,
            DenialDate              date           NULL,
            CheckDate               date           NULL,
            PostingDate             date           NULL,
            ICDCode                 nvarchar(1000) NULL,
            ICDPointer              nvarchar(100)  NULL,
            SourceRowHash           nvarchar(64)   NULL
        );
        CREATE TABLE #lineSum (ClaimID nvarchar(200) NOT NULL PRIMARY KEY, LineChecksum int NULL);

        IF @HasLines = 1
        BEGIN
            DECLARE @LineMap TABLE (Ord int IDENTITY(1,1), TargetCol sysname, SourceCol sysname, Kind char(1), MaxLen int);
            INSERT INTO @LineMap (TargetCol, SourceCol, Kind, MaxLen) VALUES
                (N'ClaimID', N'ClaimID', 'T', 200),
                (N'SourceRecordId', N'RecordId', 'I', 0),
                (N'CPTCode', N'CPTCode', 'T', 50),
                (N'CPTDescription', N'CPTDescription', 'T', 500),
                (N'Units', N'Units', 'U', 0),
                (N'Modifier', N'Modifier', 'T', 100),
                (N'POS', N'POS', 'T', 50),
                (N'TOS', N'TOS', 'T', 50),
                (N'ChargeAmount', N'ChargeAmount', 'M', 0),
                (N'AllowedAmount', N'AllowedAmount', 'M', 0),
                (N'InsurancePayment', N'InsurancePayment', 'M', 0),
                (N'PatientPayment', N'PatientPayment', 'M', 0),
                (N'TotalPayments', N'TotalPayments', 'M', 0),
                (N'InsuranceAdjustments', N'InsuranceAdjustments', 'M', 0),
                (N'PatientAdjustments', N'PatientAdjustments', 'M', 0),
                (N'TotalAdjustments', N'TotalAdjustments', 'M', 0),
                (N'InsuranceBalance', N'InsuranceBalance', 'M', 0),
                (N'PatientBalance', N'PatientBalance', 'M', 0),
                (N'TotalBalance', N'TotalBalance', 'M', 0),
                (N'LineClaimStatus', N'ClaimStatus', 'T', 200),
                (N'PayStatus', N'PayStatus', 'T', 200),
                (N'DenialCode', N'DenialCode', 'T', 1000),
                (N'DenialDate', N'DenialDate', 'D', 0),
                (N'CheckDate', N'CheckDate', 'D', 0),
                (N'PostingDate', N'PostingDate', 'D', 0),
                (N'ICDCode', N'ICDCode', 'T', 1000),
                (N'ICDPointer', N'ICDPointer', 'T', 100),
                (N'SourceRowHash', N'RowHash', 'T', 64);

            SELECT @Cols = STUFF((
                    SELECT N', ' + QUOTENAME(m.TargetCol) FROM @LineMap m ORDER BY m.Ord
                    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
                   @Exprs = STUFF((
                    SELECT N', ' +
                        CASE
                            WHEN COL_LENGTH(N'dbo.LineLevelData', m.SourceCol) IS NULL THEN CASE m.Kind WHEN 'M' THEN N'0' ELSE N'NULL' END
                            WHEN m.Kind = 'T' THEN N'LEFT(NULLIF(NULLIF(LTRIM(RTRIM(r.' + QUOTENAME(m.SourceCol) + N')), N''''), N''NULL''), ' + CONVERT(nvarchar(10), m.MaxLen) + N')'
                            WHEN m.Kind = 'M' THEN N'ISNULL((SELECT x.Amount FROM dbo.ARWB_tvf_ParseMoney(r.' + QUOTENAME(m.SourceCol) + N') x), 0)'
                            WHEN m.Kind = 'D' THEN N'(SELECT x.DateValue FROM dbo.ARWB_tvf_ParseDate(r.' + QUOTENAME(m.SourceCol) + N') x)'
                            WHEN m.Kind = 'I' THEN N'TRY_CONVERT(int, r.' + QUOTENAME(m.SourceCol) + N')'
                            WHEN m.Kind = 'U' THEN N'TRY_CONVERT(decimal(9,2), (SELECT x.Amount FROM dbo.ARWB_tvf_ParseMoney(r.' + QUOTENAME(m.SourceCol) + N') x))'
                        END
                    FROM @LineMap m ORDER BY m.Ord
                    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

            -- Only the latest line file per claim (LineLevelData can hold more than one load).
            SET @Rank =
                CASE WHEN COL_LENGTH(N'dbo.LineLevelData', N'FileLogId') IS NOT NULL
                         THEN N'DENSE_RANK() OVER (PARTITION BY LTRIM(RTRIM(r.ClaimID)) ORDER BY ISNULL(TRY_CONVERT(int, r.FileLogId), 0) DESC)'
                     WHEN COL_LENGTH(N'dbo.LineLevelData', N'InsertedDateTime') IS NOT NULL
                         THEN N'DENSE_RANK() OVER (PARTITION BY LTRIM(RTRIM(r.ClaimID)) ORDER BY CONVERT(date, r.InsertedDateTime) DESC)'
                     ELSE N'1' END;

            -- Every line of every synced claim, whatever its denial state.
            SET @Sql = N'
;WITH ranked AS
(
    SELECT r.*, arwb_rk = ' + @Rank + N'
    FROM dbo.LineLevelData r
    WHERE EXISTS (SELECT 1 FROM #src s WHERE s.ClaimID = LTRIM(RTRIM(r.ClaimID)))
)
INSERT INTO #line (' + @Cols + N')
SELECT ' + @Exprs + N'
FROM ranked r
WHERE r.arwb_rk = 1;

SELECT @LineOnly = COUNT(DISTINCT LTRIM(RTRIM(r.ClaimID)))
FROM dbo.LineLevelData r
WHERE NULLIF(LTRIM(RTRIM(r.ClaimID)), N'''') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.ClaimID = LTRIM(RTRIM(r.ClaimID)));';

            EXEC sys.sp_executesql @Sql, N'@LineOnly int OUTPUT', @LineOnly = @LineOnlyClaims OUTPUT;

            SET @SourceLineRows    = (SELECT COUNT(*) FROM #line);
            SET @SourceDeniedLines = (SELECT COUNT(*) FROM #line WHERE DenialCode IS NOT NULL);

            CREATE NONCLUSTERED INDEX IX_line_Claim ON #line (ClaimID, SourceRecordId);

            INSERT INTO #lineSum (ClaimID, LineChecksum)
            SELECT l.ClaimID,
                   CHECKSUM_AGG(CHECKSUM(l.CPTCode, l.Units, l.Modifier, l.ChargeAmount, l.AllowedAmount, l.InsurancePayment, l.PatientPayment,
                                         l.InsuranceAdjustments, l.InsuranceBalance, l.PatientBalance, l.DenialCode,
                                         l.LineClaimStatus, l.PayStatus, l.DenialDate, l.CheckDate, l.PostingDate))
            FROM #line l
            GROUP BY l.ClaimID;
        END;

        /* ------------------------------------------------------------------------------------
           3. Apply (one transaction, so a failure never leaves a half-synced week)
           ------------------------------------------------------------------------------------ */
        CREATE TABLE #changed
        (
            ClaimKey                bigint        NOT NULL PRIMARY KEY,
            OldInsuranceBalance     decimal(18,2) NULL,
            NewInsuranceBalance     decimal(18,2) NULL,
            OldInsurancePayment     decimal(18,2) NULL,
            NewInsurancePayment     decimal(18,2) NULL,
            OldPatientBalance       decimal(18,2) NULL,
            NewPatientBalance       decimal(18,2) NULL
        );
        CREATE TABLE #new    (ClaimKey bigint NOT NULL PRIMARY KEY, ClaimID nvarchar(200) NOT NULL);
        CREATE TABLE #reload (ClaimKey bigint NOT NULL PRIMARY KEY, ClaimID nvarchar(200) NOT NULL, LineChecksum int NULL);
        CREATE TABLE #den
        (
            ClaimKey            bigint         NOT NULL PRIMARY KEY,
            IsExisting          bit            NOT NULL,
            OldPrimary          nvarchar(50)   NULL,
            NewPrimary          nvarchar(50)   NULL,
            NewPrimaryRaw       nvarchar(100)  NULL,
            NewGroupCode        varchar(2)     NULL,
            NewCategory         nvarchar(200)  NULL,
            NewTemplate         varchar(50)    NULL,
            NewReason           nvarchar(1000) NULL,
            IsNewNonCollectible bit            NOT NULL DEFAULT (0),
            WorkflowStatus      varchar(30)    NULL,
            WorkedStatus        varchar(20)    NULL,
            AssignedAgentUser   nvarchar(256)  NULL,
            IsChanged           bit            NOT NULL DEFAULT (0),
            ResyncRule          varchar(20)    NULL       -- AutoUnassign | NewDenialFlag
        );
        CREATE TABLE #adj (ClaimKey bigint NOT NULL PRIMARY KEY, AgentUser nvarchar(256) NULL, Kind varchar(10) NOT NULL);   -- NotPosted | Posted

        DECLARE @NoLongerInSource int, @DenialChanged int = 0, @AutoUnassigned int = 0, @NewDenialFlagged int = 0,
                @AdjNotPosted int = 0, @AdjPosted int = 0;

        BEGIN TRANSACTION;

        -- 3a. Changed claims: refresh source columns, keep workflow state
        UPDATE c
        SET c.LabId = s.LabId, c.LabName = s.LabName, c.AccessionNumber = s.AccessionNumber,
            c.PatientID = s.PatientID, c.PatientName = s.PatientName, c.PatientDOB = s.PatientDOB, c.SubscriberId = s.SubscriberId,
            c.PayerName = s.PayerName, c.PayerNameRaw = s.PayerNameRaw, c.PayerCode = s.PayerCode, c.PayerType = s.PayerType, c.ClaimType = s.ClaimType,
            c.BillingProvider = s.BillingProvider, c.ReferringProvider = s.ReferringProvider, c.ClinicName = s.ClinicName, c.SalesRepName = s.SalesRepName,
            c.PanelName = s.PanelName, c.PanelType = s.PanelType,
            c.DateOfService = s.DateOfService, c.ChargeEnteredDate = s.ChargeEnteredDate, c.FirstBilledDate = s.FirstBilledDate,
            c.CheckDate = s.CheckDate, c.SourceLastActivityDate = s.SourceLastActivityDate,
            c.CptSummary = s.CptSummary, c.ICDCode = s.ICDCode,
            c.SourceClaimStatus = s.SourceClaimStatus, c.DeniedStatus = s.DeniedStatus,
            c.DenialCode = s.DenialCode,          -- the curated column as received; a cleared value means "no longer denied"
            c.ChargeAmount = s.ChargeAmount, c.AllowedAmount = s.AllowedAmount,
            c.InsurancePayment = s.InsurancePayment, c.PatientPayment = s.PatientPayment, c.TotalPayments = s.TotalPayments,
            c.InsuranceAdjustments = s.InsuranceAdjustments, c.PatientAdjustments = s.PatientAdjustments, c.TotalAdjustments = s.TotalAdjustments,
            c.InsuranceBalance = s.InsuranceBalance, c.PatientBalance = s.PatientBalance, c.TotalBalance = s.TotalBalance,
            c.SourceRecordId = s.SourceRecordId, c.SourceRunId = s.SourceRunId, c.SourceRowHash = s.RowHash,
            c.IsInCurrentSource = 1, c.LastRefreshRunId = @RunId, c.LastRefreshedOn = @Now,
            c.UpdatedOn = @Now, c.UpdatedBy = N'System'
        OUTPUT inserted.ClaimKey,
               deleted.InsuranceBalance, inserted.InsuranceBalance,
               deleted.InsurancePayment, inserted.InsurancePayment,
               deleted.PatientBalance,   inserted.PatientBalance
        INTO #changed (ClaimKey, OldInsuranceBalance, NewInsuranceBalance, OldInsurancePayment, NewInsurancePayment,
                       OldPatientBalance, NewPatientBalance)
        FROM dbo.ARWB_Claim c
        INNER JOIN #src s ON s.ClaimKey = c.ClaimKey
        WHERE s.ChangeKind = 'Changed';

        -- Unchanged claims: just stamp the run
        UPDATE c
        SET c.IsInCurrentSource = 1, c.LastRefreshRunId = @RunId, c.LastRefreshedOn = @Now,
            c.SourceRecordId = s.SourceRecordId, c.SourceRunId = s.SourceRunId
        FROM dbo.ARWB_Claim c
        INNER JOIN #src s ON s.ClaimKey = c.ClaimKey
        WHERE s.ChangeKind = 'Same';

        -- New claims: Initial* frozen here
        INSERT INTO dbo.ARWB_Claim
        (
            ClaimID, LabId, LabName, AccessionNumber, PatientID, PatientName, PatientDOB, SubscriberId,
            PayerName, PayerNameRaw, PayerCode, PayerType, ClaimType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepName, PanelName, PanelType,
            DateOfService, ChargeEnteredDate, FirstBilledDate, CheckDate, SourceLastActivityDate, CptSummary, ICDCode,
            SourceClaimStatus, DeniedStatus, DenialCode,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments, InsuranceBalance, PatientBalance, TotalBalance,
            InitialInsuranceAR, InitialInsurancePayment, InitialInsuranceAdjustments, RemainingAR,
            WorkflowStatus, WorkedStatus,
            SourceRecordId, SourceRunId, SourceRowHash, IsInCurrentSource,
            FirstIdentifiedOn, FirstRefreshRunId, LastRefreshRunId, LastRefreshedOn, LastTouchedOn, UpdatedOn, UpdatedBy
        )
        OUTPUT inserted.ClaimKey, inserted.ClaimID INTO #new (ClaimKey, ClaimID)
        SELECT
            s.ClaimID, s.LabId, s.LabName, s.AccessionNumber, s.PatientID, s.PatientName, s.PatientDOB, s.SubscriberId,
            s.PayerName, s.PayerNameRaw, s.PayerCode, s.PayerType, s.ClaimType,
            s.BillingProvider, s.ReferringProvider, s.ClinicName, s.SalesRepName, s.PanelName, s.PanelType,
            s.DateOfService, s.ChargeEnteredDate, s.FirstBilledDate, s.CheckDate, s.SourceLastActivityDate, s.CptSummary, s.ICDCode,
            s.SourceClaimStatus, s.DeniedStatus, s.DenialCode,
            s.ChargeAmount, s.AllowedAmount, s.InsurancePayment, s.PatientPayment, s.TotalPayments,
            s.InsuranceAdjustments, s.PatientAdjustments, s.TotalAdjustments, s.InsuranceBalance, s.PatientBalance, s.TotalBalance,
            CASE WHEN s.InsuranceBalance > 0 THEN s.InsuranceBalance ELSE 0 END, s.InsurancePayment, s.InsuranceAdjustments,
            CASE WHEN s.InsuranceBalance > 0 THEN s.InsuranceBalance ELSE 0 END,
            'Unassigned', 'Not Worked',
            s.SourceRecordId, s.SourceRunId, s.RowHash, 1,
            @Now, @RunId, @RunId, @Now, @Now, @Now, N'System'
        FROM #src s
        WHERE s.ChangeKind = 'New';

        UPDATE s SET s.ClaimKey = n.ClaimKey
        FROM #src s INNER JOIN #new n ON n.ClaimID = s.ClaimID;

        -- Claims that dropped out of the source feed are kept, flagged.
        UPDATE c
        SET c.IsInCurrentSource = 0, c.LastRefreshedOn = @Now
        FROM dbo.ARWB_Claim c
        WHERE c.IsInCurrentSource = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.ClaimKey = c.ClaimKey);
        SET @NoLongerInSource = @@ROWCOUNT;

        -- 3b. Point-in-time history (first sync + every financial / denial change) and activity
        INSERT INTO dbo.ARWB_ClaimFinancialHistory
        (
            ClaimKey, RefreshRunId, SnapshotOn, ChangeType,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance, SourceClaimStatus, DenialCode
        )
        SELECT c.ClaimKey, @RunId, @Now, CASE WHEN n.ClaimKey IS NOT NULL THEN 'Identified' ELSE 'SourceChanged' END,
               c.ChargeAmount, c.AllowedAmount, c.InsurancePayment, c.PatientPayment, c.InsuranceAdjustments, c.PatientAdjustments,
               c.InsuranceBalance, c.PatientBalance, c.TotalBalance, c.SourceClaimStatus, c.DenialCode
        FROM dbo.ARWB_Claim c
        LEFT JOIN #new n     ON n.ClaimKey = c.ClaimKey
        LEFT JOIN #changed x ON x.ClaimKey = c.ClaimKey
        WHERE n.ClaimKey IS NOT NULL OR x.ClaimKey IS NOT NULL;

        -- Every claim gets "Claim Identified", which makes "days since last touch" work for claims
        -- nobody has ever assigned.
        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, NewValue, UserName, RoleCode, IsSystem, RelatedEntityType, RelatedEntityId)
        SELECT n.ClaimKey, @Now, N'Claim Identified',
               LEFT(N'Claim synced from the claim-level master file (refresh #' + CONVERT(nvarchar(20), @RunId) + N')'
                    + CASE WHEN s.DenialCode IS NOT NULL THEN N'; denial ' + s.DenialCode ELSE N'; no denial' END + N'.', 2000),
               LEFT(s.DenialCode, 1000), N'System', 'ETL', 1, 'RefreshRun', @RunId
        FROM #new n
        INNER JOIN #src s ON s.ClaimKey = n.ClaimKey;

        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, UserName, RoleCode, IsSystem, RelatedEntityType, RelatedEntityId)
        SELECT x.ClaimKey, @Now, N'Source Data Updated',
               LEFT(
                   CASE WHEN x.OldInsuranceBalance <> x.NewInsuranceBalance
                        THEN N'Insurance balance ' + CONVERT(nvarchar(30), x.OldInsuranceBalance) + N' -> ' + CONVERT(nvarchar(30), x.NewInsuranceBalance) + N'. ' ELSE N'' END
                 + CASE WHEN x.OldInsurancePayment <> x.NewInsurancePayment
                        THEN N'Insurance payment ' + CONVERT(nvarchar(30), x.OldInsurancePayment) + N' -> ' + CONVERT(nvarchar(30), x.NewInsurancePayment) + N'. ' ELSE N'' END
                 + CASE WHEN x.OldPatientBalance <> x.NewPatientBalance
                        THEN N'Patient balance ' + CONVERT(nvarchar(30), x.OldPatientBalance) + N' -> ' + CONVERT(nvarchar(30), x.NewPatientBalance) + N'. ' ELSE N'' END
                 + N'(refresh #' + CONVERT(nvarchar(20), @RunId) + N')', 2000),
               N'System', 'ETL', 1, 'RefreshRun', @RunId
        FROM #changed x
        WHERE x.OldInsuranceBalance <> x.NewInsuranceBalance
           OR x.OldInsurancePayment <> x.NewInsurancePayment
           OR x.OldPatientBalance   <> x.NewPatientBalance;

        -- 3c. Lines: reload only claims whose line set changed
        INSERT INTO #reload (ClaimKey, ClaimID, LineChecksum)
        SELECT c.ClaimKey, c.ClaimID, ls.LineChecksum
        FROM #src s
        INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = s.ClaimKey
        INNER JOIN #lineSum ls      ON ls.ClaimID = s.ClaimID
        WHERE c.LineSetChecksum IS NULL OR c.LineSetChecksum <> ls.LineChecksum;
        SET @ClaimsLinesReloaded = @@ROWCOUNT;

        DELETE ld
        FROM dbo.ARWB_ClaimLineDenial ld
        INNER JOIN #reload r ON r.ClaimKey = ld.ClaimKey;

        DELETE cl
        FROM dbo.ARWB_ClaimLine cl
        INNER JOIN #reload r ON r.ClaimKey = cl.ClaimKey;

        INSERT INTO dbo.ARWB_ClaimLine
        (
            ClaimKey, ClaimID, LineNumber, CPTCode, CPTDescription, Units, Modifier, POS, TOS,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
            InsuranceAdjustments, PatientAdjustments, TotalAdjustments, InsuranceBalance, PatientBalance, TotalBalance,
            LineClaimStatus, PayStatus, DenialCode, HasDenial, DenialDate, CheckDate, PostingDate, ICDCode, ICDPointer,
            SourceRecordId, SourceRowHash, RefreshRunId, LoadedOn
        )
        SELECT r.ClaimKey, l.ClaimID,
               ROW_NUMBER() OVER (PARTITION BY l.ClaimID ORDER BY l.SourceRecordId, l.LineRowId),
               l.CPTCode, l.CPTDescription, l.Units, l.Modifier, l.POS, l.TOS,
               l.ChargeAmount, l.AllowedAmount, l.InsurancePayment, l.PatientPayment, l.TotalPayments,
               l.InsuranceAdjustments, l.PatientAdjustments, l.TotalAdjustments, l.InsuranceBalance, l.PatientBalance, l.TotalBalance,
               l.LineClaimStatus, l.PayStatus, l.DenialCode, 0, l.DenialDate, l.CheckDate, l.PostingDate, l.ICDCode, l.ICDPointer,
               l.SourceRecordId, l.SourceRowHash, @RunId, @Now
        FROM #line l
        INNER JOIN #reload r ON r.ClaimID = l.ClaimID;

        -- One row per denial code on each reloaded line (raw prefix kept for display, normalized for mapping)
        INSERT INTO dbo.ARWB_ClaimLineDenial
            (ClaimLineKey, ClaimKey, Ordinal, DenialCodeRaw, GroupCode, DenialCode, CodeType, DenialCategory, DenialReason, IsNonCollectible)
        SELECT cl.ClaimLineKey, cl.ClaimKey, d.Ordinal, d.RawCode, d.GroupCode, d.DenialCode, d.CodeType,
               mp.DenialCategory,
               COALESCE(dcm.DenialDescription, mp.DenialReason),
               CASE WHEN nc.ItemValue IS NOT NULL THEN 1 ELSE 0 END
        FROM dbo.ARWB_ClaimLine cl
        INNER JOIN #reload r ON r.ClaimKey = cl.ClaimKey
        CROSS APPLY dbo.ARWB_tvf_SplitDenialCodes(LEFT(cl.DenialCode, 4000)) d
        LEFT JOIN dbo.ARWB_DenialCodeCategoryMap mp ON mp.DenialCode = d.DenialCode AND mp.IsActive = 1
        LEFT JOIN #dcm dcm ON dcm.DenialCode = d.DenialCode
        LEFT JOIN dbo.ARWB_MasterListItem nc ON nc.ListType = 'NON_COLLECTIBLE_CODE' AND nc.IsActive = 1 AND nc.ItemValue = d.DenialCode
        WHERE cl.DenialCode IS NOT NULL;

        UPDATE cl SET cl.HasDenial = 1
        FROM dbo.ARWB_ClaimLine cl
        INNER JOIN #reload r ON r.ClaimKey = cl.ClaimKey
        WHERE EXISTS (SELECT 1 FROM dbo.ARWB_ClaimLineDenial ld WHERE ld.ClaimLineKey = cl.ClaimLineKey);

        -- Claim-level line rollup
        UPDATE c
        SET c.LineSetChecksum = r.LineChecksum,
            c.LineCount       = ISNULL(agg.LineCount, 0),
            c.DeniedLineCount = ISNULL(agg.DeniedLineCount, 0),
            c.DenialDate      = COALESCE(agg.MinDenialDate, c.DenialDate),
            c.LineDenialCodes = LEFT(STUFF((
                                    SELECT N',' + x.DenialCode
                                    FROM (SELECT DISTINCT ld.DenialCode FROM dbo.ARWB_ClaimLineDenial ld WHERE ld.ClaimKey = r.ClaimKey) x
                                    ORDER BY x.DenialCode
                                    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N''), 2000)
        FROM dbo.ARWB_Claim c
        INNER JOIN #reload r ON r.ClaimKey = c.ClaimKey
        OUTER APPLY
        (
            SELECT LineCount       = COUNT(*),
                   DeniedLineCount = SUM(CASE WHEN cl.HasDenial = 1 THEN 1 ELSE 0 END),
                   MinDenialDate   = MIN(cl.DenialDate)
            FROM dbo.ARWB_ClaimLine cl
            WHERE cl.ClaimKey = r.ClaimKey
        ) agg;

        -- Master-data reprocess: refresh the line denial mappings for every line.
        IF @ReprocessAll = 1
            UPDATE ld
            SET ld.DenialCategory   = mp.DenialCategory,
                ld.DenialReason     = COALESCE(dcm.DenialDescription, mp.DenialReason),
                ld.IsNonCollectible = CASE WHEN nc.ItemValue IS NOT NULL THEN 1 ELSE 0 END
            FROM dbo.ARWB_ClaimLineDenial ld
            LEFT JOIN dbo.ARWB_DenialCodeCategoryMap mp ON mp.DenialCode = ld.DenialCode AND mp.IsActive = 1
            LEFT JOIN #dcm dcm ON dcm.DenialCode = ld.DenialCode
            LEFT JOIN dbo.ARWB_MasterListItem nc ON nc.ListType = 'NON_COLLECTIBLE_CODE' AND nc.IsActive = 1 AND nc.ItemValue = ld.DenialCode;

        -- 3d. Primary denial for new / changed claims, claims whose lines changed, or every claim on reprocess
        INSERT INTO #den (ClaimKey, IsExisting, OldPrimary, NewPrimary, NewPrimaryRaw, NewGroupCode,
                          WorkflowStatus, WorkedStatus, AssignedAgentUser)
        SELECT c.ClaimKey,
               CASE WHEN n.ClaimKey IS NULL THEN 1 ELSE 0 END,
               c.PrimaryDenialCode,
               pick.DenialCode, pick.RawCode, pick.GroupCode,
               c.WorkflowStatus, c.WorkedStatus, c.AssignedAgentUser
        FROM dbo.ARWB_Claim c
        LEFT JOIN #new n ON n.ClaimKey = c.ClaimKey
        -- first code written in the curated claim-level column
        OUTER APPLY (SELECT TOP (1) d.RawCode, d.GroupCode, d.DenialCode
                     FROM dbo.ARWB_tvf_SplitDenialCodes(LEFT(c.DenialCode, 4000)) d ORDER BY d.Ordinal) cur
        -- Phase 2: the highest-ranked code across the curated column and the lines
        OUTER APPLY (SELECT TOP (1) x.RawCode, x.GroupCode, x.DenialCode
                     FROM (SELECT d.RawCode, d.GroupCode, d.DenialCode, Src = 0, Ord = d.Ordinal
                           FROM dbo.ARWB_tvf_SplitDenialCodes(LEFT(c.DenialCode, 4000)) d
                           UNION ALL
                           SELECT ld.DenialCodeRaw, ld.GroupCode, ld.DenialCode, 1, ld.Ordinal
                           FROM dbo.ARWB_ClaimLineDenial ld WHERE ld.ClaimKey = c.ClaimKey) x
                     INNER JOIN dbo.ARWB_DenialCodeRank rk ON rk.DenialCode = x.DenialCode
                     WHERE @UseRanking = 1
                     ORDER BY rk.RankOrder, x.Src, x.Ord) rnk
        -- optional fallback: first line-level code when the curated column is blank
        OUTER APPLY (SELECT TOP (1) ld.DenialCodeRaw AS RawCode, ld.GroupCode, ld.DenialCode
                     FROM dbo.ARWB_ClaimLineDenial ld
                     INNER JOIN dbo.ARWB_ClaimLine cl ON cl.ClaimLineKey = ld.ClaimLineKey
                     WHERE @LineFallback = 1 AND ld.ClaimKey = c.ClaimKey
                     ORDER BY cl.LineNumber, ld.Ordinal) lnf
        CROSS APPLY
        (
            SELECT DenialCode = CASE WHEN rnk.DenialCode IS NOT NULL THEN rnk.DenialCode WHEN cur.DenialCode IS NOT NULL THEN cur.DenialCode ELSE lnf.DenialCode END,
                   RawCode    = CASE WHEN rnk.DenialCode IS NOT NULL THEN rnk.RawCode    WHEN cur.DenialCode IS NOT NULL THEN cur.RawCode    ELSE lnf.RawCode    END,
                   GroupCode  = CASE WHEN rnk.DenialCode IS NOT NULL THEN rnk.GroupCode  WHEN cur.DenialCode IS NOT NULL THEN cur.GroupCode  ELSE lnf.GroupCode  END
        ) pick
        WHERE @ReprocessAll = 1
           OR EXISTS (SELECT 1 FROM #src s WHERE s.ClaimKey = c.ClaimKey AND s.ChangeKind IN ('New', 'Changed'))
           OR EXISTS (SELECT 1 FROM #reload r WHERE r.ClaimKey = c.ClaimKey);

        UPDATE d
        SET d.NewCategory = CASE WHEN d.NewPrimary IS NULL THEN NULL ELSE COALESCE(mp.DenialCategory, N'Other') END,
            d.NewTemplate = CASE WHEN d.NewPrimary IS NOT NULL THEN COALESCE(dt.TemplateKey, 'denied')
                                 WHEN c.InsurancePayment > @Eps THEN 'partial_payment'
                                 ELSE 'non_responded' END,
            d.NewReason   = CASE WHEN d.NewPrimary IS NULL THEN NULL ELSE COALESCE(dcm.DenialDescription, mp.DenialReason) END,
            d.IsNewNonCollectible = CASE WHEN nc.ItemValue IS NOT NULL THEN 1 ELSE 0 END,
            d.IsChanged   = CASE WHEN d.IsExisting = 1 AND ISNULL(d.OldPrimary, N'') <> ISNULL(d.NewPrimary, N'') THEN 1 ELSE 0 END
        FROM #den d
        INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = d.ClaimKey
        LEFT JOIN dbo.ARWB_DenialCodeCategoryMap mp ON mp.DenialCode = d.NewPrimary AND mp.IsActive = 1
        LEFT JOIN dbo.ARWB_DenialCategoryTemplate dt ON dt.DenialCategory = COALESCE(mp.DenialCategory, N'Other')
        LEFT JOIN #dcm dcm ON dcm.DenialCode = d.NewPrimary
        LEFT JOIN dbo.ARWB_MasterListItem nc ON nc.ListType = 'NON_COLLECTIBLE_CODE' AND nc.IsActive = 1 AND nc.ItemValue = d.NewPrimary;

        SET @DenialChanged = (SELECT COUNT(*) FROM #den WHERE IsChanged = 1);

        -- 3e. Re-sync rules - decided on the state BEFORE this sync touched the claim
        UPDATE #den
        SET ResyncRule = CASE
                WHEN WorkflowStatus = 'Assigned' AND WorkedStatus = 'Not Worked' AND IsNewNonCollectible = 1 THEN 'AutoUnassign'
                WHEN WorkflowStatus IN ('Submitted for QA', 'QA Rejected', 'Completed')                    THEN 'NewDenialFlag'
                END
        WHERE IsChanged = 1 AND NewPrimary IS NOT NULL;

        UPDATE c
        SET c.PrimaryDenialCode         = d.NewPrimary,
            c.PrimaryDenialCodeRaw      = d.NewPrimaryRaw,
            c.PrimaryDenialGroupCode    = d.NewGroupCode,
            c.DenialCategory            = CASE WHEN c.IsDenialCategoryManual = 1 AND d.NewPrimary IS NOT NULL THEN c.DenialCategory ELSE d.NewCategory END,
            c.WorkflowTemplateKey       = CASE WHEN c.IsDenialCategoryManual = 1 AND d.NewPrimary IS NOT NULL THEN c.WorkflowTemplateKey ELSE d.NewTemplate END,
            c.DenialReason              = d.NewReason,
            c.PreviousPrimaryDenialCode = CASE WHEN d.IsChanged = 1 THEN d.OldPrimary ELSE c.PreviousPrimaryDenialCode END,
            c.PrimaryDenialChangedOn    = CASE WHEN d.IsChanged = 1 THEN @Now ELSE c.PrimaryDenialChangedOn END,
            -- Assigned, not yet worked, new denial is Non-Collectible: out of the agent's queue.
            c.WorkflowStatus            = CASE WHEN d.ResyncRule = 'AutoUnassign' THEN 'Unassigned' ELSE c.WorkflowStatus END,
            -- Worked claim with a new denial: flagged; a Completed one goes back unassigned now,
            -- one still in QA goes back when QA completes (the API clears the agent on approval).
            c.NewDenialSinceWork        = CASE WHEN d.ResyncRule = 'NewDenialFlag' THEN 1 ELSE c.NewDenialSinceWork END,
            c.AssignedAgentUser         = CASE WHEN d.ResyncRule = 'AutoUnassign'
                                                 OR (d.ResyncRule = 'NewDenialFlag' AND d.WorkflowStatus = 'Completed') THEN NULL ELSE c.AssignedAgentUser END,
            c.AssignedOn                = CASE WHEN d.ResyncRule = 'AutoUnassign'
                                                 OR (d.ResyncRule = 'NewDenialFlag' AND d.WorkflowStatus = 'Completed') THEN NULL ELSE c.AssignedOn END,
            c.UpdatedOn                 = CASE WHEN d.IsChanged = 1 THEN @Now ELSE c.UpdatedOn END,
            c.UpdatedBy                 = CASE WHEN d.IsChanged = 1 THEN N'System' ELSE c.UpdatedBy END
        FROM dbo.ARWB_Claim c
        INNER JOIN #den d ON d.ClaimKey = c.ClaimKey;

        SET @AutoUnassigned   = (SELECT COUNT(*) FROM #den WHERE ResyncRule = 'AutoUnassign');
        SET @NewDenialFlagged = (SELECT COUNT(*) FROM #den WHERE ResyncRule = 'NewDenialFlag');

        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, IsSystem, RelatedEntityType, RelatedEntityId)
        SELECT d.ClaimKey, @Now, N'Denial Code Changed',
               LEFT(N'Primary denial ' + ISNULL(d.OldPrimary, N'none') + N' -> ' + ISNULL(d.NewPrimary, N'none')
                    + N' on sync (refresh #' + CONVERT(nvarchar(20), @RunId) + N').', 2000),
               d.OldPrimary, d.NewPrimary, N'System', 'ETL', 1, 'RefreshRun', @RunId
        FROM #den d
        WHERE d.IsChanged = 1;

        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, PreviousValue, NewValue, UserName, RoleCode, IsSystem, RelatedEntityType, RelatedEntityId)
        SELECT d.ClaimKey, @Now,
               CASE d.ResyncRule WHEN 'AutoUnassign' THEN N'Auto-Processed - Non-Collectible Denial' ELSE N'New Denial Received' END,
               CASE d.ResyncRule
                    WHEN 'AutoUnassign' THEN N'New primary denial ' + d.NewPrimary + N' is Non-Collectible; claim removed from ' + ISNULL(d.AssignedAgentUser, N'the agent') + N'''s queue.'
                    ELSE N'New primary denial ' + d.NewPrimary + N' after the claim was worked (' + d.WorkflowStatus + N'); returns to Re-Follow-Up Required - New Denials for reassignment.' END,
               d.AssignedAgentUser, CASE WHEN d.ResyncRule = 'AutoUnassign' OR d.WorkflowStatus = 'Completed' THEN NULL ELSE d.AssignedAgentUser END,
               N'System', 'Automation', 1, 'RefreshRun', @RunId
        FROM #den d
        WHERE d.ResyncRule IS NOT NULL;

        INSERT INTO dbo.ARWB_Notification (ClaimKey, RecipientUser, RecipientRole, NotificationType, Message, CreatedOn, RelatedEntityType, RelatedEntityId)
        SELECT d.ClaimKey, d.AssignedAgentUser, NULL, 'AutoUnassigned',
               N'Claim ' + c.ClaimID + N' was removed from your queue: new denial ' + d.NewPrimary + N' is Non-Collectible.', @Now, 'RefreshRun', @RunId
        FROM #den d INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = d.ClaimKey
        WHERE d.ResyncRule = 'AutoUnassign' AND d.AssignedAgentUser IS NOT NULL
        UNION ALL
        SELECT d.ClaimKey, NULL, 'manager', 'NewDenial',
               N'Claim ' + c.ClaimID + N' received new denial ' + d.NewPrimary + N' after it was worked; reassign from Re-Follow-Up Required - New Denials.', @Now, 'RefreshRun', @RunId
        FROM #den d INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = d.ClaimKey
        WHERE d.ResyncRule = 'NewDenialFlag';

        -- Auto-adjusted / written-off claims: still open in the master, or now posted.
        INSERT INTO #adj (ClaimKey, AgentUser, Kind)
        SELECT c.ClaimKey, c.AssignedAgentUser,
               CASE WHEN c.InsuranceBalance > @Eps THEN 'NotPosted' ELSE 'Posted' END
        FROM dbo.ARWB_Claim c
        WHERE c.IsInCurrentSource = 1
          AND (c.IsAutoAdjusted = 1 OR c.IsWriteOffApproved = 1)
          AND (   -- adjusted before this sync and the master still shows the balance
                  (c.InsuranceBalance > @Eps
                   AND COALESCE(c.AutoAdjustedOn, c.WriteOffApprovedOn) <= @Now
                   AND (c.IsAdjustmentNotPosted = 0 OR c.IsPmsPostedConfirmed = 1))
               -- the master now shows it posted
               OR (c.InsuranceBalance <= @Eps AND (c.IsPmsPostedConfirmed = 0 OR c.IsAdjustmentNotPosted = 1)));

        UPDATE c
        SET c.IsAdjustmentNotPosted = CASE WHEN a.Kind = 'NotPosted' THEN 1 ELSE 0 END,
            c.AdjustmentNotPostedOn = CASE WHEN a.Kind = 'NotPosted' THEN @Now ELSE c.AdjustmentNotPostedOn END,
            c.IsPmsPostedConfirmed  = CASE WHEN a.Kind = 'NotPosted' THEN 0 ELSE 1 END,
            c.PmsPostedOn           = CASE WHEN a.Kind = 'NotPosted' THEN NULL ELSE COALESCE(c.PmsPostedOn, @Now) END,
            c.PmsPostedBy           = CASE WHEN a.Kind = 'NotPosted' THEN NULL ELSE COALESCE(c.PmsPostedBy, N'System') END
        FROM dbo.ARWB_Claim c
        INNER JOIN #adj a ON a.ClaimKey = c.ClaimKey;

        SET @AdjNotPosted = (SELECT COUNT(*) FROM #adj WHERE Kind = 'NotPosted');
        SET @AdjPosted    = (SELECT COUNT(*) FROM #adj WHERE Kind = 'Posted');

        INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, UserName, RoleCode, IsSystem, RelatedEntityType, RelatedEntityId)
        SELECT a.ClaimKey, @Now,
               CASE a.Kind WHEN 'NotPosted' THEN N'Adjustment Not Posted' ELSE N'Adjustment Posted in PMS' END,
               CASE a.Kind WHEN 'NotPosted' THEN N'Adjusted / written off in the workbench but still open in the master file; returned to Auto Adjustments.'
                           ELSE N'The master file shows the adjustment posted; confirmed automatically.' END,
               N'System', 'ETL', 1, 'RefreshRun', @RunId
        FROM #adj a;

        INSERT INTO dbo.ARWB_Notification (ClaimKey, RecipientUser, RecipientRole, NotificationType, Message, CreatedOn, RelatedEntityType, RelatedEntityId)
        SELECT a.ClaimKey, a.AgentUser, NULL, 'AdjustmentNotPosted',
               N'Claim ' + c.ClaimID + N' is still open in the master file: the adjustment / write-off has not been posted in the PMS.', @Now, 'RefreshRun', @RunId
        FROM #adj a INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = a.ClaimKey
        WHERE a.Kind = 'NotPosted' AND a.AgentUser IS NOT NULL
        UNION ALL
        SELECT a.ClaimKey, NULL, 'manager', 'AdjustmentNotPosted',
               N'Claim ' + c.ClaimID + N' is still open in the master file: the adjustment / write-off has not been posted in the PMS.', @Now, 'RefreshRun', @RunId
        FROM #adj a INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = a.ClaimKey
        WHERE a.Kind = 'NotPosted';

        -- 3f. Revenue Expectation for the lines loaded now (or every line on reprocess)
        CREATE TABLE #priced (PricedLines int);
        IF @ReprocessAll = 1
            INSERT INTO #priced EXEC dbo.ARWB_usp_PriceClaimLines;
        ELSE
            INSERT INTO #priced EXEC dbo.ARWB_usp_PriceClaimLines @RefreshRunId = @RunId;

        COMMIT TRANSACTION;

        /* ------------------------------------------------------------------------------------
           4. Derived state for every claim (aging, TFL and re-follow-up move with the calendar)
           ------------------------------------------------------------------------------------ */
        CREATE TABLE #recalc (UpdatedClaims int);
        INSERT INTO #recalc EXEC dbo.ARWB_usp_RecalculateClaimState;

        /* ------------------------------------------------------------------------------------
           5. Denial Analysis insights for this sync week
           ------------------------------------------------------------------------------------ */
        CREATE TABLE #ins (InsightsBuilt int);
        INSERT INTO #ins EXEC dbo.ARWB_usp_BuildDenialInsights @RefreshRunId = @RunId;

        /* ------------------------------------------------------------------------------------
           6. Run summary
           ------------------------------------------------------------------------------------ */
        UPDATE rr
        SET rr.RunStatus                 = 'Succeeded',
            rr.CompletedOn               = SYSUTCDATETIME(),
            rr.SourceRunId               = (SELECT TOP (1) s.SourceRunId FROM #src s WHERE s.SourceRunId IS NOT NULL ORDER BY s.SourceRecordId DESC),
            rr.SourceFileName            = (SELECT TOP (1) s.SourceFileName FROM #src s WHERE s.SourceFileName IS NOT NULL ORDER BY s.SourceRecordId DESC),
            rr.SourceWeekFolder          = (SELECT TOP (1) s.SourceWeekFolder FROM #src s WHERE s.SourceWeekFolder IS NOT NULL ORDER BY s.SourceRecordId DESC),
            rr.SourcePeriodStart         = (SELECT MIN(s.DateOfService) FROM #src s),
            rr.SourcePeriodEnd           = (SELECT MAX(s.DateOfService) FROM #src s),
            rr.SourceClaimRows           = (SELECT COUNT(*) FROM #src),
            rr.SourceDeniedClaims        = (SELECT COUNT(*) FROM #src WHERE DenialCode IS NOT NULL),
            rr.SourceLineRows            = @SourceLineRows,
            rr.SourceDeniedLines         = @SourceDeniedLines,
            rr.LineOnlyClaims            = @LineOnlyClaims,
            rr.ClaimsInserted            = (SELECT COUNT(*) FROM #src WHERE ChangeKind = 'New'),
            rr.ClaimsUpdated             = (SELECT COUNT(*) FROM #src WHERE ChangeKind = 'Changed'),
            rr.ClaimsUnchanged           = (SELECT COUNT(*) FROM #src WHERE ChangeKind = 'Same'),
            rr.ClaimsNoLongerInSource    = @NoLongerInSource,
            rr.ClaimsLinesReloaded       = @ClaimsLinesReloaded,
            rr.ClaimsDenialChanged       = @DenialChanged,
            rr.ClaimsAutoUnassigned      = @AutoUnassigned,
            rr.ClaimsNewDenialFlagged    = @NewDenialFlagged,
            rr.ClaimsAdjustmentNotPosted = @AdjNotPosted,
            rr.ClaimsAdjustmentPosted    = @AdjPosted,
            rr.InsightsBuilt             = (SELECT TOP (1) InsightsBuilt FROM #ins)
        FROM dbo.ARWB_RefreshRun rr
        WHERE rr.RefreshRunId = @RunId;

        EXEC sp_releaseapplock @Resource = N'dbo.ARWB_usp_LoadClaimsFromSource', @LockOwner = N'Session';

        SELECT * FROM dbo.ARWB_RefreshRun WHERE RefreshRunId = @RunId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @Err nvarchar(4000) = ERROR_MESSAGE();
        UPDATE dbo.ARWB_RefreshRun
        SET RunStatus = 'Failed', CompletedOn = SYSUTCDATETIME(), ErrorMessage = @Err
        WHERE RefreshRunId = @RunId;

        EXEC sp_releaseapplock @Resource = N'dbo.ARWB_usp_LoadClaimsFromSource', @LockOwner = N'Session';
        THROW;
    END CATCH;
END;
GO

PRINT 'AR Workbench 05: dbo.ARWB_usp_LoadClaimsFromSource ready.';
GO

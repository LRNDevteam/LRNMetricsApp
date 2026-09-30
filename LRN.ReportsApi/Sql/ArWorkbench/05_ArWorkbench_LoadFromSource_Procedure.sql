/* ============================================================================================
   AR Workbench - 05 arwb.usp_LoadClaimsFromSource  (the Data Processing refresh)

   Copies denied claims from the lab's claim-level feed into the workbench:
     dbo.ClaimLevelData  -> arwb.Claim      every claim whose DenialCode is not null / blank
     dbo.LineLevelData   -> arwb.ClaimLine  the CPT lines of those claims

   Rules
   - One row per ClaimID: the latest ClaimLevelData row (InsertedDateTime DESC, RecordId DESC).
   - A claim ALREADY in the workbench keeps refreshing even if the source later clears its denial
     code. Otherwise a denial that the payer pays would silently drop out instead of showing as
     recovered.
   - Claims no longer present in the source are kept, flagged IsInCurrentSource = 0.
   - Initial* financials are frozen on first identification; RecoveredAmount is the delta from
     there (arwb.ClaimFinancialHistory keeps every changed snapshot).
   - Workflow state (assignment, follow-ups, QA, CIP) is never overwritten by a refresh.
   - Lines are reloaded only for claims whose line set changed (checksum), so a weekly refresh
     does not rewrite millions of unchanged lines.
   - Source columns are probed with COL_LENGTH: a lab missing an optional column loads NULL for it
     instead of failing (labs migrate one at a time).

   Usage:   EXEC arwb.usp_LoadClaimsFromSource @RunBy = N'jdoe', @Note = N'Weekly refresh';
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE arwb.usp_LoadClaimsFromSource
    @RunBy  nvarchar(256)  = N'System',
    @Note   nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NULL
        THROW 51001, 'dbo.ClaimLevelData does not exist in this database. Run AR Workbench scripts in the lab database.', 1;
    IF COL_LENGTH(N'dbo.ClaimLevelData', N'ClaimID') IS NULL OR COL_LENGTH(N'dbo.ClaimLevelData', N'DenialCode') IS NULL
        THROW 51002, 'dbo.ClaimLevelData must have ClaimID and DenialCode columns.', 1;
    -- An empty feed (e.g. mid-import) would otherwise flag every claim as "no longer in source".
    IF NOT EXISTS (SELECT TOP (1) 1 FROM dbo.ClaimLevelData)
        THROW 51004, 'dbo.ClaimLevelData is empty. Refresh skipped so existing claims are not flagged as removed.', 1;

    -- One refresh at a time per lab database.
    DECLARE @Lock int;
    EXEC @Lock = sp_getapplock @Resource = N'arwb.usp_LoadClaimsFromSource', @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0;
    IF @Lock < 0
        THROW 51003, 'An AR Workbench refresh is already running for this lab.', 1;

    DECLARE @RunId int;
    INSERT INTO arwb.RefreshRun (RunBy, Note) VALUES (@RunBy, @Note);
    SET @RunId = CONVERT(int, SCOPE_IDENTITY());

    BEGIN TRY
        DECLARE @Now datetime2(0) = SYSUTCDATETIME();
        DECLARE @Sql nvarchar(max), @Cols nvarchar(max), @Exprs nvarchar(max), @OrderBy nvarchar(400), @Rank nvarchar(400);

        /* ------------------------------------------------------------------------------------
           1. Latest claim-level row per ClaimID, typed
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
            DenialCategory          nvarchar(200)  NULL,
            TemplateKey             varchar(50)    NULL,
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
                        WHEN m.Kind = 'M' THEN N'ISNULL((SELECT x.Amount FROM arwb.tvf_ParseMoney(r.' + QUOTENAME(m.SourceCol) + N') x), 0)'
                        WHEN m.Kind = 'D' THEN N'(SELECT x.DateValue FROM arwb.tvf_ParseDate(r.' + QUOTENAME(m.SourceCol) + N') x)'
                        WHEN m.Kind = 'I' THEN N'TRY_CONVERT(int, r.' + QUOTENAME(m.SourceCol) + N')'
                    END
                FROM @ClaimMap m ORDER BY m.Ord
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

        SET @OrderBy =
            CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'InsertedDateTime') IS NOT NULL THEN N'r.InsertedDateTime DESC, ' ELSE N'' END
            + CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'RecordId') IS NOT NULL THEN N'r.RecordId DESC' ELSE N'(SELECT NULL)' END;

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
WHERE r.arwb_rn = 1
  AND (   NULLIF(NULLIF(LTRIM(RTRIM(r.DenialCode)), N''''), N''NULL'') IS NOT NULL
       OR EXISTS (SELECT 1 FROM arwb.Claim c WHERE c.ClaimID = LTRIM(RTRIM(r.ClaimID))));';

        EXEC sys.sp_executesql @Sql;

        /* ------------------------------------------------------------------------------------
           2. Change hash, match to existing claims, denial category
           ------------------------------------------------------------------------------------ */
        UPDATE #src
        SET RowHash = CONVERT(nvarchar(64), HASHBYTES('SHA2_256', CONCAT(
                ClaimID, N'|', DenialCode, N'|', SourceClaimStatus, N'|', DeniedStatus, N'|', PayerName, N'|', PayerType, N'|',
                ClinicName, N'|', ReferringProvider, N'|', BillingProvider, N'|', PanelName, N'|', PanelType, N'|',
                CONVERT(nvarchar(10), DateOfService, 23), N'|', CONVERT(nvarchar(10), FirstBilledDate, 23), N'|', CONVERT(nvarchar(10), CheckDate, 23), N'|',
                ChargeAmount, N'|', AllowedAmount, N'|', InsurancePayment, N'|', PatientPayment, N'|', TotalPayments, N'|',
                InsuranceAdjustments, N'|', PatientAdjustments, N'|', TotalAdjustments, N'|',
                InsuranceBalance, N'|', PatientBalance, N'|', TotalBalance, N'|', AccessionNumber, N'|', PatientName, N'|', ICDCode)), 2);

        UPDATE s
        SET s.ClaimKey   = c.ClaimKey,
            s.ChangeKind = CASE WHEN c.SourceRowHash = s.RowHash THEN 'Same' ELSE 'Changed' END
        FROM #src s
        INNER JOIN arwb.Claim c ON c.ClaimID = s.ClaimID;

        UPDATE #src SET ChangeKind = 'New' WHERE ClaimKey IS NULL;

        -- First listed code that has a mapping wins; unmapped claims are 'Other'.
        UPDATE s
        SET s.DenialCategory = COALESCE(mp.DenialCategory, N'Other'),
            s.TemplateKey    = COALESCE(dt.TemplateKey, 'denied')
        FROM #src s
        CROSS APPLY (SELECT Codes = N',' + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(UPPER(ISNULL(s.DenialCode, N'')), N' ', N''), N'-', N''), N';', N','), N'|', N','), N'/', N',') + N',') n
        OUTER APPLY
        (
            SELECT TOP (1) m.DenialCategory
            FROM arwb.DenialCodeCategoryMap m
            WHERE m.IsActive = 1 AND n.Codes LIKE N'%,' + m.DenialCode + N',%'
            ORDER BY CHARINDEX(N',' + m.DenialCode + N',', n.Codes)
        ) mp
        LEFT JOIN arwb.DenialCategoryTemplate dt ON dt.DenialCategory = COALESCE(mp.DenialCategory, N'Other')
        WHERE s.ChangeKind IN ('New', 'Changed');

        /* ------------------------------------------------------------------------------------
           3. Apply to arwb.Claim (one transaction)
           ------------------------------------------------------------------------------------ */
        CREATE TABLE #changed
        (
            ClaimKey                bigint        NOT NULL PRIMARY KEY,
            OldInsuranceBalance     decimal(18,2) NULL,
            NewInsuranceBalance     decimal(18,2) NULL,
            OldInsurancePayment     decimal(18,2) NULL,
            NewInsurancePayment     decimal(18,2) NULL,
            OldPatientBalance       decimal(18,2) NULL,
            NewPatientBalance       decimal(18,2) NULL,
            OldDenialCode           nvarchar(1000) NULL,
            NewDenialCode           nvarchar(1000) NULL
        );
        CREATE TABLE #new (ClaimKey bigint NOT NULL PRIMARY KEY, ClaimID nvarchar(200) NOT NULL);

        DECLARE @NoLongerInSource int;

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
            -- keep the last known denial code when the source clears it, so the claim's denial history stays readable
            c.DenialCode = COALESCE(s.DenialCode, c.DenialCode),
            c.DenialCategory = CASE WHEN c.IsDenialCategoryManual = 1 OR s.DenialCode IS NULL THEN c.DenialCategory ELSE s.DenialCategory END,
            c.WorkflowTemplateKey = CASE WHEN c.IsDenialCategoryManual = 1 OR s.DenialCode IS NULL THEN c.WorkflowTemplateKey ELSE s.TemplateKey END,
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
               deleted.PatientBalance,   inserted.PatientBalance,
               deleted.DenialCode,       inserted.DenialCode
        INTO #changed (ClaimKey, OldInsuranceBalance, NewInsuranceBalance, OldInsurancePayment, NewInsurancePayment,
                       OldPatientBalance, NewPatientBalance, OldDenialCode, NewDenialCode)
        FROM arwb.Claim c
        INNER JOIN #src s ON s.ClaimKey = c.ClaimKey
        WHERE s.ChangeKind = 'Changed';

        -- 3b. Unchanged claims: just stamp the run
        UPDATE c
        SET c.IsInCurrentSource = 1, c.LastRefreshRunId = @RunId, c.LastRefreshedOn = @Now,
            c.SourceRecordId = s.SourceRecordId, c.SourceRunId = s.SourceRunId
        FROM arwb.Claim c
        INNER JOIN #src s ON s.ClaimKey = c.ClaimKey
        WHERE s.ChangeKind = 'Same';

        -- 3c. New claims: Initial* frozen here
        INSERT INTO arwb.Claim
        (
            ClaimID, LabId, LabName, AccessionNumber, PatientID, PatientName, PatientDOB, SubscriberId,
            PayerName, PayerNameRaw, PayerCode, PayerType, ClaimType,
            BillingProvider, ReferringProvider, ClinicName, SalesRepName, PanelName, PanelType,
            DateOfService, ChargeEnteredDate, FirstBilledDate, CheckDate, SourceLastActivityDate, CptSummary, ICDCode,
            SourceClaimStatus, DeniedStatus, DenialCode, DenialCategory, WorkflowTemplateKey,
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
            s.SourceClaimStatus, s.DeniedStatus, s.DenialCode, s.DenialCategory, s.TemplateKey,
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

        -- 3d. Claims that dropped out of the source feed
        UPDATE c
        SET c.IsInCurrentSource = 0, c.LastRefreshedOn = @Now
        FROM arwb.Claim c
        WHERE c.IsInCurrentSource = 1
          AND NOT EXISTS (SELECT 1 FROM #src s WHERE s.ClaimKey = c.ClaimKey);
        SET @NoLongerInSource = @@ROWCOUNT;

        -- 3e. Point-in-time history: first identification + every financial/denial change
        INSERT INTO arwb.ClaimFinancialHistory
        (
            ClaimKey, RefreshRunId, SnapshotOn, ChangeType,
            ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, InsuranceAdjustments, PatientAdjustments,
            InsuranceBalance, PatientBalance, TotalBalance, SourceClaimStatus, DenialCode
        )
        SELECT c.ClaimKey, @RunId, @Now, CASE WHEN n.ClaimKey IS NOT NULL THEN 'Identified' ELSE 'SourceChanged' END,
               c.ChargeAmount, c.AllowedAmount, c.InsurancePayment, c.PatientPayment, c.InsuranceAdjustments, c.PatientAdjustments,
               c.InsuranceBalance, c.PatientBalance, c.TotalBalance, c.SourceClaimStatus, c.DenialCode
        FROM arwb.Claim c
        LEFT JOIN #new n     ON n.ClaimKey  = c.ClaimKey
        LEFT JOIN #changed x ON x.ClaimKey  = c.ClaimKey
        WHERE n.ClaimKey IS NOT NULL OR x.ClaimKey IS NOT NULL;

        -- 3f. Activity log. Every claim gets "Claim Identified", which is what makes
        --     "days since last touch" work for claims nobody has ever assigned.
        INSERT INTO arwb.ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, UserName, RoleCode, IsSystem, RelatedEntityType, RelatedEntityId)
        SELECT n.ClaimKey, @Now, N'Claim Identified',
               LEFT(N'Denial ' + ISNULL(s.DenialCode, N'') + N' identified from claim-level data (refresh #' + CONVERT(nvarchar(20), @RunId) + N').', 2000),
               N'System', NULL, 1, 'RefreshRun', @RunId
        FROM #new n
        INNER JOIN #src s ON s.ClaimKey = n.ClaimKey;

        INSERT INTO arwb.ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, UserName, RoleCode, IsSystem, RelatedEntityType, RelatedEntityId)
        SELECT x.ClaimKey, @Now, N'Source Data Updated',
               LEFT(
                   CASE WHEN x.OldInsuranceBalance <> x.NewInsuranceBalance
                        THEN N'Insurance balance ' + CONVERT(nvarchar(30), x.OldInsuranceBalance) + N' -> ' + CONVERT(nvarchar(30), x.NewInsuranceBalance) + N'. ' ELSE N'' END
                 + CASE WHEN x.OldInsurancePayment <> x.NewInsurancePayment
                        THEN N'Insurance payment ' + CONVERT(nvarchar(30), x.OldInsurancePayment) + N' -> ' + CONVERT(nvarchar(30), x.NewInsurancePayment) + N'. ' ELSE N'' END
                 + CASE WHEN x.OldPatientBalance <> x.NewPatientBalance
                        THEN N'Patient balance ' + CONVERT(nvarchar(30), x.OldPatientBalance) + N' -> ' + CONVERT(nvarchar(30), x.NewPatientBalance) + N'. ' ELSE N'' END
                 + CASE WHEN ISNULL(x.OldDenialCode, N'') <> ISNULL(x.NewDenialCode, N'')
                        THEN N'Denial code ' + ISNULL(x.OldDenialCode, N'-') + N' -> ' + ISNULL(x.NewDenialCode, N'-') + N'. ' ELSE N'' END
                 + N'(refresh #' + CONVERT(nvarchar(20), @RunId) + N')', 2000),
               N'System', NULL, 1, 'RefreshRun', @RunId
        FROM #changed x
        WHERE x.OldInsuranceBalance <> x.NewInsuranceBalance
           OR x.OldInsurancePayment <> x.NewInsurancePayment
           OR x.OldPatientBalance   <> x.NewPatientBalance
           OR ISNULL(x.OldDenialCode, N'') <> ISNULL(x.NewDenialCode, N'');

        COMMIT TRANSACTION;

        /* ------------------------------------------------------------------------------------
           4. CPT lines from dbo.LineLevelData (only claims whose line set changed)
           ------------------------------------------------------------------------------------ */
        DECLARE @SourceLineRows int = 0, @ClaimsLinesReloaded int = 0;

        IF OBJECT_ID(N'dbo.LineLevelData', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.LineLevelData', N'ClaimID') IS NOT NULL
        BEGIN
            CREATE TABLE #line
            (
                ClaimID                 nvarchar(200)  NOT NULL,
                SourceRecordId          int            NULL,
                CPTCode                 nvarchar(50)   NULL,
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

            DECLARE @LineMap TABLE (Ord int IDENTITY(1,1), TargetCol sysname, SourceCol sysname, Kind char(1), MaxLen int);
            INSERT INTO @LineMap (TargetCol, SourceCol, Kind, MaxLen) VALUES
                (N'ClaimID', N'ClaimID', 'T', 200),
                (N'SourceRecordId', N'RecordId', 'I', 0),
                (N'CPTCode', N'CPTCode', 'T', 50),
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
                            WHEN m.Kind = 'M' THEN N'ISNULL((SELECT x.Amount FROM arwb.tvf_ParseMoney(r.' + QUOTENAME(m.SourceCol) + N') x), 0)'
                            WHEN m.Kind = 'D' THEN N'(SELECT x.DateValue FROM arwb.tvf_ParseDate(r.' + QUOTENAME(m.SourceCol) + N') x)'
                            WHEN m.Kind = 'I' THEN N'TRY_CONVERT(int, r.' + QUOTENAME(m.SourceCol) + N')'
                            WHEN m.Kind = 'U' THEN N'TRY_CONVERT(decimal(9,2), (SELECT x.Amount FROM arwb.tvf_ParseMoney(r.' + QUOTENAME(m.SourceCol) + N') x))'
                        END
                    FROM @LineMap m ORDER BY m.Ord
                    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');

            -- Only the latest line file per claim (LineLevelData can hold more than one load).
            SET @Rank =
                CASE WHEN COL_LENGTH(N'dbo.LineLevelData', N'FileLogId') IS NOT NULL
                         THEN N'DENSE_RANK() OVER (PARTITION BY r.ClaimID ORDER BY ISNULL(TRY_CONVERT(int, r.FileLogId), 0) DESC)'
                     WHEN COL_LENGTH(N'dbo.LineLevelData', N'InsertedDateTime') IS NOT NULL
                         THEN N'DENSE_RANK() OVER (PARTITION BY r.ClaimID ORDER BY CONVERT(date, r.InsertedDateTime) DESC)'
                     ELSE N'1' END;

            SET @Sql = N'
;WITH ranked AS
(
    SELECT r.*, arwb_rk = ' + @Rank + N'
    FROM dbo.LineLevelData r
    WHERE EXISTS (SELECT 1 FROM #src s WHERE s.ClaimID = r.ClaimID)
)
INSERT INTO #line (' + @Cols + N')
SELECT ' + @Exprs + N'
FROM ranked r
WHERE r.arwb_rk = 1;';

            EXEC sys.sp_executesql @Sql;
            SET @SourceLineRows = (SELECT COUNT(*) FROM #line);

            CREATE CLUSTERED INDEX CX_line ON #line (ClaimID, SourceRecordId);

            CREATE TABLE #lineSum (ClaimID nvarchar(200) NOT NULL PRIMARY KEY, LineChecksum int NULL, MinDenialDate date NULL);
            INSERT INTO #lineSum (ClaimID, LineChecksum, MinDenialDate)
            SELECT l.ClaimID,
                   CHECKSUM_AGG(CHECKSUM(l.CPTCode, l.Units, l.Modifier, l.ChargeAmount, l.AllowedAmount, l.InsurancePayment,
                                         l.InsuranceAdjustments, l.InsuranceBalance, l.PatientBalance, l.DenialCode,
                                         l.LineClaimStatus, l.PayStatus, l.DenialDate, l.CheckDate)),
                   MIN(l.DenialDate)
            FROM #line l
            GROUP BY l.ClaimID;

            CREATE TABLE #reload (ClaimKey bigint NOT NULL PRIMARY KEY, ClaimID nvarchar(200) NOT NULL, LineChecksum int NULL, MinDenialDate date NULL);
            INSERT INTO #reload (ClaimKey, ClaimID, LineChecksum, MinDenialDate)
            SELECT c.ClaimKey, c.ClaimID, ls.LineChecksum, ls.MinDenialDate
            FROM #src s
            INNER JOIN arwb.Claim c ON c.ClaimKey = s.ClaimKey
            INNER JOIN #lineSum ls  ON ls.ClaimID = s.ClaimID
            WHERE c.LineSetChecksum IS NULL OR c.LineSetChecksum <> ls.LineChecksum;
            SET @ClaimsLinesReloaded = @@ROWCOUNT;

            BEGIN TRANSACTION;

            DELETE cl
            FROM arwb.ClaimLine cl
            INNER JOIN #reload r ON r.ClaimKey = cl.ClaimKey;

            INSERT INTO arwb.ClaimLine
            (
                ClaimKey, ClaimID, LineNumber, CPTCode, Units, Modifier, POS, TOS,
                ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
                InsuranceAdjustments, PatientAdjustments, TotalAdjustments, InsuranceBalance, PatientBalance, TotalBalance,
                LineClaimStatus, PayStatus, DenialCode, DenialDate, CheckDate, PostingDate, ICDCode, ICDPointer,
                SourceRecordId, SourceRowHash, RefreshRunId, LoadedOn
            )
            SELECT r.ClaimKey, l.ClaimID,
                   ROW_NUMBER() OVER (PARTITION BY l.ClaimID ORDER BY l.SourceRecordId),
                   l.CPTCode, l.Units, l.Modifier, l.POS, l.TOS,
                   l.ChargeAmount, l.AllowedAmount, l.InsurancePayment, l.PatientPayment, l.TotalPayments,
                   l.InsuranceAdjustments, l.PatientAdjustments, l.TotalAdjustments, l.InsuranceBalance, l.PatientBalance, l.TotalBalance,
                   l.LineClaimStatus, l.PayStatus, l.DenialCode, l.DenialDate, l.CheckDate, l.PostingDate, l.ICDCode, l.ICDPointer,
                   l.SourceRecordId, l.SourceRowHash, @RunId, @Now
            FROM #line l
            INNER JOIN #reload r ON r.ClaimID = l.ClaimID;

            UPDATE c
            SET c.LineSetChecksum = r.LineChecksum,
                c.DenialDate      = COALESCE(r.MinDenialDate, c.DenialDate)
            FROM arwb.Claim c
            INNER JOIN #reload r ON r.ClaimKey = c.ClaimKey;

            COMMIT TRANSACTION;
        END;

        /* ------------------------------------------------------------------------------------
           5. Denial reason from the lab's existing dbo.DenialCodeMaster, when it is present.
              Read-only use of the existing Denial Workflow master; nothing there is changed.
           ------------------------------------------------------------------------------------ */
        IF OBJECT_ID(N'dbo.DenialCodeMaster', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.DenialCodeMaster', N'DenialDescription') IS NOT NULL
        BEGIN
            EXEC sys.sp_executesql N'
UPDATE c
SET c.DenialReason = LEFT(d.DenialDescription, 1000)
FROM arwb.Claim c
INNER JOIN #src s ON s.ClaimKey = c.ClaimKey AND s.ChangeKind IN (''New'', ''Changed'')
CROSS APPLY
(
    SELECT TOP (1) dm.DenialDescription
    FROM dbo.DenialCodeMaster dm
    WHERE dm.DenialDescription IS NOT NULL
      AND c.DenialCodesNormalized LIKE N''%,'' + REPLACE(REPLACE(UPPER(dm.DenialCode), N'' '', N''''), N''-'', N'''') + N'',%''
    ORDER BY CHARINDEX(N'','' + REPLACE(REPLACE(UPPER(dm.DenialCode), N'' '', N''''), N''-'', N'''') + N'','', c.DenialCodesNormalized)
) d;';
        END;

        /* ------------------------------------------------------------------------------------
           6. Derived state for every claim (aging, TFL and re-follow-up move with the calendar)
           ------------------------------------------------------------------------------------ */
        CREATE TABLE #recalc (UpdatedClaims int);
        INSERT INTO #recalc EXEC arwb.usp_RecalculateClaimState;

        /* ------------------------------------------------------------------------------------
           7. Run summary
           ------------------------------------------------------------------------------------ */
        UPDATE rr
        SET rr.RunStatus              = 'Succeeded',
            rr.CompletedOn            = SYSUTCDATETIME(),
            rr.SourceRunId            = (SELECT TOP (1) s.SourceRunId FROM #src s WHERE s.SourceRunId IS NOT NULL ORDER BY s.SourceRecordId DESC),
            rr.SourceFileName         = (SELECT TOP (1) s.SourceFileName FROM #src s WHERE s.SourceFileName IS NOT NULL ORDER BY s.SourceRecordId DESC),
            rr.SourceWeekFolder       = (SELECT TOP (1) s.SourceWeekFolder FROM #src s WHERE s.SourceWeekFolder IS NOT NULL ORDER BY s.SourceRecordId DESC),
            rr.SourcePeriodStart      = (SELECT MIN(s.DateOfService) FROM #src s),
            rr.SourcePeriodEnd        = (SELECT MAX(s.DateOfService) FROM #src s),
            rr.SourceClaimRows        = (SELECT COUNT(*) FROM #src),
            rr.SourceLineRows         = @SourceLineRows,
            rr.ClaimsInserted         = (SELECT COUNT(*) FROM #src WHERE ChangeKind = 'New'),
            rr.ClaimsUpdated          = (SELECT COUNT(*) FROM #src WHERE ChangeKind = 'Changed'),
            rr.ClaimsUnchanged        = (SELECT COUNT(*) FROM #src WHERE ChangeKind = 'Same'),
            rr.ClaimsNoLongerInSource = @NoLongerInSource,
            rr.ClaimsLinesReloaded    = @ClaimsLinesReloaded
        FROM arwb.RefreshRun rr
        WHERE rr.RefreshRunId = @RunId;

        EXEC sp_releaseapplock @Resource = N'arwb.usp_LoadClaimsFromSource', @LockOwner = N'Session';

        SELECT * FROM arwb.RefreshRun WHERE RefreshRunId = @RunId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @Err nvarchar(4000) = ERROR_MESSAGE();
        UPDATE arwb.RefreshRun
        SET RunStatus = 'Failed', CompletedOn = SYSUTCDATETIME(), ErrorMessage = @Err
        WHERE RefreshRunId = @RunId;

        EXEC sp_releaseapplock @Resource = N'arwb.usp_LoadClaimsFromSource', @LockOwner = N'Session';
        THROW;
    END CATCH;
END;
GO

PRINT 'AR Workbench 05: arwb.usp_LoadClaimsFromSource ready.';
GO

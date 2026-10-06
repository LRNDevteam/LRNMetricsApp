/* ============================================================================================
   AR Workbench - 01 Tables
   Run once per LAB database (the database that holds dbo.ClaimLevelData / dbo.LineLevelData).
   Run 00_ARWB_Drop_Existing_Objects.sql first to remove the legacy [arwb] schema.

   Every object is in dbo and named ARWB_<Name>, so the Denial Workflow objects (dbo.DenialTaskBoard,
   dbo.DenialClaimNotes, dbo.DenialCodeMaster, ...) are not touched and all workbench objects sort
   together.

   Data grain (AR Workbench Developer Handoff v1.1, sections 2 and 3):
     - EVERY claim in the claim-level master file is synced, denied or not. The curated
       ClaimLevelData.DenialCode column (the reporting team's choice) decides whether a claim is denied
       and what its primary denial is. The queue engine then classifies every claim.
     - EVERY line in the line-level file is synced for those claims, denied or not. Line-level denial
       codes are kept per line (ARWB_ClaimLineDenial) for follow-up support; they do not drive queue
       placement in this phase.
     - Lists, queues and counts are always claims, never lines.

   Denial codes are stored normalized: upper case, no spaces or hyphens, CARC group prefix
   (CO / PR / PI / OA) removed, RARC letters kept. "PR 204" and "CO-204" are both 204; N57 stays N57.
   The raw value is kept next to it for display.

   Idempotent: every object is created only when missing. SQL Server 2016 SP1+.
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ============================================================================================
   A. SECURITY - not in the lab database.
   Users, roles and lab access come from LRNMaster (dbo.LabUsers, dbo.Roles, dbo.UserRoles,
   dbo.UserLabs, dbo.RoleFeatureAccess, dbo.ARWB_UserScope) - see LRNMaster_01_ARWB_Roles_Access.sql.
   Columns that record a user (AssignedAgentUser, CreatedBy, ReviewedBy, ...) hold dbo.LabUsers.UserName.
   ============================================================================================ */

/* ============================================================================================
   B. MASTER FILE MAINTENANCE - admin-editable reference data
   ============================================================================================ */

-- Generic chip-list master: one table for every simple list, so CSV download/upload is one code path.
-- ListType values (seeded in script 03):
--   DENIAL_CATEGORY, PANEL_TYPE, NON_COLLECTIBLE_CODE, AUTO_ADJUST_CODE, DENIAL_ROOT_CAUSE,
--   FIX_RESOLUTION, CLAIM_TYPE, FOLLOW_UP_TYPE, CLAIM_STATUS, CIP_CATEGORY, CIP_REQUIRED_INFO,
--   WORKFLOW_STATUS, AGING_BUCKET, FINANCIAL_CLASS, ESCALATION_REASON, REASSIGNMENT_REASON,
--   DOCUMENT_CATEGORY, QA_ERROR_TYPE, REVENUE_CONFIDENCE_TIER
-- NON_COLLECTIBLE_CODE and AUTO_ADJUST_CODE values are normalized codes (no CARC prefix).
IF OBJECT_ID(N'dbo.ARWB_MasterListItem', N'U') IS NULL
CREATE TABLE dbo.ARWB_MasterListItem
(
    MasterListItemId    int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_MasterListItem PRIMARY KEY,
    ListType            varchar(50)    NOT NULL,
    ItemValue           nvarchar(400)  NOT NULL,
    SortOrder           int            NOT NULL CONSTRAINT DF_ARWB_MasterListItem_SortOrder DEFAULT (0),
    IsActive            bit            NOT NULL CONSTRAINT DF_ARWB_MasterListItem_IsActive  DEFAULT (1),
    CreatedOn           datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_MasterListItem_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CreatedBy           nvarchar(256)  NULL,
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL,
    CONSTRAINT UQ_ARWB_MasterListItem_Type_Value UNIQUE (ListType, ItemValue)
);
GO

-- Normalized denial code -> denial category (drives DenialCategory and the workflow template).
IF OBJECT_ID(N'dbo.ARWB_DenialCodeCategoryMap', N'U') IS NULL
CREATE TABLE dbo.ARWB_DenialCodeCategoryMap
(
    DenialCode          nvarchar(50)   NOT NULL CONSTRAINT PK_ARWB_DenialCodeCategoryMap PRIMARY KEY,
    DenialCategory      nvarchar(200)  NOT NULL,
    DenialReason        nvarchar(1000) NULL,
    IsActive            bit            NOT NULL CONSTRAINT DF_ARWB_DenialCodeCategoryMap_IsActive  DEFAULT (1),
    CreatedOn           datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_DenialCodeCategoryMap_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CreatedBy           nvarchar(256)  NULL,
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL
);
GO

-- Denial hierarchy (Phase 2, handoff 4.1): lower rank wins when a claim carries several codes.
-- Terminal denials (e.g. 204, 197) get the lowest ranks. Used only when AppSetting
-- PrimaryDenialSource = 'Ranking'; until then the curated DenialCode column is the primary denial.
IF OBJECT_ID(N'dbo.ARWB_DenialCodeRank', N'U') IS NULL
CREATE TABLE dbo.ARWB_DenialCodeRank
(
    DenialCode          nvarchar(50)   NOT NULL CONSTRAINT PK_ARWB_DenialCodeRank PRIMARY KEY,
    RankOrder           int            NOT NULL,
    IsTerminal          bit            NOT NULL CONSTRAINT DF_ARWB_DenialCodeRank_IsTerminal DEFAULT (0),
    Note                nvarchar(400)  NULL,
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL
);
GO

-- Denial category -> Key Observations tag and recommended action (was hard-coded in the mockup).
IF OBJECT_ID(N'dbo.ARWB_DenialCategoryAction', N'U') IS NULL
CREATE TABLE dbo.ARWB_DenialCategoryAction
(
    DenialCategory      nvarchar(200)  NOT NULL CONSTRAINT PK_ARWB_DenialCategoryAction PRIMARY KEY,
    CategoryTag         nvarchar(50)   NOT NULL,      -- Review | Appeal / MR
    RecommendedAction   nvarchar(1000) NOT NULL,
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL
);
GO

-- Which Fix/Resolution options are valid for a given follow-up Claim Status.
IF OBJECT_ID(N'dbo.ARWB_FixResolutionByStatus', N'U') IS NULL
CREATE TABLE dbo.ARWB_FixResolutionByStatus
(
    ClaimStatus         nvarchar(100)  NOT NULL,
    FixResolution       nvarchar(200)  NOT NULL,
    SortOrder           int            NOT NULL CONSTRAINT DF_ARWB_FixResolutionByStatus_SortOrder DEFAULT (0),
    CONSTRAINT PK_ARWB_FixResolutionByStatus PRIMARY KEY (ClaimStatus, FixResolution)
);
GO

-- Named stage path per denial category (claim workspace stepper).
IF OBJECT_ID(N'dbo.ARWB_WorkflowTemplate', N'U') IS NULL
CREATE TABLE dbo.ARWB_WorkflowTemplate
(
    TemplateKey         varchar(50)    NOT NULL CONSTRAINT PK_ARWB_WorkflowTemplate PRIMARY KEY,
    TemplateLabel       nvarchar(200)  NOT NULL,
    IsActive            bit            NOT NULL CONSTRAINT DF_ARWB_WorkflowTemplate_IsActive DEFAULT (1)
);
GO

IF OBJECT_ID(N'dbo.ARWB_WorkflowTemplateStage', N'U') IS NULL
CREATE TABLE dbo.ARWB_WorkflowTemplateStage
(
    TemplateKey         varchar(50)    NOT NULL CONSTRAINT FK_ARWB_WorkflowTemplateStage_Template REFERENCES dbo.ARWB_WorkflowTemplate (TemplateKey),
    StageOrder          tinyint        NOT NULL,
    StageName           nvarchar(200)  NOT NULL,
    CONSTRAINT PK_ARWB_WorkflowTemplateStage PRIMARY KEY (TemplateKey, StageOrder)
);
GO

IF OBJECT_ID(N'dbo.ARWB_DenialCategoryTemplate', N'U') IS NULL
CREATE TABLE dbo.ARWB_DenialCategoryTemplate
(
    DenialCategory      nvarchar(200)  NOT NULL CONSTRAINT PK_ARWB_DenialCategoryTemplate PRIMARY KEY,
    TemplateKey         varchar(50)    NOT NULL CONSTRAINT FK_ARWB_DenialCategoryTemplate_Template REFERENCES dbo.ARWB_WorkflowTemplate (TemplateKey)
);
GO

-- Timely-filing limit per financial class (ClaimLevelData.PayerType). Unmatched: AppSetting TflDefaultDays.
IF OBJECT_ID(N'dbo.ARWB_TflThreshold', N'U') IS NULL
CREATE TABLE dbo.ARWB_TflThreshold
(
    FinancialClass      nvarchar(200)  NOT NULL CONSTRAINT PK_ARWB_TflThreshold PRIMARY KEY,
    ThresholdDays       int            NOT NULL,
    CONSTRAINT CK_ARWB_TflThreshold_Days CHECK (ThresholdDays > 0)
);
GO

-- Revenue Expectation rate per CPT (handoff section 7): Medicare-rate allowable. Rate source is an
-- open item (Medicare fee schedule vs historical allowed); the table holds whichever is chosen.
-- Modifier NULL = any modifier. A line with no matching rate contributes 0.
IF OBJECT_ID(N'dbo.ARWB_CptFeeSchedule', N'U') IS NULL
CREATE TABLE dbo.ARWB_CptFeeSchedule
(
    CptFeeScheduleId    int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_CptFeeSchedule PRIMARY KEY,
    CPTCode             nvarchar(50)   NOT NULL,
    Modifier            nvarchar(100)  NULL,
    Rate                decimal(18,2)  NOT NULL,
    EffectiveFrom       date           NOT NULL CONSTRAINT DF_ARWB_CptFeeSchedule_From DEFAULT ('19000101'),
    EffectiveTo         date           NULL,
    RateSource          nvarchar(100)  NULL,          -- e.g. 'Medicare CLFS 2026'
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL,
    CONSTRAINT CK_ARWB_CptFeeSchedule_Rate  CHECK (Rate >= 0),
    CONSTRAINT CK_ARWB_CptFeeSchedule_Dates CHECK (EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom)
);
GO

-- AR queue taxonomy: top-level queues and their sub-queues. Master data, not code.
IF OBJECT_ID(N'dbo.ARWB_ArQueue', N'U') IS NULL
CREATE TABLE dbo.ARWB_ArQueue
(
    QueueId             varchar(40)    NOT NULL CONSTRAINT PK_ARWB_ArQueue PRIMARY KEY,
    ParentQueueId       varchar(40)    NULL CONSTRAINT FK_ARWB_ArQueue_Parent REFERENCES dbo.ARWB_ArQueue (QueueId),
    QueueLabel          nvarchar(200)  NOT NULL,
    QueueGroup          varchar(20)    NULL,          -- Closed | Active AR | Patient | Workflow
    IsPriority          bit            NOT NULL CONSTRAINT DF_ARWB_ArQueue_IsPriority DEFAULT (0),   -- needs agent work
    IsRestricted        bit            NOT NULL CONSTRAINT DF_ARWB_ArQueue_IsRestricted DEFAULT (0), -- admin / manager / lead only
    IsAutoRouted        bit            NOT NULL CONSTRAINT DF_ARWB_ArQueue_IsAutoRouted DEFAULT (0), -- feeds the Work Queue for assignment
    SortOrder           int            NOT NULL CONSTRAINT DF_ARWB_ArQueue_SortOrder  DEFAULT (0),
    BadgeClass          varchar(40)    NULL
);
GO

-- Tunable business-rule thresholds.
IF OBJECT_ID(N'dbo.ARWB_AppSetting', N'U') IS NULL
CREATE TABLE dbo.ARWB_AppSetting
(
    SettingKey          varchar(100)   NOT NULL CONSTRAINT PK_ARWB_AppSetting PRIMARY KEY,
    SettingValue        nvarchar(400)  NOT NULL,
    Description         nvarchar(1000) NULL,
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL
);
GO

/* ============================================================================================
   C. DATA PROCESSING - one row per weekly sync from dbo.ClaimLevelData / dbo.LineLevelData
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_RefreshRun', N'U') IS NULL
CREATE TABLE dbo.ARWB_RefreshRun
(
    RefreshRunId                int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_RefreshRun PRIMARY KEY,
    SourceRunId                 nvarchar(500)  NULL,     -- ClaimLevelData.RunId of the latest file
    SourceFileName              nvarchar(500)  NULL,
    SourceWeekFolder            nvarchar(500)  NULL,
    SyncWeekStart               date           NULL,     -- Monday of the sync week (insight week stamp)
    SourcePeriodStart           date           NULL,     -- MIN(DateOfService) in the loaded set
    SourcePeriodEnd             date           NULL,     -- MAX(DateOfService) in the loaded set
    RunStatus                   varchar(20)    NOT NULL CONSTRAINT DF_ARWB_RefreshRun_Status DEFAULT ('Running'),
    StartedOn                   datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_RefreshRun_StartedOn DEFAULT (SYSUTCDATETIME()),
    CompletedOn                 datetime2(0)   NULL,
    SourceClaimRows             int            NULL,     -- distinct claims read (all claims, denied or not)
    SourceDeniedClaims          int            NULL,     -- of those, claims with a curated denial code
    SourceLineRows              int            NULL,     -- line rows read (all lines, denied or not)
    SourceDeniedLines           int            NULL,
    LineOnlyClaims              int            NULL,     -- ClaimIDs in LineLevelData with no claim-level row (not loaded)
    ClaimsInserted              int            NULL,
    ClaimsUpdated               int            NULL,
    ClaimsUnchanged             int            NULL,
    ClaimsNoLongerInSource      int            NULL,
    ClaimsLinesReloaded         int            NULL,
    ClaimsDenialChanged         int            NULL,     -- primary denial changed vs the previous sync
    ClaimsAutoUnassigned        int            NULL,     -- assigned, not worked, new denial is non-collectible
    ClaimsNewDenialFlagged      int            NULL,     -- worked claim received a new denial
    ClaimsAdjustmentNotPosted   int            NULL,     -- adjusted / written off in the workbench, still open in the master
    ClaimsAdjustmentPosted      int            NULL,     -- adjustment now visible in the master (auto-confirmed)
    InsightsBuilt               int            NULL,
    RunBy                       nvarchar(256)  NULL,
    Note                        nvarchar(1000) NULL,
    ErrorMessage                nvarchar(max)  NULL,
    CONSTRAINT CK_ARWB_RefreshRun_Status CHECK (RunStatus IN ('Running', 'Succeeded', 'Failed'))
);
GO

/* ============================================================================================
   D. CLAIM - one row per claim in the master file (denied or not) + workbench state
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_Claim', N'U') IS NULL
CREATE TABLE dbo.ARWB_Claim
(
    ClaimKey                    bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_Claim PRIMARY KEY,

    -- Identification (source: ClaimLevelData)
    ClaimID                     nvarchar(200)  NOT NULL,
    LabId                       int            NULL,
    LabName                     nvarchar(500)  NULL,          -- "client" in the AR Workbench model
    AccessionNumber             nvarchar(200)  NULL,
    PatientID                   nvarchar(200)  NULL,
    PatientName                 nvarchar(1000) NULL,
    PatientDOB                  date           NULL,
    SubscriberId                nvarchar(200)  NULL,
    PayerName                   nvarchar(500)  NULL,
    PayerNameRaw                nvarchar(500)  NULL,
    PayerCode                   nvarchar(200)  NULL,
    PayerType                   nvarchar(200)  NULL,          -- financial class
    ClaimType                   nvarchar(200)  NULL,

    -- Providers and service
    BillingProvider             nvarchar(500)  NULL,
    ReferringProvider           nvarchar(500)  NULL,          -- provider-level access scope
    ClinicName                  nvarchar(500)  NULL,          -- clinic-level access scope (ordering practice)
    SalesRepName                nvarchar(500)  NULL,
    PanelName                   nvarchar(500)  NULL,
    PanelType                   nvarchar(500)  NULL,
    DateOfService               date           NULL,
    ChargeEnteredDate           date           NULL,
    FirstBilledDate             date           NULL,          -- submission date
    CheckDate                   date           NULL,          -- last payment date
    SourceLastActivityDate      date           NULL,
    CptSummary                  nvarchar(max)  NULL,          -- ClaimLevelData.CPTCodeXUnitsXModifier
    ICDCode                     nvarchar(1000) NULL,

    -- Source status
    SourceClaimStatus           nvarchar(200)  NULL,          -- ingested: Fully Denied / Partially Paid / No Response ... (never overwritten by follow-ups)
    DeniedStatus                nvarchar(200)  NULL,

    -- Claim-level denial. DenialCode is the curated source column as received; the primary denial is
    -- derived from it (handoff 4.1). A claim is "denied" when PrimaryDenialCode is not null.
    DenialCode                  nvarchar(1000) NULL,          -- raw curated value, e.g. 'PR 204'
    PrimaryDenialCodeRaw        nvarchar(100)  NULL,          -- the chosen code as received, e.g. 'PR 204'
    PrimaryDenialCode           nvarchar(50)   NULL,          -- normalized, e.g. '204'
    PrimaryDenialGroupCode      varchar(2)     NULL,          -- CO | PR | PI | OA, when present
    HasDenial                   AS (CONVERT(bit, CASE WHEN PrimaryDenialCode IS NULL THEN 0 ELSE 1 END)) PERSISTED,
    PreviousPrimaryDenialCode   nvarchar(50)   NULL,          -- value before the last change (re-sync rules)
    PrimaryDenialChangedOn      datetime2(0)   NULL,
    NewDenialSinceWork          bit            NOT NULL CONSTRAINT DF_ARWB_Claim_NewDenialSinceWork DEFAULT (0),  -- worked claim got a new denial; cleared when re-worked
    DenialDate                  date           NULL,          -- earliest line-level DenialDate
    DenialCategory              nvarchar(200)  NULL,          -- NULL when the claim has no denial
    IsDenialCategoryManual      bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsDenialCategoryManual DEFAULT (0),
    DenialReason                nvarchar(1000) NULL,
    DenialRootCause             nvarchar(400)  NULL,

    -- Line-level denial rollup (display and search only - never drives the queue in this phase)
    LineCount                   int            NOT NULL CONSTRAINT DF_ARWB_Claim_LineCount       DEFAULT (0),
    DeniedLineCount             int            NOT NULL CONSTRAINT DF_ARWB_Claim_DeniedLineCount DEFAULT (0),
    LineDenialCodes             nvarchar(2000) NULL,          -- distinct normalized line codes, comma separated
    LineDenialCodesSearch       AS (CONVERT(nvarchar(2002), N',' + ISNULL(LineDenialCodes, N'') + N',')) PERSISTED,

    -- Source financials (typed)
    ChargeAmount                decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_ChargeAmount         DEFAULT (0),
    AllowedAmount               decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_AllowedAmount        DEFAULT (0),
    InsurancePayment            decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_InsurancePayment     DEFAULT (0),
    PatientPayment              decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_PatientPayment       DEFAULT (0),
    TotalPayments               decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_TotalPayments        DEFAULT (0),
    InsuranceAdjustments        decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_InsuranceAdjustments DEFAULT (0),
    PatientAdjustments          decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_PatientAdjustments   DEFAULT (0),
    TotalAdjustments            decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_TotalAdjustments     DEFAULT (0),
    InsuranceBalance            decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_InsuranceBalance     DEFAULT (0),
    PatientBalance              decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_PatientBalance       DEFAULT (0),
    TotalBalance                decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_TotalBalance         DEFAULT (0),

    -- Recovery (handoff section 7). Initial* are frozen at first sync; the rest are recomputed by
    -- dbo.ARWB_usp_RecalculateClaimState.
    InitialInsuranceAR          decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_InitialInsuranceAR          DEFAULT (0),
    InitialInsurancePayment     decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_InitialInsurancePayment     DEFAULT (0),
    InitialInsuranceAdjustments decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_InitialInsuranceAdjustments DEFAULT (0),
    RevenueExpectation          decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_RevenueExpectation DEFAULT (0),  -- renamed from Expected Payment
    IsRevenueRateMissing        bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsRevenueRateMissing DEFAULT (0), -- a line had no fee-schedule rate
    ActualPayment               decimal(18,2)  NULL,
    PaymentVariance             decimal(18,2)  NULL,          -- Revenue Expectation - insurance payment
    PaymentPct                  decimal(9,4)   NULL,
    UnderpaymentAmount          decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_UnderpaymentAmount DEFAULT (0),
    IsAppealRequired            bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsAppealRequired   DEFAULT (0),
    PotentialRecovery           decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_PotentialRecovery  DEFAULT (0),
    RecoveryStatus              varchar(30)    NULL,          -- In Progress | Partially Recovered | Fully Recovered | No Recovery
    RecoveredAmount             decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_RecoveredAmount    DEFAULT (0),
    RemainingAR                 decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_RemainingAR        DEFAULT (0),
    AdjustmentAmount            decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_AdjustmentAmount   DEFAULT (0),

    -- Automatic adjustment and write-off (handoff 6, 8.3). The workbench is not PMS-integrated:
    -- the balance is nullified here, then posted in the PMS and confirmed.
    IsAutoAdjustEligible        bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsAutoAdjustEligible DEFAULT (0),
    IsAutoAdjusted              bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsAutoAdjusted       DEFAULT (0),
    AutoAdjustedOn              datetime2(0)   NULL,
    AutoAdjustedBy              nvarchar(256)  NULL,
    AutoAdjustReasonCode        nvarchar(50)   NULL,
    AutoAdjustAmount            decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_AutoAdjustAmount DEFAULT (0),
    IsWriteOffApproved          bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsWriteOffApproved   DEFAULT (0),
    WriteOffApprovedOn          datetime2(0)   NULL,
    WriteOffApprovedBy          nvarchar(256)  NULL,
    WriteOffAmount              decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_Claim_WriteOffAmount DEFAULT (0),
    IsPmsPostedConfirmed        bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsPmsPostedConfirmed DEFAULT (0),
    PmsPostedOn                 datetime2(0)   NULL,
    PmsPostedBy                 nvarchar(256)  NULL,
    IsAdjustmentNotPosted       bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsAdjustmentNotPosted DEFAULT (0),  -- still open in the master after a sync
    AdjustmentNotPostedOn       datetime2(0)   NULL,

    -- Workflow state
    WorkflowStatus              varchar(30)    NOT NULL CONSTRAINT DF_ARWB_Claim_WorkflowStatus DEFAULT ('Unassigned'),
    WorkflowTemplateKey         varchar(50)    NULL,
    Priority                    varchar(10)    NULL,
    PriorityOverride            varchar(10)    NULL,
    AssignedAgentUser           nvarchar(256)  NULL,
    AssignedOn                  datetime2(0)   NULL,
    AssignedBy                  nvarchar(256)  NULL,
    AssignmentBatchId           int            NULL,
    AssignmentDueDate           date           NULL,          -- optional batch due date (e.g. TFL-urgent batches)
    LastFollowUpDate            date           NULL,
    NextFollowUpDate            date           NULL,
    WorkedStatus                varchar(20)    NOT NULL CONSTRAINT DF_ARWB_Claim_WorkedStatus DEFAULT ('Not Worked'),
    FixResolution               nvarchar(200)  NULL,
    EscalationApproved          bit            NOT NULL CONSTRAINT DF_ARWB_Claim_EscalationApproved    DEFAULT (0),
    AdHocFollowUpAssigned       bit            NOT NULL CONSTRAINT DF_ARWB_Claim_AdHocFollowUpAssigned DEFAULT (0),

    -- Derived state (one server-side implementation: dbo.ARWB_usp_RecalculateClaimState)
    AgingDays                   int            NULL,
    AgingBucket                 nvarchar(50)   NULL,
    TflDeadline                 date           NULL,
    IsTflRisk                   bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsTflRisk           DEFAULT (0),
    IsNonCollectible            bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsNonCollectible    DEFAULT (0),
    HasNonCollectibleDenial     bit            NOT NULL CONSTRAINT DF_ARWB_Claim_HasNonCollectibleDenial DEFAULT (0),  -- ANY code on the claim is non-collectible
    IsFinanciallyClosed         bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsFinanciallyClosed DEFAULT (0),
    IsWorkComplete              bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsWorkComplete      DEFAULT (0),
    IsOpenInsuranceAR           bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsOpenInsuranceAR   DEFAULT (0),
    IsRefollowupDue             bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsRefollowupDue     DEFAULT (0),
    IsFollowUpActionable        bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsFollowUpActionable DEFAULT (0),
    ArQueueId                   varchar(40)    NULL,
    ArSubQueueId                varchar(40)    NULL,
    IsPriorityQueue             bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsPriorityQueue     DEFAULT (0),
    IsRestrictedQueue           bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsRestrictedQueue   DEFAULT (0),
    LastTouchedOn               datetime2(0)   NULL,          -- latest ARWB_ClaimActivity entry
    ClassifiedOn                datetime2(0)   NULL,

    -- Source tracking
    SourceRecordId              int            NULL,
    SourceRunId                 nvarchar(500)  NULL,
    SourceRowHash               nvarchar(64)   NULL,
    LineSetChecksum             int            NULL,          -- detects line-level changes independently of the claim row
    IsInCurrentSource           bit            NOT NULL CONSTRAINT DF_ARWB_Claim_IsInCurrentSource DEFAULT (1),
    FirstIdentifiedOn           datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_Claim_FirstIdentifiedOn DEFAULT (SYSUTCDATETIME()),
    FirstRefreshRunId           int            NULL CONSTRAINT FK_ARWB_Claim_FirstRefreshRun REFERENCES dbo.ARWB_RefreshRun (RefreshRunId),
    LastRefreshRunId            int            NULL CONSTRAINT FK_ARWB_Claim_LastRefreshRun  REFERENCES dbo.ARWB_RefreshRun (RefreshRunId),
    LastRefreshedOn             datetime2(0)   NULL,
    UpdatedOn                   datetime2(0)   NULL,
    UpdatedBy                   nvarchar(256)  NULL,
    RowVer                      rowversion     NOT NULL,

    CONSTRAINT CK_ARWB_Claim_WorkflowStatus   CHECK (WorkflowStatus IN ('Unassigned', 'Assigned', 'Submitted for QA', 'QA Rejected', 'Completed')),
    CONSTRAINT CK_ARWB_Claim_WorkedStatus     CHECK (WorkedStatus IN ('Not Worked', 'Worked')),
    CONSTRAINT CK_ARWB_Claim_Priority         CHECK (Priority IS NULL OR Priority IN ('High', 'Medium', 'Low')),
    CONSTRAINT CK_ARWB_Claim_PriorityOverride CHECK (PriorityOverride IS NULL OR PriorityOverride IN ('High', 'Medium', 'Low')),
    CONSTRAINT CK_ARWB_Claim_RecoveryStatus   CHECK (RecoveryStatus IS NULL OR RecoveryStatus IN ('In Progress', 'Partially Recovered', 'Fully Recovered', 'No Recovery')),
    CONSTRAINT FK_ARWB_Claim_ArQueue          FOREIGN KEY (ArQueueId)           REFERENCES dbo.ARWB_ArQueue (QueueId),
    CONSTRAINT FK_ARWB_Claim_ArSubQueue       FOREIGN KEY (ArSubQueueId)        REFERENCES dbo.ARWB_ArQueue (QueueId),
    CONSTRAINT FK_ARWB_Claim_WorkflowTemplate FOREIGN KEY (WorkflowTemplateKey) REFERENCES dbo.ARWB_WorkflowTemplate (TemplateKey)
);
GO

-- Added after the first release: existing installs get the column here (new installs above).
IF COL_LENGTH(N'dbo.ARWB_Claim', N'HasNonCollectibleDenial') IS NULL
    ALTER TABLE dbo.ARWB_Claim ADD HasNonCollectibleDenial bit NOT NULL
        CONSTRAINT DF_ARWB_Claim_HasNonCollectibleDenial DEFAULT (0);
GO

/* ============================================================================================
   E. CLAIM LINE - every CPT line from dbo.LineLevelData (denied or not)
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_ClaimLine', N'U') IS NULL
CREATE TABLE dbo.ARWB_ClaimLine
(
    ClaimLineKey            bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_ClaimLine PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_ClaimLine_Claim REFERENCES dbo.ARWB_Claim (ClaimKey),
    ClaimID                 nvarchar(200)  NOT NULL,
    LineNumber              int            NOT NULL,
    CPTCode                 nvarchar(50)   NULL,
    CPTDescription          nvarchar(500)  NULL,
    Units                   decimal(9,2)   NULL,
    Modifier                nvarchar(100)  NULL,
    POS                     nvarchar(50)   NULL,
    TOS                     nvarchar(50)   NULL,
    ChargeAmount            decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_ChargeAmount         DEFAULT (0),
    AllowedAmount           decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_AllowedAmount        DEFAULT (0),
    InsurancePayment        decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_InsurancePayment     DEFAULT (0),
    PatientPayment          decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_PatientPayment       DEFAULT (0),
    TotalPayments           decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_TotalPayments        DEFAULT (0),
    InsuranceAdjustments    decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_InsuranceAdjustments DEFAULT (0),
    PatientAdjustments      decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_PatientAdjustments   DEFAULT (0),
    TotalAdjustments        decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_TotalAdjustments     DEFAULT (0),
    InsuranceBalance        decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_InsuranceBalance     DEFAULT (0),
    PatientBalance          decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_PatientBalance       DEFAULT (0),
    TotalBalance            decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_TotalBalance         DEFAULT (0),
    LineClaimStatus         nvarchar(200)  NULL,
    PayStatus               nvarchar(200)  NULL,
    DenialCode              nvarchar(1000) NULL,          -- raw, group prefix kept for display (e.g. 'CO-16, N290')
    HasDenial               bit            NOT NULL CONSTRAINT DF_ARWB_ClaimLine_HasDenial DEFAULT (0),
    DenialDate              date           NULL,
    CheckDate               date           NULL,          -- payment date (drives Recovered Amount)
    PostingDate             date           NULL,
    ICDCode                 nvarchar(1000) NULL,
    ICDPointer              nvarchar(100)  NULL,
    -- Revenue Expectation for this line: fee-schedule rate x units (dbo.ARWB_usp_PriceClaimLines)
    ExpectedRate            decimal(18,2)  NULL,
    RevenueExpectation      decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_ClaimLine_RevenueExpectation DEFAULT (0),
    PricedOn                datetime2(0)   NULL,
    SourceRecordId          int            NULL,
    SourceRowHash           nvarchar(64)   NULL,
    RefreshRunId            int            NULL CONSTRAINT FK_ARWB_ClaimLine_RefreshRun REFERENCES dbo.ARWB_RefreshRun (RefreshRunId),
    LoadedOn                datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_ClaimLine_LoadedOn DEFAULT (SYSUTCDATETIME())
);
GO

-- One row per denial code on a line: the per-CPT "expand" in Claim Detail (handoff 2.3, FR-CD-05).
IF OBJECT_ID(N'dbo.ARWB_ClaimLineDenial', N'U') IS NULL
CREATE TABLE dbo.ARWB_ClaimLineDenial
(
    ClaimLineDenialKey      bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_ClaimLineDenial PRIMARY KEY,
    ClaimLineKey            bigint         NOT NULL CONSTRAINT FK_ARWB_ClaimLineDenial_Line  REFERENCES dbo.ARWB_ClaimLine (ClaimLineKey),
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_ClaimLineDenial_Claim REFERENCES dbo.ARWB_Claim (ClaimKey),
    Ordinal                 int            NOT NULL,
    DenialCodeRaw           nvarchar(100)  NOT NULL,      -- as received, e.g. 'CO-16'
    GroupCode               varchar(2)     NULL,          -- CO | PR | PI | OA
    DenialCode              nvarchar(50)   NOT NULL,      -- normalized, e.g. '16'
    CodeType                varchar(4)     NOT NULL,      -- CARC | RARC
    DenialCategory          nvarchar(200)  NULL,
    DenialReason            nvarchar(1000) NULL,
    IsNonCollectible        bit            NOT NULL CONSTRAINT DF_ARWB_ClaimLineDenial_IsNonCollectible DEFAULT (0),
    CONSTRAINT CK_ARWB_ClaimLineDenial_CodeType CHECK (CodeType IN ('CARC', 'RARC'))
);
GO

/* ============================================================================================
   F. POINT-IN-TIME FINANCIAL HISTORY - one row per claim per sync in which it changed
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_ClaimFinancialHistory', N'U') IS NULL
CREATE TABLE dbo.ARWB_ClaimFinancialHistory
(
    HistoryId               bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_ClaimFinancialHistory PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_ClaimFinancialHistory_Claim REFERENCES dbo.ARWB_Claim (ClaimKey),
    RefreshRunId            int            NOT NULL CONSTRAINT FK_ARWB_ClaimFinancialHistory_Run   REFERENCES dbo.ARWB_RefreshRun (RefreshRunId),
    SnapshotOn              datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_ClaimFinancialHistory_SnapshotOn DEFAULT (SYSUTCDATETIME()),
    ChangeType              varchar(20)    NOT NULL,          -- Identified | SourceChanged
    ChargeAmount            decimal(18,2)  NOT NULL,
    AllowedAmount           decimal(18,2)  NOT NULL,
    InsurancePayment        decimal(18,2)  NOT NULL,
    PatientPayment          decimal(18,2)  NOT NULL,
    InsuranceAdjustments    decimal(18,2)  NOT NULL,
    PatientAdjustments      decimal(18,2)  NOT NULL,
    InsuranceBalance        decimal(18,2)  NOT NULL,
    PatientBalance          decimal(18,2)  NOT NULL,
    TotalBalance            decimal(18,2)  NOT NULL,
    SourceClaimStatus       nvarchar(200)  NULL,
    DenialCode              nvarchar(1000) NULL,
    CONSTRAINT UQ_ARWB_ClaimFinancialHistory_Claim_Run UNIQUE (ClaimKey, RefreshRunId)
);
GO

/* ============================================================================================
   G. ACTIVITY / AUDIT LOG - append-only. Every claim has at least one entry ("Claim Identified").
      The Audit Logs screen is a projection over this table; there is no second audit source.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_ClaimActivity', N'U') IS NULL
CREATE TABLE dbo.ARWB_ClaimActivity
(
    ActivityId              bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_ClaimActivity PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_ClaimActivity_Claim REFERENCES dbo.ARWB_Claim (ClaimKey),
    ActivityOn              datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_ClaimActivity_ActivityOn DEFAULT (SYSUTCDATETIME()),
    ActionType              nvarchar(100)  NOT NULL,
    Detail                  nvarchar(2000) NULL,
    PreviousValue           nvarchar(1000) NULL,
    NewValue                nvarchar(1000) NULL,
    UserName                nvarchar(256)  NOT NULL,
    RoleCode                varchar(20)    NULL,          -- 'Automation' / 'ETL' for system entries
    IsSystem                bit            NOT NULL CONSTRAINT DF_ARWB_ClaimActivity_IsSystem DEFAULT (0),
    RelatedEntityType       varchar(30)    NULL,          -- FollowUp | QaReview | AgentRequest | CipCase | AssignmentBatch | RefreshRun | Document
    RelatedEntityId         bigint         NULL
);
GO

/* ============================================================================================
   H. FOLLOW-UP NOTES - Comments Framework, claim level only. Saving a note submits the claim to QA.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_ClaimFollowUp', N'U') IS NULL
CREATE TABLE dbo.ARWB_ClaimFollowUp
(
    FollowUpId              bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_ClaimFollowUp PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_ClaimFollowUp_Claim REFERENCES dbo.ARWB_Claim (ClaimKey),
    ClaimType               nvarchar(50)   NULL,          -- Primary | Secondary
    FollowUpType            nvarchar(50)   NULL,          -- Review | Online | Call
    FollowUpClaimStatus     nvarchar(100)  NOT NULL,      -- Paid | Denied | Not Received | ...
    DenialRootCause         nvarchar(400)  NULL,          -- required only when status = Denied
    FixResolution           nvarchar(200)  NOT NULL,
    FollowUpComment         nvarchar(4000) NULL,          -- internal; never shown to client users on CIP claims
    NextFollowUpDate        date           NULL,          -- default today + NextFollowUpDefaultDays (45)
    CipCategory             nvarchar(200)  NULL,          -- when FixResolution = CIP - Client Escalations
    CipRequiredInfo         nvarchar(400)  NULL,
    CipComment              nvarchar(4000) NULL,          -- client-facing; stored separately from FollowUpComment
    IsSystem                bit            NOT NULL CONSTRAINT DF_ARWB_ClaimFollowUp_IsSystem DEFAULT (0),
    CreatedBy               nvarchar(256)  NOT NULL,
    CreatedByRole           varchar(20)    NULL,
    CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_ClaimFollowUp_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_ARWB_ClaimFollowUp_RootCause CHECK (FollowUpClaimStatus <> N'Denied' OR DenialRootCause IS NOT NULL),
    CONSTRAINT CK_ARWB_ClaimFollowUp_Cip       CHECK (FixResolution <> N'CIP - Client Escalations' OR (CipCategory IS NOT NULL AND CipRequiredInfo IS NOT NULL AND CipComment IS NOT NULL))
);
GO

/* ============================================================================================
   I. QA REVIEW - one current row per claim. A reviewer can never approve their own submission.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_ClaimQaReview', N'U') IS NULL
CREATE TABLE dbo.ARWB_ClaimQaReview
(
    QaReviewId              bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_ClaimQaReview PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_ClaimQaReview_Claim    REFERENCES dbo.ARWB_Claim (ClaimKey),
    FollowUpId              bigint         NULL     CONSTRAINT FK_ARWB_ClaimQaReview_FollowUp REFERENCES dbo.ARWB_ClaimFollowUp (FollowUpId),
    ReviewStatus            varchar(20)    NOT NULL CONSTRAINT DF_ARWB_ClaimQaReview_Status DEFAULT ('Awaiting QA'),
    IsEscalation            bit            NOT NULL CONSTRAINT DF_ARWB_ClaimQaReview_IsEscalation DEFAULT (0),   -- CIP note: approval releases the CIP case
    IsWriteOff              bit            NOT NULL CONSTRAINT DF_ARWB_ClaimQaReview_IsWriteOff   DEFAULT (0),   -- Write Off note: approval -> Approved Write-Offs
    IsCurrent               bit            NOT NULL CONSTRAINT DF_ARWB_ClaimQaReview_IsCurrent    DEFAULT (1),
    SubmittedBy             nvarchar(256)  NOT NULL,
    SubmittedOn             datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_ClaimQaReview_SubmittedOn DEFAULT (SYSUTCDATETIME()),
    ReviewedBy              nvarchar(256)  NULL,
    ReviewedByRole          varchar(20)    NULL,
    ReviewedOn              datetime2(0)   NULL,
    ErrorType               nvarchar(100)  NULL,          -- required on reject (QA_ERROR_TYPE list)
    ScoreClaimAnalysis      bit            NULL,
    ScoreDenialCategory     bit            NULL,
    ScoreActionTaken        bit            NULL,
    ScoreDocumentation      bit            NULL,
    ScoreFinancialUpdate    bit            NULL,
    ScoreFollowUpTiming     bit            NULL,
    ReviewNote              nvarchar(2000) NULL,
    BulkBatchId             uniqueidentifier NULL,
    CONSTRAINT CK_ARWB_ClaimQaReview_Status        CHECK (ReviewStatus IN ('Awaiting QA', 'Approved', 'Rejected')),
    CONSTRAINT CK_ARWB_ClaimQaReview_NoSelfApprove CHECK (ReviewedBy IS NULL OR ReviewedBy <> SubmittedBy),
    CONSTRAINT CK_ARWB_ClaimQaReview_RejectReason  CHECK (ReviewStatus <> 'Rejected' OR (ErrorType IS NOT NULL AND ReviewNote IS NOT NULL))
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_ARWB_ClaimQaReview_Current' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimQaReview'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_ARWB_ClaimQaReview_Current
        ON dbo.ARWB_ClaimQaReview (ClaimKey)
        INCLUDE (ReviewStatus, IsEscalation, IsWriteOff, SubmittedBy, SubmittedOn)
        WHERE IsCurrent = 1;
GO

/* ============================================================================================
   J. AGENT REQUESTS - Escalate to Supervisor / Request Reassignment (internal only, never a CIP).
      A reason category is mandatory so volumes can be analysed by reason.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_AgentRequest', N'U') IS NULL
CREATE TABLE dbo.ARWB_AgentRequest
(
    AgentRequestId          bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_AgentRequest PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_AgentRequest_Claim REFERENCES dbo.ARWB_Claim (ClaimKey),
    RequestType             varchar(40)    NOT NULL,
    ReasonCategory          nvarchar(200)  NOT NULL,      -- ESCALATION_REASON / REASSIGNMENT_REASON list
    RequestNote             nvarchar(2000) NOT NULL,
    RequestedBy             nvarchar(256)  NOT NULL,
    RequestedByRole         varchar(20)    NULL,
    RequestedOn             datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_AgentRequest_RequestedOn DEFAULT (SYSUTCDATETIME()),
    RequestStatus           varchar(20)    NOT NULL CONSTRAINT DF_ARWB_AgentRequest_Status DEFAULT ('Pending'),
    ResolvedBy              nvarchar(256)  NULL,
    ResolvedByRole          varchar(20)    NULL,
    ResolvedOn              datetime2(0)   NULL,
    ResolutionNote          nvarchar(2000) NULL,
    BulkBatchId             uniqueidentifier NULL,        -- one shared note across a bulk resolve
    CONSTRAINT CK_ARWB_AgentRequest_Type   CHECK (RequestType IN ('Escalation to Supervisor', 'Reassignment Request')),
    CONSTRAINT CK_ARWB_AgentRequest_Status CHECK (RequestStatus IN ('Pending', 'Resolved'))
);
GO

/* ============================================================================================
   K. CIP - CLIENT ESCALATIONS
      Awaiting QA -> Pending Approval -> Sent to Client -> Client Responded
                  -> (Sent to Client, round + 1) -> Returned to Agent
      The case is created when the agent saves the CIP note, but only reaches Pending Approval after
      QA approves the note (handoff 9.1, FR-FU-03). Client users never see Awaiting QA or Pending Approval.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_CipCase', N'U') IS NULL
CREATE TABLE dbo.ARWB_CipCase
(
    CipCaseId               bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_CipCase PRIMARY KEY,
    CaseNumber              AS (CONVERT(varchar(30), 'CIP-' + RIGHT('000000' + CONVERT(varchar(20), CipCaseId), 6))) PERSISTED,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_CipCase_Claim    REFERENCES dbo.ARWB_Claim (ClaimKey),
    FollowUpId              bigint         NULL     CONSTRAINT FK_ARWB_CipCase_FollowUp REFERENCES dbo.ARWB_ClaimFollowUp (FollowUpId),
    CipCategory             nvarchar(200)  NOT NULL,
    RequiredInfo            nvarchar(400)  NOT NULL,
    CipComment              nvarchar(4000) NOT NULL,      -- client-facing wording
    CaseStatus              varchar(30)    NOT NULL CONSTRAINT DF_ARWB_CipCase_Status DEFAULT ('Awaiting QA'),
    RoundNumber             int            NOT NULL CONSTRAINT DF_ARWB_CipCase_Round  DEFAULT (1),
    OriginalAgentUser       nvarchar(256)  NULL,          -- claim returns to this agent when resolved
    ClinicName              nvarchar(500)  NULL,          -- routing to the clinic's scoped client users
    RequestedBy             nvarchar(256)  NOT NULL,
    RequestedByRole         varchar(20)    NULL,
    RequestedOn             datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_CipCase_RequestedOn DEFAULT (SYSUTCDATETIME()),
    FollowUpDate            date           NULL,
    LastReviewDecision      varchar(30)    NULL,          -- approved | insufficient | rejected
    LastReviewNote          nvarchar(2000) NULL,          -- visible to the client when insufficient
    LastReviewedBy          nvarchar(256)  NULL,
    LastReviewedByRole      varchar(20)    NULL,
    LastReviewedOn          datetime2(0)   NULL,
    ClientResponseText      nvarchar(4000) NULL,
    ClientRespondedBy       nvarchar(256)  NULL,
    ClientRespondedByRole   varchar(20)    NULL,
    ClientRespondedOn       datetime2(0)   NULL,
    ClosedOn                datetime2(0)   NULL,
    CONSTRAINT CK_ARWB_CipCase_Status CHECK (CaseStatus IN ('Awaiting QA', 'Pending Approval', 'Sent to Client', 'Client Responded', 'Returned to Agent')),
    CONSTRAINT CK_ARWB_CipCase_Round  CHECK (RoundNumber >= 1)
);
GO

IF OBJECT_ID(N'dbo.ARWB_CipCaseHistory', N'U') IS NULL
CREATE TABLE dbo.ARWB_CipCaseHistory
(
    CipCaseHistoryId        bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_CipCaseHistory PRIMARY KEY,
    CipCaseId               bigint         NOT NULL CONSTRAINT FK_ARWB_CipCaseHistory_Case REFERENCES dbo.ARWB_CipCase (CipCaseId),
    RoundNumber             int            NOT NULL,
    ActionOn                datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_CipCaseHistory_ActionOn DEFAULT (SYSUTCDATETIME()),
    Actor                   nvarchar(256)  NOT NULL,
    ActorRole               varchar(20)    NULL,
    ActionName              nvarchar(100)  NOT NULL,     -- Escalation Logged | QA Approved | Approved for Client | Client Responded | Sent Back | Returned to Agent
    Note                    nvarchar(4000) NULL,
    IsBulkAction            bit            NOT NULL CONSTRAINT DF_ARWB_CipCaseHistory_IsBulk DEFAULT (0),
    BulkBatchId             uniqueidentifier NULL
);
GO

/* ============================================================================================
   L. DOCUMENTS - attachments on every follow-up note and on CIP client responses (handoff 8.2).
      Files live in Azure Blob Storage (private container, encryption at rest, short-lived SAS);
      only the metadata is here. Size and type limits: AppSetting AttachmentMaxBytes / AttachmentAllowedTypes.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_Document', N'U') IS NULL
CREATE TABLE dbo.ARWB_Document
(
    DocumentId              bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_Document PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_Document_Claim    REFERENCES dbo.ARWB_Claim (ClaimKey),
    FollowUpId              bigint         NULL     CONSTRAINT FK_ARWB_Document_FollowUp REFERENCES dbo.ARWB_ClaimFollowUp (FollowUpId),
    CipCaseId               bigint         NULL     CONSTRAINT FK_ARWB_Document_CipCase  REFERENCES dbo.ARWB_CipCase (CipCaseId),
    CipRoundNumber          int            NULL,
    DocumentSource          varchar(20)    NOT NULL,      -- FollowUp | CipResponse | Other
    DocumentCategory        nvarchar(100)  NOT NULL,      -- DOCUMENT_CATEGORY list
    FileName                nvarchar(260)  NOT NULL,
    ContentType             nvarchar(200)  NULL,
    SizeBytes               bigint         NOT NULL,
    BlobContainer           nvarchar(100)  NOT NULL,
    BlobPath                nvarchar(1024) NOT NULL,
    ContentSha256           varchar(64)    NULL,
    UploadedBy              nvarchar(256)  NOT NULL,
    UploadedByRole          varchar(20)    NULL,
    UploadedOn              datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_Document_UploadedOn DEFAULT (SYSUTCDATETIME()),
    IsDeleted               bit            NOT NULL CONSTRAINT DF_ARWB_Document_IsDeleted DEFAULT (0),
    DeletedBy               nvarchar(256)  NULL,
    DeletedOn               datetime2(0)   NULL,
    CONSTRAINT CK_ARWB_Document_Size   CHECK (SizeBytes > 0),
    CONSTRAINT CK_ARWB_Document_Source CHECK (DocumentSource IN ('FollowUp', 'CipResponse', 'Other'))
);
GO

-- HIPAA: every view and download is logged.
IF OBJECT_ID(N'dbo.ARWB_DocumentAccessLog', N'U') IS NULL
CREATE TABLE dbo.ARWB_DocumentAccessLog
(
    DocumentAccessLogId     bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_DocumentAccessLog PRIMARY KEY,
    DocumentId              bigint         NOT NULL CONSTRAINT FK_ARWB_DocumentAccessLog_Document REFERENCES dbo.ARWB_Document (DocumentId),
    AccessType              varchar(20)    NOT NULL,      -- View | Download | Upload | Delete
    UserName                nvarchar(256)  NOT NULL,
    RoleCode                varchar(20)    NULL,
    ClientIp                varchar(64)    NULL,
    AccessedOn              datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_DocumentAccessLog_AccessedOn DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_ARWB_DocumentAccessLog_Type CHECK (AccessType IN ('View', 'Download', 'Upload', 'Delete'))
);
GO

/* ============================================================================================
   M. ASSIGNMENT - named batches with a running log. Due date is optional.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_AssignmentBatch', N'U') IS NULL
CREATE TABLE dbo.ARWB_AssignmentBatch
(
    AssignmentBatchId       int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_AssignmentBatch PRIMARY KEY,
    BatchNumber             AS (CONVERT(varchar(20), 'BATCH-' + RIGHT('0000' + CONVERT(varchar(10), AssignmentBatchId), 4))) PERSISTED,
    BatchName               nvarchar(200)  NOT NULL,
    AgentUser               nvarchar(256)  NOT NULL,
    DueDate                 date           NULL,
    CriteriaJson            nvarchar(max)  NULL,          -- client, category, payer, panel, priority, action/task
    ClaimCount              int            NOT NULL CONSTRAINT DF_ARWB_AssignmentBatch_ClaimCount DEFAULT (0),
    TotalInsuranceAR        decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_AssignmentBatch_TotalAR    DEFAULT (0),
    BatchStatus             varchar(20)    NOT NULL CONSTRAINT DF_ARWB_AssignmentBatch_Status     DEFAULT ('Open'),
    CreatedBy               nvarchar(256)  NOT NULL,
    CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_AssignmentBatch_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CompletedOn             datetime2(0)   NULL,
    CONSTRAINT CK_ARWB_AssignmentBatch_Status CHECK (BatchStatus IN ('Open', 'Completed', 'Cancelled'))
);
GO

IF OBJECT_ID(N'dbo.ARWB_AssignmentBatchClaim', N'U') IS NULL
CREATE TABLE dbo.ARWB_AssignmentBatchClaim
(
    AssignmentBatchId       int            NOT NULL CONSTRAINT FK_ARWB_AssignmentBatchClaim_Batch REFERENCES dbo.ARWB_AssignmentBatch (AssignmentBatchId),
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_AssignmentBatchClaim_Claim REFERENCES dbo.ARWB_Claim (ClaimKey),
    PreviousAgentUser       nvarchar(256)  NULL,
    InsuranceARAtAssignment decimal(18,2)  NOT NULL CONSTRAINT DF_ARWB_AssignmentBatchClaim_AR DEFAULT (0),
    AssignedOn              datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_AssignmentBatchClaim_AssignedOn DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ARWB_AssignmentBatchClaim PRIMARY KEY (AssignmentBatchId, ClaimKey)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ARWB_Claim_AssignmentBatch')
    ALTER TABLE dbo.ARWB_Claim WITH CHECK
        ADD CONSTRAINT FK_ARWB_Claim_AssignmentBatch FOREIGN KEY (AssignmentBatchId) REFERENCES dbo.ARWB_AssignmentBatch (AssignmentBatchId);
GO

/* ============================================================================================
   N. SAVED VIEWS - per user, per queue: filters + hidden columns (server-persisted)
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_SavedView', N'U') IS NULL
CREATE TABLE dbo.ARWB_SavedView
(
    SavedViewId             int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_SavedView PRIMARY KEY,
    UserName                nvarchar(256)  NOT NULL,
    ViewKey                 varchar(60)    NOT NULL,      -- workqueue | mywork | followup | assignment | qa | cip | agent-requests | audit | vault
    ViewName                nvarchar(120)  NOT NULL,
    FiltersJson             nvarchar(max)  NULL,
    HiddenColumnsJson       nvarchar(max)  NULL,
    IsDefault               bit            NOT NULL CONSTRAINT DF_ARWB_SavedView_IsDefault DEFAULT (0),
    CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_SavedView_CreatedOn DEFAULT (SYSUTCDATETIME()),
    UpdatedOn               datetime2(0)   NULL,
    CONSTRAINT UQ_ARWB_SavedView_User_Key_Name UNIQUE (UserName, ViewKey, ViewName)
);
GO

/* ============================================================================================
   O. NOTIFICATIONS - write-off approved, adjustment not posted, CIP responses, auto-unassigned claims.
      Addressed to one user, or to every user of a role in the lab (RecipientRole, e.g. 'manager').
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_Notification', N'U') IS NULL
CREATE TABLE dbo.ARWB_Notification
(
    NotificationId          bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_Notification PRIMARY KEY,
    ClaimKey                bigint         NULL     CONSTRAINT FK_ARWB_Notification_Claim REFERENCES dbo.ARWB_Claim (ClaimKey),
    RecipientUser           nvarchar(256)  NULL,
    RecipientRole           varchar(20)    NULL,          -- admin | manager | lead | agent | qa | viewer
    NotificationType        varchar(40)    NOT NULL,      -- WriteOffApproved | AdjustmentNotPosted | CipClientResponded | AutoUnassigned | NewDenial
    Message                 nvarchar(1000) NOT NULL,
    CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_Notification_CreatedOn DEFAULT (SYSUTCDATETIME()),
    ReadOn                  datetime2(0)   NULL,
    ReadBy                  nvarchar(256)  NULL,
    RelatedEntityType       varchar(30)    NULL,
    RelatedEntityId         bigint         NULL,
    CONSTRAINT CK_ARWB_Notification_Recipient CHECK (RecipientUser IS NOT NULL OR RecipientRole IS NOT NULL)
);
GO

/* ============================================================================================
   P. DENIAL ANALYSIS INSIGHTS - one set per sync week, grouped by PRIMARY denial code.
      The claim list is frozen at build time; dbo.ARWB_vw_DenialInsight shows the live unassigned,
      still-open remainder, so assigned claims drop out of an insight's count and balance.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_DenialInsight', N'U') IS NULL
CREATE TABLE dbo.ARWB_DenialInsight
(
    DenialInsightId         int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_ARWB_DenialInsight PRIMARY KEY,
    WeekStart               date           NOT NULL,
    RefreshRunId            int            NULL CONSTRAINT FK_ARWB_DenialInsight_Run REFERENCES dbo.ARWB_RefreshRun (RefreshRunId),
    DenialCode              nvarchar(50)   NOT NULL,      -- normalized primary code
    DenialDescription       nvarchar(1000) NULL,
    DenialCategory          nvarchar(200)  NULL,
    CategoryTag             nvarchar(50)   NULL,
    RecommendedAction       nvarchar(1000) NULL,
    ClaimCount              int            NOT NULL,      -- at build time
    TotalBalance            decimal(18,2)  NOT NULL,      -- at build time, all payers
    TopPayer                nvarchar(500)  NULL,          -- informational highlight, not a filter
    TopPayerBalance         decimal(18,2)  NULL,
    ImpactPct               decimal(9,4)   NULL,
    TopServiceLine          nvarchar(200)  NULL,          -- most common denied CPT, else panel
    Observation             nvarchar(1000) NULL,
    CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_DenialInsight_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT UQ_ARWB_DenialInsight_Week_Code UNIQUE (WeekStart, DenialCode)
);
GO

IF OBJECT_ID(N'dbo.ARWB_DenialInsightClaim', N'U') IS NULL
CREATE TABLE dbo.ARWB_DenialInsightClaim
(
    DenialInsightId         int            NOT NULL CONSTRAINT FK_ARWB_DenialInsightClaim_Insight REFERENCES dbo.ARWB_DenialInsight (DenialInsightId),
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_ARWB_DenialInsightClaim_Claim   REFERENCES dbo.ARWB_Claim (ClaimKey),
    CONSTRAINT PK_ARWB_DenialInsightClaim PRIMARY KEY (DenialInsightId, ClaimKey)
);
GO

/* ============================================================================================
   Q. QUEUE SNAPSHOT - nightly queue membership per claim, for trend / movement reporting.
   ============================================================================================ */
IF OBJECT_ID(N'dbo.ARWB_QueueSnapshot', N'U') IS NULL
CREATE TABLE dbo.ARWB_QueueSnapshot
(
    SnapshotDate            date           NOT NULL,
    ClaimKey                bigint         NOT NULL,
    ArQueueId               varchar(40)    NULL,
    ArSubQueueId            varchar(40)    NULL,
    WorkflowStatus          varchar(30)    NOT NULL,
    AssignedAgentUser       nvarchar(256)  NULL,
    InsuranceBalance        decimal(18,2)  NOT NULL,
    PatientBalance          decimal(18,2)  NOT NULL,
    RemainingAR             decimal(18,2)  NOT NULL,
    RecoveredAmount         decimal(18,2)  NOT NULL,
    CONSTRAINT PK_ARWB_QueueSnapshot PRIMARY KEY (SnapshotDate, ClaimKey)
);
GO

/* ============================================================================================
   R. INDEXES - sized for the full claim-level master (every claim, not only denied ones)
   ============================================================================================ */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_ARWB_Claim_ClaimID' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_ARWB_Claim_ClaimID ON dbo.ARWB_Claim (ClaimID);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_Queue' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_Queue
        ON dbo.ARWB_Claim (ArQueueId, ArSubQueueId)
        INCLUDE (WorkflowStatus, AssignedAgentUser, RemainingAR, InsuranceBalance, PatientBalance, RecoveredAmount, PotentialRecovery, IsInCurrentSource);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_WorkflowStatus' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_WorkflowStatus
        ON dbo.ARWB_Claim (WorkflowStatus, IsOpenInsuranceAR)
        INCLUDE (AssignedAgentUser, LastTouchedOn, InsuranceBalance, RemainingAR, ArQueueId, PrimaryDenialCode);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_Agent' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_Agent
        ON dbo.ARWB_Claim (AssignedAgentUser, WorkflowStatus)
        INCLUDE (NextFollowUpDate, LastFollowUpDate, InsuranceBalance, RemainingAR, IsWorkComplete, IsOpenInsuranceAR)
        WHERE AssignedAgentUser IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_FollowUpDue' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_FollowUpDue
        ON dbo.ARWB_Claim (NextFollowUpDate)
        INCLUDE (LastFollowUpDate, WorkflowStatus, AssignedAgentUser, InsuranceBalance)
        WHERE NextFollowUpDate IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_PrimaryDenial' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_PrimaryDenial
        ON dbo.ARWB_Claim (PrimaryDenialCode)
        INCLUDE (WorkflowStatus, IsOpenInsuranceAR, RemainingAR, PayerName, DenialCategory)
        WHERE PrimaryDenialCode IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_Clinic' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_Clinic   ON dbo.ARWB_Claim (ClinicName)        INCLUDE (ArQueueId, WorkflowStatus);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_Provider' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_Provider ON dbo.ARWB_Claim (ReferringProvider) INCLUDE (ArQueueId, WorkflowStatus);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_Payer' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_Payer    ON dbo.ARWB_Claim (PayerName)         INCLUDE (RecoveredAmount, RemainingAR, InitialInsuranceAR);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Claim_LastRefreshRun' AND object_id = OBJECT_ID(N'dbo.ARWB_Claim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Claim_LastRefreshRun ON dbo.ARWB_Claim (LastRefreshRunId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimLine_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimLine'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimLine_Claim
        ON dbo.ARWB_ClaimLine (ClaimKey, LineNumber)
        INCLUDE (InsurancePayment, CheckDate, PostingDate, RevenueExpectation, ExpectedRate, HasDenial);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimLine_CPT' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimLine'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimLine_CPT ON dbo.ARWB_ClaimLine (CPTCode) INCLUDE (ClaimKey, InsuranceBalance, Modifier);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimLineDenial_Line' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimLineDenial'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimLineDenial_Line ON dbo.ARWB_ClaimLineDenial (ClaimLineKey, Ordinal);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimLineDenial_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimLineDenial'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimLineDenial_Claim ON dbo.ARWB_ClaimLineDenial (ClaimKey) INCLUDE (DenialCode, ClaimLineKey);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimLineDenial_Code' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimLineDenial'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimLineDenial_Code ON dbo.ARWB_ClaimLineDenial (DenialCode) INCLUDE (ClaimKey, ClaimLineKey);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_CptFeeSchedule_CPT' AND object_id = OBJECT_ID(N'dbo.ARWB_CptFeeSchedule'))
    CREATE NONCLUSTERED INDEX IX_ARWB_CptFeeSchedule_CPT ON dbo.ARWB_CptFeeSchedule (CPTCode, Modifier, EffectiveFrom) INCLUDE (Rate, EffectiveTo);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimActivity_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimActivity'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimActivity_Claim ON dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimActivity_On' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimActivity'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimActivity_On ON dbo.ARWB_ClaimActivity (ActivityOn DESC) INCLUDE (ClaimKey, ActionType, UserName, IsSystem);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimFollowUp_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimFollowUp'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimFollowUp_Claim ON dbo.ARWB_ClaimFollowUp (ClaimKey, CreatedOn DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimQaReview_Status' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimQaReview'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimQaReview_Status ON dbo.ARWB_ClaimQaReview (ReviewStatus, SubmittedOn) INCLUDE (ClaimKey, SubmittedBy, IsEscalation, IsWriteOff) WHERE IsCurrent = 1;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_AgentRequest_Status' AND object_id = OBJECT_ID(N'dbo.ARWB_AgentRequest'))
    CREATE NONCLUSTERED INDEX IX_ARWB_AgentRequest_Status ON dbo.ARWB_AgentRequest (RequestStatus, RequestedOn) INCLUDE (ClaimKey, RequestType, ReasonCategory, RequestedBy);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_AgentRequest_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_AgentRequest'))
    CREATE NONCLUSTERED INDEX IX_ARWB_AgentRequest_Claim ON dbo.ARWB_AgentRequest (ClaimKey);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_CipCase_Status' AND object_id = OBJECT_ID(N'dbo.ARWB_CipCase'))
    CREATE NONCLUSTERED INDEX IX_ARWB_CipCase_Status ON dbo.ARWB_CipCase (CaseStatus) INCLUDE (ClaimKey, RoundNumber, RequestedOn, ClientRespondedOn, ClinicName);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_CipCase_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_CipCase'))
    CREATE NONCLUSTERED INDEX IX_ARWB_CipCase_Claim ON dbo.ARWB_CipCase (ClaimKey) INCLUDE (CaseStatus, ClientRespondedOn);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_CipCaseHistory_Case' AND object_id = OBJECT_ID(N'dbo.ARWB_CipCaseHistory'))
    CREATE NONCLUSTERED INDEX IX_ARWB_CipCaseHistory_Case ON dbo.ARWB_CipCaseHistory (CipCaseId, ActionOn);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Document_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_Document'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Document_Claim ON dbo.ARWB_Document (ClaimKey, UploadedOn DESC) INCLUDE (DocumentCategory, FileName, IsDeleted);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Document_Category' AND object_id = OBJECT_ID(N'dbo.ARWB_Document'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Document_Category ON dbo.ARWB_Document (DocumentCategory, UploadedOn DESC) INCLUDE (ClaimKey, UploadedBy) WHERE IsDeleted = 0;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Document_CipCase' AND object_id = OBJECT_ID(N'dbo.ARWB_Document'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Document_CipCase ON dbo.ARWB_Document (CipCaseId, CipRoundNumber) WHERE CipCaseId IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_DocumentAccessLog_Document' AND object_id = OBJECT_ID(N'dbo.ARWB_DocumentAccessLog'))
    CREATE NONCLUSTERED INDEX IX_ARWB_DocumentAccessLog_Document ON dbo.ARWB_DocumentAccessLog (DocumentId, AccessedOn);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_ClaimFinancialHistory_Run' AND object_id = OBJECT_ID(N'dbo.ARWB_ClaimFinancialHistory'))
    CREATE NONCLUSTERED INDEX IX_ARWB_ClaimFinancialHistory_Run ON dbo.ARWB_ClaimFinancialHistory (RefreshRunId) INCLUDE (ClaimKey, InsurancePayment, InsuranceBalance);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_AssignmentBatchClaim_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_AssignmentBatchClaim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_AssignmentBatchClaim_Claim ON dbo.ARWB_AssignmentBatchClaim (ClaimKey);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Notification_User' AND object_id = OBJECT_ID(N'dbo.ARWB_Notification'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Notification_User ON dbo.ARWB_Notification (RecipientUser, ReadOn) INCLUDE (NotificationType, CreatedOn, ClaimKey) WHERE RecipientUser IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Notification_Role' AND object_id = OBJECT_ID(N'dbo.ARWB_Notification'))
    CREATE NONCLUSTERED INDEX IX_ARWB_Notification_Role ON dbo.ARWB_Notification (RecipientRole, ReadOn) INCLUDE (NotificationType, CreatedOn, ClaimKey) WHERE RecipientRole IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_DenialInsightClaim_Claim' AND object_id = OBJECT_ID(N'dbo.ARWB_DenialInsightClaim'))
    CREATE NONCLUSTERED INDEX IX_ARWB_DenialInsightClaim_Claim ON dbo.ARWB_DenialInsightClaim (ClaimKey);
GO

PRINT 'AR Workbench 01: ARWB_ tables ready.';
GO

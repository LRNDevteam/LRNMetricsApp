/* ============================================================================================
   AR Workbench - COMPLETE LAB DATABASE SETUP (scripts 01-06 merged)
   GENERATED from the numbered scripts in this folder - edit those, then regenerate this file.
   Run in each lab database (the one holding dbo.ClaimLevelData / dbo.LineLevelData).
   Users, roles and permissions are NOT here: they use the existing LRNMaster tables - run
   LRNMaster_01_ArWorkbench_Roles_Access.sql once in LRNMaster.
   Optional script 07 (index on dbo.LineLevelData) is NOT included - run it separately if wanted.
   ============================================================================================ */

-- >>>>>>>>>> 01_ArWorkbench_Schema_Tables.sql >>>>>>>>>>
/* ============================================================================================
   AR Workbench - 01 Schema and Tables
   Run once per LAB database (the same database that holds dbo.ClaimLevelData / dbo.LineLevelData).

   Everything lives in its own schema, [arwb], so the existing Denial Workflow objects
   (dbo.DenialTaskBoard, dbo.DenialClaimNotes, dbo.DenialCodeMaster, ...) are not touched.

   Source of truth for claims is dbo.ClaimLevelData (claim level) and dbo.LineLevelData (CPT lines).
   arwb.usp_LoadClaimsFromSource (script 05) copies every claim-level row whose DenialCode is not
   null into arwb.Claim, and that claim's line-level rows into arwb.ClaimLine.

   Idempotent: every object is created only when missing. Safe to re-run.
   Requires SQL Server 2016 SP1+ (CREATE OR ALTER in later scripts).
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF SCHEMA_ID(N'arwb') IS NULL
    EXEC (N'CREATE SCHEMA arwb AUTHORIZATION dbo;');
GO

/* ============================================================================================
   A. SECURITY - not in the lab database.
   Users, roles and lab access come from the existing LRNMaster tables (dbo.LabUsers, dbo.Roles,
   dbo.UserRoles, dbo.UserLabs, dbo.RoleFeatureAccess) - see LRNMaster_01_ArWorkbench_Roles_Access.sql.
   Claim columns that hold a user (AssignedAgentUser, CreatedBy, ReviewedBy, ...) store
   dbo.LabUsers.UserName.
   ============================================================================================ */

/* ============================================================================================
   B. MASTER FILE MAINTENANCE - admin-editable reference data
   ============================================================================================ */

-- Generic chip-list master. One table for every simple list so CSV download/upload is one code path.
-- ListType values used by the app (seeded in script 03):
--   DENIAL_CATEGORY, PANEL_TYPE, NON_COLLECTIBLE_CODE, DENIAL_ROOT_CAUSE, FIX_RESOLUTION,
--   CLAIM_TYPE, FOLLOW_UP_TYPE, CLAIM_STATUS, CIP_CATEGORY, CIP_REQUIRED_INFO,
--   WORKFLOW_STATUS, AGING_BUCKET, FINANCIAL_CLASS
IF OBJECT_ID(N'arwb.MasterListItem', N'U') IS NULL
CREATE TABLE arwb.MasterListItem
(
    MasterListItemId    int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_MasterListItem PRIMARY KEY,
    ListType            varchar(50)    NOT NULL,
    ItemValue           nvarchar(400)  NOT NULL,
    SortOrder           int            NOT NULL CONSTRAINT DF_arwb_MasterListItem_SortOrder DEFAULT (0),
    IsActive            bit            NOT NULL CONSTRAINT DF_arwb_MasterListItem_IsActive  DEFAULT (1),
    CreatedOn           datetime2(0)   NOT NULL CONSTRAINT DF_arwb_MasterListItem_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CreatedBy           nvarchar(256)  NULL,
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL,
    CONSTRAINT UQ_arwb_MasterListItem_Type_Value UNIQUE (ListType, ItemValue)
);
GO

-- Denial Code -> Denial Category. Codes are stored normalized: upper case, no spaces, no hyphen
-- (CO-16 and CO16 are the same code). Drives Claim.DenialCategory and the workflow template.
IF OBJECT_ID(N'arwb.DenialCodeCategoryMap', N'U') IS NULL
CREATE TABLE arwb.DenialCodeCategoryMap
(
    DenialCode          nvarchar(50)   NOT NULL CONSTRAINT PK_arwb_DenialCodeCategoryMap PRIMARY KEY,
    DenialCategory      nvarchar(200)  NOT NULL,
    DenialReason        nvarchar(1000) NULL,
    IsActive            bit            NOT NULL CONSTRAINT DF_arwb_DenialCodeCategoryMap_IsActive  DEFAULT (1),
    CreatedOn           datetime2(0)   NOT NULL CONSTRAINT DF_arwb_DenialCodeCategoryMap_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CreatedBy           nvarchar(256)  NULL,
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL
);
GO

-- Which Fix/Resolution options are valid for a given follow-up Claim Status.
IF OBJECT_ID(N'arwb.FixResolutionByStatus', N'U') IS NULL
CREATE TABLE arwb.FixResolutionByStatus
(
    ClaimStatus         nvarchar(100)  NOT NULL,
    FixResolution       nvarchar(200)  NOT NULL,
    SortOrder           int            NOT NULL CONSTRAINT DF_arwb_FixResolutionByStatus_SortOrder DEFAULT (0),
    CONSTRAINT PK_arwb_FixResolutionByStatus PRIMARY KEY (ClaimStatus, FixResolution)
);
GO

-- Named stage path per denial category (claim workspace stepper).
IF OBJECT_ID(N'arwb.WorkflowTemplate', N'U') IS NULL
CREATE TABLE arwb.WorkflowTemplate
(
    TemplateKey         varchar(50)    NOT NULL CONSTRAINT PK_arwb_WorkflowTemplate PRIMARY KEY,
    TemplateLabel       nvarchar(200)  NOT NULL,
    IsActive            bit            NOT NULL CONSTRAINT DF_arwb_WorkflowTemplate_IsActive DEFAULT (1)
);
GO

IF OBJECT_ID(N'arwb.WorkflowTemplateStage', N'U') IS NULL
CREATE TABLE arwb.WorkflowTemplateStage
(
    TemplateKey         varchar(50)    NOT NULL CONSTRAINT FK_arwb_WorkflowTemplateStage_Template REFERENCES arwb.WorkflowTemplate (TemplateKey),
    StageOrder          tinyint        NOT NULL,
    StageName           nvarchar(200)  NOT NULL,
    CONSTRAINT PK_arwb_WorkflowTemplateStage PRIMARY KEY (TemplateKey, StageOrder)
);
GO

IF OBJECT_ID(N'arwb.DenialCategoryTemplate', N'U') IS NULL
CREATE TABLE arwb.DenialCategoryTemplate
(
    DenialCategory      nvarchar(200)  NOT NULL CONSTRAINT PK_arwb_DenialCategoryTemplate PRIMARY KEY,
    TemplateKey         varchar(50)    NOT NULL CONSTRAINT FK_arwb_DenialCategoryTemplate_Template REFERENCES arwb.WorkflowTemplate (TemplateKey)
);
GO

-- Timely-filing limit per financial class (ClaimLevelData.PayerType). Unmatched classes use
-- AppSetting TflDefaultDays.
IF OBJECT_ID(N'arwb.TflThreshold', N'U') IS NULL
CREATE TABLE arwb.TflThreshold
(
    FinancialClass      nvarchar(200)  NOT NULL CONSTRAINT PK_arwb_TflThreshold PRIMARY KEY,
    ThresholdDays       int            NOT NULL,
    CONSTRAINT CK_arwb_TflThreshold_Days CHECK (ThresholdDays > 0)
);
GO

-- The AR queue taxonomy: 12 top-level queues, several with collectible / non-collectible sub-queues.
IF OBJECT_ID(N'arwb.ArQueue', N'U') IS NULL
CREATE TABLE arwb.ArQueue
(
    QueueId             varchar(40)    NOT NULL CONSTRAINT PK_arwb_ArQueue PRIMARY KEY,
    ParentQueueId       varchar(40)    NULL CONSTRAINT FK_arwb_ArQueue_Parent REFERENCES arwb.ArQueue (QueueId),
    QueueLabel          nvarchar(200)  NOT NULL,
    IsPriority          bit            NOT NULL CONSTRAINT DF_arwb_ArQueue_IsPriority DEFAULT (0),
    SortOrder           int            NOT NULL CONSTRAINT DF_arwb_ArQueue_SortOrder  DEFAULT (0),
    BadgeClass          varchar(40)    NULL
);
GO

-- Tunable business-rule thresholds (45-day untouched, balance epsilon, TFL window, ...).
IF OBJECT_ID(N'arwb.AppSetting', N'U') IS NULL
CREATE TABLE arwb.AppSetting
(
    SettingKey          varchar(100)   NOT NULL CONSTRAINT PK_arwb_AppSetting PRIMARY KEY,
    SettingValue        nvarchar(400)  NOT NULL,
    Description         nvarchar(1000) NULL,
    UpdatedOn           datetime2(0)   NULL,
    UpdatedBy           nvarchar(256)  NULL
);
GO

/* ============================================================================================
   C. DATA PROCESSING - one row per refresh from dbo.ClaimLevelData
   ============================================================================================ */
IF OBJECT_ID(N'arwb.RefreshRun', N'U') IS NULL
CREATE TABLE arwb.RefreshRun
(
    RefreshRunId            int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_RefreshRun PRIMARY KEY,
    SourceRunId             nvarchar(500)  NULL,     -- ClaimLevelData.RunId of the latest file
    SourceFileName          nvarchar(500)  NULL,
    SourceWeekFolder        nvarchar(500)  NULL,
    SourcePeriodStart       date           NULL,     -- MIN(DateOfService) in the loaded set
    SourcePeriodEnd         date           NULL,     -- MAX(DateOfService) in the loaded set
    RunStatus               varchar(20)    NOT NULL CONSTRAINT DF_arwb_RefreshRun_Status DEFAULT ('Running'),
    StartedOn               datetime2(0)   NOT NULL CONSTRAINT DF_arwb_RefreshRun_StartedOn DEFAULT (SYSUTCDATETIME()),
    CompletedOn             datetime2(0)   NULL,
    SourceClaimRows         int            NULL,
    SourceLineRows          int            NULL,
    ClaimsInserted          int            NULL,
    ClaimsUpdated           int            NULL,
    ClaimsUnchanged         int            NULL,
    ClaimsNoLongerInSource  int            NULL,
    ClaimsLinesReloaded     int            NULL,
    RunBy                   nvarchar(256)  NULL,
    Note                    nvarchar(1000) NULL,
    ErrorMessage            nvarchar(max)  NULL,
    CONSTRAINT CK_arwb_RefreshRun_Status CHECK (RunStatus IN ('Running', 'Succeeded', 'Failed'))
);
GO

/* ============================================================================================
   D. CLAIM - one row per denied claim, typed copy of dbo.ClaimLevelData + workbench state
   ============================================================================================ */
IF OBJECT_ID(N'arwb.Claim', N'U') IS NULL
CREATE TABLE arwb.Claim
(
    ClaimKey                    bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_Claim PRIMARY KEY,

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

    -- Source status and denial
    SourceClaimStatus           nvarchar(200)  NULL,
    DeniedStatus                nvarchar(200)  NULL,
    DenialCode                  nvarchar(1000) NULL,
    DenialCodesNormalized       AS (CONVERT(nvarchar(1100),
                                        N',' + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(UPPER(ISNULL(DenialCode, N'')),
                                        N' ', N''), N'-', N''), N';', N','), N'|', N','), N'/', N',') + N',')) PERSISTED,
    DenialDate                  date           NULL,          -- earliest line-level DenialDate
    DenialCategory              nvarchar(200)  NULL,
    IsDenialCategoryManual      bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsDenialCategoryManual DEFAULT (0),
    DenialReason                nvarchar(1000) NULL,
    DenialRootCause             nvarchar(400)  NULL,

    -- Source financials (typed)
    ChargeAmount                decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_ChargeAmount         DEFAULT (0),
    AllowedAmount               decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_AllowedAmount        DEFAULT (0),
    InsurancePayment            decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_InsurancePayment     DEFAULT (0),
    PatientPayment              decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_PatientPayment       DEFAULT (0),
    TotalPayments               decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_TotalPayments        DEFAULT (0),
    InsuranceAdjustments        decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_InsuranceAdjustments DEFAULT (0),
    PatientAdjustments          decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_PatientAdjustments   DEFAULT (0),
    TotalAdjustments            decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_TotalAdjustments     DEFAULT (0),
    InsuranceBalance            decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_InsuranceBalance     DEFAULT (0),
    PatientBalance              decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_PatientBalance       DEFAULT (0),
    TotalBalance                decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_TotalBalance         DEFAULT (0),

    -- Recovery / AR remediation (item 1). Initial* are frozen at first identification; the rest are
    -- recomputed by arwb.usp_RecalculateClaimState.
    InitialInsuranceAR          decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_InitialInsuranceAR          DEFAULT (0),
    InitialInsurancePayment     decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_InitialInsurancePayment     DEFAULT (0),
    InitialInsuranceAdjustments decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_InitialInsuranceAdjustments DEFAULT (0),
    ExpectedPayment             decimal(18,2)  NULL,
    ActualPayment               decimal(18,2)  NULL,
    PaymentVariance             decimal(18,2)  NULL,
    PaymentPct                  decimal(9,4)   NULL,
    UnderpaymentAmount          decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_UnderpaymentAmount DEFAULT (0),
    IsAppealRequired            bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsAppealRequired   DEFAULT (0),
    RecoveryStatus              varchar(30)    NULL,
    RecoveredAmount             decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_RecoveredAmount    DEFAULT (0),
    RemainingAR                 decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_RemainingAR        DEFAULT (0),
    AdjustmentAmount            decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_AdjustmentAmount   DEFAULT (0),
    ArCategory                  nvarchar(200)  NULL,
    ArRemark                    nvarchar(1000) NULL,

    -- Automatic adjustment (no-touch write-off of a non-collectible balance)
    IsWrittenOff                bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsWrittenOff DEFAULT (0),
    WriteOffAmount              decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_Claim_WriteOffAmount DEFAULT (0),
    WrittenOffOn                datetime2(0)   NULL,
    WrittenOffBy                nvarchar(256)  NULL,

    -- Workflow state
    WorkflowStatus              varchar(30)    NOT NULL CONSTRAINT DF_arwb_Claim_WorkflowStatus DEFAULT ('Unassigned'),
    WorkflowTemplateKey         varchar(50)    NULL,
    Priority                    varchar(10)    NULL,
    PriorityOverride            varchar(10)    NULL,
    AssignedAgentUser           nvarchar(256)  NULL,
    AssignedOn                  datetime2(0)   NULL,
    AssignedBy                  nvarchar(256)  NULL,
    AssignmentBatchId           int            NULL,
    AssignmentDueDate           date           NULL,
    LastFollowUpDate            date           NULL,
    NextFollowUpDate            date           NULL,
    WorkedStatus                varchar(20)    NOT NULL CONSTRAINT DF_arwb_Claim_WorkedStatus DEFAULT ('Not Worked'),
    FixResolution               nvarchar(200)  NULL,
    EscalationApproved          bit            NOT NULL CONSTRAINT DF_arwb_Claim_EscalationApproved    DEFAULT (0),
    AdHocFollowUpAssigned       bit            NOT NULL CONSTRAINT DF_arwb_Claim_AdHocFollowUpAssigned DEFAULT (0),

    -- Derived state (one server-side implementation: arwb.usp_RecalculateClaimState)
    AgingDays                   int            NULL,
    AgingBucket                 nvarchar(50)   NULL,
    TflDeadline                 date           NULL,
    IsTflRisk                   bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsTflRisk           DEFAULT (0),
    IsNonCollectible            bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsNonCollectible    DEFAULT (0),
    IsFinanciallyClosed         bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsFinanciallyClosed DEFAULT (0),
    IsWorkComplete              bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsWorkComplete      DEFAULT (0),
    IsOpenInsuranceAR           bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsOpenInsuranceAR   DEFAULT (0),
    IsRefollowupDue             bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsRefollowupDue     DEFAULT (0),
    ArQueueId                   varchar(40)    NULL,
    ArSubQueueId                varchar(40)    NULL,
    IsPriorityQueue             bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsPriorityQueue     DEFAULT (0),
    LastTouchedOn               datetime2(0)   NULL,          -- latest arwb.ClaimActivity entry
    ClassifiedOn                datetime2(0)   NULL,

    -- Source tracking
    SourceRecordId              int            NULL,
    SourceRunId                 nvarchar(500)  NULL,
    SourceRowHash               nvarchar(64)   NULL,
    LineSetChecksum             int            NULL,          -- detects line-level changes independently of the claim row
    IsInCurrentSource           bit            NOT NULL CONSTRAINT DF_arwb_Claim_IsInCurrentSource DEFAULT (1),
    FirstIdentifiedOn           datetime2(0)   NOT NULL CONSTRAINT DF_arwb_Claim_FirstIdentifiedOn DEFAULT (SYSUTCDATETIME()),
    FirstRefreshRunId           int            NULL CONSTRAINT FK_arwb_Claim_FirstRefreshRun REFERENCES arwb.RefreshRun (RefreshRunId),
    LastRefreshRunId            int            NULL CONSTRAINT FK_arwb_Claim_LastRefreshRun  REFERENCES arwb.RefreshRun (RefreshRunId),
    LastRefreshedOn             datetime2(0)   NULL,
    UpdatedOn                   datetime2(0)   NULL,
    UpdatedBy                   nvarchar(256)  NULL,
    RowVer                      rowversion     NOT NULL,

    CONSTRAINT CK_arwb_Claim_WorkflowStatus CHECK (WorkflowStatus IN ('Unassigned', 'Assigned', 'Submitted for QA', 'QA Rejected', 'Completed')),
    CONSTRAINT CK_arwb_Claim_WorkedStatus   CHECK (WorkedStatus IN ('Not Worked', 'Worked')),
    CONSTRAINT CK_arwb_Claim_Priority       CHECK (Priority IS NULL OR Priority IN ('High', 'Medium', 'Low')),
    CONSTRAINT CK_arwb_Claim_PriorityOverride CHECK (PriorityOverride IS NULL OR PriorityOverride IN ('High', 'Medium', 'Low')),
    CONSTRAINT FK_arwb_Claim_ArQueue    FOREIGN KEY (ArQueueId)    REFERENCES arwb.ArQueue (QueueId),
    CONSTRAINT FK_arwb_Claim_ArSubQueue FOREIGN KEY (ArSubQueueId) REFERENCES arwb.ArQueue (QueueId),
    CONSTRAINT FK_arwb_Claim_WorkflowTemplate FOREIGN KEY (WorkflowTemplateKey) REFERENCES arwb.WorkflowTemplate (TemplateKey)
);
GO

/* ============================================================================================
   E. CLAIM LINE - CPT lines from dbo.LineLevelData
   ============================================================================================ */
IF OBJECT_ID(N'arwb.ClaimLine', N'U') IS NULL
CREATE TABLE arwb.ClaimLine
(
    ClaimLineKey            bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_ClaimLine PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_arwb_ClaimLine_Claim REFERENCES arwb.Claim (ClaimKey),
    ClaimID                 nvarchar(200)  NOT NULL,
    LineNumber              int            NOT NULL,
    CPTCode                 nvarchar(50)   NULL,
    Units                   decimal(9,2)   NULL,
    Modifier                nvarchar(100)  NULL,
    POS                     nvarchar(50)   NULL,
    TOS                     nvarchar(50)   NULL,
    ChargeAmount            decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_ChargeAmount         DEFAULT (0),
    AllowedAmount           decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_AllowedAmount        DEFAULT (0),
    InsurancePayment        decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_InsurancePayment     DEFAULT (0),
    PatientPayment          decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_PatientPayment       DEFAULT (0),
    TotalPayments           decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_TotalPayments        DEFAULT (0),
    InsuranceAdjustments    decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_InsuranceAdjustments DEFAULT (0),
    PatientAdjustments      decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_PatientAdjustments   DEFAULT (0),
    TotalAdjustments        decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_TotalAdjustments     DEFAULT (0),
    InsuranceBalance        decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_InsuranceBalance     DEFAULT (0),
    PatientBalance          decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_PatientBalance       DEFAULT (0),
    TotalBalance            decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_ClaimLine_TotalBalance         DEFAULT (0),
    LineClaimStatus         nvarchar(200)  NULL,
    PayStatus               nvarchar(200)  NULL,
    DenialCode              nvarchar(1000) NULL,
    DenialDate              date           NULL,
    CheckDate               date           NULL,
    PostingDate             date           NULL,
    ICDCode                 nvarchar(1000) NULL,
    ICDPointer              nvarchar(100)  NULL,
    SourceRecordId          int            NULL,
    SourceRowHash           nvarchar(64)   NULL,
    RefreshRunId            int            NULL CONSTRAINT FK_arwb_ClaimLine_RefreshRun REFERENCES arwb.RefreshRun (RefreshRunId),
    LoadedOn                datetime2(0)   NOT NULL CONSTRAINT DF_arwb_ClaimLine_LoadedOn DEFAULT (SYSUTCDATETIME())
);
GO

/* ============================================================================================
   F. POINT-IN-TIME FINANCIAL HISTORY - one row per claim per refresh in which it changed.
      Recovered amount is a delta against a previous refresh; this is the history it is read from.
   ============================================================================================ */
IF OBJECT_ID(N'arwb.ClaimFinancialHistory', N'U') IS NULL
CREATE TABLE arwb.ClaimFinancialHistory
(
    HistoryId               bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_ClaimFinancialHistory PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_arwb_ClaimFinancialHistory_Claim REFERENCES arwb.Claim (ClaimKey),
    RefreshRunId            int            NOT NULL CONSTRAINT FK_arwb_ClaimFinancialHistory_Run   REFERENCES arwb.RefreshRun (RefreshRunId),
    SnapshotOn              datetime2(0)   NOT NULL CONSTRAINT DF_arwb_ClaimFinancialHistory_SnapshotOn DEFAULT (SYSUTCDATETIME()),
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
    CONSTRAINT UQ_arwb_ClaimFinancialHistory_Claim_Run UNIQUE (ClaimKey, RefreshRunId)
);
GO

/* ============================================================================================
   G. ACTIVITY / AUDIT LOG - every claim has at least one entry ("Claim Identified").
      Audit Logs screen is a projection over this table; there is no second audit source.
   ============================================================================================ */
IF OBJECT_ID(N'arwb.ClaimActivity', N'U') IS NULL
CREATE TABLE arwb.ClaimActivity
(
    ActivityId              bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_ClaimActivity PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_arwb_ClaimActivity_Claim REFERENCES arwb.Claim (ClaimKey),
    ActivityOn              datetime2(0)   NOT NULL CONSTRAINT DF_arwb_ClaimActivity_ActivityOn DEFAULT (SYSUTCDATETIME()),
    ActionType              nvarchar(100)  NOT NULL,
    Detail                  nvarchar(2000) NULL,
    UserName                nvarchar(256)  NOT NULL,
    RoleCode                varchar(20)    NULL,
    IsSystem                bit            NOT NULL CONSTRAINT DF_arwb_ClaimActivity_IsSystem DEFAULT (0),   -- 'System' / 'Automation' entries
    RelatedEntityType       varchar(30)    NULL,                                                             -- FollowUp | QaReview | AgentRequest | CipCase | AssignmentBatch | RefreshRun
    RelatedEntityId         bigint         NULL
);
GO

/* ============================================================================================
   H. FOLLOW-UP NOTES - Comments Framework capture. Saving a note submits the claim to QA.
   ============================================================================================ */
IF OBJECT_ID(N'arwb.ClaimFollowUp', N'U') IS NULL
CREATE TABLE arwb.ClaimFollowUp
(
    FollowUpId              bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_ClaimFollowUp PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_arwb_ClaimFollowUp_Claim REFERENCES arwb.Claim (ClaimKey),
    ClaimType               nvarchar(50)   NULL,          -- Primary | Secondary
    FollowUpType            nvarchar(50)   NULL,          -- Review | Online | Call
    FollowUpClaimStatus     nvarchar(100)  NOT NULL,      -- Paid | Denied | Not Received | ...
    DenialRootCause         nvarchar(400)  NULL,          -- required only when status = Denied
    FixResolution           nvarchar(200)  NOT NULL,
    FollowUpComment         nvarchar(4000) NULL,
    NextFollowUpDate        date           NULL,
    CipCategory             nvarchar(200)  NULL,          -- historical copy of the CIP request, when FixResolution = CIP - Client Escalations
    CipRequiredInfo         nvarchar(400)  NULL,
    CipComment              nvarchar(4000) NULL,
    CreatedBy               nvarchar(256)  NOT NULL,
    CreatedByRole           varchar(20)    NULL,
    CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_arwb_ClaimFollowUp_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_arwb_ClaimFollowUp_RootCause CHECK (FollowUpClaimStatus <> N'Denied' OR DenialRootCause IS NOT NULL)
);
GO

/* ============================================================================================
   I. QA REVIEW - one current row per claim. A reviewer can never approve their own submission.
   ============================================================================================ */
IF OBJECT_ID(N'arwb.ClaimQaReview', N'U') IS NULL
CREATE TABLE arwb.ClaimQaReview
(
    QaReviewId              bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_ClaimQaReview PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_arwb_ClaimQaReview_Claim    REFERENCES arwb.Claim (ClaimKey),
    FollowUpId              bigint         NULL     CONSTRAINT FK_arwb_ClaimQaReview_FollowUp REFERENCES arwb.ClaimFollowUp (FollowUpId),
    ReviewStatus            varchar(20)    NOT NULL CONSTRAINT DF_arwb_ClaimQaReview_Status DEFAULT ('Awaiting QA'),
    IsEscalation            bit            NOT NULL CONSTRAINT DF_arwb_ClaimQaReview_IsEscalation DEFAULT (0),
    IsCurrent               bit            NOT NULL CONSTRAINT DF_arwb_ClaimQaReview_IsCurrent    DEFAULT (1),
    SubmittedBy             nvarchar(256)  NOT NULL,
    SubmittedOn             datetime2(0)   NOT NULL CONSTRAINT DF_arwb_ClaimQaReview_SubmittedOn DEFAULT (SYSUTCDATETIME()),
    ReviewedBy              nvarchar(256)  NULL,
    ReviewedByRole          varchar(20)    NULL,
    ReviewedOn              datetime2(0)   NULL,
    ReviewNote              nvarchar(2000) NULL,
    BulkBatchId             uniqueidentifier NULL,
    CONSTRAINT CK_arwb_ClaimQaReview_Status   CHECK (ReviewStatus IN ('Awaiting QA', 'Approved', 'Rejected')),
    CONSTRAINT CK_arwb_ClaimQaReview_NoSelfApprove CHECK (ReviewedBy IS NULL OR ReviewedBy <> SubmittedBy)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_arwb_ClaimQaReview_Current' AND object_id = OBJECT_ID(N'arwb.ClaimQaReview'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_arwb_ClaimQaReview_Current
        ON arwb.ClaimQaReview (ClaimKey)
        INCLUDE (ReviewStatus, IsEscalation, SubmittedBy, SubmittedOn)
        WHERE IsCurrent = 1;
GO

/* ============================================================================================
   J. AGENT REQUESTS - Escalate to Supervisor / Request Reassignment (internal only, never a CIP)
   ============================================================================================ */
IF OBJECT_ID(N'arwb.AgentRequest', N'U') IS NULL
CREATE TABLE arwb.AgentRequest
(
    AgentRequestId          bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_AgentRequest PRIMARY KEY,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_arwb_AgentRequest_Claim REFERENCES arwb.Claim (ClaimKey),
    RequestType             varchar(40)    NOT NULL,
    RequestNote             nvarchar(2000) NULL,
    RequestedBy             nvarchar(256)  NOT NULL,
    RequestedOn             datetime2(0)   NOT NULL CONSTRAINT DF_arwb_AgentRequest_RequestedOn DEFAULT (SYSUTCDATETIME()),
    RequestStatus           varchar(20)    NOT NULL CONSTRAINT DF_arwb_AgentRequest_Status DEFAULT ('Pending'),
    ResolvedBy              nvarchar(256)  NULL,
    ResolvedOn              datetime2(0)   NULL,
    ResolutionNote          nvarchar(2000) NULL,
    BulkBatchId             uniqueidentifier NULL,       -- one shared note across a bulk resolve
    CONSTRAINT CK_arwb_AgentRequest_Type   CHECK (RequestType IN ('Escalation to Supervisor', 'Reassignment Request')),
    CONSTRAINT CK_arwb_AgentRequest_Status CHECK (RequestStatus IN ('Pending', 'Resolved'))
);
GO

/* ============================================================================================
   K. CIP - CLIENT ESCALATIONS
      Pending Approval -> Sent to Client -> Client Responded -> (Sent to Client, round + 1) -> Returned to Agent
   ============================================================================================ */
IF OBJECT_ID(N'arwb.CipCase', N'U') IS NULL
CREATE TABLE arwb.CipCase
(
    CipCaseId               bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_CipCase PRIMARY KEY,
    CaseNumber              AS (CONVERT(varchar(30), 'CIP-' + RIGHT('000000' + CONVERT(varchar(20), CipCaseId), 6))) PERSISTED,
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_arwb_CipCase_Claim    REFERENCES arwb.Claim (ClaimKey),
    FollowUpId              bigint         NULL     CONSTRAINT FK_arwb_CipCase_FollowUp REFERENCES arwb.ClaimFollowUp (FollowUpId),
    CipCategory             nvarchar(200)  NOT NULL,
    RequiredInfo            nvarchar(400)  NOT NULL,
    CipComment              nvarchar(4000) NULL,
    CaseStatus              varchar(30)    NOT NULL CONSTRAINT DF_arwb_CipCase_Status DEFAULT ('Pending Approval'),
    RoundNumber             int            NOT NULL CONSTRAINT DF_arwb_CipCase_Round  DEFAULT (1),
    RequestedBy             nvarchar(256)  NOT NULL,
    RequestedByRole         varchar(20)    NULL,
    RequestedOn             datetime2(0)   NOT NULL CONSTRAINT DF_arwb_CipCase_RequestedOn DEFAULT (SYSUTCDATETIME()),
    FollowUpDate            date           NULL,
    LastReviewDecision      varchar(30)    NULL,          -- approved | insufficient | rejected
    LastReviewNote          nvarchar(2000) NULL,
    LastReviewedBy          nvarchar(256)  NULL,
    LastReviewedOn          datetime2(0)   NULL,
    ClientResponseText      nvarchar(4000) NULL,
    ClientRespondedBy       nvarchar(256)  NULL,
    ClientRespondedOn       datetime2(0)   NULL,
    ClosedOn                datetime2(0)   NULL,
    CONSTRAINT CK_arwb_CipCase_Status CHECK (CaseStatus IN ('Pending Approval', 'Sent to Client', 'Client Responded', 'Returned to Agent')),
    CONSTRAINT CK_arwb_CipCase_Round  CHECK (RoundNumber >= 1)
);
GO

IF OBJECT_ID(N'arwb.CipCaseHistory', N'U') IS NULL
CREATE TABLE arwb.CipCaseHistory
(
    CipCaseHistoryId        bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_CipCaseHistory PRIMARY KEY,
    CipCaseId               bigint         NOT NULL CONSTRAINT FK_arwb_CipCaseHistory_Case REFERENCES arwb.CipCase (CipCaseId),
    RoundNumber             int            NOT NULL,
    ActionOn                datetime2(0)   NOT NULL CONSTRAINT DF_arwb_CipCaseHistory_ActionOn DEFAULT (SYSUTCDATETIME()),
    Actor                   nvarchar(256)  NOT NULL,
    ActorRole               varchar(20)    NULL,
    ActionName              nvarchar(100)  NOT NULL,     -- Escalation Logged | Approved for Client | Client Responded | Sent Back | Returned to Agent
    Note                    nvarchar(4000) NULL,
    BulkBatchId             uniqueidentifier NULL
);
GO

-- Up to 3 attachments per client response (AppSetting CipAttachMaxFiles / CipAttachMaxBytes).
IF OBJECT_ID(N'arwb.CipAttachment', N'U') IS NULL
CREATE TABLE arwb.CipAttachment
(
    CipAttachmentId         bigint         IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_CipAttachment PRIMARY KEY,
    CipCaseId               bigint         NOT NULL CONSTRAINT FK_arwb_CipAttachment_Case REFERENCES arwb.CipCase (CipCaseId),
    RoundNumber             int            NOT NULL,
    FileName                nvarchar(260)  NOT NULL,
    ContentType             nvarchar(200)  NULL,
    SizeBytes               int            NOT NULL,
    Content                 varbinary(max) NOT NULL,
    UploadedBy              nvarchar(256)  NOT NULL,
    UploadedOn              datetime2(0)   NOT NULL CONSTRAINT DF_arwb_CipAttachment_UploadedOn DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_arwb_CipAttachment_Size CHECK (SizeBytes > 0)
);
GO

/* ============================================================================================
   L. ASSIGNMENT - named batches with a running log
   ============================================================================================ */
IF OBJECT_ID(N'arwb.AssignmentBatch', N'U') IS NULL
CREATE TABLE arwb.AssignmentBatch
(
    AssignmentBatchId       int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_AssignmentBatch PRIMARY KEY,
    BatchName               nvarchar(200)  NOT NULL,
    AgentUser               nvarchar(256)  NOT NULL,
    DueDate                 date           NULL,
    CriteriaJson            nvarchar(max)  NULL,          -- filter set the batch was built from
    ClaimCount              int            NOT NULL CONSTRAINT DF_arwb_AssignmentBatch_ClaimCount DEFAULT (0),
    TotalInsuranceAR        decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_AssignmentBatch_TotalAR    DEFAULT (0),
    BatchStatus             varchar(20)    NOT NULL CONSTRAINT DF_arwb_AssignmentBatch_Status     DEFAULT ('Open'),
    CreatedBy               nvarchar(256)  NOT NULL,
    CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_arwb_AssignmentBatch_CreatedOn DEFAULT (SYSUTCDATETIME()),
    CompletedOn             datetime2(0)   NULL,
    CONSTRAINT CK_arwb_AssignmentBatch_Status CHECK (BatchStatus IN ('Open', 'Completed', 'Cancelled'))
);
GO

IF OBJECT_ID(N'arwb.AssignmentBatchClaim', N'U') IS NULL
CREATE TABLE arwb.AssignmentBatchClaim
(
    AssignmentBatchId       int            NOT NULL CONSTRAINT FK_arwb_AssignmentBatchClaim_Batch REFERENCES arwb.AssignmentBatch (AssignmentBatchId),
    ClaimKey                bigint         NOT NULL CONSTRAINT FK_arwb_AssignmentBatchClaim_Claim REFERENCES arwb.Claim (ClaimKey),
    PreviousAgentUser       nvarchar(256)  NULL,
    InsuranceARAtAssignment decimal(18,2)  NOT NULL CONSTRAINT DF_arwb_AssignmentBatchClaim_AR DEFAULT (0),
    AssignedOn              datetime2(0)   NOT NULL CONSTRAINT DF_arwb_AssignmentBatchClaim_AssignedOn DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_arwb_AssignmentBatchClaim PRIMARY KEY (AssignmentBatchId, ClaimKey)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_arwb_Claim_AssignmentBatch')
    ALTER TABLE arwb.Claim WITH CHECK
        ADD CONSTRAINT FK_arwb_Claim_AssignmentBatch FOREIGN KEY (AssignmentBatchId) REFERENCES arwb.AssignmentBatch (AssignmentBatchId);
GO

/* ============================================================================================
   M. SAVED VIEWS - per user, per queue: filters + hidden columns
   ============================================================================================ */
IF OBJECT_ID(N'arwb.SavedView', N'U') IS NULL
CREATE TABLE arwb.SavedView
(
    SavedViewId             int            IDENTITY(1,1) NOT NULL CONSTRAINT PK_arwb_SavedView PRIMARY KEY,
    UserName                nvarchar(256)  NOT NULL,
    ViewKey                 varchar(60)    NOT NULL,      -- workqueue | mywork | followup | assignment | qa | cip | agent-requests | audit
    ViewName                nvarchar(120)  NOT NULL,
    FiltersJson             nvarchar(max)  NULL,
    HiddenColumnsJson       nvarchar(max)  NULL,
    IsDefault               bit            NOT NULL CONSTRAINT DF_arwb_SavedView_IsDefault DEFAULT (0),
    CreatedOn               datetime2(0)   NOT NULL CONSTRAINT DF_arwb_SavedView_CreatedOn DEFAULT (SYSUTCDATETIME()),
    UpdatedOn               datetime2(0)   NULL,
    CONSTRAINT UQ_arwb_SavedView_User_Key_Name UNIQUE (UserName, ViewKey, ViewName)
);
GO

/* ============================================================================================
   N. INDEXES - sized for 400k+ claims per lab
   ============================================================================================ */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_arwb_Claim_ClaimID' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE UNIQUE NONCLUSTERED INDEX UX_arwb_Claim_ClaimID ON arwb.Claim (ClaimID);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_Claim_Queue' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE NONCLUSTERED INDEX IX_arwb_Claim_Queue
        ON arwb.Claim (ArQueueId, ArSubQueueId)
        INCLUDE (WorkflowStatus, AssignedAgentUser, RemainingAR, InsuranceBalance, PatientBalance, RecoveredAmount, IsInCurrentSource);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_Claim_WorkflowStatus' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE NONCLUSTERED INDEX IX_arwb_Claim_WorkflowStatus
        ON arwb.Claim (WorkflowStatus, IsOpenInsuranceAR)
        INCLUDE (AssignedAgentUser, LastTouchedOn, InsuranceBalance, RemainingAR, ArQueueId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_Claim_Agent' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE NONCLUSTERED INDEX IX_arwb_Claim_Agent
        ON arwb.Claim (AssignedAgentUser, WorkflowStatus)
        INCLUDE (NextFollowUpDate, LastFollowUpDate, InsuranceBalance, RemainingAR, IsWorkComplete, IsOpenInsuranceAR)
        WHERE AssignedAgentUser IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_Claim_FollowUpDue' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE NONCLUSTERED INDEX IX_arwb_Claim_FollowUpDue
        ON arwb.Claim (NextFollowUpDate)
        INCLUDE (LastFollowUpDate, WorkflowStatus, AssignedAgentUser, InsuranceBalance)
        WHERE NextFollowUpDate IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_Claim_Clinic' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE NONCLUSTERED INDEX IX_arwb_Claim_Clinic   ON arwb.Claim (ClinicName)        INCLUDE (ArQueueId, WorkflowStatus);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_Claim_Provider' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE NONCLUSTERED INDEX IX_arwb_Claim_Provider ON arwb.Claim (ReferringProvider) INCLUDE (ArQueueId, WorkflowStatus);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_Claim_Payer' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE NONCLUSTERED INDEX IX_arwb_Claim_Payer    ON arwb.Claim (PayerName)         INCLUDE (RecoveredAmount, RemainingAR, InitialInsuranceAR);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_Claim_LastRefreshRun' AND object_id = OBJECT_ID(N'arwb.Claim'))
    CREATE NONCLUSTERED INDEX IX_arwb_Claim_LastRefreshRun ON arwb.Claim (LastRefreshRunId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_ClaimLine_Claim' AND object_id = OBJECT_ID(N'arwb.ClaimLine'))
    CREATE NONCLUSTERED INDEX IX_arwb_ClaimLine_Claim ON arwb.ClaimLine (ClaimKey, LineNumber);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_ClaimLine_CPT' AND object_id = OBJECT_ID(N'arwb.ClaimLine'))
    CREATE NONCLUSTERED INDEX IX_arwb_ClaimLine_CPT ON arwb.ClaimLine (CPTCode) INCLUDE (ClaimKey, InsuranceBalance);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_ClaimActivity_Claim' AND object_id = OBJECT_ID(N'arwb.ClaimActivity'))
    CREATE NONCLUSTERED INDEX IX_arwb_ClaimActivity_Claim ON arwb.ClaimActivity (ClaimKey, ActivityOn DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_ClaimActivity_On' AND object_id = OBJECT_ID(N'arwb.ClaimActivity'))
    CREATE NONCLUSTERED INDEX IX_arwb_ClaimActivity_On ON arwb.ClaimActivity (ActivityOn DESC) INCLUDE (ClaimKey, ActionType, UserName, IsSystem);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_ClaimFollowUp_Claim' AND object_id = OBJECT_ID(N'arwb.ClaimFollowUp'))
    CREATE NONCLUSTERED INDEX IX_arwb_ClaimFollowUp_Claim ON arwb.ClaimFollowUp (ClaimKey, CreatedOn DESC);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_ClaimQaReview_Status' AND object_id = OBJECT_ID(N'arwb.ClaimQaReview'))
    CREATE NONCLUSTERED INDEX IX_arwb_ClaimQaReview_Status ON arwb.ClaimQaReview (ReviewStatus, SubmittedOn) INCLUDE (ClaimKey, SubmittedBy, IsEscalation) WHERE IsCurrent = 1;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_AgentRequest_Status' AND object_id = OBJECT_ID(N'arwb.AgentRequest'))
    CREATE NONCLUSTERED INDEX IX_arwb_AgentRequest_Status ON arwb.AgentRequest (RequestStatus, RequestedOn) INCLUDE (ClaimKey, RequestType, RequestedBy);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_AgentRequest_Claim' AND object_id = OBJECT_ID(N'arwb.AgentRequest'))
    CREATE NONCLUSTERED INDEX IX_arwb_AgentRequest_Claim ON arwb.AgentRequest (ClaimKey);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_CipCase_Status' AND object_id = OBJECT_ID(N'arwb.CipCase'))
    CREATE NONCLUSTERED INDEX IX_arwb_CipCase_Status ON arwb.CipCase (CaseStatus) INCLUDE (ClaimKey, RoundNumber, RequestedOn, ClientRespondedOn);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_CipCase_Claim' AND object_id = OBJECT_ID(N'arwb.CipCase'))
    CREATE NONCLUSTERED INDEX IX_arwb_CipCase_Claim ON arwb.CipCase (ClaimKey) INCLUDE (CaseStatus, ClientRespondedOn);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_CipCaseHistory_Case' AND object_id = OBJECT_ID(N'arwb.CipCaseHistory'))
    CREATE NONCLUSTERED INDEX IX_arwb_CipCaseHistory_Case ON arwb.CipCaseHistory (CipCaseId, ActionOn);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_CipAttachment_Case' AND object_id = OBJECT_ID(N'arwb.CipAttachment'))
    CREATE NONCLUSTERED INDEX IX_arwb_CipAttachment_Case ON arwb.CipAttachment (CipCaseId, RoundNumber);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_ClaimFinancialHistory_Run' AND object_id = OBJECT_ID(N'arwb.ClaimFinancialHistory'))
    CREATE NONCLUSTERED INDEX IX_arwb_ClaimFinancialHistory_Run ON arwb.ClaimFinancialHistory (RefreshRunId) INCLUDE (ClaimKey, InsurancePayment, InsuranceBalance);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_arwb_AssignmentBatchClaim_Claim' AND object_id = OBJECT_ID(N'arwb.AssignmentBatchClaim'))
    CREATE NONCLUSTERED INDEX IX_arwb_AssignmentBatchClaim_Claim ON arwb.AssignmentBatchClaim (ClaimKey);
GO

PRINT 'AR Workbench 01: schema and tables ready.';
GO

GO

-- >>>>>>>>>> 02_ArWorkbench_Functions.sql >>>>>>>>>>
/* ============================================================================================
   AR Workbench - 02 Parsing helpers
   dbo.ClaimLevelData / dbo.LineLevelData hold every value as nvarchar. These inline table-valued
   functions convert them once, consistently. Inline TVFs (not scalar UDFs) so the optimizer folds
   them into the calling query - they cost nothing extra on a 400k-row load.
   Usage:  CROSS APPLY arwb.tvf_ParseMoney(s.InsuranceBalance) ib   ->  ib.Amount
           CROSS APPLY arwb.tvf_ParseDate(s.DateofService)     dos  ->  dos.DateValue
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- "$1,234.50" -> 1234.50 ; "(12.00)" -> -12.00 ; "" / "NULL" / junk -> NULL
CREATE OR ALTER FUNCTION arwb.tvf_ParseMoney (@Value nvarchar(500))
RETURNS TABLE
AS
RETURN
    SELECT Amount =
        CASE
            WHEN c.v IS NULL THEN NULL
            WHEN c.v LIKE N'(%)' THEN -TRY_CONVERT(decimal(18,2), SUBSTRING(c.v, 2, LEN(c.v) - 2))
            ELSE TRY_CONVERT(decimal(18,2), c.v)
        END
    FROM (SELECT v = NULLIF(NULLIF(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Value)), N'$', N''), N',', N''), N' ', N''), N''), N'NULL')) c;
GO

-- Accepts yyyy-mm-dd, yyyy-mm-dd hh:mi:ss, mm/dd/yyyy and anything else SQL Server parses.
CREATE OR ALTER FUNCTION arwb.tvf_ParseDate (@Value nvarchar(500))
RETURNS TABLE
AS
RETURN
    SELECT DateValue = COALESCE(
                TRY_CONVERT(date, c.v, 23),
                TRY_CONVERT(date, c.v, 120),
                TRY_CONVERT(date, c.v, 101),
                TRY_CONVERT(date, c.v, 126),
                TRY_CONVERT(date, c.v))
    FROM (SELECT v = NULLIF(NULLIF(LTRIM(RTRIM(@Value)), N''), N'NULL')) c;
GO

-- Trimmed text, with blank and the literal string "NULL" treated as NULL.
CREATE OR ALTER FUNCTION arwb.tvf_CleanText (@Value nvarchar(max))
RETURNS TABLE
AS
RETURN
    SELECT TextValue = NULLIF(NULLIF(LTRIM(RTRIM(@Value)), N''), N'NULL');
GO

-- Typed setting lookup with a fallback, so a missing AppSetting row never breaks a rule.
CREATE OR ALTER FUNCTION arwb.tvf_Setting (@SettingKey varchar(100), @Fallback nvarchar(400))
RETURNS TABLE
AS
RETURN
    SELECT SettingValue = COALESCE(
                (SELECT TOP (1) s.SettingValue FROM arwb.AppSetting s WHERE s.SettingKey = @SettingKey),
                @Fallback);
GO

PRINT 'AR Workbench 02: parsing helpers ready.';
GO

GO

-- >>>>>>>>>> 03_ArWorkbench_MasterData_Seed.sql >>>>>>>>>>
/* ============================================================================================
   AR Workbench - 03 Master data seed
   Values come from the AR Workbench reference build (docs/Denial_WorkFlow, meta.json).
   Insert-if-missing only: re-running never overwrites an admin's Master File Maintenance edits.
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- Roles and permissions are not seeded here: they live in LRNMaster
-- (see LRNMaster_01_ArWorkbench_Roles_Access.sql).

/* ---------- Business-rule settings -------------------------------------------------------- */
INSERT INTO arwb.AppSetting (SettingKey, SettingValue, Description)
SELECT v.SettingKey, v.SettingValue, v.Description
FROM (VALUES
    ('BalanceEpsilon',          N'0.005',  N'Balances at or below this are treated as zero (absorbs rounding noise).'),
    ('UntouchedDays',           N'45',     N'Assignment Management: unassigned claims untouched this many days surface in Unassigned Claims.'),
    ('RefollowupDays',          N'45',     N'Completed claims whose last follow-up is this old are Re-follow-up Required.'),
    ('NextFollowUpDefaultDays', N'7',      N'Default Next Follow-Up Date offset on the follow-up note.'),
    ('TflDefaultDays',          N'180',    N'Timely-filing limit for a financial class with no arwb.TflThreshold row.'),
    ('TflRiskWindowDays',       N'30',     N'Open claims within this many days of the TFL deadline are flagged TFL-at-risk.'),
    ('PriorityHighAmount',      N'500',    N'Remaining AR at or above this is High priority.'),
    ('PriorityMediumAmount',    N'100',    N'Remaining AR at or above this is Medium priority.'),
    ('CipAttachMaxFiles',       N'3',      N'Maximum attachments on one CIP client response.'),
    ('CipAttachMaxBytes',       N'5242880',N'Maximum size of one CIP attachment in bytes.')
) v (SettingKey, SettingValue, Description)
WHERE NOT EXISTS (SELECT 1 FROM arwb.AppSetting s WHERE s.SettingKey = v.SettingKey);
GO

/* ---------- AR queue taxonomy (parents first, FK on ParentQueueId) ------------------------ */
INSERT INTO arwb.ArQueue (QueueId, ParentQueueId, QueueLabel, IsPriority, SortOrder, BadgeClass)
SELECT v.QueueId, NULL, v.QueueLabel, v.IsPriority, v.SortOrder, v.BadgeClass
FROM (VALUES
    ('submittedqa',  N'Submitted for QA Queue',                   1,  10, 'purple'),
    ('qarejected',   N'QA Rejected Queue',                        1,  20, 'critical'),
    ('cipresponse',  N'CIP Response Received Queue',              1,  30, 'info'),
    ('escalation',   N'Client Escalations Pending Queue',         1,  40, 'warning'),
    ('refollowup',   N'Re-follow-up Required Queue',              1,  50, 'warning'),
    ('denied',       N'Denied Queue',                             1,  60, 'critical'),
    ('partial',      N'Partially Paid and Outstanding AR Queue',  1,  70, 'info'),
    ('partialadj',   N'Partially Adjusted Queue',                 1,  80, 'info'),
    ('nonresponded', N'Non-Responded AR Queue',                   1,  90, 'warning'),
    ('patientar',    N'Patient AR Queue',                         0, 100, 'neutral'),
    ('completed',    N'Completed Claims Queue',                   1, 110, 'good'),
    ('closed',       N'Closed Claims',                            0, 120, 'good')
) v (QueueId, QueueLabel, IsPriority, SortOrder, BadgeClass)
WHERE NOT EXISTS (SELECT 1 FROM arwb.ArQueue q WHERE q.QueueId = v.QueueId);

INSERT INTO arwb.ArQueue (QueueId, ParentQueueId, QueueLabel, IsPriority, SortOrder, BadgeClass)
SELECT v.QueueId, v.ParentQueueId, v.QueueLabel, v.IsPriority, v.SortOrder, NULL
FROM (VALUES
    ('closed_paid',              'closed',       N'Fully Paid and Closed Claims', 0, 121),
    ('closed_adjusted',          'closed',       N'Fully Adjusted',               0, 122),
    ('nonresponded_collectible', 'nonresponded', N'Possible Collectible AR',      1,  91),
    ('denied_collectible',       'denied',       N'Possible Collectible AR',      1,  61),
    ('denied_noncollectible',    'denied',       N'Non-Collectible Denials',      0,  62),
    ('partial_collectible',      'partial',      N'Possible Collectible AR',      1,  71),
    ('partial_noncollectible',   'partial',      N'Non-Collectible Denials',      0,  72),
    ('partialadj_collectible',   'partialadj',   N'Possible Collectible AR',      1,  81)
) v (QueueId, ParentQueueId, QueueLabel, IsPriority, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM arwb.ArQueue q WHERE q.QueueId = v.QueueId);
GO

/* ---------- Chip-list masters ------------------------------------------------------------- */
INSERT INTO arwb.MasterListItem (ListType, ItemValue, SortOrder, CreatedBy)
SELECT v.ListType, v.ItemValue, v.SortOrder, N'seed'
FROM (VALUES
    -- Denial categories
    ('DENIAL_CATEGORY', N'Additional Documentation Required', 1),
    ('DENIAL_CATEGORY', N'Medical Necessity', 2),
    ('DENIAL_CATEGORY', N'Coding-Related Denials', 3),
    ('DENIAL_CATEGORY', N'Eligibility Issues', 4),
    ('DENIAL_CATEGORY', N'Authorization Required', 5),
    ('DENIAL_CATEGORY', N'Timely Filing', 6),
    ('DENIAL_CATEGORY', N'Duplicate Claims', 7),
    ('DENIAL_CATEGORY', N'Payer Processing Issues', 8),
    ('DENIAL_CATEGORY', N'Partially Paid Claims', 9),
    ('DENIAL_CATEGORY', N'Unresponsive Payers', 10),
    ('DENIAL_CATEGORY', N'Other', 99),
    -- Panel types
    ('PANEL_TYPE', N'Toxicology', 1),
    ('PANEL_TYPE', N'UTI Panel', 2),
    ('PANEL_TYPE', N'STI Panel', 3),
    -- Non-collectible denial codes (normalized: no hyphen, no space)
    ('NON_COLLECTIBLE_CODE', N'OA257', 1),
    ('NON_COLLECTIBLE_CODE', N'PR288', 2),
    ('NON_COLLECTIBLE_CODE', N'PR27',  3),
    ('NON_COLLECTIBLE_CODE', N'PR31',  4),
    -- Comments framework
    ('CLAIM_TYPE', N'Primary', 1),
    ('CLAIM_TYPE', N'Secondary', 2),
    ('FOLLOW_UP_TYPE', N'Review', 1),
    ('FOLLOW_UP_TYPE', N'Online', 2),
    ('FOLLOW_UP_TYPE', N'Call', 3),
    ('CLAIM_STATUS', N'Paid', 1),
    ('CLAIM_STATUS', N'Denied', 2),
    ('CLAIM_STATUS', N'Not Received', 3),
    ('CLAIM_STATUS', N'In Process', 4),
    ('CLAIM_STATUS', N'Paid to Patient', 5),
    ('CLAIM_STATUS', N'Patient Responsibility', 6),
    ('CLAIM_STATUS', N'On Hold', 7),
    ('DENIAL_ROOT_CAUSE', N'Additional Documentation/ Information Requests', 1),
    ('DENIAL_ROOT_CAUSE', N'Billing, Rendering or Referring Provider Eligibility Related Issues', 2),
    ('DENIAL_ROOT_CAUSE', N'Bundling', 3),
    ('DENIAL_ROOT_CAUSE', N'Claims Edits Related Issues', 4),
    ('DENIAL_ROOT_CAUSE', N'Coverage, Eligibility or Benefits Related Issues', 5),
    ('DENIAL_ROOT_CAUSE', N'Duplicate Claim Encounter', 6),
    ('DENIAL_ROOT_CAUSE', N'ICD-10 Codes Related Issues', 7),
    ('DENIAL_ROOT_CAUSE', N'Maximum Benefit Reached', 8),
    ('DENIAL_ROOT_CAUSE', N'Medical Necessity or Non Covered Charges Related Issues', 9),
    ('DENIAL_ROOT_CAUSE', N'Missing Prior Authorization', 10),
    ('DENIAL_ROOT_CAUSE', N'Other Denials - Remark or Payer Review Required', 11),
    ('DENIAL_ROOT_CAUSE', N'Previous Payer Processing Information Related Denials', 12),
    ('DENIAL_ROOT_CAUSE', N'Procedure Code, Modifier or Coding Related Issues', 13),
    ('DENIAL_ROOT_CAUSE', N'Provider Out of Network', 14),
    ('DENIAL_ROOT_CAUSE', N'Timely Filling Limits Exceeded', 15),
    ('FIX_RESOLUTION', N'Appealed', 1),
    ('FIX_RESOLUTION', N'Awaiting EOB', 2),
    ('FIX_RESOLUTION', N'Billed to Patient', 3),
    ('FIX_RESOLUTION', N'Billed to Secondary', 4),
    ('FIX_RESOLUTION', N'CIP - Client Escalations', 5),
    ('FIX_RESOLUTION', N'Medical Records Submitted', 6),
    ('FIX_RESOLUTION', N'Paid Posted and Closed', 7),
    ('FIX_RESOLUTION', N'Pending Payer Adjudication', 8),
    ('FIX_RESOLUTION', N'Reconsideration Submitted', 9),
    ('FIX_RESOLUTION', N'Reprocessed', 10),
    ('FIX_RESOLUTION', N'Resubmitted - E', 11),
    ('FIX_RESOLUTION', N'Resubmitted - F', 12),
    ('FIX_RESOLUTION', N'Resubmitted - P', 13),
    ('FIX_RESOLUTION', N'Write Off', 14),
    -- CIP
    ('CIP_CATEGORY', N'DX Codes', 1),
    ('CIP_CATEGORY', N'Insurance', 2),
    ('CIP_CATEGORY', N'Enrollment', 3),
    ('CIP_CATEGORY', N'Documents', 4),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - Chart/ History Notes', 1),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - Requisitions Form', 2),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - Result Sheets', 3),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - Req & Results', 4),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - All', 5),
    ('CIP_REQUIRED_INFO', N'Active Current Insurance info required', 6),
    ('CIP_REQUIRED_INFO', N'Active Alternative Insurance info required', 7),
    ('CIP_REQUIRED_INFO', N'Patient call required', 8),
    ('CIP_REQUIRED_INFO', N'Enrollment Required with the payer', 9),
    ('CIP_REQUIRED_INFO', N'COB Update Requested', 10),
    ('CIP_REQUIRED_INFO', N'Valid ICD-10 Codes Required', 11),
    -- Workflow / aging / financial class
    ('WORKFLOW_STATUS', N'Unassigned', 1),
    ('WORKFLOW_STATUS', N'Assigned', 2),
    ('WORKFLOW_STATUS', N'Submitted for QA', 3),
    ('WORKFLOW_STATUS', N'QA Rejected', 4),
    ('WORKFLOW_STATUS', N'Completed', 5),
    ('AGING_BUCKET', N'0-30 Days', 1),
    ('AGING_BUCKET', N'31-60 Days', 2),
    ('AGING_BUCKET', N'61-90 Days', 3),
    ('AGING_BUCKET', N'91-120 Days', 4),
    ('AGING_BUCKET', N'121-180 Days', 5),
    ('AGING_BUCKET', N'181+ Days', 6),
    ('FINANCIAL_CLASS', N'Commercial', 1),
    ('FINANCIAL_CLASS', N'Medicare', 2),
    ('FINANCIAL_CLASS', N'Medicaid', 3),
    ('FINANCIAL_CLASS', N'Self Pay', 4)
) v (ListType, ItemValue, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM arwb.MasterListItem m WHERE m.ListType = v.ListType AND m.ItemValue = v.ItemValue);
GO

/* ---------- Fix / Resolution by Claim Status --------------------------------------------- */
INSERT INTO arwb.FixResolutionByStatus (ClaimStatus, FixResolution, SortOrder)
SELECT v.ClaimStatus, v.FixResolution, v.SortOrder
FROM (VALUES
    (N'Paid', N'Awaiting EOB', 1), (N'Paid', N'Paid Posted and Closed', 2),
    (N'Denied', N'Appealed', 1), (N'Denied', N'Billed to Patient', 2), (N'Denied', N'Billed to Secondary', 3),
    (N'Denied', N'CIP - Client Escalations', 4), (N'Denied', N'Medical Records Submitted', 5),
    (N'Denied', N'Reconsideration Submitted', 6), (N'Denied', N'Reprocessed', 7), (N'Denied', N'Resubmitted - E', 8),
    (N'Denied', N'Resubmitted - F', 9), (N'Denied', N'Resubmitted - P', 10), (N'Denied', N'Write Off', 11),
    (N'Not Received', N'Resubmitted - E', 1), (N'Not Received', N'Resubmitted - F', 2), (N'Not Received', N'Resubmitted - P', 3),
    (N'In Process', N'Awaiting EOB', 1), (N'In Process', N'Pending Payer Adjudication', 2),
    (N'Paid to Patient', N'Awaiting EOB', 1), (N'Paid to Patient', N'Billed to Patient', 2),
    (N'Patient Responsibility', N'Awaiting EOB', 1), (N'Patient Responsibility', N'Billed to Patient', 2),
    (N'On Hold', N'Appealed', 1), (N'On Hold', N'Medical Records Submitted', 2), (N'On Hold', N'Reconsideration Submitted', 3)
) v (ClaimStatus, FixResolution, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM arwb.FixResolutionByStatus f WHERE f.ClaimStatus = v.ClaimStatus AND f.FixResolution = v.FixResolution);
GO

/* ---------- Workflow templates and stage paths ------------------------------------------- */
INSERT INTO arwb.WorkflowTemplate (TemplateKey, TemplateLabel)
SELECT v.TemplateKey, v.TemplateLabel
FROM (VALUES
    ('doc_required',    N'Additional Documentation / Information Required'),
    ('non_responded',   N'Non-Responded AR'),
    ('coding_edit',     N'Claims Edit / Coding-Related Issues'),
    ('partial_payment', N'Partially Paid Claims'),
    ('denied',          N'Denied Claims')
) v (TemplateKey, TemplateLabel)
WHERE NOT EXISTS (SELECT 1 FROM arwb.WorkflowTemplate t WHERE t.TemplateKey = v.TemplateKey);

INSERT INTO arwb.WorkflowTemplateStage (TemplateKey, StageOrder, StageName)
SELECT v.TemplateKey, v.StageOrder, v.StageName
FROM (VALUES
    ('doc_required', 1, N'Identified'), ('doc_required', 2, N'Assigned'), ('doc_required', 3, N'Documentation Review'),
    ('doc_required', 4, N'Records Requested Internally'), ('doc_required', 5, N'Records Submitted to Payer'),
    ('doc_required', 6, N'Payer Follow-Up'), ('doc_required', 7, N'Payment / Resolution'), ('doc_required', 8, N'QA'), ('doc_required', 9, N'Closed'),

    ('non_responded', 1, N'Identified'), ('non_responded', 2, N'Assigned'), ('non_responded', 3, N'Payer Contact Attempt'),
    ('non_responded', 4, N'Follow-Up Scheduled'), ('non_responded', 5, N'Payer Response Received'),
    ('non_responded', 6, N'Resolution Action'), ('non_responded', 7, N'QA'), ('non_responded', 8, N'Closed'),

    ('coding_edit', 1, N'Identified'), ('coding_edit', 2, N'Assigned'), ('coding_edit', 3, N'Coding Review'),
    ('coding_edit', 4, N'Correction Required'), ('coding_edit', 5, N'Corrected Claim Submitted'),
    ('coding_edit', 6, N'Payer Follow-Up'), ('coding_edit', 7, N'Payment / Resolution'), ('coding_edit', 8, N'QA'), ('coding_edit', 9, N'Closed'),

    ('partial_payment', 1, N'Identified'), ('partial_payment', 2, N'Assigned'), ('partial_payment', 3, N'Payment Variance Review'),
    ('partial_payment', 4, N'Expected Payment Validation'), ('partial_payment', 5, N'Underpayment Follow-Up'),
    ('partial_payment', 6, N'Additional Payment / Adjustment'), ('partial_payment', 7, N'QA'), ('partial_payment', 8, N'Closed'),

    ('denied', 1, N'Identified'), ('denied', 2, N'Assigned'), ('denied', 3, N'Denial Review'),
    ('denied', 4, N'Corrective Action'), ('denied', 5, N'Resubmission / Appeal / Payer Follow-Up'),
    ('denied', 6, N'Payer Decision'), ('denied', 7, N'QA'), ('denied', 8, N'Closed')
) v (TemplateKey, StageOrder, StageName)
WHERE NOT EXISTS (SELECT 1 FROM arwb.WorkflowTemplateStage s WHERE s.TemplateKey = v.TemplateKey AND s.StageOrder = v.StageOrder);

-- Category -> template. Categories with no row fall back to 'denied'.
INSERT INTO arwb.DenialCategoryTemplate (DenialCategory, TemplateKey)
SELECT v.DenialCategory, v.TemplateKey
FROM (VALUES
    (N'Additional Documentation Required', 'doc_required'),
    (N'Coding-Related Denials',            'coding_edit'),
    (N'Partially Paid Claims',             'partial_payment'),
    (N'Unresponsive Payers',               'non_responded'),
    (N'Medical Necessity',                 'denied'),
    (N'Eligibility Issues',                'denied'),
    (N'Authorization Required',            'denied'),
    (N'Timely Filing',                     'denied'),
    (N'Duplicate Claims',                  'denied'),
    (N'Payer Processing Issues',           'denied'),
    (N'Other',                             'denied')
) v (DenialCategory, TemplateKey)
WHERE NOT EXISTS (SELECT 1 FROM arwb.DenialCategoryTemplate d WHERE d.DenialCategory = v.DenialCategory);
GO

/* ---------- Timely-filing thresholds (keys match ClaimLevelData.PayerType values) -------- */
INSERT INTO arwb.TflThreshold (FinancialClass, ThresholdDays)
SELECT v.FinancialClass, v.ThresholdDays
FROM (VALUES
    (N'Commercial', 180), (N'CC - COMMERCIAL', 180),
    (N'Medicare',   365), (N'MC - MEDICARE',   365),
    (N'Medicaid',   365), (N'MD - MEDICAID',   365),
    (N'Self Pay',  9999), (N'SP - SELF PAY',  9999)
) v (FinancialClass, ThresholdDays)
WHERE NOT EXISTS (SELECT 1 FROM arwb.TflThreshold t WHERE t.FinancialClass = v.FinancialClass);
GO

/* ---------- Starter Denial Code -> Category map (standard CARC codes) ---------------------
   STARTER DATA: review with operations before go-live and maintain it in Master File
   Maintenance. Codes not listed here land in category 'Other'.                                */
INSERT INTO arwb.DenialCodeCategoryMap (DenialCode, DenialCategory, CreatedBy)
SELECT v.DenialCode, v.DenialCategory, N'seed'
FROM (VALUES
    (N'CO16',  N'Additional Documentation Required'), (N'CO252', N'Additional Documentation Required'),
    (N'CO226', N'Additional Documentation Required'), (N'PR16',  N'Additional Documentation Required'),
    (N'CO50',  N'Medical Necessity'), (N'CO150', N'Medical Necessity'), (N'CO151', N'Medical Necessity'), (N'CO96', N'Medical Necessity'),
    (N'CO4',   N'Coding-Related Denials'), (N'CO5',   N'Coding-Related Denials'), (N'CO6',   N'Coding-Related Denials'),
    (N'CO11',  N'Coding-Related Denials'), (N'CO97',  N'Coding-Related Denials'), (N'CO234', N'Coding-Related Denials'),
    (N'CO236', N'Coding-Related Denials'), (N'CO167', N'Coding-Related Denials'),
    (N'CO26',  N'Eligibility Issues'), (N'CO27', N'Eligibility Issues'), (N'CO31', N'Eligibility Issues'),
    (N'CO109', N'Eligibility Issues'), (N'CO177', N'Eligibility Issues'), (N'PR27', N'Eligibility Issues'), (N'PR31', N'Eligibility Issues'),
    (N'CO15',  N'Authorization Required'), (N'CO62', N'Authorization Required'), (N'CO197', N'Authorization Required'), (N'CO198', N'Authorization Required'),
    (N'CO29',  N'Timely Filing'),
    (N'CO18',  N'Duplicate Claims'), (N'OA18', N'Duplicate Claims'),
    (N'CO22',  N'Payer Processing Issues'), (N'OA23', N'Payer Processing Issues'), (N'CO24', N'Payer Processing Issues'), (N'CO133', N'Payer Processing Issues'),
    (N'CO45',  N'Partially Paid Claims'), (N'CO94', N'Partially Paid Claims'),
    (N'OA257', N'Other'), (N'PR288', N'Other')
) v (DenialCode, DenialCategory)
WHERE NOT EXISTS (SELECT 1 FROM arwb.DenialCodeCategoryMap m WHERE m.DenialCode = v.DenialCode);
GO

PRINT 'AR Workbench 03: master data seeded.';
GO

GO

-- >>>>>>>>>> 04_ArWorkbench_ClaimState_Procedure.sql >>>>>>>>>>
/* ============================================================================================
   AR Workbench - 04 arwb.usp_RecalculateClaimState

   THE one server-side implementation of the derived claim rules. Screens read the columns this
   procedure writes; they never re-derive a rule in the UI. Call it:
     - after every source refresh            (usp_LoadClaimsFromSource calls it for all claims)
     - after every claim mutation in the API (EXEC arwb.usp_RecalculateClaimState @ClaimKey = @k)
     - nightly, so aging / TFL / re-follow-up due roll forward with the calendar

   Rules (from AR_Workbench_Developer_Documentation.pdf, Business Logic Reference):
     RemainingAR          = InsuranceBalance, or 0 once written off (Automatic Adjustment)
     RecoveredAmount      = InsurancePayment now - InsurancePayment at first identification  (>= 0)
     IsFinanciallyClosed  = RemainingAR <= eps AND PatientBalance <= eps
     IsWorkComplete       = IsFinanciallyClosed OR WorkflowStatus = 'Completed'
     IsOpenInsuranceAR    = RemainingAR > eps          (NOT the opposite of IsWorkComplete - by design)
     IsRefollowupDue      = worked before AND (45+ days since LastFollowUpDate OR NextFollowUpDate lapsed)
     IsNonCollectible     = any of the claim's denial codes is on the NON_COLLECTIBLE_CODE list

   Queue classification - priority ordered, first match wins:
     1 current QA review is 'Awaiting QA'                      -> submittedqa
     2 WorkflowStatus = 'QA Rejected'                          -> qarejected
     3 WorkflowStatus = 'Completed'
         RemainingAR <= eps                                    -> financial state
         open CIP case (status <> Returned to Agent)           -> escalation
         re-follow-up due                                      -> refollowup
         otherwise                                             -> completed
     4 a CIP case came back to the agent WITH a client reply   -> cipresponse
     5 otherwise                                               -> financial state
   Financial state:
     RemainingAR <= eps : PatientBalance > eps -> patientar ; recovered > eps -> closed/closed_paid ; else closed/closed_adjusted
     recovered <= eps AND adjusted <= eps AND category 'Unresponsive Payers' -> nonresponded/nonresponded_collectible
     recovered <= eps AND adjusted > eps  -> partialadj/partialadj_collectible
     recovered > eps                      -> partial/partial_(non)collectible
     otherwise                            -> denied/denied_(non)collectible
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE arwb.usp_RecalculateClaimState
    @ClaimKey       bigint = NULL,      -- one claim (API mutations)
    @RefreshRunId   int    = NULL,      -- only claims touched by this refresh
    @AsOfDate       date   = NULL       -- defaults to today; pass a date to reproduce a past classification
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AsOf date = COALESCE(@AsOfDate, CONVERT(date, SYSDATETIME()));

    DECLARE @Eps            decimal(9,4)  = COALESCE(TRY_CONVERT(decimal(9,4),  (SELECT SettingValue FROM arwb.tvf_Setting('BalanceEpsilon',       N'0.005'))), 0.005);
    DECLARE @RefollowDays   int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM arwb.tvf_Setting('RefollowupDays',       N'45'))),    45);
    DECLARE @TflDefaultDays int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM arwb.tvf_Setting('TflDefaultDays',       N'180'))),   180);
    DECLARE @TflRiskDays    int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM arwb.tvf_Setting('TflRiskWindowDays',    N'30'))),    30);
    DECLARE @HighAmount     decimal(18,2) = COALESCE(TRY_CONVERT(decimal(18,2), (SELECT SettingValue FROM arwb.tvf_Setting('PriorityHighAmount',   N'500'))),   500);
    DECLARE @MediumAmount   decimal(18,2) = COALESCE(TRY_CONVERT(decimal(18,2), (SELECT SettingValue FROM arwb.tvf_Setting('PriorityMediumAmount', N'100'))),   100);

    UPDATE c
    SET
        -- Recovery / AR
        c.RemainingAR         = f.RemainingAR,
        c.RecoveredAmount     = f.RecoveredAmount,
        c.AdjustmentAmount    = f.AdjustmentAmount,
        c.ExpectedPayment     = p.ExpectedPayment,
        c.ActualPayment       = c.InsurancePayment,
        c.PaymentVariance     = p.PaymentVariance,
        c.PaymentPct          = p.PaymentPct,
        c.UnderpaymentAmount  = p.UnderpaymentAmount,
        c.IsAppealRequired    = CASE WHEN p.UnderpaymentAmount > @Eps
                                       OR (q.SubQueueId = 'denied_collectible' AND c.WorkflowStatus <> 'Completed') THEN 1 ELSE 0 END,
        c.RecoveryStatus      = CASE
                                    WHEN c.InitialInsuranceAR <= @Eps              THEN 'Not Applicable'
                                    WHEN f.RecoveredAmount    <= @Eps              THEN 'Not Recovered'
                                    WHEN f.RemainingAR        <= @Eps              THEN 'Fully Recovered'
                                    ELSE 'Partially Recovered'
                                END,
        -- Lifecycle flags
        c.IsFinanciallyClosed = s.IsFinanciallyClosed,
        c.IsWorkComplete      = CASE WHEN s.IsFinanciallyClosed = 1 OR c.WorkflowStatus = 'Completed' THEN 1 ELSE 0 END,
        c.IsOpenInsuranceAR   = CASE WHEN f.RemainingAR > @Eps THEN 1 ELSE 0 END,
        c.IsRefollowupDue     = s.IsRefollowupDue,
        c.IsNonCollectible    = s.IsNonCollectible,
        -- Aging / TFL / priority
        c.AgingDays           = a.AgingDays,
        c.AgingBucket         = a.AgingBucket,
        c.TflDeadline         = t.TflDeadline,
        c.IsTflRisk           = t.IsTflRisk,
        c.Priority            = COALESCE(c.PriorityOverride,
                                    CASE WHEN t.IsTflRisk = 1 OR f.RemainingAR >= @HighAmount THEN 'High'
                                         WHEN f.RemainingAR >= @MediumAmount                 THEN 'Medium'
                                         ELSE 'Low' END),
        -- Queue
        c.ArQueueId           = q.QueueId,
        c.ArSubQueueId        = q.SubQueueId,
        c.IsPriorityQueue     = COALESCE(aq.IsPriority, 0),
        c.LastTouchedOn       = COALESCE(lt.LastTouchedOn, c.LastTouchedOn),
        c.ClassifiedOn        = SYSUTCDATETIME()
    FROM arwb.Claim c
    -- Financial figures
    CROSS APPLY
    (
        SELECT
            RemainingAR      = CASE WHEN c.IsWrittenOff = 1 OR c.InsuranceBalance <= 0 THEN CONVERT(decimal(18,2), 0) ELSE c.InsuranceBalance END,
            RecoveredAmount  = CASE WHEN c.InsurancePayment - c.InitialInsurancePayment > 0
                                    THEN c.InsurancePayment - c.InitialInsurancePayment ELSE CONVERT(decimal(18,2), 0) END,
            -- A write-off not yet posted by the billing system is counted here; once the source
            -- posts it the balance drops to zero and the source adjustment carries it instead.
            AdjustmentAmount = c.InsuranceAdjustments
                               + CASE WHEN c.IsWrittenOff = 1 AND c.InsuranceBalance > 0 THEN c.InsuranceBalance ELSE 0 END
    ) f
    -- Expected vs actual payment
    CROSS APPLY
    (
        SELECT
            ExpectedPayment    = NULLIF(c.AllowedAmount, 0),
            PaymentVariance    = CASE WHEN c.AllowedAmount > 0 THEN c.AllowedAmount - c.InsurancePayment END,
            PaymentPct         = CASE WHEN c.AllowedAmount > 0 THEN CONVERT(decimal(9,4), c.InsurancePayment / c.AllowedAmount) END,
            UnderpaymentAmount = CASE WHEN c.AllowedAmount > 0 AND c.InsurancePayment > @Eps AND c.AllowedAmount - c.InsurancePayment > @Eps
                                      THEN c.AllowedAmount - c.InsurancePayment ELSE CONVERT(decimal(18,2), 0) END
    ) p
    -- State flags read from the workflow tables
    CROSS APPLY
    (
        SELECT
            IsFinanciallyClosed = CASE WHEN f.RemainingAR <= @Eps AND c.PatientBalance <= @Eps THEN 1 ELSE 0 END,
            IsRefollowupDue     = CASE WHEN c.LastFollowUpDate IS NOT NULL
                                        AND (DATEDIFF(day, c.LastFollowUpDate, @AsOf) >= @RefollowDays
                                             OR (c.NextFollowUpDate IS NOT NULL AND c.NextFollowUpDate <= @AsOf))
                                       THEN 1 ELSE 0 END,
            IsNonCollectible    = CASE WHEN EXISTS (SELECT 1 FROM arwb.MasterListItem m
                                                    WHERE m.ListType = 'NON_COLLECTIBLE_CODE' AND m.IsActive = 1
                                                      AND c.DenialCodesNormalized LIKE N'%,' + m.ItemValue + N',%')
                                       THEN 1 ELSE 0 END,
            IsAwaitingQa        = CASE WHEN EXISTS (SELECT 1 FROM arwb.ClaimQaReview r
                                                    WHERE r.ClaimKey = c.ClaimKey AND r.IsCurrent = 1 AND r.ReviewStatus = 'Awaiting QA')
                                       THEN 1 ELSE 0 END,
            HasActiveCip        = CASE WHEN EXISTS (SELECT 1 FROM arwb.CipCase cc
                                                    WHERE cc.ClaimKey = c.ClaimKey AND cc.CaseStatus <> 'Returned to Agent')
                                       THEN 1 ELSE 0 END,
            HasReturnedCipReply = CASE WHEN EXISTS (SELECT 1 FROM arwb.CipCase cc
                                                    WHERE cc.ClaimKey = c.ClaimKey AND cc.CaseStatus = 'Returned to Agent'
                                                      AND cc.ClientRespondedOn IS NOT NULL)
                                       THEN 1 ELSE 0 END
    ) s
    -- Financial-state fallback bucket
    CROSS APPLY
    (
        SELECT
            FinQueue = CASE
                WHEN f.RemainingAR <= @Eps THEN CASE WHEN c.PatientBalance > @Eps THEN 'patientar' ELSE 'closed' END
                WHEN f.RecoveredAmount <= @Eps AND f.AdjustmentAmount <= @Eps AND c.DenialCategory = N'Unresponsive Payers' THEN 'nonresponded'
                WHEN f.RecoveredAmount <= @Eps AND f.AdjustmentAmount >  @Eps THEN 'partialadj'
                WHEN f.RecoveredAmount >  @Eps THEN 'partial'
                ELSE 'denied' END,
            FinSubQueue = CASE
                WHEN f.RemainingAR <= @Eps THEN CASE WHEN c.PatientBalance > @Eps THEN NULL
                                                     WHEN f.RecoveredAmount > @Eps THEN 'closed_paid'
                                                     ELSE 'closed_adjusted' END
                WHEN f.RecoveredAmount <= @Eps AND f.AdjustmentAmount <= @Eps AND c.DenialCategory = N'Unresponsive Payers' THEN 'nonresponded_collectible'
                WHEN f.RecoveredAmount <= @Eps AND f.AdjustmentAmount >  @Eps THEN 'partialadj_collectible'
                WHEN f.RecoveredAmount >  @Eps THEN CASE WHEN s.IsNonCollectible = 1 THEN 'partial_noncollectible' ELSE 'partial_collectible' END
                ELSE CASE WHEN s.IsNonCollectible = 1 THEN 'denied_noncollectible' ELSE 'denied_collectible' END END
    ) fin
    -- Priority-ordered classification
    CROSS APPLY
    (
        SELECT
            QueueId = CASE
                WHEN s.IsAwaitingQa = 1                 THEN 'submittedqa'
                WHEN c.WorkflowStatus = 'QA Rejected'   THEN 'qarejected'
                WHEN c.WorkflowStatus = 'Completed' THEN
                    CASE WHEN f.RemainingAR <= @Eps     THEN fin.FinQueue
                         WHEN s.HasActiveCip = 1        THEN 'escalation'
                         WHEN s.IsRefollowupDue = 1     THEN 'refollowup'
                         ELSE 'completed' END
                WHEN s.HasReturnedCipReply = 1          THEN 'cipresponse'
                ELSE fin.FinQueue END,
            SubQueueId = CASE
                WHEN s.IsAwaitingQa = 1                 THEN NULL
                WHEN c.WorkflowStatus = 'QA Rejected'   THEN NULL
                WHEN c.WorkflowStatus = 'Completed' THEN
                    CASE WHEN f.RemainingAR <= @Eps     THEN fin.FinSubQueue ELSE NULL END
                WHEN s.HasReturnedCipReply = 1          THEN NULL
                ELSE fin.FinSubQueue END
    ) q
    LEFT JOIN arwb.ArQueue aq ON aq.QueueId = COALESCE(q.SubQueueId, q.QueueId)
    -- Aging from date of service
    CROSS APPLY
    (
        SELECT AgingDays = DATEDIFF(day, c.DateOfService, @AsOf)
    ) a0
    CROSS APPLY
    (
        SELECT
            AgingDays   = a0.AgingDays,
            AgingBucket = CASE
                WHEN a0.AgingDays IS NULL THEN NULL
                WHEN a0.AgingDays <= 30   THEN N'0-30 Days'
                WHEN a0.AgingDays <= 60   THEN N'31-60 Days'
                WHEN a0.AgingDays <= 90   THEN N'61-90 Days'
                WHEN a0.AgingDays <= 120  THEN N'91-120 Days'
                WHEN a0.AgingDays <= 180  THEN N'121-180 Days'
                ELSE N'181+ Days' END
    ) a
    -- Timely filing
    OUTER APPLY
    (
        SELECT TOP (1) th.ThresholdDays FROM arwb.TflThreshold th WHERE th.FinancialClass = c.PayerType
    ) tf
    CROSS APPLY
    (
        SELECT
            TflDeadline = DATEADD(day, COALESCE(tf.ThresholdDays, @TflDefaultDays), c.DateOfService),
            IsTflRisk   = CASE WHEN c.DateOfService IS NOT NULL
                                AND f.RemainingAR > @Eps
                                AND DATEDIFF(day, @AsOf, DATEADD(day, COALESCE(tf.ThresholdDays, @TflDefaultDays), c.DateOfService)) <= @TflRiskDays
                               THEN 1 ELSE 0 END
    ) t
    -- Days since last touch reads the activity log (every claim has the "Claim Identified" entry)
    OUTER APPLY
    (
        SELECT LastTouchedOn = MAX(ca.ActivityOn) FROM arwb.ClaimActivity ca WHERE ca.ClaimKey = c.ClaimKey
    ) lt
    WHERE (@ClaimKey     IS NULL OR c.ClaimKey         = @ClaimKey)
      AND (@RefreshRunId IS NULL OR c.LastRefreshRunId = @RefreshRunId)
    OPTION (RECOMPILE);

    SELECT UpdatedClaims = @@ROWCOUNT;
END;
GO

PRINT 'AR Workbench 04: arwb.usp_RecalculateClaimState ready.';
GO

GO

-- >>>>>>>>>> 05_ArWorkbench_LoadFromSource_Procedure.sql >>>>>>>>>>
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

GO

-- >>>>>>>>>> 06_ArWorkbench_Views.sql >>>>>>>>>>
/* ============================================================================================
   AR Workbench - 06 Views
   arwb.vw_ClaimWorklist is the one read shape every queue screen uses: the claim, its queue labels,
   days since last touch, and the live QA / CIP / agent-request state.
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW arwb.vw_ClaimWorklist
AS
SELECT
    c.ClaimKey,
    c.ClaimID,
    c.LabId,
    c.LabName,
    c.AccessionNumber,
    c.PatientID,
    c.PatientName,
    c.PayerName,
    c.PayerType,
    c.ClaimType,
    c.BillingProvider,
    c.ReferringProvider,
    c.ClinicName,
    c.PanelName,
    c.PanelType,
    c.DateOfService,
    c.FirstBilledDate,
    c.CheckDate,
    c.SourceClaimStatus,
    c.DenialCode,
    c.DenialDate,
    c.DenialCategory,
    c.DenialReason,
    c.DenialRootCause,
    c.ChargeAmount,
    c.AllowedAmount,
    c.InsurancePayment,
    c.PatientPayment,
    c.InsuranceAdjustments,
    c.InsuranceBalance,
    c.PatientBalance,
    c.TotalBalance,
    c.InitialInsuranceAR,
    c.RecoveredAmount,
    c.RemainingAR,
    c.AdjustmentAmount,
    c.ExpectedPayment,
    c.PaymentVariance,
    c.UnderpaymentAmount,
    c.IsAppealRequired,
    c.RecoveryStatus,
    c.WorkflowStatus,
    c.WorkflowTemplateKey,
    c.Priority,
    c.AssignedAgentUser,                                -- dbo.LabUsers.UserName in LRNMaster; the API resolves the display name
    c.AssignedOn,
    c.AssignmentBatchId,
    c.LastFollowUpDate,
    c.NextFollowUpDate,
    c.WorkedStatus,
    c.FixResolution,
    c.AgingDays,
    c.AgingBucket,
    c.TflDeadline,
    c.IsTflRisk,
    c.IsNonCollectible,
    c.IsFinanciallyClosed,
    c.IsWorkComplete,
    c.IsOpenInsuranceAR,
    c.IsRefollowupDue,
    c.IsWrittenOff,
    c.ArQueueId,
    q.QueueLabel                                        AS ArQueueLabel,
    q.BadgeClass                                        AS ArQueueBadgeClass,
    c.ArSubQueueId,
    sq.QueueLabel                                       AS ArSubQueueLabel,
    c.IsPriorityQueue,
    c.LastTouchedOn,
    DATEDIFF(day, c.LastTouchedOn, SYSUTCDATETIME())    AS DaysSinceLastTouch,
    c.IsInCurrentSource,
    c.FirstIdentifiedOn,
    c.LastRefreshedOn,
    qa.ReviewStatus                                     AS QaStatus,
    qa.IsEscalation                                     AS QaIsEscalation,
    qa.SubmittedBy                                      AS QaSubmittedBy,
    qa.SubmittedOn                                      AS QaSubmittedOn,
    ISNULL(cip.OpenCipCases, 0)                         AS OpenCipCases,
    ISNULL(req.PendingAgentRequests, 0)                 AS PendingAgentRequests,
    c.RowVer
FROM arwb.Claim c
LEFT JOIN arwb.ArQueue q      ON q.QueueId  = c.ArQueueId
LEFT JOIN arwb.ArQueue sq     ON sq.QueueId = c.ArSubQueueId
LEFT JOIN arwb.ClaimQaReview qa ON qa.ClaimKey = c.ClaimKey AND qa.IsCurrent = 1
OUTER APPLY (SELECT OpenCipCases = COUNT(*) FROM arwb.CipCase x WHERE x.ClaimKey = c.ClaimKey AND x.CaseStatus <> 'Returned to Agent') cip
OUTER APPLY (SELECT PendingAgentRequests = COUNT(*) FROM arwb.AgentRequest x WHERE x.ClaimKey = c.ClaimKey AND x.RequestStatus = 'Pending') req;
GO

PRINT 'AR Workbench 06: views ready.';
GO

GO


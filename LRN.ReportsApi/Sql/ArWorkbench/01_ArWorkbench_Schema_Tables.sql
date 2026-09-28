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

/* AUTO-GENERATED FROM LIVE NORTHWEST DATABASE: NWL_LRN
   Explicit destructive drop/create script for all Denial Workflow tables.
   Run in SQLCMD mode and provide TargetDatabase and AllowDestructiveReset. */
:setvar TargetDatabase "REPLACE_WITH_TARGET_DATABASE"
:setvar AllowDestructiveReset "NO"
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF N'$(AllowDestructiveReset)'<>N'YES' THROW 51000,'Set AllowDestructiveReset=YES after backing up the target database.',1;
IF N'$(TargetDatabase)' IN(N'',N'REPLACE_WITH_TARGET_DATABASE',N'master',N'model',N'msdb',N'tempdb',N'NWL_LRN') THROW 51001,'Invalid target database.',1;
IF DB_ID(N'$(TargetDatabase)') IS NULL THROW 51002,'Target database does not exist.',1;
GO
USE [$(TargetDatabase)];
GO
BEGIN TRANSACTION;
DECLARE @DropFks nvarchar(max)=N'';
SELECT @DropFks=@DropFks+N'ALTER TABLE '+QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id))+N'.'+QUOTENAME(OBJECT_NAME(parent_object_id))+N' DROP CONSTRAINT '+QUOTENAME(name)+N';' FROM sys.foreign_keys WHERE OBJECT_NAME(parent_object_id) LIKE N'Denial%' OR OBJECT_NAME(referenced_object_id) LIKE N'Denial%';
IF @DropFks<>N'' EXEC sys.sp_executesql @DropFks;
DROP TABLE IF EXISTS dbo.[DenialVerificationTask];
DROP TABLE IF EXISTS dbo.[DenialVerification];
DROP TABLE IF EXISTS dbo.[DenialTaskHistory];
DROP TABLE IF EXISTS dbo.[DenialTaskBoard];
DROP TABLE IF EXISTS dbo.[DenialStatusMaster];
DROP TABLE IF EXISTS dbo.[DenialMapperSuperMaster];
DROP TABLE IF EXISTS dbo.[DenialMapperPushAuditDetail];
DROP TABLE IF EXISTS dbo.[DenialMapperPushAudit];
DROP TABLE IF EXISTS dbo.[DenialMapperLabOverride];
DROP TABLE IF EXISTS dbo.[DenialMapperLabMaster];
DROP TABLE IF EXISTS dbo.[DenialMapperAuditLog];
DROP TABLE IF EXISTS dbo.[DenialLineItem];
DROP TABLE IF EXISTS dbo.[DenialInsight];
DROP TABLE IF EXISTS dbo.[DenialCodeStaging];
DROP TABLE IF EXISTS dbo.[DenialCodeMaster];
DROP TABLE IF EXISTS dbo.[DenialCodeMapper];
DROP TABLE IF EXISTS dbo.[DenialCodeActionChangeVerification];
DROP TABLE IF EXISTS dbo.[DenialCodeActionChangeBatch];
DROP TABLE IF EXISTS dbo.[DenialClosedClaimsHistory];
DROP TABLE IF EXISTS dbo.[DenialClosedClaims];
DROP TABLE IF EXISTS dbo.[DenialClaimNotes];
DROP TABLE IF EXISTS dbo.[DenialClaimEscalations];
DROP TABLE IF EXISTS dbo.[DenialClaimDocuments];
DROP TABLE IF EXISTS dbo.[DenialAnalysisRunLog];
DROP TABLE IF EXISTS dbo.[DenialActionCategoryMaster];
COMMIT;
GO
CREATE TABLE dbo.[DenialActionCategoryMaster]
(
    [ActionCategoryId] int IDENTITY(1,1) NOT NULL,
    [ActionCategory] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ActionScope] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL CONSTRAINT [DF_DenialActionCategoryMaster_ActionScope] DEFAULT (N'CPTLevel'),
    [IsActive] bit NOT NULL CONSTRAINT [DF_DenialActionCategoryMaster_IsActive] DEFAULT ((1)),
    [CreatedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DenialActionCategoryMaster_CreatedOn] DEFAULT (sysutcdatetime()),
    CONSTRAINT [PK_DenialActionCategoryMaster] PRIMARY KEY CLUSTERED ([ActionCategoryId] ASC),
    CONSTRAINT [UQ_DenialActionCategoryMaster_ActionCategory] UNIQUE NONCLUSTERED ([ActionCategory] ASC)
);
GO
CREATE TABLE dbo.[DenialAnalysisRunLog]
(
    [RunId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabId] int NULL,
    [OutputFileName] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CreatedOn] datetime2(0) NULL
);
GO
CREATE TABLE dbo.[DenialClaimDocuments]
(
    [DocumentId] bigint IDENTITY(1,1) NOT NULL,
    [LabId] int NOT NULL,
    [ClaimId] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [OriginalFileName] nvarchar(260) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [StoredFileName] nvarchar(260) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ContentType] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [FileSizeBytes] bigint NOT NULL,
    [FilePath] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [Comment] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [UploadedBy] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [UploadedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DenialClaimDocuments_UploadedOn] DEFAULT (sysutcdatetime()),
    [IsDeleted] bit NOT NULL CONSTRAINT [DF_DenialClaimDocuments_IsDeleted] DEFAULT ((0)),
    CONSTRAINT [PK_DenialClaimDocuments] PRIMARY KEY CLUSTERED ([DocumentId] ASC)
);
GO
CREATE TABLE dbo.[DenialClaimEscalations]
(
    [EscalationId] bigint IDENTITY(1,1) NOT NULL,
    [LabId] int NOT NULL,
    [ClaimId] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [TaskId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CptCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [EscalationLevel] nvarchar(20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [EscalationReason] nvarchar(300) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [Comments] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Status] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL CONSTRAINT [DF_DenialClaimEscalations_Status] DEFAULT ('Open'),
    [CreatedBy] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [CreatedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DenialClaimEscalations_CreatedOn] DEFAULT (sysutcdatetime()),
    [IsDeleted] bit NOT NULL CONSTRAINT [DF_DenialClaimEscalations_IsDeleted] DEFAULT ((0)),
    [EscalatedTo] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [EscalatedToRole] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NextFollowUpDate] date NULL,
    CONSTRAINT [PK_DenialClaimEscalations] PRIMARY KEY CLUSTERED ([EscalationId] ASC)
);
GO
CREATE TABLE dbo.[DenialClaimNotes]
(
    [NoteId] bigint IDENTITY(1,1) NOT NULL,
    [LabId] int NOT NULL,
    [ClaimId] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [TaskId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CptCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NoteLevel] nvarchar(20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [NoteText] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [CreatedBy] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [CreatedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DenialClaimNotes_CreatedOn] DEFAULT (sysutcdatetime()),
    [IsDeleted] bit NOT NULL CONSTRAINT [DF_DenialClaimNotes_IsDeleted] DEFAULT ((0)),
    [Status] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NextFollowUpDate] date NULL,
    CONSTRAINT [PK_DenialClaimNotes] PRIMARY KEY CLUSTERED ([NoteId] ASC)
);
GO
CREATE TABLE dbo.[DenialClosedClaims]
(
    [ClosedClaimId] bigint IDENTITY(1,1) NOT NULL,
    [LabId] int NOT NULL,
    [ClaimId] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [PayerName] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PanelName] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatientName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatientDOB] date NULL,
    [PatientId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SubscriberId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClinicName] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SalesRepname] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ReferringProvider] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DateOfService] date NULL,
    [AssignedTo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Status] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL CONSTRAINT [DF_DenialClosedClaims_Status] DEFAULT ('Closed'),
    [WorkFlowStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL CONSTRAINT [DF_DenialClosedClaims_WorkFlowStatus] DEFAULT ('Closed Claim'),
    [TaskCount] int NOT NULL CONSTRAINT [DF_DenialClosedClaims_TaskCount] DEFAULT ((0)),
    [InsuranceBalance] decimal(18,2) NOT NULL CONSTRAINT [DF_DenialClosedClaims_InsuranceBalance] DEFAULT ((0)),
    [ClosedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DenialClosedClaims_ClosedOn] DEFAULT (sysutcdatetime()),
    [ClosedBy] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LastUpdatedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DenialClosedClaims_LastUpdatedOn] DEFAULT (sysutcdatetime()),
    CONSTRAINT [PK_DenialClosedClaims] PRIMARY KEY CLUSTERED ([ClosedClaimId] ASC)
);
GO
CREATE TABLE dbo.[DenialClosedClaimsHistory]
(
    [HistoryId] bigint IDENTITY(1,1) NOT NULL,
    [ClosedClaimId] bigint NULL,
    [LabId] int NOT NULL,
    [ClaimId] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ActionType] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [OldWorkFlowStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewWorkFlowStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [OldAssignedTo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewAssignedTo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Comments] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionBy] nvarchar(256) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionDate] datetime2(0) NOT NULL CONSTRAINT [DF_DenialClosedClaimsHistory_ActionDate] DEFAULT (sysutcdatetime()),
    CONSTRAINT [PK_DenialClosedClaimsHistory] PRIMARY KEY CLUSTERED ([HistoryId] ASC)
);
GO
CREATE TABLE dbo.[DenialCodeActionChangeBatch]
(
    [BatchId] bigint IDENTITY(1,1) NOT NULL,
    [SourceFileName] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [UploadedBy] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [UploadedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DCACB_UploadedOn] DEFAULT (sysutcdatetime()),
    [TotalAffectedClaims] int NOT NULL CONSTRAINT [DF_DCACB_TotalAffectedClaims] DEFAULT ((0)),
    [TotalAffectedTasks] int NOT NULL CONSTRAINT [DF_DCACB_TotalAffectedTasks] DEFAULT ((0)),
    [PendingCount] int NOT NULL CONSTRAINT [DF_DCACB_PendingCount] DEFAULT ((0)),
    [ConfirmedCount] int NOT NULL CONSTRAINT [DF_DCACB_ConfirmedCount] DEFAULT ((0)),
    [IgnoredCount] int NOT NULL CONSTRAINT [DF_DCACB_IgnoredCount] DEFAULT ((0)),
    [Status] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL CONSTRAINT [DF_DCACB_Status] DEFAULT ('Pending'),
    CONSTRAINT [PK_DenialCodeActionChangeBatch] PRIMARY KEY CLUSTERED ([BatchId] ASC)
);
GO
CREATE TABLE dbo.[DenialCodeActionChangeVerification]
(
    [VerificationId] bigint IDENTITY(1,1) NOT NULL,
    [BatchId] bigint NOT NULL,
    [ClaimID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [TaskID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatientId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PayerName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [AssignedTo] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClaimStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ICDComplianceStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoverageStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [OldActionCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewActionCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [OldActionCategory] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewActionCategory] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [OldTask] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewTask] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [OldShortCategory] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewShortCategory] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [VerificationStatus] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL CONSTRAINT [DF_DCACV_VerificationStatus] DEFAULT ('Pending'),
    [VerifiedBy] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [VerifiedOn] datetime2(0) NULL,
    [CreatedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DCACV_CreatedOn] DEFAULT (sysutcdatetime()),
    [CPTCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Units] int NULL,
    [Modifier] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialDescription] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialClassification] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCategory] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RecommendedAction] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Task] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Priority] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [InsuranceBalance] decimal(18,2) NULL,
    [SLADays] int NULL,
    [Status] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DateOpened] date NULL,
    [DueDate] date NULL,
    [SLAStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [FirstBilledDate] date NULL,
    [ChargeEnteredDate] date NULL,
    [DenialValidity] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    CONSTRAINT [PK_DenialCodeActionChangeVerification] PRIMARY KEY CLUSTERED ([VerificationId] ASC)
);
GO
CREATE TABLE dbo.[DenialCodeMapper]
(
    [DenialCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [DenialDescription] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ReplacementDescrp] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialComment] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionComment] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CreatedOn] datetime NULL CONSTRAINT [DF__DenialCod__Creat__6EF57B66] DEFAULT (getdate()),
    [UpdatedOn] datetime NULL,
    [DenialCodePrefix] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    CONSTRAINT [PK__DenialCo__9773E095EDEB5F40] PRIMARY KEY CLUSTERED ([DenialCode] ASC)
);
GO
CREATE TABLE dbo.[DenialCodeMaster]
(
    [DenialCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [DenialDescription] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialClassification] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoverageStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ICDComplianceStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [DenialValidity] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RecommendedAction] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCategory] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Task] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ShortCategory] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Priority] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SLADays] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NotesComments] nvarchar(2000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CreatedOn] datetime2(7) NOT NULL CONSTRAINT [DF_DenialCodeMaster_CreatedOn] DEFAULT (sysutcdatetime()),
    [CreatedBy] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [UpdatedOn] datetime2(7) NULL,
    [UpdatedBy] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    CONSTRAINT [PK_DenialCodeMaster] PRIMARY KEY CLUSTERED ([DenialCode] ASC,[CoverageStatus] ASC,[ICDComplianceStatus] ASC)
);
GO
CREATE TABLE dbo.[DenialCodeStaging]
(
    [DenialCodeMaperId] bigint IDENTITY(1,1) NOT NULL,
    [DenialCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialDescription] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ReplacementDecription] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialComment] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionComment] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ImportedFileID] int NULL,
    [ImportedOn] datetime NULL CONSTRAINT [DF__DenialCod__Impor__6FE99F9F] DEFAULT (getdate()),
    CONSTRAINT [PK__DenialCo__909E96DDD9314CFA] PRIMARY KEY CLUSTERED ([DenialCodeMaperId] ASC)
);
GO
CREATE TABLE dbo.[DenialInsight]
(
    [DenialCodes] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Descriptions] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NoOfDenialCount] int NULL,
    [NoOfClaimsCount] int NULL,
    [TotalBalance] decimal(18,2) NULL,
    [HighImpactInsurance] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [InsuranceBalance] decimal(18,2) NULL,
    [ImpactPercentage] decimal(18,2) NULL,
    [ActionCategory] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCode] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Action] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Task] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Feedback] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Responsibility] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DiscussionDate] date NULL,
    [ETA] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabId] int NULL,
    [RunId] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CreatedOn] datetime NULL CONSTRAINT [DF__DenialIns__Creat__70DDC3D8] DEFAULT (getdate()),
    [AssignedTo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ResponsibilityReviewer] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
);
GO
CREATE TABLE dbo.[DenialLineItem]
(
    [AccessionNo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [VisitNumber] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CPTCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatientDOB] date NULL,
    [PayerCode] int NULL,
    [PayerName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PayerNameNormalized] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PayStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [HistoricalPayment] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [HistoricalPaidLineItemCount] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [HistoricalPaymentConfidenceScore] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [TotalLineItemCount] int NULL,
    [PaidLineItemCount] int NULL,
    [PaidLineItemCountPercent] decimal(18,4) NULL,
    [PayerType] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PayerFoundInPolicy] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DateOfService] date NULL,
    [FirstBilledDate] date NULL,
    [PanelName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LISICD10Codes] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CCWICD10Code] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Units] int NULL,
    [Modifier] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialCodeOriginal] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialCodeNormalized] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialDescription] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [BilledAmount] decimal(18,4) NULL,
    [AllowedAmount] decimal(18,4) NULL,
    [InsurancePayment] decimal(18,4) NULL,
    [InsuranceAdjustment] decimal(18,4) NULL,
    [PatientPaidAmount] decimal(18,4) NULL,
    [PatientAdjustment] decimal(18,4) NULL,
    [InsuranceBalance] decimal(18,4) NULL,
    [PatientBalance] decimal(18,4) NULL,
    [TotalBalance] decimal(18,4) NULL,
    [MedicareFee] decimal(18,4) NULL,
    [FinalClaimStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoveredICD10CodesBilled] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NonCoveredICD10CodesBilled] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [BilledICDCodesNotAvailableInPayerPolicy] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoverageStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [FinalCoverageStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoveredICD10CodesAsPerPayerPolicy] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NonCoveredICD10CodesAsPerPayerPolicy] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionComment] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Resolution] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CodingValidation] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CodingValidationSubStatus] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ICDComplianceStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ICDComplianceSubstatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ICDPrimaryIndicatorAvailable] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoveredICDPresence] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ICDValidationConfidence] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [FrequencyConditionMet] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [GenderConditionMet] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Payability] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ForecastingPayability] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PolicyCoverageExpectation] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialValidity] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoverageExpectationRemarks] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ExpectedAverageAllowedAmount] decimal(18,4) NULL,
    [ExpectedAverageInsurancePayment] decimal(18,4) NULL,
    [ExpectedAllowedAmountSameLab] decimal(18,4) NULL,
    [ExpectedInsurancePaymentSameLab] decimal(18,4) NULL,
    [ModeAllowedAmountSameLab] decimal(18,4) NULL,
    [ModeInsurancePaidSameLab] decimal(18,4) NULL,
    [ModeAllowedAmountPeer] decimal(18,4) NULL,
    [ModeInsurancePaidPeer] decimal(18,4) NULL,
    [MedianAllowedAmountSameLab] decimal(18,4) NULL,
    [MedianInsurancePaidSameLab] decimal(18,4) NULL,
    [MedianAllowedAmountPeer] decimal(18,4) NULL,
    [MedianInsurancePaidPeer] decimal(18,4) NULL,
    [ModeAllowedAmountDifference] decimal(18,4) NULL,
    [ModeInsurancePaidDifference] decimal(18,4) NULL,
    [MedianAllowedAmountDifference] decimal(18,4) NULL,
    [MedianInsurancePaidDifference] decimal(18,4) NULL,
    [DenialRate] decimal(18,4) NULL,
    [AdjustmentRate] decimal(18,4) NULL,
    [PaymentDays] int NULL,
    [ExpectedPaymentDate] date NULL,
    [ExpectedPaymentMonth] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [BillingProvider] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ReferringProvider] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClinicName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SalesRepname] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatientID] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ChargeEnteredDate] date NULL,
    [POS] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [TOS] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CheckDate] date NULL,
    [DaystoDOS] int NULL,
    [RollingDays] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DaystoBill] int NULL,
    [DaystoPost] int NULL,
    [DenialClassification] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialType] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCategory] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCode] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RecommendedAction] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [TaskGuidance] nvarchar(1500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [TaskStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ShortCategory] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Priority] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SLADays] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NotesComments] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabId] int NULL,
    [RunId] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CreatedOn] datetime NULL CONSTRAINT [DF__DenialLin__Creat__71D1E811] DEFAULT (getdate()),
    [DenialDate] date NULL,
    [PatientName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClaimUID] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [AssignedTo] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [WorkFlowStatus] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClaimFrom] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Source] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatName] nvarchar(250) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SubscriberId] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
);
GO
CREATE TABLE dbo.[DenialMapperAuditLog]
(
    [Id] bigint IDENTITY(1,1) NOT NULL,
    [EventType] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [LabId] int NULL,
    [SuperMasterId] bigint NULL,
    [DenialCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [FieldName] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [FromValue] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ToValue] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PerformedBy] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [PerformedRole] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [PerformedOn] datetime2(7) NOT NULL CONSTRAINT [DF__DenialMap__Perfo__38B96646] DEFAULT (sysutcdatetime()),
    [Remarks] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    CONSTRAINT [PK__DenialMa__3214EC07DCBCDB8B] PRIMARY KEY CLUSTERED ([Id] ASC)
);
GO
CREATE TABLE dbo.[DenialMapperLabMaster]
(
    [Id] bigint IDENTITY(1,1) NOT NULL,
    [LabId] int NOT NULL,
    [SuperMasterId] bigint NOT NULL,
    [IsActive] bit NOT NULL CONSTRAINT [DF__DenialMap__IsAct__2D47B39A] DEFAULT ((1)),
    [PushedBy] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [PushedOn] datetime2(7) NOT NULL CONSTRAINT [DF__DenialMap__Pushe__2E3BD7D3] DEFAULT (sysutcdatetime()),
    [CreatedBy] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [CreatedOn] datetime2(7) NOT NULL CONSTRAINT [DF__DenialMap__Creat__2F2FFC0C] DEFAULT (sysutcdatetime()),
    [ModifiedBy] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ModifiedOn] datetime2(7) NOT NULL CONSTRAINT [DF__DenialMap__Modif__30242045] DEFAULT (sysutcdatetime()),
    [DenialCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialDescription] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialClassification] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoverageStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ICDComplianceStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialValidity] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCategory] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Task] nvarchar(300) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RecommendedAction] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SLA] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Priority] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    CONSTRAINT [PK__DenialMa__3214EC072B61FB81] PRIMARY KEY CLUSTERED ([Id] ASC),
    CONSTRAINT [UQ_DenialMapperLabMaster] UNIQUE NONCLUSTERED ([LabId] ASC,[SuperMasterId] ASC)
);
GO
CREATE TABLE dbo.[DenialMapperLabOverride]
(
    [Id] bigint IDENTITY(1,1) NOT NULL,
    [LabId] int NOT NULL,
    [SuperMasterId] bigint NOT NULL,
    [ActionCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ActionCategory] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [Task] nvarchar(300) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [RecommendedAction] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [IsActive] bit NOT NULL CONSTRAINT [DF__DenialMap__IsAct__33F4B129] DEFAULT ((1)),
    [CreatedBy] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [CreatedOn] datetime2(7) NOT NULL CONSTRAINT [DF__DenialMap__Creat__34E8D562] DEFAULT (sysutcdatetime()),
    [ModifiedBy] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ModifiedOn] datetime2(7) NOT NULL CONSTRAINT [DF__DenialMap__Modif__35DCF99B] DEFAULT (sysutcdatetime()),
    CONSTRAINT [PK__DenialMa__3214EC07BF2F7356] PRIMARY KEY CLUSTERED ([Id] ASC)
);
GO
CREATE TABLE dbo.[DenialMapperPushAudit]
(
    [PushAuditId] bigint IDENTITY(1,1) NOT NULL,
    [SourceLabId] int NOT NULL,
    [TargetLabId] int NOT NULL,
    [PushedByUserId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [PushStatus] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [TotalCompared] int NOT NULL CONSTRAINT [DF_DMPA_TotalCompared] DEFAULT ((0)),
    [TotalDifferences] int NOT NULL CONSTRAINT [DF_DMPA_TotalDifferences] DEFAULT ((0)),
    [TotalAssignedOpenTasksAffected] int NOT NULL CONSTRAINT [DF_DMPA_OpenTasks] DEFAULT ((0)),
    [CreatedOn] datetime2(7) NOT NULL CONSTRAINT [DF_DMPA_CreatedOn] DEFAULT (sysutcdatetime()),
    [ConfirmedOn] datetime2(7) NULL,
    [ConfirmedByUserId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CancelledOn] datetime2(7) NULL,
    [CancelledByUserId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [AcknowledgedOn] datetime2(7) NULL,
    [AcknowledgedByUserId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [FailureMessage] nvarchar(2000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    CONSTRAINT [PK_DenialMapperPushAudit] PRIMARY KEY CLUSTERED ([PushAuditId] ASC)
);
GO
CREATE TABLE dbo.[DenialMapperPushAuditDetail]
(
    [PushAuditDetailId] bigint IDENTITY(1,1) NOT NULL,
    [PushAuditId] bigint NOT NULL,
    [TargetLabId] int NOT NULL,
    [DenialCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ICDComplianceStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoverageStatus] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ExistingActionCode] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewActionCode] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ExistingActionCategory] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewActionCategory] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ExistingTask] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewTask] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ExistingShortCategory] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewShortCategory] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ExistingDenialClassification] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewDenialClassification] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DifferenceType] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [IsAssignedToOpenTask] bit NOT NULL CONSTRAINT [DF_DMPAD_Open] DEFAULT ((0)),
    [OpenAssignedTaskCount] int NOT NULL CONSTRAINT [DF_DMPAD_OpenCount] DEFAULT ((0)),
    [CreatedOn] datetime2(7) NOT NULL CONSTRAINT [DF_DMPAD_CreatedOn] DEFAULT (sysutcdatetime()),
    CONSTRAINT [PK_DenialMapperPushAuditDetail] PRIMARY KEY CLUSTERED ([PushAuditDetailId] ASC)
);
GO
CREATE TABLE dbo.[DenialMapperSuperMaster]
(
    [Id] bigint IDENTITY(1,1) NOT NULL,
    [DenialCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [DenialDescription] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialClassification] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoverageStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ICDComplianceStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialValidity] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ActionCategory] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [Task] nvarchar(300) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [RecommendedAction] nvarchar(1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [SLA] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [Priority] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [IsActive] bit NOT NULL CONSTRAINT [DF_DMSM_Active] DEFAULT ((1)),
    [CreatedBy] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [CreatedOn] datetime2(7) NOT NULL CONSTRAINT [DF_DMSM_Created] DEFAULT (sysutcdatetime()),
    [ModifiedBy] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [ModifiedOn] datetime2(7) NOT NULL CONSTRAINT [DF_DMSM_Modified] DEFAULT (sysutcdatetime()),
    CONSTRAINT [PK__DenialMa__3214EC07F1553B17] PRIMARY KEY CLUSTERED ([Id] ASC)
);
GO
CREATE TABLE dbo.[DenialStatusMaster]
(
    [StatusId] int IDENTITY(1,1) NOT NULL,
    [StatusName] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [IsClosedStatus] bit NOT NULL CONSTRAINT [DF_DenialStatusMaster_IsClosedStatus] DEFAULT ((0)),
    [IsVerificationStatus] bit NOT NULL CONSTRAINT [DF_DenialStatusMaster_IsVerificationStatus] DEFAULT ((0)),
    [SortOrder] int NOT NULL CONSTRAINT [DF_DenialStatusMaster_SortOrder] DEFAULT ((100)),
    [IsActive] bit NOT NULL CONSTRAINT [DF_DenialStatusMaster_IsActive] DEFAULT ((1)),
    [CreatedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DenialStatusMaster_CreatedOn] DEFAULT (sysutcdatetime()),
    CONSTRAINT [PK_DenialStatusMaster] PRIMARY KEY CLUSTERED ([StatusId] ASC),
    CONSTRAINT [UQ_DenialStatusMaster_StatusName] UNIQUE NONCLUSTERED ([StatusName] ASC)
);
GO
CREATE TABLE dbo.[DenialTaskBoard]
(
    [TaskID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClaimID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatientId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CPTCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialDescription] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialClassification] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RecommendedAction] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCategory] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Task] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Priority] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [InsuranceBalance] decimal(18,2) NOT NULL CONSTRAINT [DF__DenialTas__Insur__72C60C4A] DEFAULT ((0.0)),
    [IsCurrentDenial] bit NULL,
    [SLADays] int NULL,
    [Status] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DateOpened] date NULL,
    [DueDate] date NULL,
    [DateCompleted] date NULL,
    [DaysRemaining] int NULL,
    [SLAStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [AssignedTo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabId] int NULL,
    [LabName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RunId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CreatedOn] datetime2(0) NULL,
    [UniqueTrackId] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SalesRepname] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClinicName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ReferringProvider] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PayerName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PayerNameNormalized] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PayerCode] int NULL,
    [PayerType] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [FirstBilledDate] date NULL,
    [ChargeEnteredDate] date NULL,
    [BillingProvider] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PanelName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DateOfService] date NULL,
    [ReviewerComments] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ReviewerUpdatedOn] datetime2(0) NULL,
    [ReviewerUpdatedBy] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ICDCodes] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CoverageStatus] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ICDComplianceStatus] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialValidity] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Units] int NULL,
    [Modifier] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClaimIDNormalized] AS (CONVERT([varchar](50),replace([ClaimID],'CLM-',''))),
    [ClaimUID] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [WorkFlowStatus] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClaimFrom] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Source] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatName] nvarchar(250) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SubscriberId] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ShortCategory] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL
);
GO
CREATE TABLE dbo.[DenialTaskHistory]
(
    [HistoryId] bigint IDENTITY(1,1) NOT NULL,
    [TaskID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [UniqueTrackId] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionType] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [OldStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [OldAssignedTo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [NewAssignedTo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Comments] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionBy] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionDate] datetime2(0) NOT NULL CONSTRAINT [DF_DenialTaskHistory_ActionDate] DEFAULT (sysutcdatetime()),
    [RunId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [SnapshotJson] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabId] int NULL,
    [LabName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    CONSTRAINT [PK_DenialTaskHistory] PRIMARY KEY CLUSTERED ([HistoryId] ASC)
);
GO
CREATE TABLE dbo.[DenialVerification]
(
    [DenialVerificationId] int IDENTITY(1,1) NOT NULL,
    [ClaimUID] nvarchar(600) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [TaskID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClaimID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [UniqueTrackId] nvarchar(450) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabId] int NOT NULL,
    [LabName] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RunId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [AssignedTo] nvarchar(200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Status] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [VerificationStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    [CreatedOn] datetime2(7) NOT NULL,
    CONSTRAINT [PK__DenialVe__FC6A8FEA056F2D31] PRIMARY KEY CLUSTERED ([DenialVerificationId] ASC)
);
GO
CREATE TABLE dbo.[DenialVerificationTask]
(
    [VerificationId] bigint IDENTITY(1,1) NOT NULL,
    [TaskID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [UniqueTrackId] nvarchar(150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ClaimID] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PatientId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CPTCode] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialCode] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DenialDescription] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ActionCategory] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RecommendedAction] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Task] nvarchar(500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [Priority] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [InsuranceBalance] decimal(18,2) NOT NULL CONSTRAINT [DF_DenialVerificationTask_InsuranceBalance] DEFAULT ((0)),
    [Status] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [DateOpened] date NULL,
    [DueDate] date NULL,
    [DateCompleted] date NULL,
    [DaysRemaining] int NULL,
    [SLAStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [AssignedTo] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [LabId] int NULL,
    [LabName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [RunId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [CreatedOn] datetime2(0) NULL,
    [PayerName] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [PayerNameNormalized] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ReviewerComments] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [ReviewerUpdatedOn] datetime2(0) NULL,
    [ReviewerUpdatedBy] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [VerificationStatus] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL CONSTRAINT [DF_DenialVerificationTask_VerificationStatus] DEFAULT (N'Verification Pending'),
    [VerificationComments] nvarchar(max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [OriginalRunId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [MissingDetectedRunId] nvarchar(100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [MovedOn] datetime2(0) NOT NULL CONSTRAINT [DF_DenialVerificationTask_MovedOn] DEFAULT (sysutcdatetime()),
    [VerifiedBy] nvarchar(255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
    [VerifiedOn] datetime2(0) NULL,
    CONSTRAINT [PK_DenialVerificationTask] PRIMARY KEY CLUSTERED ([VerificationId] ASC)
);
GO
ALTER TABLE dbo.[DenialCodeActionChangeVerification] ADD CONSTRAINT [FK_DCACV_Batch] FOREIGN KEY ([BatchId]) REFERENCES dbo.[DenialCodeActionChangeBatch] ([BatchId]);
GO
ALTER TABLE dbo.[DenialMapperPushAuditDetail] ADD CONSTRAINT [FK_DenialMapperPushAuditDetail_Audit] FOREIGN KEY ([PushAuditId]) REFERENCES dbo.[DenialMapperPushAudit] ([PushAuditId]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialClaimDocuments_Claim] ON dbo.[DenialClaimDocuments] ([LabId] ASC,[ClaimId] ASC,[UploadedOn] DESC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialClaimEscalations_Claim] ON dbo.[DenialClaimEscalations] ([LabId] ASC,[ClaimId] ASC,[EscalationLevel] ASC,[CreatedOn] DESC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialClaimEscalations_FollowUp] ON dbo.[DenialClaimEscalations] ([LabId] ASC,[EscalationLevel] ASC,[Status] ASC,[NextFollowUpDate] ASC,[CreatedOn] DESC) INCLUDE ([ClaimId],[TaskId],[CptCode],[EscalationReason],[EscalatedTo],[EscalatedToRole],[CreatedBy]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialClaimEscalations_Line] ON dbo.[DenialClaimEscalations] ([LabId] ASC,[ClaimId] ASC,[TaskId] ASC,[CptCode] ASC,[CreatedOn] DESC);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_Escalations_Lab_Claim_Active] ON dbo.[DenialClaimEscalations] ([LabId] ASC,[ClaimId] ASC,[IsDeleted] ASC) INCLUDE ([Comments],[CreatedBy],[CreatedOn],[EscalatedTo],[EscalatedToRole],[EscalationId],[EscalationLevel],[EscalationReason],[NextFollowUpDate],[Status]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_Escalations_Lab_Claim_Status_Role] ON dbo.[DenialClaimEscalations] ([LabId] ASC,[ClaimId] ASC,[Status] ASC,[EscalatedToRole] ASC) INCLUDE ([IsDeleted],[EscalatedTo],[NextFollowUpDate],[EscalationReason],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialClaimNotes_Claim] ON dbo.[DenialClaimNotes] ([LabId] ASC,[ClaimId] ASC,[NoteLevel] ASC,[CreatedOn] DESC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialClaimNotes_Line] ON dbo.[DenialClaimNotes] ([LabId] ASC,[ClaimId] ASC,[TaskId] ASC,[CptCode] ASC,[CreatedOn] DESC);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_Notes_Lab_Claim_Followup] ON dbo.[DenialClaimNotes] ([LabId] ASC,[ClaimId] ASC,[NextFollowUpDate] ASC) INCLUDE ([IsDeleted],[NoteLevel],[Status],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialClosedClaims_Lab_ClosedOn] ON dbo.[DenialClosedClaims] ([LabId] ASC,[ClosedOn] DESC) INCLUDE ([ClaimId],[AssignedTo],[WorkFlowStatus],[InsuranceBalance]);
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_DenialClosedClaims_Lab_Claim] ON dbo.[DenialClosedClaims] ([LabId] ASC,[ClaimId] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialClosedClaimsHistory_Lab_Claim] ON dbo.[DenialClosedClaimsHistory] ([LabId] ASC,[ClaimId] ASC,[ActionDate] DESC);
GO
CREATE NONCLUSTERED INDEX [IX_DCACV_Batch_Status] ON dbo.[DenialCodeActionChangeVerification] ([BatchId] ASC,[VerificationStatus] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DCACV_Claim_Task] ON dbo.[DenialCodeActionChangeVerification] ([ClaimID] ASC,[TaskID] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DCACV_Denial_Key] ON dbo.[DenialCodeActionChangeVerification] ([DenialCode] ASC,[ICDComplianceStatus] ASC,[CoverageStatus] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialCodeMaster_Action] ON dbo.[DenialCodeMaster] ([ActionCode] ASC,[ActionCategory] ASC) INCLUDE ([DenialClassification],[CoverageStatus],[Task]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialCodeMaster_Classification] ON dbo.[DenialCodeMaster] ([DenialClassification] ASC,[CoverageStatus] ASC) INCLUDE ([ActionCode],[ActionCategory],[Priority],[SLADays]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialCodeMaster_Lookups] ON dbo.[DenialCodeMaster] ([DenialValidity] ASC,[ICDComplianceStatus] ASC,[Task] ASC) INCLUDE ([DenialClassification],[CoverageStatus],[ActionCode],[ActionCategory]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialInsight_Assignment] ON dbo.[DenialInsight] ([LabId] ASC,[RunId] ASC,[DenialCodes] ASC,[HighImpactInsurance] ASC) INCLUDE ([AssignedTo],[ResponsibilityReviewer]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialInsight_Lab_Filter] ON dbo.[DenialInsight] ([LabId] ASC,[DenialCodes] ASC,[HighImpactInsurance] ASC,[RunId] ASC) INCLUDE ([AssignedTo],[InsuranceBalance],[CreatedOn],[ActionCategory],[ActionCode]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialInsight_Lab_Paging] ON dbo.[DenialInsight] ([LabId] ASC,[InsuranceBalance] DESC,[DenialCodes] ASC) INCLUDE ([RunId],[CreatedOn],[AssignedTo],[ResponsibilityReviewer],[HighImpactInsurance],[ActionCategory],[ActionCode],[NoOfDenialCount],[NoOfClaimsCount],[TotalBalance],[ImpactPercentage],[LabName]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialInsight_Workflow_Page] ON dbo.[DenialInsight] ([LabId] ASC,[DenialCodes] ASC,[HighImpactInsurance] ASC,[RunId] ASC) INCLUDE ([InsuranceBalance],[ImpactPercentage],[NoOfDenialCount],[NoOfClaimsCount]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_ClaimAssignment_Page] ON dbo.[DenialLineItem] ([DateOfService] DESC,[VisitNumber] ASC) INCLUDE ([PayerName],[PanelName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance],[DenialCodeNormalized],[ActionCategory],[DenialClassification]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_Lab_Filters] ON dbo.[DenialLineItem] ([LabId] ASC,[PayerNameNormalized] ASC,[DenialCodeNormalized] ASC) INCLUDE ([VisitNumber],[ClinicName],[SalesRepname],[ReferringProvider],[DateOfService],[ActionCategory],[DenialClassification]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_Lab_Visit_SLA] ON dbo.[DenialLineItem] ([LabId] ASC,[VisitNumber] ASC) INCLUDE ([SLADays],[CPTCode]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_Lab_VisitNumber] ON dbo.[DenialLineItem] ([LabId] ASC,[VisitNumber] ASC) INCLUDE ([PatientName],[PatientDOB],[PatientID],[ClinicName],[SalesRepname],[ReferringProvider],[PayerName],[PayerNameNormalized],[DateOfService],[DenialCodeNormalized],[ActionCategory],[DenialClassification],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_VisitNumber_ClaimView] ON dbo.[DenialLineItem] ([VisitNumber] ASC,[DateOfService] ASC) INCLUDE ([PayerNameNormalized],[PanelName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance]);
GO
CREATE NONCLUSTERED INDEX [IX_DLI_Filtered] ON dbo.[DenialLineItem] ([VisitNumber] ASC) INCLUDE ([DenialDescription],[DenialDate]) WHERE ([DenialCodeOriginal] IS NOT NULL AND [DenialCodeOriginal]<>'');
GO
CREATE NONCLUSTERED INDEX [IX_DLI_VisitNumber_Fast] ON dbo.[DenialLineItem] ([VisitNumber] ASC) INCLUDE ([DenialCodeOriginal],[DenialDescription],[DenialDate]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_ClaimUID_ClaimView] ON dbo.[DenialLineItem] ([ClaimUID] ASC,[DateOfService] DESC) INCLUDE ([ActionCategory],[AssignedTo],[ClinicName],[DenialClassification],[DenialCodeNormalized],[InsuranceBalance],[PanelName],[PatientDOB],[PatientID],[PatientName],[PayerName],[PayerNameNormalized],[ReferringProvider],[SalesRepname],[WorkFlowStatus]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_DOS_ClaimUID_Page] ON dbo.[DenialLineItem] ([DateOfService] DESC,[ClaimUID] ASC) INCLUDE ([ActionCategory],[AssignedTo],[ClinicName],[DenialClassification],[DenialCodeNormalized],[InsuranceBalance],[PanelName],[PatientDOB],[PatientID],[PatientName],[PayerName],[PayerNameNormalized],[ReferringProvider],[SalesRepname],[WorkFlowStatus]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_Lab_ClaimUID_DOS] ON dbo.[DenialLineItem] ([LabId] ASC,[ClaimUID] ASC,[DateOfService] DESC) INCLUDE ([VisitNumber],[PayerName],[PanelName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance],[DenialCodeNormalized],[ActionCategory],[DenialClassification]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_Lab_Code_Payer] ON dbo.[DenialLineItem] ([LabId] ASC,[DenialCodeNormalized] ASC,[PayerNameNormalized] ASC) INCLUDE ([VisitNumber],[DateOfService],[ClinicName],[ReferringProvider],[PatientID],[PatientName],[PatientDOB],[PanelName],[SalesRepname],[InsuranceBalance],[DenialClassification],[ActionCategory]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_Lab_DOS] ON dbo.[DenialLineItem] ([LabId] ASC,[DateOfService] DESC) INCLUDE ([VisitNumber],[PayerNameNormalized],[PanelName],[PatientName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance],[DenialCodeNormalized],[DenialClassification],[ActionCategory]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_Lab_DOS_Visit_Page] ON dbo.[DenialLineItem] ([LabId] ASC,[DateOfService] DESC,[VisitNumber] ASC) INCLUDE ([PayerName],[PanelName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance],[DenialCodeNormalized],[ActionCategory],[DenialClassification]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_VisitNumber_ClaimView_Fallback] ON dbo.[DenialLineItem] ([VisitNumber] ASC,[DateOfService] DESC) INCLUDE ([ActionCategory],[AssignedTo],[ClinicName],[DenialClassification],[DenialCodeNormalized],[InsuranceBalance],[PanelName],[PatientDOB],[PatientID],[PatientName],[PayerName],[PayerNameNormalized],[ReferringProvider],[SalesRepname],[WorkFlowStatus]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialMapperAuditLog_LabDate] ON dbo.[DenialMapperAuditLog] ([LabId] ASC,[PerformedOn] DESC);
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_DenialMapperLabOverride_Active] ON dbo.[DenialMapperLabOverride] ([LabId] ASC,[SuperMasterId] ASC) WHERE ([IsActive]=(1));
GO
CREATE NONCLUSTERED INDEX [IX_DenialMapperPushAudit_Status_TargetLab] ON dbo.[DenialMapperPushAudit] ([TargetLabId] ASC,[PushStatus] ASC,[CreatedOn] DESC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialMapperPushAuditDetail_Code_Key] ON dbo.[DenialMapperPushAuditDetail] ([TargetLabId] ASC,[DenialCode] ASC,[ICDComplianceStatus] ASC,[CoverageStatus] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialMapperPushAuditDetail_PushAuditId] ON dbo.[DenialMapperPushAuditDetail] ([PushAuditId] ASC);
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_DenialMapperSuperMaster_Key] ON dbo.[DenialMapperSuperMaster] ([DenialCode] ASC,[DenialClassification] ASC,[CoverageStatus] ASC,[ICDComplianceStatus] ASC) WHERE ([IsActive]=(1));
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Assignment] ON dbo.[DenialTaskBoard] ([LabId] ASC,[RunId] ASC,[DenialCode] ASC,[PayerNameNormalized] ASC,[AssignedTo] ASC) INCLUDE ([TaskID],[Status],[PayerName]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_ClaimAssignment_Status] ON dbo.[DenialTaskBoard] ([ClaimIDNormalized] ASC) INCLUDE ([TaskID],[Status],[AssignedTo],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_ClaimIDNormalized] ON dbo.[DenialTaskBoard] ([ClaimIDNormalized] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_ActionCategory] ON dbo.[DenialTaskBoard] ([LabId] ASC,[ActionCategory] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_AssignLookup] ON dbo.[DenialTaskBoard] ([LabId] ASC,[DenialCode] ASC,[PayerName] ASC,[RunId] ASC) INCLUDE ([AssignedTo],[Status],[TaskID],[ReviewerUpdatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_ClaimID] ON dbo.[DenialTaskBoard] ([LabId] ASC,[ClaimID] ASC) INCLUDE ([TaskID],[CPTCode],[DenialCode],[DenialDescription],[InsuranceBalance],[DenialClassification],[ActionCode],[RecommendedAction],[ActionCategory],[SLADays],[Status],[AssignedTo],[CoverageStatus],[ICDCodes],[ICDComplianceStatus],[DenialValidity]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_DenialCode] ON dbo.[DenialTaskBoard] ([LabId] ASC,[DenialCode] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_PayerName] ON dbo.[DenialTaskBoard] ([LabId] ASC,[PayerName] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_Priority] ON dbo.[DenialTaskBoard] ([LabId] ASC,[Priority] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_Queue] ON dbo.[DenialTaskBoard] ([LabId] ASC,[AssignedTo] ASC,[Status] ASC,[DueDate] ASC,[TaskID] ASC) INCLUDE ([RunId],[UniqueTrackId],[ClaimID],[PatientId],[CPTCode],[DenialCode],[DenialClassification],[ActionCategory],[Priority],[InsuranceBalance],[PayerName],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_Status] ON dbo.[DenialTaskBoard] ([LabId] ASC,[Status] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_UID] ON dbo.[DenialTaskBoard] ([LabId] ASC,[UniqueTrackId] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Status_AssignedTo] ON dbo.[DenialTaskBoard] ([Status] ASC,[AssignedTo] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_TaskView_ClaimIDNormalized] ON dbo.[DenialTaskBoard] ([Status] ASC,[AssignedTo] ASC,[ClaimIDNormalized] ASC) INCLUDE ([TaskID],[UniqueTrackId],[CPTCode],[SLAStatus],[DueDate],[InsuranceBalance],[DenialCode],[DenialClassification],[ActionCategory]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Workflow_Active] ON dbo.[DenialTaskBoard] ([LabId] ASC,[Status] ASC,[AssignedTo] ASC,[UniqueTrackId] ASC) INCLUDE ([TaskID],[RunId],[ClaimID],[CPTCode],[DenialCode],[DueDate]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Workflow_ClaimAction] ON dbo.[DenialTaskBoard] ([LabId] ASC,[ClaimID] ASC,[ActionCategory] ASC) INCLUDE ([TaskID],[Status],[AssignedTo]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Workflow_Page] ON dbo.[DenialTaskBoard] ([LabId] ASC,[Status] ASC,[AssignedTo] ASC,[DueDate] ASC,[TaskID] ASC) INCLUDE ([ClaimID],[CPTCode],[DenialCode],[PayerName],[RunId],[InsuranceBalance]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Workflow_Search] ON dbo.[DenialTaskBoard] ([LabId] ASC,[DenialCode] ASC,[PayerName] ASC,[RunId] ASC) INCLUDE ([TaskID],[ClaimID],[AssignedTo],[Status],[InsuranceBalance]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg] ON dbo.[DenialTaskBoard] ([ClaimIDNormalized] ASC,[Status] ASC,[AssignedTo] ASC,[CreatedOn] ASC) INCLUDE ([ActionCategory],[ActionCode],[BillingProvider],[ChargeEnteredDate],[ClaimID],[ClinicName],[CoverageStatus],[DateCompleted],[DateOfService],[DateOpened],[DaysRemaining],[DenialClassification],[DenialCode],[DenialDescription],[DenialValidity],[DueDate],[FirstBilledDate],[ICDCodes],[ICDComplianceStatus],[InsuranceBalance],[IsCurrentDenial],[LabId],[LabName],[Modifier],[PanelName],[PatientId],[PayerCode],[PayerName],[PayerType],[Priority],[RecommendedAction],[ReferringProvider],[ReviewerComments],[ReviewerUpdatedBy],[ReviewerUpdatedOn],[RunId],[SalesRepname],[SLADays],[SLAStatus],[Task],[UniqueTrackId],[Units],[WorkFlowStatus]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_ClaimUID_Drill] ON dbo.[DenialTaskBoard] ([ClaimUID] ASC,[CPTCode] ASC,[TaskID] ASC) INCLUDE ([ActionCategory],[ActionCode],[BillingProvider],[ChargeEnteredDate],[ClaimID],[ClinicName],[CoverageStatus],[DateCompleted],[DateOfService],[DateOpened],[DaysRemaining],[DenialClassification],[DenialCode],[DenialDescription],[DenialValidity],[DueDate],[FirstBilledDate],[ICDCodes],[ICDComplianceStatus],[InsuranceBalance],[IsCurrentDenial],[LabId],[LabName],[Modifier],[PanelName],[PatientId],[PayerCode],[PayerName],[PayerType],[Priority],[RecommendedAction],[ReferringProvider],[ReviewerComments],[ReviewerUpdatedBy],[ReviewerUpdatedOn],[RunId],[SalesRepname],[SLADays],[SLAStatus],[Task],[UniqueTrackId],[Units],[WorkFlowStatus]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_ClaimUID_StatusAgg] ON dbo.[DenialTaskBoard] ([ClaimUID] ASC) INCLUDE ([ActionCategory],[ActionCode],[AssignedTo],[BillingProvider],[ChargeEnteredDate],[ClaimID],[ClinicName],[CoverageStatus],[CreatedOn],[DateCompleted],[DateOfService],[DateOpened],[DaysRemaining],[DenialClassification],[DenialCode],[DenialDescription],[DenialValidity],[DueDate],[FirstBilledDate],[ICDCodes],[ICDComplianceStatus],[InsuranceBalance],[IsCurrentDenial],[LabId],[LabName],[Modifier],[PanelName],[PatientId],[PayerCode],[PayerName],[PayerType],[Priority],[RecommendedAction],[ReferringProvider],[ReviewerComments],[ReviewerUpdatedBy],[ReviewerUpdatedOn],[RunId],[SalesRepname],[SLADays],[SLAStatus],[Status],[Task],[UniqueTrackId],[Units],[WorkFlowStatus]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Claim] ON dbo.[DenialTaskBoard] ([LabId] ASC,[ClaimID] ASC) INCLUDE ([TaskID],[UniqueTrackId],[CPTCode],[DenialCode],[DenialClassification],[ActionCategory],[Priority],[Status],[AssignedTo],[InsuranceBalance],[DueDate],[DateOfService],[PayerName],[PayerNameNormalized]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Claim_Status_Assigned] ON dbo.[DenialTaskBoard] ([LabId] ASC,[ClaimIDNormalized] ASC,[Status] ASC,[AssignedTo] ASC) INCLUDE ([TaskID],[ClaimID],[CreatedOn],[ReviewerUpdatedOn],[WorkFlowStatus]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_ClaimUID_Status] ON dbo.[DenialTaskBoard] ([LabId] ASC,[ClaimUID] ASC,[Status] ASC,[AssignedTo] ASC,[CreatedOn] ASC) INCLUDE ([TaskID],[ClaimIDNormalized],[CPTCode],[SLAStatus],[WorkFlowStatus],[InsuranceBalance],[DenialClassification],[ActionCategory]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Class_Action] ON dbo.[DenialTaskBoard] ([LabId] ASC,[DenialClassification] ASC,[ActionCategory] ASC) INCLUDE ([Status],[AssignedTo],[DueDate],[TaskID],[ClaimID],[DenialCode],[Priority],[InsuranceBalance],[PayerName],[PayerNameNormalized],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Code_Payer] ON dbo.[DenialTaskBoard] ([LabId] ASC,[DenialCode] ASC,[PayerNameNormalized] ASC) INCLUDE ([Status],[AssignedTo],[DueDate],[TaskID],[ClaimID],[DenialClassification],[ActionCategory],[Priority],[InsuranceBalance],[PayerName],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Status_Assigned_Created] ON dbo.[DenialTaskBoard] ([LabId] ASC,[Status] ASC,[AssignedTo] ASC,[CreatedOn] ASC,[ClaimIDNormalized] ASC) INCLUDE ([TaskID],[ClaimID],[CPTCode],[SLAStatus],[WorkFlowStatus],[InsuranceBalance],[DenialCode],[DenialClassification],[ActionCategory],[Priority],[PayerName],[PanelName],[DateOfService]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Status_Assigned_Due] ON dbo.[DenialTaskBoard] ([LabId] ASC,[Status] ASC,[AssignedTo] ASC,[DueDate] ASC,[TaskID] ASC) INCLUDE ([ClaimID],[DenialCode],[DenialClassification],[ActionCategory],[Priority],[InsuranceBalance],[PayerName],[PayerNameNormalized],[ClinicName],[SalesRepname],[ReferringProvider],[DateOfService],[RunId],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Status_WorkFlowStatus] ON dbo.[DenialTaskBoard] ([LabId] ASC,[Status] ASC,[WorkFlowStatus] ASC) INCLUDE ([ClaimIDNormalized],[ClaimID],[AssignedTo],[CreatedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialTaskHistory_Workflow] ON dbo.[DenialTaskHistory] ([LabId] ASC,[TaskID] ASC,[UniqueTrackId] ASC,[ActionDate] ASC) INCLUDE ([ActionType],[RunId]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialVerificationTask_Lab_Paging] ON dbo.[DenialVerificationTask] ([LabId] ASC,[VerificationId] DESC) INCLUDE ([TaskID],[UniqueTrackId],[ClaimID],[PatientId],[CPTCode],[DenialCode],[Status],[AssignedTo],[RunId],[PayerName],[CreatedOn],[VerificationStatus]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialVerificationTask_Workflow] ON dbo.[DenialVerificationTask] ([LabId] ASC,[VerificationStatus] ASC,[AssignedTo] ASC,[UniqueTrackId] ASC) INCLUDE ([TaskID],[RunId],[MovedOn]);
GO
CREATE NONCLUSTERED INDEX [IX_DenialVerificationTask_Workflow_Page] ON dbo.[DenialVerificationTask] ([LabId] ASC,[VerificationStatus] ASC,[AssignedTo] ASC,[MovedOn] ASC,[TaskID] ASC) INCLUDE ([ClaimID],[CPTCode],[DenialCode],[PayerName],[RunId],[InsuranceBalance]);
GO
-- Standard lookup seed rows required by Denial Workflow.
MERGE dbo.DenialStatusMaster t USING (VALUES (N'Closed',1,0,10),(N'Completed',1,0,20),(N'Duplicate',0,1,30),(N'Verification Pending',0,1,40),(N'Pending Review',0,0,50),(N'In-Progress',0,0,60),(N'New',0,0,70)) s(StatusName,IsClosedStatus,IsVerificationStatus,SortOrder) ON t.StatusName=s.StatusName WHEN NOT MATCHED THEN INSERT(StatusName,IsClosedStatus,IsVerificationStatus,SortOrder) VALUES(s.StatusName,s.IsClosedStatus,s.IsVerificationStatus,s.SortOrder);
MERGE dbo.DenialActionCategoryMaster t USING (VALUES(N'Rebill',N'ClaimLevel')) s(ActionCategory,ActionScope) ON t.ActionCategory=s.ActionCategory WHEN NOT MATCHED THEN INSERT(ActionCategory,ActionScope) VALUES(s.ActionCategory,s.ActionScope);
GO
SELECT t.name TableName,SUM(p.rows) RowCount FROM sys.tables t JOIN sys.partitions p ON p.object_id=t.object_id AND p.index_id IN(0,1) WHERE t.name LIKE N'Denial%' GROUP BY t.name ORDER BY t.name;
PRINT 'NorthWest Denial Workflow table structure created successfully in $(TargetDatabase).';
GO

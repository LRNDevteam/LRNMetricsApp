USE [NWL_LRN]
GO
/****** Object:  Table [dbo].[DenialActionCategoryMaster]    Script Date: 07/21/2026 10:17:23 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialActionCategoryMaster](
	[ActionCategoryId] [int] IDENTITY(1,1) NOT NULL,
	[ActionCategory] [nvarchar](255) NOT NULL,
	[ActionScope] [nvarchar](50) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_DenialActionCategoryMaster] PRIMARY KEY CLUSTERED 
(
	[ActionCategoryId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY],
 CONSTRAINT [UQ_DenialActionCategoryMaster_ActionCategory] UNIQUE NONCLUSTERED 
(
	[ActionCategory] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialAnalysisRunLog]    Script Date: 07/21/2026 10:17:25 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialAnalysisRunLog](
	[RunId] [nvarchar](100) NULL,
	[LabId] [int] NULL,
	[OutputFileName] [nvarchar](500) NULL,
	[CreatedOn] [datetime2](0) NULL
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialClaimDocuments]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialClaimDocuments](
	[DocumentId] [bigint] IDENTITY(1,1) NOT NULL,
	[LabId] [int] NOT NULL,
	[ClaimId] [nvarchar](150) NOT NULL,
	[OriginalFileName] [nvarchar](260) NOT NULL,
	[StoredFileName] [nvarchar](260) NOT NULL,
	[ContentType] [nvarchar](150) NULL,
	[FileSizeBytes] [bigint] NOT NULL,
	[FilePath] [nvarchar](1000) NOT NULL,
	[Comment] [nvarchar](1000) NULL,
	[UploadedBy] [nvarchar](256) NOT NULL,
	[UploadedOn] [datetime2](0) NOT NULL,
	[IsDeleted] [bit] NOT NULL,
 CONSTRAINT [PK_DenialClaimDocuments] PRIMARY KEY CLUSTERED 
(
	[DocumentId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialClaimEscalations]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialClaimEscalations](
	[EscalationId] [bigint] IDENTITY(1,1) NOT NULL,
	[LabId] [int] NOT NULL,
	[ClaimId] [nvarchar](150) NOT NULL,
	[TaskId] [nvarchar](100) NULL,
	[CptCode] [nvarchar](50) NULL,
	[EscalationLevel] [nvarchar](20) NOT NULL,
	[EscalationReason] [nvarchar](300) NOT NULL,
	[Comments] [nvarchar](max) NULL,
	[Status] [nvarchar](50) NOT NULL,
	[CreatedBy] [nvarchar](256) NOT NULL,
	[CreatedOn] [datetime2](0) NOT NULL,
	[IsDeleted] [bit] NOT NULL,
	[EscalatedTo] [nvarchar](256) NULL,
	[EscalatedToRole] [nvarchar](100) NULL,
	[NextFollowUpDate] [date] NULL,
 CONSTRAINT [PK_DenialClaimEscalations] PRIMARY KEY CLUSTERED 
(
	[EscalationId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialClaimNotes]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialClaimNotes](
	[NoteId] [bigint] IDENTITY(1,1) NOT NULL,
	[LabId] [int] NOT NULL,
	[ClaimId] [nvarchar](150) NOT NULL,
	[TaskId] [nvarchar](100) NULL,
	[CptCode] [nvarchar](50) NULL,
	[NoteLevel] [nvarchar](20) NOT NULL,
	[NoteText] [nvarchar](max) NOT NULL,
	[CreatedBy] [nvarchar](256) NOT NULL,
	[CreatedOn] [datetime2](0) NOT NULL,
	[IsDeleted] [bit] NOT NULL,
	[Status] [nvarchar](50) NULL,
	[NextFollowUpDate] [date] NULL,
	[ClaimIdNormalized]  AS (CONVERT([varchar](150),replace(ltrim(rtrim(isnull([ClaimId],''))),'CLM-',''))) PERSISTED,
	[FollowUpReason] [nvarchar](250) NULL,
 CONSTRAINT [PK_DenialClaimNotes] PRIMARY KEY CLUSTERED 
(
	[NoteId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialClosedClaims]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialClosedClaims](
	[ClosedClaimId] [bigint] IDENTITY(1,1) NOT NULL,
	[LabId] [int] NOT NULL,
	[ClaimId] [nvarchar](150) NOT NULL,
	[PayerName] [nvarchar](256) NULL,
	[PanelName] [nvarchar](256) NULL,
	[PatientName] [nvarchar](255) NULL,
	[PatientDOB] [date] NULL,
	[PatientId] [nvarchar](100) NULL,
	[SubscriberId] [nvarchar](100) NULL,
	[ClinicName] [nvarchar](256) NULL,
	[SalesRepname] [nvarchar](256) NULL,
	[ReferringProvider] [nvarchar](256) NULL,
	[DateOfService] [date] NULL,
	[AssignedTo] [nvarchar](255) NULL,
	[Status] [nvarchar](100) NOT NULL,
	[WorkFlowStatus] [nvarchar](100) NOT NULL,
	[TaskCount] [int] NOT NULL,
	[InsuranceBalance] [decimal](18, 2) NOT NULL,
	[ClosedOn] [datetime2](0) NOT NULL,
	[ClosedBy] [nvarchar](256) NULL,
	[LastUpdatedOn] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_DenialClosedClaims] PRIMARY KEY CLUSTERED 
(
	[ClosedClaimId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialClosedClaimsHistory]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialClosedClaimsHistory](
	[HistoryId] [bigint] IDENTITY(1,1) NOT NULL,
	[ClosedClaimId] [bigint] NULL,
	[LabId] [int] NOT NULL,
	[ClaimId] [nvarchar](150) NOT NULL,
	[ActionType] [nvarchar](100) NOT NULL,
	[OldWorkFlowStatus] [nvarchar](100) NULL,
	[NewWorkFlowStatus] [nvarchar](100) NULL,
	[OldAssignedTo] [nvarchar](255) NULL,
	[NewAssignedTo] [nvarchar](255) NULL,
	[Comments] [nvarchar](max) NULL,
	[ActionBy] [nvarchar](256) NULL,
	[ActionDate] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_DenialClosedClaimsHistory] PRIMARY KEY CLUSTERED 
(
	[HistoryId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialCodeActionChangeBatch]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialCodeActionChangeBatch](
	[BatchId] [bigint] IDENTITY(1,1) NOT NULL,
	[SourceFileName] [nvarchar](500) NOT NULL,
	[UploadedBy] [nvarchar](100) NOT NULL,
	[UploadedOn] [datetime2](0) NOT NULL,
	[TotalAffectedClaims] [int] NOT NULL,
	[TotalAffectedTasks] [int] NOT NULL,
	[PendingCount] [int] NOT NULL,
	[ConfirmedCount] [int] NOT NULL,
	[IgnoredCount] [int] NOT NULL,
	[Status] [nvarchar](50) NOT NULL,
 CONSTRAINT [PK_DenialCodeActionChangeBatch] PRIMARY KEY CLUSTERED 
(
	[BatchId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialCodeActionChangeVerification]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialCodeActionChangeVerification](
	[VerificationId] [bigint] IDENTITY(1,1) NOT NULL,
	[BatchId] [bigint] NOT NULL,
	[ClaimID] [nvarchar](100) NOT NULL,
	[TaskID] [nvarchar](100) NULL,
	[PatientId] [nvarchar](100) NULL,
	[PayerName] [nvarchar](255) NULL,
	[AssignedTo] [nvarchar](100) NULL,
	[ClaimStatus] [nvarchar](100) NULL,
	[DenialCode] [nvarchar](100) NOT NULL,
	[ICDComplianceStatus] [nvarchar](255) NULL,
	[CoverageStatus] [nvarchar](255) NULL,
	[OldActionCode] [nvarchar](100) NULL,
	[NewActionCode] [nvarchar](100) NULL,
	[OldActionCategory] [nvarchar](500) NULL,
	[NewActionCategory] [nvarchar](500) NULL,
	[OldTask] [nvarchar](500) NULL,
	[NewTask] [nvarchar](500) NULL,
	[OldShortCategory] [nvarchar](255) NULL,
	[NewShortCategory] [nvarchar](255) NULL,
	[VerificationStatus] [nvarchar](50) NOT NULL,
	[VerifiedBy] [nvarchar](100) NULL,
	[VerifiedOn] [datetime2](0) NULL,
	[CreatedOn] [datetime2](0) NOT NULL,
	[CPTCode] [nvarchar](100) NULL,
	[Units] [int] NULL,
	[Modifier] [nvarchar](100) NULL,
	[DenialDescription] [nvarchar](1000) NULL,
	[DenialClassification] [nvarchar](255) NULL,
	[ActionCode] [nvarchar](100) NULL,
	[ActionCategory] [nvarchar](500) NULL,
	[RecommendedAction] [nvarchar](1000) NULL,
	[Task] [nvarchar](500) NULL,
	[Priority] [nvarchar](100) NULL,
	[InsuranceBalance] [decimal](18, 2) NULL,
	[SLADays] [int] NULL,
	[Status] [nvarchar](100) NULL,
	[DateOpened] [date] NULL,
	[DueDate] [date] NULL,
	[SLAStatus] [nvarchar](100) NULL,
	[FirstBilledDate] [date] NULL,
	[ChargeEnteredDate] [date] NULL,
	[DenialValidity] [nvarchar](255) NULL,
 CONSTRAINT [PK_DenialCodeActionChangeVerification] PRIMARY KEY CLUSTERED 
(
	[VerificationId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialCodeMapper]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialCodeMapper](
	[DenialCode] [nvarchar](50) NOT NULL,
	[DenialDescription] [nvarchar](500) NULL,
	[ReplacementDescrp] [nvarchar](500) NULL,
	[DenialComment] [nvarchar](500) NULL,
	[ActionComment] [nvarchar](500) NULL,
	[CreatedOn] [datetime] NULL,
	[UpdatedOn] [datetime] NULL,
	[DenialCodePrefix] [nvarchar](50) NULL,
PRIMARY KEY CLUSTERED 
(
	[DenialCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialCodeMaster]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialCodeMaster](
	[DenialCode] [nvarchar](100) NOT NULL,
	[DenialDescription] [nvarchar](1000) NULL,
	[DenialClassification] [nvarchar](255) NULL,
	[CoverageStatus] [nvarchar](255) NOT NULL,
	[ICDComplianceStatus] [nvarchar](255) NOT NULL,
	[DenialValidity] [nvarchar](255) NULL,
	[ActionCode] [nvarchar](100) NULL,
	[RecommendedAction] [nvarchar](1000) NULL,
	[ActionCategory] [nvarchar](255) NULL,
	[Task] [nvarchar](500) NULL,
	[ShortCategory] [nvarchar](255) NULL,
	[Priority] [nvarchar](100) NULL,
	[SLADays] [nvarchar](100) NULL,
	[NotesComments] [nvarchar](2000) NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[CreatedBy] [nvarchar](100) NULL,
	[UpdatedOn] [datetime2](7) NULL,
	[UpdatedBy] [nvarchar](100) NULL,
 CONSTRAINT [PK_DenialCodeMaster] PRIMARY KEY CLUSTERED 
(
	[DenialCode] ASC,
	[CoverageStatus] ASC,
	[ICDComplianceStatus] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialCodeStaging]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialCodeStaging](
	[DenialCodeMaperId] [bigint] IDENTITY(1,1) NOT NULL,
	[DenialCode] [nvarchar](50) NULL,
	[DenialDescription] [nvarchar](500) NULL,
	[ReplacementDecription] [nvarchar](1500) NULL,
	[DenialComment] [nvarchar](1500) NULL,
	[ActionComment] [nvarchar](1500) NULL,
	[ImportedFileID] [int] NULL,
	[ImportedOn] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[DenialCodeMaperId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialInsight]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialInsight](
	[DenialCodes] [nvarchar](150) NULL,
	[Descriptions] [nvarchar](max) NULL,
	[NoOfDenialCount] [int] NULL,
	[NoOfClaimsCount] [int] NULL,
	[TotalBalance] [decimal](18, 2) NULL,
	[HighImpactInsurance] [nvarchar](255) NULL,
	[InsuranceBalance] [decimal](18, 2) NULL,
	[ImpactPercentage] [decimal](18, 2) NULL,
	[ActionCategory] [nvarchar](1500) NULL,
	[ActionCode] [nvarchar](255) NULL,
	[Action] [nvarchar](max) NULL,
	[Task] [nvarchar](1500) NULL,
	[Feedback] [nvarchar](1500) NULL,
	[Responsibility] [nvarchar](255) NULL,
	[DiscussionDate] [date] NULL,
	[ETA] [nvarchar](50) NULL,
	[LabName] [nvarchar](255) NULL,
	[LabId] [int] NULL,
	[RunId] [nvarchar](255) NULL,
	[CreatedOn] [datetime] NULL,
	[AssignedTo] [nvarchar](255) NULL,
	[ResponsibilityReviewer] [nvarchar](255) NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialLineItem]    Script Date: 07/21/2026 10:17:26 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialLineItem](
	[AccessionNo] [nvarchar](255) NULL,
	[VisitNumber] [nvarchar](255) NULL,
	[CPTCode] [nvarchar](50) NULL,
	[PatientDOB] [date] NULL,
	[PayerCode] [int] NULL,
	[PayerName] [nvarchar](255) NULL,
	[PayerNameNormalized] [nvarchar](255) NULL,
	[PayStatus] [nvarchar](255) NULL,
	[HistoricalPayment] [nvarchar](255) NULL,
	[HistoricalPaidLineItemCount] [nvarchar](255) NULL,
	[HistoricalPaymentConfidenceScore] [nvarchar](255) NULL,
	[TotalLineItemCount] [int] NULL,
	[PaidLineItemCount] [int] NULL,
	[PaidLineItemCountPercent] [decimal](18, 4) NULL,
	[PayerType] [nvarchar](255) NULL,
	[PayerFoundInPolicy] [nvarchar](255) NULL,
	[DateOfService] [date] NULL,
	[FirstBilledDate] [date] NULL,
	[PanelName] [nvarchar](255) NULL,
	[LISICD10Codes] [nvarchar](1500) NULL,
	[CCWICD10Code] [nvarchar](1500) NULL,
	[Units] [int] NULL,
	[Modifier] [nvarchar](255) NULL,
	[DenialCodeOriginal] [nvarchar](255) NULL,
	[DenialCodeNormalized] [nvarchar](255) NULL,
	[DenialDescription] [nvarchar](max) NULL,
	[BilledAmount] [decimal](18, 4) NULL,
	[AllowedAmount] [decimal](18, 4) NULL,
	[InsurancePayment] [decimal](18, 4) NULL,
	[InsuranceAdjustment] [decimal](18, 4) NULL,
	[PatientPaidAmount] [decimal](18, 4) NULL,
	[PatientAdjustment] [decimal](18, 4) NULL,
	[InsuranceBalance] [decimal](18, 4) NULL,
	[PatientBalance] [decimal](18, 4) NULL,
	[TotalBalance] [decimal](18, 4) NULL,
	[MedicareFee] [decimal](18, 4) NULL,
	[FinalClaimStatus] [nvarchar](255) NULL,
	[CoveredICD10CodesBilled] [nvarchar](max) NULL,
	[NonCoveredICD10CodesBilled] [nvarchar](max) NULL,
	[BilledICDCodesNotAvailableInPayerPolicy] [nvarchar](max) NULL,
	[CoverageStatus] [nvarchar](255) NULL,
	[FinalCoverageStatus] [nvarchar](255) NULL,
	[CoveredICD10CodesAsPerPayerPolicy] [nvarchar](max) NULL,
	[NonCoveredICD10CodesAsPerPayerPolicy] [nvarchar](max) NULL,
	[ActionComment] [nvarchar](1500) NULL,
	[Resolution] [nvarchar](255) NULL,
	[LabName] [nvarchar](255) NULL,
	[CodingValidation] [nvarchar](255) NULL,
	[CodingValidationSubStatus] [nvarchar](max) NULL,
	[ICDComplianceStatus] [nvarchar](255) NULL,
	[ICDComplianceSubstatus] [nvarchar](255) NULL,
	[ICDPrimaryIndicatorAvailable] [nvarchar](255) NULL,
	[CoveredICDPresence] [nvarchar](255) NULL,
	[ICDValidationConfidence] [nvarchar](255) NULL,
	[FrequencyConditionMet] [nvarchar](255) NULL,
	[GenderConditionMet] [nvarchar](255) NULL,
	[Payability] [nvarchar](255) NULL,
	[ForecastingPayability] [nvarchar](255) NULL,
	[PolicyCoverageExpectation] [nvarchar](255) NULL,
	[DenialValidity] [nvarchar](255) NULL,
	[CoverageExpectationRemarks] [nvarchar](max) NULL,
	[ExpectedAverageAllowedAmount] [decimal](18, 4) NULL,
	[ExpectedAverageInsurancePayment] [decimal](18, 4) NULL,
	[ExpectedAllowedAmountSameLab] [decimal](18, 4) NULL,
	[ExpectedInsurancePaymentSameLab] [decimal](18, 4) NULL,
	[ModeAllowedAmountSameLab] [decimal](18, 4) NULL,
	[ModeInsurancePaidSameLab] [decimal](18, 4) NULL,
	[ModeAllowedAmountPeer] [decimal](18, 4) NULL,
	[ModeInsurancePaidPeer] [decimal](18, 4) NULL,
	[MedianAllowedAmountSameLab] [decimal](18, 4) NULL,
	[MedianInsurancePaidSameLab] [decimal](18, 4) NULL,
	[MedianAllowedAmountPeer] [decimal](18, 4) NULL,
	[MedianInsurancePaidPeer] [decimal](18, 4) NULL,
	[ModeAllowedAmountDifference] [decimal](18, 4) NULL,
	[ModeInsurancePaidDifference] [decimal](18, 4) NULL,
	[MedianAllowedAmountDifference] [decimal](18, 4) NULL,
	[MedianInsurancePaidDifference] [decimal](18, 4) NULL,
	[DenialRate] [decimal](18, 4) NULL,
	[AdjustmentRate] [decimal](18, 4) NULL,
	[PaymentDays] [int] NULL,
	[ExpectedPaymentDate] [date] NULL,
	[ExpectedPaymentMonth] [nvarchar](255) NULL,
	[BillingProvider] [nvarchar](255) NULL,
	[ReferringProvider] [nvarchar](255) NULL,
	[ClinicName] [nvarchar](255) NULL,
	[SalesRepname] [nvarchar](255) NULL,
	[PatientID] [nvarchar](150) NULL,
	[ChargeEnteredDate] [date] NULL,
	[POS] [nvarchar](150) NULL,
	[TOS] [nvarchar](150) NULL,
	[CheckDate] [date] NULL,
	[DaystoDOS] [int] NULL,
	[RollingDays] [nvarchar](50) NULL,
	[DaystoBill] [int] NULL,
	[DaystoPost] [int] NULL,
	[DenialClassification] [nvarchar](255) NULL,
	[DenialType] [nvarchar](255) NULL,
	[ActionCategory] [nvarchar](255) NULL,
	[ActionCode] [nvarchar](255) NULL,
	[RecommendedAction] [nvarchar](1500) NULL,
	[TaskGuidance] [nvarchar](1500) NULL,
	[TaskStatus] [nvarchar](255) NULL,
	[ShortCategory] [nvarchar](255) NULL,
	[Priority] [nvarchar](255) NULL,
	[SLADays] [nvarchar](255) NULL,
	[NotesComments] [nvarchar](max) NULL,
	[LabId] [int] NULL,
	[RunId] [nvarchar](255) NULL,
	[CreatedOn] [datetime] NULL,
	[DenialDate] [date] NULL,
	[PatientName] [nvarchar](255) NULL,
	[ClaimUID] [nvarchar](150) NULL,
	[AssignedTo] [nvarchar](150) NULL,
	[WorkFlowStatus] [nvarchar](150) NULL,
	[ClaimFrom] [nvarchar](150) NULL,
	[Source] [nvarchar](50) NULL,
	[PatName] [nvarchar](250) NULL,
	[SubscriberId] [nvarchar](50) NULL,
	[VisitNumberNormalized]  AS (CONVERT([varchar](150),replace(ltrim(rtrim(isnull([VisitNumber],''))),'CLM-',''))) PERSISTED
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialMapperAuditLog]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialMapperAuditLog](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[EventType] [nvarchar](100) NOT NULL,
	[LabId] [int] NULL,
	[SuperMasterId] [bigint] NULL,
	[DenialCode] [nvarchar](50) NULL,
	[FieldName] [nvarchar](100) NULL,
	[FromValue] [nvarchar](max) NULL,
	[ToValue] [nvarchar](max) NULL,
	[PerformedBy] [nvarchar](200) NOT NULL,
	[PerformedRole] [nvarchar](100) NOT NULL,
	[PerformedOn] [datetime2](7) NOT NULL,
	[Remarks] [nvarchar](1000) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialMapperLabMaster]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialMapperLabMaster](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[LabId] [int] NOT NULL,
	[SuperMasterId] [bigint] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[PushedBy] [nvarchar](200) NOT NULL,
	[PushedOn] [datetime2](7) NOT NULL,
	[CreatedBy] [nvarchar](200) NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[ModifiedBy] [nvarchar](200) NOT NULL,
	[ModifiedOn] [datetime2](7) NOT NULL,
	[DenialCode] [nvarchar](50) NULL,
	[DenialDescription] [nvarchar](500) NULL,
	[DenialClassification] [nvarchar](100) NULL,
	[CoverageStatus] [nvarchar](100) NULL,
	[ICDComplianceStatus] [nvarchar](100) NULL,
	[DenialValidity] [nvarchar](100) NULL,
	[ActionCode] [nvarchar](100) NULL,
	[ActionCategory] [nvarchar](100) NULL,
	[Task] [nvarchar](300) NULL,
	[RecommendedAction] [nvarchar](1000) NULL,
	[SLA] [nvarchar](50) NULL,
	[Priority] [nvarchar](50) NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY],
 CONSTRAINT [UQ_DenialMapperLabMaster] UNIQUE NONCLUSTERED 
(
	[LabId] ASC,
	[SuperMasterId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialMapperLabOverride]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialMapperLabOverride](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[LabId] [int] NOT NULL,
	[SuperMasterId] [bigint] NOT NULL,
	[ActionCode] [nvarchar](100) NOT NULL,
	[ActionCategory] [nvarchar](100) NOT NULL,
	[Task] [nvarchar](300) NOT NULL,
	[RecommendedAction] [nvarchar](1000) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedBy] [nvarchar](200) NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[ModifiedBy] [nvarchar](200) NOT NULL,
	[ModifiedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialMapperPushAudit]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialMapperPushAudit](
	[PushAuditId] [bigint] IDENTITY(1,1) NOT NULL,
	[SourceLabId] [int] NOT NULL,
	[TargetLabId] [int] NOT NULL,
	[PushedByUserId] [nvarchar](100) NOT NULL,
	[PushStatus] [nvarchar](50) NOT NULL,
	[TotalCompared] [int] NOT NULL,
	[TotalDifferences] [int] NOT NULL,
	[TotalAssignedOpenTasksAffected] [int] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[ConfirmedOn] [datetime2](7) NULL,
	[ConfirmedByUserId] [nvarchar](100) NULL,
	[CancelledOn] [datetime2](7) NULL,
	[CancelledByUserId] [nvarchar](100) NULL,
	[AcknowledgedOn] [datetime2](7) NULL,
	[AcknowledgedByUserId] [nvarchar](100) NULL,
	[FailureMessage] [nvarchar](2000) NULL,
 CONSTRAINT [PK_DenialMapperPushAudit] PRIMARY KEY CLUSTERED 
(
	[PushAuditId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialMapperPushAuditDetail]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialMapperPushAuditDetail](
	[PushAuditDetailId] [bigint] IDENTITY(1,1) NOT NULL,
	[PushAuditId] [bigint] NOT NULL,
	[TargetLabId] [int] NOT NULL,
	[DenialCode] [nvarchar](100) NOT NULL,
	[ICDComplianceStatus] [nvarchar](255) NULL,
	[CoverageStatus] [nvarchar](255) NULL,
	[ExistingActionCode] [nvarchar](255) NULL,
	[NewActionCode] [nvarchar](255) NULL,
	[ExistingActionCategory] [nvarchar](500) NULL,
	[NewActionCategory] [nvarchar](500) NULL,
	[ExistingTask] [nvarchar](500) NULL,
	[NewTask] [nvarchar](500) NULL,
	[ExistingShortCategory] [nvarchar](1000) NULL,
	[NewShortCategory] [nvarchar](1000) NULL,
	[ExistingDenialClassification] [nvarchar](255) NULL,
	[NewDenialClassification] [nvarchar](255) NULL,
	[DifferenceType] [nvarchar](255) NOT NULL,
	[IsAssignedToOpenTask] [bit] NOT NULL,
	[OpenAssignedTaskCount] [int] NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
 CONSTRAINT [PK_DenialMapperPushAuditDetail] PRIMARY KEY CLUSTERED 
(
	[PushAuditDetailId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialMapperSuperMaster]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialMapperSuperMaster](
	[Id] [bigint] IDENTITY(1,1) NOT NULL,
	[DenialCode] [nvarchar](50) NOT NULL,
	[DenialDescription] [nvarchar](500) NULL,
	[DenialClassification] [nvarchar](100) NULL,
	[CoverageStatus] [nvarchar](100) NULL,
	[ICDComplianceStatus] [nvarchar](100) NULL,
	[DenialValidity] [nvarchar](100) NULL,
	[ActionCode] [nvarchar](100) NOT NULL,
	[ActionCategory] [nvarchar](100) NOT NULL,
	[Task] [nvarchar](300) NOT NULL,
	[RecommendedAction] [nvarchar](1000) NOT NULL,
	[SLA] [nvarchar](50) NOT NULL,
	[Priority] [nvarchar](50) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedBy] [nvarchar](200) NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
	[ModifiedBy] [nvarchar](200) NOT NULL,
	[ModifiedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialStatusMaster]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialStatusMaster](
	[StatusId] [int] IDENTITY(1,1) NOT NULL,
	[StatusName] [nvarchar](100) NOT NULL,
	[IsClosedStatus] [bit] NOT NULL,
	[IsVerificationStatus] [bit] NOT NULL,
	[SortOrder] [int] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[CreatedOn] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_DenialStatusMaster] PRIMARY KEY CLUSTERED 
(
	[StatusId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY],
 CONSTRAINT [UQ_DenialStatusMaster_StatusName] UNIQUE NONCLUSTERED 
(
	[StatusName] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialTaskBoard]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialTaskBoard](
	[TaskID] [nvarchar](100) NULL,
	[ClaimID] [nvarchar](100) NULL,
	[PatientId] [nvarchar](100) NULL,
	[CPTCode] [nvarchar](50) NULL,
	[DenialCode] [nvarchar](100) NULL,
	[DenialDescription] [nvarchar](500) NULL,
	[DenialClassification] [nvarchar](255) NULL,
	[ActionCode] [nvarchar](100) NULL,
	[RecommendedAction] [nvarchar](500) NULL,
	[ActionCategory] [nvarchar](500) NULL,
	[Task] [nvarchar](500) NULL,
	[Priority] [nvarchar](100) NULL,
	[InsuranceBalance] [decimal](18, 2) NOT NULL,
	[IsCurrentDenial] [bit] NULL,
	[SLADays] [int] NULL,
	[Status] [nvarchar](100) NULL,
	[DateOpened] [date] NULL,
	[DueDate] [date] NULL,
	[DateCompleted] [date] NULL,
	[DaysRemaining] [int] NULL,
	[SLAStatus] [nvarchar](100) NULL,
	[AssignedTo] [nvarchar](255) NULL,
	[LabId] [int] NULL,
	[LabName] [nvarchar](255) NULL,
	[RunId] [nvarchar](100) NULL,
	[CreatedOn] [datetime2](0) NULL,
	[UniqueTrackId] [nvarchar](150) NULL,
	[SalesRepname] [nvarchar](255) NULL,
	[ClinicName] [nvarchar](255) NULL,
	[ReferringProvider] [nvarchar](255) NULL,
	[PayerName] [nvarchar](255) NULL,
	[PayerNameNormalized] [nvarchar](255) NULL,
	[PayerCode] [int] NULL,
	[PayerType] [nvarchar](255) NULL,
	[FirstBilledDate] [date] NULL,
	[ChargeEnteredDate] [date] NULL,
	[BillingProvider] [nvarchar](255) NULL,
	[PanelName] [nvarchar](255) NULL,
	[DateOfService] [date] NULL,
	[ReviewerComments] [nvarchar](max) NULL,
	[ReviewerUpdatedOn] [datetime2](0) NULL,
	[ReviewerUpdatedBy] [nvarchar](255) NULL,
	[ICDCodes] [nvarchar](max) NULL,
	[CoverageStatus] [nvarchar](200) NULL,
	[ICDComplianceStatus] [nvarchar](200) NULL,
	[DenialValidity] [nvarchar](max) NULL,
	[Units] [int] NULL,
	[Modifier] [nvarchar](255) NULL,
	[ClaimIDNormalized]  AS (CONVERT([varchar](50),replace([ClaimID],'CLM-',''))) PERSISTED,
	[ClaimUID] [nvarchar](150) NULL,
	[WorkFlowStatus] [nvarchar](150) NULL,
	[ClaimFrom] [nvarchar](150) NULL,
	[Source] [nvarchar](50) NULL,
	[PatName] [nvarchar](250) NULL,
	[SubscriberId] [nvarchar](50) NULL,
	[ShortCategory] [nvarchar](255) NULL,
	[AssignedOn] [datetime2](7) NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialTaskHistory]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialTaskHistory](
	[HistoryId] [bigint] IDENTITY(1,1) NOT NULL,
	[TaskID] [nvarchar](100) NULL,
	[UniqueTrackId] [nvarchar](150) NULL,
	[ActionType] [nvarchar](100) NOT NULL,
	[OldStatus] [nvarchar](100) NULL,
	[NewStatus] [nvarchar](100) NULL,
	[OldAssignedTo] [nvarchar](255) NULL,
	[NewAssignedTo] [nvarchar](255) NULL,
	[Comments] [nvarchar](max) NULL,
	[ActionBy] [nvarchar](255) NULL,
	[ActionDate] [datetime2](0) NOT NULL,
	[RunId] [nvarchar](100) NULL,
	[SnapshotJson] [nvarchar](max) NULL,
	[LabId] [int] NULL,
	[LabName] [nvarchar](255) NULL,
 CONSTRAINT [PK_DenialTaskHistory] PRIMARY KEY CLUSTERED 
(
	[HistoryId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialVerification]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialVerification](
	[DenialVerificationId] [int] IDENTITY(1,1) NOT NULL,
	[ClaimUID] [nvarchar](600) NOT NULL,
	[TaskID] [nvarchar](100) NULL,
	[ClaimID] [nvarchar](100) NULL,
	[UniqueTrackId] [nvarchar](450) NULL,
	[LabId] [int] NOT NULL,
	[LabName] [nvarchar](200) NULL,
	[RunId] [nvarchar](100) NULL,
	[AssignedTo] [nvarchar](200) NULL,
	[Status] [nvarchar](100) NULL,
	[VerificationStatus] [nvarchar](100) NOT NULL,
	[CreatedOn] [datetime2](7) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[DenialVerificationId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO
/****** Object:  Table [dbo].[DenialVerificationTask]    Script Date: 07/21/2026 10:17:27 pm ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[DenialVerificationTask](
	[VerificationId] [bigint] IDENTITY(1,1) NOT NULL,
	[TaskID] [nvarchar](100) NULL,
	[UniqueTrackId] [nvarchar](150) NULL,
	[ClaimID] [nvarchar](100) NULL,
	[PatientId] [nvarchar](100) NULL,
	[CPTCode] [nvarchar](50) NULL,
	[DenialCode] [nvarchar](100) NULL,
	[DenialDescription] [nvarchar](500) NULL,
	[ActionCategory] [nvarchar](500) NULL,
	[RecommendedAction] [nvarchar](500) NULL,
	[Task] [nvarchar](500) NULL,
	[Priority] [nvarchar](100) NULL,
	[InsuranceBalance] [decimal](18, 2) NOT NULL,
	[Status] [nvarchar](100) NULL,
	[DateOpened] [date] NULL,
	[DueDate] [date] NULL,
	[DateCompleted] [date] NULL,
	[DaysRemaining] [int] NULL,
	[SLAStatus] [nvarchar](100) NULL,
	[AssignedTo] [nvarchar](255) NULL,
	[LabId] [int] NULL,
	[LabName] [nvarchar](255) NULL,
	[RunId] [nvarchar](100) NULL,
	[CreatedOn] [datetime2](0) NULL,
	[PayerName] [nvarchar](255) NULL,
	[PayerNameNormalized] [nvarchar](255) NULL,
	[ReviewerComments] [nvarchar](max) NULL,
	[ReviewerUpdatedOn] [datetime2](0) NULL,
	[ReviewerUpdatedBy] [nvarchar](255) NULL,
	[VerificationStatus] [nvarchar](100) NOT NULL,
	[VerificationComments] [nvarchar](max) NULL,
	[OriginalRunId] [nvarchar](100) NULL,
	[MissingDetectedRunId] [nvarchar](100) NULL,
	[MovedOn] [datetime2](0) NOT NULL,
	[VerifiedBy] [nvarchar](255) NULL,
	[VerifiedOn] [datetime2](0) NULL,
 CONSTRAINT [PK_DenialVerificationTask] PRIMARY KEY CLUSTERED 
(
	[VerificationId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialClaimDocuments_Claim]    Script Date: 07/21/2026 10:17:27 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClaimDocuments_Claim] ON [dbo].[DenialClaimDocuments]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[UploadedOn] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialClaimEscalations_Claim]    Script Date: 07/21/2026 10:17:27 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClaimEscalations_Claim] ON [dbo].[DenialClaimEscalations]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[EscalationLevel] ASC,
	[CreatedOn] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialClaimEscalations_FollowUp]    Script Date: 07/21/2026 10:17:27 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClaimEscalations_FollowUp] ON [dbo].[DenialClaimEscalations]
(
	[LabId] ASC,
	[EscalationLevel] ASC,
	[Status] ASC,
	[NextFollowUpDate] ASC,
	[CreatedOn] DESC
)
INCLUDE([ClaimId],[TaskId],[CptCode],[EscalationReason],[EscalatedTo],[EscalatedToRole],[CreatedBy]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialClaimEscalations_Line]    Script Date: 07/21/2026 10:17:27 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClaimEscalations_Line] ON [dbo].[DenialClaimEscalations]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[TaskId] ASC,
	[CptCode] ASC,
	[CreatedOn] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_Escalations_Lab_Claim_Active]    Script Date: 07/21/2026 10:17:27 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_Escalations_Lab_Claim_Active] ON [dbo].[DenialClaimEscalations]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[IsDeleted] ASC
)
INCLUDE([Comments],[CreatedBy],[CreatedOn],[EscalatedTo],[EscalatedToRole],[EscalationId],[EscalationLevel],[EscalationReason],[NextFollowUpDate],[Status]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF, DATA_COMPRESSION = PAGE) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_Escalations_Lab_Claim_Status_Role]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_Escalations_Lab_Claim_Status_Role] ON [dbo].[DenialClaimEscalations]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[Status] ASC,
	[EscalatedToRole] ASC
)
INCLUDE([IsDeleted],[EscalatedTo],[NextFollowUpDate],[EscalationReason],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialClaimNotes_Claim]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClaimNotes_Claim] ON [dbo].[DenialClaimNotes]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[NoteLevel] ASC,
	[CreatedOn] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  Index [IX_DenialClaimNotes_FollowUpNotification]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClaimNotes_FollowUpNotification] ON [dbo].[DenialClaimNotes]
(
	[LabId] ASC,
	[NextFollowUpDate] ASC,
	[IsDeleted] ASC
)
INCLUDE([ClaimId],[TaskId],[CptCode],[Status],[FollowUpReason],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialClaimNotes_Line]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClaimNotes_Line] ON [dbo].[DenialClaimNotes]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[TaskId] ASC,
	[CptCode] ASC,
	[CreatedOn] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [IX_DenialClaimNotes_Normalized]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClaimNotes_Normalized] ON [dbo].[DenialClaimNotes]
(
	[LabId] ASC,
	[NoteLevel] ASC,
	[ClaimIdNormalized] ASC,
	[CreatedOn] DESC
)
INCLUDE([TaskId],[CptCode],[IsDeleted]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_Notes_Lab_Claim_Followup]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_Notes_Lab_Claim_Followup] ON [dbo].[DenialClaimNotes]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[NextFollowUpDate] ASC
)
INCLUDE([IsDeleted],[NoteLevel],[Status],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  Index [IX_DenialClosedClaims_Lab_ClosedOn]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClosedClaims_Lab_ClosedOn] ON [dbo].[DenialClosedClaims]
(
	[LabId] ASC,
	[ClosedOn] DESC
)
INCLUDE([ClaimId],[AssignedTo],[WorkFlowStatus],[InsuranceBalance]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [UX_DenialClosedClaims_Lab_Claim]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE UNIQUE NONCLUSTERED INDEX [UX_DenialClosedClaims_Lab_Claim] ON [dbo].[DenialClosedClaims]
(
	[LabId] ASC,
	[ClaimId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialClosedClaimsHistory_Lab_Claim]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialClosedClaimsHistory_Lab_Claim] ON [dbo].[DenialClosedClaimsHistory]
(
	[LabId] ASC,
	[ClaimId] ASC,
	[ActionDate] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DCACV_Batch_Status]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DCACV_Batch_Status] ON [dbo].[DenialCodeActionChangeVerification]
(
	[BatchId] ASC,
	[VerificationStatus] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DCACV_Claim_Task]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DCACV_Claim_Task] ON [dbo].[DenialCodeActionChangeVerification]
(
	[ClaimID] ASC,
	[TaskID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DCACV_Denial_Key]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DCACV_Denial_Key] ON [dbo].[DenialCodeActionChangeVerification]
(
	[DenialCode] ASC,
	[ICDComplianceStatus] ASC,
	[CoverageStatus] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialCodeMaster_Action]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialCodeMaster_Action] ON [dbo].[DenialCodeMaster]
(
	[ActionCode] ASC,
	[ActionCategory] ASC
)
INCLUDE([DenialClassification],[CoverageStatus],[Task]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialCodeMaster_Classification]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialCodeMaster_Classification] ON [dbo].[DenialCodeMaster]
(
	[DenialClassification] ASC,
	[CoverageStatus] ASC
)
INCLUDE([ActionCode],[ActionCategory],[Priority],[SLADays]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialCodeMaster_Lookups]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialCodeMaster_Lookups] ON [dbo].[DenialCodeMaster]
(
	[DenialValidity] ASC,
	[ICDComplianceStatus] ASC,
	[Task] ASC
)
INCLUDE([DenialClassification],[CoverageStatus],[ActionCode],[ActionCategory]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialInsight_Assignment]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialInsight_Assignment] ON [dbo].[DenialInsight]
(
	[LabId] ASC,
	[RunId] ASC,
	[DenialCodes] ASC,
	[HighImpactInsurance] ASC
)
INCLUDE([AssignedTo],[ResponsibilityReviewer]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialInsight_Lab_Filter]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialInsight_Lab_Filter] ON [dbo].[DenialInsight]
(
	[LabId] ASC,
	[DenialCodes] ASC,
	[HighImpactInsurance] ASC,
	[RunId] ASC
)
INCLUDE([AssignedTo],[InsuranceBalance],[CreatedOn],[ActionCategory],[ActionCode]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialInsight_Lab_Paging]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialInsight_Lab_Paging] ON [dbo].[DenialInsight]
(
	[LabId] ASC,
	[InsuranceBalance] DESC,
	[DenialCodes] ASC
)
INCLUDE([RunId],[CreatedOn],[AssignedTo],[ResponsibilityReviewer],[HighImpactInsurance],[ActionCategory],[ActionCode],[NoOfDenialCount],[NoOfClaimsCount],[TotalBalance],[ImpactPercentage],[LabName]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialInsight_Workflow_Page]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialInsight_Workflow_Page] ON [dbo].[DenialInsight]
(
	[LabId] ASC,
	[DenialCodes] ASC,
	[HighImpactInsurance] ASC,
	[RunId] ASC
)
INCLUDE([InsuranceBalance],[ImpactPercentage],[NoOfDenialCount],[NoOfClaimsCount]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialLineItem_ClaimAssignment_Page]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_ClaimAssignment_Page] ON [dbo].[DenialLineItem]
(
	[DateOfService] DESC,
	[VisitNumber] ASC
)
INCLUDE([PayerName],[PanelName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance],[DenialCodeNormalized],[ActionCategory],[DenialClassification]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialLineItem_Lab_Filters]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_Lab_Filters] ON [dbo].[DenialLineItem]
(
	[LabId] ASC,
	[PayerNameNormalized] ASC,
	[DenialCodeNormalized] ASC
)
INCLUDE([VisitNumber],[ClinicName],[SalesRepname],[ReferringProvider],[DateOfService],[ActionCategory],[DenialClassification]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialLineItem_Lab_Visit_SLA]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_Lab_Visit_SLA] ON [dbo].[DenialLineItem]
(
	[LabId] ASC,
	[VisitNumber] ASC
)
INCLUDE([SLADays],[CPTCode]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialLineItem_Lab_VisitNumber]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_Lab_VisitNumber] ON [dbo].[DenialLineItem]
(
	[LabId] ASC,
	[VisitNumber] ASC
)
INCLUDE([PatientName],[PatientDOB],[PatientID],[ClinicName],[SalesRepname],[ReferringProvider],[PayerName],[PayerNameNormalized],[DateOfService],[DenialCodeNormalized],[ActionCategory],[DenialClassification],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialLineItem_VisitNumber_ClaimView]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_VisitNumber_ClaimView] ON [dbo].[DenialLineItem]
(
	[VisitNumber] ASC,
	[DateOfService] ASC
)
INCLUDE([PayerNameNormalized],[PanelName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [IX_DenialLineItem_VisitNumberNormalized]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialLineItem_VisitNumberNormalized] ON [dbo].[DenialLineItem]
(
	[VisitNumberNormalized] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Assigned_Status_Lab]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Assigned_Status_Lab] ON [dbo].[DenialLineItem]
(
	[AssignedTo] ASC,
	[TaskStatus] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_AssignedTo]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_AssignedTo] ON [dbo].[DenialLineItem]
(
	[AssignedTo] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DLI_Filtered]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DLI_Filtered] ON [dbo].[DenialLineItem]
(
	[VisitNumber] ASC
)
INCLUDE([DenialDescription],[DenialDate]) 
WHERE ([DenialCodeOriginal] IS NOT NULL AND [DenialCodeOriginal]<>'')
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DLI_VisitNumber_Fast]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DLI_VisitNumber_Fast] ON [dbo].[DenialLineItem]
(
	[VisitNumber] ASC
)
INCLUDE([DenialCodeOriginal],[DenialDescription],[DenialDate]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_LineItem_ClaimUID_ClaimView]    Script Date: 07/21/2026 10:17:28 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_ClaimUID_ClaimView] ON [dbo].[DenialLineItem]
(
	[ClaimUID] ASC,
	[DateOfService] DESC
)
INCLUDE([ActionCategory],[AssignedTo],[ClinicName],[DenialClassification],[DenialCodeNormalized],[InsuranceBalance],[PanelName],[PatientDOB],[PatientID],[PatientName],[PayerName],[PayerNameNormalized],[ReferringProvider],[SalesRepname],[WorkFlowStatus]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF, DATA_COMPRESSION = PAGE) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_LineItem_DOS_ClaimUID_Page]    Script Date: 07/21/2026 10:17:29 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_DOS_ClaimUID_Page] ON [dbo].[DenialLineItem]
(
	[DateOfService] DESC,
	[ClaimUID] ASC
)
INCLUDE([ActionCategory],[AssignedTo],[ClinicName],[DenialClassification],[DenialCodeNormalized],[InsuranceBalance],[PanelName],[PatientDOB],[PatientID],[PatientName],[PayerName],[PayerNameNormalized],[ReferringProvider],[SalesRepname],[WorkFlowStatus]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF, DATA_COMPRESSION = PAGE) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_LineItem_Lab_ClaimUID_DOS]    Script Date: 07/21/2026 10:17:29 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_Lab_ClaimUID_DOS] ON [dbo].[DenialLineItem]
(
	[LabId] ASC,
	[ClaimUID] ASC,
	[DateOfService] DESC
)
INCLUDE([VisitNumber],[PayerName],[PanelName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance],[DenialCodeNormalized],[ActionCategory],[DenialClassification]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_LineItem_Lab_Code_Payer]    Script Date: 07/21/2026 10:17:29 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_Lab_Code_Payer] ON [dbo].[DenialLineItem]
(
	[LabId] ASC,
	[DenialCodeNormalized] ASC,
	[PayerNameNormalized] ASC
)
INCLUDE([VisitNumber],[DateOfService],[ClinicName],[ReferringProvider],[PatientID],[PatientName],[PatientDOB],[PanelName],[SalesRepname],[InsuranceBalance],[DenialClassification],[ActionCategory]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  Index [IX_DWF_LineItem_Lab_DOS]    Script Date: 07/21/2026 10:17:29 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_Lab_DOS] ON [dbo].[DenialLineItem]
(
	[LabId] ASC,
	[DateOfService] DESC
)
INCLUDE([VisitNumber],[PayerNameNormalized],[PanelName],[PatientName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance],[DenialCodeNormalized],[DenialClassification],[ActionCategory]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_LineItem_Lab_DOS_Visit_Page]    Script Date: 07/21/2026 10:17:29 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_Lab_DOS_Visit_Page] ON [dbo].[DenialLineItem]
(
	[LabId] ASC,
	[DateOfService] DESC,
	[VisitNumber] ASC
)
INCLUDE([PayerName],[PanelName],[PatientDOB],[ClinicName],[ReferringProvider],[PatientID],[SalesRepname],[InsuranceBalance],[DenialCodeNormalized],[ActionCategory],[DenialClassification]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_LineItem_VisitNumber_ClaimView_Fallback]    Script Date: 07/21/2026 10:17:29 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_LineItem_VisitNumber_ClaimView_Fallback] ON [dbo].[DenialLineItem]
(
	[VisitNumber] ASC,
	[DateOfService] DESC
)
INCLUDE([ActionCategory],[AssignedTo],[ClinicName],[DenialClassification],[DenialCodeNormalized],[InsuranceBalance],[PanelName],[PatientDOB],[PatientID],[PatientName],[PayerName],[PayerNameNormalized],[ReferringProvider],[SalesRepname],[WorkFlowStatus]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF, DATA_COMPRESSION = PAGE) ON [PRIMARY]
GO
/****** Object:  Index [IX_DenialMapperAuditLog_LabDate]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialMapperAuditLog_LabDate] ON [dbo].[DenialMapperAuditLog]
(
	[LabId] ASC,
	[PerformedOn] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  Index [UX_DenialMapperLabOverride_Active]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE UNIQUE NONCLUSTERED INDEX [UX_DenialMapperLabOverride_Active] ON [dbo].[DenialMapperLabOverride]
(
	[LabId] ASC,
	[SuperMasterId] ASC
)
WHERE ([IsActive]=(1))
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialMapperPushAudit_Status_TargetLab]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialMapperPushAudit_Status_TargetLab] ON [dbo].[DenialMapperPushAudit]
(
	[TargetLabId] ASC,
	[PushStatus] ASC,
	[CreatedOn] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialMapperPushAuditDetail_Code_Key]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialMapperPushAuditDetail_Code_Key] ON [dbo].[DenialMapperPushAuditDetail]
(
	[TargetLabId] ASC,
	[DenialCode] ASC,
	[ICDComplianceStatus] ASC,
	[CoverageStatus] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  Index [IX_DenialMapperPushAuditDetail_PushAuditId]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialMapperPushAuditDetail_PushAuditId] ON [dbo].[DenialMapperPushAuditDetail]
(
	[PushAuditId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [UX_DenialMapperSuperMaster_Key]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE UNIQUE NONCLUSTERED INDEX [UX_DenialMapperSuperMaster_Key] ON [dbo].[DenialMapperSuperMaster]
(
	[DenialCode] ASC,
	[DenialClassification] ASC,
	[CoverageStatus] ASC,
	[ICDComplianceStatus] ASC
)
WHERE ([IsActive]=(1))
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_AssignedOn]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_AssignedOn] ON [dbo].[DenialTaskBoard]
(
	[AssignedOn] ASC,
	[AssignedTo] ASC
)
INCLUDE([ClaimID],[TaskID],[CPTCode],[Status]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_AssignedTo]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_AssignedTo] ON [dbo].[DenialTaskBoard]
(
	[AssignedTo] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Assignment]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Assignment] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[RunId] ASC,
	[DenialCode] ASC,
	[PayerNameNormalized] ASC,
	[AssignedTo] ASC
)
INCLUDE([TaskID],[Status],[PayerName]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [IX_DenialTaskBoard_ClaimAssignment_Status]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_ClaimAssignment_Status] ON [dbo].[DenialTaskBoard]
(
	[ClaimIDNormalized] ASC
)
INCLUDE([TaskID],[Status],[AssignedTo],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [IX_DenialTaskBoard_ClaimIDNormalized]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_ClaimIDNormalized] ON [dbo].[DenialTaskBoard]
(
	[ClaimIDNormalized] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_ActionCategory]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_ActionCategory] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[ActionCategory] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_AssignLookup]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_AssignLookup] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[DenialCode] ASC,
	[PayerName] ASC,
	[RunId] ASC
)
INCLUDE([AssignedTo],[Status],[TaskID],[ReviewerUpdatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_ClaimID]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_ClaimID] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[ClaimID] ASC
)
INCLUDE([TaskID],[CPTCode],[DenialCode],[DenialDescription],[InsuranceBalance],[DenialClassification],[ActionCode],[RecommendedAction],[ActionCategory],[SLADays],[Status],[AssignedTo],[CoverageStatus],[ICDCodes],[ICDComplianceStatus],[DenialValidity]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_DenialCode]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_DenialCode] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[DenialCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_PayerName]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_PayerName] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[PayerName] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_Priority]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_Priority] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[Priority] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_Queue]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_Queue] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[AssignedTo] ASC,
	[Status] ASC,
	[DueDate] ASC,
	[TaskID] ASC
)
INCLUDE([RunId],[UniqueTrackId],[ClaimID],[PatientId],[CPTCode],[DenialCode],[DenialClassification],[ActionCategory],[Priority],[InsuranceBalance],[PayerName],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_Status]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_Status] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[Status] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Lab_UID]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Lab_UID] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[UniqueTrackId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Status_AssignedTo]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Status_AssignedTo] ON [dbo].[DenialTaskBoard]
(
	[Status] ASC,
	[AssignedTo] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [IX_DenialTaskBoard_TaskView_ClaimIDNormalized]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_TaskView_ClaimIDNormalized] ON [dbo].[DenialTaskBoard]
(
	[Status] ASC,
	[AssignedTo] ASC,
	[ClaimIDNormalized] ASC
)
INCLUDE([TaskID],[UniqueTrackId],[CPTCode],[SLAStatus],[DueDate],[InsuranceBalance],[DenialCode],[DenialClassification],[ActionCategory]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Workflow_Active]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Workflow_Active] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[Status] ASC,
	[AssignedTo] ASC,
	[UniqueTrackId] ASC
)
INCLUDE([TaskID],[RunId],[ClaimID],[CPTCode],[DenialCode],[DueDate]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Workflow_ClaimAction]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Workflow_ClaimAction] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[ClaimID] ASC,
	[ActionCategory] ASC
)
INCLUDE([TaskID],[Status],[AssignedTo]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Workflow_Page]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Workflow_Page] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[Status] ASC,
	[AssignedTo] ASC,
	[DueDate] ASC,
	[TaskID] ASC
)
INCLUDE([ClaimID],[CPTCode],[DenialCode],[PayerName],[RunId],[InsuranceBalance]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskBoard_Workflow_Search]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskBoard_Workflow_Search] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[DenialCode] ASC,
	[PayerName] ASC,
	[RunId] ASC
)
INCLUDE([TaskID],[ClaimID],[AssignedTo],[Status],[InsuranceBalance]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_ClaimIDNormalized_StatusAgg] ON [dbo].[DenialTaskBoard]
(
	[ClaimIDNormalized] ASC,
	[Status] ASC,
	[AssignedTo] ASC,
	[CreatedOn] ASC
)
INCLUDE([ActionCategory],[ActionCode],[BillingProvider],[ChargeEnteredDate],[ClaimID],[ClinicName],[CoverageStatus],[DateCompleted],[DateOfService],[DateOpened],[DaysRemaining],[DenialClassification],[DenialCode],[DenialDescription],[DenialValidity],[DueDate],[FirstBilledDate],[ICDCodes],[ICDComplianceStatus],[InsuranceBalance],[IsCurrentDenial],[LabId],[LabName],[Modifier],[PanelName],[PatientId],[PayerCode],[PayerName],[PayerType],[Priority],[RecommendedAction],[ReferringProvider],[ReviewerComments],[ReviewerUpdatedBy],[ReviewerUpdatedOn],[RunId],[SalesRepname],[SLADays],[SLAStatus],[Task],[UniqueTrackId],[Units],[WorkFlowStatus]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF, DATA_COMPRESSION = PAGE) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_TaskBoard_ClaimUID_Drill]    Script Date: 07/21/2026 10:17:30 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_ClaimUID_Drill] ON [dbo].[DenialTaskBoard]
(
	[ClaimUID] ASC,
	[CPTCode] ASC,
	[TaskID] ASC
)
INCLUDE([ActionCategory],[ActionCode],[BillingProvider],[ChargeEnteredDate],[ClaimID],[ClinicName],[CoverageStatus],[DateCompleted],[DateOfService],[DateOpened],[DaysRemaining],[DenialClassification],[DenialCode],[DenialDescription],[DenialValidity],[DueDate],[FirstBilledDate],[ICDCodes],[ICDComplianceStatus],[InsuranceBalance],[IsCurrentDenial],[LabId],[LabName],[Modifier],[PanelName],[PatientId],[PayerCode],[PayerName],[PayerType],[Priority],[RecommendedAction],[ReferringProvider],[ReviewerComments],[ReviewerUpdatedBy],[ReviewerUpdatedOn],[RunId],[SalesRepname],[SLADays],[SLAStatus],[Task],[UniqueTrackId],[Units],[WorkFlowStatus]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF, DATA_COMPRESSION = PAGE) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_TaskBoard_ClaimUID_StatusAgg]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_ClaimUID_StatusAgg] ON [dbo].[DenialTaskBoard]
(
	[ClaimUID] ASC
)
INCLUDE([ActionCategory],[ActionCode],[AssignedTo],[BillingProvider],[ChargeEnteredDate],[ClaimID],[ClinicName],[CoverageStatus],[CreatedOn],[DateCompleted],[DateOfService],[DateOpened],[DaysRemaining],[DenialClassification],[DenialCode],[DenialDescription],[DenialValidity],[DueDate],[FirstBilledDate],[ICDCodes],[ICDComplianceStatus],[InsuranceBalance],[IsCurrentDenial],[LabId],[LabName],[Modifier],[PanelName],[PatientId],[PayerCode],[PayerName],[PayerType],[Priority],[RecommendedAction],[ReferringProvider],[ReviewerComments],[ReviewerUpdatedBy],[ReviewerUpdatedOn],[RunId],[SalesRepname],[SLADays],[SLAStatus],[Status],[Task],[UniqueTrackId],[Units],[WorkFlowStatus]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF, DATA_COMPRESSION = PAGE) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_TaskBoard_Lab_Claim]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Claim] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[ClaimID] ASC
)
INCLUDE([TaskID],[UniqueTrackId],[CPTCode],[DenialCode],[DenialClassification],[ActionCategory],[Priority],[Status],[AssignedTo],[InsuranceBalance],[DueDate],[DateOfService],[PayerName],[PayerNameNormalized]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [IX_DWF_TaskBoard_Lab_Claim_Status_Assigned]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Claim_Status_Assigned] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[ClaimIDNormalized] ASC,
	[Status] ASC,
	[AssignedTo] ASC
)
INCLUDE([TaskID],[ClaimID],[CreatedOn],[ReviewerUpdatedOn],[WorkFlowStatus]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_TaskBoard_Lab_ClaimUID_Status]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_ClaimUID_Status] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[ClaimUID] ASC,
	[Status] ASC,
	[AssignedTo] ASC,
	[CreatedOn] ASC
)
INCLUDE([TaskID],[ClaimIDNormalized],[CPTCode],[SLAStatus],[WorkFlowStatus],[InsuranceBalance],[DenialClassification],[ActionCategory]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_TaskBoard_Lab_Class_Action]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Class_Action] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[DenialClassification] ASC,
	[ActionCategory] ASC
)
INCLUDE([Status],[AssignedTo],[DueDate],[TaskID],[ClaimID],[DenialCode],[Priority],[InsuranceBalance],[PayerName],[PayerNameNormalized],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_TaskBoard_Lab_Code_Payer]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Code_Payer] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[DenialCode] ASC,
	[PayerNameNormalized] ASC
)
INCLUDE([Status],[AssignedTo],[DueDate],[TaskID],[ClaimID],[DenialClassification],[ActionCategory],[Priority],[InsuranceBalance],[PayerName],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ARITHABORT ON
SET CONCAT_NULL_YIELDS_NULL ON
SET QUOTED_IDENTIFIER ON
SET ANSI_NULLS ON
SET ANSI_PADDING ON
SET ANSI_WARNINGS ON
SET NUMERIC_ROUNDABORT OFF
GO
/****** Object:  Index [IX_DWF_TaskBoard_Lab_Status_Assigned_Created]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Status_Assigned_Created] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[Status] ASC,
	[AssignedTo] ASC,
	[CreatedOn] ASC,
	[ClaimIDNormalized] ASC
)
INCLUDE([TaskID],[ClaimID],[CPTCode],[SLAStatus],[WorkFlowStatus],[InsuranceBalance],[DenialCode],[DenialClassification],[ActionCategory],[Priority],[PayerName],[PanelName],[DateOfService]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_TaskBoard_Lab_Status_Assigned_Due]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Status_Assigned_Due] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[Status] ASC,
	[AssignedTo] ASC,
	[DueDate] ASC,
	[TaskID] ASC
)
INCLUDE([ClaimID],[DenialCode],[DenialClassification],[ActionCategory],[Priority],[InsuranceBalance],[PayerName],[PayerNameNormalized],[ClinicName],[SalesRepname],[ReferringProvider],[DateOfService],[RunId],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DWF_TaskBoard_Lab_Status_WorkFlowStatus]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DWF_TaskBoard_Lab_Status_WorkFlowStatus] ON [dbo].[DenialTaskBoard]
(
	[LabId] ASC,
	[Status] ASC,
	[WorkFlowStatus] ASC
)
INCLUDE([ClaimIDNormalized],[ClaimID],[AssignedTo],[CreatedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialTaskHistory_Workflow]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialTaskHistory_Workflow] ON [dbo].[DenialTaskHistory]
(
	[LabId] ASC,
	[TaskID] ASC,
	[UniqueTrackId] ASC,
	[ActionDate] ASC
)
INCLUDE([ActionType],[RunId]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
/****** Object:  Index [IX_DenialVerificationTask_Lab_Paging]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialVerificationTask_Lab_Paging] ON [dbo].[DenialVerificationTask]
(
	[LabId] ASC,
	[VerificationId] DESC
)
INCLUDE([TaskID],[UniqueTrackId],[ClaimID],[PatientId],[CPTCode],[DenialCode],[Status],[AssignedTo],[RunId],[PayerName],[CreatedOn],[VerificationStatus]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialVerificationTask_Workflow]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialVerificationTask_Workflow] ON [dbo].[DenialVerificationTask]
(
	[LabId] ASC,
	[VerificationStatus] ASC,
	[AssignedTo] ASC,
	[UniqueTrackId] ASC
)
INCLUDE([TaskID],[RunId],[MovedOn]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON
GO
/****** Object:  Index [IX_DenialVerificationTask_Workflow_Page]    Script Date: 07/21/2026 10:17:31 pm ******/
CREATE NONCLUSTERED INDEX [IX_DenialVerificationTask_Workflow_Page] ON [dbo].[DenialVerificationTask]
(
	[LabId] ASC,
	[VerificationStatus] ASC,
	[AssignedTo] ASC,
	[MovedOn] ASC,
	[TaskID] ASC
)
INCLUDE([ClaimID],[CPTCode],[DenialCode],[PayerName],[RunId],[InsuranceBalance]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
ALTER TABLE [dbo].[DenialActionCategoryMaster] ADD  CONSTRAINT [DF_DenialActionCategoryMaster_ActionScope]  DEFAULT (N'CPTLevel') FOR [ActionScope]
GO
ALTER TABLE [dbo].[DenialActionCategoryMaster] ADD  CONSTRAINT [DF_DenialActionCategoryMaster_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[DenialActionCategoryMaster] ADD  CONSTRAINT [DF_DenialActionCategoryMaster_CreatedOn]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialClaimDocuments] ADD  CONSTRAINT [DF_DenialClaimDocuments_UploadedOn]  DEFAULT (sysutcdatetime()) FOR [UploadedOn]
GO
ALTER TABLE [dbo].[DenialClaimDocuments] ADD  CONSTRAINT [DF_DenialClaimDocuments_IsDeleted]  DEFAULT ((0)) FOR [IsDeleted]
GO
ALTER TABLE [dbo].[DenialClaimEscalations] ADD  CONSTRAINT [DF_DenialClaimEscalations_Status]  DEFAULT ('Open') FOR [Status]
GO
ALTER TABLE [dbo].[DenialClaimEscalations] ADD  CONSTRAINT [DF_DenialClaimEscalations_CreatedOn]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialClaimEscalations] ADD  CONSTRAINT [DF_DenialClaimEscalations_IsDeleted]  DEFAULT ((0)) FOR [IsDeleted]
GO
ALTER TABLE [dbo].[DenialClaimNotes] ADD  CONSTRAINT [DF_DenialClaimNotes_CreatedOn]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialClaimNotes] ADD  CONSTRAINT [DF_DenialClaimNotes_IsDeleted]  DEFAULT ((0)) FOR [IsDeleted]
GO
ALTER TABLE [dbo].[DenialClosedClaims] ADD  CONSTRAINT [DF_DenialClosedClaims_Status]  DEFAULT ('Closed') FOR [Status]
GO
ALTER TABLE [dbo].[DenialClosedClaims] ADD  CONSTRAINT [DF_DenialClosedClaims_WorkFlowStatus]  DEFAULT ('Closed Claim') FOR [WorkFlowStatus]
GO
ALTER TABLE [dbo].[DenialClosedClaims] ADD  CONSTRAINT [DF_DenialClosedClaims_TaskCount]  DEFAULT ((0)) FOR [TaskCount]
GO
ALTER TABLE [dbo].[DenialClosedClaims] ADD  CONSTRAINT [DF_DenialClosedClaims_InsuranceBalance]  DEFAULT ((0)) FOR [InsuranceBalance]
GO
ALTER TABLE [dbo].[DenialClosedClaims] ADD  CONSTRAINT [DF_DenialClosedClaims_ClosedOn]  DEFAULT (sysutcdatetime()) FOR [ClosedOn]
GO
ALTER TABLE [dbo].[DenialClosedClaims] ADD  CONSTRAINT [DF_DenialClosedClaims_LastUpdatedOn]  DEFAULT (sysutcdatetime()) FOR [LastUpdatedOn]
GO
ALTER TABLE [dbo].[DenialClosedClaimsHistory] ADD  CONSTRAINT [DF_DenialClosedClaimsHistory_ActionDate]  DEFAULT (sysutcdatetime()) FOR [ActionDate]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeBatch] ADD  CONSTRAINT [DF_DCACB_UploadedOn]  DEFAULT (sysutcdatetime()) FOR [UploadedOn]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeBatch] ADD  CONSTRAINT [DF_DCACB_TotalAffectedClaims]  DEFAULT ((0)) FOR [TotalAffectedClaims]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeBatch] ADD  CONSTRAINT [DF_DCACB_TotalAffectedTasks]  DEFAULT ((0)) FOR [TotalAffectedTasks]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeBatch] ADD  CONSTRAINT [DF_DCACB_PendingCount]  DEFAULT ((0)) FOR [PendingCount]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeBatch] ADD  CONSTRAINT [DF_DCACB_ConfirmedCount]  DEFAULT ((0)) FOR [ConfirmedCount]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeBatch] ADD  CONSTRAINT [DF_DCACB_IgnoredCount]  DEFAULT ((0)) FOR [IgnoredCount]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeBatch] ADD  CONSTRAINT [DF_DCACB_Status]  DEFAULT ('Pending') FOR [Status]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeVerification] ADD  CONSTRAINT [DF_DCACV_VerificationStatus]  DEFAULT ('Pending') FOR [VerificationStatus]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeVerification] ADD  CONSTRAINT [DF_DCACV_CreatedOn]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialCodeMapper] ADD  DEFAULT (getdate()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialCodeMaster] ADD  CONSTRAINT [DF_DenialCodeMaster_CreatedOn]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialCodeStaging] ADD  DEFAULT (getdate()) FOR [ImportedOn]
GO
ALTER TABLE [dbo].[DenialInsight] ADD  DEFAULT (getdate()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialLineItem] ADD  DEFAULT (getdate()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialMapperAuditLog] ADD  DEFAULT (sysutcdatetime()) FOR [PerformedOn]
GO
ALTER TABLE [dbo].[DenialMapperLabMaster] ADD  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[DenialMapperLabMaster] ADD  DEFAULT (sysutcdatetime()) FOR [PushedOn]
GO
ALTER TABLE [dbo].[DenialMapperLabMaster] ADD  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialMapperLabMaster] ADD  DEFAULT (sysutcdatetime()) FOR [ModifiedOn]
GO
ALTER TABLE [dbo].[DenialMapperLabOverride] ADD  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[DenialMapperLabOverride] ADD  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialMapperLabOverride] ADD  DEFAULT (sysutcdatetime()) FOR [ModifiedOn]
GO
ALTER TABLE [dbo].[DenialMapperPushAudit] ADD  CONSTRAINT [DF_DMPA_TotalCompared]  DEFAULT ((0)) FOR [TotalCompared]
GO
ALTER TABLE [dbo].[DenialMapperPushAudit] ADD  CONSTRAINT [DF_DMPA_TotalDifferences]  DEFAULT ((0)) FOR [TotalDifferences]
GO
ALTER TABLE [dbo].[DenialMapperPushAudit] ADD  CONSTRAINT [DF_DMPA_OpenTasks]  DEFAULT ((0)) FOR [TotalAssignedOpenTasksAffected]
GO
ALTER TABLE [dbo].[DenialMapperPushAudit] ADD  CONSTRAINT [DF_DMPA_CreatedOn]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialMapperPushAuditDetail] ADD  CONSTRAINT [DF_DMPAD_Open]  DEFAULT ((0)) FOR [IsAssignedToOpenTask]
GO
ALTER TABLE [dbo].[DenialMapperPushAuditDetail] ADD  CONSTRAINT [DF_DMPAD_OpenCount]  DEFAULT ((0)) FOR [OpenAssignedTaskCount]
GO
ALTER TABLE [dbo].[DenialMapperPushAuditDetail] ADD  CONSTRAINT [DF_DMPAD_CreatedOn]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialMapperSuperMaster] ADD  CONSTRAINT [DF_DMSM_Active]  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[DenialMapperSuperMaster] ADD  CONSTRAINT [DF_DMSM_Created]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialMapperSuperMaster] ADD  CONSTRAINT [DF_DMSM_Modified]  DEFAULT (sysutcdatetime()) FOR [ModifiedOn]
GO
ALTER TABLE [dbo].[DenialStatusMaster] ADD  CONSTRAINT [DF_DenialStatusMaster_IsClosedStatus]  DEFAULT ((0)) FOR [IsClosedStatus]
GO
ALTER TABLE [dbo].[DenialStatusMaster] ADD  CONSTRAINT [DF_DenialStatusMaster_IsVerificationStatus]  DEFAULT ((0)) FOR [IsVerificationStatus]
GO
ALTER TABLE [dbo].[DenialStatusMaster] ADD  CONSTRAINT [DF_DenialStatusMaster_SortOrder]  DEFAULT ((100)) FOR [SortOrder]
GO
ALTER TABLE [dbo].[DenialStatusMaster] ADD  CONSTRAINT [DF_DenialStatusMaster_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[DenialStatusMaster] ADD  CONSTRAINT [DF_DenialStatusMaster_CreatedOn]  DEFAULT (sysutcdatetime()) FOR [CreatedOn]
GO
ALTER TABLE [dbo].[DenialTaskBoard] ADD  DEFAULT ((0.0)) FOR [InsuranceBalance]
GO
ALTER TABLE [dbo].[DenialTaskHistory] ADD  CONSTRAINT [DF_DenialTaskHistory_ActionDate]  DEFAULT (sysutcdatetime()) FOR [ActionDate]
GO
ALTER TABLE [dbo].[DenialVerificationTask] ADD  CONSTRAINT [DF_DenialVerificationTask_InsuranceBalance]  DEFAULT ((0)) FOR [InsuranceBalance]
GO
ALTER TABLE [dbo].[DenialVerificationTask] ADD  CONSTRAINT [DF_DenialVerificationTask_VerificationStatus]  DEFAULT (N'Verification Pending') FOR [VerificationStatus]
GO
ALTER TABLE [dbo].[DenialVerificationTask] ADD  CONSTRAINT [DF_DenialVerificationTask_MovedOn]  DEFAULT (sysutcdatetime()) FOR [MovedOn]
GO
ALTER TABLE [dbo].[DenialCodeActionChangeVerification]  WITH CHECK ADD  CONSTRAINT [FK_DCACV_Batch] FOREIGN KEY([BatchId])
REFERENCES [dbo].[DenialCodeActionChangeBatch] ([BatchId])
GO
ALTER TABLE [dbo].[DenialCodeActionChangeVerification] CHECK CONSTRAINT [FK_DCACV_Batch]
GO
ALTER TABLE [dbo].[DenialMapperPushAuditDetail]  WITH CHECK ADD  CONSTRAINT [FK_DenialMapperPushAuditDetail_Audit] FOREIGN KEY([PushAuditId])
REFERENCES [dbo].[DenialMapperPushAudit] ([PushAuditId])
GO
ALTER TABLE [dbo].[DenialMapperPushAuditDetail] CHECK CONSTRAINT [FK_DenialMapperPushAuditDetail_Audit]
GO

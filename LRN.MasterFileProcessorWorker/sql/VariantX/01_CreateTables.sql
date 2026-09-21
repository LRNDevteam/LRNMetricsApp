/* ============================================================================
   VariantX - claim-level and line-level landing tables.
   Run against the VariantX lab database (VariantX_LRN), not LRNMaster.

   GENERATED from LabMetricsDashboard/Templates/VariantX_SharePointFolderMapping_
   ColumMapping_v1.0.xlsx. Regenerate rather than hand-edit if that workbook changes,
   or the DDL and VariantXFieldMappings.Json will drift apart and the bulk copy will
   fail on 'Invalid column name'.

   WHY EVERY COLUMN IS NVARCHAR
   These are landing tables loaded straight from CSV by SqlBulkCopy. Everything
   arrives as text, and one malformed cell in a typed column fails the entire load
   rather than the row. Typing happens downstream, where a bad value can be isolated.
   This matches ClaimLineCSVDataCapture/Sql/01_CreateTables.sql, which the other labs use.

   Re-runnable: each CREATE is guarded, so this is safe to run twice.
   ============================================================================ */

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'ClaimLevelData' AND schema_id = SCHEMA_ID('dbo'))
CREATE TABLE dbo.ClaimLevelData
(
    RecordId                    INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,

    /* Pipeline columns - written by the loader, not present in the lab's file. */
    [FileLogId]                 NVARCHAR(500)  NULL,
    [RunId]                     NVARCHAR(500)  NULL,
    [WeekFolder]                NVARCHAR(500)  NULL,
    [SourceFullPath]            NVARCHAR(1000) NULL,
    [FileName]                  NVARCHAR(500)  NULL,
    [FileType]                  NVARCHAR(100)  NULL,
    [RowHash]                   NVARCHAR(64)   NULL,

    /* Mapped columns, in the order VariantX_..._ColumMapping_v1.0.xlsx lists them. */
    [LabID]                     NVARCHAR(500)  NULL,
    [LabName]                   NVARCHAR(500)  NULL,
    [SourceFileID]              NVARCHAR(500)  NULL,
    [IngestedOn]                NVARCHAR(500)  NULL,
    [CsvRowHash]                NVARCHAR(500)  NULL,
    [ClaimID]                   NVARCHAR(500)  NULL,
    [AccessionNumber]           NVARCHAR(500)  NULL,
    [PanelName]                 NVARCHAR(500)  NULL,
    [PlanType]                  NVARCHAR(500)  NULL,
    [PatientID]                 NVARCHAR(500)  NULL,
    [PatientFirstName]          NVARCHAR(500)  NULL,
    [PatientLastName]           NVARCHAR(500)  NULL,
    [PatientDOB]                NVARCHAR(500)  NULL,
    [DateofService]             NVARCHAR(500)  NULL,
    [AgingDOS]                  NVARCHAR(500)  NULL,
    [EndDOS]                    NVARCHAR(500)  NULL,
    [ChargeEnteredDate]         NVARCHAR(500)  NULL,
    [AgingDOE]                  NVARCHAR(500)  NULL,
    [Facility]                  NVARCHAR(500)  NULL,
    [ReferringProviderFirstName]NVARCHAR(500)  NULL,
    [ReferringProviderLastName] NVARCHAR(500)  NULL,
    [RendPhyFirstName]          NVARCHAR(500)  NULL,
    [RendPhyLastName]           NVARCHAR(500)  NULL,
    [ServLocCode]               NVARCHAR(500)  NULL,
    [ServLocation]              NVARCHAR(500)  NULL,
    [PayerName_Raw]             NVARCHAR(500)  NULL,
    [PayerName]                 NVARCHAR(500)  NULL,
    [Payer_Code]                NVARCHAR(500)  NULL,
    [Payer_Common_Code]         NVARCHAR(500)  NULL,
    [Payer_Group_Code]          NVARCHAR(500)  NULL,
    [Global_Payer_ID]           NVARCHAR(500)  NULL,
    [SubscriberId]              NVARCHAR(500)  NULL,
    [FirstBilledDate]           NVARCHAR(500)  NULL,
    [BilledWeek]                NVARCHAR(500)  NULL,
    [ClaimLevelCPT]             NVARCHAR(500)  NULL,
    [Modifier]                  NVARCHAR(500)  NULL,
    [CheckDate]                 NVARCHAR(500)  NULL,
    [DODWeek]                   NVARCHAR(500)  NULL,
    [DenialDate]                NVARCHAR(500)  NULL,
    [DeniedWeek]                NVARCHAR(500)  NULL,
    [DenialCode]                NVARCHAR(500)  NULL,
    [LineLevelDenialCode]       NVARCHAR(500)  NULL,
    [ClaimLevelDenialCode]      NVARCHAR(500)  NULL,
    [LineLevelICD]              NVARCHAR(500)  NULL,
    [ClaimLevelICD]             NVARCHAR(500)  NULL,
    [POS]                       NVARCHAR(500)  NULL,
    [TOS]                       NVARCHAR(500)  NULL,
    [LineLevelCPT]              NVARCHAR(500)  NULL,
    [CPTCodeXUnitsXModifier]    NVARCHAR(MAX)  NULL,
    [ChargeAmount]              NVARCHAR(500)  NULL,
    [AllowedAmount]             NVARCHAR(500)  NULL,
    [InsurancePayment]          NVARCHAR(500)  NULL,
    [PatientPayment]            NVARCHAR(500)  NULL,
    [TotalPayments]             NVARCHAR(500)  NULL,
    [InsuranceBalance]          NVARCHAR(500)  NULL,
    [PatientBalance]            NVARCHAR(500)  NULL,
    [TotalBalance]              NVARCHAR(500)  NULL,
    [InsuranceAdjustments]      NVARCHAR(500)  NULL,
    [PatientAdjustments]        NVARCHAR(500)  NULL,
    [TotalWO]                   NVARCHAR(500)  NULL,
    [BillingOption]             NVARCHAR(500)  NULL,
    [CurrentStatus]             NVARCHAR(500)  NULL,
    [BatchNo]                   NVARCHAR(500)  NULL,
    [CreatedBy]                 NVARCHAR(500)  NULL,
    [UpdatedOn]                 NVARCHAR(500)  NULL,
    [UpdatedBy]                 NVARCHAR(500)  NULL,
    [PaymentPercent]            NVARCHAR(500)  NULL,
    [BillStatus]                NVARCHAR(500)  NULL,
    [FullyPaidCount]            NVARCHAR(500)  NULL,
    [FullyPaidAmount]           NVARCHAR(500)  NULL,
    [AdjucticatedCount]         NVARCHAR(500)  NULL,
    [AdjucticatedAmount]        NVARCHAR(500)  NULL,
    [Bucket30Count]             NVARCHAR(500)  NULL,
    [Bucket30Amount]            NVARCHAR(500)  NULL,
    [Bucket60Count]             NVARCHAR(500)  NULL,
    [Bucket60Amount]            NVARCHAR(500)  NULL,
    [ClaimStatus]               NVARCHAR(500)  NULL,
    [DaystoDOS]                 NVARCHAR(500)  NULL,
    [RollingDays]               NVARCHAR(500)  NULL,
    [DaystoBill]                NVARCHAR(500)  NULL,
    [DaystoPost]                NVARCHAR(500)  NULL,

    /* Unmapped source columns land here as JSON when CaptureAdditionalFields is on. */
    [AdditionalFields]          NVARCHAR(MAX)  NULL,
    [InsertedDateTime]          DATETIME2(3)   NOT NULL CONSTRAINT DF_ClaimLevelData_InsertedDateTime DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'LineLevelData' AND schema_id = SCHEMA_ID('dbo'))
CREATE TABLE dbo.LineLevelData
(
    RecordId                    INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,

    /* Pipeline columns - written by the loader, not present in the lab's file. */
    [FileLogId]                 NVARCHAR(500)  NULL,
    [RunId]                     NVARCHAR(500)  NULL,
    [WeekFolder]                NVARCHAR(500)  NULL,
    [SourceFullPath]            NVARCHAR(1000) NULL,
    [FileName]                  NVARCHAR(500)  NULL,
    [FileType]                  NVARCHAR(100)  NULL,
    [RowHash]                   NVARCHAR(64)   NULL,

    /* Mapped columns, in the order VariantX_..._ColumMapping_v1.0.xlsx lists them. */
    [LabID]                     NVARCHAR(500)  NULL,
    [LabName]                   NVARCHAR(500)  NULL,
    [SourceFileID]              NVARCHAR(500)  NULL,
    [IngestedOn]                NVARCHAR(500)  NULL,
    [CsvRowHash]                NVARCHAR(500)  NULL,
    [ClaimID]                   NVARCHAR(500)  NULL,
    [T_F]                       NVARCHAR(500)  NULL,
    [LineLevelUID]              NVARCHAR(500)  NULL,
    [AccessionNumber]           NVARCHAR(500)  NULL,
    [Panelname]                 NVARCHAR(500)  NULL,
    [PlanType]                  NVARCHAR(500)  NULL,
    [PatientID]                 NVARCHAR(500)  NULL,
    [PatientFirstName]          NVARCHAR(500)  NULL,
    [PatientLastName]           NVARCHAR(500)  NULL,
    [PatientDOB]                NVARCHAR(500)  NULL,
    [DateofService]             NVARCHAR(500)  NULL,
    [AgingDOS]                  NVARCHAR(500)  NULL,
    [EndDOS]                    NVARCHAR(500)  NULL,
    [ChargeEnteredDate]         NVARCHAR(500)  NULL,
    [AgingDOE]                  NVARCHAR(500)  NULL,
    [Facility]                  NVARCHAR(500)  NULL,
    [ReferringProviderLastName] NVARCHAR(500)  NULL,
    [ReferringProviderFirstName]NVARCHAR(500)  NULL,
    [RendPhyFirstName]          NVARCHAR(500)  NULL,
    [RendPhyLastName]           NVARCHAR(500)  NULL,
    [ServLocCode]               NVARCHAR(500)  NULL,
    [ServLocation]              NVARCHAR(500)  NULL,
    [PayerName_Raw]             NVARCHAR(500)  NULL,
    [PayerName]                 NVARCHAR(500)  NULL,
    [Payer_Code]                NVARCHAR(500)  NULL,
    [Payer_Common_Code]         NVARCHAR(500)  NULL,
    [Payer_Group_Code]          NVARCHAR(500)  NULL,
    [Global_Payer_ID]           NVARCHAR(500)  NULL,
    [SubscriberId]              NVARCHAR(500)  NULL,
    [FirstBilledDate]           NVARCHAR(500)  NULL,
    [BilledWeek]                NVARCHAR(500)  NULL,
    [CPTCode]                   NVARCHAR(500)  NULL,
    [Units]                     NVARCHAR(500)  NULL,
    [Modifier]                  NVARCHAR(500)  NULL,
    [CPTXMODXUnits]             NVARCHAR(MAX)  NULL,
    [LineLevelCPT]              NVARCHAR(500)  NULL,
    [CheckDate]                 NVARCHAR(500)  NULL,
    [DODWeek]                   NVARCHAR(500)  NULL,
    [DenialDate]                NVARCHAR(500)  NULL,
    [DeniedWeek]                NVARCHAR(500)  NULL,
    [DenialCode]                NVARCHAR(500)  NULL,
    [LineLevelDenialCode]       NVARCHAR(500)  NULL,
    [ICDCode]                   NVARCHAR(500)  NULL,
    [ClaimLevelICDCode]         NVARCHAR(500)  NULL,
    [POS]                       NVARCHAR(500)  NULL,
    [TOS]                       NVARCHAR(500)  NULL,
    [ChargeAmount]              NVARCHAR(500)  NULL,
    [ChargeAmountPerUnit]       NVARCHAR(500)  NULL,
    [AllowedAmount]             NVARCHAR(500)  NULL,
    [AllowedAmountPerUnit]      NVARCHAR(500)  NULL,
    [InsurancePayment]          NVARCHAR(500)  NULL,
    [InsurancePaymentPerUnit]   NVARCHAR(500)  NULL,
    [PatientPayment]            NVARCHAR(500)  NULL,
    [PatientPaymentPerUnit]     NVARCHAR(500)  NULL,
    [InsuranceBalance]          NVARCHAR(500)  NULL,
    [PatientBalance]            NVARCHAR(500)  NULL,
    [PatientBalancePerUnit]     NVARCHAR(500)  NULL,
    [TotalBalance]              NVARCHAR(500)  NULL,
    [InsuranceAdjustments]      NVARCHAR(500)  NULL,
    [PatientAdjustments]        NVARCHAR(500)  NULL,
    [TotalAdjustments]          NVARCHAR(500)  NULL,
    [BillingOption]             NVARCHAR(500)  NULL,
    [CPTStatus]                 NVARCHAR(500)  NULL,
    [CurrentStatus]             NVARCHAR(500)  NULL,
    [PaymentPercent]            NVARCHAR(500)  NULL,
    [BillStatus]                NVARCHAR(500)  NULL,
    [CreatedOn]                 NVARCHAR(500)  NULL,
    [CreatedBy]                 NVARCHAR(500)  NULL,
    [UpdatedOn]                 NVARCHAR(500)  NULL,
    [UpdatedBy]                 NVARCHAR(500)  NULL,
    [ClaimStatus]               NVARCHAR(500)  NULL,
    [PayStatus]                 NVARCHAR(500)  NULL,
    [DaystoDOS]                 NVARCHAR(500)  NULL,
    [RollingDays]               NVARCHAR(500)  NULL,
    [DaystoBill]                NVARCHAR(500)  NULL,
    [DaystoPost]                NVARCHAR(500)  NULL,
    [ICDPointer]                NVARCHAR(500)  NULL,
    [PaymentPostedDate]         NVARCHAR(500)  NULL,
    [UID]                       NVARCHAR(500)  NULL,
    [Source]                    NVARCHAR(500)  NULL,
    [InsuranceBalance_Decimal]  NVARCHAR(500)  NULL,

    /* Unmapped source columns land here as JSON when CaptureAdditionalFields is on. */
    [AdditionalFields]          NVARCHAR(MAX)  NULL,
    [InsertedDateTime]          DATETIME2(3)   NOT NULL CONSTRAINT DF_LineLevelData_InsertedDateTime DEFAULT SYSUTCDATETIME()
);
GO

/* Indexes the reporting reads against. Added after the tables so a fresh database
   gets them, and guarded so an existing one is not disturbed. */
IF OBJECT_ID('dbo.ClaimLevelData','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ClaimLevelData') AND name = 'IX_ClaimLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_ClaimLevelData_ClaimID ON dbo.ClaimLevelData (ClaimID);
GO

IF OBJECT_ID('dbo.LineLevelData','U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LineLevelData') AND name = 'IX_LineLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_LineLevelData_ClaimID ON dbo.LineLevelData (ClaimID);
GO

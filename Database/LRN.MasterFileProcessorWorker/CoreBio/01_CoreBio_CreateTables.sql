/*
    CoreBio - lab database tables for LRN.MasterFileProcessorWorker.
    Run against the COREBIO lab database (CoreBio_LRN), not LRNMaster.

    What the worker writes here:
      dbo.LineClaimFileLogs  one row per load (LineClaimFileLogRepository)
      dbo.ClaimLevelData     "Claim Level File" sheet - TRUNCATE + SqlBulkCopy per run
      dbo.LineLevelData      "Line Level File" sheet  - TRUNCATE + SqlBulkCopy per run
      dbo.LIMSMaster         Corebio_LIMS_Master File  - TRUNCATE + SqlBulkCopy per run

    Built from the WellHealth tables, then aligned to:
      Schemas/LabMappings/CoreBioFieldMappings.json   (ClaimLevelData / LineLevelData SqlColumn)
      Schemas/CoreBio_LIMS_Schema.json                (LIMSMaster SQLColName)
    Mapping source: AveragesTable_AllAccounts_Field Mapping_V1.20.xlsx, column 'CoreBio'.
    SqlBulkCopy fails the load outright if a mapped column is missing, and the LIMS importer silently
    skips one, so keep them in step.

    Dropped from WellHealth (only its file fills them):
      ClaimLevelData / LineLevelData  ClaimBillingProviderID, ChargePanelID
    Added for CoreBio:
      ClaimLevelData   TF, OrderingProviderID, LISFacilityName, ChargePanelName, CPTDescription,
                       ClaimCPTs, LineLevelCombination, ClaimLevelICD, OriginalDenialCode,
                       LineLevelDenialCode, ClaimLevelDenialCode, ChargeBalanceDueIns, ClaimDeleted,
                       DepositWeek, BalanceAtCollections
      LineLevelData    TF, OrderingProviderID, LISFacilityName, ChargePanelName, CPTDescription,
                       AgingDOS, PanelNameLIS, LineLevelCombination, ClaimLevelICD, UpdatedDenial,
                       LineLevelDenialCode, ClaimLevelDenialCode, PaymentPercent, ClaimDeleted,
                       BalanceAtCollections
      LIMSMaster       Department, DueDate, CreatedFrom, AccessionedBy, Priority, SarsCov2PCR,
                       FinalReportType, CollectionWeek, DnrStatus (plus DoctorNPI / PanelName, which
                       WellHealth's file does not carry)
    Denials (V1.20): ClaimLevelData.DenialCode is the sheet's "Denial Code"; LineLevelData.DenialCode is
    "Original Denial Code" and the line sheet's "Denial Code" lands in LineLevelData.UpdatedDenial.
    Columns not loaded from the file (DenialCodeNormalized, DenialDescription, Aging buckets, ...)
    are kept: other processes write them after the load.

    Re-runnable: tables are created only when missing, and every CoreBio column is added only
    when missing, so it is also safe on a database cloned from another lab.
*/

SET NOCOUNT ON;
GO

/* ── 1. LineClaimFileLogs ─────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.LineClaimFileLogs', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LineClaimFileLogs
    (
        FileLogId            INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
        RunId                NVARCHAR(500)  NOT NULL,
        WeekFolder           NVARCHAR(500)  NULL,
        LabName              NVARCHAR(500)  NULL,
        SourceFullPath       NVARCHAR(1000) NULL,
        FileName             NVARCHAR(500)  NULL,
        FileType             NVARCHAR(100)  NOT NULL,
        FileCreatedDateTime  DATETIME       NULL,
        InsertedDateTime     DATETIME       NOT NULL DEFAULT GETDATE(),
        Status               NVARCHAR(50)   NULL,
        RowsCopied           BIGINT         NULL,
        ErrorMessage         NVARCHAR(MAX)  NULL,
        CompletedDateTime    DATETIME2      NULL
    );
    PRINT 'Created dbo.LineClaimFileLogs.';
END
GO

/* ── 2. ClaimLevelData ────────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.ClaimLevelData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ClaimLevelData
    (
        RecordId                      INT            IDENTITY(1,1) NOT NULL,
        -- audit block stamped by the loader
        FileLogId                     NVARCHAR(500)  NULL,
        RunId                         NVARCHAR(500)  NULL,
        WeekFolder                    NVARCHAR(500)  NULL,
        SourceFullPath                NVARCHAR(1000) NULL,
        FileName                      NVARCHAR(500)  NULL,
        FileType                      NVARCHAR(100)  NULL,
        RowHash                       NVARCHAR(64)   NULL,
        LabID                         NVARCHAR(500)  NULL,
        LabName                       NVARCHAR(500)  NULL,
        -- standard claim columns
        ClaimID                       NVARCHAR(500)  NULL,   -- Charge Claim ID
        AccessionNumber               NVARCHAR(500)  NULL,   -- Claim Reference #
        SourceFileID                  NVARCHAR(1000) NULL,
        IngestedOn                    NVARCHAR(500)  NULL,
        CsvRowHash                    NVARCHAR(500)  NULL,
        PayerName_Raw                 NVARCHAR(500)  NULL,   -- Claim Primary Payer Name
        PayerName                     NVARCHAR(500)  NULL,
        Payer_Code                    NVARCHAR(500)  NULL,
        Payer_Common_Code             NVARCHAR(500)  NULL,
        Payer_Group_Code              NVARCHAR(500)  NULL,
        Global_Payer_ID               NVARCHAR(500)  NULL,
        PayerType                     NVARCHAR(500)  NULL,   -- Claim Primary Payer Type
        BillingProvider               NVARCHAR(500)  NULL,
        ReferringProvider             NVARCHAR(500)  NULL,   -- Referring Full Name
        ClinicName                    NVARCHAR(500)  NULL,   -- Facility Name (COMMON alias)
        SalesRepname                  NVARCHAR(500)  NULL,
        PatientID                     NVARCHAR(500)  NULL,   -- Charge Patient ID
        PatientDOB                    NVARCHAR(500)  NULL,   -- Patient Birthday
        DateofService                 NVARCHAR(500)  NULL,   -- Charge From Date
        ChargeEnteredDate             NVARCHAR(500)  NULL,   -- Charge Entered Date
        FirstBilledDate               NVARCHAR(500)  NULL,   -- Charge First Bill Date
        Panelname                     NVARCHAR(500)  NULL,   -- Panel Name
        CPTCodeXUnitsXModifier        NVARCHAR(MAX)  NULL,   -- rebuilt from the line level
        POS                           NVARCHAR(500)  NULL,
        TOS                           NVARCHAR(500)  NULL,
        ChargeAmount                  NVARCHAR(500)  NULL,   -- Charge Amount
        AllowedAmount                 NVARCHAR(500)  NULL,
        InsurancePayment              NVARCHAR(500)  NULL,   -- Charge Insurance Payments
        PatientPayment                NVARCHAR(500)  NULL,   -- Charge Patient Payments
        TotalPayments                 NVARCHAR(500)  NULL,
        InsuranceAdjustments          NVARCHAR(500)  NULL,   -- Charge Insurance Adjustments
        PatientAdjustments            NVARCHAR(500)  NULL,   -- Charge Patient Adjustments
        TotalAdjustments              NVARCHAR(500)  NULL,
        InsuranceBalance              NVARCHAR(500)  NULL,   -- Total Ins Balance
        PatientBalance                NVARCHAR(500)  NULL,   -- Pat Balance
        TotalBalance                  NVARCHAR(500)  NULL,
        CheckDate                     NVARCHAR(500)  NULL,   -- Deposit Date
        ClaimStatus                   NVARCHAR(500)  NULL,   -- Claim Status
        DenialCode                    NVARCHAR(MAX)  NULL,   -- Denial Code
        ICDCode                       NVARCHAR(500)  NULL,   -- Claim ICD List
        DaystoDOS                     NVARCHAR(500)  NULL,
        RollingDays                   NVARCHAR(500)  NULL,
        DaystoBill                    NVARCHAR(500)  NULL,
        DaystoPost                    NVARCHAR(500)  NULL,
        ICDPointer                    NVARCHAR(500)  NULL,   -- Charge Diagnosis Pointer List
        InsertedDateTime              DATETIME       NOT NULL DEFAULT GETDATE(),
        -- lab columns
        PatientName                   NVARCHAR(1000) NULL,   -- Patient Full Name
        PaymentPercent                NVARCHAR(100)  NULL,   -- Payment %
        Aging                         NVARCHAR(100)  NULL,
        BilledWeek                    NVARCHAR(500)  NULL,   -- Billed Week
        PostedWeek                    NVARCHAR(500)  NULL,
        FullyPaidCount                NVARCHAR(500)  NULL,   -- Fully Paid #
        FullyPaidAmount               NVARCHAR(500)  NULL,   -- Fully Paid $
        AdjudicatedAmount             NVARCHAR(500)  NULL,   -- Adjucticated $
        CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX)  NULL,   -- CPT X MOD X UNITS
        BilledUnbilled                NVARCHAR(100)  NULL,
        AgingBucket                   NVARCHAR(200)  NULL,
        AdjudicatedCount              NVARCHAR(500)  NULL,
        Days30Count                   NVARCHAR(500)  NULL,
        Days30Amount                  NVARCHAR(500)  NULL,
        Days60Count                   NVARCHAR(500)  NULL,
        Days60Amount                  NVARCHAR(500)  NULL,
        DOE_Year                      NVARCHAR(20)   NULL,
        DOE_Month                     NVARCHAR(20)   NULL,
        ClaimUID                      NVARCHAR(500)  NULL,
        AgingDOE                      NVARCHAR(500)  NULL,
        AgingDOS                      NVARCHAR(500)  NULL,   -- Aging DOS
        PanelNameLIS                  NVARCHAR(MAX)  NULL,   -- LIS Panel (full test list, 1,700+ chars)
        PanelNameBasedOnCPT           NVARCHAR(500)  NULL,
        InsuranceBalance_Decimal      AS (TRY_CAST(InsuranceBalance AS DECIMAL(18,2))) PERSISTED,
        AdditionalFields              NVARCHAR(MAX)  NULL,   -- unmapped CSV columns as JSON
        Facility                      NVARCHAR(500)  NULL,   -- Facility Name
        Modifier                      NVARCHAR(500)  NULL,
        DenialCodeNormalized          NVARCHAR(400)  NULL,
        DenialDescription             NVARCHAR(MAX)  NULL,
        SubscriberId                  NVARCHAR(1000) NULL,   -- Claim Primary Member ID
        BilledStatus                  NVARCHAR(MAX)  NULL,   -- Bill Type
        Adjudicated                   NVARCHAR(500)  NULL,   -- Adjucticated #
        Bucket30                      NVARCHAR(500)  NULL,   -- 30 Bucket #
        Bucket30Amount                NVARCHAR(500)  NULL,   -- 30 Bucket $
        Bucket60                      NVARCHAR(500)  NULL,   -- 60 Bucket #
        Bucket60Amount                NVARCHAR(500)  NULL,   -- 60 Bucket $
        LastBilledDate                NVARCHAR(500)  NULL,   -- Charge Last Bill Date
        DenialDate                    NVARCHAR(500)  NULL,   -- Denial Date
        TotalInsuranceBalance         NVARCHAR(500)  NULL,
        OtherBalance                  NVARCHAR(500)  NULL,   -- Charge Balance Due Other
        CPTCodeList                   NVARCHAR(MAX)  NULL,   -- Charge CPT Code
        UnitsList                     NVARCHAR(500)  NULL,   -- Charge Units
        ModifierList                  NVARCHAR(500)  NULL,   -- Charge Modifier List
        CptWithUnits                  NVARCHAR(MAX)  NULL,
        ChargeToDate                  NVARCHAR(500)  NULL,   -- Charge To Date
        ChargeTotalPayments           NVARCHAR(500)  NULL,   -- Charge Total Payments
        ChargeTotalAdjustments        NVARCHAR(500)  NULL,   -- Charge Total Adjustments
        PostingDate                   NVARCHAR(500)  NULL,   -- (no posted date on the CoreBio sheet)
        PaymentPostedDate             NVARCHAR(500)  NULL,
        -- CoreBio only
        DepositWeek                   NVARCHAR(500)  NULL,   -- DOD Week
        BalanceAtCollections          NVARCHAR(500)  NULL,   -- Charge Balance At Collections
        TF                            NVARCHAR(10)   NULL,   -- T/F
        OrderingProviderID            NVARCHAR(500)  NULL,   -- Claim Ordering Provider ID
        LISFacilityName               NVARCHAR(500)  NULL,   -- LIS Facility Name
        ChargePanelName               NVARCHAR(500)  NULL,   -- Charge Panel Name
        CPTDescription                NVARCHAR(MAX)  NULL,   -- Charge CPT Description
        ClaimCPTs                     NVARCHAR(MAX)  NULL,   -- Claim Level Combination
        LineLevelCombination          NVARCHAR(MAX)  NULL,   -- Line Level Combination
        ClaimLevelICD                 NVARCHAR(MAX)  NULL,   -- Claim Level ICD
        OriginalDenialCode            NVARCHAR(MAX)  NULL,   -- Original Denial Code
        LineLevelDenialCode           NVARCHAR(MAX)  NULL,   -- Line Level Denial Code
        ClaimLevelDenialCode          NVARCHAR(MAX)  NULL,   -- Claim Level Denial Code
        ChargeBalanceDueIns           NVARCHAR(500)  NULL,   -- Charge Balance Due Ins
        ClaimDeleted                  NVARCHAR(50)   NULL,   -- Claim Deleted?
        PRIMARY KEY CLUSTERED (RecordId ASC)
    );
    PRINT 'Created dbo.ClaimLevelData.';
END
GO

-- CoreBio claim columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.ClaimLevelData', 'LastBilledDate') IS NULL         ALTER TABLE dbo.ClaimLevelData ADD LastBilledDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DenialDate') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD DenialDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TotalInsuranceBalance') IS NULL  ALTER TABLE dbo.ClaimLevelData ADD TotalInsuranceBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OtherBalance') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD OtherBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CPTCodeList') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD CPTCodeList NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'UnitsList') IS NULL              ALTER TABLE dbo.ClaimLevelData ADD UnitsList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ModifierList') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD ModifierList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeToDate') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD ChargeToDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalPayments') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD ChargeTotalPayments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalAdjustments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD ChargeTotalAdjustments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PostingDate') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD PostingDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PaymentPostedDate') IS NULL      ALTER TABLE dbo.ClaimLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DepositWeek') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD DepositWeek NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BalanceAtCollections') IS NULL   ALTER TABLE dbo.ClaimLevelData ADD BalanceAtCollections NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TF') IS NULL                     ALTER TABLE dbo.ClaimLevelData ADD TF NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OrderingProviderID') IS NULL     ALTER TABLE dbo.ClaimLevelData ADD OrderingProviderID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LISFacilityName') IS NULL        ALTER TABLE dbo.ClaimLevelData ADD LISFacilityName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargePanelName') IS NULL        ALTER TABLE dbo.ClaimLevelData ADD ChargePanelName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CPTDescription') IS NULL         ALTER TABLE dbo.ClaimLevelData ADD CPTDescription NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimCPTs') IS NULL              ALTER TABLE dbo.ClaimLevelData ADD ClaimCPTs NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LineLevelCombination') IS NULL   ALTER TABLE dbo.ClaimLevelData ADD LineLevelCombination NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimLevelICD') IS NULL          ALTER TABLE dbo.ClaimLevelData ADD ClaimLevelICD NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OriginalDenialCode') IS NULL     ALTER TABLE dbo.ClaimLevelData ADD OriginalDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LineLevelDenialCode') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimLevelDenialCode') IS NULL   ALTER TABLE dbo.ClaimLevelData ADD ClaimLevelDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeBalanceDueIns') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD ChargeBalanceDueIns NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimDeleted') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD ClaimDeleted NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PanelNameLIS') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD PanelNameLIS NVARCHAR(MAX) NULL;
GO

-- CoreBio's "LIS Panel" is the full test list (1,700+ chars), longer than the NVARCHAR(500) other labs
-- use; SqlBulkCopy rejects the whole load when it does not fit. Widen a narrower existing column.
IF COL_LENGTH('dbo.ClaimLevelData', 'PanelNameLIS') <> -1
    ALTER TABLE dbo.ClaimLevelData ALTER COLUMN PanelNameLIS NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.ClaimLevelData') AND name = 'IX_ClaimLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_ClaimLevelData_ClaimID ON dbo.ClaimLevelData (ClaimID);
GO

/* ── 3. LineLevelData ─────────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.LineLevelData', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LineLevelData
    (
        RecordId                 INT            IDENTITY(1,1) NOT NULL,
        -- audit block stamped by the loader
        FileLogId                NVARCHAR(500)  NULL,
        RunId                    NVARCHAR(500)  NULL,
        WeekFolder               NVARCHAR(500)  NULL,
        SourceFullPath           NVARCHAR(1000) NULL,
        FileName                 NVARCHAR(500)  NULL,
        FileType                 NVARCHAR(100)  NULL,
        RowHash                  NVARCHAR(64)   NULL,
        LabID                    NVARCHAR(500)  NULL,
        LabName                  NVARCHAR(500)  NULL,
        -- standard line columns
        ClaimID                  NVARCHAR(500)  NULL,   -- Charge Claim ID
        AccessionNumber          NVARCHAR(500)  NULL,   -- Claim Reference #
        SourceFileID             NVARCHAR(1000) NULL,
        IngestedOn               NVARCHAR(500)  NULL,
        CsvRowHash               NVARCHAR(500)  NULL,
        PayerName_Raw            NVARCHAR(500)  NULL,   -- Claim Primary Payer Name
        PayerName                NVARCHAR(500)  NULL,
        Payer_Code               NVARCHAR(500)  NULL,
        Payer_Common_Code        NVARCHAR(500)  NULL,
        Payer_Group_Code         NVARCHAR(500)  NULL,
        Global_Payer_ID          NVARCHAR(500)  NULL,
        PayerType                NVARCHAR(500)  NULL,   -- Claim Primary Payer Type
        BillingProvider          NVARCHAR(500)  NULL,
        ReferringProvider        NVARCHAR(500)  NULL,   -- Referring Full Name
        ClinicName               NVARCHAR(500)  NULL,   -- Facility Name (COMMON alias)
        SalesRepname             NVARCHAR(500)  NULL,
        PatientID                NVARCHAR(500)  NULL,   -- Charge Patient ID
        PatientDOB               NVARCHAR(500)  NULL,   -- Patient Birthday
        DateofService            NVARCHAR(500)  NULL,   -- Charge From Date
        ChargeEnteredDate        NVARCHAR(500)  NULL,   -- Charge Entered Date
        FirstBilledDate          NVARCHAR(500)  NULL,   -- Charge First Bill Date
        Panelname                NVARCHAR(500)  NULL,   -- Panel Name
        CPTCode                  NVARCHAR(500)  NULL,   -- Charge CPT Code
        Units                    NVARCHAR(500)  NULL,   -- Charge Units
        Modifier                 NVARCHAR(500)  NULL,   -- Charge Modifier List
        POS                      NVARCHAR(500)  NULL,
        TOS                      NVARCHAR(500)  NULL,
        ChargeAmount             NVARCHAR(500)  NULL,   -- Charge Amount
        ChargeAmountPerUnit      NVARCHAR(500)  NULL,
        AllowedAmount            NVARCHAR(500)  NULL,
        AllowedAmountPerUnit     NVARCHAR(500)  NULL,
        InsurancePayment         NVARCHAR(500)  NULL,   -- Charge Insurance Payments
        InsurancePaymentPerUnit  NVARCHAR(500)  NULL,
        PatientPayment           NVARCHAR(500)  NULL,   -- Charge Patient Payments
        PatientPaymentPerUnit    NVARCHAR(500)  NULL,
        TotalPayments            NVARCHAR(500)  NULL,
        InsuranceAdjustments     NVARCHAR(500)  NULL,   -- Charge Insurance Adjustments
        PatientAdjustments       NVARCHAR(500)  NULL,   -- Charge Patient Adjustments
        TotalAdjustments         NVARCHAR(500)  NULL,
        InsuranceBalance         NVARCHAR(500)  NULL,   -- Charge Balance Due Ins
        PatientBalance           NVARCHAR(500)  NULL,   -- Pat Balance
        PatientBalancePerUnit    NVARCHAR(500)  NULL,
        TotalBalance             NVARCHAR(500)  NULL,
        CheckDate                NVARCHAR(500)  NULL,   -- Deposit Date
        PostingDate              NVARCHAR(500)  NULL,   -- (no posted date on the CoreBio sheet)
        ClaimStatus              NVARCHAR(500)  NULL,   -- copied from the claim sheet
        PayStatus                NVARCHAR(500)  NULL,
        DenialCode               NVARCHAR(MAX)  NULL,   -- Original Denial Code
        DenialDate               NVARCHAR(500)  NULL,   -- Denial Date
        ICDCode                  NVARCHAR(500)  NULL,   -- Claim ICD List
        DaystoDOS                NVARCHAR(500)  NULL,
        RollingDays              NVARCHAR(500)  NULL,
        DaystoBill               NVARCHAR(500)  NULL,
        DaystoPost               NVARCHAR(500)  NULL,
        ICDPointer               NVARCHAR(500)  NULL,   -- Charge Diagnosis Pointer List
        InsertedDateTime         DATETIME       NOT NULL DEFAULT GETDATE(),
        -- lab columns
        PatientName              NVARCHAR(1000) NULL,   -- Patient Full Name
        SubscriberId             NVARCHAR(500)  NULL,   -- Claim Primary Member ID
        PaymentPostedDate        NVARCHAR(500)  NULL,
        ResponsibleParty         NVARCHAR(500)  NULL,
        EndDOS                   NVARCHAR(500)  NULL,
        BillOccurance            NVARCHAR(500)  NULL,
        EntryUser                NVARCHAR(500)  NULL,
        CPTUnits                 NVARCHAR(500)  NULL,
        CPTMOD                   NVARCHAR(500)  NULL,
        PostedWeek               NVARCHAR(500)  NULL,
        LineLevelUID             NVARCHAR(500)  NULL,
        Source                   NVARCHAR(500)  NULL,
        InsuranceBalance_Decimal AS (TRY_CAST(InsuranceBalance AS DECIMAL(18,2))) PERSISTED,
        AdditionalFields         NVARCHAR(MAX)  NULL,   -- unmapped CSV columns as JSON
        Facility                 NVARCHAR(500)  NULL,   -- Facility Name
        CPTs                     NVARCHAR(500)  NULL,
        DenialCodeNormalized     NVARCHAR(400)  NULL,
        DenialDescription        NVARCHAR(MAX)  NULL,
        UID                      NVARCHAR(500)  NULL,   -- UID
        LastBilledDate           NVARCHAR(500)  NULL,   -- Charge Last Bill Date
        CptWithUnits             NVARCHAR(MAX)  NULL,
        CPTModifier              NVARCHAR(MAX)  NULL,   -- CPT X MOD X UNITS
        ClaimCPTs                NVARCHAR(MAX)  NULL,   -- Claim Level Combination
        TotalInsuranceBalance    NVARCHAR(500)  NULL,   -- Total Ins Balance
        OtherBalance             NVARCHAR(500)  NULL,   -- Charge Balance Due Other
        ChargeToDate             NVARCHAR(500)  NULL,   -- Charge To Date
        ChargeTotalPayments      NVARCHAR(500)  NULL,   -- Charge Total Payments
        ChargeTotalAdjustments   NVARCHAR(500)  NULL,   -- Charge Total Adjustments
        -- CoreBio only
        BalanceAtCollections     NVARCHAR(500)  NULL,   -- Charge Balance At Collections
        TF                       NVARCHAR(10)   NULL,   -- T/F
        OrderingProviderID       NVARCHAR(500)  NULL,   -- Claim Ordering Provider ID
        LISFacilityName          NVARCHAR(500)  NULL,   -- LIS Facility Name
        ChargePanelName          NVARCHAR(500)  NULL,   -- Charge Panel Name
        CPTDescription           NVARCHAR(MAX)  NULL,   -- Charge CPT Description
        AgingDOS                 NVARCHAR(500)  NULL,   -- Aging DOS
        PanelNameLIS             NVARCHAR(MAX)  NULL,   -- LIS Panel (full test list, 1,700+ chars)
        LineLevelCombination     NVARCHAR(MAX)  NULL,   -- Line Level Combination
        ClaimLevelICD            NVARCHAR(MAX)  NULL,   -- Claim Level ICD
        UpdatedDenial            NVARCHAR(MAX)  NULL,   -- Denial Code (the updated code)
        LineLevelDenialCode      NVARCHAR(MAX)  NULL,   -- Line Level Denial Code
        ClaimLevelDenialCode     NVARCHAR(MAX)  NULL,   -- Claim Level Denial Code
        PaymentPercent           NVARCHAR(100)  NULL,   -- Payment %
        ClaimDeleted             NVARCHAR(50)   NULL,   -- Claim Deleted?
        PRIMARY KEY CLUSTERED (RecordId ASC)
    );
    PRINT 'Created dbo.LineLevelData.';
END
GO

-- CoreBio line columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.LineLevelData', 'UID') IS NULL                    ALTER TABLE dbo.LineLevelData ADD UID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LastBilledDate') IS NULL         ALTER TABLE dbo.LineLevelData ADD LastBilledDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CPTModifier') IS NULL            ALTER TABLE dbo.LineLevelData ADD CPTModifier NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimCPTs') IS NULL              ALTER TABLE dbo.LineLevelData ADD ClaimCPTs NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TotalInsuranceBalance') IS NULL  ALTER TABLE dbo.LineLevelData ADD TotalInsuranceBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OtherBalance') IS NULL           ALTER TABLE dbo.LineLevelData ADD OtherBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeToDate') IS NULL           ALTER TABLE dbo.LineLevelData ADD ChargeToDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeTotalPayments') IS NULL    ALTER TABLE dbo.LineLevelData ADD ChargeTotalPayments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeTotalAdjustments') IS NULL ALTER TABLE dbo.LineLevelData ADD ChargeTotalAdjustments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'BalanceAtCollections') IS NULL   ALTER TABLE dbo.LineLevelData ADD BalanceAtCollections NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TF') IS NULL                     ALTER TABLE dbo.LineLevelData ADD TF NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OrderingProviderID') IS NULL     ALTER TABLE dbo.LineLevelData ADD OrderingProviderID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LISFacilityName') IS NULL        ALTER TABLE dbo.LineLevelData ADD LISFacilityName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargePanelName') IS NULL        ALTER TABLE dbo.LineLevelData ADD ChargePanelName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CPTDescription') IS NULL         ALTER TABLE dbo.LineLevelData ADD CPTDescription NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AgingDOS') IS NULL               ALTER TABLE dbo.LineLevelData ADD AgingDOS NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PanelNameLIS') IS NULL           ALTER TABLE dbo.LineLevelData ADD PanelNameLIS NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LineLevelCombination') IS NULL   ALTER TABLE dbo.LineLevelData ADD LineLevelCombination NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimLevelICD') IS NULL          ALTER TABLE dbo.LineLevelData ADD ClaimLevelICD NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'UpdatedDenial') IS NULL          ALTER TABLE dbo.LineLevelData ADD UpdatedDenial NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LineLevelDenialCode') IS NULL    ALTER TABLE dbo.LineLevelData ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimLevelDenialCode') IS NULL   ALTER TABLE dbo.LineLevelData ADD ClaimLevelDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PaymentPercent') IS NULL         ALTER TABLE dbo.LineLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimDeleted') IS NULL           ALTER TABLE dbo.LineLevelData ADD ClaimDeleted NVARCHAR(50) NULL;
GO

-- See ClaimLevelData: the LIS Panel test list does not fit NVARCHAR(500).
IF COL_LENGTH('dbo.LineLevelData', 'PanelNameLIS') <> -1
    ALTER TABLE dbo.LineLevelData ALTER COLUMN PanelNameLIS NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LineLevelData') AND name = 'IX_LineLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_LineLevelData_ClaimID ON dbo.LineLevelData (ClaimID);
GO

/* ── 4. LIMSMaster ────────────────────────────────────────────────────────── */
-- Column names match Schemas/CoreBio_LIMS_Schema.json (SQLColName). The importer loads by
-- destination column, so a column missing here is skipped without an error.
IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LIMSMaster
    (
        -- shared LIMS columns (same as every lab's LIMSMaster)
        OrderID               NVARCHAR(100)  NULL,   -- Order #
        Accession             NVARCHAR(100)  NULL,   -- Req #
        PaymentMethod         NVARCHAR(100)  NULL,
        Barcode               NVARCHAR(100)  NULL,   -- SID(s)
        Specimen              NVARCHAR(100)  NULL,   -- Sample type
        Collector             NVARCHAR(150)  NULL,
        OrderStatus           NVARCHAR(100)  NULL,
        BillingStatus         NVARCHAR(100)  NULL,
        SampleStatus          NVARCHAR(100)  NULL,
        RequestSubmittedDate  DATE           NULL,
        RequestCollectDate    DATE           NULL,   -- Collection Date
        ReqReceivedDate       DATE           NULL,   -- Date Accessioned
        ReqReportedDate       DATE           NULL,   -- Approved Date
        RessultedStatus       NVARCHAR(100)  NULL,
        ClientStatus          NVARCHAR(100)  NULL,
        TimetoResult          NVARCHAR(100)  NULL,   -- Time to Result
        TurnaroundTime        NVARCHAR(100)  NULL,
        Facility              NVARCHAR(255)  NULL,   -- Site
        [Performing Laboratory] NVARCHAR(255) NULL,
        Results               NVARCHAR(MAX)  NULL,
        PatientFirstName      NVARCHAR(150)  NULL,
        PatientLastName       NVARCHAR(150)  NULL,
        PatientDateOfBirth    DATE           NULL,   -- DOB
        VisitNumber           NVARCHAR(100)  NULL,
        AMDDOE                NVARCHAR(100)  NULL,
        AMDLBD                NVARCHAR(100)  NULL,
        TimetoBill            NVARCHAR(100)  NULL,   -- Time to Bill
        ClaimStatus           NVARCHAR(100)  NULL,
        BilledorNot           NVARCHAR(100)  NULL,   -- Billed
        Provider              NVARCHAR(255)  NULL,
        PrimaryInsurance      NVARCHAR(255)  NULL,   -- Primary Insurance
        PrimaryInsuranceID    NVARCHAR(150)  NULL,   -- Policy ID
        ICD10Codes            NVARCHAR(MAX)  NULL,   -- Icd Codes
        Tests                 NVARCHAR(MAX)  NULL,   -- Panels
        PanelCategory         NVARCHAR(255)  NULL,
        -- CoreBio sheet columns
        TrueFalse             NVARCHAR(10)   NULL,   -- T/F
        Requisition           NVARCHAR(100)  NULL,   -- RID
        Department            NVARCHAR(255)  NULL,   -- Dept
        PatientFullName       NVARCHAR(500)  NULL,   -- Patient Name
        ClinicName            NVARCHAR(500)  NULL,   -- Client
        DoctorFullName        NVARCHAR(500)  NULL,   -- Ordering Physician
        DoctorNPI             NVARCHAR(50)   NULL,   -- Provider NPI
        DueDate               DATE           NULL,   -- Due Date
        CreatedFrom           NVARCHAR(255)  NULL,   -- Created From
        AccessionedBy         NVARCHAR(255)  NULL,   -- Accessioned by
        TestCategory          NVARCHAR(255)  NULL,   -- Methods
        Samples               NVARCHAR(500)  NULL,   -- Sample #(s)
        Priority              NVARCHAR(100)  NULL,   -- Priority
        SarsCov2PCR           NVARCHAR(255)  NULL,   -- SARS-CoV-2 PCR
        FinalReportType       NVARCHAR(255)  NULL,   -- Final Report Type
        CollectionWeek        NVARCHAR(100)  NULL,   -- Week
        PanelName             NVARCHAR(500)  NULL,   -- Panel Name
        Status                NVARCHAR(255)  NULL,   -- Status
        DnrStatus             NVARCHAR(255)  NULL,   -- Dnr Status
        ResultStatus          NVARCHAR(255)  NULL,   -- Result Status
        NewStatus             NVARCHAR(255)  NULL,   -- New Status
        BillCategory          NVARCHAR(255)  NULL,   -- Bill Category
        SubStatus             NVARCHAR(255)  NULL,   -- Sub Status
        BilledDate            DATE           NULL,   -- Billed Date
        -- filled by the importer, not the sheet
        LabId                 INT            NULL,
        LabName               NVARCHAR(200)  NULL,
        SourceFile            NVARCHAR(260)  NULL,
        RunId                 VARCHAR(30)    NULL,
        AdditionalFields      NVARCHAR(MAX)  NULL,
        CreatedOn             DATETIME2(7)   NULL DEFAULT SYSDATETIME()
    );
    PRINT 'Created dbo.LIMSMaster.';
END
GO

-- CoreBio LIMS columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.LIMSMaster', 'TrueFalse') IS NULL        ALTER TABLE dbo.LIMSMaster ADD TrueFalse NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Requisition') IS NULL      ALTER TABLE dbo.LIMSMaster ADD Requisition NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Department') IS NULL       ALTER TABLE dbo.LIMSMaster ADD Department NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientFullName') IS NULL  ALTER TABLE dbo.LIMSMaster ADD PatientFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ClinicName') IS NULL       ALTER TABLE dbo.LIMSMaster ADD ClinicName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorFullName') IS NULL   ALTER TABLE dbo.LIMSMaster ADD DoctorFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorNPI') IS NULL        ALTER TABLE dbo.LIMSMaster ADD DoctorNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DueDate') IS NULL          ALTER TABLE dbo.LIMSMaster ADD DueDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'CreatedFrom') IS NULL      ALTER TABLE dbo.LIMSMaster ADD CreatedFrom NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'AccessionedBy') IS NULL    ALTER TABLE dbo.LIMSMaster ADD AccessionedBy NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'TestCategory') IS NULL     ALTER TABLE dbo.LIMSMaster ADD TestCategory NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Samples') IS NULL          ALTER TABLE dbo.LIMSMaster ADD Samples NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Priority') IS NULL         ALTER TABLE dbo.LIMSMaster ADD Priority NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SarsCov2PCR') IS NULL      ALTER TABLE dbo.LIMSMaster ADD SarsCov2PCR NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'FinalReportType') IS NULL  ALTER TABLE dbo.LIMSMaster ADD FinalReportType NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'CollectionWeek') IS NULL   ALTER TABLE dbo.LIMSMaster ADD CollectionWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PanelName') IS NULL        ALTER TABLE dbo.LIMSMaster ADD PanelName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Status') IS NULL           ALTER TABLE dbo.LIMSMaster ADD Status NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DnrStatus') IS NULL        ALTER TABLE dbo.LIMSMaster ADD DnrStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ResultStatus') IS NULL     ALTER TABLE dbo.LIMSMaster ADD ResultStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'NewStatus') IS NULL        ALTER TABLE dbo.LIMSMaster ADD NewStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BillCategory') IS NULL     ALTER TABLE dbo.LIMSMaster ADD BillCategory NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SubStatus') IS NULL        ALTER TABLE dbo.LIMSMaster ADD SubStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BilledDate') IS NULL       ALTER TABLE dbo.LIMSMaster ADD BilledDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'LabId') IS NULL            ALTER TABLE dbo.LIMSMaster ADD LabId INT NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'LabName') IS NULL          ALTER TABLE dbo.LIMSMaster ADD LabName NVARCHAR(200) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SourceFile') IS NULL       ALTER TABLE dbo.LIMSMaster ADD SourceFile NVARCHAR(260) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RunId') IS NULL            ALTER TABLE dbo.LIMSMaster ADD RunId VARCHAR(30) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'AdditionalFields') IS NULL ALTER TABLE dbo.LIMSMaster ADD AdditionalFields NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'IX_LIMSMaster_Accession')
    CREATE NONCLUSTERED INDEX IX_LIMSMaster_Accession ON dbo.LIMSMaster (Accession);
GO

PRINT 'CoreBio lab tables are up to date.';
GO

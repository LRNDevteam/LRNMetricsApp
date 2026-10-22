/*
    TexasDiagnostic - lab database tables for LRN.MasterFileProcessorWorker.
    Run against the TEXAS DIAGNOSTIC lab database (TexasDiagnostic_LRN), not LRNMaster.

    What the worker writes here:
      dbo.LineClaimFileLogs  one row per load (LineClaimFileLogRepository)
      dbo.ClaimLevelData     "Claim Level" sheet - TRUNCATE + SqlBulkCopy per run
      dbo.LineLevelData      "Line Level" sheet  - TRUNCATE + SqlBulkCopy per run
      dbo.LIMSMaster         Texas_LIMS Master File - TRUNCATE + SqlBulkCopy per run

    Built from the CoreBio tables, then aligned to:
      Schemas/LabMappings/TexasDiagnosticFieldMappings.json   (ClaimLevelData / LineLevelData SqlColumn)
      Schemas/TexasDiagnostic_LIMS_Schema.json                (LIMSMaster SQLColName)
    Mapping source: AveragesTable_AllAccounts_Field Mapping_V1.20.xlsx, column 'Texas Dx' / 'TexasDx'.
    SqlBulkCopy fails the load outright if a mapped column is missing or a value does not fit, and
    the LIMS importer silently skips a missing column, so keep them in step.

    Added for Texas Diagnostic:
      ClaimLevelData   UID, TF, EncCptTc, EndDOS, EntryWeek, LineLevelCPT, DepositWeek, CheckNumber,
                       DeniedWeek, OriginalDenialCode, LineLevelDenialCode, ClaimLevelDenialCode,
                       LineLevelICD, ExpectedPayment, TimeToPay
      LineLevelData    TF, EncCptTc, AgingDOS, AgingDOE, EntryWeek, BilledWeek, LineLevelCPT,
                       DepositWeek, CheckNumber, DeniedWeek, OriginalDenialCode, ClaimLevelDenialCode,
                       ClaimLevelICD, MedicareFeeSchedule, ExpectedPayment, PaymentPercent
      LIMSMaster       Requisition, Gender, State, PatientCode, SalesRepName, CRN, CollectionWeek,
                       ResultedDate (plus the usual sheet columns)
    Denials: ClaimLevelData.DenialCode is "Claim Level Denial Code" (V1.20); LineLevelData.DenialCode is
    "Line Level Denial Code". The sheets' "Denial Code" (original code) lands in OriginalDenialCode.
    ICD: ClaimLevelData.ICDCode is "Claim Level ICD", LineLevelData.ICDCode is "Line Level ICD".
    Columns not loaded from the file (DenialCodeNormalized, DenialDescription, Aging buckets, ...)
    are kept: other processes write them after the load.

    Re-runnable: tables are created only when missing, and every Texas Diagnostic column is added
    only when missing, so it is also safe on a database cloned from another lab.
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
        ClaimID                       NVARCHAR(500)  NULL,   -- VisitNum
        AccessionNumber               NVARCHAR(1000) NULL,   -- Accession (can list several)
        SourceFileID                  NVARCHAR(1000) NULL,
        IngestedOn                    NVARCHAR(500)  NULL,
        CsvRowHash                    NVARCHAR(500)  NULL,
        PayerName_Raw                 NVARCHAR(500)  NULL,   -- Payer Name
        PayerName                     NVARCHAR(500)  NULL,
        Payer_Code                    NVARCHAR(500)  NULL,
        Payer_Common_Code             NVARCHAR(500)  NULL,
        Payer_Group_Code              NVARCHAR(500)  NULL,
        Global_Payer_ID               NVARCHAR(500)  NULL,
        PayerType                     NVARCHAR(500)  NULL,   -- FinancialClass
        BillingProvider               NVARCHAR(500)  NULL,   -- Provider
        ReferringProvider             NVARCHAR(500)  NULL,   -- ReferringProvider
        ClinicName                    NVARCHAR(500)  NULL,   -- Clinic Name
        SalesRepname                  NVARCHAR(500)  NULL,
        PatientID                     NVARCHAR(500)  NULL,   -- ChartNum
        PatientDOB                    NVARCHAR(500)  NULL,   -- DOB
        DateofService                 NVARCHAR(500)  NULL,   -- BeginDOS
        ChargeEnteredDate             NVARCHAR(500)  NULL,   -- DOE
        FirstBilledDate               NVARCHAR(500)  NULL,   -- LastBillDate
        Panelname                     NVARCHAR(500)  NULL,   -- Panel
        CPTCodeXUnitsXModifier        NVARCHAR(MAX)  NULL,   -- rebuilt from the line level
        POS                           NVARCHAR(500)  NULL,
        TOS                           NVARCHAR(500)  NULL,
        ChargeAmount                  NVARCHAR(500)  NULL,   -- TotalCharge
        AllowedAmount                 NVARCHAR(500)  NULL,   -- TotalAllowed
        InsurancePayment              NVARCHAR(500)  NULL,   -- CarrierPayment
        PatientPayment                NVARCHAR(500)  NULL,   -- PatientPayment
        TotalPayments                 NVARCHAR(500)  NULL,
        InsuranceAdjustments          NVARCHAR(500)  NULL,   -- CarrierWO
        PatientAdjustments            NVARCHAR(500)  NULL,   -- PatientWO
        TotalAdjustments              NVARCHAR(500)  NULL,
        InsuranceBalance              NVARCHAR(500)  NULL,   -- CarrierBalance
        PatientBalance                NVARCHAR(500)  NULL,   -- PatientBalance
        TotalBalance                  NVARCHAR(500)  NULL,
        CheckDate                     NVARCHAR(500)  NULL,   -- Deposit Date
        ClaimStatus                   NVARCHAR(500)  NULL,   -- Claim Status
        DenialCode                    NVARCHAR(MAX)  NULL,   -- Claim Level Denial Code
        ICDCode                       NVARCHAR(MAX)  NULL,   -- Claim Level ICD
        DaystoDOS                     NVARCHAR(500)  NULL,
        RollingDays                   NVARCHAR(500)  NULL,
        DaystoBill                    NVARCHAR(500)  NULL,
        DaystoPost                    NVARCHAR(500)  NULL,
        ICDPointer                    NVARCHAR(500)  NULL,
        InsertedDateTime              DATETIME       NOT NULL DEFAULT GETDATE(),
        -- lab columns
        PatientName                   NVARCHAR(1000) NULL,   -- PatientName
        PaymentPercent                NVARCHAR(100)  NULL,   -- Payment %
        Aging                         NVARCHAR(100)  NULL,
        BilledWeek                    NVARCHAR(500)  NULL,   -- Billed Week
        PostedWeek                    NVARCHAR(500)  NULL,
        FullyPaidCount                NVARCHAR(500)  NULL,   -- Fully Paid #
        FullyPaidAmount               NVARCHAR(500)  NULL,   -- Fully Paid $
        AdjudicatedAmount             NVARCHAR(500)  NULL,   -- Adjucticated $
        CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX)  NULL,   -- Claim Level CPT
        BilledUnbilled                NVARCHAR(100)  NULL,
        AgingBucket                   NVARCHAR(200)  NULL,
        AdjudicatedCount              NVARCHAR(500)  NULL,
        Days30Count                   NVARCHAR(500)  NULL,
        Days30Amount                  NVARCHAR(500)  NULL,
        Days60Count                   NVARCHAR(500)  NULL,
        Days60Amount                  NVARCHAR(500)  NULL,
        DOE_Year                      NVARCHAR(20)   NULL,
        DOE_Month                     NVARCHAR(20)   NULL,
        ClaimUID                      NVARCHAR(1000) NULL,
        AgingDOE                      NVARCHAR(500)  NULL,   -- Aging DOE
        AgingDOS                      NVARCHAR(500)  NULL,   -- Aging DOS
        PanelNameLIS                  NVARCHAR(MAX)  NULL,
        PanelNameBasedOnCPT           NVARCHAR(500)  NULL,
        InsuranceBalance_Decimal      AS (TRY_CAST(InsuranceBalance AS DECIMAL(18,2))) PERSISTED,
        AdditionalFields              NVARCHAR(MAX)  NULL,   -- unmapped CSV columns as JSON
        Facility                      NVARCHAR(500)  NULL,   -- Facility
        Modifier                      NVARCHAR(500)  NULL,
        DenialCodeNormalized          NVARCHAR(400)  NULL,
        DenialDescription             NVARCHAR(MAX)  NULL,
        SubscriberId                  NVARCHAR(1000) NULL,   -- SubscriberID
        BilledStatus                  NVARCHAR(MAX)  NULL,   -- Bill Status
        Adjudicated                   NVARCHAR(500)  NULL,   -- Adjucticated #
        Bucket30                      NVARCHAR(500)  NULL,   -- 30 Bucket #
        Bucket30Amount                NVARCHAR(500)  NULL,   -- 30 Bucket $
        Bucket60                      NVARCHAR(500)  NULL,   -- 60 Bucket #
        Bucket60Amount                NVARCHAR(500)  NULL,   -- 60 Bucket $
        LastBilledDate                NVARCHAR(500)  NULL,
        DenialDate                    NVARCHAR(500)  NULL,   -- Denial Date
        TotalInsuranceBalance         NVARCHAR(500)  NULL,
        OtherBalance                  NVARCHAR(500)  NULL,
        CPTCodeList                   NVARCHAR(MAX)  NULL,
        UnitsList                     NVARCHAR(500)  NULL,   -- Units
        ModifierList                  NVARCHAR(500)  NULL,   -- Modifier
        CptWithUnits                  NVARCHAR(MAX)  NULL,
        ChargeToDate                  NVARCHAR(500)  NULL,
        ChargeTotalPayments           NVARCHAR(500)  NULL,   -- TotalPayment
        ChargeTotalAdjustments        NVARCHAR(500)  NULL,   -- TotalWO
        PostingDate                   NVARCHAR(500)  NULL,   -- Posted Date
        PaymentPostedDate             NVARCHAR(500)  NULL,   -- Posted Date
        -- Texas Diagnostic only
        UID                           NVARCHAR(500)  NULL,   -- UID
        TF                            NVARCHAR(10)   NULL,   -- T/F
        EncCptTc                      NVARCHAR(500)  NULL,   -- ENC/CPT/TC
        EndDOS                        NVARCHAR(500)  NULL,   -- EndDOS
        EntryWeek                     NVARCHAR(100)  NULL,   -- Entry Week
        LineLevelCPT                  NVARCHAR(MAX)  NULL,   -- Line Level CPT
        DepositWeek                   NVARCHAR(100)  NULL,   -- DOD Week
        CheckNumber                   NVARCHAR(500)  NULL,   -- Cheque No
        DeniedWeek                    NVARCHAR(100)  NULL,   -- Denied Week
        OriginalDenialCode            NVARCHAR(MAX)  NULL,   -- Denial Code
        LineLevelDenialCode           NVARCHAR(MAX)  NULL,   -- Line Level Denial Code
        ClaimLevelDenialCode          NVARCHAR(MAX)  NULL,   -- Claim Level Denial Code
        LineLevelICD                  NVARCHAR(MAX)  NULL,   -- Line Level ICD
        ExpectedPayment               NVARCHAR(500)  NULL,   -- Expected Payment
        TimeToPay                     NVARCHAR(100)  NULL,   -- Time to Pay
        PRIMARY KEY CLUSTERED (RecordId ASC)
    );
    PRINT 'Created dbo.ClaimLevelData.';
END
GO

-- Texas Diagnostic claim columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.ClaimLevelData', 'LastBilledDate') IS NULL         ALTER TABLE dbo.ClaimLevelData ADD LastBilledDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DenialDate') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD DenialDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'UnitsList') IS NULL              ALTER TABLE dbo.ClaimLevelData ADD UnitsList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ModifierList') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD ModifierList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalPayments') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD ChargeTotalPayments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalAdjustments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD ChargeTotalAdjustments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PostingDate') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD PostingDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PaymentPostedDate') IS NULL      ALTER TABLE dbo.ClaimLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'UID') IS NULL                    ALTER TABLE dbo.ClaimLevelData ADD UID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TF') IS NULL                     ALTER TABLE dbo.ClaimLevelData ADD TF NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'EncCptTc') IS NULL               ALTER TABLE dbo.ClaimLevelData ADD EncCptTc NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'EndDOS') IS NULL                 ALTER TABLE dbo.ClaimLevelData ADD EndDOS NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'EntryWeek') IS NULL              ALTER TABLE dbo.ClaimLevelData ADD EntryWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LineLevelCPT') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD LineLevelCPT NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DepositWeek') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD DepositWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CheckNumber') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD CheckNumber NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DeniedWeek') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD DeniedWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OriginalDenialCode') IS NULL     ALTER TABLE dbo.ClaimLevelData ADD OriginalDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LineLevelDenialCode') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimLevelDenialCode') IS NULL   ALTER TABLE dbo.ClaimLevelData ADD ClaimLevelDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'LineLevelICD') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD LineLevelICD NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ExpectedPayment') IS NULL        ALTER TABLE dbo.ClaimLevelData ADD ExpectedPayment NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TimeToPay') IS NULL              ALTER TABLE dbo.ClaimLevelData ADD TimeToPay NVARCHAR(100) NULL;
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
        ClaimID                  NVARCHAR(500)  NULL,   -- VisitNum
        AccessionNumber          NVARCHAR(1000) NULL,   -- Accession (can list several)
        SourceFileID             NVARCHAR(1000) NULL,
        IngestedOn               NVARCHAR(500)  NULL,
        CsvRowHash               NVARCHAR(500)  NULL,
        PayerName_Raw            NVARCHAR(500)  NULL,   -- Payer Name
        PayerName                NVARCHAR(500)  NULL,
        Payer_Code               NVARCHAR(500)  NULL,
        Payer_Common_Code        NVARCHAR(500)  NULL,
        Payer_Group_Code         NVARCHAR(500)  NULL,
        Global_Payer_ID          NVARCHAR(500)  NULL,
        PayerType                NVARCHAR(500)  NULL,   -- FinancialClass
        BillingProvider          NVARCHAR(500)  NULL,   -- Provider
        ReferringProvider        NVARCHAR(500)  NULL,   -- ReferringProvider
        ClinicName               NVARCHAR(500)  NULL,   -- Clinic Name
        SalesRepname             NVARCHAR(500)  NULL,
        PatientID                NVARCHAR(500)  NULL,   -- ChartNum
        PatientDOB               NVARCHAR(500)  NULL,   -- DOB
        DateofService            NVARCHAR(500)  NULL,   -- BeginDOS
        ChargeEnteredDate        NVARCHAR(500)  NULL,   -- DOE
        FirstBilledDate          NVARCHAR(500)  NULL,   -- LastBillDate
        Panelname                NVARCHAR(500)  NULL,   -- Panel
        CPTCode                  NVARCHAR(500)  NULL,   -- CPT
        Units                    NVARCHAR(500)  NULL,   -- Units
        Modifier                 NVARCHAR(500)  NULL,   -- Modifier
        POS                      NVARCHAR(500)  NULL,
        TOS                      NVARCHAR(500)  NULL,
        ChargeAmount             NVARCHAR(500)  NULL,   -- TotalCharge
        ChargeAmountPerUnit      NVARCHAR(500)  NULL,
        AllowedAmount            NVARCHAR(500)  NULL,   -- TotalAllowed
        AllowedAmountPerUnit     NVARCHAR(500)  NULL,
        InsurancePayment         NVARCHAR(500)  NULL,   -- CarrierPayment
        InsurancePaymentPerUnit  NVARCHAR(500)  NULL,
        PatientPayment           NVARCHAR(500)  NULL,   -- PatientPayment
        PatientPaymentPerUnit    NVARCHAR(500)  NULL,
        TotalPayments            NVARCHAR(500)  NULL,
        InsuranceAdjustments     NVARCHAR(500)  NULL,   -- CarrierWO
        PatientAdjustments       NVARCHAR(500)  NULL,   -- PatientWO
        TotalAdjustments         NVARCHAR(500)  NULL,
        InsuranceBalance         NVARCHAR(500)  NULL,   -- CarrierBalance
        PatientBalance           NVARCHAR(500)  NULL,   -- PatientBalance
        PatientBalancePerUnit    NVARCHAR(500)  NULL,
        TotalBalance             NVARCHAR(500)  NULL,
        CheckDate                NVARCHAR(500)  NULL,   -- Deposit Date
        PostingDate              NVARCHAR(500)  NULL,   -- Posted Date
        ClaimStatus              NVARCHAR(500)  NULL,   -- copied from the claim sheet
        PayStatus                NVARCHAR(500)  NULL,
        DenialCode               NVARCHAR(MAX)  NULL,   -- Line Level Denial Code
        DenialDate               NVARCHAR(500)  NULL,   -- Denial Date
        ICDCode                  NVARCHAR(MAX)  NULL,   -- Line Level ICD
        DaystoDOS                NVARCHAR(500)  NULL,
        RollingDays              NVARCHAR(500)  NULL,
        DaystoBill               NVARCHAR(500)  NULL,
        DaystoPost               NVARCHAR(500)  NULL,
        ICDPointer               NVARCHAR(500)  NULL,
        InsertedDateTime         DATETIME       NOT NULL DEFAULT GETDATE(),
        -- lab columns
        PatientName              NVARCHAR(1000) NULL,   -- PatientName
        SubscriberId             NVARCHAR(500)  NULL,   -- SubscriberID
        PaymentPostedDate        NVARCHAR(500)  NULL,   -- Posted Date
        ResponsibleParty         NVARCHAR(500)  NULL,
        EndDOS                   NVARCHAR(500)  NULL,   -- EndDOS
        BillOccurance            NVARCHAR(500)  NULL,
        EntryUser                NVARCHAR(500)  NULL,
        CPTUnits                 NVARCHAR(500)  NULL,
        CPTMOD                   NVARCHAR(500)  NULL,
        PostedWeek               NVARCHAR(500)  NULL,
        LineLevelUID             NVARCHAR(1000) NULL,
        Source                   NVARCHAR(500)  NULL,
        InsuranceBalance_Decimal AS (TRY_CAST(InsuranceBalance AS DECIMAL(18,2))) PERSISTED,
        AdditionalFields         NVARCHAR(MAX)  NULL,   -- unmapped CSV columns as JSON
        Facility                 NVARCHAR(500)  NULL,   -- Facility
        CPTs                     NVARCHAR(500)  NULL,
        DenialCodeNormalized     NVARCHAR(400)  NULL,
        DenialDescription        NVARCHAR(MAX)  NULL,
        UID                      NVARCHAR(500)  NULL,   -- UID
        LastBilledDate           NVARCHAR(500)  NULL,
        CptWithUnits             NVARCHAR(MAX)  NULL,
        CPTModifier              NVARCHAR(MAX)  NULL,
        ClaimCPTs                NVARCHAR(MAX)  NULL,   -- Claim Level CPT
        TotalInsuranceBalance    NVARCHAR(500)  NULL,
        OtherBalance             NVARCHAR(500)  NULL,
        ChargeToDate             NVARCHAR(500)  NULL,
        ChargeTotalPayments      NVARCHAR(500)  NULL,
        ChargeTotalAdjustments   NVARCHAR(500)  NULL,
        -- Texas Diagnostic only
        TF                       NVARCHAR(10)   NULL,   -- T/F
        EncCptTc                 NVARCHAR(500)  NULL,   -- ENC/CPT/TC
        AgingDOS                 NVARCHAR(500)  NULL,   -- Aging DOS
        AgingDOE                 NVARCHAR(500)  NULL,   -- Aging DOE
        EntryWeek                NVARCHAR(100)  NULL,   -- Entry Week
        BilledWeek               NVARCHAR(100)  NULL,   -- Billed Week
        LineLevelCPT             NVARCHAR(MAX)  NULL,   -- Line Level CPT
        DepositWeek              NVARCHAR(100)  NULL,   -- DOD Week
        CheckNumber              NVARCHAR(500)  NULL,   -- Cheque No
        DeniedWeek               NVARCHAR(100)  NULL,   -- Denied Week
        OriginalDenialCode       NVARCHAR(MAX)  NULL,   -- Denial Code
        ClaimLevelDenialCode     NVARCHAR(MAX)  NULL,   -- Claim Level Denial Code
        ClaimLevelICD            NVARCHAR(MAX)  NULL,   -- Claim Level ICD
        MedicareFeeSchedule      NVARCHAR(500)  NULL,   -- Medicare Fee Schedule
        ExpectedPayment          NVARCHAR(500)  NULL,   -- Expected Payment
        PaymentPercent           NVARCHAR(100)  NULL,   -- Payment %
        PRIMARY KEY CLUSTERED (RecordId ASC)
    );
    PRINT 'Created dbo.LineLevelData.';
END
GO

-- Texas Diagnostic line columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.LineLevelData', 'EndDOS') IS NULL               ALTER TABLE dbo.LineLevelData ADD EndDOS NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'UID') IS NULL                  ALTER TABLE dbo.LineLevelData ADD UID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimCPTs') IS NULL            ALTER TABLE dbo.LineLevelData ADD ClaimCPTs NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TF') IS NULL                   ALTER TABLE dbo.LineLevelData ADD TF NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'EncCptTc') IS NULL             ALTER TABLE dbo.LineLevelData ADD EncCptTc NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AgingDOS') IS NULL             ALTER TABLE dbo.LineLevelData ADD AgingDOS NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AgingDOE') IS NULL             ALTER TABLE dbo.LineLevelData ADD AgingDOE NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'EntryWeek') IS NULL            ALTER TABLE dbo.LineLevelData ADD EntryWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'BilledWeek') IS NULL           ALTER TABLE dbo.LineLevelData ADD BilledWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'LineLevelCPT') IS NULL         ALTER TABLE dbo.LineLevelData ADD LineLevelCPT NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DepositWeek') IS NULL          ALTER TABLE dbo.LineLevelData ADD DepositWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CheckNumber') IS NULL          ALTER TABLE dbo.LineLevelData ADD CheckNumber NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DeniedWeek') IS NULL           ALTER TABLE dbo.LineLevelData ADD DeniedWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OriginalDenialCode') IS NULL   ALTER TABLE dbo.LineLevelData ADD OriginalDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimLevelDenialCode') IS NULL ALTER TABLE dbo.LineLevelData ADD ClaimLevelDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimLevelICD') IS NULL        ALTER TABLE dbo.LineLevelData ADD ClaimLevelICD NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'MedicareFeeSchedule') IS NULL  ALTER TABLE dbo.LineLevelData ADD MedicareFeeSchedule NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ExpectedPayment') IS NULL      ALTER TABLE dbo.LineLevelData ADD ExpectedPayment NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PaymentPercent') IS NULL       ALTER TABLE dbo.LineLevelData ADD PaymentPercent NVARCHAR(100) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LineLevelData') AND name = 'IX_LineLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_LineLevelData_ClaimID ON dbo.LineLevelData (ClaimID);
GO

/* ── 4. LIMSMaster ────────────────────────────────────────────────────────── */
-- Column names match Schemas/TexasDiagnostic_LIMS_Schema.json (SQLColName). The importer loads by
-- destination column, so a column missing here is skipped without an error.
IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LIMSMaster
    (
        -- shared LIMS columns (same as every lab's LIMSMaster)
        OrderID               NVARCHAR(100)  NULL,
        Accession             NVARCHAR(500)  NULL,   -- Sample IDs (can list several)
        PaymentMethod         NVARCHAR(100)  NULL,   -- Payment status
        Barcode               NVARCHAR(100)  NULL,
        Specimen              NVARCHAR(100)  NULL,
        Collector             NVARCHAR(150)  NULL,
        OrderStatus           NVARCHAR(100)  NULL,   -- Order status
        BillingStatus         NVARCHAR(100)  NULL,
        SampleStatus          NVARCHAR(100)  NULL,
        RequestSubmittedDate  DATE           NULL,
        RequestCollectDate    DATE           NULL,   -- Collection Date
        ReqReceivedDate       DATE           NULL,   -- Accession Date
        ReqReportedDate       DATE           NULL,   -- Report Date
        RessultedStatus       NVARCHAR(100)  NULL,
        ClientStatus          NVARCHAR(100)  NULL,
        TimetoResult          NVARCHAR(100)  NULL,   -- Time to Result
        TurnaroundTime        NVARCHAR(100)  NULL,
        Facility              NVARCHAR(255)  NULL,
        [Performing Laboratory] NVARCHAR(255) NULL,
        Results               NVARCHAR(MAX)  NULL,
        PatientFirstName      NVARCHAR(150)  NULL,   -- Patient Firstname
        PatientLastName       NVARCHAR(150)  NULL,   -- Patient Lastname
        PatientDateOfBirth    DATE           NULL,   -- DOB
        VisitNumber           NVARCHAR(100)  NULL,
        AMDDOE                NVARCHAR(100)  NULL,
        AMDLBD                NVARCHAR(100)  NULL,
        TimetoBill            NVARCHAR(100)  NULL,   -- Time to Bill
        ClaimStatus           NVARCHAR(100)  NULL,
        BilledorNot           NVARCHAR(100)  NULL,
        Provider              NVARCHAR(255)  NULL,
        PrimaryInsurance      NVARCHAR(255)  NULL,   -- Primary Insurance
        PrimaryInsuranceID    NVARCHAR(150)  NULL,   -- Primary policyId
        ICD10Codes            NVARCHAR(MAX)  NULL,   -- ICD codes
        Tests                 NVARCHAR(MAX)  NULL,   -- Panels
        PanelCategory         NVARCHAR(255)  NULL,
        -- Texas Diagnostic sheet columns
        TrueFalse             NVARCHAR(10)   NULL,   -- T/F
        Requisition           NVARCHAR(100)  NULL,   -- Requisition ID
        PatientFullName       NVARCHAR(500)  NULL,   -- Patient Name
        Gender                NVARCHAR(50)   NULL,   -- Gender
        State                 NVARCHAR(100)  NULL,   -- State
        PatientCode           NVARCHAR(100)  NULL,   -- Patient ID
        DoctorFullName        NVARCHAR(500)  NULL,   -- Provider Name
        DoctorNPI             NVARCHAR(50)   NULL,   -- Provider NPI
        SalesRepName          NVARCHAR(500)  NULL,   -- Sales Representatives
        CRN                   NVARCHAR(255)  NULL,   -- CRN
        TestCategory          NVARCHAR(255)  NULL,   -- Category
        PanelName             NVARCHAR(500)  NULL,   -- Panel Name
        CollectionWeek        NVARCHAR(100)  NULL,   -- Collection Week
        ResultedDate          DATE           NULL,   -- Resulted Date
        ResultStatus          NVARCHAR(255)  NULL,   -- Result Status
        ClinicName            NVARCHAR(500)  NULL,   -- Client
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

-- Texas Diagnostic LIMS columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.LIMSMaster', 'TrueFalse') IS NULL        ALTER TABLE dbo.LIMSMaster ADD TrueFalse NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Requisition') IS NULL      ALTER TABLE dbo.LIMSMaster ADD Requisition NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientFullName') IS NULL  ALTER TABLE dbo.LIMSMaster ADD PatientFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Gender') IS NULL           ALTER TABLE dbo.LIMSMaster ADD Gender NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'State') IS NULL            ALTER TABLE dbo.LIMSMaster ADD State NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientCode') IS NULL      ALTER TABLE dbo.LIMSMaster ADD PatientCode NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorFullName') IS NULL   ALTER TABLE dbo.LIMSMaster ADD DoctorFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorNPI') IS NULL        ALTER TABLE dbo.LIMSMaster ADD DoctorNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SalesRepName') IS NULL     ALTER TABLE dbo.LIMSMaster ADD SalesRepName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'CRN') IS NULL              ALTER TABLE dbo.LIMSMaster ADD CRN NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'TestCategory') IS NULL     ALTER TABLE dbo.LIMSMaster ADD TestCategory NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PanelName') IS NULL        ALTER TABLE dbo.LIMSMaster ADD PanelName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'CollectionWeek') IS NULL   ALTER TABLE dbo.LIMSMaster ADD CollectionWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ResultedDate') IS NULL     ALTER TABLE dbo.LIMSMaster ADD ResultedDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ResultStatus') IS NULL     ALTER TABLE dbo.LIMSMaster ADD ResultStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ClinicName') IS NULL       ALTER TABLE dbo.LIMSMaster ADD ClinicName NVARCHAR(500) NULL;
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

PRINT 'TexasDiagnostic lab tables are up to date.';
GO

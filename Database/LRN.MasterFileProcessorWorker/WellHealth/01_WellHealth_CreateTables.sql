/*
    WellHealth - lab database tables for LRN.MasterFileProcessorWorker.
    Run against the WELLHEALTH lab database, not LRNMaster.

    What the worker writes here:
      dbo.LineClaimFileLogs  one row per load (LineClaimFileLogRepository)
      dbo.ClaimLevelData     "Claim Level" sheet - TRUNCATE + SqlBulkCopy per run
      dbo.LineLevelData      "Line Level" sheet  - TRUNCATE + SqlBulkCopy per run
      dbo.LIMSMaster         "LIMS Mater" sheet  - TRUNCATE + SqlBulkCopy per run

    Built from the live Analyze Pathology tables, then aligned to:
      Schemas/LabMappings/WellHealthFieldMappings.json   (ClaimLevelData / LineLevelData SqlColumn)
      Schemas/WellHealth_LIMS_Schema.json                (LIMSMaster SQLColName)
    SqlBulkCopy fails the load outright if a mapped column is missing, and the LIMS importer silently
    skips one, so keep them in step.

    Dropped from Analyze Pathology (only its file fills them):
      ClaimLevelData / LineLevelData  OrderingProviderID, TF
      LIMSMaster                      OrganizationCode, EnteredDate, PatientCode, DoctorNPI,
                                      ReferringProvider, SystemName, ChargeClaimId, PanelName
    Added for WellHealth:
      ClaimLevelData   DepositWeek, ClaimBillingProviderID, ChargePanelID, BalanceAtCollections
      LineLevelData    ClaimBillingProviderID, ChargePanelID, BalanceAtCollections
      LIMSMaster       Requisition, TestCategory, ProcessDate, PatientFullName, BillType,
                       PhysicianSignature, State
    Columns not loaded from the file (DenialCodeNormalized, DenialDescription, Aging buckets, ...)
    are kept: other processes write them after the load.

    Re-runnable: tables are created only when missing, and every WellHealth column is added only
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
        ClaimID                       NVARCHAR(500)  NULL,   -- Claim ID
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
        ClinicName                    NVARCHAR(500)  NULL,   -- Facility Name
        SalesRepname                  NVARCHAR(500)  NULL,
        PatientID                     NVARCHAR(500)  NULL,   -- Claim Patient ID
        PatientDOB                    NVARCHAR(500)  NULL,   -- Patient Birthday
        DateofService                 NVARCHAR(500)  NULL,   -- Charge From Date
        ChargeEnteredDate             NVARCHAR(500)  NULL,   -- Charge Entered Date
        FirstBilledDate               NVARCHAR(500)  NULL,   -- Charge First Bill Date
        Panelname                     NVARCHAR(500)  NULL,   -- Panel Name
        CPTCodeXUnitsXModifier        NVARCHAR(MAX)  NULL,
        POS                           NVARCHAR(500)  NULL,   -- Charge POS Code
        TOS                           NVARCHAR(500)  NULL,
        ChargeAmount                  NVARCHAR(500)  NULL,   -- Charge Amount
        AllowedAmount                 NVARCHAR(500)  NULL,
        InsurancePayment              NVARCHAR(500)  NULL,   -- Charge Insurance Payments
        PatientPayment                NVARCHAR(500)  NULL,   -- Charge Patient Payments
        TotalPayments                 NVARCHAR(500)  NULL,
        InsuranceAdjustments          NVARCHAR(500)  NULL,   -- Charge Insurance Adjustments
        PatientAdjustments            NVARCHAR(500)  NULL,   -- Charge Patient Adjustments
        TotalAdjustments              NVARCHAR(500)  NULL,
        InsuranceBalance              NVARCHAR(500)  NULL,   -- Charge Balance Due Ins
        PatientBalance                NVARCHAR(500)  NULL,   -- Charge Balance Due Pat
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
        PostedWeek                    NVARCHAR(500)  NULL,   -- Payment Entered  Week
        FullyPaidCount                NVARCHAR(500)  NULL,   -- Fully Paid #
        FullyPaidAmount               NVARCHAR(500)  NULL,   -- Fully Paid $
        AdjudicatedAmount             NVARCHAR(500)  NULL,   -- Adjucticated $
        CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX)  NULL,   -- CPT Combination
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
        PanelNameLIS                  NVARCHAR(500)  NULL,
        PanelNameBasedOnCPT           NVARCHAR(500)  NULL,
        InsuranceBalance_Decimal      AS (TRY_CAST(InsuranceBalance AS DECIMAL(18,2))) PERSISTED,
        AdditionalFields              NVARCHAR(MAX)  NULL,   -- unmapped CSV columns as JSON
        Facility                      NVARCHAR(500)  NULL,   -- Office Name
        Modifier                      NVARCHAR(500)  NULL,
        DenialCodeNormalized          NVARCHAR(400)  NULL,
        DenialDescription             NVARCHAR(MAX)  NULL,
        SubscriberId                  NVARCHAR(1000) NULL,
        BilledStatus                  NVARCHAR(MAX)  NULL,   -- Bill Status
        Adjudicated                   NVARCHAR(500)  NULL,   -- Adjucticated #
        Bucket30                      NVARCHAR(500)  NULL,   -- 30 Bucket #
        Bucket30Amount                NVARCHAR(500)  NULL,   -- 30 Bucket $
        Bucket60                      NVARCHAR(500)  NULL,   -- 60 Bucket #
        Bucket60Amount                NVARCHAR(500)  NULL,   -- 60 Bucket $
        LastBilledDate                NVARCHAR(500)  NULL,   -- Charge Last Bill Date
        DenialDate                    NVARCHAR(500)  NULL,   -- Denial Deposit Date
        TotalInsuranceBalance         NVARCHAR(500)  NULL,   -- Total Insurance Balance
        OtherBalance                  NVARCHAR(500)  NULL,   -- Charge Balance Due Other
        CPTCodeList                   NVARCHAR(MAX)  NULL,   -- Charge CPT Code
        UnitsList                     NVARCHAR(500)  NULL,   -- Charge Units
        ModifierList                  NVARCHAR(500)  NULL,   -- Charge Modifier List
        CptWithUnits                  NVARCHAR(MAX)  NULL,   -- CPTunits
        ChargeToDate                  NVARCHAR(500)  NULL,   -- Charge To Date
        ChargeTotalPayments           NVARCHAR(500)  NULL,   -- Charge Total Payments
        ChargeTotalAdjustments        NVARCHAR(500)  NULL,   -- Charge Total Adjustments
        PostingDate                   NVARCHAR(500)  NULL,   -- Payment Entered
        PaymentPostedDate             NVARCHAR(500)  NULL,   -- Payment Entered
        -- WellHealth only
        DepositWeek                   NVARCHAR(500)  NULL,   -- Deposit Week
        ClaimBillingProviderID        NVARCHAR(500)  NULL,   -- Claim Billing Provider ID
        ChargePanelID                 NVARCHAR(500)  NULL,   -- Charge Panel ID
        BalanceAtCollections          NVARCHAR(500)  NULL,   -- Charge Balance At Collections
        PRIMARY KEY CLUSTERED (RecordId ASC)
    );
    PRINT 'Created dbo.ClaimLevelData.';
END
GO

-- WellHealth claim columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.ClaimLevelData', 'DepositWeek') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD DepositWeek NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ClaimBillingProviderID') IS NULL ALTER TABLE dbo.ClaimLevelData ADD ClaimBillingProviderID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargePanelID') IS NULL          ALTER TABLE dbo.ClaimLevelData ADD ChargePanelID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BalanceAtCollections') IS NULL   ALTER TABLE dbo.ClaimLevelData ADD BalanceAtCollections NVARCHAR(500) NULL;
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
        ClaimID                  NVARCHAR(500)  NULL,   -- Claim ID
        AccessionNumber          NVARCHAR(500)  NULL,   -- Claim Reference # ("D-" prefixed on this sheet)
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
        ClinicName               NVARCHAR(500)  NULL,   -- Facility Name
        SalesRepname             NVARCHAR(500)  NULL,
        PatientID                NVARCHAR(500)  NULL,   -- Claim Patient ID
        PatientDOB               NVARCHAR(500)  NULL,   -- Patient Birthday
        DateofService            NVARCHAR(500)  NULL,   -- Charge From Date
        ChargeEnteredDate        NVARCHAR(500)  NULL,   -- Charge Entered Date
        FirstBilledDate          NVARCHAR(500)  NULL,   -- Charge First Bill Date
        Panelname                NVARCHAR(500)  NULL,
        CPTCode                  NVARCHAR(500)  NULL,   -- Charge CPT Code
        Units                    NVARCHAR(500)  NULL,   -- Charge Units
        Modifier                 NVARCHAR(500)  NULL,   -- ChargeModifierList
        POS                      NVARCHAR(500)  NULL,   -- Charge POS Code
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
        PatientBalance           NVARCHAR(500)  NULL,   -- Charge Balance Due Pat
        PatientBalancePerUnit    NVARCHAR(500)  NULL,
        TotalBalance             NVARCHAR(500)  NULL,
        CheckDate                NVARCHAR(500)  NULL,   -- Deposit Date
        PostingDate              NVARCHAR(500)  NULL,   -- Payment Entered
        ClaimStatus              NVARCHAR(500)  NULL,   -- copied from the claim sheet
        PayStatus                NVARCHAR(500)  NULL,
        DenialCode               NVARCHAR(MAX)  NULL,   -- Denial Code
        DenialDate               NVARCHAR(500)  NULL,   -- Denial Deposit Date
        ICDCode                  NVARCHAR(500)  NULL,   -- Claim ICD List
        DaystoDOS                NVARCHAR(500)  NULL,
        RollingDays              NVARCHAR(500)  NULL,
        DaystoBill               NVARCHAR(500)  NULL,
        DaystoPost               NVARCHAR(500)  NULL,
        ICDPointer               NVARCHAR(500)  NULL,   -- Charge Diagnosis Pointer List
        InsertedDateTime         DATETIME       NOT NULL DEFAULT GETDATE(),
        -- lab columns
        PatientName              NVARCHAR(1000) NULL,   -- Patient Full Name
        SubscriberId             NVARCHAR(500)  NULL,
        PaymentPostedDate        NVARCHAR(500)  NULL,   -- Payment Entered
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
        Facility                 NVARCHAR(500)  NULL,   -- Office Name
        CPTs                     NVARCHAR(500)  NULL,
        DenialCodeNormalized     NVARCHAR(400)  NULL,
        DenialDescription        NVARCHAR(MAX)  NULL,
        UID                      NVARCHAR(500)  NULL,   -- UNID
        LastBilledDate           NVARCHAR(500)  NULL,   -- Charge Last Bill Date
        CptWithUnits             NVARCHAR(MAX)  NULL,   -- CPTunits
        CPTModifier              NVARCHAR(MAX)  NULL,   -- CPTMOD
        ClaimCPTs                NVARCHAR(MAX)  NULL,   -- Concatenate CPTs
        TotalInsuranceBalance    NVARCHAR(500)  NULL,
        OtherBalance             NVARCHAR(500)  NULL,   -- Charge Balance Due Other
        ChargeToDate             NVARCHAR(500)  NULL,   -- Charge To Date
        ChargeTotalPayments      NVARCHAR(500)  NULL,   -- Charge Total Payments
        ChargeTotalAdjustments   NVARCHAR(500)  NULL,   -- Charge Total Adjustments
        -- WellHealth only
        ClaimBillingProviderID   NVARCHAR(500)  NULL,   -- Claim Billing Provider ID
        ChargePanelID            NVARCHAR(500)  NULL,   -- Charge Panel ID
        BalanceAtCollections     NVARCHAR(500)  NULL,   -- Charge Balance At Collections
        PRIMARY KEY CLUSTERED (RecordId ASC)
    );
    PRINT 'Created dbo.LineLevelData.';
END
GO

-- WellHealth line columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.LineLevelData', 'ClaimBillingProviderID') IS NULL ALTER TABLE dbo.LineLevelData ADD ClaimBillingProviderID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargePanelID') IS NULL          ALTER TABLE dbo.LineLevelData ADD ChargePanelID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'BalanceAtCollections') IS NULL   ALTER TABLE dbo.LineLevelData ADD BalanceAtCollections NVARCHAR(500) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LineLevelData') AND name = 'IX_LineLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_LineLevelData_ClaimID ON dbo.LineLevelData (ClaimID);
GO

/* ── 4. LIMSMaster ────────────────────────────────────────────────────────── */
-- Column names match Schemas/WellHealth_LIMS_Schema.json (SQLColName). The importer loads by
-- destination column, so a column missing here is skipped without an error.
IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LIMSMaster
    (
        -- shared LIMS columns (same as every lab's LIMSMaster)
        OrderID               NVARCHAR(100)  NULL,
        Accession             NVARCHAR(100)  NULL,   -- Accession
        PaymentMethod         NVARCHAR(100)  NULL,
        Barcode               NVARCHAR(100)  NULL,
        Specimen              NVARCHAR(100)  NULL,
        Collector             NVARCHAR(150)  NULL,
        OrderStatus           NVARCHAR(100)  NULL,
        BillingStatus         NVARCHAR(100)  NULL,
        SampleStatus          NVARCHAR(100)  NULL,
        RequestSubmittedDate  DATE           NULL,
        RequestCollectDate    DATE           NULL,   -- Collection Date
        ReqReceivedDate       DATE           NULL,   -- Received
        ReqReportedDate       DATE           NULL,   -- Released Date
        RessultedStatus       NVARCHAR(100)  NULL,
        ClientStatus          NVARCHAR(100)  NULL,
        TimetoResult          NVARCHAR(100)  NULL,   -- Time to result
        TurnaroundTime        NVARCHAR(100)  NULL,
        Facility              NVARCHAR(255)  NULL,
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
        BilledorNot           NVARCHAR(100)  NULL,
        Provider              NVARCHAR(255)  NULL,
        PrimaryInsurance      NVARCHAR(255)  NULL,
        PrimaryInsuranceID    NVARCHAR(150)  NULL,
        ICD10Codes            NVARCHAR(MAX)  NULL,
        Tests                 NVARCHAR(MAX)  NULL,   -- Tests
        PanelCategory         NVARCHAR(255)  NULL,
        -- WellHealth sheet columns
        TrueFalse             NVARCHAR(10)   NULL,   -- T/F
        Requisition           NVARCHAR(100)  NULL,   -- Requisition
        TestCategory          NVARCHAR(255)  NULL,   -- Test Category
        ProcessDate           DATE           NULL,   -- Process Date
        PatientFullName       NVARCHAR(500)  NULL,   -- Patient
        DoctorFullName        NVARCHAR(500)  NULL,   -- Physician
        BillType              NVARCHAR(255)  NULL,   -- Bill Type
        ClinicName            NVARCHAR(500)  NULL,   -- Location
        Samples               NVARCHAR(500)  NULL,   -- Specimens
        PhysicianSignature    NVARCHAR(500)  NULL,   -- Physician Signature
        Status                NVARCHAR(255)  NULL,   -- Status
        ResultStatus          NVARCHAR(255)  NULL,   -- Result Status
        SubStatus             NVARCHAR(255)  NULL,   -- Sub Status (first of the two)
        NewStatus             NVARCHAR(255)  NULL,   -- New Status
        BillCategory          NVARCHAR(255)  NULL,   -- Bill Category
        BilledDate            DATE           NULL,   -- Billed date
        State                 NVARCHAR(100)  NULL,   -- State
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

-- WellHealth LIMS columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.LIMSMaster', 'TrueFalse') IS NULL          ALTER TABLE dbo.LIMSMaster ADD TrueFalse NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Requisition') IS NULL        ALTER TABLE dbo.LIMSMaster ADD Requisition NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'TestCategory') IS NULL       ALTER TABLE dbo.LIMSMaster ADD TestCategory NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ProcessDate') IS NULL        ALTER TABLE dbo.LIMSMaster ADD ProcessDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientFullName') IS NULL    ALTER TABLE dbo.LIMSMaster ADD PatientFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorFullName') IS NULL     ALTER TABLE dbo.LIMSMaster ADD DoctorFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BillType') IS NULL           ALTER TABLE dbo.LIMSMaster ADD BillType NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ClinicName') IS NULL         ALTER TABLE dbo.LIMSMaster ADD ClinicName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Samples') IS NULL            ALTER TABLE dbo.LIMSMaster ADD Samples NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PhysicianSignature') IS NULL ALTER TABLE dbo.LIMSMaster ADD PhysicianSignature NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Status') IS NULL             ALTER TABLE dbo.LIMSMaster ADD Status NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ResultStatus') IS NULL       ALTER TABLE dbo.LIMSMaster ADD ResultStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SubStatus') IS NULL          ALTER TABLE dbo.LIMSMaster ADD SubStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'NewStatus') IS NULL          ALTER TABLE dbo.LIMSMaster ADD NewStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BillCategory') IS NULL       ALTER TABLE dbo.LIMSMaster ADD BillCategory NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BilledDate') IS NULL         ALTER TABLE dbo.LIMSMaster ADD BilledDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'State') IS NULL              ALTER TABLE dbo.LIMSMaster ADD State NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'LabId') IS NULL              ALTER TABLE dbo.LIMSMaster ADD LabId INT NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'LabName') IS NULL            ALTER TABLE dbo.LIMSMaster ADD LabName NVARCHAR(200) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SourceFile') IS NULL         ALTER TABLE dbo.LIMSMaster ADD SourceFile NVARCHAR(260) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RunId') IS NULL              ALTER TABLE dbo.LIMSMaster ADD RunId VARCHAR(30) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'AdditionalFields') IS NULL   ALTER TABLE dbo.LIMSMaster ADD AdditionalFields NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'IX_LIMSMaster_Accession')
    CREATE NONCLUSTERED INDEX IX_LIMSMaster_Accession ON dbo.LIMSMaster (Accession);
GO

PRINT 'WellHealth lab tables are up to date.';
GO

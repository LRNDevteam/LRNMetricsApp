/*
    PNC - lab database tables for LRN.MasterFileProcessorWorker.
    Run against the PNC lab database (PNC), not LRNMaster.

    What the worker writes here:
      dbo.LineClaimFileLogs  one row per load (LineClaimFileLogRepository)
      dbo.ClaimLevelData     "Claim Level" sheet - TRUNCATE + SqlBulkCopy per run
      dbo.LineLevelData      "Line Level" sheet  - TRUNCATE + SqlBulkCopy per run
      dbo.LIMSMaster         PNC LIMS Master File - TRUNCATE + SqlBulkCopy per run

    Built from the TexasDiagnostic tables, then aligned to:
      Schemas/LabMappings/PNCFieldMappings.json   (ClaimLevelData / LineLevelData SqlColumn)
      Schemas/PNC_LIMS_Schema.json                (LIMSMaster SQLColName)
    Mapping source: AveragesTable_AllAccounts_Field Mapping_V1.21.xlsx, column 'PNC'.
    SqlBulkCopy fails the load outright if a mapped column is missing or a value does not fit, and
    the LIMS importer silently skips a missing column, so keep them in step.

    Added for PNC (both claim and line tables):
      Source, Status, FormType, PatientGender, GroupNumber, SubscriberRelationship, SecondaryPayer,
      SecondaryPolicyId, SecondaryGroupNumber, PayerId, RenderingProvider, ReferringProviderNPI,
      BillingProviderNPI, RenderingProviderNPI, UpdatedDenialCode, PredictedDecisionDate,
      PredictedPaymentDate, PredictedDaysToPayment, DaysPastExpectedPayment, PayerStatus,
      OperationalStatus, WorkSubStatus, RejectionSource, RemarkCodes, WriteOffReason, BillingNote,
      AdditionalClaimInfo
      LIMSMaster       AccessionedDate, IsDirectBillOrder, PrimaryGroupId, InsuranceType, FacilityID,
                       RequisitionType, ReflexedPanels, BilledSystem
    Where PNC's sheet columns land in existing columns:
      'Policy ID' -> SubscriberId, 'Service Facility' -> Facility, 'Balance Due' -> OtherBalance,
      'Aging' -> AgingDOS, 'DOE Week' -> EntryWeek, 'Deposit Week' -> DepositWeek,
      'Expected Amount' -> ExpectedPayment, line 'Line Level CPT' -> CPTUnits,
      claim 'CPT / Procedure' / 'Units' / 'Modifiers' -> CPTCodeList / UnitsList / ModifierList.
    Denials: DenialCode is the sheets' "Denial Code"; "Updated Denial Code" lands in UpdatedDenialCode.
    ICD: ICDCode is "Diagnosis Codes" on both sheets.
    Columns not loaded from the file (DenialCodeNormalized, DenialDescription, Aging buckets, ...)
    are kept: other processes write them after the load.

    Re-runnable: tables are created only when missing, and every PNC column is added only when
    missing, so it is also safe on a database cloned from another lab.
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
        AccessionNumber               NVARCHAR(1000) NULL,   -- Accession Number
        SourceFileID                  NVARCHAR(1000) NULL,
        IngestedOn                    NVARCHAR(500)  NULL,
        CsvRowHash                    NVARCHAR(500)  NULL,
        PayerName_Raw                 NVARCHAR(500)  NULL,   -- Payer Name
        PayerName                     NVARCHAR(500)  NULL,
        Payer_Code                    NVARCHAR(500)  NULL,
        Payer_Common_Code             NVARCHAR(500)  NULL,
        Payer_Group_Code              NVARCHAR(500)  NULL,
        Global_Payer_ID               NVARCHAR(500)  NULL,
        PayerType                     NVARCHAR(500)  NULL,   -- Insurance Type
        BillingProvider               NVARCHAR(500)  NULL,   -- Billing Provider
        ReferringProvider             NVARCHAR(500)  NULL,   -- Referring Provider
        ClinicName                    NVARCHAR(500)  NULL,   -- Sales Rep Facility
        SalesRepname                  NVARCHAR(500)  NULL,   -- Sales Rep
        PatientID                     NVARCHAR(500)  NULL,   -- Patient Control #
        PatientDOB                    NVARCHAR(500)  NULL,   -- Patient DOB
        DateofService                 NVARCHAR(500)  NULL,   -- Date of Service
        ChargeEnteredDate             NVARCHAR(500)  NULL,   -- Created Date
        FirstBilledDate               NVARCHAR(500)  NULL,   -- Billed Date
        Panelname                     NVARCHAR(500)  NULL,   -- Service Type
        CPTCodeXUnitsXModifier        NVARCHAR(MAX)  NULL,   -- rebuilt from the line level
        POS                           NVARCHAR(500)  NULL,
        TOS                           NVARCHAR(500)  NULL,
        ChargeAmount                  NVARCHAR(500)  NULL,   -- Total Charges
        AllowedAmount                 NVARCHAR(500)  NULL,   -- Allowed Amount
        InsurancePayment              NVARCHAR(500)  NULL,   -- Insurance Paid
        PatientPayment                NVARCHAR(500)  NULL,   -- Patient Paid
        TotalPayments                 NVARCHAR(500)  NULL,
        InsuranceAdjustments          NVARCHAR(500)  NULL,   -- Write Off
        PatientAdjustments            NVARCHAR(500)  NULL,
        TotalAdjustments              NVARCHAR(500)  NULL,
        InsuranceBalance              NVARCHAR(500)  NULL,   -- Carrier Balance
        PatientBalance                NVARCHAR(500)  NULL,   -- Patient Responsibility
        TotalBalance                  NVARCHAR(500)  NULL,
        CheckDate                     NVARCHAR(500)  NULL,   -- Deposit Date
        ClaimStatus                   NVARCHAR(500)  NULL,   -- Claim Status
        DenialCode                    NVARCHAR(MAX)  NULL,   -- Denial Code
        ICDCode                       NVARCHAR(MAX)  NULL,   -- Diagnosis Codes
        DaystoDOS                     NVARCHAR(500)  NULL,
        RollingDays                   NVARCHAR(500)  NULL,
        DaystoBill                    NVARCHAR(500)  NULL,
        DaystoPost                    NVARCHAR(500)  NULL,
        ICDPointer                    NVARCHAR(500)  NULL,
        InsertedDateTime              DATETIME       NOT NULL DEFAULT GETDATE(),
        -- lab columns
        PatientName                   NVARCHAR(1000) NULL,   -- Patient Name
        PaymentPercent                NVARCHAR(100)  NULL,   -- Payment %
        Aging                         NVARCHAR(100)  NULL,
        BilledWeek                    NVARCHAR(500)  NULL,   -- Billed Week
        PostedWeek                    NVARCHAR(500)  NULL,   -- Posted Week
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
        AgingDOE                      NVARCHAR(500)  NULL,
        AgingDOS                      NVARCHAR(500)  NULL,   -- Aging
        PanelNameLIS                  NVARCHAR(MAX)  NULL,
        PanelNameBasedOnCPT           NVARCHAR(500)  NULL,
        InsuranceBalance_Decimal      AS (TRY_CAST(InsuranceBalance AS DECIMAL(18,2))) PERSISTED,
        AdditionalFields              NVARCHAR(MAX)  NULL,   -- unmapped CSV columns as JSON
        Facility                      NVARCHAR(500)  NULL,   -- Service Facility
        Modifier                      NVARCHAR(500)  NULL,
        DenialCodeNormalized          NVARCHAR(400)  NULL,
        DenialDescription             NVARCHAR(MAX)  NULL,
        SubscriberId                  NVARCHAR(1000) NULL,   -- Policy ID
        BilledStatus                  NVARCHAR(MAX)  NULL,   -- Bill Status
        Adjudicated                   NVARCHAR(500)  NULL,   -- Adjucticated #
        Bucket30                      NVARCHAR(500)  NULL,   -- 30 Bucket #
        Bucket30Amount                NVARCHAR(500)  NULL,   -- 30 Bucket $
        Bucket60                      NVARCHAR(500)  NULL,   -- 60 Bucket #
        Bucket60Amount                NVARCHAR(500)  NULL,   -- 60 Bucket $
        LastBilledDate                NVARCHAR(500)  NULL,
        DenialDate                    NVARCHAR(500)  NULL,
        TotalInsuranceBalance         NVARCHAR(500)  NULL,
        OtherBalance                  NVARCHAR(500)  NULL,   -- Balance Due
        CPTCodeList                   NVARCHAR(MAX)  NULL,   -- CPT / Procedure
        UnitsList                     NVARCHAR(500)  NULL,   -- Units
        ModifierList                  NVARCHAR(500)  NULL,   -- Modifiers
        CptWithUnits                  NVARCHAR(MAX)  NULL,
        ChargeToDate                  NVARCHAR(500)  NULL,
        ChargeTotalPayments           NVARCHAR(500)  NULL,
        ChargeTotalAdjustments        NVARCHAR(500)  NULL,
        PostingDate                   NVARCHAR(500)  NULL,   -- Posted Date
        PaymentPostedDate             NVARCHAR(500)  NULL,   -- Posted Date
        UID                           NVARCHAR(500)  NULL,
        TF                            NVARCHAR(10)   NULL,
        EncCptTc                      NVARCHAR(500)  NULL,
        EndDOS                        NVARCHAR(500)  NULL,
        EntryWeek                     NVARCHAR(100)  NULL,   -- DOE Week
        LineLevelCPT                  NVARCHAR(MAX)  NULL,
        DepositWeek                   NVARCHAR(100)  NULL,   -- Deposit Week
        CheckNumber                   NVARCHAR(500)  NULL,
        DeniedWeek                    NVARCHAR(100)  NULL,
        OriginalDenialCode            NVARCHAR(MAX)  NULL,
        LineLevelDenialCode           NVARCHAR(MAX)  NULL,
        ClaimLevelDenialCode          NVARCHAR(MAX)  NULL,
        LineLevelICD                  NVARCHAR(MAX)  NULL,
        ExpectedPayment               NVARCHAR(500)  NULL,   -- Expected Amount
        TimeToPay                     NVARCHAR(100)  NULL,   -- Time to Pay
        -- PNC only
        Source                        NVARCHAR(500)  NULL,   -- Source
        Status                        NVARCHAR(500)  NULL,   -- Status
        FormType                      NVARCHAR(100)  NULL,   -- Form Type
        PatientGender                 NVARCHAR(50)   NULL,   -- Patient Gender
        GroupNumber                   NVARCHAR(500)  NULL,   -- Group Number
        SubscriberRelationship        NVARCHAR(100)  NULL,   -- Subscriber Relationship
        SecondaryPayer                NVARCHAR(500)  NULL,   -- Secondary Payer
        SecondaryPolicyId             NVARCHAR(500)  NULL,   -- Secondary Policy ID
        SecondaryGroupNumber          NVARCHAR(500)  NULL,   -- Secondary Group Number
        PayerId                       NVARCHAR(500)  NULL,   -- Payer ID
        RenderingProvider             NVARCHAR(500)  NULL,   -- Rendering Provider
        ReferringProviderNPI          NVARCHAR(50)   NULL,   -- Referring Provider NPI
        BillingProviderNPI            NVARCHAR(50)   NULL,   -- Billing Provider NPI
        RenderingProviderNPI          NVARCHAR(50)   NULL,   -- Rendering Provider NPI
        UpdatedDenialCode             NVARCHAR(MAX)  NULL,   -- Updated Denial Code
        PredictedDecisionDate         NVARCHAR(500)  NULL,   -- Predicted Decision Date
        PredictedPaymentDate          NVARCHAR(500)  NULL,   -- Predicted Payment Date
        PredictedDaysToPayment        NVARCHAR(100)  NULL,   -- Predicted Days to Payment
        DaysPastExpectedPayment       NVARCHAR(100)  NULL,   -- Days Past Expected Payment
        PayerStatus                   NVARCHAR(500)  NULL,   -- Payer Status
        OperationalStatus             NVARCHAR(500)  NULL,   -- Operational Status
        WorkSubStatus                 NVARCHAR(500)  NULL,   -- Work Sub-Status
        RejectionSource               NVARCHAR(500)  NULL,   -- Rejection Source
        RemarkCodes                   NVARCHAR(MAX)  NULL,   -- Remark Codes
        WriteOffReason                NVARCHAR(500)  NULL,   -- Write-Off Reason
        BillingNote                   NVARCHAR(MAX)  NULL,   -- Billing Note
        AdditionalClaimInfo           NVARCHAR(MAX)  NULL,   -- Additional Claim Info (Box 19)
        PRIMARY KEY CLUSTERED (RecordId ASC)
    );
    PRINT 'Created dbo.ClaimLevelData.';
END
GO

-- PNC claim columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.ClaimLevelData', 'AgingDOS') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD AgingDOS NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Facility') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD Facility NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SubscriberId') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD SubscriberId NVARCHAR(1000) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OtherBalance') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD OtherBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CPTCodeList') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD CPTCodeList NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'UnitsList') IS NULL               ALTER TABLE dbo.ClaimLevelData ADD UnitsList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ModifierList') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD ModifierList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PostingDate') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD PostingDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PaymentPostedDate') IS NULL       ALTER TABLE dbo.ClaimLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'EntryWeek') IS NULL               ALTER TABLE dbo.ClaimLevelData ADD EntryWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DepositWeek') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD DepositWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ExpectedPayment') IS NULL         ALTER TABLE dbo.ClaimLevelData ADD ExpectedPayment NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'TimeToPay') IS NULL               ALTER TABLE dbo.ClaimLevelData ADD TimeToPay NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Source') IS NULL                  ALTER TABLE dbo.ClaimLevelData ADD Source NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'Status') IS NULL                  ALTER TABLE dbo.ClaimLevelData ADD Status NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'FormType') IS NULL                ALTER TABLE dbo.ClaimLevelData ADD FormType NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PatientGender') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD PatientGender NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'GroupNumber') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD GroupNumber NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SubscriberRelationship') IS NULL  ALTER TABLE dbo.ClaimLevelData ADD SubscriberRelationship NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SecondaryPayer') IS NULL          ALTER TABLE dbo.ClaimLevelData ADD SecondaryPayer NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SecondaryPolicyId') IS NULL       ALTER TABLE dbo.ClaimLevelData ADD SecondaryPolicyId NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'SecondaryGroupNumber') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD SecondaryGroupNumber NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PayerId') IS NULL                 ALTER TABLE dbo.ClaimLevelData ADD PayerId NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'RenderingProvider') IS NULL       ALTER TABLE dbo.ClaimLevelData ADD RenderingProvider NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ReferringProviderNPI') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD ReferringProviderNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BillingProviderNPI') IS NULL      ALTER TABLE dbo.ClaimLevelData ADD BillingProviderNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'RenderingProviderNPI') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD RenderingProviderNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'UpdatedDenialCode') IS NULL       ALTER TABLE dbo.ClaimLevelData ADD UpdatedDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PredictedDecisionDate') IS NULL   ALTER TABLE dbo.ClaimLevelData ADD PredictedDecisionDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PredictedPaymentDate') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD PredictedPaymentDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PredictedDaysToPayment') IS NULL  ALTER TABLE dbo.ClaimLevelData ADD PredictedDaysToPayment NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'DaysPastExpectedPayment') IS NULL ALTER TABLE dbo.ClaimLevelData ADD DaysPastExpectedPayment NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PayerStatus') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD PayerStatus NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OperationalStatus') IS NULL       ALTER TABLE dbo.ClaimLevelData ADD OperationalStatus NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'WorkSubStatus') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD WorkSubStatus NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'RejectionSource') IS NULL         ALTER TABLE dbo.ClaimLevelData ADD RejectionSource NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'RemarkCodes') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD RemarkCodes NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'WriteOffReason') IS NULL          ALTER TABLE dbo.ClaimLevelData ADD WriteOffReason NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'BillingNote') IS NULL             ALTER TABLE dbo.ClaimLevelData ADD BillingNote NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'AdditionalClaimInfo') IS NULL     ALTER TABLE dbo.ClaimLevelData ADD AdditionalClaimInfo NVARCHAR(MAX) NULL;
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
        AccessionNumber          NVARCHAR(1000) NULL,   -- Accession Number
        SourceFileID             NVARCHAR(1000) NULL,
        IngestedOn               NVARCHAR(500)  NULL,
        CsvRowHash               NVARCHAR(500)  NULL,
        PayerName_Raw            NVARCHAR(500)  NULL,   -- Payer Name
        PayerName                NVARCHAR(500)  NULL,
        Payer_Code               NVARCHAR(500)  NULL,
        Payer_Common_Code        NVARCHAR(500)  NULL,
        Payer_Group_Code         NVARCHAR(500)  NULL,
        Global_Payer_ID          NVARCHAR(500)  NULL,
        PayerType                NVARCHAR(500)  NULL,   -- Insurance Type
        BillingProvider          NVARCHAR(500)  NULL,   -- Billing Provider
        ReferringProvider        NVARCHAR(500)  NULL,   -- Referring Provider
        ClinicName               NVARCHAR(500)  NULL,   -- Sales Rep Facility
        SalesRepname             NVARCHAR(500)  NULL,   -- Sales Rep
        PatientID                NVARCHAR(500)  NULL,   -- Patient Control #
        PatientDOB               NVARCHAR(500)  NULL,   -- Patient DOB
        DateofService            NVARCHAR(500)  NULL,   -- Date of Service
        ChargeEnteredDate        NVARCHAR(500)  NULL,   -- Created Date
        FirstBilledDate          NVARCHAR(500)  NULL,   -- Billed Date
        Panelname                NVARCHAR(500)  NULL,   -- Service Type
        CPTCode                  NVARCHAR(500)  NULL,   -- CPT / Procedure
        Units                    NVARCHAR(500)  NULL,   -- Units
        Modifier                 NVARCHAR(500)  NULL,   -- Modifiers
        POS                      NVARCHAR(500)  NULL,
        TOS                      NVARCHAR(500)  NULL,
        ChargeAmount             NVARCHAR(500)  NULL,   -- Total Charges
        ChargeAmountPerUnit      NVARCHAR(500)  NULL,
        AllowedAmount            NVARCHAR(500)  NULL,   -- Allowed Amount
        AllowedAmountPerUnit     NVARCHAR(500)  NULL,
        InsurancePayment         NVARCHAR(500)  NULL,   -- Insurance Paid
        InsurancePaymentPerUnit  NVARCHAR(500)  NULL,
        PatientPayment           NVARCHAR(500)  NULL,   -- Patient Paid
        PatientPaymentPerUnit    NVARCHAR(500)  NULL,
        TotalPayments            NVARCHAR(500)  NULL,
        InsuranceAdjustments     NVARCHAR(500)  NULL,   -- Write Off
        PatientAdjustments       NVARCHAR(500)  NULL,
        TotalAdjustments         NVARCHAR(500)  NULL,
        InsuranceBalance         NVARCHAR(500)  NULL,   -- Carrier Balance
        PatientBalance           NVARCHAR(500)  NULL,   -- Patient Responsibility
        PatientBalancePerUnit    NVARCHAR(500)  NULL,
        TotalBalance             NVARCHAR(500)  NULL,
        CheckDate                NVARCHAR(500)  NULL,   -- Deposit Date
        PostingDate              NVARCHAR(500)  NULL,   -- Posted Date
        ClaimStatus              NVARCHAR(500)  NULL,   -- copied from the claim sheet
        PayStatus                NVARCHAR(500)  NULL,
        DenialCode               NVARCHAR(MAX)  NULL,   -- Denial Code
        DenialDate               NVARCHAR(500)  NULL,
        ICDCode                  NVARCHAR(MAX)  NULL,   -- Diagnosis Codes
        DaystoDOS                NVARCHAR(500)  NULL,
        RollingDays              NVARCHAR(500)  NULL,
        DaystoBill               NVARCHAR(500)  NULL,
        DaystoPost               NVARCHAR(500)  NULL,
        ICDPointer               NVARCHAR(500)  NULL,
        InsertedDateTime         DATETIME       NOT NULL DEFAULT GETDATE(),
        -- lab columns
        PatientName              NVARCHAR(1000) NULL,   -- Patient Name
        SubscriberId             NVARCHAR(500)  NULL,   -- Policy ID
        PaymentPostedDate        NVARCHAR(500)  NULL,   -- Posted Date
        ResponsibleParty         NVARCHAR(500)  NULL,
        EndDOS                   NVARCHAR(500)  NULL,
        BillOccurance            NVARCHAR(500)  NULL,
        EntryUser                NVARCHAR(500)  NULL,
        CPTUnits                 NVARCHAR(500)  NULL,   -- Line Level CPT
        CPTMOD                   NVARCHAR(500)  NULL,
        PostedWeek               NVARCHAR(500)  NULL,   -- Posted Week
        LineLevelUID             NVARCHAR(1000) NULL,
        Source                   NVARCHAR(500)  NULL,   -- Source
        InsuranceBalance_Decimal AS (TRY_CAST(InsuranceBalance AS DECIMAL(18,2))) PERSISTED,
        AdditionalFields         NVARCHAR(MAX)  NULL,   -- unmapped CSV columns as JSON
        Facility                 NVARCHAR(500)  NULL,   -- Service Facility
        CPTs                     NVARCHAR(500)  NULL,
        DenialCodeNormalized     NVARCHAR(400)  NULL,
        DenialDescription        NVARCHAR(MAX)  NULL,
        UID                      NVARCHAR(500)  NULL,
        LastBilledDate           NVARCHAR(500)  NULL,
        CptWithUnits             NVARCHAR(MAX)  NULL,
        CPTModifier              NVARCHAR(MAX)  NULL,
        ClaimCPTs                NVARCHAR(MAX)  NULL,   -- Claim Level CPT
        TotalInsuranceBalance    NVARCHAR(500)  NULL,
        OtherBalance             NVARCHAR(500)  NULL,   -- Balance Due
        ChargeToDate             NVARCHAR(500)  NULL,
        ChargeTotalPayments      NVARCHAR(500)  NULL,
        ChargeTotalAdjustments   NVARCHAR(500)  NULL,
        TF                       NVARCHAR(10)   NULL,   -- T/F
        EncCptTc                 NVARCHAR(500)  NULL,
        AgingDOS                 NVARCHAR(500)  NULL,   -- Aging
        AgingDOE                 NVARCHAR(500)  NULL,
        EntryWeek                NVARCHAR(100)  NULL,   -- DOE Week
        BilledWeek               NVARCHAR(100)  NULL,   -- Billed Week
        LineLevelCPT             NVARCHAR(MAX)  NULL,
        DepositWeek              NVARCHAR(100)  NULL,   -- Deposit Week
        CheckNumber              NVARCHAR(500)  NULL,
        DeniedWeek               NVARCHAR(100)  NULL,
        OriginalDenialCode       NVARCHAR(MAX)  NULL,
        ClaimLevelDenialCode     NVARCHAR(MAX)  NULL,
        ClaimLevelICD            NVARCHAR(MAX)  NULL,
        MedicareFeeSchedule      NVARCHAR(500)  NULL,
        ExpectedPayment          NVARCHAR(500)  NULL,   -- Expected Amount
        PaymentPercent           NVARCHAR(100)  NULL,   -- Payment %
        -- PNC only
        Status                   NVARCHAR(500)  NULL,   -- Status
        FormType                 NVARCHAR(100)  NULL,   -- Form Type
        PatientGender            NVARCHAR(50)   NULL,   -- Patient Gender
        GroupNumber              NVARCHAR(500)  NULL,   -- Group Number
        SubscriberRelationship   NVARCHAR(100)  NULL,   -- Subscriber Relationship
        SecondaryPayer           NVARCHAR(500)  NULL,   -- Secondary Payer
        SecondaryPolicyId        NVARCHAR(500)  NULL,   -- Secondary Policy ID
        SecondaryGroupNumber     NVARCHAR(500)  NULL,   -- Secondary Group Number
        PayerId                  NVARCHAR(500)  NULL,   -- Payer ID
        RenderingProvider        NVARCHAR(500)  NULL,   -- Rendering Provider
        ReferringProviderNPI     NVARCHAR(50)   NULL,   -- Referring Provider NPI
        BillingProviderNPI       NVARCHAR(50)   NULL,   -- Billing Provider NPI
        RenderingProviderNPI     NVARCHAR(50)   NULL,   -- Rendering Provider NPI
        UpdatedDenialCode        NVARCHAR(MAX)  NULL,   -- Updated Denial Code
        PredictedDecisionDate    NVARCHAR(500)  NULL,   -- Predicted Decision Date
        PredictedPaymentDate     NVARCHAR(500)  NULL,   -- Predicted Payment Date
        PredictedDaysToPayment   NVARCHAR(100)  NULL,   -- Predicted Days to Payment
        DaysPastExpectedPayment  NVARCHAR(100)  NULL,   -- Days Past Expected Payment
        PayerStatus              NVARCHAR(500)  NULL,   -- Payer Status
        OperationalStatus        NVARCHAR(500)  NULL,   -- Operational Status
        WorkSubStatus            NVARCHAR(500)  NULL,   -- Work Sub-Status
        RejectionSource          NVARCHAR(500)  NULL,   -- Rejection Source
        RemarkCodes              NVARCHAR(MAX)  NULL,   -- Remark Codes
        WriteOffReason           NVARCHAR(500)  NULL,   -- Write-Off Reason
        BillingNote              NVARCHAR(MAX)  NULL,   -- Billing Note
        AdditionalClaimInfo      NVARCHAR(MAX)  NULL,   -- Additional Claim Info (Box 19)
        PRIMARY KEY CLUSTERED (RecordId ASC)
    );
    PRINT 'Created dbo.LineLevelData.';
END
GO

-- PNC line columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.LineLevelData', 'Source') IS NULL                  ALTER TABLE dbo.LineLevelData ADD Source NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ClaimCPTs') IS NULL               ALTER TABLE dbo.LineLevelData ADD ClaimCPTs NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TF') IS NULL                      ALTER TABLE dbo.LineLevelData ADD TF NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Facility') IS NULL                ALTER TABLE dbo.LineLevelData ADD Facility NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SubscriberId') IS NULL            ALTER TABLE dbo.LineLevelData ADD SubscriberId NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OtherBalance') IS NULL            ALTER TABLE dbo.LineLevelData ADD OtherBalance NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'CPTUnits') IS NULL                ALTER TABLE dbo.LineLevelData ADD CPTUnits NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PostedWeek') IS NULL              ALTER TABLE dbo.LineLevelData ADD PostedWeek NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AgingDOS') IS NULL                ALTER TABLE dbo.LineLevelData ADD AgingDOS NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'EntryWeek') IS NULL               ALTER TABLE dbo.LineLevelData ADD EntryWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'BilledWeek') IS NULL              ALTER TABLE dbo.LineLevelData ADD BilledWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DepositWeek') IS NULL             ALTER TABLE dbo.LineLevelData ADD DepositWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ExpectedPayment') IS NULL         ALTER TABLE dbo.LineLevelData ADD ExpectedPayment NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PaymentPercent') IS NULL          ALTER TABLE dbo.LineLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'Status') IS NULL                  ALTER TABLE dbo.LineLevelData ADD Status NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'FormType') IS NULL                ALTER TABLE dbo.LineLevelData ADD FormType NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PatientGender') IS NULL           ALTER TABLE dbo.LineLevelData ADD PatientGender NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'GroupNumber') IS NULL             ALTER TABLE dbo.LineLevelData ADD GroupNumber NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SubscriberRelationship') IS NULL  ALTER TABLE dbo.LineLevelData ADD SubscriberRelationship NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SecondaryPayer') IS NULL          ALTER TABLE dbo.LineLevelData ADD SecondaryPayer NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SecondaryPolicyId') IS NULL       ALTER TABLE dbo.LineLevelData ADD SecondaryPolicyId NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'SecondaryGroupNumber') IS NULL    ALTER TABLE dbo.LineLevelData ADD SecondaryGroupNumber NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PayerId') IS NULL                 ALTER TABLE dbo.LineLevelData ADD PayerId NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'RenderingProvider') IS NULL       ALTER TABLE dbo.LineLevelData ADD RenderingProvider NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ReferringProviderNPI') IS NULL    ALTER TABLE dbo.LineLevelData ADD ReferringProviderNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'BillingProviderNPI') IS NULL      ALTER TABLE dbo.LineLevelData ADD BillingProviderNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'RenderingProviderNPI') IS NULL    ALTER TABLE dbo.LineLevelData ADD RenderingProviderNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'UpdatedDenialCode') IS NULL       ALTER TABLE dbo.LineLevelData ADD UpdatedDenialCode NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PredictedDecisionDate') IS NULL   ALTER TABLE dbo.LineLevelData ADD PredictedDecisionDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PredictedPaymentDate') IS NULL    ALTER TABLE dbo.LineLevelData ADD PredictedPaymentDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PredictedDaysToPayment') IS NULL  ALTER TABLE dbo.LineLevelData ADD PredictedDaysToPayment NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'DaysPastExpectedPayment') IS NULL ALTER TABLE dbo.LineLevelData ADD DaysPastExpectedPayment NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'PayerStatus') IS NULL             ALTER TABLE dbo.LineLevelData ADD PayerStatus NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OperationalStatus') IS NULL       ALTER TABLE dbo.LineLevelData ADD OperationalStatus NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'WorkSubStatus') IS NULL           ALTER TABLE dbo.LineLevelData ADD WorkSubStatus NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'RejectionSource') IS NULL         ALTER TABLE dbo.LineLevelData ADD RejectionSource NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'RemarkCodes') IS NULL             ALTER TABLE dbo.LineLevelData ADD RemarkCodes NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'WriteOffReason') IS NULL          ALTER TABLE dbo.LineLevelData ADD WriteOffReason NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'BillingNote') IS NULL             ALTER TABLE dbo.LineLevelData ADD BillingNote NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'AdditionalClaimInfo') IS NULL     ALTER TABLE dbo.LineLevelData ADD AdditionalClaimInfo NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LineLevelData') AND name = 'IX_LineLevelData_ClaimID')
    CREATE NONCLUSTERED INDEX IX_LineLevelData_ClaimID ON dbo.LineLevelData (ClaimID);
GO

/* ── 4. LIMSMaster ────────────────────────────────────────────────────────── */
-- Column names match Schemas/PNC_LIMS_Schema.json (SQLColName). The importer loads by
-- destination column, so a column missing here is skipped without an error.
IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LIMSMaster
    (
        -- shared LIMS columns (same as every lab's LIMSMaster)
        OrderID               NVARCHAR(100)  NULL,   -- RecordId
        Accession             NVARCHAR(500)  NULL,   -- AccessionNo
        PaymentMethod         NVARCHAR(100)  NULL,
        Barcode               NVARCHAR(100)  NULL,
        Specimen              NVARCHAR(100)  NULL,
        Collector             NVARCHAR(150)  NULL,
        OrderStatus           NVARCHAR(100)  NULL,   -- Status
        BillingStatus         NVARCHAR(100)  NULL,
        SampleStatus          NVARCHAR(100)  NULL,
        RequestSubmittedDate  DATE           NULL,
        RequestCollectDate    DATE           NULL,   -- DateOfCollection
        ReqReceivedDate       DATE           NULL,   -- Received_Date
        ReqReportedDate       DATE           NULL,
        RessultedStatus       NVARCHAR(100)  NULL,
        ClientStatus          NVARCHAR(100)  NULL,
        TimetoResult          NVARCHAR(100)  NULL,   -- Time to Result
        TurnaroundTime        NVARCHAR(100)  NULL,
        Facility              NVARCHAR(255)  NULL,
        [Performing Laboratory] NVARCHAR(255) NULL,
        Results               NVARCHAR(MAX)  NULL,
        PatientFirstName      NVARCHAR(150)  NULL,   -- FirstName
        PatientLastName       NVARCHAR(150)  NULL,   -- LastName
        PatientDateOfBirth    DATE           NULL,   -- DOB
        VisitNumber           NVARCHAR(100)  NULL,
        AMDDOE                NVARCHAR(100)  NULL,
        AMDLBD                NVARCHAR(100)  NULL,
        TimetoBill            NVARCHAR(100)  NULL,   -- Time to Bill
        ClaimStatus           NVARCHAR(100)  NULL,
        BilledorNot           NVARCHAR(100)  NULL,
        Provider              NVARCHAR(255)  NULL,
        PrimaryInsurance      NVARCHAR(255)  NULL,   -- Primary_Insurance_Provider
        PrimaryInsuranceID    NVARCHAR(150)  NULL,   -- Primary_PolicyId
        ICD10Codes            NVARCHAR(MAX)  NULL,   -- ICDCodes
        Tests                 NVARCHAR(MAX)  NULL,   -- Ordered Panels
        PanelCategory         NVARCHAR(255)  NULL,
        -- columns shared with Texas Diagnostic
        TrueFalse             NVARCHAR(10)   NULL,   -- T/F
        Requisition           NVARCHAR(100)  NULL,
        PatientFullName       NVARCHAR(500)  NULL,   -- Patient Name
        Gender                NVARCHAR(50)   NULL,   -- Gender
        State                 NVARCHAR(100)  NULL,   -- State
        PatientCode           NVARCHAR(100)  NULL,   -- PatientId
        DoctorFullName        NVARCHAR(500)  NULL,   -- PhysicianName
        DoctorNPI             NVARCHAR(50)   NULL,   -- NPI
        SalesRepName          NVARCHAR(500)  NULL,   -- SaleRepName
        CRN                   NVARCHAR(255)  NULL,
        TestCategory          NVARCHAR(255)  NULL,
        PanelName             NVARCHAR(500)  NULL,   -- Panel type
        CollectionWeek        NVARCHAR(100)  NULL,   -- Collection Week
        ResultedDate          DATE           NULL,   -- Validated_Date
        ResultStatus          NVARCHAR(255)  NULL,
        ClinicName            NVARCHAR(500)  NULL,   -- FacilityName
        NewStatus             NVARCHAR(255)  NULL,   -- New Status
        BillCategory          NVARCHAR(255)  NULL,   -- Bill Category
        SubStatus             NVARCHAR(255)  NULL,   -- Sub Status
        BilledDate            DATE           NULL,   -- Billed Date
        -- PNC sheet columns
        AccessionedDate       DATE           NULL,   -- Accessioned_Date
        IsDirectBillOrder     NVARCHAR(50)   NULL,   -- Is Direct Bill Order
        PrimaryGroupId        NVARCHAR(150)  NULL,   -- Primary_GroupId
        InsuranceType         NVARCHAR(255)  NULL,   -- Insurance_Type
        FacilityID            NVARCHAR(100)  NULL,   -- FacilityID
        RequisitionType       NVARCHAR(255)  NULL,   -- Requistion_Type
        ReflexedPanels        NVARCHAR(MAX)  NULL,   -- Reflexed Panels
        BilledSystem          NVARCHAR(255)  NULL,   -- Billed System
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

-- PNC LIMS columns, for a database cloned from another lab.
IF COL_LENGTH('dbo.LIMSMaster', 'TrueFalse') IS NULL         ALTER TABLE dbo.LIMSMaster ADD TrueFalse NVARCHAR(10) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientFullName') IS NULL   ALTER TABLE dbo.LIMSMaster ADD PatientFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Gender') IS NULL            ALTER TABLE dbo.LIMSMaster ADD Gender NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'State') IS NULL             ALTER TABLE dbo.LIMSMaster ADD State NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientCode') IS NULL       ALTER TABLE dbo.LIMSMaster ADD PatientCode NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorFullName') IS NULL    ALTER TABLE dbo.LIMSMaster ADD DoctorFullName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DoctorNPI') IS NULL         ALTER TABLE dbo.LIMSMaster ADD DoctorNPI NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SalesRepName') IS NULL      ALTER TABLE dbo.LIMSMaster ADD SalesRepName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PanelName') IS NULL         ALTER TABLE dbo.LIMSMaster ADD PanelName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'CollectionWeek') IS NULL    ALTER TABLE dbo.LIMSMaster ADD CollectionWeek NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ResultedDate') IS NULL      ALTER TABLE dbo.LIMSMaster ADD ResultedDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ClinicName') IS NULL        ALTER TABLE dbo.LIMSMaster ADD ClinicName NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'NewStatus') IS NULL         ALTER TABLE dbo.LIMSMaster ADD NewStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BillCategory') IS NULL      ALTER TABLE dbo.LIMSMaster ADD BillCategory NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SubStatus') IS NULL         ALTER TABLE dbo.LIMSMaster ADD SubStatus NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BilledDate') IS NULL        ALTER TABLE dbo.LIMSMaster ADD BilledDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'AccessionedDate') IS NULL   ALTER TABLE dbo.LIMSMaster ADD AccessionedDate DATE NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'IsDirectBillOrder') IS NULL ALTER TABLE dbo.LIMSMaster ADD IsDirectBillOrder NVARCHAR(50) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PrimaryGroupId') IS NULL    ALTER TABLE dbo.LIMSMaster ADD PrimaryGroupId NVARCHAR(150) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'InsuranceType') IS NULL     ALTER TABLE dbo.LIMSMaster ADD InsuranceType NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'FacilityID') IS NULL        ALTER TABLE dbo.LIMSMaster ADD FacilityID NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RequisitionType') IS NULL   ALTER TABLE dbo.LIMSMaster ADD RequisitionType NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ReflexedPanels') IS NULL    ALTER TABLE dbo.LIMSMaster ADD ReflexedPanels NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BilledSystem') IS NULL      ALTER TABLE dbo.LIMSMaster ADD BilledSystem NVARCHAR(255) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'LabId') IS NULL             ALTER TABLE dbo.LIMSMaster ADD LabId INT NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'LabName') IS NULL           ALTER TABLE dbo.LIMSMaster ADD LabName NVARCHAR(200) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SourceFile') IS NULL        ALTER TABLE dbo.LIMSMaster ADD SourceFile NVARCHAR(260) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RunId') IS NULL             ALTER TABLE dbo.LIMSMaster ADD RunId VARCHAR(30) NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'AdditionalFields') IS NULL  ALTER TABLE dbo.LIMSMaster ADD AdditionalFields NVARCHAR(MAX) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.LIMSMaster') AND name = 'IX_LIMSMaster_Accession')
    CREATE NONCLUSTERED INDEX IX_LIMSMaster_Accession ON dbo.LIMSMaster (Accession);
GO

PRINT 'PNC lab tables are up to date.';
GO

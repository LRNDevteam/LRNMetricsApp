-- Alter script: add lab-specific columns to existing ClaimLevelData and ClaimLevelDataArchive tables
-- Run this against the target database that already contains the ClaimLine CSV tables.

SET NOCOUNT ON;

-- Add columns to ClaimLevelData if they do not exist
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'UID')
ALTER TABLE dbo.ClaimLevelData ADD
    UID NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Aging')
ALTER TABLE dbo.ClaimLevelData ADD
    Aging NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientName')
ALTER TABLE dbo.ClaimLevelData ADD
    PatientName NVARCHAR(1000) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'LISPatientName')
ALTER TABLE dbo.ClaimLevelData ADD
    LISPatientName NVARCHAR(1000) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'SubscriberId')
ALTER TABLE dbo.ClaimLevelData ADD
    SubscriberId NVARCHAR(1000) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PanelType')
ALTER TABLE dbo.ClaimLevelData ADD
    PanelType NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EnteredWeek')
ALTER TABLE dbo.ClaimLevelData ADD
    EnteredWeek NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EnteredStatus')
ALTER TABLE dbo.ClaimLevelData ADD
    EnteredStatus NVARCHAR(1000) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'LastActivityDate')
ALTER TABLE dbo.ClaimLevelData ADD
    LastActivityDate NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EmedixSubmissionDate')
ALTER TABLE dbo.ClaimLevelData ADD
    EmedixSubmissionDate NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ClaimType')
ALTER TABLE dbo.ClaimLevelData ADD
    ClaimType NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledStatus')
ALTER TABLE dbo.ClaimLevelData ADD
    BilledStatus NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledWeek')
ALTER TABLE dbo.ClaimLevelData ADD
    BilledWeek NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PostedWeek')
ALTER TABLE dbo.ClaimLevelData ADD
    PostedWeek NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ModField')
ALTER TABLE dbo.ClaimLevelData ADD
    ModField NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CheqNo')
ALTER TABLE dbo.ClaimLevelData ADD
    CheqNo NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DuplicatePaymentPosted')
ALTER TABLE dbo.ClaimLevelData ADD
    DuplicatePaymentPosted NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ActualPayment')
ALTER TABLE dbo.ClaimLevelData ADD
    ActualPayment NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ProcTotalBal')
ALTER TABLE dbo.ClaimLevelData ADD
    ProcTotalBal NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DeniedStatus')
ALTER TABLE dbo.ClaimLevelData ADD
    DeniedStatus NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ScrubberEditReason')
ALTER TABLE dbo.ClaimLevelData ADD
    ScrubberEditReason NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EmedixRejectionDate')
ALTER TABLE dbo.ClaimLevelData ADD
    EmedixRejectionDate NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EmedixRejection')
ALTER TABLE dbo.ClaimLevelData ADD
    EmedixRejection NVARCHAR(Max) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'RejectionCategory')
ALTER TABLE dbo.ClaimLevelData ADD
    RejectionCategory NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'TimeToPay')
ALTER TABLE dbo.ClaimLevelData ADD
    TimeToPay NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PaymentPercent')
ALTER TABLE dbo.ClaimLevelData ADD
    PaymentPercent NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidCount')
ALTER TABLE dbo.ClaimLevelData ADD
    FullyPaidCount NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidAmount')
ALTER TABLE dbo.ClaimLevelData ADD
    FullyPaidAmount NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Adjudicated')
ALTER TABLE dbo.ClaimLevelData ADD
    Adjudicated NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AdjudicatedAmount')
ALTER TABLE dbo.ClaimLevelData ADD
    AdjudicatedAmount NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket30')
ALTER TABLE dbo.ClaimLevelData ADD
    Bucket30 NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket30Amount')
ALTER TABLE dbo.ClaimLevelData ADD
    Bucket30Amount NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket60')
ALTER TABLE dbo.ClaimLevelData ADD
    Bucket60 NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket60Amount')
ALTER TABLE dbo.ClaimLevelData ADD
    Bucket60Amount NVARCHAR(500) NULL;

-- Add same columns to ClaimLevelDataArchive if they do not exist
IF OBJECT_ID('dbo.ClaimLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'UID')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD UID NVARCHAR(500) NULL;

    -- (repeat checks for archive table)
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Aging')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD Aging NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PatientName')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'LISPatientName')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD LISPatientName NVARCHAR(1000) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'SubscriberId')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD SubscriberId NVARCHAR(1000) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PanelType')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD PanelType NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EnteredWeek')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD EnteredWeek NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EnteredStatus')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD EnteredStatus NVARCHAR(1000) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'LastActivityDate')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD LastActivityDate NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EmedixSubmissionDate')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD EmedixSubmissionDate NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ClaimType')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD ClaimType NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BilledStatus')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledStatus NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BilledWeek')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledWeek NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PostedWeek')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD PostedWeek NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ModField')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD ModField NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CheqNo')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD CheqNo NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DuplicatePaymentPosted')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD DuplicatePaymentPosted NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ActualPayment')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD ActualPayment NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ProcTotalBal')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD ProcTotalBal NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DeniedStatus')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD DeniedStatus NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ScrubberEditReason')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD ScrubberEditReason NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EmedixRejectionDate')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD EmedixRejectionDate NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EmedixRejection')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD EmedixRejection NVARCHAR(Max) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'RejectionCategory')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD RejectionCategory NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'TimeToPay')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD TimeToPay NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PaymentPercent')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidCount')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidCount NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidAmount')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidAmount NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Adjudicated')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD Adjudicated NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AdjudicatedAmount')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjudicatedAmount NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket30')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30 NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket30Amount')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30Amount NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket60')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60 NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket60Amount')
    ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60Amount NVARCHAR(500) NULL;
END

PRINT 'Alter script completed.\nNote: this script adds columns to ClaimLevelData and ClaimLevelDataArchive.\nTo update the TVP type (ClaimLevelDataTVP) and stored procedure (usp_BulkInsertClaimLevelData) to include these fields, run the updated create script: ClaimLineCSVDataCapture/Sql/01_CreateTables.sql (it contains the new definitions). If the TVP type already exists, you may need to DROP TYPE dbo.ClaimLevelDataTVP and then re-run the create script.'

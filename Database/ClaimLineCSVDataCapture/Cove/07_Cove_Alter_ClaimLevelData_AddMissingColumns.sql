SET NOCOUNT ON;

-- ============================================================
-- Migration: Add missing shared columns to ClaimLevelData / Archive
-- File  : 07_Cove_Alter_ClaimLevelData_AddMissingColumns.sql
--
-- Root cause:
--   usp_BulkInsertClaimLevelData references 25 columns that the
--   existing 02_Cove_Alter_ClaimLevelData_AddFields.sql did not add.
--   These are the shared "additional lab-specific" columns that are
--   present in 01_CreateTables.sql (lines 83-115) and were already
--   added to other lab databases (e.g. NorthWest, Certus, Augustus)
--   but were missed in the Cove-specific alter script.
--
-- Columns added (exactly the 25 referenced in the Msg 207 errors):
--   Aging, LISPatientName, PanelType, EnteredWeek, EnteredStatus,
--   LastActivityDate, EmedixSubmissionDate, ClaimType, BilledStatus,
--   PostedWeek, ModField, CheqNo, DuplicatePaymentPosted, ActualPayment,
--   ProcTotalBal, DeniedStatus, ScrubberEditReason, EmedixRejectionDate,
--   EmedixRejection, RejectionCategory, TimeToPay, Adjudicated,
--   AdjudicatedAmount, Bucket30, Bucket60
--
-- Safe to re-run: all ALTER TABLE statements are guarded by IF NOT EXISTS.
-- Does NOT touch the TVP or SP — only adds table columns.
-- ============================================================

-- ── dbo.ClaimLevelData ───────────────────────────────────────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Aging')
    ALTER TABLE dbo.ClaimLevelData ADD Aging NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='LISPatientName')
    ALTER TABLE dbo.ClaimLevelData ADD LISPatientName NVARCHAR(1000) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='PanelType')
    ALTER TABLE dbo.ClaimLevelData ADD PanelType NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='EnteredWeek')
    ALTER TABLE dbo.ClaimLevelData ADD EnteredWeek NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='EnteredStatus')
    ALTER TABLE dbo.ClaimLevelData ADD EnteredStatus NVARCHAR(1000) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='LastActivityDate')
    ALTER TABLE dbo.ClaimLevelData ADD LastActivityDate NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='EmedixSubmissionDate')
    ALTER TABLE dbo.ClaimLevelData ADD EmedixSubmissionDate NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='ClaimType')
    ALTER TABLE dbo.ClaimLevelData ADD ClaimType NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='BilledStatus')
    ALTER TABLE dbo.ClaimLevelData ADD BilledStatus NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='PostedWeek')
    ALTER TABLE dbo.ClaimLevelData ADD PostedWeek NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='ModField')
    ALTER TABLE dbo.ClaimLevelData ADD ModField NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='CheqNo')
    ALTER TABLE dbo.ClaimLevelData ADD CheqNo NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='DuplicatePaymentPosted')
    ALTER TABLE dbo.ClaimLevelData ADD DuplicatePaymentPosted NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='ActualPayment')
    ALTER TABLE dbo.ClaimLevelData ADD ActualPayment NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='ProcTotalBal')
    ALTER TABLE dbo.ClaimLevelData ADD ProcTotalBal NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='DeniedStatus')
    ALTER TABLE dbo.ClaimLevelData ADD DeniedStatus NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='ScrubberEditReason')
    ALTER TABLE dbo.ClaimLevelData ADD ScrubberEditReason NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='EmedixRejectionDate')
    ALTER TABLE dbo.ClaimLevelData ADD EmedixRejectionDate NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='EmedixRejection')
    ALTER TABLE dbo.ClaimLevelData ADD EmedixRejection NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='RejectionCategory')
    ALTER TABLE dbo.ClaimLevelData ADD RejectionCategory NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='TimeToPay')
    ALTER TABLE dbo.ClaimLevelData ADD TimeToPay NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Adjudicated')
    ALTER TABLE dbo.ClaimLevelData ADD Adjudicated NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='AdjudicatedAmount')
    ALTER TABLE dbo.ClaimLevelData ADD AdjudicatedAmount NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Bucket30')
    ALTER TABLE dbo.ClaimLevelData ADD Bucket30 NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Bucket60')
    ALTER TABLE dbo.ClaimLevelData ADD Bucket60 NVARCHAR(500) NULL;

PRINT 'dbo.ClaimLevelData: missing columns added (or already present).';

-- ── dbo.ClaimLevelDataArchive (if it exists) ─────────────────────────────────

IF OBJECT_ID('dbo.ClaimLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Aging')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Aging NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='LISPatientName')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD LISPatientName NVARCHAR(1000) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='PanelType')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PanelType NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='EnteredWeek')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EnteredWeek NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='EnteredStatus')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EnteredStatus NVARCHAR(1000) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='LastActivityDate')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD LastActivityDate NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='EmedixSubmissionDate')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EmedixSubmissionDate NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='ClaimType')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ClaimType NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='BilledStatus')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledStatus NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='PostedWeek')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PostedWeek NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='ModField')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ModField NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='CheqNo')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CheqNo NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='DuplicatePaymentPosted')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD DuplicatePaymentPosted NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='ActualPayment')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ActualPayment NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='ProcTotalBal')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ProcTotalBal NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='DeniedStatus')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD DeniedStatus NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='ScrubberEditReason')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ScrubberEditReason NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='EmedixRejectionDate')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EmedixRejectionDate NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='EmedixRejection')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EmedixRejection NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='RejectionCategory')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD RejectionCategory NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='TimeToPay')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD TimeToPay NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Adjudicated')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Adjudicated NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='AdjudicatedAmount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjudicatedAmount NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Bucket30')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30 NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Bucket60')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60 NVARCHAR(500) NULL;

    PRINT 'dbo.ClaimLevelDataArchive: missing columns added (or already present).';
END
ELSE
    PRINT 'dbo.ClaimLevelDataArchive does not exist — skipped.';
GO

PRINT '07_Cove_Alter_ClaimLevelData_AddMissingColumns.sql completed successfully.';
GO

SET NOCOUNT ON;

-- PhiLife-specific ClaimLevel additional columns
-- Run after base table creation script (01_CreateTables.sql).
-- PhiLife ClaimLevel CSV contains individual CPT/Unit/Modifier columns
-- plus per-unit amounts, posting/denial fields, and extra provider fields.

-- ── Per-line CPT/Unit/Modifier fields ────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCode')
    ALTER TABLE dbo.ClaimLevelData ADD CPTCode NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Units')
    ALTER TABLE dbo.ClaimLevelData ADD Units NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Modifier')
    ALTER TABLE dbo.ClaimLevelData ADD Modifier NVARCHAR(500) NULL;

-- ── Per-unit amount fields ────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ChargeAmountPerUnit')
    ALTER TABLE dbo.ClaimLevelData ADD ChargeAmountPerUnit NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AllowedAmountPerUnit')
    ALTER TABLE dbo.ClaimLevelData ADD AllowedAmountPerUnit NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'InsurancePaymentPerUnit')
    ALTER TABLE dbo.ClaimLevelData ADD InsurancePaymentPerUnit NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientPaymentPerUnit')
    ALTER TABLE dbo.ClaimLevelData ADD PatientPaymentPerUnit NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientBalancePerUnit')
    ALTER TABLE dbo.ClaimLevelData ADD PatientBalancePerUnit NVARCHAR(500) NULL;

-- ── Payment / Denial status fields ───────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PaymentPostedDate')
    ALTER TABLE dbo.ClaimLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PayStatus')
    ALTER TABLE dbo.ClaimLevelData ADD PayStatus NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DenialDate')
    ALTER TABLE dbo.ClaimLevelData ADD DenialDate NVARCHAR(500) NULL;

-- ── Provider / patient extra fields ──────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ResponsibleParty')
    ALTER TABLE dbo.ClaimLevelData ADD ResponsibleParty NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EndDOS')
    ALTER TABLE dbo.ClaimLevelData ADD EndDOS NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BillOccurance')
    ALTER TABLE dbo.ClaimLevelData ADD BillOccurance NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EntryUser')
    ALTER TABLE dbo.ClaimLevelData ADD EntryUser NVARCHAR(500) NULL;

-- ── CPT summary / composite fields ───────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTUnits')
    ALTER TABLE dbo.ClaimLevelData ADD CPTUnits NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTMOD')
    ALTER TABLE dbo.ClaimLevelData ADD CPTMOD NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTs')
    ALTER TABLE dbo.ClaimLevelData ADD CPTs NVARCHAR(MAX) NULL;

-- ── Mirror changes to ClaimLevelDataArchive ───────────────────────────────────
IF OBJECT_ID('dbo.ClaimLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTCode')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCode NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Units')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Units NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Modifier')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Modifier NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ChargeAmountPerUnit')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ChargeAmountPerUnit NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AllowedAmountPerUnit')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD AllowedAmountPerUnit NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'InsurancePaymentPerUnit')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD InsurancePaymentPerUnit NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PatientPaymentPerUnit')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientPaymentPerUnit NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PatientBalancePerUnit')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientBalancePerUnit NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PaymentPostedDate')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PaymentPostedDate NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PayStatus')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PayStatus NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DenialDate')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD DenialDate NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ResponsibleParty')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ResponsibleParty NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EndDOS')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EndDOS NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BillOccurance')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD BillOccurance NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EntryUser')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EntryUser NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTUnits')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTUnits NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTMOD')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTMOD NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTs')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTs NVARCHAR(MAX) NULL;
END

PRINT 'PhiLife ClaimLevel alter script completed.';

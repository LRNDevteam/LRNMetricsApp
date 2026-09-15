/* ============================================================================
   Denial Workflow - master value lists (LRNMaster)

   The seven lists the Denial Mapper offers when a denial code is mapped:

     List               Table                                   Key
     -----------------  --------------------------------------  ----------------------
     Classification     dbo.DenialMapperLookupMaster            LookupType = DenialClassification
     Coverage Status    dbo.DenialMapperLookupMaster            LookupType = CoverageStatus
     ICD Compliance     dbo.DenialMapperLookupMaster            LookupType = ICDComplianceStatus
     Denial Validity    dbo.DenialMapperLookupMaster            LookupType = DenialValidity
     SLA                dbo.DenialMapperLookupMaster            LookupType = SLADays
     Priority           dbo.DenialMapperLookupMaster            LookupType = Priority
     Action Category    dbo.DenialMapperActionCategoryMaster    ActionCategory (+ ActionCode)

   Admins maintain them in the Denial Workflow app: Master Values (admin only).

   These are the SAME tables the Denial Mapper has always read. No second copy is created -
   a parallel set of tables would give the admin screen data that nothing reads.

   What this script does
     1. Creates both tables if they do not exist.
     2. Adds CreatedBy / ModifiedBy / ModifiedOn so the screen can show who changed a value.
     3. Seeds the default values ONLY into an empty table.

   It never updates or re-activates an existing row. The API used to run a MERGE on every
   Denial Mapper load that did exactly that, which would have undone every admin change;
   that is fixed in the same release (DenialMapperService.EnsureMasterDataSchemaAsync).

   RE-RUNNABLE and non-destructive. Safe on a database that already has the lists.
   The API performs steps 1-3 itself on first use, so running this is optional - it is
   here for DBAs who prefer schema changes to go in ahead of the deploy.

   NOT to be confused with DenialMapper_MasterData_Setup.sql: that one-off normalisation
   script MERGEs its values back in and re-activates them. Do not re-run it once admins
   have started using the Master Values screen.
   ============================================================================ */

USE LRNMaster;
GO

-- NormalizedValue is a PERSISTED computed column; writes to the table need these ON.
-- SSMS sets them by default but sqlcmd does not.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------- 1. Tables */
IF OBJECT_ID('dbo.DenialMapperLookupMaster','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialMapperLookupMaster
    (
        LookupType      nvarchar(50)  NOT NULL,
        LookupValue     nvarchar(255) NOT NULL,
        NormalizedValue AS UPPER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(LookupValue)),'-',''),' ',''),'/','')) PERSISTED,
        SortOrder       int           NOT NULL CONSTRAINT DF_DMLM_SortOrder DEFAULT 0,
        IsActive        bit           NOT NULL CONSTRAINT DF_DMLM_IsActive  DEFAULT 1,
        CreatedOn       datetime2(0)  NOT NULL CONSTRAINT DF_DMLM_CreatedOn DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_DenialMapperLookupMaster PRIMARY KEY (LookupType, LookupValue)
    );
    PRINT 'Created dbo.DenialMapperLookupMaster';
END

IF OBJECT_ID('dbo.DenialMapperActionCategoryMaster','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialMapperActionCategoryMaster
    (
        ActionCategory nvarchar(255) NOT NULL CONSTRAINT PK_DenialMapperActionCategoryMaster PRIMARY KEY,
        ActionCode     nvarchar(100) NOT NULL,
        SortOrder      int           NOT NULL CONSTRAINT DF_DMACM_SortOrder DEFAULT 0,
        IsActive       bit           NOT NULL CONSTRAINT DF_DMACM_IsActive  DEFAULT 1,
        CreatedOn      datetime2(0)  NOT NULL CONSTRAINT DF_DMACM_CreatedOn DEFAULT SYSUTCDATETIME()
    );
    PRINT 'Created dbo.DenialMapperActionCategoryMaster';
END
GO

/* --------------------------------------------------------- 2. Audit columns */
-- Nullable: the existing seeded rows predate the admin screen and have no author.
IF COL_LENGTH('dbo.DenialMapperLookupMaster','CreatedBy')  IS NULL ALTER TABLE dbo.DenialMapperLookupMaster ADD CreatedBy  nvarchar(200) NULL;
IF COL_LENGTH('dbo.DenialMapperLookupMaster','ModifiedBy') IS NULL ALTER TABLE dbo.DenialMapperLookupMaster ADD ModifiedBy nvarchar(200) NULL;
IF COL_LENGTH('dbo.DenialMapperLookupMaster','ModifiedOn') IS NULL ALTER TABLE dbo.DenialMapperLookupMaster ADD ModifiedOn datetime2(0)  NULL;

IF COL_LENGTH('dbo.DenialMapperActionCategoryMaster','CreatedBy')  IS NULL ALTER TABLE dbo.DenialMapperActionCategoryMaster ADD CreatedBy  nvarchar(200) NULL;
IF COL_LENGTH('dbo.DenialMapperActionCategoryMaster','ModifiedBy') IS NULL ALTER TABLE dbo.DenialMapperActionCategoryMaster ADD ModifiedBy nvarchar(200) NULL;
IF COL_LENGTH('dbo.DenialMapperActionCategoryMaster','ModifiedOn') IS NULL ALTER TABLE dbo.DenialMapperActionCategoryMaster ADD ModifiedOn datetime2(0)  NULL;
GO
-- ^ This GO matters: step 3 names CreatedBy, and SQL Server binds column names per batch,
--   so the INSERTs must compile in a batch that starts after the columns exist.

/* ------------------------------------------------ 3. Defaults, empty tables only */
IF NOT EXISTS (SELECT 1 FROM dbo.DenialMapperLookupMaster)
BEGIN
    INSERT dbo.DenialMapperLookupMaster (LookupType, LookupValue, SortOrder, CreatedBy)
    VALUES
    ('DenialClassification','Administrative Denial',10,N'system'),
    ('DenialClassification','Administrative Denial / Denial Upheld on Appeal',20,N'system'),
    ('DenialClassification','Authorization Denial',30,N'system'),
    ('DenialClassification','Billing / Coding Error',40,N'system'),
    ('DenialClassification','Billing Related Denial',50,N'system'),
    ('DenialClassification','Bundling/Unbundling Denial',60,N'system'),
    ('DenialClassification','COB / Coordination of Benefits Denial',70,N'system'),
    ('DenialClassification','COB / Routing Denial',80,N'system'),
    ('DenialClassification','Contractual Adjustment',90,N'system'),
    ('DenialClassification','CPT Related Denial',100,N'system'),
    ('DenialClassification',N'CPT Related Denial — Scenario 2 (Post EOB Review)',110,N'system'),
    ('DenialClassification','Documentation Denial',120,N'system'),
    ('DenialClassification','Duplicate Claim',130,N'system'),
    ('DenialClassification','Eligibility / Coverage Denial',140,N'system'),
    ('DenialClassification','Frequency Related Denial',150,N'system'),
    ('DenialClassification','ICD/CPT Policy Compliance Denial',160,N'system'),
    ('DenialClassification','Informational / No Action Required',170,N'system'),
    ('DenialClassification','Medical Necessity / CPT Related Denial',180,N'system'),
    ('DenialClassification','Medical Necessity / Utilization Review Denial',190,N'system'),
    ('DenialClassification','Medical Necessity Denial',200,N'system'),
    ('DenialClassification','Patient Responsibility',210,N'system'),
    ('DenialClassification','Plan Benefit Denial',220,N'system'),
    ('DenialClassification','Policy Related Denial',230,N'system'),
    ('DenialClassification','Provider Credentialing',240,N'system'),
    ('DenialClassification','Third Party Liability',250,N'system'),
    ('DenialClassification','Timely Filing Denial',260,N'system'),
    ('CoverageStatus','Covered',10,N'system'),
    ('CoverageStatus','Conditional - Note',20,N'system'),
    ('CoverageStatus','Conditional - Note & Dx',30,N'system'),
    ('CoverageStatus','Conditional - Dx',40,N'system'),
    ('CoverageStatus','N/A',50,N'system'),
    ('CoverageStatus','No Policy Found',60,N'system'),
    ('CoverageStatus','Non-Covered',70,N'system'),
    ('CoverageStatus','No Policy Found - Payment Expected',80,N'system'),
    ('CoverageStatus','No Policy Found - Payment Uncertain',90,N'system'),
    ('ICDComplianceStatus','N/A',10,N'system'),
    ('ICDComplianceStatus','ICD Non Payable',20,N'system'),
    ('ICDComplianceStatus','ICD Not Found in Policy',30,N'system'),
    ('ICDComplianceStatus','CPT Not Found in Policy',40,N'system'),
    ('ICDComplianceStatus','ICD Potentially Compliant',50,N'system'),
    ('ICDComplianceStatus','Payer Not Found',60,N'system'),
    ('ICDComplianceStatus','Other ICD Covered but not billed as Primary',70,N'system'),
    ('ICDComplianceStatus','ICD Validation Not Required',80,N'system'),
    ('ICDComplianceStatus','ICD Compliant',90,N'system'),
    ('ICDComplianceStatus','Policy Not Found',100,N'system'),
    ('DenialValidity','Denial Not Valid as per Payer Policy',10,N'system'),
    ('DenialValidity',N'Denial Upheld — Claim Processed Correctly',20,N'system'),
    ('DenialValidity','Denial Valid as per Payer Policy',30,N'system'),
    ('DenialValidity','Denial Validity Unknown',40,N'system'),
    ('DenialValidity',N'Denial Validity Unknown — Review EOB',50,N'system'),
    ('DenialValidity','N/A',60,N'system'),
    ('DenialValidity','Provider Enrollment Missing / Inactive',70,N'system'),
    ('DenialValidity',N'Wrong Payer Billed — Correct Payer Unknown',80,N'system'),
    ('SLADays','0 days',10,N'system'),
    ('SLADays','5 days',20,N'system'),
    ('SLADays','7 days',30,N'system'),
    ('SLADays','10 days',40,N'system'),
    ('SLADays','15 days',50,N'system'),
    ('SLADays','30 days',60,N'system'),
    ('Priority','High',10,N'system'),
    ('Priority','Medium',20,N'system'),
    ('Priority','Low',30,N'system');

    PRINT 'Seeded dbo.DenialMapperLookupMaster with the default lists';
END
ELSE
    PRINT 'dbo.DenialMapperLookupMaster already has values - left unchanged';

IF NOT EXISTS (SELECT 1 FROM dbo.DenialMapperActionCategoryMaster)
BEGIN
    INSERT dbo.DenialMapperActionCategoryMaster (ActionCategory, ActionCode, SortOrder, CreatedBy)
    VALUES
    ('Appeal','APP',10,N'system'),
    ('Rebill','APP',20,N'system'),
    ('Client Info Pending','CIP',30,N'system'),
    ('Client Info Pending / Write Off','CIP / WOFF',40,N'system'),
    ('Credentialing / Enrollment','CRED',50,N'system'),
    ('Manual Review','MR',60,N'system'),
    ('No Action','NA',70,N'system');

    PRINT 'Seeded dbo.DenialMapperActionCategoryMaster with the default action categories';
END
ELSE
    PRINT 'dbo.DenialMapperActionCategoryMaster already has values - left unchanged';
GO

/* ------------------------------------------------------------------- Verify */
SELECT LookupType, COUNT(*) AS [Values], SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END) AS Active
FROM dbo.DenialMapperLookupMaster
GROUP BY LookupType
UNION ALL
SELECT 'ActionCategory', COUNT(*), SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END)
FROM dbo.DenialMapperActionCategoryMaster
ORDER BY LookupType;
GO

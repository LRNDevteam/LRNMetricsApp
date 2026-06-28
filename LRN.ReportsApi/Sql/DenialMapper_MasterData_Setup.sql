/*
  LRNMaster - normalized Denial Mapper master data
  Source: master data.xlsx supplied 2026-06-26

  Normalization decisions:
  - Non Covered / Non-Covered => Non-Covered
  - Conditional Note variants => canonical values using "Conditional - ..."
  - Provider Credentialling => Provider Credentialing
  - Blank coverage is omitted; use N/A where a value is required
  - Appeal had APP and CRED in the source. APP is canonical for Appeal;
    CRED is canonical for Credentialing / Enrollment.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID('dbo.DenialMapperLookupMaster','U') IS NULL
CREATE TABLE dbo.DenialMapperLookupMaster
(
    LookupType nvarchar(50) NOT NULL,
    LookupValue nvarchar(255) NOT NULL,
    NormalizedValue AS UPPER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(LookupValue)),'-',''),' ',''),'/','')) PERSISTED,
    SortOrder int NOT NULL CONSTRAINT DF_DMLM_SortOrder DEFAULT 0,
    IsActive bit NOT NULL CONSTRAINT DF_DMLM_IsActive DEFAULT 1,
    CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DMLM_CreatedOn DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_DenialMapperLookupMaster PRIMARY KEY(LookupType,LookupValue)
);

IF OBJECT_ID('dbo.DenialMapperActionCategoryMaster','U') IS NULL
CREATE TABLE dbo.DenialMapperActionCategoryMaster
(
    ActionCategory nvarchar(255) NOT NULL CONSTRAINT PK_DenialMapperActionCategoryMaster PRIMARY KEY,
    ActionCode nvarchar(100) NOT NULL,
    SortOrder int NOT NULL CONSTRAINT DF_DMACM_SortOrder DEFAULT 0,
    IsActive bit NOT NULL CONSTRAINT DF_DMACM_IsActive DEFAULT 1,
    CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DMACM_CreatedOn DEFAULT SYSUTCDATETIME()
);

DECLARE @Lookup TABLE(LookupType nvarchar(50),LookupValue nvarchar(255),SortOrder int);
INSERT @Lookup VALUES
('DenialClassification','Administrative Denial',10),
('DenialClassification','Administrative Denial / Denial Upheld on Appeal',20),
('DenialClassification','Authorization Denial',30),
('DenialClassification','Billing / Coding Error',40),
('DenialClassification','Billing Related Denial',50),
('DenialClassification','Bundling/Unbundling Denial',60),
('DenialClassification','COB / Coordination of Benefits Denial',70),
('DenialClassification','COB / Routing Denial',80),
('DenialClassification','Contractual Adjustment',90),
('DenialClassification','CPT Related Denial',100),
('DenialClassification','CPT Related Denial — Scenario 2 (Post EOB Review)',110),
('DenialClassification','Documentation Denial',120),
('DenialClassification','Duplicate Claim',130),
('DenialClassification','Eligibility / Coverage Denial',140),
('DenialClassification','Frequency Related Denial',150),
('DenialClassification','ICD/CPT Policy Compliance Denial',160),
('DenialClassification','Informational / No Action Required',170),
('DenialClassification','Medical Necessity / CPT Related Denial',180),
('DenialClassification','Medical Necessity / Utilization Review Denial',190),
('DenialClassification','Medical Necessity Denial',200),
('DenialClassification','Patient Responsibility',210),
('DenialClassification','Plan Benefit Denial',220),
('DenialClassification','Policy Related Denial',230),
('DenialClassification','Provider Credentialing',240),
('DenialClassification','Third Party Liability',250),
('DenialClassification','Timely Filing Denial',260),
('CoverageStatus','Covered',10),
('CoverageStatus','Conditional - Note',20),
('CoverageStatus','Conditional - Note & Dx',30),
('CoverageStatus','Conditional - Dx',40),
('CoverageStatus','N/A',50),
('CoverageStatus','No Policy Found',60),
('CoverageStatus','Non-Covered',70),
('CoverageStatus','No Policy Found - Payment Expected',80),
('CoverageStatus','No Policy Found - Payment Uncertain',90),
('ICDComplianceStatus','N/A',10),
('ICDComplianceStatus','ICD Non Payable',20),
('ICDComplianceStatus','ICD Not Found in Policy',30),
('ICDComplianceStatus','CPT Not Found in Policy',40),
('ICDComplianceStatus','ICD Potentially Compliant',50),
('ICDComplianceStatus','Payer Not Found',60),
('ICDComplianceStatus','Other ICD Covered but not billed as Primary',70),
('ICDComplianceStatus','ICD Validation Not Required',80),
('ICDComplianceStatus','ICD Compliant',90),
('ICDComplianceStatus','Policy Not Found',100),
('DenialValidity','Denial Not Valid as per Payer Policy',10),
('DenialValidity','Denial Upheld — Claim Processed Correctly',20),
('DenialValidity','Denial Valid as per Payer Policy',30),
('DenialValidity','Denial Validity Unknown',40),
('DenialValidity','Denial Validity Unknown — Review EOB',50),
('DenialValidity','N/A',60),
('DenialValidity','Provider Enrollment Missing / Inactive',70),
('DenialValidity','Wrong Payer Billed — Correct Payer Unknown',80),
('SLADays','0 days',10),('SLADays','5 days',20),('SLADays','7 days',30),
('SLADays','10 days',40),('SLADays','15 days',50),('SLADays','30 days',60),
('Priority','High',10),('Priority','Medium',20),('Priority','Low',30);

MERGE dbo.DenialMapperLookupMaster AS target
USING @Lookup AS source
ON target.LookupType=source.LookupType AND target.LookupValue=source.LookupValue
WHEN MATCHED THEN UPDATE SET SortOrder=source.SortOrder,IsActive=1
WHEN NOT MATCHED THEN INSERT(LookupType,LookupValue,SortOrder)
VALUES(source.LookupType,source.LookupValue,source.SortOrder);

DECLARE @Action TABLE(ActionCategory nvarchar(255),ActionCode nvarchar(100),SortOrder int);
INSERT @Action VALUES
('Appeal','APP',10),
('Rebill','APP',20),
('Client Info Pending','CIP',30),
('Client Info Pending / Write Off','CIP / WOFF',40),
('Credentialing / Enrollment','CRED',50),
('Manual Review','MR',60),
('No Action','NA',70);

MERGE dbo.DenialMapperActionCategoryMaster AS target
USING @Action AS source ON target.ActionCategory=source.ActionCategory
WHEN MATCHED THEN UPDATE SET ActionCode=source.ActionCode,SortOrder=source.SortOrder,IsActive=1
WHEN NOT MATCHED THEN INSERT(ActionCategory,ActionCode,SortOrder)
VALUES(source.ActionCategory,source.ActionCode,source.SortOrder);

COMMIT TRANSACTION;

SELECT LookupType,LookupValue,SortOrder,IsActive
FROM dbo.DenialMapperLookupMaster
ORDER BY LookupType,SortOrder,LookupValue;

SELECT ActionCategory,ActionCode,SortOrder,IsActive
FROM dbo.DenialMapperActionCategoryMaster
ORDER BY SortOrder,ActionCategory;

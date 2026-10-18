/* =====================================================================
   Payer Policy Mapper - minimal schema additions (idempotent)
   Companion to LRN_PayerPolicyMapper (Core + worker + web endpoints).
   Reference tables (USStateCode, PayerFamilyRule, StateBrandMapping,
   ProgramTypeRule, PlanNetworkTypeCode, PayerAlias) are deployed by
   Payer_Matching_Reference_Tables_DDL_and_Seed.sql and are NOT touched here.
   ===================================================================== */
SET NOCOUNT ON;
GO

-- 1. Three columns on LabInsuranceMaster ---------------------------------
IF COL_LENGTH('dbo.LabInsuranceMaster', 'MappingStatus') IS NULL
    ALTER TABLE dbo.LabInsuranceMaster ADD MappingStatus NVARCHAR(50) NULL;   -- 'Mapped' / 'Unmapped' / 'Unmapped - Pending Review' / 'No Match Found'
GO
IF COL_LENGTH('dbo.LabInsuranceMaster', 'MappedBy') IS NULL
    ALTER TABLE dbo.LabInsuranceMaster ADD MappedBy NVARCHAR(100) NULL;       -- 'System (Auto-Match)' / 'Approved (System Match)' / 'Manual (<username>)'
GO
IF COL_LENGTH('dbo.LabInsuranceMaster', 'LastEvaluatedOn') IS NULL
    ALTER TABLE dbo.LabInsuranceMaster ADD LastEvaluatedOn DATETIME2 NULL;    -- worker watermark
GO

-- Backfill MappingStatus for existing rows (only where still blank).
UPDATE dbo.LabInsuranceMaster
SET MappingStatus = CASE WHEN GlobalPayerID IS NOT NULL THEN 'Mapped' ELSE 'Unmapped' END
WHERE MappingStatus IS NULL;
GO

-- 2. Top-5 suggestions for the mapping UI (delete-and-replace per evaluation)
IF OBJECT_ID('dbo.PendingMatchCandidates', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PendingMatchCandidates (
        Id                  BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_PendingMatchCandidates PRIMARY KEY,
        LabInsuranceMasterId INT          NOT NULL,
        PPInsuranceMasterId INT           NOT NULL,
        GlobalPayerId       INT           NULL,     -- null when the candidate policy row has no parseable id
        Score               DECIMAL(5,2)  NULL,
        [Rank]              TINYINT       NULL,
        BaseNameScore       DECIMAL(5,2)  NULL,
        StateAdjustment     INT           NULL,
        ProgramAdjustment   INT           NULL,
        CreatedOn           DATETIME2     NOT NULL CONSTRAINT DF_PMC_CreatedOn DEFAULT (SYSUTCDATETIME())
    );
    CREATE INDEX IX_PMC_Lab ON dbo.PendingMatchCandidates (LabInsuranceMasterId);
END
GO

-- 3. Audit trail (one row per evaluation or user action)
IF OBJECT_ID('dbo.PayerMatchAudit', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PayerMatchAudit (
        AuditId              BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_PayerMatchAudit PRIMARY KEY,
        LabInsuranceMasterId INT           NULL,
        PayerNameRaw         NVARCHAR(500) NULL,
        CanonicalName        NVARCHAR(500) NULL,
        ResolvedStateCode    CHAR(2)       NULL,
        StateSignalSource    NVARCHAR(20)  NULL,    -- None / NameEmbedded / BrandMapping / LabState
        ResolvedProgramType  NVARCHAR(50)  NULL,
        CandidateFamily      NVARCHAR(250) NULL,
        Decision             NVARCHAR(20)  NULL,    -- AutoMap / ManualReview / NoMatch
        ConfidenceScore      DECIMAL(5,2)  NULL,
        SelectedGlobalPayerId INT          NULL,
        CandidatesJson       NVARCHAR(MAX) NULL,
        AliasHit             BIT           NULL,
        ActionType           NVARCHAR(30)  NULL,    -- Evaluate / AutoMap / Approve / Reject / ManualMap / NightlyRescan
        PerformedBy          NVARCHAR(100) NULL,
        PerformedOn          DATETIME2     NOT NULL CONSTRAINT DF_PayerMatchAudit_PerformedOn DEFAULT (SYSUTCDATETIME())
    );
    CREATE INDEX IX_PayerMatchAudit_Lab ON dbo.PayerMatchAudit (LabInsuranceMasterId);
END
GO

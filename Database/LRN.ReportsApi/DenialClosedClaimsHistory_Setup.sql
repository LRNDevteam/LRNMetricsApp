/*
Run this in each lab database that contains DenialTaskBoard and DenialLineItem.
It adds workflow status tracking, the closed-claims display table, and the
history table for closed-claim audit entries.
*/

IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard','WorkFlowStatus') IS NULL
        ALTER TABLE dbo.DenialTaskBoard ADD WorkFlowStatus nvarchar(100) NULL;
END;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialLineItem','AssignedTo') IS NULL
        ALTER TABLE dbo.DenialLineItem ADD AssignedTo nvarchar(255) NULL;

    IF COL_LENGTH('dbo.DenialLineItem','WorkFlowStatus') IS NULL
        ALTER TABLE dbo.DenialLineItem ADD WorkFlowStatus nvarchar(100) NULL;
END;

IF OBJECT_ID('dbo.DenialClosedClaims','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClosedClaims
    (
        ClosedClaimId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClosedClaims PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        PayerName nvarchar(256) NULL,
        PanelName nvarchar(256) NULL,
        PatientName nvarchar(255) NULL,
        PatientDOB date NULL,
        PatientId nvarchar(100) NULL,
        SubscriberId nvarchar(100) NULL,
        ClinicName nvarchar(256) NULL,
        SalesRepname nvarchar(256) NULL,
        ReferringProvider nvarchar(256) NULL,
        DateOfService date NULL,
        AssignedTo nvarchar(255) NULL,
        Status nvarchar(100) NOT NULL CONSTRAINT DF_DenialClosedClaims_Status DEFAULT 'Closed',
        WorkFlowStatus nvarchar(100) NOT NULL CONSTRAINT DF_DenialClosedClaims_WorkFlowStatus DEFAULT 'Closed Claim',
        TaskCount int NOT NULL CONSTRAINT DF_DenialClosedClaims_TaskCount DEFAULT 0,
        InsuranceBalance decimal(18,2) NOT NULL CONSTRAINT DF_DenialClosedClaims_InsuranceBalance DEFAULT 0,
        ClosedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaims_ClosedOn DEFAULT SYSUTCDATETIME(),
        ClosedBy nvarchar(256) NULL,
        LastUpdatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaims_LastUpdatedOn DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_DenialClosedClaims_Lab_Claim
        ON dbo.DenialClosedClaims(LabId, ClaimId);

    CREATE INDEX IX_DenialClosedClaims_Lab_ClosedOn
        ON dbo.DenialClosedClaims(LabId, ClosedOn DESC)
        INCLUDE(ClaimId, AssignedTo, WorkFlowStatus, InsuranceBalance);
END;

IF OBJECT_ID('dbo.DenialClosedClaimsHistory','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClosedClaimsHistory
    (
        HistoryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClosedClaimsHistory PRIMARY KEY,
        ClosedClaimId bigint NULL,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        ActionType nvarchar(100) NOT NULL,
        OldWorkFlowStatus nvarchar(100) NULL,
        NewWorkFlowStatus nvarchar(100) NULL,
        OldAssignedTo nvarchar(255) NULL,
        NewAssignedTo nvarchar(255) NULL,
        Comments nvarchar(max) NULL,
        ActionBy nvarchar(256) NULL,
        ActionDate datetime2(0) NOT NULL CONSTRAINT DF_DenialClosedClaimsHistory_ActionDate DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_DenialClosedClaimsHistory_Lab_Claim
        ON dbo.DenialClosedClaimsHistory(LabId, ClaimId, ActionDate DESC);
END;

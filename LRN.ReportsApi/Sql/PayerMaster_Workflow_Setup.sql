/* =====================================================================
   Payer Master Workflow Setup (Requirements Spec v1.0, July 2026)
   Target database: LRNMaster (ConnectionStrings:DefaultConnection)

   Creates:
     - dbo.PayerMasterApprovalRequests  (approval queue for Reports Analyst actions)
     - dbo.PayerMasterAuditTrail        (field-level before/after audit, both masters)
     - dbo.PayerMasterNotifications     (in-app role/user notifications)
     - dbo.PayerMasterGlobalPayerIdSeq  (system-assigned sequential Global Payer ID,
                                         seeded above the current max in both masters;
                                         never reused, including after deactivation)

   Idempotent - safe to run multiple times.
   ===================================================================== */
SET NOCOUNT ON;

IF OBJECT_ID('dbo.PayerMasterApprovalRequests', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PayerMasterApprovalRequests
    (
        ApprovalRequestId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayerMasterApprovalRequests PRIMARY KEY,
        Master            NVARCHAR(20)  NOT NULL,               -- 'Policy' | 'Lab'
        ActionType        NVARCHAR(20)  NOT NULL,               -- 'Add' | 'Edit' | 'Deactivate' | 'Map'
        TargetId          INT           NULL,                   -- existing record id (NULL for Add)
        PayerName         NVARCHAR(250) NULL,
        PayloadJson       NVARCHAR(MAX) NULL,                   -- serialized DTO to apply on approval
        SubmittedBy       NVARCHAR(100) NOT NULL,
        SubmittedOn       DATETIME2(0)  NOT NULL CONSTRAINT DF_PMApproval_SubmittedOn DEFAULT SYSUTCDATETIME(),
        Status            NVARCHAR(20)  NOT NULL CONSTRAINT DF_PMApproval_Status DEFAULT 'Pending',  -- Pending | Approved | Rejected
        DecidedBy         NVARCHAR(100) NULL,
        DecidedOn         DATETIME2(0)  NULL,
        RejectionReason   NVARCHAR(1000) NULL,
        EscalatedOn       DATETIME2(0)  NULL                    -- set when the SLA escalation notification was sent
    );
    CREATE INDEX IX_PMApproval_Status_Master ON dbo.PayerMasterApprovalRequests (Status, Master) INCLUDE (SubmittedOn);
    CREATE INDEX IX_PMApproval_SubmittedBy ON dbo.PayerMasterApprovalRequests (SubmittedBy);
END;

IF OBJECT_ID('dbo.PayerMasterAuditTrail', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PayerMasterAuditTrail
    (
        AuditId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayerMasterAuditTrail PRIMARY KEY,
        Master          NVARCHAR(20)  NOT NULL,                 -- 'Policy' | 'Lab'
        RecordId        INT           NULL,
        GlobalPayerID   INT           NULL,
        PayerName       NVARCHAR(250) NULL,
        FieldName       NVARCHAR(100) NOT NULL,
        OldValue        NVARCHAR(1000) NULL,
        NewValue        NVARCHAR(1000) NULL,
        ActionType      NVARCHAR(20)  NOT NULL,                 -- Add | Edit | Deactivate | Map | Approve | Reject | Import
        PerformedBy     NVARCHAR(100) NOT NULL,
        PerformedOn     DATETIME2(0)  NOT NULL CONSTRAINT DF_PMAudit_PerformedOn DEFAULT SYSUTCDATETIME(),
        ApprovalStatus  NVARCHAR(30)  NULL,                     -- Applied directly | Pending | Approved | Rejected
        Approver        NVARCHAR(100) NULL,
        RejectionReason NVARCHAR(1000) NULL
    );
    CREATE INDEX IX_PMAudit_Master_PerformedOn ON dbo.PayerMasterAuditTrail (Master, PerformedOn DESC);
    CREATE INDEX IX_PMAudit_RecordId ON dbo.PayerMasterAuditTrail (Master, RecordId);
END;

IF OBJECT_ID('dbo.PayerMasterNotifications', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PayerMasterNotifications
    (
        NotificationId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayerMasterNotifications PRIMARY KEY,
        Master          NVARCHAR(20)  NOT NULL,                 -- 'Policy' | 'Lab'
        TriggerType     NVARCHAR(40)  NOT NULL,                 -- NewPayer | PayerUpdated | PayerDeactivated | ApprovalPending | ApprovalOutcome | SlaEscalation | NewUnmappedPayer
        Title           NVARCHAR(300) NOT NULL,
        Message         NVARCHAR(1000) NULL,
        RecipientRole   NVARCHAR(50)  NULL,                     -- role-wide notification (one row per role)
        RecipientUser   NVARCHAR(100) NULL,                     -- user-specific (approval/rejection outcome to submitter)
        CreatedOn       DATETIME2(0)  NOT NULL CONSTRAINT DF_PMNotif_CreatedOn DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PMNotif_Role_CreatedOn ON dbo.PayerMasterNotifications (RecipientRole, CreatedOn DESC);
    CREATE INDEX IX_PMNotif_User_CreatedOn ON dbo.PayerMasterNotifications (RecipientUser, CreatedOn DESC);
END;

/* Sequential, never-reused Global Payer ID (Spec 5.1).
   Seeded above the current max across both masters. */
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = 'PayerMasterGlobalPayerIdSeq' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    DECLARE @MaxId INT = 1000;
    SELECT @MaxId = MAX(v) FROM (VALUES
        (ISNULL((SELECT MAX(GlobalPayerID) FROM dbo.PayerPolicyInsuranceMaster), 1000)),
        (ISNULL((SELECT MAX(GlobalPayerID) FROM dbo.LabInsuranceMaster), 1000)),
        (1000)) AS x(v);

    DECLARE @Sql NVARCHAR(400) =
        N'CREATE SEQUENCE dbo.PayerMasterGlobalPayerIdSeq AS INT START WITH ' + CAST(@MaxId + 1 AS NVARCHAR(20)) + N' INCREMENT BY 1 NO CYCLE;';
    EXEC sys.sp_executesql @Sql;
END;

PRINT 'Payer Master workflow objects are ready.';

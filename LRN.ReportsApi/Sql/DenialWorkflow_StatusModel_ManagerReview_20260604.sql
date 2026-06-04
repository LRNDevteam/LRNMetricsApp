/*
  Denial Workflow Manager Review status model migration
  Date: 2026-06-04

  Run this once per lab database before relying on the manager-review status fields.
  The script is idempotent and intentionally leaves unmapped/custom statuses for review.
*/

SET NOCOUNT ON;

IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NULL
BEGIN
    RAISERROR('dbo.DenialTaskBoard was not found in this database.', 16, 1);
    RETURN;
END;

IF COL_LENGTH('dbo.DenialTaskBoard','ActionCompleted') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ActionCompleted bit NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ActualOutcome') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ActualOutcome nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','DocumentationType') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD DocumentationType nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','FollowUpReason') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD FollowUpReason nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ClosureReason') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ClosureReason nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','SyncConfirmation') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD SyncConfirmation nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ValidationStatus') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ValidationStatus nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ExpectedResponseDate') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ExpectedResponseDate date NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','LastWorkflowUpdatedBy') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD LastWorkflowUpdatedBy nvarchar(255) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','LastWorkflowUpdatedOn') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD LastWorkflowUpdatedOn datetime2(0) NULL;

IF OBJECT_ID('dbo.DenialClaimEscalations','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimEscalations','EscalationScope') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD EscalationScope nvarchar(30) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','EscalationScopeValue') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD EscalationScopeValue nvarchar(150) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','EscalationScopeDisplay') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD EscalationScopeDisplay nvarchar(255) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','AffectedTaskIds') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD AffectedTaskIds nvarchar(max) NULL;
    IF COL_LENGTH('dbo.DenialClaimEscalations','RecommendedNextAction') IS NULL ALTER TABLE dbo.DenialClaimEscalations ADD RecommendedNextAction nvarchar(150) NULL;
END;

UPDATE dbo.DenialTaskBoard
SET Status = CASE LOWER(LTRIM(RTRIM(ISNULL(Status,''))))
    WHEN '' THEN 'Assigned'
    WHEN 'open' THEN 'Assigned'
    WHEN 'in progress' THEN 'Assigned'
    WHEN 'in-progress' THEN 'Assigned'
    WHEN 'pending review' THEN 'Assigned'
    WHEN 'pending payer' THEN 'Pending Payer Response'
    WHEN 'escalated' THEN 'Escalated to AR Manager'
    WHEN 'internal escalation' THEN 'Escalated to AR Manager'
    WHEN 'external escalation' THEN 'Escalated to AR Manager'
    WHEN 'completed' THEN 'Closed'
    WHEN 'required review' THEN 'Rework'
    ELSE Status
END,
WorkFlowStatus = CASE LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,''))))
    WHEN 'pending review' THEN 'Assigned'
    WHEN 'assigned to ar reviewer' THEN 'Assigned'
    WHEN 'internal escalation' THEN 'Escalated to AR Manager'
    WHEN 'external escalation' THEN 'Escalated to AR Manager'
    WHEN 'closed claim' THEN 'Closed'
    ELSE WorkFlowStatus
END,
LastWorkflowUpdatedOn = COALESCE(LastWorkflowUpdatedOn, SYSDATETIME())
WHERE LOWER(LTRIM(RTRIM(ISNULL(Status,'')))) IN ('','open','in progress','in-progress','pending review','pending payer','escalated','internal escalation','external escalation','completed','required review')
   OR LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,'')))) IN ('pending review','assigned to ar reviewer','internal escalation','external escalation','closed claim');

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL AND COL_LENGTH('dbo.DenialLineItem','WorkFlowStatus') IS NOT NULL
BEGIN
    UPDATE dbo.DenialLineItem
    SET WorkFlowStatus = CASE LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,''))))
        WHEN 'pending review' THEN 'Assigned'
        WHEN 'assigned to ar reviewer' THEN 'Assigned'
        WHEN 'internal escalation' THEN 'Escalated to AR Manager'
        WHEN 'external escalation' THEN 'Escalated to AR Manager'
        WHEN 'closed claim' THEN 'Closed'
        ELSE WorkFlowStatus
    END
    WHERE LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,'')))) IN ('pending review','assigned to ar reviewer','internal escalation','external escalation','closed claim');
END;

IF OBJECT_ID('dbo.DenialStatusMaster','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialStatusMaster','StatusName') IS NOT NULL
    BEGIN
        DECLARE @StatusSeed table(StatusName nvarchar(100), SortOrder int);
        INSERT INTO @StatusSeed(StatusName, SortOrder) VALUES
        ('New',10),('Unassigned',20),('Assigned',30),('Payer Follow-up Required',40),
        ('Pending Payer Response',50),('Pending Documentation',60),('Write-Off Pending Approval',70),
        ('Escalated to AR Manager',80),('Rework',90),('Closed',100);

        INSERT INTO dbo.DenialStatusMaster(StatusName, SortOrder)
        SELECT s.StatusName, s.SortOrder
        FROM @StatusSeed s
        WHERE NOT EXISTS (SELECT 1 FROM dbo.DenialStatusMaster m WHERE m.StatusName = s.StatusName);
    END;
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DenialTaskBoard_Status_AssignedTo')
    CREATE INDEX IX_DenialTaskBoard_Status_AssignedTo ON dbo.DenialTaskBoard(Status, AssignedTo) INCLUDE (LabId, ClaimID, TaskID, InsuranceBalance);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DenialTaskBoard') AND name = 'IX_DenialTaskBoard_ExpectedResponseDate')
    CREATE INDEX IX_DenialTaskBoard_ExpectedResponseDate ON dbo.DenialTaskBoard(ExpectedResponseDate) INCLUDE (Status, LabId, ClaimID, TaskID);

SELECT Status, COUNT_BIG(*) AS TaskCount
FROM dbo.DenialTaskBoard
WHERE ISNULL(Status,'') NOT IN
('New','Unassigned','Assigned','Payer Follow-up Required','Pending Payer Response','Pending Documentation','Write-Off Pending Approval','Escalated to AR Manager','Rework','Closed')
GROUP BY Status
ORDER BY TaskCount DESC;

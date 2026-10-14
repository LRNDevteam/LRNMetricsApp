/*
Denial workflow claim-status precedence and role-filter support.

Validation scenarios:
A. Closed, Closed, Closed -> ClaimStatus = Closed, Queue = Closed.
B. All old unassigned/no assigned user -> ClaimStatus = Unassigned, Queue = Unassigned.
C. Assigned, Assigned -> ClaimStatus = Assigned, Queue = Assigned.
D. Assigned + Pending Payer Response + Closed -> ClaimStatus = Pending Payer Response, Queue = Pending Payer Response.
E. Pending Documentation + Pending Payer Response + Assigned + Closed -> ClaimStatus = Pending Documentation, Queue = Pending Documentation.
F. Any Write Off Approval Pending with documentation/payer/closed -> ClaimStatus = Write Off Approval Pending, Queue = Write-Off Approval.
G. Any internal escalation/escalated to AR manager -> ClaimStatus = Escalated to AR Manager, Queue = Internal Escalation.
H. Verify role queue/filter visibility in the React config for AR Reviewer, AR Manager, Account Manager, and Client Manager.
*/

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Claim_Status_Assigned' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Claim_Status_Assigned
    ON dbo.DenialTaskBoard(LabId, ClaimIDNormalized, Status, AssignedTo)
    INCLUDE(TaskID, ClaimID, CreatedOn, ReviewerUpdatedOn, WorkFlowStatus);
END;

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Status_WorkFlowStatus' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Status_WorkFlowStatus
    ON dbo.DenialTaskBoard(LabId, Status, WorkFlowStatus)
    INCLUDE(ClaimIDNormalized, ClaimID, AssignedTo, CreatedOn);
END;

IF OBJECT_ID('dbo.DenialClaimEscalations', 'U') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_Escalations_Lab_Claim_Status_Role' AND object_id = OBJECT_ID('dbo.DenialClaimEscalations'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_Escalations_Lab_Claim_Status_Role
    ON dbo.DenialClaimEscalations(LabId, ClaimId, Status, EscalatedToRole)
    INCLUDE(IsDeleted, EscalatedTo, NextFollowUpDate, EscalationReason, CreatedOn);
END;

IF OBJECT_ID('dbo.DenialClaimNotes', 'U') IS NOT NULL
AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_Notes_Lab_Claim_Followup' AND object_id = OBJECT_ID('dbo.DenialClaimNotes'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_DWF_Notes_Lab_Claim_Followup
    ON dbo.DenialClaimNotes(LabId, ClaimId, NextFollowUpDate)
    INCLUDE(IsDeleted, NoteLevel, Status, CreatedOn);
END;

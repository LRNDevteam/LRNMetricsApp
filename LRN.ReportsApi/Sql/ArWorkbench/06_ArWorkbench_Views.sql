/* ============================================================================================
   AR Workbench - 06 Views
   arwb.vw_ClaimWorklist is the one read shape every queue screen uses: the claim, its queue labels,
   days since last touch, and the live QA / CIP / agent-request state.
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW arwb.vw_ClaimWorklist
AS
SELECT
    c.ClaimKey,
    c.ClaimID,
    c.LabId,
    c.LabName,
    c.AccessionNumber,
    c.PatientID,
    c.PatientName,
    c.PayerName,
    c.PayerType,
    c.ClaimType,
    c.BillingProvider,
    c.ReferringProvider,
    c.ClinicName,
    c.PanelName,
    c.PanelType,
    c.DateOfService,
    c.FirstBilledDate,
    c.CheckDate,
    c.SourceClaimStatus,
    c.DenialCode,
    c.DenialDate,
    c.DenialCategory,
    c.DenialReason,
    c.DenialRootCause,
    c.ChargeAmount,
    c.AllowedAmount,
    c.InsurancePayment,
    c.PatientPayment,
    c.InsuranceAdjustments,
    c.InsuranceBalance,
    c.PatientBalance,
    c.TotalBalance,
    c.InitialInsuranceAR,
    c.RecoveredAmount,
    c.RemainingAR,
    c.AdjustmentAmount,
    c.ExpectedPayment,
    c.PaymentVariance,
    c.UnderpaymentAmount,
    c.IsAppealRequired,
    c.RecoveryStatus,
    c.WorkflowStatus,
    c.WorkflowTemplateKey,
    c.Priority,
    c.AssignedAgentUser,                                -- dbo.LabUsers.UserName in LRNMaster; the API resolves the display name
    c.AssignedOn,
    c.AssignmentBatchId,
    c.LastFollowUpDate,
    c.NextFollowUpDate,
    c.WorkedStatus,
    c.FixResolution,
    c.AgingDays,
    c.AgingBucket,
    c.TflDeadline,
    c.IsTflRisk,
    c.IsNonCollectible,
    c.IsFinanciallyClosed,
    c.IsWorkComplete,
    c.IsOpenInsuranceAR,
    c.IsRefollowupDue,
    c.IsWrittenOff,
    c.ArQueueId,
    q.QueueLabel                                        AS ArQueueLabel,
    q.BadgeClass                                        AS ArQueueBadgeClass,
    c.ArSubQueueId,
    sq.QueueLabel                                       AS ArSubQueueLabel,
    c.IsPriorityQueue,
    c.LastTouchedOn,
    DATEDIFF(day, c.LastTouchedOn, SYSUTCDATETIME())    AS DaysSinceLastTouch,
    c.IsInCurrentSource,
    c.FirstIdentifiedOn,
    c.LastRefreshedOn,
    qa.ReviewStatus                                     AS QaStatus,
    qa.IsEscalation                                     AS QaIsEscalation,
    qa.SubmittedBy                                      AS QaSubmittedBy,
    qa.SubmittedOn                                      AS QaSubmittedOn,
    ISNULL(cip.OpenCipCases, 0)                         AS OpenCipCases,
    ISNULL(req.PendingAgentRequests, 0)                 AS PendingAgentRequests,
    c.RowVer
FROM arwb.Claim c
LEFT JOIN arwb.ArQueue q      ON q.QueueId  = c.ArQueueId
LEFT JOIN arwb.ArQueue sq     ON sq.QueueId = c.ArSubQueueId
LEFT JOIN arwb.ClaimQaReview qa ON qa.ClaimKey = c.ClaimKey AND qa.IsCurrent = 1
OUTER APPLY (SELECT OpenCipCases = COUNT(*) FROM arwb.CipCase x WHERE x.ClaimKey = c.ClaimKey AND x.CaseStatus <> 'Returned to Agent') cip
OUTER APPLY (SELECT PendingAgentRequests = COUNT(*) FROM arwb.AgentRequest x WHERE x.ClaimKey = c.ClaimKey AND x.RequestStatus = 'Pending') req;
GO

PRINT 'AR Workbench 06: views ready.';
GO

/* ============================================================================================
   AR Workbench - 07 Views
     dbo.ARWB_vw_ClaimWorklist     the one read shape every queue screen uses (claim grain)
     dbo.ARWB_vw_ClaimLineDetail   CPT lines with their denial codes, for the per-CPT expand
     dbo.ARWB_vw_DenialInsight     insights with the LIVE unassigned remainder (current + previous week)
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW dbo.ARWB_vw_ClaimWorklist
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
    c.DenialCode,                                       -- curated source value as received
    c.PrimaryDenialCode,                                -- normalized primary denial (drives category and queue)
    c.PrimaryDenialCodeRaw,
    c.HasDenial,
    c.PreviousPrimaryDenialCode,
    c.NewDenialSinceWork,
    c.DenialDate,
    c.DenialCategory,
    c.DenialReason,
    c.DenialRootCause,
    c.LineCount,
    c.DeniedLineCount,
    c.LineDenialCodes,
    c.ChargeAmount,
    c.AllowedAmount,
    c.InsurancePayment,
    c.PatientPayment,
    c.InsuranceAdjustments,
    c.InsuranceBalance,
    c.PatientBalance,
    c.TotalBalance,
    c.InitialInsuranceAR,
    c.RevenueExpectation,
    c.IsRevenueRateMissing,
    c.ActualPayment,
    c.PaymentVariance,
    c.UnderpaymentAmount,
    c.IsAppealRequired,
    c.PotentialRecovery,
    c.RecoveryStatus,
    c.RecoveredAmount,
    c.RemainingAR,
    c.AdjustmentAmount,
    c.IsAutoAdjustEligible,
    c.IsAutoAdjusted,
    c.AutoAdjustedOn,
    c.AutoAdjustReasonCode,
    c.AutoAdjustAmount,
    c.IsWriteOffApproved,
    c.WriteOffApprovedOn,
    c.IsPmsPostedConfirmed,
    c.IsAdjustmentNotPosted,
    c.WorkflowStatus,
    c.WorkflowTemplateKey,
    c.Priority,
    c.AssignedAgentUser,                                -- dbo.LabUsers.UserName in LRNMaster; the API resolves the display name
    c.AssignedOn,
    c.AssignmentBatchId,
    c.AssignmentDueDate,
    c.LastFollowUpDate,
    c.NextFollowUpDate,
    c.WorkedStatus,
    c.FixResolution,
    c.AdHocFollowUpAssigned,
    c.AgingDays,
    c.AgingBucket,
    c.TflDeadline,
    c.IsTflRisk,
    c.IsNonCollectible,
    c.HasNonCollectibleDenial,
    c.IsFinanciallyClosed,
    c.IsWorkComplete,
    c.IsOpenInsuranceAR,
    c.IsRefollowupDue,
    c.IsFollowUpActionable,
    c.ArQueueId,
    q.QueueLabel                                        AS ArQueueLabel,
    q.BadgeClass                                        AS ArQueueBadgeClass,
    q.QueueGroup                                        AS ArQueueGroup,
    c.ArSubQueueId,
    sq.QueueLabel                                       AS ArSubQueueLabel,
    c.IsPriorityQueue,
    c.IsRestrictedQueue,
    c.LastTouchedOn,
    DATEDIFF(day, c.LastTouchedOn, SYSUTCDATETIME())    AS DaysSinceLastTouch,
    c.IsInCurrentSource,
    c.FirstIdentifiedOn,
    c.LastRefreshedOn,
    qa.ReviewStatus                                     AS QaStatus,
    qa.IsEscalation                                     AS QaIsEscalation,
    qa.IsWriteOff                                       AS QaIsWriteOff,
    qa.SubmittedBy                                      AS QaSubmittedBy,
    qa.SubmittedOn                                      AS QaSubmittedOn,
    ISNULL(cip.OpenCipCases, 0)                         AS OpenCipCases,
    ISNULL(req.PendingAgentRequests, 0)                 AS PendingAgentRequests,
    ISNULL(doc.DocumentCount, 0)                        AS DocumentCount,
    c.RowVer
FROM dbo.ARWB_Claim c
LEFT JOIN dbo.ARWB_ArQueue q        ON q.QueueId  = c.ArQueueId
LEFT JOIN dbo.ARWB_ArQueue sq       ON sq.QueueId = c.ArSubQueueId
LEFT JOIN dbo.ARWB_ClaimQaReview qa ON qa.ClaimKey = c.ClaimKey AND qa.IsCurrent = 1
OUTER APPLY (SELECT OpenCipCases = COUNT(*) FROM dbo.ARWB_CipCase x
             WHERE x.ClaimKey = c.ClaimKey AND x.CaseStatus IN ('Awaiting QA', 'Pending Approval', 'Sent to Client', 'Client Responded')) cip
OUTER APPLY (SELECT PendingAgentRequests = COUNT(*) FROM dbo.ARWB_AgentRequest x WHERE x.ClaimKey = c.ClaimKey AND x.RequestStatus = 'Pending') req
OUTER APPLY (SELECT DocumentCount = COUNT(*) FROM dbo.ARWB_Document x WHERE x.ClaimKey = c.ClaimKey AND x.IsDeleted = 0) doc;
GO

-- One row per line denial code (lines with no denial appear once with NULL code columns).
CREATE OR ALTER VIEW dbo.ARWB_vw_ClaimLineDetail
AS
SELECT
    cl.ClaimLineKey,
    cl.ClaimKey,
    cl.ClaimID,
    cl.LineNumber,
    cl.CPTCode,
    cl.CPTDescription,
    cl.ICDCode                  AS Diagnosis,
    cl.Units,
    cl.Modifier,
    cl.ChargeAmount,
    cl.AllowedAmount,
    cl.InsurancePayment,
    cl.PatientPayment,
    cl.InsuranceAdjustments,
    cl.InsuranceBalance,
    cl.PatientBalance,
    cl.LineClaimStatus,
    cl.PayStatus,
    cl.HasDenial,
    cl.DenialCode               AS LineDenialCodesRaw,
    cl.DenialDate,
    cl.CheckDate,
    cl.ExpectedRate,
    cl.RevenueExpectation,
    ld.Ordinal                  AS DenialOrdinal,
    ld.DenialCodeRaw,           -- display value, group prefix kept (e.g. 'CO-16')
    ld.GroupCode,
    ld.DenialCode,              -- normalized, used for every mapping
    ld.CodeType,
    ld.DenialCategory,
    ld.DenialReason,
    ld.IsNonCollectible
FROM dbo.ARWB_ClaimLine cl
LEFT JOIN dbo.ARWB_ClaimLineDenial ld ON ld.ClaimLineKey = cl.ClaimLineKey;
GO

-- The latest InsightWeeksShown sync weeks. Outstanding* is the live remainder: claims still
-- unassigned with open insurance AR. Rows with nothing outstanding are resolved and hidden.
CREATE OR ALTER VIEW dbo.ARWB_vw_DenialInsight
AS
SELECT
    i.DenialInsightId,
    i.WeekStart,
    CASE WHEN i.WeekStart = w.LatestWeek THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END AS IsCurrentWeek,
    i.DenialCode,
    i.DenialDescription,
    i.DenialCategory,
    i.CategoryTag,
    i.RecommendedAction,
    i.ClaimCount                AS ClaimCountAtBuild,
    i.TotalBalance              AS TotalBalanceAtBuild,
    live.OutstandingClaims,
    live.OutstandingBalance,
    i.TopPayer,
    i.TopPayerBalance,
    i.ImpactPct,
    i.TopServiceLine,
    i.Observation
FROM dbo.ARWB_DenialInsight i
CROSS JOIN (SELECT LatestWeek = MAX(WeekStart) FROM dbo.ARWB_DenialInsight) w
CROSS APPLY
(
    SELECT OutstandingClaims  = COUNT(*),
           OutstandingBalance = ISNULL(SUM(c.RemainingAR), 0)
    FROM dbo.ARWB_DenialInsightClaim ic
    INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = ic.ClaimKey
    WHERE ic.DenialInsightId = i.DenialInsightId
      AND c.WorkflowStatus = 'Unassigned'
      AND c.AssignedAgentUser IS NULL
      AND c.IsOpenInsuranceAR = 1
      AND c.PrimaryDenialCode = i.DenialCode
) live
WHERE i.WeekStart > DATEADD(week, -COALESCE(TRY_CONVERT(int, (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('InsightWeeksShown', N'2'))), 2), w.LatestWeek)
  AND live.OutstandingClaims > 0;
GO

PRINT 'AR Workbench 07: views ready.';
GO

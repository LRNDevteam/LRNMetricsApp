/* ============================================================================================
   AR Workbench - 04 arwb.usp_RecalculateClaimState

   THE one server-side implementation of the derived claim rules. Screens read the columns this
   procedure writes; they never re-derive a rule in the UI. Call it:
     - after every source refresh            (usp_LoadClaimsFromSource calls it for all claims)
     - after every claim mutation in the API (EXEC arwb.usp_RecalculateClaimState @ClaimKey = @k)
     - nightly, so aging / TFL / re-follow-up due roll forward with the calendar

   Rules (from AR_Workbench_Developer_Documentation.pdf, Business Logic Reference):
     RemainingAR          = InsuranceBalance, or 0 once written off (Automatic Adjustment)
     RecoveredAmount      = InsurancePayment now - InsurancePayment at first identification  (>= 0)
     IsFinanciallyClosed  = RemainingAR <= eps AND PatientBalance <= eps
     IsWorkComplete       = IsFinanciallyClosed OR WorkflowStatus = 'Completed'
     IsOpenInsuranceAR    = RemainingAR > eps          (NOT the opposite of IsWorkComplete - by design)
     IsRefollowupDue      = worked before AND (45+ days since LastFollowUpDate OR NextFollowUpDate lapsed)
     IsNonCollectible     = any of the claim's denial codes is on the NON_COLLECTIBLE_CODE list

   Queue classification - priority ordered, first match wins:
     1 current QA review is 'Awaiting QA'                      -> submittedqa
     2 WorkflowStatus = 'QA Rejected'                          -> qarejected
     3 WorkflowStatus = 'Completed'
         RemainingAR <= eps                                    -> financial state
         open CIP case (status <> Returned to Agent)           -> escalation
         re-follow-up due                                      -> refollowup
         otherwise                                             -> completed
     4 a CIP case came back to the agent WITH a client reply   -> cipresponse
     5 otherwise                                               -> financial state
   Financial state:
     RemainingAR <= eps : PatientBalance > eps -> patientar ; recovered > eps -> closed/closed_paid ; else closed/closed_adjusted
     recovered <= eps AND adjusted <= eps AND category 'Unresponsive Payers' -> nonresponded/nonresponded_collectible
     recovered <= eps AND adjusted > eps  -> partialadj/partialadj_collectible
     recovered > eps                      -> partial/partial_(non)collectible
     otherwise                            -> denied/denied_(non)collectible
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE arwb.usp_RecalculateClaimState
    @ClaimKey       bigint = NULL,      -- one claim (API mutations)
    @RefreshRunId   int    = NULL,      -- only claims touched by this refresh
    @AsOfDate       date   = NULL       -- defaults to today; pass a date to reproduce a past classification
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AsOf date = COALESCE(@AsOfDate, CONVERT(date, SYSDATETIME()));

    DECLARE @Eps            decimal(9,4)  = COALESCE(TRY_CONVERT(decimal(9,4),  (SELECT SettingValue FROM arwb.tvf_Setting('BalanceEpsilon',       N'0.005'))), 0.005);
    DECLARE @RefollowDays   int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM arwb.tvf_Setting('RefollowupDays',       N'45'))),    45);
    DECLARE @TflDefaultDays int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM arwb.tvf_Setting('TflDefaultDays',       N'180'))),   180);
    DECLARE @TflRiskDays    int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM arwb.tvf_Setting('TflRiskWindowDays',    N'30'))),    30);
    DECLARE @HighAmount     decimal(18,2) = COALESCE(TRY_CONVERT(decimal(18,2), (SELECT SettingValue FROM arwb.tvf_Setting('PriorityHighAmount',   N'500'))),   500);
    DECLARE @MediumAmount   decimal(18,2) = COALESCE(TRY_CONVERT(decimal(18,2), (SELECT SettingValue FROM arwb.tvf_Setting('PriorityMediumAmount', N'100'))),   100);

    UPDATE c
    SET
        -- Recovery / AR
        c.RemainingAR         = f.RemainingAR,
        c.RecoveredAmount     = f.RecoveredAmount,
        c.AdjustmentAmount    = f.AdjustmentAmount,
        c.ExpectedPayment     = p.ExpectedPayment,
        c.ActualPayment       = c.InsurancePayment,
        c.PaymentVariance     = p.PaymentVariance,
        c.PaymentPct          = p.PaymentPct,
        c.UnderpaymentAmount  = p.UnderpaymentAmount,
        c.IsAppealRequired    = CASE WHEN p.UnderpaymentAmount > @Eps
                                       OR (q.SubQueueId = 'denied_collectible' AND c.WorkflowStatus <> 'Completed') THEN 1 ELSE 0 END,
        c.RecoveryStatus      = CASE
                                    WHEN c.InitialInsuranceAR <= @Eps              THEN 'Not Applicable'
                                    WHEN f.RecoveredAmount    <= @Eps              THEN 'Not Recovered'
                                    WHEN f.RemainingAR        <= @Eps              THEN 'Fully Recovered'
                                    ELSE 'Partially Recovered'
                                END,
        -- Lifecycle flags
        c.IsFinanciallyClosed = s.IsFinanciallyClosed,
        c.IsWorkComplete      = CASE WHEN s.IsFinanciallyClosed = 1 OR c.WorkflowStatus = 'Completed' THEN 1 ELSE 0 END,
        c.IsOpenInsuranceAR   = CASE WHEN f.RemainingAR > @Eps THEN 1 ELSE 0 END,
        c.IsRefollowupDue     = s.IsRefollowupDue,
        c.IsNonCollectible    = s.IsNonCollectible,
        -- Aging / TFL / priority
        c.AgingDays           = a.AgingDays,
        c.AgingBucket         = a.AgingBucket,
        c.TflDeadline         = t.TflDeadline,
        c.IsTflRisk           = t.IsTflRisk,
        c.Priority            = COALESCE(c.PriorityOverride,
                                    CASE WHEN t.IsTflRisk = 1 OR f.RemainingAR >= @HighAmount THEN 'High'
                                         WHEN f.RemainingAR >= @MediumAmount                 THEN 'Medium'
                                         ELSE 'Low' END),
        -- Queue
        c.ArQueueId           = q.QueueId,
        c.ArSubQueueId        = q.SubQueueId,
        c.IsPriorityQueue     = COALESCE(aq.IsPriority, 0),
        c.LastTouchedOn       = COALESCE(lt.LastTouchedOn, c.LastTouchedOn),
        c.ClassifiedOn        = SYSUTCDATETIME()
    FROM arwb.Claim c
    -- Financial figures
    CROSS APPLY
    (
        SELECT
            RemainingAR      = CASE WHEN c.IsWrittenOff = 1 OR c.InsuranceBalance <= 0 THEN CONVERT(decimal(18,2), 0) ELSE c.InsuranceBalance END,
            RecoveredAmount  = CASE WHEN c.InsurancePayment - c.InitialInsurancePayment > 0
                                    THEN c.InsurancePayment - c.InitialInsurancePayment ELSE CONVERT(decimal(18,2), 0) END,
            -- A write-off not yet posted by the billing system is counted here; once the source
            -- posts it the balance drops to zero and the source adjustment carries it instead.
            AdjustmentAmount = c.InsuranceAdjustments
                               + CASE WHEN c.IsWrittenOff = 1 AND c.InsuranceBalance > 0 THEN c.InsuranceBalance ELSE 0 END
    ) f
    -- Expected vs actual payment
    CROSS APPLY
    (
        SELECT
            ExpectedPayment    = NULLIF(c.AllowedAmount, 0),
            PaymentVariance    = CASE WHEN c.AllowedAmount > 0 THEN c.AllowedAmount - c.InsurancePayment END,
            PaymentPct         = CASE WHEN c.AllowedAmount > 0 THEN CONVERT(decimal(9,4), c.InsurancePayment / c.AllowedAmount) END,
            UnderpaymentAmount = CASE WHEN c.AllowedAmount > 0 AND c.InsurancePayment > @Eps AND c.AllowedAmount - c.InsurancePayment > @Eps
                                      THEN c.AllowedAmount - c.InsurancePayment ELSE CONVERT(decimal(18,2), 0) END
    ) p
    -- State flags read from the workflow tables
    CROSS APPLY
    (
        SELECT
            IsFinanciallyClosed = CASE WHEN f.RemainingAR <= @Eps AND c.PatientBalance <= @Eps THEN 1 ELSE 0 END,
            IsRefollowupDue     = CASE WHEN c.LastFollowUpDate IS NOT NULL
                                        AND (DATEDIFF(day, c.LastFollowUpDate, @AsOf) >= @RefollowDays
                                             OR (c.NextFollowUpDate IS NOT NULL AND c.NextFollowUpDate <= @AsOf))
                                       THEN 1 ELSE 0 END,
            IsNonCollectible    = CASE WHEN EXISTS (SELECT 1 FROM arwb.MasterListItem m
                                                    WHERE m.ListType = 'NON_COLLECTIBLE_CODE' AND m.IsActive = 1
                                                      AND c.DenialCodesNormalized LIKE N'%,' + m.ItemValue + N',%')
                                       THEN 1 ELSE 0 END,
            IsAwaitingQa        = CASE WHEN EXISTS (SELECT 1 FROM arwb.ClaimQaReview r
                                                    WHERE r.ClaimKey = c.ClaimKey AND r.IsCurrent = 1 AND r.ReviewStatus = 'Awaiting QA')
                                       THEN 1 ELSE 0 END,
            HasActiveCip        = CASE WHEN EXISTS (SELECT 1 FROM arwb.CipCase cc
                                                    WHERE cc.ClaimKey = c.ClaimKey AND cc.CaseStatus <> 'Returned to Agent')
                                       THEN 1 ELSE 0 END,
            HasReturnedCipReply = CASE WHEN EXISTS (SELECT 1 FROM arwb.CipCase cc
                                                    WHERE cc.ClaimKey = c.ClaimKey AND cc.CaseStatus = 'Returned to Agent'
                                                      AND cc.ClientRespondedOn IS NOT NULL)
                                       THEN 1 ELSE 0 END
    ) s
    -- Financial-state fallback bucket
    CROSS APPLY
    (
        SELECT
            FinQueue = CASE
                WHEN f.RemainingAR <= @Eps THEN CASE WHEN c.PatientBalance > @Eps THEN 'patientar' ELSE 'closed' END
                WHEN f.RecoveredAmount <= @Eps AND f.AdjustmentAmount <= @Eps AND c.DenialCategory = N'Unresponsive Payers' THEN 'nonresponded'
                WHEN f.RecoveredAmount <= @Eps AND f.AdjustmentAmount >  @Eps THEN 'partialadj'
                WHEN f.RecoveredAmount >  @Eps THEN 'partial'
                ELSE 'denied' END,
            FinSubQueue = CASE
                WHEN f.RemainingAR <= @Eps THEN CASE WHEN c.PatientBalance > @Eps THEN NULL
                                                     WHEN f.RecoveredAmount > @Eps THEN 'closed_paid'
                                                     ELSE 'closed_adjusted' END
                WHEN f.RecoveredAmount <= @Eps AND f.AdjustmentAmount <= @Eps AND c.DenialCategory = N'Unresponsive Payers' THEN 'nonresponded_collectible'
                WHEN f.RecoveredAmount <= @Eps AND f.AdjustmentAmount >  @Eps THEN 'partialadj_collectible'
                WHEN f.RecoveredAmount >  @Eps THEN CASE WHEN s.IsNonCollectible = 1 THEN 'partial_noncollectible' ELSE 'partial_collectible' END
                ELSE CASE WHEN s.IsNonCollectible = 1 THEN 'denied_noncollectible' ELSE 'denied_collectible' END END
    ) fin
    -- Priority-ordered classification
    CROSS APPLY
    (
        SELECT
            QueueId = CASE
                WHEN s.IsAwaitingQa = 1                 THEN 'submittedqa'
                WHEN c.WorkflowStatus = 'QA Rejected'   THEN 'qarejected'
                WHEN c.WorkflowStatus = 'Completed' THEN
                    CASE WHEN f.RemainingAR <= @Eps     THEN fin.FinQueue
                         WHEN s.HasActiveCip = 1        THEN 'escalation'
                         WHEN s.IsRefollowupDue = 1     THEN 'refollowup'
                         ELSE 'completed' END
                WHEN s.HasReturnedCipReply = 1          THEN 'cipresponse'
                ELSE fin.FinQueue END,
            SubQueueId = CASE
                WHEN s.IsAwaitingQa = 1                 THEN NULL
                WHEN c.WorkflowStatus = 'QA Rejected'   THEN NULL
                WHEN c.WorkflowStatus = 'Completed' THEN
                    CASE WHEN f.RemainingAR <= @Eps     THEN fin.FinSubQueue ELSE NULL END
                WHEN s.HasReturnedCipReply = 1          THEN NULL
                ELSE fin.FinSubQueue END
    ) q
    LEFT JOIN arwb.ArQueue aq ON aq.QueueId = COALESCE(q.SubQueueId, q.QueueId)
    -- Aging from date of service
    CROSS APPLY
    (
        SELECT AgingDays = DATEDIFF(day, c.DateOfService, @AsOf)
    ) a0
    CROSS APPLY
    (
        SELECT
            AgingDays   = a0.AgingDays,
            AgingBucket = CASE
                WHEN a0.AgingDays IS NULL THEN NULL
                WHEN a0.AgingDays <= 30   THEN N'0-30 Days'
                WHEN a0.AgingDays <= 60   THEN N'31-60 Days'
                WHEN a0.AgingDays <= 90   THEN N'61-90 Days'
                WHEN a0.AgingDays <= 120  THEN N'91-120 Days'
                WHEN a0.AgingDays <= 180  THEN N'121-180 Days'
                ELSE N'181+ Days' END
    ) a
    -- Timely filing
    OUTER APPLY
    (
        SELECT TOP (1) th.ThresholdDays FROM arwb.TflThreshold th WHERE th.FinancialClass = c.PayerType
    ) tf
    CROSS APPLY
    (
        SELECT
            TflDeadline = DATEADD(day, COALESCE(tf.ThresholdDays, @TflDefaultDays), c.DateOfService),
            IsTflRisk   = CASE WHEN c.DateOfService IS NOT NULL
                                AND f.RemainingAR > @Eps
                                AND DATEDIFF(day, @AsOf, DATEADD(day, COALESCE(tf.ThresholdDays, @TflDefaultDays), c.DateOfService)) <= @TflRiskDays
                               THEN 1 ELSE 0 END
    ) t
    -- Days since last touch reads the activity log (every claim has the "Claim Identified" entry)
    OUTER APPLY
    (
        SELECT LastTouchedOn = MAX(ca.ActivityOn) FROM arwb.ClaimActivity ca WHERE ca.ClaimKey = c.ClaimKey
    ) lt
    WHERE (@ClaimKey     IS NULL OR c.ClaimKey         = @ClaimKey)
      AND (@RefreshRunId IS NULL OR c.LastRefreshRunId = @RefreshRunId)
    OPTION (RECOMPILE);

    SELECT UpdatedClaims = @@ROWCOUNT;
END;
GO

PRINT 'AR Workbench 04: arwb.usp_RecalculateClaimState ready.';
GO

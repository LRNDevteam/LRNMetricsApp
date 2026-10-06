/* ============================================================================================
   AR Workbench - 04 Claim state
     dbo.ARWB_usp_PriceClaimLines        Revenue Expectation per CPT line (fee-schedule rate x units)
     dbo.ARWB_usp_RecalculateClaimState  THE one implementation of the derived claim rules and the
                                         AR queue classification (handoff section 18)

   Screens, badges, reports and exports read the columns these procedures write; they never
   re-derive a rule. Call RecalculateClaimState:
     - after every sync                         (ARWB_usp_LoadClaimsFromSource calls it)
     - after every claim mutation in the API    (EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKey = @k)
     - nightly, so aging / TFL / re-follow-up due move forward with the calendar
   Call PriceClaimLines with no arguments after the fee schedule changes, then RecalculateClaimState.

   Lifecycle predicates (18.1)
     RemainingAR          InsuranceBalance; 0 once auto-adjusted or write-off approved (nullified in the workbench)
     IsFinanciallyClosed  RemainingAR <= eps AND PatientBalance <= eps
     IsWorkComplete       IsFinanciallyClosed OR WorkflowStatus = 'Completed'
     IsOpenInsuranceAR    RemainingAR > eps   (drives every agent-facing inventory view)
     IsRefollowupDue      worked at least once AND (45+ days since LastFollowUpDate OR NextFollowUpDate reached)
     IsFollowUpActionable (IsOpenInsuranceAR OR AdHocFollowUpAssigned) AND WorkflowStatus IN (Assigned, QA Rejected)
     IsNonCollectible     the PRIMARY denial code is on the NON_COLLECTIBLE_CODE list (not "any code")
     HasNonCollectibleDenial  ANY denial code on the claim (primary or line level) is on that list - a flag
                          only; queues still follow IsNonCollectible

   Financial fields (section 7)
     RevenueExpectation   sum of line RevenueExpectation (Medicare-rate allowable); 0 when no rate
     PotentialRecovery    RevenueExpectation - (InsurancePayment + PatientPayment + PatientBalance), floor 0
     RecoveryStatus       No Recovery          financially closed with no insurance or patient payment (interim definition - open item)
                          In Progress          insurance payment, patient payment and patient balance all 0
                          Fully Recovered      their total >= RevenueExpectation
                          Partially Recovered  otherwise
     RecoveredAmount      insurance payments on lines whose payment date is after the denial date
                          (claims with no denial: after the claim entered the workbench). Payments only.

   Queue precedence (18.3) - first match wins
     1  current QA review is Awaiting QA                                -> submittedqa
     2  WorkflowStatus = QA Rejected                                    -> qarejected
     3  nullified (auto-adjust / approved write-off), not yet posted,
        master still shows an insurance balance                         -> autoadj / autoadj_system | autoadj_writeoff
     4  Completed AND RemainingAR <= eps                                -> financial state
     5  Completed AND open CIP case                                     -> escalation
     6  Completed AND new denial received on sync                       -> refollowup / refollowup_newdenials
     7  Completed AND re-follow-up due                                  -> refollowup / refollowup_unresolved
     7a Completed                                                       -> completed
     7b CIP returned to agent with a client reply, claim Assigned       -> cipresponse
     8  financial state
        RemainingAR <= eps, PatientBalance > eps                        -> patientar (denials ignored)
        RemainingAR <= eps, payments received                           -> closed / closed_paid
        RemainingAR <= eps, no payment                                  -> closed / closed_adjusted
        insurance payment > 0                                           -> partial / partial_(non)collectible
        no payment, denial present                                      -> denied / denied_(non)collectible
        no payment, no denial, adjustment > 0                           -> partialadj / partialadj_collectible
        no payment, no denial, no adjustment                            -> nonresponded / nonresponded_collectible
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.ARWB_usp_PriceClaimLines
    @ClaimKey       bigint = NULL,      -- one claim
    @RefreshRunId   int    = NULL       -- only lines loaded by this sync; both NULL = every line
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now datetime2(0) = SYSUTCDATETIME();
    DECLARE @Today date = CONVERT(date, SYSDATETIME());

    UPDATE l
    SET l.ExpectedRate       = fs.Rate,
        l.RevenueExpectation = CASE WHEN fs.Rate IS NULL THEN CONVERT(decimal(18,2), 0)
                                    ELSE CONVERT(decimal(18,2), fs.Rate * COALESCE(NULLIF(l.Units, 0), 1)) END,
        l.PricedOn           = @Now
    FROM dbo.ARWB_ClaimLine l
    INNER JOIN dbo.ARWB_Claim c ON c.ClaimKey = l.ClaimKey
    OUTER APPLY
    (
        -- An exact modifier match beats a rate for any modifier; the latest effective rate wins.
        SELECT TOP (1) f.Rate
        FROM dbo.ARWB_CptFeeSchedule f
        WHERE f.CPTCode = l.CPTCode
          AND (f.Modifier IS NULL OR f.Modifier = l.Modifier)
          AND f.EffectiveFrom <= COALESCE(c.DateOfService, @Today)
          AND (f.EffectiveTo IS NULL OR f.EffectiveTo >= COALESCE(c.DateOfService, @Today))
        ORDER BY CASE WHEN f.Modifier IS NULL THEN 1 ELSE 0 END, f.EffectiveFrom DESC
    ) fs
    WHERE (@ClaimKey     IS NULL OR l.ClaimKey     = @ClaimKey)
      AND (@RefreshRunId IS NULL OR l.RefreshRunId = @RefreshRunId);

    SELECT PricedLines = @@ROWCOUNT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.ARWB_usp_RecalculateClaimState
    @ClaimKey       bigint = NULL,      -- one claim (API mutations)
    @RefreshRunId   int    = NULL,      -- only claims touched by this sync
    @AsOfDate       date   = NULL,      -- defaults to today; pass a date to reproduce a past classification
    @ClaimKeyList   nvarchar(max) = NULL -- comma-separated ClaimKeys (bulk actions)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AsOf date = COALESCE(@AsOfDate, CONVERT(date, SYSDATETIME()));

    DECLARE @Keys TABLE (ClaimKey bigint NOT NULL PRIMARY KEY);
    IF @ClaimKeyList IS NOT NULL
        INSERT INTO @Keys (ClaimKey) SELECT k.ClaimKey FROM dbo.ARWB_tvf_ParseKeyList(@ClaimKeyList) k;
    DECLARE @HasKeys bit = CASE WHEN @ClaimKeyList IS NULL THEN 0 ELSE 1 END;

    DECLARE @Eps            decimal(9,4)  = COALESCE(TRY_CONVERT(decimal(9,4),  (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('BalanceEpsilon',       N'0.005'))), 0.005);
    DECLARE @RefollowDays   int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('RefollowupDays',       N'45'))),    45);
    DECLARE @TflDefaultDays int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('TflDefaultDays',       N'180'))),   180);
    DECLARE @TflRiskDays    int           = COALESCE(TRY_CONVERT(int,           (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('TflRiskWindowDays',    N'30'))),    30);
    DECLARE @HighAmount     decimal(18,2) = COALESCE(TRY_CONVERT(decimal(18,2), (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('PriorityHighAmount',   N'500'))),   500);
    DECLARE @MediumAmount   decimal(18,2) = COALESCE(TRY_CONVERT(decimal(18,2), (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('PriorityMediumAmount', N'100'))),   100);
    DECLARE @AgingOnDenial  bit           = CASE WHEN (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('AgingBasis', N'DateOfService')) = N'DenialDate' THEN 1 ELSE 0 END;
    DECLARE @AutoAdjNc      bit           = CASE WHEN (SELECT SettingValue FROM dbo.ARWB_tvf_Setting('AutoAdjustIncludesNonCollectible', N'0')) = N'1' THEN 1 ELSE 0 END;

    UPDATE c
    SET
        -- Recovery / AR
        c.RemainingAR          = f.RemainingAR,
        c.RecoveredAmount      = f.RecoveredAmount,
        c.AdjustmentAmount     = f.AdjustmentAmount,
        c.RevenueExpectation   = f.RevenueExpectation,
        c.IsRevenueRateMissing = f.IsRevenueRateMissing,
        c.ActualPayment        = c.InsurancePayment,
        c.PaymentVariance      = p.PaymentVariance,
        c.PaymentPct           = p.PaymentPct,
        c.UnderpaymentAmount   = p.UnderpaymentAmount,
        c.PotentialRecovery    = p.PotentialRecovery,
        c.IsAppealRequired     = CASE WHEN p.UnderpaymentAmount > @Eps
                                        OR (q.SubQueueId = 'denied_collectible' AND c.WorkflowStatus <> 'Completed') THEN 1 ELSE 0 END,
        c.RecoveryStatus       = CASE
                                     WHEN s.IsFinanciallyClosed = 1 AND c.InsurancePayment + c.PatientPayment <= @Eps THEN 'No Recovery'
                                     WHEN f.Collected <= @Eps                     THEN 'In Progress'
                                     WHEN f.Collected >= f.RevenueExpectation     THEN 'Fully Recovered'
                                     ELSE 'Partially Recovered'
                                 END,
        -- Lifecycle flags
        c.IsFinanciallyClosed  = s.IsFinanciallyClosed,
        c.IsWorkComplete       = CASE WHEN s.IsFinanciallyClosed = 1 OR c.WorkflowStatus = 'Completed' THEN 1 ELSE 0 END,
        c.IsOpenInsuranceAR    = CASE WHEN f.RemainingAR > @Eps THEN 1 ELSE 0 END,
        c.IsRefollowupDue      = s.IsRefollowupDue,
        c.IsFollowUpActionable = CASE WHEN (f.RemainingAR > @Eps OR c.AdHocFollowUpAssigned = 1)
                                       AND c.WorkflowStatus IN ('Assigned', 'QA Rejected') THEN 1 ELSE 0 END,
        c.IsNonCollectible     = s.IsNonCollectible,
        c.HasNonCollectibleDenial = s.HasNonCollectibleDenial,
        c.IsAutoAdjustEligible = CASE WHEN f.RemainingAR > @Eps AND f.IsNullified = 0
                                       AND c.WorkflowStatus <> 'Submitted for QA'
                                       AND (s.IsAutoAdjustCode = 1 OR (@AutoAdjNc = 1 AND s.IsNonCollectible = 1)) THEN 1 ELSE 0 END,
        -- Aging / TFL / priority
        c.AgingDays            = a.AgingDays,
        c.AgingBucket          = a.AgingBucket,
        c.TflDeadline          = t.TflDeadline,
        c.IsTflRisk            = t.IsTflRisk,
        c.Priority             = COALESCE(c.PriorityOverride,
                                     CASE WHEN t.IsTflRisk = 1 OR f.RemainingAR >= @HighAmount THEN 'High'
                                          WHEN f.RemainingAR >= @MediumAmount                 THEN 'Medium'
                                          ELSE 'Low' END),
        -- Queue
        c.ArQueueId            = q.QueueId,
        c.ArSubQueueId         = q.SubQueueId,
        c.IsPriorityQueue      = COALESCE(aq.IsPriority, 0),
        c.IsRestrictedQueue    = COALESCE(aq.IsRestricted, 0),
        c.LastTouchedOn        = COALESCE(lt.LastTouchedOn, c.LastTouchedOn),
        c.ClassifiedOn         = SYSUTCDATETIME()
    FROM dbo.ARWB_Claim c
    -- Recovery baseline: the denial date, else the day the claim entered the workbench
    CROSS APPLY (SELECT Baseline = COALESCE(c.DenialDate, CONVERT(date, c.FirstIdentifiedOn))) b
    -- Line rollups: revenue expectation and payments after the baseline
    OUTER APPLY
    (
        SELECT LineCount       = COUNT(*),
               LineRevenue     = SUM(x.RevenueExpectation),
               UnpricedLines   = SUM(x.IsUnpriced),
               PaidAfterDenial = SUM(x.PaidAfterBaseline)
        FROM
        (
            SELECT l.RevenueExpectation,
                   IsUnpriced        = CASE WHEN l.ExpectedRate IS NULL THEN 1 ELSE 0 END,
                   PaidAfterBaseline = CASE WHEN COALESCE(l.CheckDate, l.PostingDate) > b.Baseline THEN l.InsurancePayment ELSE 0 END
            FROM dbo.ARWB_ClaimLine l
            WHERE l.ClaimKey = c.ClaimKey
        ) x
    ) la
    -- Financial figures
    CROSS APPLY
    (
        SELECT
            IsNullified          = CASE WHEN c.IsAutoAdjusted = 1 OR c.IsWriteOffApproved = 1 THEN 1 ELSE 0 END,
            RemainingAR          = CASE WHEN c.IsAutoAdjusted = 1 OR c.IsWriteOffApproved = 1 OR c.InsuranceBalance <= 0
                                        THEN CONVERT(decimal(18,2), 0) ELSE c.InsuranceBalance END,
            -- Lines are the payment-date source. A claim with no lines falls back to the payment
            -- increase since the claim entered the workbench.
            RecoveredAmount      = CASE WHEN ISNULL(la.LineCount, 0) > 0
                                        THEN CASE WHEN la.PaidAfterDenial > 0 THEN la.PaidAfterDenial ELSE CONVERT(decimal(18,2), 0) END
                                        ELSE CASE WHEN c.InsurancePayment - c.InitialInsurancePayment > 0
                                                  THEN c.InsurancePayment - c.InitialInsurancePayment ELSE CONVERT(decimal(18,2), 0) END END,
            -- A nullified balance not yet posted by the PMS is counted here; once the master posts it
            -- the balance drops to zero and the source adjustment carries it instead.
            AdjustmentAmount     = c.InsuranceAdjustments
                                   + CASE WHEN (c.IsAutoAdjusted = 1 OR c.IsWriteOffApproved = 1) AND c.InsuranceBalance > 0 THEN c.InsuranceBalance ELSE 0 END,
            RevenueExpectation   = CONVERT(decimal(18,2), ISNULL(la.LineRevenue, 0)),
            IsRevenueRateMissing = CASE WHEN ISNULL(la.LineCount, 0) = 0 OR la.UnpricedLines > 0 THEN 1 ELSE 0 END,
            Collected            = c.InsurancePayment + c.PatientPayment + c.PatientBalance
    ) f
    -- Revenue expectation vs actual
    CROSS APPLY
    (
        SELECT
            PotentialRecovery  = CASE WHEN f.RevenueExpectation - f.Collected > 0 THEN f.RevenueExpectation - f.Collected ELSE CONVERT(decimal(18,2), 0) END,
            PaymentVariance    = CASE WHEN f.RevenueExpectation > 0 THEN f.RevenueExpectation - c.InsurancePayment END,
            PaymentPct         = CASE WHEN f.RevenueExpectation > 0 AND c.InsurancePayment / f.RevenueExpectation < 10000
                                      THEN CONVERT(decimal(9,4), c.InsurancePayment / f.RevenueExpectation) END,
            -- Underpayment stays contract based: allowed minus paid, once the payer has paid something.
            UnderpaymentAmount = CASE WHEN c.AllowedAmount > 0 AND c.InsurancePayment > @Eps AND c.AllowedAmount - c.InsurancePayment > @Eps
                                      THEN c.AllowedAmount - c.InsurancePayment ELSE CONVERT(decimal(18,2), 0) END
    ) p
    -- State flags read from the workflow tables and master lists
    CROSS APPLY
    (
        SELECT
            IsFinanciallyClosed = CASE WHEN f.RemainingAR <= @Eps AND c.PatientBalance <= @Eps THEN 1 ELSE 0 END,
            IsRefollowupDue     = CASE WHEN c.LastFollowUpDate IS NOT NULL
                                        AND (DATEDIFF(day, c.LastFollowUpDate, @AsOf) >= @RefollowDays
                                             OR (c.NextFollowUpDate IS NOT NULL AND c.NextFollowUpDate <= @AsOf))
                                       THEN 1 ELSE 0 END,
            IsNonCollectible    = CASE WHEN c.PrimaryDenialCode IS NOT NULL
                                        AND EXISTS (SELECT 1 FROM dbo.ARWB_MasterListItem m
                                                    WHERE m.ListType = 'NON_COLLECTIBLE_CODE' AND m.IsActive = 1 AND m.ItemValue = c.PrimaryDenialCode)
                                       THEN 1 ELSE 0 END,
            HasNonCollectibleDenial = CASE WHEN EXISTS (SELECT 1 FROM dbo.ARWB_MasterListItem m
                                                        WHERE m.ListType = 'NON_COLLECTIBLE_CODE' AND m.IsActive = 1
                                                          AND (m.ItemValue = c.PrimaryDenialCode
                                                               OR EXISTS (SELECT 1 FROM dbo.ARWB_ClaimLineDenial ld
                                                                          WHERE ld.ClaimKey = c.ClaimKey AND ld.DenialCode = m.ItemValue)))
                                           THEN 1 ELSE 0 END,
            IsAutoAdjustCode    = CASE WHEN c.PrimaryDenialCode IS NOT NULL
                                        AND EXISTS (SELECT 1 FROM dbo.ARWB_MasterListItem m
                                                    WHERE m.ListType = 'AUTO_ADJUST_CODE' AND m.IsActive = 1 AND m.ItemValue = c.PrimaryDenialCode)
                                       THEN 1 ELSE 0 END,
            IsAwaitingQa        = CASE WHEN EXISTS (SELECT 1 FROM dbo.ARWB_ClaimQaReview r
                                                    WHERE r.ClaimKey = c.ClaimKey AND r.IsCurrent = 1 AND r.ReviewStatus = 'Awaiting QA')
                                       THEN 1 ELSE 0 END,
            HasActiveCip        = CASE WHEN EXISTS (SELECT 1 FROM dbo.ARWB_CipCase cc
                                                    WHERE cc.ClaimKey = c.ClaimKey AND cc.CaseStatus IN ('Pending Approval', 'Sent to Client', 'Client Responded'))
                                       THEN 1 ELSE 0 END,
            HasReturnedCipReply = CASE WHEN EXISTS (SELECT 1 FROM dbo.ARWB_CipCase cc
                                                    WHERE cc.ClaimKey = c.ClaimKey AND cc.CaseStatus = 'Returned to Agent'
                                                      AND cc.ClientRespondedOn IS NOT NULL)
                                       THEN 1 ELSE 0 END,
            IsPendingPosting    = CASE WHEN f.IsNullified = 1 AND c.IsPmsPostedConfirmed = 0 AND c.InsuranceBalance > @Eps THEN 1 ELSE 0 END
    ) s
    -- Financial-state bucket (precedence step 8)
    CROSS APPLY
    (
        SELECT
            FinQueue = CASE
                WHEN f.RemainingAR <= @Eps              THEN CASE WHEN c.PatientBalance > @Eps THEN 'patientar' ELSE 'closed' END
                WHEN c.InsurancePayment > @Eps          THEN 'partial'
                WHEN c.HasDenial = 1                    THEN 'denied'
                WHEN c.InsuranceAdjustments > @Eps      THEN 'partialadj'
                ELSE 'nonresponded' END,
            FinSubQueue = CASE
                WHEN f.RemainingAR <= @Eps              THEN CASE WHEN c.PatientBalance > @Eps THEN NULL
                                                              WHEN c.InsurancePayment + c.PatientPayment > @Eps THEN 'closed_paid'
                                                              ELSE 'closed_adjusted' END
                WHEN c.InsurancePayment > @Eps          THEN CASE WHEN s.IsNonCollectible = 1 THEN 'partial_noncollectible' ELSE 'partial_collectible' END
                WHEN c.HasDenial = 1                    THEN CASE WHEN s.IsNonCollectible = 1 THEN 'denied_noncollectible'  ELSE 'denied_collectible'  END
                WHEN c.InsuranceAdjustments > @Eps      THEN 'partialadj_collectible'
                ELSE 'nonresponded_collectible' END
    ) fin
    -- Priority-ordered classification (precedence steps 1-7b)
    CROSS APPLY
    (
        SELECT
            QueueId = CASE
                WHEN s.IsAwaitingQa = 1                 THEN 'submittedqa'
                WHEN c.WorkflowStatus = 'QA Rejected'   THEN 'qarejected'
                WHEN s.IsPendingPosting = 1             THEN 'autoadj'
                WHEN c.WorkflowStatus = 'Completed' THEN
                    CASE WHEN f.RemainingAR <= @Eps     THEN fin.FinQueue
                         WHEN s.HasActiveCip = 1        THEN 'escalation'
                         WHEN c.NewDenialSinceWork = 1  THEN 'refollowup'
                         WHEN s.IsRefollowupDue = 1     THEN 'refollowup'
                         ELSE 'completed' END
                WHEN s.HasReturnedCipReply = 1 AND c.WorkflowStatus = 'Assigned' THEN 'cipresponse'
                ELSE fin.FinQueue END,
            SubQueueId = CASE
                WHEN s.IsAwaitingQa = 1                 THEN NULL
                WHEN c.WorkflowStatus = 'QA Rejected'   THEN NULL
                WHEN s.IsPendingPosting = 1             THEN CASE WHEN c.IsAutoAdjusted = 1 THEN 'autoadj_system' ELSE 'autoadj_writeoff' END
                WHEN c.WorkflowStatus = 'Completed' THEN
                    CASE WHEN f.RemainingAR <= @Eps     THEN fin.FinSubQueue
                         WHEN s.HasActiveCip = 1        THEN NULL
                         WHEN c.NewDenialSinceWork = 1  THEN 'refollowup_newdenials'
                         WHEN s.IsRefollowupDue = 1     THEN 'refollowup_unresolved'
                         ELSE NULL END
                WHEN s.HasReturnedCipReply = 1 AND c.WorkflowStatus = 'Assigned' THEN NULL
                ELSE fin.FinSubQueue END
    ) q
    LEFT JOIN dbo.ARWB_ArQueue aq ON aq.QueueId = COALESCE(q.SubQueueId, q.QueueId)
    -- Aging (basis is an AppSetting: date of service by default)
    CROSS APPLY
    (
        SELECT AgingDays = DATEDIFF(day, CASE WHEN @AgingOnDenial = 1 THEN COALESCE(c.DenialDate, c.DateOfService) ELSE c.DateOfService END, @AsOf)
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
        SELECT TOP (1) th.ThresholdDays FROM dbo.ARWB_TflThreshold th WHERE th.FinancialClass = c.PayerType
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
        SELECT LastTouchedOn = MAX(ca.ActivityOn) FROM dbo.ARWB_ClaimActivity ca WHERE ca.ClaimKey = c.ClaimKey
    ) lt
    WHERE (@ClaimKey     IS NULL OR c.ClaimKey         = @ClaimKey)
      AND (@RefreshRunId IS NULL OR c.LastRefreshRunId = @RefreshRunId)
      AND (@HasKeys = 0 OR c.ClaimKey IN (SELECT k.ClaimKey FROM @Keys k))
    OPTION (RECOMPILE);

    SELECT UpdatedClaims = @@ROWCOUNT;
END;
GO

PRINT 'AR Workbench 04: dbo.ARWB_usp_PriceClaimLines and dbo.ARWB_usp_RecalculateClaimState ready.';
GO

/* ============================================================================================
   AR Workbench - 03 Master data seed
   Values come from the AR Workbench mockup (meta.json) and the Developer Handoff v1.1 session
   decisions. Insert-if-missing only: re-running never overwrites Master File Maintenance edits.

   Every denial code below is NORMALIZED (no CARC prefix): 'CO16' and 'PR16' are both '16'.
   Lists marked STARTER are open items with the business owner - review before go-live.
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- Roles and permissions are not seeded here: they live in LRNMaster
-- (see LRNMaster_01_ARWB_Roles_Access.sql).

/* ---------- Business-rule settings -------------------------------------------------------- */
INSERT INTO dbo.ARWB_AppSetting (SettingKey, SettingValue, Description)
SELECT v.SettingKey, v.SettingValue, v.Description
FROM (VALUES
    ('BalanceEpsilon',                   N'0.005',         N'Balances at or below this are treated as zero (absorbs rounding noise).'),
    ('UntouchedDays',                    N'45',            N'Assignment Management: unassigned claims untouched this many days surface in Unassigned Claims.'),
    ('RefollowupDays',                   N'45',            N'Worked claims whose last follow-up is this old are Re-Follow-Up Required - Unresolved Claims.'),
    ('NextFollowUpDefaultDays',          N'45',            N'Default Next Follow-Up Date = today + this many calendar days (handoff 8.1).'),
    ('TflDefaultDays',                   N'180',           N'Timely-filing limit for a financial class with no ARWB_TflThreshold row.'),
    ('TflRiskWindowDays',                N'30',            N'Open claims within this many days of the TFL deadline are flagged TFL-at-risk.'),
    ('PriorityHighAmount',               N'500',           N'Remaining AR at or above this is High priority (priority rule is an open item).'),
    ('PriorityMediumAmount',             N'100',           N'Remaining AR at or above this is Medium priority.'),
    ('AgingBasis',                       N'DateOfService', N'DateOfService | DenialDate. Aging basis is an open item; the mockup uses date of service.'),
    ('PrimaryDenialSource',              N'CuratedColumn', N'CuratedColumn: first code of ClaimLevelData.DenialCode. Ranking: lowest ARWB_DenialCodeRank among claim and line codes (Phase 2).'),
    ('PrimaryDenialFallbackToLine',      N'0',             N'1 = when the curated DenialCode column is blank, use the first line-level denial code. 0 = the claim has no denial.'),
    ('AutoAdjustIncludesNonCollectible', N'0',             N'1 = Non-Collectible codes are also eligible for Process Automatic Adjustments (mockup). Open item: one list or two.'),
    ('AttachmentMaxBytes',               N'15728640',      N'Maximum size of one attachment (15 MB; 10 vs 15 MB is an open item).'),
    ('AttachmentMaxFiles',               N'10',            N'Maximum attachments on one follow-up note or CIP response.'),
    ('AttachmentAllowedTypes',           N'pdf,png,jpg,jpeg,tif,tiff,gif,doc,docx,xls,xlsx,csv,txt', N'Allowed attachment file extensions.'),
    ('DocumentBlobContainer',            N'arwb-documents', N'Azure Blob container for the Document Vault (private access, encryption at rest).'),
    ('InsightWeeksShown',                N'2',             N'Data Processing shows this many sync weeks of insights (current + previous).'),
    ('QueueSnapshotRetentionDays',       N'400',           N'Nightly queue snapshots older than this are purged.'),
    -- Operational SLA (Reports > RPT-09). DRAFT targets in calendar days until SlaTargetsConfirmed = 1;
    -- edited on Master Values > Operational SLA Targets.
    ('SlaFirstFollowUpDays',             N'3',             N'SLA: days from assignment to the first follow-up note (draft).'),
    ('SlaFollowUpGraceDays',             N'0',             N'SLA: days of grace after Next Follow-Up Date for the next note (draft).'),
    ('SlaQaDecisionDays',                N'2',             N'SLA: days from Submitted for QA to the QA decision (draft).'),
    ('SlaCipApprovalDays',               N'2',             N'SLA: days from a CIP note''s QA approval to send-to-client / return (draft).'),
    ('SlaClientResponseDays',            N'7',             N'SLA: days from a CIP escalation sent to the client to the client response (draft).'),
    ('SlaCipResponseReviewDays',         N'2',             N'SLA: days from the client response to its review (draft).'),
    ('SlaTargetsConfirmed',              N'0',             N'1 = the team has confirmed the SLA targets; 0 = the Operational SLA report labels them as drafts.')
) v (SettingKey, SettingValue, Description)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_AppSetting s WHERE s.SettingKey = v.SettingKey);
GO

/* ---------- AR queue taxonomy (handoff 3.1 / 18.3). Parents first (FK on ParentQueueId). -----
   IsPriority   : needs agent work.  IsRestricted: admin / manager / lead only.
   IsAutoRouted : feeds the Denial & AR Work Queue for assignment.                              */
INSERT INTO dbo.ARWB_ArQueue (QueueId, ParentQueueId, QueueLabel, QueueGroup, IsPriority, IsRestricted, IsAutoRouted, SortOrder, BadgeClass)
SELECT v.QueueId, NULL, v.QueueLabel, v.QueueGroup, v.IsPriority, v.IsRestricted, v.IsAutoRouted, v.SortOrder, v.BadgeClass
FROM (VALUES
    ('submittedqa',  N'Submitted for QA',                'Workflow',  1, 0, 0,  10, 'purple'),
    ('qarejected',   N'QA Rejected',                     'Workflow',  1, 0, 0,  20, 'critical'),
    ('autoadj',      N'Auto Adjustments',                'Workflow',  1, 0, 0,  25, 'warning'),
    ('cipresponse',  N'CIP Response Received',           'Workflow',  1, 0, 0,  30, 'info'),
    ('escalation',   N'Client Escalation (CIP) Pending', 'Workflow',  1, 0, 0,  40, 'warning'),
    ('refollowup',   N'Re-Follow-Up Required',           'Workflow',  1, 0, 1,  50, 'warning'),
    ('denied',       N'Denied',                          'Active AR', 1, 0, 0,  60, 'critical'),
    ('partial',      N'Partially Paid',                  'Active AR', 1, 0, 0,  70, 'info'),
    ('partialadj',   N'Partially Adjusted',              'Active AR', 1, 0, 1,  80, 'info'),
    ('nonresponded', N'Non-Responder',                   'Active AR', 1, 0, 1,  90, 'warning'),
    ('patientar',    N'Patient AR',                      'Patient',   0, 1, 0, 100, 'neutral'),
    ('completed',    N'Completed Claims',                'Workflow',  1, 0, 0, 110, 'good'),
    ('closed',       N'Closed',                          'Closed',    0, 1, 0, 120, 'good')
) v (QueueId, QueueLabel, QueueGroup, IsPriority, IsRestricted, IsAutoRouted, SortOrder, BadgeClass)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_ArQueue q WHERE q.QueueId = v.QueueId);

INSERT INTO dbo.ARWB_ArQueue (QueueId, ParentQueueId, QueueLabel, QueueGroup, IsPriority, IsRestricted, IsAutoRouted, SortOrder, BadgeClass)
SELECT v.QueueId, v.ParentQueueId, v.QueueLabel, p.QueueGroup, v.IsPriority, v.IsRestricted, v.IsAutoRouted, v.SortOrder, NULL
FROM (VALUES
    ('autoadj_system',           'autoadj',      N'System Auto-Adjusted',                  1, 0, 0,  26),
    ('autoadj_writeoff',         'autoadj',      N'Approved Write-Offs - Pending Posting', 1, 0, 0,  27),
    ('refollowup_unresolved',    'refollowup',   N'Unresolved Claims',                     1, 0, 1,  51),
    ('refollowup_newdenials',    'refollowup',   N'New Denials',                           1, 0, 1,  52),
    ('denied_collectible',       'denied',       N'Possible Collectible',                  1, 0, 1,  61),
    ('denied_noncollectible',    'denied',       N'Non-Collectible',                       0, 1, 0,  62),
    ('partial_collectible',      'partial',      N'Possible Collectible',                  1, 0, 1,  71),
    ('partial_noncollectible',   'partial',      N'Non-Collectible',                       0, 1, 0,  72),
    ('partialadj_collectible',   'partialadj',   N'Possible Collectible',                  1, 0, 1,  81),
    ('nonresponded_collectible', 'nonresponded', N'Possible Collectible',                  1, 0, 1,  91),
    ('closed_paid',              'closed',       N'Fully Paid',                            0, 1, 0, 121),
    ('closed_adjusted',          'closed',       N'Fully Adjusted',                        0, 1, 0, 122)
) v (QueueId, ParentQueueId, QueueLabel, IsPriority, IsRestricted, IsAutoRouted, SortOrder)
INNER JOIN dbo.ARWB_ArQueue p ON p.QueueId = v.ParentQueueId
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_ArQueue q WHERE q.QueueId = v.QueueId);
GO

/* ---------- Chip-list masters ------------------------------------------------------------- */
INSERT INTO dbo.ARWB_MasterListItem (ListType, ItemValue, SortOrder, CreatedBy)
SELECT v.ListType, v.ItemValue, v.SortOrder, N'seed'
FROM (VALUES
    -- Denial categories
    ('DENIAL_CATEGORY', N'Additional Documentation Required', 1),
    ('DENIAL_CATEGORY', N'Medical Necessity', 2),
    ('DENIAL_CATEGORY', N'Coding-Related Denials', 3),
    ('DENIAL_CATEGORY', N'Eligibility Issues', 4),
    ('DENIAL_CATEGORY', N'Authorization Required', 5),
    ('DENIAL_CATEGORY', N'Timely Filing', 6),
    ('DENIAL_CATEGORY', N'Duplicate Claims', 7),
    ('DENIAL_CATEGORY', N'Payer Processing Issues', 8),
    ('DENIAL_CATEGORY', N'Partially Paid Claims', 9),
    ('DENIAL_CATEGORY', N'Unresponsive Payers', 10),
    ('DENIAL_CATEGORY', N'Other', 99),
    -- Panel types
    ('PANEL_TYPE', N'Toxicology', 1),
    ('PANEL_TYPE', N'UTI Panel', 2),
    ('PANEL_TYPE', N'STI Panel', 3),
    -- STARTER: Non-Collectible codes (primary denial on this list -> Non-Collectible sub-queues)
    ('NON_COLLECTIBLE_CODE', N'197', 1),     -- precertification / authorization absent
    ('NON_COLLECTIBLE_CODE', N'242', 2),     -- services not provided by network providers
    ('NON_COLLECTIBLE_CODE', N'257', 3),
    ('NON_COLLECTIBLE_CODE', N'288', 4),
    ('NON_COLLECTIBLE_CODE', N'27',  5),
    ('NON_COLLECTIBLE_CODE', N'31',  6),
    -- STARTER: Auto-Adjust codes (adjust rather than follow up; session examples 242, 197)
    ('AUTO_ADJUST_CODE', N'242', 1),
    ('AUTO_ADJUST_CODE', N'197', 2),
    -- Comments framework
    ('CLAIM_TYPE', N'Primary', 1),
    ('CLAIM_TYPE', N'Secondary', 2),
    ('FOLLOW_UP_TYPE', N'Review', 1),
    ('FOLLOW_UP_TYPE', N'Online', 2),
    ('FOLLOW_UP_TYPE', N'Call', 3),
    ('CLAIM_STATUS', N'Paid', 1),
    ('CLAIM_STATUS', N'Denied', 2),
    ('CLAIM_STATUS', N'Not Received', 3),
    ('CLAIM_STATUS', N'In Process', 4),
    ('CLAIM_STATUS', N'Paid to Patient', 5),
    ('CLAIM_STATUS', N'Patient Responsibility', 6),
    ('CLAIM_STATUS', N'On Hold', 7),
    ('DENIAL_ROOT_CAUSE', N'Additional Documentation/ Information Requests', 1),
    ('DENIAL_ROOT_CAUSE', N'Billing, Rendering or Referring Provider Eligibility Related Issues', 2),
    ('DENIAL_ROOT_CAUSE', N'Bundling', 3),
    ('DENIAL_ROOT_CAUSE', N'Claims Edits Related Issues', 4),
    ('DENIAL_ROOT_CAUSE', N'Coverage, Eligibility or Benefits Related Issues', 5),
    ('DENIAL_ROOT_CAUSE', N'Duplicate Claim Encounter', 6),
    ('DENIAL_ROOT_CAUSE', N'ICD-10 Codes Related Issues', 7),
    ('DENIAL_ROOT_CAUSE', N'Maximum Benefit Reached', 8),
    ('DENIAL_ROOT_CAUSE', N'Medical Necessity or Non Covered Charges Related Issues', 9),
    ('DENIAL_ROOT_CAUSE', N'Missing Prior Authorization', 10),
    ('DENIAL_ROOT_CAUSE', N'Other Denials - Remark or Payer Review Required', 11),
    ('DENIAL_ROOT_CAUSE', N'Previous Payer Processing Information Related Denials', 12),
    ('DENIAL_ROOT_CAUSE', N'Procedure Code, Modifier or Coding Related Issues', 13),
    ('DENIAL_ROOT_CAUSE', N'Provider Out of Network', 14),
    ('DENIAL_ROOT_CAUSE', N'Timely Filling Limits Exceeded', 15),
    ('FIX_RESOLUTION', N'Appealed', 1),
    ('FIX_RESOLUTION', N'Awaiting EOB', 2),
    ('FIX_RESOLUTION', N'Billed to Patient', 3),
    ('FIX_RESOLUTION', N'Billed to Secondary', 4),
    ('FIX_RESOLUTION', N'CIP - Client Escalations', 5),
    ('FIX_RESOLUTION', N'Medical Records Submitted', 6),
    ('FIX_RESOLUTION', N'Paid Posted and Closed', 7),
    ('FIX_RESOLUTION', N'Pending Payer Adjudication', 8),
    ('FIX_RESOLUTION', N'Reconsideration Submitted', 9),
    ('FIX_RESOLUTION', N'Reprocessed', 10),
    ('FIX_RESOLUTION', N'Resubmitted - E', 11),
    ('FIX_RESOLUTION', N'Resubmitted - F', 12),
    ('FIX_RESOLUTION', N'Resubmitted - P', 13),
    ('FIX_RESOLUTION', N'Write Off', 14),
    -- CIP
    ('CIP_CATEGORY', N'DX Codes', 1),
    ('CIP_CATEGORY', N'Insurance', 2),
    ('CIP_CATEGORY', N'Enrollment', 3),
    ('CIP_CATEGORY', N'Documents', 4),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - Chart/ History Notes', 1),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - Requisitions Form', 2),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - Result Sheets', 3),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - Req & Results', 4),
    ('CIP_REQUIRED_INFO', N'Additional Documentation Required - All', 5),
    ('CIP_REQUIRED_INFO', N'Active Current Insurance info required', 6),
    ('CIP_REQUIRED_INFO', N'Active Alternative Insurance info required', 7),
    ('CIP_REQUIRED_INFO', N'Patient call required', 8),
    ('CIP_REQUIRED_INFO', N'Enrollment Required with the payer', 9),
    ('CIP_REQUIRED_INFO', N'COB Update Requested', 10),
    ('CIP_REQUIRED_INFO', N'Valid ICD-10 Codes Required', 11),
    -- STARTER: escalation / reassignment reason categories (open item 9)
    ('ESCALATION_REASON', N'Payer portal access required', 1),
    ('ESCALATION_REASON', N'Payer call required', 2),
    ('ESCALATION_REASON', N'Coding or clinical review required', 3),
    ('ESCALATION_REASON', N'Supervisor guidance on complex denial', 4),
    ('ESCALATION_REASON', N'Timely filing risk', 5),
    ('ESCALATION_REASON', N'Other', 99),
    ('REASSIGNMENT_REASON', N'Payer call outside my shift', 1),
    ('REASSIGNMENT_REASON', N'Workload / capacity', 2),
    ('REASSIGNMENT_REASON', N'Skill or payer specialty mismatch', 3),
    ('REASSIGNMENT_REASON', N'Payer portal access not available', 4),
    ('REASSIGNMENT_REASON', N'Other', 99),
    -- Documents
    ('DOCUMENT_CATEGORY', N'Appeal', 1),
    ('DOCUMENT_CATEGORY', N'EOB', 2),
    ('DOCUMENT_CATEGORY', N'Medical Record', 3),
    ('DOCUMENT_CATEGORY', N'Payer Correspondence', 4),
    ('DOCUMENT_CATEGORY', N'CIP Response', 5),
    ('DOCUMENT_CATEGORY', N'Other', 99),
    -- QA
    ('QA_ERROR_TYPE', N'Incomplete Documentation', 1),
    ('QA_ERROR_TYPE', N'Incorrect Denial Category', 2),
    ('QA_ERROR_TYPE', N'Missed Follow-Up', 3),
    ('QA_ERROR_TYPE', N'Financial Update Error', 4),
    ('QA_ERROR_TYPE', N'Other', 99),
    -- Reports: AR Collections Progress confidence tiers (percent)
    ('REVENUE_CONFIDENCE_TIER', N'100', 1),
    ('REVENUE_CONFIDENCE_TIER', N'50', 2),
    ('REVENUE_CONFIDENCE_TIER', N'30', 3),
    -- Workflow / aging / financial class
    ('WORKFLOW_STATUS', N'Unassigned', 1),
    ('WORKFLOW_STATUS', N'Assigned', 2),
    ('WORKFLOW_STATUS', N'Submitted for QA', 3),
    ('WORKFLOW_STATUS', N'QA Rejected', 4),
    ('WORKFLOW_STATUS', N'Completed', 5),
    ('AGING_BUCKET', N'0-30 Days', 1),
    ('AGING_BUCKET', N'31-60 Days', 2),
    ('AGING_BUCKET', N'61-90 Days', 3),
    ('AGING_BUCKET', N'91-120 Days', 4),
    ('AGING_BUCKET', N'121-180 Days', 5),
    ('AGING_BUCKET', N'181+ Days', 6),
    ('FINANCIAL_CLASS', N'Commercial', 1),
    ('FINANCIAL_CLASS', N'Medicare', 2),
    ('FINANCIAL_CLASS', N'Medicaid', 3),
    ('FINANCIAL_CLASS', N'Self Pay', 4)
) v (ListType, ItemValue, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_MasterListItem m WHERE m.ListType = v.ListType AND m.ItemValue = v.ItemValue);
GO

/* ---------- Fix / Resolution by Claim Status --------------------------------------------- */
INSERT INTO dbo.ARWB_FixResolutionByStatus (ClaimStatus, FixResolution, SortOrder)
SELECT v.ClaimStatus, v.FixResolution, v.SortOrder
FROM (VALUES
    (N'Paid', N'Awaiting EOB', 1), (N'Paid', N'Paid Posted and Closed', 2),
    (N'Denied', N'Appealed', 1), (N'Denied', N'Billed to Patient', 2), (N'Denied', N'Billed to Secondary', 3),
    (N'Denied', N'CIP - Client Escalations', 4), (N'Denied', N'Medical Records Submitted', 5),
    (N'Denied', N'Reconsideration Submitted', 6), (N'Denied', N'Reprocessed', 7), (N'Denied', N'Resubmitted - E', 8),
    (N'Denied', N'Resubmitted - F', 9), (N'Denied', N'Resubmitted - P', 10), (N'Denied', N'Write Off', 11),
    (N'Not Received', N'Resubmitted - E', 1), (N'Not Received', N'Resubmitted - F', 2), (N'Not Received', N'Resubmitted - P', 3),
    (N'In Process', N'Awaiting EOB', 1), (N'In Process', N'Pending Payer Adjudication', 2),
    (N'Paid to Patient', N'Awaiting EOB', 1), (N'Paid to Patient', N'Billed to Patient', 2),
    (N'Patient Responsibility', N'Awaiting EOB', 1), (N'Patient Responsibility', N'Billed to Patient', 2),
    (N'On Hold', N'Appealed', 1), (N'On Hold', N'Medical Records Submitted', 2), (N'On Hold', N'Reconsideration Submitted', 3)
) v (ClaimStatus, FixResolution, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_FixResolutionByStatus f WHERE f.ClaimStatus = v.ClaimStatus AND f.FixResolution = v.FixResolution);
GO

/* ---------- Workflow templates and stage paths ------------------------------------------- */
INSERT INTO dbo.ARWB_WorkflowTemplate (TemplateKey, TemplateLabel)
SELECT v.TemplateKey, v.TemplateLabel
FROM (VALUES
    ('doc_required',    N'Additional Documentation / Information Required'),
    ('non_responded',   N'Non-Responded AR'),
    ('coding_edit',     N'Claims Edit / Coding-Related Issues'),
    ('partial_payment', N'Partially Paid Claims'),
    ('denied',          N'Denied Claims')
) v (TemplateKey, TemplateLabel)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_WorkflowTemplate t WHERE t.TemplateKey = v.TemplateKey);

INSERT INTO dbo.ARWB_WorkflowTemplateStage (TemplateKey, StageOrder, StageName)
SELECT v.TemplateKey, v.StageOrder, v.StageName
FROM (VALUES
    ('doc_required', 1, N'Identified'), ('doc_required', 2, N'Assigned'), ('doc_required', 3, N'Documentation Review'),
    ('doc_required', 4, N'Records Requested Internally'), ('doc_required', 5, N'Records Submitted to Payer'),
    ('doc_required', 6, N'Payer Follow-Up'), ('doc_required', 7, N'Payment / Resolution'), ('doc_required', 8, N'QA'), ('doc_required', 9, N'Closed'),

    ('non_responded', 1, N'Identified'), ('non_responded', 2, N'Assigned'), ('non_responded', 3, N'Payer Contact Attempt'),
    ('non_responded', 4, N'Follow-Up Scheduled'), ('non_responded', 5, N'Payer Response Received'),
    ('non_responded', 6, N'Resolution Action'), ('non_responded', 7, N'QA'), ('non_responded', 8, N'Closed'),

    ('coding_edit', 1, N'Identified'), ('coding_edit', 2, N'Assigned'), ('coding_edit', 3, N'Coding Review'),
    ('coding_edit', 4, N'Correction Required'), ('coding_edit', 5, N'Corrected Claim Submitted'),
    ('coding_edit', 6, N'Payer Follow-Up'), ('coding_edit', 7, N'Payment / Resolution'), ('coding_edit', 8, N'QA'), ('coding_edit', 9, N'Closed'),

    ('partial_payment', 1, N'Identified'), ('partial_payment', 2, N'Assigned'), ('partial_payment', 3, N'Payment Variance Review'),
    ('partial_payment', 4, N'Revenue Expectation Validation'), ('partial_payment', 5, N'Underpayment Follow-Up'),
    ('partial_payment', 6, N'Additional Payment / Adjustment'), ('partial_payment', 7, N'QA'), ('partial_payment', 8, N'Closed'),

    ('denied', 1, N'Identified'), ('denied', 2, N'Assigned'), ('denied', 3, N'Denial Review'),
    ('denied', 4, N'Corrective Action'), ('denied', 5, N'Resubmission / Appeal / Payer Follow-Up'),
    ('denied', 6, N'Payer Decision'), ('denied', 7, N'QA'), ('denied', 8, N'Closed')
) v (TemplateKey, StageOrder, StageName)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_WorkflowTemplateStage s WHERE s.TemplateKey = v.TemplateKey AND s.StageOrder = v.StageOrder);

-- Category -> template. Denied claims whose category has no row use 'denied'. Claims with no denial
-- use 'partial_payment' when paid in part, else 'non_responded' (see script 05).
INSERT INTO dbo.ARWB_DenialCategoryTemplate (DenialCategory, TemplateKey)
SELECT v.DenialCategory, v.TemplateKey
FROM (VALUES
    (N'Additional Documentation Required', 'doc_required'),
    (N'Coding-Related Denials',            'coding_edit'),
    (N'Partially Paid Claims',             'partial_payment'),
    (N'Unresponsive Payers',               'non_responded'),
    (N'Medical Necessity',                 'denied'),
    (N'Eligibility Issues',                'denied'),
    (N'Authorization Required',            'denied'),
    (N'Timely Filing',                     'denied'),
    (N'Duplicate Claims',                  'denied'),
    (N'Payer Processing Issues',           'denied'),
    (N'Other',                             'denied')
) v (DenialCategory, TemplateKey)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_DenialCategoryTemplate d WHERE d.DenialCategory = v.DenialCategory);
GO

/* ---------- Denial category -> Key Observations tag and recommended action --------------- */
INSERT INTO dbo.ARWB_DenialCategoryAction (DenialCategory, CategoryTag, RecommendedAction)
SELECT v.DenialCategory, v.CategoryTag, v.RecommendedAction
FROM (VALUES
    (N'Additional Documentation Required', N'Appeal / MR', N'Submit the requested medical records / documentation to the payer via the appropriate channel (portal, fax, etc.).'),
    (N'Medical Necessity',                 N'Appeal / MR', N'Review clinical documentation for medical necessity support and file an appeal with supporting notes.'),
    (N'Coding-Related Denials',            N'Review',      N'Verify the CPT / modifier / diagnosis combination on file and rebill a corrected claim if warranted.'),
    (N'Eligibility Issues',                N'Review',      N'Re-verify patient eligibility and coordination of benefits; rebill the correct payer if one is identified.'),
    (N'Authorization Required',            N'Review',      N'Check whether a referral / prior authorization is on file; submit it with medical records if available, or adjust off if not.'),
    (N'Timely Filing',                     N'Appeal / MR', N'Document proof of timely submission and file a timely-filing exception appeal.'),
    (N'Duplicate Claims',                  N'Review',      N'Confirm whether this is a true duplicate; void the claim or provide the original claim reference if not.'),
    (N'Payer Processing Issues',           N'Review',      N'LRN currently investigating - contact the payer to confirm claim receipt and expedite processing.'),
    (N'Partially Paid Claims',             N'Review',      N'Validate the expected allowable against the contract and file an underpayment appeal if warranted.'),
    (N'Unresponsive Payers',               N'Review',      N'Escalate follow-up with the payer provider line; consider a formal status inquiry.'),
    (N'Other',                             N'Review',      N'Review payer remittance remarks and determine the appropriate corrective action.')
) v (DenialCategory, CategoryTag, RecommendedAction)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_DenialCategoryAction a WHERE a.DenialCategory = v.DenialCategory);
GO

/* ---------- Timely-filing thresholds (keys match ClaimLevelData.PayerType values) -------- */
INSERT INTO dbo.ARWB_TflThreshold (FinancialClass, ThresholdDays)
SELECT v.FinancialClass, v.ThresholdDays
FROM (VALUES
    (N'Commercial', 180), (N'CC - COMMERCIAL', 180),
    (N'Medicare',   365), (N'MC - MEDICARE',   365),
    (N'Medicaid',   365), (N'MD - MEDICAID',   365),
    (N'Self Pay',  9999), (N'SP - SELF PAY',  9999)
) v (FinancialClass, ThresholdDays)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_TflThreshold t WHERE t.FinancialClass = v.FinancialClass);
GO

/* ---------- STARTER: normalized denial code -> category (standard CARC codes) ------------
   The business owner is delivering the full categorization (open item 2); load it here or in
   Master File Maintenance. Denied claims whose code is not mapped land in 'Other'.            */
INSERT INTO dbo.ARWB_DenialCodeCategoryMap (DenialCode, DenialCategory, CreatedBy)
SELECT v.DenialCode, v.DenialCategory, N'seed'
FROM (VALUES
    (N'16',  N'Additional Documentation Required'), (N'252', N'Additional Documentation Required'), (N'226', N'Additional Documentation Required'),
    (N'50',  N'Medical Necessity'), (N'150', N'Medical Necessity'), (N'151', N'Medical Necessity'), (N'96', N'Medical Necessity'), (N'204', N'Medical Necessity'),
    (N'4',   N'Coding-Related Denials'), (N'5',   N'Coding-Related Denials'), (N'6',   N'Coding-Related Denials'),
    (N'11',  N'Coding-Related Denials'), (N'97',  N'Coding-Related Denials'), (N'234', N'Coding-Related Denials'),
    (N'236', N'Coding-Related Denials'), (N'167', N'Coding-Related Denials'),
    (N'26',  N'Eligibility Issues'), (N'27', N'Eligibility Issues'), (N'31', N'Eligibility Issues'),
    (N'109', N'Eligibility Issues'), (N'177', N'Eligibility Issues'), (N'242', N'Eligibility Issues'),
    (N'15',  N'Authorization Required'), (N'62', N'Authorization Required'), (N'197', N'Authorization Required'), (N'198', N'Authorization Required'),
    (N'29',  N'Timely Filing'),
    (N'18',  N'Duplicate Claims'),
    (N'22',  N'Payer Processing Issues'), (N'23', N'Payer Processing Issues'), (N'24', N'Payer Processing Issues'), (N'133', N'Payer Processing Issues'),
    (N'45',  N'Partially Paid Claims'), (N'94', N'Partially Paid Claims'),
    (N'257', N'Other'), (N'288', N'Other')
) v (DenialCode, DenialCategory)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_DenialCodeCategoryMap m WHERE m.DenialCode = v.DenialCode);
GO

/* ---------- STARTER: denial hierarchy (Phase 2). Terminal denials override others. -------- */
INSERT INTO dbo.ARWB_DenialCodeRank (DenialCode, RankOrder, IsTerminal, Note)
SELECT v.DenialCode, v.RankOrder, v.IsTerminal, v.Note
FROM (VALUES
    (N'204', 10, 1, N'Service not covered by benefit plan'),
    (N'197', 20, 1, N'Precertification / authorization absent')
) v (DenialCode, RankOrder, IsTerminal, Note)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ARWB_DenialCodeRank r WHERE r.DenialCode = v.DenialCode);
GO

PRINT 'AR Workbench 03: master data seeded.';
GO

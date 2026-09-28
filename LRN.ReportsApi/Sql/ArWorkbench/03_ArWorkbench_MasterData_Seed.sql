/* ============================================================================================
   AR Workbench - 03 Master data seed
   Values come from the AR Workbench reference build (docs/Denial_WorkFlow, meta.json).
   Insert-if-missing only: re-running never overwrites an admin's Master File Maintenance edits.
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- Roles and permissions are not seeded here: they live in LRNMaster
-- (see LRNMaster_01_ArWorkbench_Roles_Access.sql).

/* ---------- Business-rule settings -------------------------------------------------------- */
INSERT INTO arwb.AppSetting (SettingKey, SettingValue, Description)
SELECT v.SettingKey, v.SettingValue, v.Description
FROM (VALUES
    ('BalanceEpsilon',          N'0.005',  N'Balances at or below this are treated as zero (absorbs rounding noise).'),
    ('UntouchedDays',           N'45',     N'Assignment Management: unassigned claims untouched this many days surface in Unassigned Claims.'),
    ('RefollowupDays',          N'45',     N'Completed claims whose last follow-up is this old are Re-follow-up Required.'),
    ('NextFollowUpDefaultDays', N'7',      N'Default Next Follow-Up Date offset on the follow-up note.'),
    ('TflDefaultDays',          N'180',    N'Timely-filing limit for a financial class with no arwb.TflThreshold row.'),
    ('TflRiskWindowDays',       N'30',     N'Open claims within this many days of the TFL deadline are flagged TFL-at-risk.'),
    ('PriorityHighAmount',      N'500',    N'Remaining AR at or above this is High priority.'),
    ('PriorityMediumAmount',    N'100',    N'Remaining AR at or above this is Medium priority.'),
    ('CipAttachMaxFiles',       N'3',      N'Maximum attachments on one CIP client response.'),
    ('CipAttachMaxBytes',       N'5242880',N'Maximum size of one CIP attachment in bytes.')
) v (SettingKey, SettingValue, Description)
WHERE NOT EXISTS (SELECT 1 FROM arwb.AppSetting s WHERE s.SettingKey = v.SettingKey);
GO

/* ---------- AR queue taxonomy (parents first, FK on ParentQueueId) ------------------------ */
INSERT INTO arwb.ArQueue (QueueId, ParentQueueId, QueueLabel, IsPriority, SortOrder, BadgeClass)
SELECT v.QueueId, NULL, v.QueueLabel, v.IsPriority, v.SortOrder, v.BadgeClass
FROM (VALUES
    ('submittedqa',  N'Submitted for QA Queue',                   1,  10, 'purple'),
    ('qarejected',   N'QA Rejected Queue',                        1,  20, 'critical'),
    ('cipresponse',  N'CIP Response Received Queue',              1,  30, 'info'),
    ('escalation',   N'Client Escalations Pending Queue',         1,  40, 'warning'),
    ('refollowup',   N'Re-follow-up Required Queue',              1,  50, 'warning'),
    ('denied',       N'Denied Queue',                             1,  60, 'critical'),
    ('partial',      N'Partially Paid and Outstanding AR Queue',  1,  70, 'info'),
    ('partialadj',   N'Partially Adjusted Queue',                 1,  80, 'info'),
    ('nonresponded', N'Non-Responded AR Queue',                   1,  90, 'warning'),
    ('patientar',    N'Patient AR Queue',                         0, 100, 'neutral'),
    ('completed',    N'Completed Claims Queue',                   1, 110, 'good'),
    ('closed',       N'Closed Claims',                            0, 120, 'good')
) v (QueueId, QueueLabel, IsPriority, SortOrder, BadgeClass)
WHERE NOT EXISTS (SELECT 1 FROM arwb.ArQueue q WHERE q.QueueId = v.QueueId);

INSERT INTO arwb.ArQueue (QueueId, ParentQueueId, QueueLabel, IsPriority, SortOrder, BadgeClass)
SELECT v.QueueId, v.ParentQueueId, v.QueueLabel, v.IsPriority, v.SortOrder, NULL
FROM (VALUES
    ('closed_paid',              'closed',       N'Fully Paid and Closed Claims', 0, 121),
    ('closed_adjusted',          'closed',       N'Fully Adjusted',               0, 122),
    ('nonresponded_collectible', 'nonresponded', N'Possible Collectible AR',      1,  91),
    ('denied_collectible',       'denied',       N'Possible Collectible AR',      1,  61),
    ('denied_noncollectible',    'denied',       N'Non-Collectible Denials',      0,  62),
    ('partial_collectible',      'partial',      N'Possible Collectible AR',      1,  71),
    ('partial_noncollectible',   'partial',      N'Non-Collectible Denials',      0,  72),
    ('partialadj_collectible',   'partialadj',   N'Possible Collectible AR',      1,  81)
) v (QueueId, ParentQueueId, QueueLabel, IsPriority, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM arwb.ArQueue q WHERE q.QueueId = v.QueueId);
GO

/* ---------- Chip-list masters ------------------------------------------------------------- */
INSERT INTO arwb.MasterListItem (ListType, ItemValue, SortOrder, CreatedBy)
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
    -- Non-collectible denial codes (normalized: no hyphen, no space)
    ('NON_COLLECTIBLE_CODE', N'OA257', 1),
    ('NON_COLLECTIBLE_CODE', N'PR288', 2),
    ('NON_COLLECTIBLE_CODE', N'PR27',  3),
    ('NON_COLLECTIBLE_CODE', N'PR31',  4),
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
WHERE NOT EXISTS (SELECT 1 FROM arwb.MasterListItem m WHERE m.ListType = v.ListType AND m.ItemValue = v.ItemValue);
GO

/* ---------- Fix / Resolution by Claim Status --------------------------------------------- */
INSERT INTO arwb.FixResolutionByStatus (ClaimStatus, FixResolution, SortOrder)
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
WHERE NOT EXISTS (SELECT 1 FROM arwb.FixResolutionByStatus f WHERE f.ClaimStatus = v.ClaimStatus AND f.FixResolution = v.FixResolution);
GO

/* ---------- Workflow templates and stage paths ------------------------------------------- */
INSERT INTO arwb.WorkflowTemplate (TemplateKey, TemplateLabel)
SELECT v.TemplateKey, v.TemplateLabel
FROM (VALUES
    ('doc_required',    N'Additional Documentation / Information Required'),
    ('non_responded',   N'Non-Responded AR'),
    ('coding_edit',     N'Claims Edit / Coding-Related Issues'),
    ('partial_payment', N'Partially Paid Claims'),
    ('denied',          N'Denied Claims')
) v (TemplateKey, TemplateLabel)
WHERE NOT EXISTS (SELECT 1 FROM arwb.WorkflowTemplate t WHERE t.TemplateKey = v.TemplateKey);

INSERT INTO arwb.WorkflowTemplateStage (TemplateKey, StageOrder, StageName)
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
    ('partial_payment', 4, N'Expected Payment Validation'), ('partial_payment', 5, N'Underpayment Follow-Up'),
    ('partial_payment', 6, N'Additional Payment / Adjustment'), ('partial_payment', 7, N'QA'), ('partial_payment', 8, N'Closed'),

    ('denied', 1, N'Identified'), ('denied', 2, N'Assigned'), ('denied', 3, N'Denial Review'),
    ('denied', 4, N'Corrective Action'), ('denied', 5, N'Resubmission / Appeal / Payer Follow-Up'),
    ('denied', 6, N'Payer Decision'), ('denied', 7, N'QA'), ('denied', 8, N'Closed')
) v (TemplateKey, StageOrder, StageName)
WHERE NOT EXISTS (SELECT 1 FROM arwb.WorkflowTemplateStage s WHERE s.TemplateKey = v.TemplateKey AND s.StageOrder = v.StageOrder);

-- Category -> template. Categories with no row fall back to 'denied'.
INSERT INTO arwb.DenialCategoryTemplate (DenialCategory, TemplateKey)
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
WHERE NOT EXISTS (SELECT 1 FROM arwb.DenialCategoryTemplate d WHERE d.DenialCategory = v.DenialCategory);
GO

/* ---------- Timely-filing thresholds (keys match ClaimLevelData.PayerType values) -------- */
INSERT INTO arwb.TflThreshold (FinancialClass, ThresholdDays)
SELECT v.FinancialClass, v.ThresholdDays
FROM (VALUES
    (N'Commercial', 180), (N'CC - COMMERCIAL', 180),
    (N'Medicare',   365), (N'MC - MEDICARE',   365),
    (N'Medicaid',   365), (N'MD - MEDICAID',   365),
    (N'Self Pay',  9999), (N'SP - SELF PAY',  9999)
) v (FinancialClass, ThresholdDays)
WHERE NOT EXISTS (SELECT 1 FROM arwb.TflThreshold t WHERE t.FinancialClass = v.FinancialClass);
GO

/* ---------- Starter Denial Code -> Category map (standard CARC codes) ---------------------
   STARTER DATA: review with operations before go-live and maintain it in Master File
   Maintenance. Codes not listed here land in category 'Other'.                                */
INSERT INTO arwb.DenialCodeCategoryMap (DenialCode, DenialCategory, CreatedBy)
SELECT v.DenialCode, v.DenialCategory, N'seed'
FROM (VALUES
    (N'CO16',  N'Additional Documentation Required'), (N'CO252', N'Additional Documentation Required'),
    (N'CO226', N'Additional Documentation Required'), (N'PR16',  N'Additional Documentation Required'),
    (N'CO50',  N'Medical Necessity'), (N'CO150', N'Medical Necessity'), (N'CO151', N'Medical Necessity'), (N'CO96', N'Medical Necessity'),
    (N'CO4',   N'Coding-Related Denials'), (N'CO5',   N'Coding-Related Denials'), (N'CO6',   N'Coding-Related Denials'),
    (N'CO11',  N'Coding-Related Denials'), (N'CO97',  N'Coding-Related Denials'), (N'CO234', N'Coding-Related Denials'),
    (N'CO236', N'Coding-Related Denials'), (N'CO167', N'Coding-Related Denials'),
    (N'CO26',  N'Eligibility Issues'), (N'CO27', N'Eligibility Issues'), (N'CO31', N'Eligibility Issues'),
    (N'CO109', N'Eligibility Issues'), (N'CO177', N'Eligibility Issues'), (N'PR27', N'Eligibility Issues'), (N'PR31', N'Eligibility Issues'),
    (N'CO15',  N'Authorization Required'), (N'CO62', N'Authorization Required'), (N'CO197', N'Authorization Required'), (N'CO198', N'Authorization Required'),
    (N'CO29',  N'Timely Filing'),
    (N'CO18',  N'Duplicate Claims'), (N'OA18', N'Duplicate Claims'),
    (N'CO22',  N'Payer Processing Issues'), (N'OA23', N'Payer Processing Issues'), (N'CO24', N'Payer Processing Issues'), (N'CO133', N'Payer Processing Issues'),
    (N'CO45',  N'Partially Paid Claims'), (N'CO94', N'Partially Paid Claims'),
    (N'OA257', N'Other'), (N'PR288', N'Other')
) v (DenialCode, DenialCategory)
WHERE NOT EXISTS (SELECT 1 FROM arwb.DenialCodeCategoryMap m WHERE m.DenialCode = v.DenialCode);
GO

PRINT 'AR Workbench 03: master data seeded.';
GO

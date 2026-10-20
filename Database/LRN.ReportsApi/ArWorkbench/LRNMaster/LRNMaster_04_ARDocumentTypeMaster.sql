/* ============================================================================================
   AR Workbench - LRNMaster: AR Document Type Master
   Target database: LRNMaster (DefaultConnection). Run ONCE per environment. Idempotent.

   The document types offered when a document is uploaded to a claim (Documents tab and the
   follow-up note). Every upload must pick one; the lab's dbo.ARWB_Document keeps the chosen
   DocumentTypeID / Code / Name and stores DocumentCategory from this table. Set IsActive = 0 to
   stop offering a type (documents already uploaded keep it).
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.ARDocumentTypeMaster', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ARDocumentTypeMaster
    (
        DocumentTypeID   INT           NOT NULL,
        DocumentCategory NVARCHAR(100) NOT NULL,
        DocumentTypeCode NVARCHAR(100) NOT NULL,
        DocumentTypeName NVARCHAR(200) NOT NULL,
        IsActive         BIT           NOT NULL
            CONSTRAINT DF_ARDocumentTypeMaster_IsActive
            DEFAULT (1),
        CreatedOn        DATETIME2(0)  NOT NULL
            CONSTRAINT DF_ARDocumentTypeMaster_CreatedOn
            DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_ARDocumentTypeMaster
            PRIMARY KEY (DocumentTypeID),

        CONSTRAINT UQ_ARDocumentTypeMaster_Code
            UNIQUE (DocumentTypeCode)
    );
END;
GO

-- Insert document types that do not already exist
INSERT INTO dbo.ARDocumentTypeMaster
(
    DocumentTypeID,
    DocumentCategory,
    DocumentTypeCode,
    DocumentTypeName
)
SELECT
    src.DocumentTypeID,
    src.DocumentCategory,
    src.DocumentTypeCode,
    src.DocumentTypeName
FROM
(
    VALUES
    (1,  N'Payer', N'EOB', N'Explanation of Benefits'),
    (2,  N'Payer', N'ERA_835', N'Electronic Remittance Advice'),
    (3,  N'Payer', N'REMITTANCE_ADVICE', N'Remittance Advice'),
    (4,  N'Payer', N'DENIAL_LETTER', N'Denial Letter'),
    (5,  N'Payer', N'PAYER_POLICY', N'Payer Medical Policy'),
    (6,  N'Payer', N'PAYER_CORRESPONDENCE', N'Payer Correspondence'),

    (7,  N'Patient', N'PATIENT_REGISTRATION', N'Patient Registration Form'),
    (8,  N'Patient', N'INSURANCE_CARD', N'Patient Insurance Card'),
    (9,  N'Patient', N'PATIENT_ID', N'Patient Identification'),
    (10, N'Patient', N'PATIENT_CONSENT', N'Patient Consent Form'),
    (11, N'Patient', N'FINANCIAL_RESPONSIBILITY', N'Financial Responsibility Form'),
    (12, N'Patient', N'PATIENT_PAYMENT_RECEIPT', N'Patient Payment Receipt'),

    (13, N'Clinical', N'MEDICAL_RECORDS', N'Medical Records'),
    (14, N'Clinical', N'PHYSICIAN_NOTES', N'Physician / Progress Notes'),
    (15, N'Clinical', N'LAB_REPORT', N'Laboratory Report / Test Results'),
    (16, N'Clinical', N'REFERRAL', N'Referral'),
    (17, N'Clinical', N'PRESCRIPTION', N'Prescription'),
    (18, N'Clinical', N'PRIOR_AUTHORIZATION', N'Prior Authorization'),

    (19, N'Claims & Billing', N'CMS1500', N'CMS-1500 Claim Form'),
    (20, N'Claims & Billing', N'UB04', N'UB-04 Institutional Claim Form'),
    (21, N'Claims & Billing', N'ITEMIZED_BILL', N'Itemized Bill'),
    (22, N'Claims & Billing', N'CORRECTED_CLAIM', N'Corrected Claim'),
    (23, N'Claims & Billing', N'CLAIM_SUBMISSION_REPORT', N'Claim Submission Report'),
    (24, N'Claims & Billing', N'CLEARINGHOUSE_REJECTION', N'Clearinghouse Rejection Report'),

    (25, N'Denial Resolution', N'APPEAL_LETTER', N'Appeal Letter'),
    (26, N'Denial Resolution', N'RECONSIDERATION_REQUEST', N'Reconsideration Request'),
    (27, N'Denial Resolution', N'TIMELY_FILING_PROOF', N'Proof of Timely Filing'),
    (28, N'Denial Resolution', N'MEDICAL_RECORDS_REQUEST', N'Medical Records Request'),
    (29, N'Denial Resolution', N'PAYER_RESPONSE', N'Payer Appeal / Review Response'),

    (30, N'Payment & Adjustments', N'PAYMENT_POSTING_REPORT', N'Payment Posting Report'),
    (31, N'Payment & Adjustments', N'CREDIT_BALANCE_REPORT', N'Credit Balance Report'),
    (32, N'Payment & Adjustments', N'REFUND_DOCUMENT', N'Refund Request / Receipt'),
    (33, N'Payment & Adjustments', N'WRITEOFF_APPROVAL', N'Write-off Approval')
) AS src
(
    DocumentTypeID,
    DocumentCategory,
    DocumentTypeCode,
    DocumentTypeName
)
WHERE NOT EXISTS
(
    SELECT 1
    FROM dbo.ARDocumentTypeMaster AS existing
    WHERE existing.DocumentTypeCode = src.DocumentTypeCode
);
GO

PRINT 'AR Workbench document types (dbo.ARDocumentTypeMaster) ready.';
GO

/* =====================================================================
   dbo.LisDrillRowDef — additional lab seeds (Cert, Inh, Phi, PCR, RT, NW)
   ---------------------------------------------------------------------
   Run AFTER LabMetricsDashboard/SqlScripts/LisDrillRowDef.sql
   (table + Cove/BT/Aug/Elix seeds). Deploy into each lab DB.
   ===================================================================== */

-- Idempotent widen before INSERTs (Op may still be NVARCHAR(10) if only
-- this script is re-run). Longest seed ops: MISMATCH|NOT IN (14), MISMATCH|IN (12).
IF OBJECT_ID('dbo.LisDrillRowDef', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'Op1' AND max_length < 64)
        ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Op1 NVARCHAR(32) NULL;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'Op2' AND max_length < 64)
        ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Op2 NVARCHAR(32) NULL;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'Op3' AND max_length < 64)
        ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Op3 NVARCHAR(32) NULL;
    IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'Op4' AND max_length < 64)
        ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Op4 NVARCHAR(32) NULL;
END
GO

/* ---------------------------------------------------------------------
   Certus (Cert) — 19_Certus LIS_Alt / 20 DetailRows / Aggregate PMS
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Cert' AND ISNULL(Source, N'LIS') = N'LIS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3)
VALUES
 (N'Cert', N'A',   N'Total Samples',                N'ReqCollectDate', N'LIS', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'B',   N'Billable Samples',             N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Insurance Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'C',   N'Billed',                       N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Insurance Bill', N'BillingStatus',N'=',N'Billed', NULL,NULL,NULL),
 (N'Cert', N'D',   N'Unbilled',                     N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Insurance Bill', N'BillingStatus',N'=',N'Not Billed', NULL,NULL,NULL),
 (N'Cert', N'D.1', N'Claim Entered in Daqbilling',  N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Insurance Bill', N'BillingStatus',N'=',N'Not Billed', N'FinalStatus',N'=',N'Claim Entered in Daqbilling'),
 (N'Cert', N'D.2', N'Resulted yet to be billed',    N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Insurance Bill', N'BillingStatus',N'=',N'Not Billed', N'FinalStatus',N'=',N'Resulted yet to be billed'),
 (N'Cert', N'D.3', N'D/L Isomer',                   N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Insurance Bill', N'BillingStatus',N'=',N'Not Billed', N'FinalStatus',N'=',N'D/L Isomer'),
 (N'Cert', N'E',   N'Other Samples',                N'ReqCollectDate', N'LIS', N'BillTo',N'<>',N'Insurance Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'E.1', N'Duplicate',                    N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Duplicate', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'E.2', N'Client Bill',                  N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Client Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'E.3', N'Yet to be Validated',          N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Yet to be Validated', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'E.4', N'Selfpay',                      N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Selfpay', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'E.5', N'Rejection',                    N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'Rejection', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'E.6', N'System Test',                  N'ReqCollectDate', N'LIS', N'BillTo',N'=',N'System Test', NULL,NULL,NULL, NULL,NULL,NULL);
GO

DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Cert' AND ISNULL(Source, N'LIS') = N'PMS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2,
     Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals)
VALUES
 (N'Cert', N'F',   N'No. of Billed Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'NOT IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'G',   N'Unbilled Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 -- H: ES = PMS billed (NOT IN Unbilled) − LIS Billed. Pipe keeps NOT IN on PMS side.
 (N'Cert', N'H',   N'Billed Mismatches - Other Samples Billed', N'DateofService', N'PMS',
     N'ClaimStatus', N'MISMATCH|NOT IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'I',   N'No. of Fully Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL,
     N'Billed (Claims)', N'ClaimStatus', N'Fully Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'J',   N'No. of Patient Responsibility Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Patient Responsibility', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'K',   N'No. of Patient Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Patient Payment', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'L',   N'No. of Adjusted/Written Off Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Adjusted', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'M',   N'Test Patients', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Test Patient', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'N',   N'No. of Partially Adjusted Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Adjusted', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'O',   N'No. of Partially Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'P',   N'No. of Insurance Balance Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'Denied,No Response,Partially Denied', NULL,NULL,NULL,
     N'Denied', N'ClaimStatus', N'Denied',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied',
     N'No Response', N'ClaimStatus', N'No Response'),
 (N'Cert', N'P.1', N'No. of Fully Denied Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Denied', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'P.2', N'No. of Partially Denied Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Denied', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'P.3', N'No. of No Response from Payor Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   Inhealth (Inh) — 26/27 LIS + 28 PMSCash. DateCol prefers ReqCollectDate.
   NA blank checks use Op '=' / '<>' with empty Val.
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Inh' AND ISNULL(Source, N'LIS') = N'LIS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3)
VALUES
 (N'Inh', N'A',   N'Total Samples',   N'ReqCollectDate', N'LIS', N'NA',N'<>',N'', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'B',   N'Billable Samples',N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', NULL,NULL,NULL),
 (N'Inh', N'C',   N'Billed',          N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Billed'),
 (N'Inh', N'D',   N'Unbilled',        N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed'),
 (N'Inh', N'E',   N'Other Samples',   N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Other Samples', NULL,NULL,NULL),
 (N'Inh', N'E.1', N'Other Samples Billed', N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Other Samples', N'BillCategory',N'=',N'Billed'),
 (N'Inh', N'E.2', N'Other Samples Not Billed', N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Other Samples', N'BillCategory',N'=',N'Not Billed'),
 (N'Inh', N'E.4', N'Self Pay',        N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Self Pay', NULL,NULL,NULL),
 (N'Inh', N'E.5', N'Deleted/Rejected',N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Deleted/Rejected', NULL,NULL,NULL),
 (N'Inh', N'E.6', N'Duplicate',       N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Duplicate', NULL,NULL,NULL),
 (N'Inh', N'E.7', N'System Test',     N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'System Test', NULL,NULL,NULL);
GO
-- Inh sub-rows that need Col4 (NA + SampleStatus + BillCategory + SubStatus)
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Inh' AND Source = N'LIS' AND RowCode IN (N'C.1',N'D.1',N'D.2',N'D.3',N'D.4',N'D.5',N'D.6');
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'Inh', N'C.1', N'Billed Via AMD',  N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Billed', N'SubStatus',N'=',N'Billed Via AMD'),
 (N'Inh', N'D.1', N'Nexum_Claim_scrubber_Eligibility', N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Nexum_Claim_scrubber_Eligibility'),
 (N'Inh', N'D.2', N'Requires Review', N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Requires Review'),
 (N'Inh', N'D.3', N'Entered in AMD but not billed', N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Entered in AMD but not billed'),
 (N'Inh', N'D.4', N'Nexum Pre Processing Queue', N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Nexum Pre Processing Queue'),
 (N'Inh', N'D.5', N'Nexum_Claim_scrubber_AMD Output', N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Nexum_Claim_scrubber_AMD Output'),
 (N'Inh', N'D.6', N'Nexum_Claim_scrubber_Diagnosis Validity', N'ReqCollectDate', N'LIS', N'NA',N'=',N'', N'SampleStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Nexum_Claim_scrubber_Diagnosis Validity');
GO

DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Inh' AND ISNULL(Source, N'LIS') = N'PMS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2,
     Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals)
VALUES
 (N'Inh', N'F',   N'No. of Billed Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'G',   N'Billed Mismatches', N'DateofService', N'PMS',
     N'BillStatus', N'MISMATCH', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'H',   N'No. of UnBilled Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Unbilled', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'H.1', N'Unbilled', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Unbilled', N'ClaimStatus', N'=', N'Unbilled',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'H.2', N'Unbilled - Patient Balance', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Unbilled', N'ClaimStatus', N'=', N'Unbilled - Patient Balance',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'I',   N'No. of Fully Paid Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid',
     N'Billed (Claims)', N'BillStatus', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'J',   N'No. of Patient Responsibility', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Responsibility',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'K',   N'No. of Fully Adjusted Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Complete W/O',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'L',   N'No. of Partially Adjusted Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Adjusted',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'M',   N'No. of Patient Payments Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Payment',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'N',   N'No. of Partially Paid Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'O',   N'No. of Insurance Balance Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'IN', N'FullyDenied,Partially Denied,No Response',
     N'FullyDenied', N'ClaimStatus', N'FullyDenied',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied',
     N'No Response', N'ClaimStatus', N'No Response'),
 (N'Inh', N'O.1', N'No. of Denied Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'FullyDenied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'O.2', N'No. of Partially Denied Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'O.3', N'No. of No Response from Payor', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   PhiLife (Phi) — 19/20 LIS + 21 PMSCash (BT-like structure)
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Phi' AND ISNULL(Source, N'LIS') = N'LIS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'Phi', N'A',   N'Total Samples',               N'RequestCollectDate', N'LIS', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'B',   N'Billable Samples - Resulted', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'C',   N'Billed to Insurance',         N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Billed', N'ClientStatus',N'=',N'', NULL,NULL,NULL),
 (N'Phi', N'C.1', N'Billed In AMD',               N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Billed', N'ClientStatus',N'=',N'', NULL,NULL,NULL),
 (N'Phi', N'D',   N'Not Entered in AMD',          N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD', N'ClientStatus',N'IN',N'__BLANK__,Billing Review Required', N'PaymentMethod',N'=',N'Insurance'),
 (N'Phi', N'E',   N'Unbilled',                    N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'', N'ClaimStatus',N'=',N'Entered', NULL,NULL,NULL),
 (N'Phi', N'F',   N'Client Bill',                 N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Client Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'G',   N'Self Pay',                    N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Self Pay', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'H',   N'Test Entries',                N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Test Entries', N'PaymentMethod',N'<>',N'No Bill', NULL,NULL,NULL),
 (N'Phi', N'I',   N'Rejected Sample',             N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Rejected Sample', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'J',   N'PaymentMethod No Bill',       N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'No Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'K',   N'Not Resulted',                N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Not Resulted', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'L',   N'Not Entered in AMD',          N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Not Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD', N'ClientStatus',N'=',N'', N'PaymentMethod',N'=',N'Insurance'),
 (N'Phi', N'M',   N'Client Bill',                 N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Client Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'N',   N'Test Entries',                N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Test Entries', N'PaymentMethod',N'=',N'Insurance', NULL,NULL,NULL),
 (N'Phi', N'O',   N'Rejected Sample',             N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Rejected Sample', N'PaymentMethod',N'=',N'Insurance', NULL,NULL,NULL),
 (N'Phi', N'P',   N'PaymentMethod No Bill',       N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Not Resulted', N'PaymentMethod',N'=',N'No Bill', NULL,NULL,NULL, NULL,NULL,NULL);
GO

DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Phi' AND ISNULL(Source, N'LIS') = N'PMS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2,
     Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals)
VALUES
 (N'Phi', N'Q',   N'Billed - Includes all Claims Billed in AMD', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'R',   N'Billed Mismatches - Non Diagnose LIS Samples', N'DateofService', N'PMS',
     N'BilledUnbilled', N'MISMATCH', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'S',   N'Unbilled - Entered to AMD - Yet to be released to Payer', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Unbilled', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'T',   N'Fully Paid - Insurance Pay', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid',
     N'Billed (Claims)', N'BilledUnbilled', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'U',   N'Fully Adjusted (Complete W/O)', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Complete W/O',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'V',   N'Patient Responsibility', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Responsibility',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'W',   N'Partially Paid', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'X',   N'Patient Payment', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Payment',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'Y',   N'Insurance Balance', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Adjusted,Partially Denied',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied',
     N'No Response', N'ClaimStatus', N'No Response',
     N'Partially Denied', N'ClaimStatus', N'Partially Adjusted,Partially Denied'),
 (N'Phi', N'Y.1', N'Fully Denied', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'Y.2', N'No Response', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'Y.3', N'Partially Denied', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'IN', N'Partially Adjusted,Partially Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   PCR (PCR) — LIS A–I* + PMS I–P (Source in PK allows shared RoleID 'I')
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'PCR' AND ISNULL(Source, N'LIS') = N'LIS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'PCR', N'A',  N'Total Samples', N'RequestCollectDate', N'LIS', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'B',  N'Resulted', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'C',  N'Billed', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'', N'BilledorNot',N'=',N'Billed', NULL,NULL,NULL),
 (N'PCR', N'D',  N'Client Bill', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Client Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'D1', N'Billed', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Client Bill', N'BilledorNot',N'=',N'Billed', NULL,NULL,NULL),
 (N'PCR', N'D2', N'Not Entered in AMD', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Client Bill', N'BilledorNot',N'=',N'Unbilled', N'ClaimStatus',N'=',N'Not Entered in AMD'),
 (N'PCR', N'D3', N'Entered', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Client Bill', N'BilledorNot',N'=',N'Unbilled', N'ClaimStatus',N'=',N'Entered'),
 (N'PCR', N'E',  N'Not Entered in AMD', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'IN',N'__BLANK__,Billing Review Required', N'ClaimStatus',N'=',N'Not Entered in AMD', NULL,NULL,NULL),
 (N'PCR', N'F',  N'Unbilled - Not Released to Payer (EDI Hold)', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'', N'BilledorNot',N'=',N'Unbilled', N'ClaimStatus',N'=',N'Entered'),
 (N'PCR', N'G',  N'Test Entries', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Test Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'H',  N'Rejected Sample', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Rejected Sample', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'I',  N'Not Resulted', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'<>',N'Resulted', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'I1', N'Not Entered in AMD', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'<>',N'Resulted', N'ClientStatus',N'=',N'', N'BilledorNot',N'=',N'Unbilled', N'ClaimStatus',N'=',N'Not Entered in AMD'),
 (N'PCR', N'I2', N'Client Bill', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'<>',N'Resulted', N'ClientStatus',N'=',N'Client Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'I3', N'Test Entries', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'<>',N'Resulted', N'ClientStatus',N'=',N'Test Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'I4', N'Rejected Sample', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'<>',N'Resulted', N'ClientStatus',N'=',N'Rejected Sample', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'I5', N'Self Pay', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'<>',N'Resulted', N'ClientStatus',N'=',N'Self Pay', NULL,NULL,NULL, NULL,NULL,NULL);
GO

DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'PCR' AND ISNULL(Source, N'LIS') = N'PMS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2,
     Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals)
VALUES
 (N'PCR', N'I',   N'Billed - Includes all Claims Billed in AMD', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'J',   N'Billed Mismatch', N'DateofService', N'PMS',
     N'BilledUnbilled', N'MISMATCH', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'K',   N'Unbilled - Entered in AMD - Yet to be released to Payer', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Unbilled', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'L',   N'Fully Paid - Insurance Pay', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid',
     N'Billed (Claims)', N'BilledUnbilled', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'M',   N'Complete W/O', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Complete W/O',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'N',   N'Patient Responsibility', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Responsibility',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'O',   N'Partially Paid', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'P',   N'Insurance Balance', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Adjusted,Partially Denied',
     N'No Response', N'ClaimStatus', N'No Response',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied',
     N'Partially Denied', N'ClaimStatus', N'Partially Adjusted,Partially Denied'),
 (N'PCR', N'P.1', N'No Response', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'P.2', N'Fully Denied', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'P.3', N'Partially Adjusted/Denied', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'IN', N'Partially Adjusted,Partially Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   RisingTides (RT) — file-27 L_* LIS scheme + PMS O–X / S Fully Paid
   LIMSMaster column is RessultedStatus (ResultedNot is an Alt alias).
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'RT' AND ISNULL(Source, N'LIS') = N'LIS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'RT', N'L_0',  N'Total Samples',               N'RequestCollectDate', N'LIS', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'L_A',  N'Billable Samples - Resulted', N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'L_A1', N'Billed to Insurance',         N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'Insurance', N'ClaimStatus',N'=',N'Billed', NULL,NULL,NULL),
 (N'RT', N'L_A1a',N'Billed In AMD',               N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'Insurance', N'ClaimStatus',N'=',N'Billed', N'BillingStatus',N'=',N'Billed'),
 (N'RT', N'L_A3', N'Unbilled',                    N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'Insurance', N'ClaimStatus',N'=',N'Entered', N'BillingStatus',N'<>',N'Billed'),
 (N'RT', N'L_A4', N'Client Bill',                 N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'Client Bill', N'ClientStatus',N'=',N'Client Bill', N'BillingStatus',N'=',N'Billed'),
 (N'RT', N'L_A5', N'Self Pay',                    N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'Self Pay', N'ClientStatus',N'=',N'Self Pay', N'BillingStatus',N'IN',N'Billed,Not Ready To Bill'),
 (N'RT', N'L_A6', N'Test Entries',                N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD', N'BillingStatus',N'<>',N'Billed', N'ClientStatus',N'=',N'Test Entries'),
 (N'RT', N'L_A7', N'Billing Status - No Bill',    N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Resulted', N'BillingStatus',N'=',N'No Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'L_B',  N'Not Resulted',                N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Not Resulted', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'L_B1', N'Not Entered in AMD',          N'RequestCollectDate', N'LIS', N'RessultedStatus',N'=',N'Not Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD', NULL,NULL,NULL, NULL,NULL,NULL);
GO

DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'RT' AND ISNULL(Source, N'LIS') = N'PMS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2,
     Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals)
VALUES
 (N'RT', N'O', N'Billed - Includes all Claims Billed in AMD', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'P', N'Billed Mismatches', N'DateofService', N'PMS',
     N'BilledUnbilled', N'MISMATCH', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'Q', N'Unbilled', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Unbilled', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'S', N'Fully Paid - Insurance Pay', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid',
     N'Billed (Claims)', N'BilledUnbilled', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'T', N'Fully Adjusted', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Complete W/O',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'U', N'Patient Responsibility', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Responsibility',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'V', N'Partially Paid', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'X', N'Patient Payment', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Payment',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'W', N'Insurance Balance', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Denied',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied',
     N'No Response', N'ClaimStatus', N'No Response',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied'),
 (N'RT', N'W1', N'Fully Denied', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'W2', N'No Response', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'W3', N'Partially Denied', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   NorthWest (NW) — 33/34 LIS + 35 PMSCash. C = Billed (Insurance Bill).
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'NW' AND ISNULL(Source, N'LIS') = N'LIS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'NW', N'A',   N'Total Samples',     N'ReqCollectDate', N'LIS', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'B',   N'Billable Samples',  N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Insurance Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'C',   N'Billed',            N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Insurance Bill', N'BillStatus',N'=',N'Billed', NULL,NULL,NULL),
 (N'NW', N'C.1', N'Claim Submitted in Webpm', N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Insurance Bill', N'BillStatus',N'=',N'Billed', N'FinalStatus',N'=',N'Claim Submitted in Webpm'),
 (N'NW', N'C.2', N'Claim Submitted in Daqbilling', N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Insurance Bill', N'BillStatus',N'=',N'Billed', N'FinalStatus',N'=',N'Claim Submitted in Daqbilling'),
 (N'NW', N'D',   N'Unbilled',          N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Insurance Bill', N'BillStatus',N'=',N'Unbilled', NULL,NULL,NULL),
 (N'NW', N'E',   N'ADCS Claims',       N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'ADCS Claims', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'F',   N'Other Samples',     N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'NOT IN',N'Insurance Bill,ADCS Claims', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'F.1', N'Yet to be validate', N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Yet to be validate', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'F.2', N'Self pay',          N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Self pay', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'F.3', N'Client Bills',      N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Client Bills', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'F.4', N'System Test',       N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'System Test', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'F.5', N'Rejections',        N'ReqCollectDate', N'LIS', N'IncorrectDOS',N'=',N'', N'BilledTo',N'=',N'Rejections', NULL,NULL,NULL, NULL,NULL,NULL);
GO

DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'NW' AND ISNULL(Source, N'LIS') = N'PMS';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3,
     Sec1Name,Sec1Col,Sec1Vals, Sec2Name,Sec2Col,Sec2Vals, Sec3Name,Sec3Col,Sec3Vals)
VALUES
 -- G: ES derives Billed from FirstBilledDate/EmedixSubmissionDate; drill uses FirstBilledDate populated
 --    + ClaimStatus <> Billed Amount 0 + ClaimType exclude (matches Aggregate predicate intent)
 (N'NW', N'G', N'Billed Claims', N'DateofService', N'PMS',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed Amount 0', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'H', N'Unbilled Claims', N'DateofService', N'PMS',
     N'FirstBilledDate', N'=', N'', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'I', N'Billed Mismatches', N'DateofService', N'PMS',
     N'FirstBilledDate', N'MISMATCH|<>', N'', N'ClaimStatus', N'<>', N'Billed Amount 0', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'J', N'Test Patient Entries', N'DateofService', N'PMS',
     N'ClaimType', N'=', N'Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'K', N'ADCS Claims', N'DateofService', N'PMS',
     N'ClaimType', N'=', N'ADCS - Invoice', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'M', N'No. of Fully Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'N', N'Fully Patient Responsibility', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Pat Responsibility', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'O', N'Adjusted/Written Off', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Adjusted', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'P', N'Partially Adjusted Claim', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Adjusted', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'Q', N'Partially Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'R', N'Patient Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Patient Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'S', N'Insurance Balance Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,No Response', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     N'Fully Denied', N'ClaimStatus', N'Fully Denied',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied',
     N'No Response', N'ClaimStatus', N'No Response'),
 (N'NW', N'S.1', N'Fully Denied', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Denied', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'S.2', N'Partially Denied', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Denied', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'S.3', N'No Response', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'No Response', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

PRINT 'LisDrillRowDef_OtherLabs.sql completed. Run LisDrillRowDef_Cash.sql for Cash Breakdown drill seeds.';
GO

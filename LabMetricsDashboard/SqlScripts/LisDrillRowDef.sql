/* =====================================================================
   dbo.LisDrillRowDef  — per-lab LIS Breakdown row → drill filter mapping
   ---------------------------------------------------------------------
   Each row a user can drill into (Total Samples, Billable, Billed,
   Unbilled/Not Billed, sub-statuses, Other Samples, …) is one row here.
   The drill controller reads (LabPrefix, RowCode) and passes the compound
   filter (up to 3 column/op/value AND-conditions) + date column to
   dbo.usp_GetExecutiveSummaryDetail_LisDrill_Core.

   Derived from each lab's usp_Refresh<Lab>_ExecutiveSummary_LIS_Alt so the
   drill uses the same definition the Executive Summary uses. Op is '=',
   '<>', 'LIKE', or 'NOT LIKE'. A row with no conditions (Col1 NULL) means
   "all samples" (Total).

   Deploy this table + seed into each lab DB (only that lab's rows are used).
   ===================================================================== */
IF OBJECT_ID('dbo.LisDrillRowDef', 'U') IS NULL
CREATE TABLE dbo.LisDrillRowDef
(
    LabPrefix NVARCHAR(20)  NOT NULL,
    RowCode   NVARCHAR(40)  NOT NULL,
    RowTitle  NVARCHAR(200) NOT NULL,
    DateCol   NVARCHAR(128) NULL,
    Col1 NVARCHAR(128) NULL, Op1 NVARCHAR(32) NULL, Val1 NVARCHAR(200) NULL,
    Col2 NVARCHAR(128) NULL, Op2 NVARCHAR(32) NULL, Val2 NVARCHAR(200) NULL,
    Col3 NVARCHAR(128) NULL, Op3 NVARCHAR(32) NULL, Val3 NVARCHAR(200) NULL,
    Col4 NVARCHAR(128) NULL, Op4 NVARCHAR(32) NULL, Val4 NVARCHAR(200) NULL,
    -- Source: 'LIS' | 'PMS' | 'Cash' (ClaimLevelData dollar SUM via AmountCol).
    Source   NVARCHAR(4)   NOT NULL CONSTRAINT DF_LisDrillRowDef_Source DEFAULT (N'LIS'),
    -- Cash: column to SUM (ChargeAmount, InsurancePayment, … or A+B compound).
    AmountCol NVARCHAR(200) NULL,
    Sec1Name NVARCHAR(200) NULL, Sec1Col NVARCHAR(128) NULL, Sec1Vals NVARCHAR(MAX) NULL,
    Sec2Name NVARCHAR(200) NULL, Sec2Col NVARCHAR(128) NULL, Sec2Vals NVARCHAR(MAX) NULL,
    Sec3Name NVARCHAR(200) NULL, Sec3Col NVARCHAR(128) NULL, Sec3Vals NVARCHAR(MAX) NULL,
    CONSTRAINT PK_LisDrillRowDef PRIMARY KEY (LabPrefix, RowCode, Source)
);
GO
-- Add later columns if the table pre-existed.
IF COL_LENGTH('dbo.LisDrillRowDef','Col4')     IS NULL ALTER TABLE dbo.LisDrillRowDef ADD Col4 NVARCHAR(128) NULL;
IF COL_LENGTH('dbo.LisDrillRowDef','Op4')      IS NULL ALTER TABLE dbo.LisDrillRowDef ADD Op4  NVARCHAR(32)  NULL;
IF COL_LENGTH('dbo.LisDrillRowDef','Val4')     IS NULL ALTER TABLE dbo.LisDrillRowDef ADD Val4 NVARCHAR(200) NULL;
IF COL_LENGTH('dbo.LisDrillRowDef','Source')   IS NULL ALTER TABLE dbo.LisDrillRowDef ADD Source   NVARCHAR(4)   NULL;
-- Cash drill: money column to SUM (single name or A+B). NULL for LIS/PMS count rows.
IF COL_LENGTH('dbo.LisDrillRowDef','AmountCol') IS NULL ALTER TABLE dbo.LisDrillRowDef ADD AmountCol NVARCHAR(200) NULL;
IF COL_LENGTH('dbo.LisDrillRowDef','Sec1Name') IS NULL ALTER TABLE dbo.LisDrillRowDef ADD Sec1Name NVARCHAR(200) NULL, Sec1Col NVARCHAR(128) NULL, Sec1Vals NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LisDrillRowDef','Sec2Name') IS NULL ALTER TABLE dbo.LisDrillRowDef ADD Sec2Name NVARCHAR(200) NULL, Sec2Col NVARCHAR(128) NULL, Sec2Vals NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.LisDrillRowDef','Sec3Name') IS NULL ALTER TABLE dbo.LisDrillRowDef ADD Sec3Name NVARCHAR(200) NULL, Sec3Col NVARCHAR(128) NULL, Sec3Vals NVARCHAR(MAX) NULL;
GO
-- Newly added columns are only visible to later batches (compile boundary).
-- Widen ops so values like MISMATCH / MISMATCH|NOT IN / MISMATCH|IN fit
-- (legacy was NVARCHAR(2)/NVARCHAR(10); truncated display showed MISMATCH|N).
-- sys.columns.max_length is bytes: NVARCHAR(32) => 64.
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'Op1' AND max_length < 64)
    ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Op1 NVARCHAR(32) NULL;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'Op2' AND max_length < 64)
    ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Op2 NVARCHAR(32) NULL;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'Op3' AND max_length < 64)
    ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Op3 NVARCHAR(32) NULL;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'Op4' AND max_length < 64)
    ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Op4 NVARCHAR(32) NULL;
-- Source is part of the PK so LIS+PMS can share a RoleID (e.g. PCR 'I').
UPDATE dbo.LisDrillRowDef SET Source = N'LIS' WHERE Source IS NULL OR LTRIM(RTRIM(Source)) = N'';
IF NOT EXISTS (
    SELECT 1 FROM sys.default_constraints
    WHERE parent_object_id = OBJECT_ID('dbo.LisDrillRowDef')
      AND COL_NAME(parent_object_id, parent_column_id) = 'Source')
    ALTER TABLE dbo.LisDrillRowDef ADD CONSTRAINT DF_LisDrillRowDef_Source DEFAULT (N'LIS') FOR Source;
IF EXISTS (
    SELECT 1 FROM sys.key_constraints
    WHERE parent_object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'PK_LisDrillRowDef')
BEGIN
    DECLARE @pkCols NVARCHAR(200) = (
        SELECT STRING_AGG(c.name, ',') WITHIN GROUP (ORDER BY ic.key_ordinal)
        FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = OBJECT_ID('dbo.LisDrillRowDef')
          AND ic.index_id = (SELECT unique_index_id FROM sys.key_constraints
                             WHERE parent_object_id = OBJECT_ID('dbo.LisDrillRowDef') AND name = 'PK_LisDrillRowDef'));
    IF @pkCols IS NULL OR @pkCols NOT LIKE '%Source%'
    BEGIN
        ALTER TABLE dbo.LisDrillRowDef DROP CONSTRAINT PK_LisDrillRowDef;
        ALTER TABLE dbo.LisDrillRowDef ALTER COLUMN Source NVARCHAR(4) NOT NULL;
        ALTER TABLE dbo.LisDrillRowDef ADD CONSTRAINT PK_LisDrillRowDef PRIMARY KEY (LabPrefix, RowCode, Source);
    END
END
GO

/* ---------------------------------------------------------------------
   Cove — from usp_RefreshCove_ExecutiveSummary_LIS_Alt
     A  Total Samples          (all)
     B  Billable Samples       NewStatus='Billable'
     C  Billed                 B AND BillCategory='Billed'
     D  Not Billed             B AND BillCategory='Not Billed'
     D.1..D.20  sub-status      D AND SubStatus='<value>'
     E  Other Samples          NewStatus<>'Billable'
     E.1..E.7  by NewStatus     NewStatus='<value>'
   Bucket date: DateOfCollection.
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Cove' AND ISNULL(Source, N'LIS') = N'LIS';

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3)
VALUES
 (N'Cove', N'A',    N'Total Samples',   N'DateOfCollection', NULL,        NULL, NULL,        NULL,          NULL, NULL,          NULL, NULL, NULL),
 (N'Cove', N'B',    N'Billable Samples',N'DateOfCollection', N'NewStatus',N'=', N'Billable', NULL,          NULL, NULL,          NULL, NULL, NULL),
 (N'Cove', N'C',    N'Billed',          N'DateOfCollection', N'NewStatus',N'=', N'Billable', N'BillCategory',N'=',N'Billed',     NULL, NULL, NULL),
 (N'Cove', N'D',    N'Not Billed',      N'DateOfCollection', N'NewStatus',N'=', N'Billable', N'BillCategory',N'=',N'Not Billed', NULL, NULL, NULL),
 (N'Cove', N'D.1',  N'Billed Insurance In Covedx',        N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Billed Insurance In Covedx'),
 (N'Cove', N'D.2',  N'Billed In Variantx Lab',            N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Billed In Variantx Lab'),
 (N'Cove', N'D.3',  N'Billed In Elixir Dx',               N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Billed In Elixir Dx'),
 (N'Cove', N'D.4',  N'Ignored - Duplicate Accession',     N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ignored - Duplicate Accession'),
 (N'Cove', N'D.5',  N'Coding exception',                  N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Coding exception'),
 (N'Cove', N'D.6',  N'CP Exception',                      N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'CP Exception'),
 (N'Cove', N'D.7',  N'In process',                        N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'In process'),
 (N'Cove', N'D.8',  N'Ignored - Client Response Non Billiable', N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ignored - Client Response Non Billiable'),
 (N'Cove', N'D.9',  N'Ready To Bill',                     N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ready To Bill'),
 (N'Cove', N'D.10', N'Ignored - NGS & PGX in Cove',       N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ignored - NGS & PGX in Cove'),
 (N'Cove', N'D.11', N'CP Exception -In Review',           N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'CP Exception -In Review'),
 (N'Cove', N'D.12', N'Medicaid Credentialling In Process',N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Medicaid Credentialling In Process'),
 (N'Cove', N'D.13', N'Ignored - Reported in Elixir Truemed', N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ignored - Reported in Elixir Truemed'),
 (N'Cove', N'D.14', N'Ignored - CP Exception',            N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ignored - CP Exception'),
 (N'Cove', N'D.15', N'Client Bill Cases',                 N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Client Bill Cases'),
 (N'Cove', N'D.16', N'Ignored - Client Response Pure Selfpay', N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ignored - Client Response Pure Selfpay'),
 (N'Cove', N'D.17', N'Selfpay',                           N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Selfpay'),
 (N'Cove', N'D.18', N'Ignored - Rejected Accession',      N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ignored - Rejected Accession'),
 (N'Cove', N'D.19', N'Hold-Amerihealth Lousiana',         N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Hold-Amerihealth Lousiana'),
 (N'Cove', N'D.20', N'Ignored - Test Cases',              N'DateOfCollection', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'SubStatus',N'=',N'Ignored - Test Cases'),
 (N'Cove', N'E',    N'Other Samples',   N'DateOfCollection', N'NewStatus',N'<>',N'Billable', NULL, NULL, NULL, NULL, NULL, NULL),
 (N'Cove', N'E.1',  N'Self Pay',                N'DateOfCollection', N'NewStatus',N'=',N'Self Pay',              NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'E.2',  N'Client Bill',             N'DateOfCollection', N'NewStatus',N'=',N'Client Bill',           NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'E.3',  N'Deleted / Rejected',      N'DateOfCollection', N'NewStatus',N'=',N'Deleted / Rejected',    NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'E.4',  N'System Test',             N'DateOfCollection', N'NewStatus',N'=',N'System Test',           NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'E.5',  N'Ref Lab - Bill Patient',  N'DateOfCollection', N'NewStatus',N'=',N'Ref Lab - Bill Patient',NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'E.6',  N'Missing Accession',       N'DateOfCollection', N'NewStatus',N'=',N'Missing Accession',     NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'E.7',  N'Yet To Be Validated',     N'DateOfCollection', N'NewStatus',N'=',N'Yet To Be Validated',   NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   BeechTree (BT) — from usp_RefreshBT_ExecutiveSummary_LIS_Alt.
     A   Total Samples                (all)
     B   Billable Samples - Resulted  RessultedStatus='Resulted'
       B2 Billed to Insurance         + ClaimStatus='Billed' + BilledOrNot='Billed' + ClientStatus=''
       B3 Not Entered in AMD          + ClaimStatus='Not Entered in AMD' + BilledOrNot='UnBilled'
       B4 Unbilled                    + ClaimStatus='Entered' + BilledOrNot='UnBilled' + ClientStatus=''
       B5 Client Bill / B6 Self Pay / B7 Test Entries / B8 Rejected Sample  (+ ClientStatus=..)
       B9 Payment Method No Bill      + PaymentMethod='No Bill'
     C   Not Resulted                 RessultedStatus='Not Resulted'
       C1 No Result date but Billed / C2 Not Entered in AMD / C3 Client Bill / C4 Self Pay
         C4.1 Not Entered in AMD      + ClientStatus='Self Pay' + ClaimStatus='Not Entered in AMD' + BilledOrNot='UnBilled'
         C4.2 Billed                  + ClientStatus='Self Pay' + BilledOrNot='Billed'
     D   Test Entries                 Not Resulted + ClientStatus='Test Entries'
     E   Rejected Sample              Not Resulted + ClientStatus='Rejected Sample'
   Bucket date: RequestCollectDate.
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'BT' AND ISNULL(Source, N'LIS') = N'LIS';

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'BT', N'A',  N'Total Samples',               N'RequestCollectDate', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'B',  N'Billable Samples - Resulted', N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'B2', N'Billed to Insurance',         N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Billed',             N'BilledOrNot',N'=',N'Billed',   N'ClientStatus',N'=',N''),
 (N'BT', N'B3', N'Not Entered in AMD',          N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD', N'BilledOrNot',N'=',N'UnBilled', N'ClientStatus',N'IN',N'__BLANK__,Billing Review Required'),
 (N'BT', N'B4', N'Unbilled',                    N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', N'ClaimStatus',N'=',N'Entered',            N'BilledOrNot',N'=',N'UnBilled', N'ClientStatus',N'=',N''),
 (N'BT', N'B5', N'Client Bill',                 N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Client Bill',       NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'B6', N'Self Pay',                    N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Self Pay',          NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'B7', N'Test Entries',                N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Test Entries',      NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'B8', N'Rejected Sample',             N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', N'ClientStatus',N'=',N'Rejected Sample',   NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'B9', N'Payment Method No Bill',      N'RequestCollectDate', N'RessultedStatus',N'=',N'Resulted', N'PaymentMethod',N'=',N'No Bill',          NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'C',  N'Not Resulted',                N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'C1', N'No Result date on LIS but Billed', N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', N'ClaimStatus',N'=',N'Billed',             N'BilledOrNot',N'=',N'Billed',   N'ClientStatus',N'=',N''),
 (N'BT', N'C2', N'Not Entered in AMD',          N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', N'ClaimStatus',N'=',N'Not Entered in AMD', N'BilledOrNot',N'=',N'UnBilled', N'ClientStatus',N'=',N''),
 (N'BT', N'C3', N'Client Bill',                 N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Client Bill',       NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'C4', N'Self Pay',                    N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Self Pay',          NULL,NULL,NULL, NULL,NULL,NULL),
 -- C4.1 / C4.2: match 19_BeechTree_ExecutiveSummary_LIS_Alt (Self Pay sub-rows)
 (N'BT', N'C4.1', N'Not Entered in AMD',        N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Self Pay', N'ClaimStatus',N'=',N'Not Entered in AMD', N'BilledOrNot',N'=',N'UnBilled'),
 (N'BT', N'C4.2', N'Billed',                    N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Self Pay', N'BilledOrNot',N'=',N'Billed', NULL,NULL,NULL),
 (N'BT', N'D',  N'Test Entries',                N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Test Entries',      NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'E',  N'Rejected Sample',             N'RequestCollectDate', N'RessultedStatus',N'=',N'Not Resulted', N'ClientStatus',N'=',N'Rejected Sample',   NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   BeechTree (BT) — PMS Breakdown (ClaimLevelData, bucket DateofService).
   Predicates match 16_BeechTree_ExecutiveSummary_Aggregate.sql /
   21_BeechTree_ExecutiveSummaryDetailRows_PMSCash.sql:
     R    BilledUnbilled = 'Billed'
     S    ES formula PMS Billed − LIS Billed (Op=MISMATCH). Drill KPIs from ES grid.
     T    BilledUnbilled = 'UnBilled'
     U    ClaimStatus = 'Fully Paid'  (+ Sec1 = Billed denominator for rate)
     V/W/X ClaimStatus = Complete W/O / Pat Responsibility / Partial Paid
                          (V Fully Adjusted = Billed + Complete W/O — same as
                           usp_RefreshBT_ExecutiveSummary; NOT ClaimStatus='Fully Adjusted')
     Y    PatientPayment > 0   ← NOT ClaimStatus (aggregate uses amount)
     Z    ClaimStatus IN (Fully Denied, No Response, Partially Denied) + Z.1/Z.2/Z.3 secs
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'BT' AND ISNULL(Source, N'LIS') = N'PMS';

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source,
     Col1, Op1, Val1, Col2, Op2, Val2,
     Sec1Name, Sec1Col, Sec1Vals, Sec2Name, Sec2Col, Sec2Vals, Sec3Name, Sec3Col, Sec3Vals)
VALUES
 (N'BT', N'R',   N'Billed - Includes all Claims Billed in AMD', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 -- S: ES grid = PMS Billed − LIS Billed (count difference). Drill uses Op=MISMATCH
 --    (billed claims whose accession is not billed in LIMSMaster) — not ClaimStatus.
 (N'BT', N'S',   N'Billed Mismatches - Non Diagnose LIS Samples', N'DateofService', N'PMS',
     N'BilledUnbilled', N'MISMATCH', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'T',   N'Unbilled - Entered to AMD - Yet to be released to Payer', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'UnBilled', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'U',   N'Fully Paid - Insurance Pay', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL,
     N'Billed (Claims)', N'BilledUnbilled', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'V',   N'Fully Adjusted', N'DateofService', N'PMS',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Complete W/O',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'W',   N'Patient Responsibility', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Pat Responsibility', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'X',   N'Partially Paid', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partial Paid', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'Y',   N'Patient Payment', N'DateofService', N'PMS',
     N'PatientPayment', N'>', N'0', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'Z',   N'Insurance Balance', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Denied', NULL,NULL,NULL,
     N'Fully Denied',     N'ClaimStatus', N'Fully Denied',
     N'No Response',      N'ClaimStatus', N'No Response',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied'),
 (N'BT', N'Z.1', N'Fully Denied', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'Z.2', N'No Response', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'Z.3', N'Partially Denied', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Denied', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* =====================================================================
   Insurance Balance ($) — dollar SUM(InsuranceBalance), stacked by the
   lab's own Fully Denied / Partially Denied / No Response split.
   Source='Cash', AmountCol='InsuranceBalance'; parent filter = union of the
   three buckets (so the parent bar equals the stack). ClaimStatus values are
   per each lab's ..._ExecutiveSummary_Aggregate.sql.
   NOTE: for Elixir/PhiLife/InHealth/NorthWest the aggregate buckets also
   require BilledUnbilled/BillStatus='Billed'; that condition is dropped here
   (a denial status implies billed) — verify against the summary $ totals.
   ===================================================================== */
-- Clear IB ($) Cash rows, plus any prior BT mis-seeds (AJ was Patient WO in
-- an older Cash.sql; AK* collided with Avg RoleIDs). Safe to re-run.
DELETE FROM dbo.LisDrillRowDef
WHERE Source = N'Cash'
  AND (
        RowTitle = N'Insurance Balance ($)'
     OR (LabPrefix = N'BT' AND RowCode IN (N'AI', N'AJ', N'AJ.1', N'AJ.2', N'AJ.3', N'AK', N'AK1', N'AK2', N'AK3'))
  );

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1,
     Sec1Name, Sec1Col, Sec1Vals, Sec2Name, Sec2Col, Sec2Vals, Sec3Name, Sec3Col, Sec3Vals)
VALUES
 (N'Aug',  N'X',  N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,No Response',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied', N'Partially Denied', N'ClaimStatus', N'Partially Denied', N'No Response', N'ClaimStatus', N'No Response'),
 (N'BT',   N'AJ', N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,No Response',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied', N'Partially Denied', N'ClaimStatus', N'Partially Denied', N'No Response', N'ClaimStatus', N'No Response'),
 (N'Cert', N'X',  N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Denied,Partially Denied,No Response',
     N'Fully Denied', N'ClaimStatus', N'Denied', N'Partially Denied', N'ClaimStatus', N'Partially Denied', N'No Response', N'ClaimStatus', N'No Response'),
 (N'Cove', N'U',  N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,Partially Adjusted,Partially Paid,Patient Payment,Patient Responsibility,No Response,No Response-Client',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied,Partially Adjusted,Partially Paid,Patient Payment,Patient Responsibility',
     N'No Response', N'ClaimStatus', N'No Response,No Response-Client'),
 (N'Elix', N'X',  N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Denied,Partially Denied,Partially Paid,Partially Adjusted,Patient Responsibility,No Response',
     N'Denials', N'ClaimStatus', N'Denied',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied,Partially Paid,Partially Adjusted,Patient Responsibility',
     N'No Response', N'ClaimStatus', N'No Response'),
 (N'Phi',  N'AI', N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,No Response',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied', N'Partially Denied', N'ClaimStatus', N'Partially Denied', N'No Response', N'ClaimStatus', N'No Response'),
 (N'RT',   N'AG', N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,No Response',
     N'Fully Denied', N'ClaimStatus', N'Fully Denied', N'Partially Denied', N'ClaimStatus', N'Partially Denied', N'No Response', N'ClaimStatus', N'No Response'),
 (N'Inh',  N'W',  N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'FullyDenied,Partially Denied,No Response',
     N'Denials', N'ClaimStatus', N'FullyDenied', N'Partially Denied', N'ClaimStatus', N'Partially Denied', N'No Response', N'ClaimStatus', N'No Response'),
 (N'NW',   N'AC', N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Fully Denied,No Response',
     N'Denials', N'ClaimStatus', N'Fully Denied', NULL, NULL, NULL, N'No Response', N'ClaimStatus', N'No Response'),
 (N'PCR',  N'Y',  N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,No Response',
     N'No Response', N'ClaimStatus', N'No Response', N'Fully Denied', N'ClaimStatus', N'Fully Denied', N'Partially Denied', N'ClaimStatus', N'Partially Denied');
GO

/* ---------------------------------------------------------------------
   Cove — PMS Breakdown (ClaimLevelData, DateofService).
   From 16_Cove_ExecutiveSummary_Aggregate.sql:
     F  BillStatus IN (Billed, Billed-Client, Billed - Client)
     G  MAX(0, F − LIS BillCategory='Billed') — Op MISMATCH|IN
     H  ClaimStatus IN (Fully Paid, Paid-Client)
     I..M  Patient Responsibility / Fully Adjusted / Partially Adjusted /
           Partially Paid / Patient Payment
     N    Insurance Balance (+ N.1 Fully Denied / N.2 Partially Denied /
          N.3 No Response(+Client))
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Cove' AND ISNULL(Source, N'LIS') = N'PMS';

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source,
     Col1, Op1, Val1, Col2, Op2, Val2,
     Sec1Name, Sec1Col, Sec1Vals, Sec2Name, Sec2Col, Sec2Vals, Sec3Name, Sec3Col, Sec3Vals)
VALUES
 (N'Cove', N'F',   N'Billed (Claims)', N'DateofService', N'PMS',
     N'BillStatus', N'IN', N'Billed,Billed-Client,Billed - Client', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 -- G: ES = MAX(0, PMS Billed − LIS Billed). Op MISMATCH|IN keeps the billed IN-list.
 (N'Cove', N'G',   N'Billed Mismatches', N'DateofService', N'PMS',
     N'BillStatus', N'MISMATCH|IN', N'Billed,Billed-Client,Billed - Client', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'H',   N'Fully Paid', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'Fully Paid,Paid-Client', NULL,NULL,NULL,
     N'Billed (Claims)', N'BillStatus', N'Billed,Billed-Client,Billed - Client', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'I',   N'Patient Responsibility', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Patient Responsibility', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'J',   N'Fully Adjusted', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Adjusted', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'K',   N'Partially Adjusted', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Adjusted', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'L',   N'Partially Paid', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'M',   N'Patient Payment', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Patient Payment', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'N',   N'Insurance Balance', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,No Response,No Response-Client', NULL,NULL,NULL,
     N'Fully Denied',      N'ClaimStatus', N'Fully Denied',
     N'Partially Denied',  N'ClaimStatus', N'Partially Denied',
     N'No Response',       N'ClaimStatus', N'No Response,No Response-Client'),
 (N'Cove', N'N.1', N'Fully Denied', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'N.2', N'Partially Denied', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Denied', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'N.3', N'No Response', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'No Response,No Response-Client', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   Augustus (Aug) — predicates match ES refresh SPs:
     LIS  30_Augustus_ExecutiveSummary_LIS_NewStructure.sql
          (usp_RefreshAug_ExecutiveSummary_LIS_Alt) — A=Total, B=BillTo LIKE '%Insurance%'
     PMS  16_Augustus_ExecutiveSummary_Aggregate.sql
          (usp_RefreshAug_ExecutiveSummary) — F/G use FirstBilledDate, not BilledStatus
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Aug' AND ISNULL(Source, N'LIS') = N'LIS';

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3, Col4,Op4,Val4)
VALUES
 (N'Aug', N'A',      N'Total Samples',                  N'RequestCollectDate', N'LIS', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'B',      N'Billable Samples',               N'RequestCollectDate', N'LIS', N'BillTo',N'LIKE',N'%Insurance%', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'B2.1',   N'Billed',                         N'RequestCollectDate', N'LIS', N'BillTo',N'LIKE',N'%Insurance%', N'BillingStatus',N'=',N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'B2.1.1', N'Claim Submitted in IRCM',        N'RequestCollectDate', N'LIS', N'BillTo',N'LIKE',N'%Insurance%', N'BillingStatus',N'=',N'Billed', N'FinalStatus',N'=',N'Claim Submitted in IRCM', NULL,NULL,NULL),
 (N'Aug', N'B2.1.2', N'Claim Submitted in Daqbilling',  N'RequestCollectDate', N'LIS', N'BillTo',N'LIKE',N'%Insurance%', N'BillingStatus',N'=',N'Billed', N'FinalStatus',N'=',N'Claim Submitted in Daqbilling', NULL,NULL,NULL),
 (N'Aug', N'B2.2',   N'Unbilled',                       N'RequestCollectDate', N'LIS', N'BillTo',N'LIKE',N'%Insurance%', N'BillingStatus',N'=',N'Unbilled', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'B2.2.1', N'Resulted yet to be billed',      N'RequestCollectDate', N'LIS', N'BillTo',N'LIKE',N'%Insurance%', N'BillingStatus',N'=',N'Unbilled', N'FinalStatus',N'=',N'Resulted yet to be billed', NULL,NULL,NULL),
 (N'Aug', N'B2.2.1*',N'Ready to bill',                  N'RequestCollectDate', N'LIS', N'BillTo',N'LIKE',N'%Insurance%', N'BillingStatus',N'=',N'Unbilled', N'FinalStatus',N'=',N'Resulted yet to be billed', N'ClientStatus1',N'=',N'Ready to bill'),
 (N'Aug', N'B2.2.2', N'Insurance name not listed',      N'RequestCollectDate', N'LIS', N'BillTo',N'LIKE',N'%Insurance%', N'BillingStatus',N'=',N'Unbilled', N'FinalStatus',N'=',N'Insurance Name Not Listed', NULL,NULL,NULL),
 (N'Aug', N'C',      N'Yet to be Validated',            N'RequestCollectDate', N'LIS', N'BillTo',N'=',N'Yet to be Validated', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'C.1',    N'Billed',                         N'RequestCollectDate', N'LIS', N'BillTo',N'=',N'Yet to be Validated', N'BillingStatus',N'=',N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'D',      N'Client Bills',                   N'RequestCollectDate', N'LIS', N'BillTo',N'=',N'Client Bills', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'D.1',    N'Billed',                         N'RequestCollectDate', N'LIS', N'BillTo',N'=',N'Client Bills', N'BillingStatus',N'=',N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'E',      N'System Test',                    N'RequestCollectDate', N'LIS', N'BillTo',N'=',N'System Test', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'E.1',    N'Billed',                         N'RequestCollectDate', N'LIS', N'BillTo',N'=',N'System Test', N'BillingStatus',N'=',N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'F',      N'Self pay',                       N'RequestCollectDate', N'LIS', N'BillTo',N'=',N'Self pay', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'F.1',    N'Billed',                         N'RequestCollectDate', N'LIS', N'BillTo',N'=',N'Self pay', N'BillingStatus',N'=',N'Billed', NULL,NULL,NULL, NULL,NULL,NULL);
GO

DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Aug' AND ISNULL(Source, N'LIS') = N'PMS';

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3,
     Sec1Name, Sec1Col, Sec1Vals, Sec2Name, Sec2Col, Sec2Vals, Sec3Name, Sec3Col, Sec3Vals)
VALUES
 -- F/F.1/F.2: FirstBilledDate populated + ClaimStatus <> Billed amount 0 (+ Source)
 (N'Aug', N'F',   N'No. of Billed Claims', N'DateofService', N'PMS',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed amount 0', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'F.1', N'No. of Claims Billed in IRCM', N'DateofService', N'PMS',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed amount 0', N'Source', N'=', N'IRCM',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'F.2', N'No. of Claims Billed in Daq Billing', N'DateofService', N'PMS',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed amount 0', N'Source', N'=', N'Daq',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 -- G: FirstBilledDate blank + ClaimStatus <> Billed amount 0
 (N'Aug', N'G',   N'No. of Unbilled Claims', N'DateofService', N'PMS',
     N'FirstBilledDate', N'=', N'', N'ClaimStatus', N'<>', N'Billed amount 0', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'H',   N'Client bill claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Billed amount 0', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'I',   N'No. of Fully Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'J',   N'No. of Patient Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Patient paid', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'K',   N'No. of Patient Responsibility Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Pat Responsibility', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'L',   N'No. of Partially Paid Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partial Paid', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'M',   N'No. of Adjusted/Written Off Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Adjusted', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'N',   N'No. of Partially Adjusted/Written Off Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Adjusted', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'O',   N'No. of Insurance Balance Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'Fully Denied,Partially Denied,No Response', NULL,NULL,NULL, NULL,NULL,NULL,
     N'Fully Denied', N'ClaimStatus', N'Fully Denied',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied',
     N'No Response', N'ClaimStatus', N'No Response'),
 (N'Aug', N'O.1', N'No. of Fully Denied Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'O.2', N'No. of Partially Denied Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Partially Denied', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'O.3', N'No. of No Response from Payor', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   Elixir (Elix) — 19_Elixir LIS_Alt + 21_Elixir PMSCash.
   J = No. of Fully Paid Claims (PMS). C = Billed (LIS).
   ClaimLevelData column is BillStatus (aliased BilledUnbilled in SPs).
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Elix' AND ISNULL(Source, N'LIS') = N'LIS';

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, Col1,Op1,Val1, Col2,Op2,Val2, Col3,Op3,Val3)
VALUES
 (N'Elix', N'A',   N'Total Samples',             N'DateOfCollection', N'LIS', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'B',   N'Billable Samples',          N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'Billable', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'C',   N'Billed',                    N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Billed', NULL,NULL,NULL),
 (N'Elix', N'D',   N'Unbilled',                  N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', NULL,NULL,NULL),
 (N'Elix', N'D.1', N'Resulted yet to be billed', N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'Billable', N'BillCategory',N'=',N'Not Billed', N'ResultStatus',N'=',N'Resulted'),
 (N'Elix', N'E',   N'Other Samples',             N'DateOfCollection', N'LIS', N'NewStatus',N'<>',N'Billable', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'E.1', N'Client Bill',               N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'Client Bill', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'E.2', N'Self Pay',                  N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'Self Pay', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'E.3', N'System Test',               N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'System Test', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'E.4', N'Deleted/Rejected',          N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'Deleted/Rejected', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'E.5', N'CIP/Pending',               N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'CIP/Pending', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'E.6', N'Yet to be validated',       N'DateOfCollection', N'LIS', N'NewStatus',N'=',N'Yet to be validated', NULL,NULL,NULL, NULL,NULL,NULL);
GO

DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Elix' AND ISNULL(Source, N'LIS') = N'PMS';

INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source,
     Col1, Op1, Val1, Col2, Op2, Val2,
     Sec1Name, Sec1Col, Sec1Vals, Sec2Name, Sec2Col, Sec2Vals, Sec3Name, Sec3Col, Sec3Vals)
VALUES
 (N'Elix', N'F',   N'No. of Billed Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'NOT IN', N'Billed Amount 0,Unbilled',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'G',   N'Unbilled Claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'H',   N'Voided claims', N'DateofService', N'PMS',
     N'ClaimStatus', N'=', N'Voided', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'I',   N'Billed Mismatches - LIS Accession Cannot be Matched', N'DateofService', N'PMS',
     N'BillStatus', N'MISMATCH', N'Billed', NULL,NULL,NULL,
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'J',   N'No. of Fully Paid Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid',
     N'Billed (Claims)', N'BillStatus', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'K',   N'No. of Fully Patient Responsibility Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Responsibility',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'L',   N'No. of Patient Paid Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Patient Payment',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'M',   N'No. of Adjusted/Written Off Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Adjusted',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'N',   N'No. of Partially Adjusted claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Adjusted',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'O',   N'No. of Partially Paid Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'P',   N'No. of Insurance Balance Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'IN', N'Denied,No Response,Partially Denied',
     N'Denied', N'ClaimStatus', N'Denied',
     N'Partially Denied', N'ClaimStatus', N'Partially Denied',
     N'No Response', N'ClaimStatus', N'No Response'),
 (N'Elix', N'P.1', N'No. of Fully Denied Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'P.2', N'No. of Partially Denied Claims', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'IN', N'Partially Adjusted,Partially Denied',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'P.3', N'No. of No Response from Payor', N'DateofService', N'PMS',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* ---------------------------------------------------------------------
   Certus / Inhealth / PhiLife / PCR / RisingTides / NorthWest
   Full seeds live in LisDrillRowDef_OtherLabs.sql (run after this file).
   Clear any stale rows here so a partial deploy cannot leave wrong filters.
   --------------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef
WHERE LabPrefix IN (N'Cert',N'Inh',N'Phi',N'PCR',N'RT',N'NW')
  AND ISNULL(Source, N'LIS') IN (N'LIS', N'PMS');
GO

PRINT 'LisDrillRowDef.sql completed (Cove/BT/Aug/Elix). Run LisDrillRowDef_OtherLabs.sql next, then LisDrillRowDef_Cash.sql for Cash drill.';
GO

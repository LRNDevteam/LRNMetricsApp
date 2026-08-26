/* =====================================================================
   dbo.LisDrillRowDef — Cash Breakdown (Source='Cash') seeds
   ---------------------------------------------------------------------
   Predicates + AmountCol MUST match each lab's ES Cash refresh
   (usp_Refresh*_ExecutiveSummary Cash INSERT / 21_*_PMSCash Cash section).

   Requires: LisDrillRowDef table with AmountCol (from LisDrillRowDef.sql).
   Deploy independently after the table exists. Does not touch LIS/PMS rows.

   Labs: Aug, BT, Cove, Elix, Cert, Inh, Phi, PCR, RT, NW
   (PCR_Dx intentionally omitted.)
   ===================================================================== */
IF COL_LENGTH('dbo.LisDrillRowDef','AmountCol') IS NULL
    ALTER TABLE dbo.LisDrillRowDef ADD AmountCol NVARCHAR(200) NULL;
GO

/* -- Cove ------------------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Cove' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'Cove', N'O',   N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BillStatus', N'IN', N'Billed,Billed-Client,Billed - Client', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'P',   N'Insurance Payment ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'IN', N'Fully Paid,Paid-Client', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'Q',   N'Patient Responsibility ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'ClaimStatus', N'NOT IN', N'Unbilled,Unbilled - PB,No Response,No Response-Client', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'R',   N'Patient Payment ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'PatientPayment', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'S',   N'Adjustments / Write Off ($)', N'DateofService', N'Cash', N'InsuranceAdjustments+PatientAdjustments',
     N'ClaimStatus', N'NOT IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'T',   N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'U',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'NOT IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'U.1', N'Denials', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'U.2', N'Partially Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Partially Denied,Partially Adjusted,Partially Paid,Patient Payment,Patient Responsibility', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cove', N'U.3', N'No Response from Payor', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'No Response,No Response-Client', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* -- BeechTree (BT) --------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'BT' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'BT', N'AA', N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AB', N'Unbilled ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BilledUnbilled', N'=', N'UnBilled', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AC', N'Insurance Payment (fully paid) ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'=', N'Fully Paid', N'InsurancePayment', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AD', N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'IN', N'Partial Paid,Partially Paid', N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AE', N'Patient Payment ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'PatientPayment', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AF', N'Fully Adjusted (Complete W/O)', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'ClaimStatus', N'=', N'Complete W/O', N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AG', N'Contractual Obligation W/O', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'<>', N'Complete W/O', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AH', N'Patient Balance ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'ClaimStatus', N'NOT IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 -- RoleIDs match 16_BeechTree_ExecutiveSummary_Aggregate Cash:
 --   AI Patient WO · AJ Insurance Balance ($)  (AK/AL/AM are Avg, not Cash)
 (N'BT', N'AI', N'Patient WO', N'DateofService', N'Cash', N'PatientAdjustments',
     N'PatientAdjustments', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AJ', N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Denied', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AJ.1', N'Fully Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AJ.2', N'No Response', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'BT', N'AJ.3', N'Partially Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'Partially Denied', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO
/* -- Augustus (Aug) --------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Aug' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'Aug', N'P',   N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed amount 0', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'P.1', N'Total Charge of Claims Billed (IRCM)', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed amount 0', N'Source', N'=', N'IRCM', NULL,NULL,NULL),
 (N'Aug', N'P.2', N'Total Charge of Claims Billed (Daq)', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed amount 0', N'Source', N'=', N'Daq', NULL,NULL,NULL),
 (N'Aug', N'Q',   N'Total Unbilled ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'=', N'', N'ClaimStatus', N'<>', N'Billed amount 0', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'R',   N'Insurance Payment ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'=', N'Fully Paid', N'InsurancePayment', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'S',   N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'=', N'Partial Paid', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'T',   N'Patient Paid ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'PatientPayment', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'U',   N'Patient Responsibility ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'PatientBalance', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'U.1', N'Daqbilling', N'DateofService', N'Cash', N'PatientBalance',
     N'PatientBalance', N'>', N'0', N'Source', N'=', N'Daq', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'U.2', N'IRCM', N'DateofService', N'Cash', N'PatientBalance',
     N'PatientBalance', N'>', N'0', N'Source', N'=', N'IRCM', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'V',   N'Adjustment amount ($)', N'DateofService', N'Cash', N'InsuranceAdjustments+PatientAdjustments',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'W',   N'Total Payments ($) - Insurance', N'DateofService', N'Cash', N'InsurancePayment',
     N'InsurancePayment', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'X',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'InsuranceBalance', N'>', N'0', N'ClaimStatus', N'IN', N'Partially Denied,Fully Denied,No Response,Partial Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'X.1', N'Fully Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'InsuranceBalance', N'>', N'0', N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'X.2', N'Partially Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'InsuranceBalance', N'>', N'0', N'ClaimStatus', N'IN', N'Partially Denied,Partial Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Aug', N'X.3', N'No Response from Payor', N'DateofService', N'Cash', N'InsuranceBalance',
     N'InsuranceBalance', N'>', N'0', N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* -- Elixir (Elix) ---------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Elix' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'Elix', N'Q',   N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'NOT IN', N'Unbilled,Billed Amount 0', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'R',   N'Unbilled Claims ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'ClaimStatus', N'=', N'Unbilled', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'S',   N'Insurance Payment ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'T',   N'Patient Responsibility ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'U',   N'Adjustments / Write Off ($)', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'V',   N'Patient Paid ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'W',   N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'X',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'NOT IN', N'Unbilled,Billed Amount 0', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'X.1', N'Denials ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Denied', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'X.2', N'Partially Denied ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'IN', N'Partially Denied,Partially Paid,Partially Adjusted,Patient Responsibility', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Elix', N'X.3', N'No Response from Payor ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* -- Certus (Cert) ---------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Cert' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'Cert', N'Q',   N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'ClaimStatus', N'NOT IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'R',   N'Unbilled Claims ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'ClaimStatus', N'IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'S',   N'Insurance Payment ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'T',   N'Patient Responsibility ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'ClaimStatus', N'NOT IN', N'Unbilled,Unbilled - PB', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'U',   N'Adjustments / Write Off ($)', N'DateofService', N'Cash', N'InsuranceAdjustments+PatientAdjustments',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'V',   N'Patient Paid ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'PatientPayment', N'>', N'0', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'W',   N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'X',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'X.1', N'Denials', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'Denied', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'X.2', N'Partially Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'Partially Denied', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Cert', N'X.3', N'No Response from Payor', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* -- Inhealth (Inh) --------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Inh' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'Inh', N'P',   N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'Q',   N'Total Unbilled ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BillStatus', N'=', N'Unbilled', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'Q.1', N'Unbilled', N'DateofService', N'Cash', N'ChargeAmount',
     N'BillStatus', N'=', N'Unbilled', N'ClaimStatus', N'=', N'Unbilled', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'Q.2', N'Unbilled - Patient Balance', N'DateofService', N'Cash', N'ChargeAmount',
     N'BillStatus', N'=', N'Unbilled', N'ClaimStatus', N'=', N'Unbilled - Patient Balance', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'R',   N'Insurance Payment ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'S',   N'Patient Payments ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'T',   N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'U',   N'Patient Responsibility ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'V',   N'Total Adjustments ($)', N'DateofService', N'Cash', N'InsuranceAdjustments+PatientAdjustments',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'W',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BillStatus', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'W.1', N'Denials', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'FullyDenied', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'W.2', N'Partially Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Denied', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Inh', N'W.3', N'No Response from Payor', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BillStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* -- PhiLife (Phi) ---------------------------------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'Phi' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'Phi', N'Z',    N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AA',   N'Unbilled ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BilledUnbilled', N'=', N'Unbilled', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AB',   N'Insurance Payment (Fully Paid) ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AC',   N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AD',   N'Patient Payment ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AE',   N'Fully Adjusted (Complete W/O) ($)', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Complete W/O', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AF',   N'Contractual Obligation W/O ($)', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'<>', N'Complete W/O', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AG',   N'Patient Balance ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AH',   N'Patient WO ($)', N'DateofService', N'Cash', N'PatientAdjustments',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AI',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AI.1', N'Fully Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AI.2', N'No Response', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'Phi', N'AI.3', N'Partially Denied ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'NOT IN', N'No Response,Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* -- PCR Labs of America (PCR) -- not PCR_Dx -------------------------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'PCR' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'PCR', N'Q',   N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'R',   N'Unbilled ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BilledUnbilled', N'=', N'Unbilled', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'S',   N'Insurance Payment (fully paid) ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'T',   N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'U',   N'Fully Adjusted (Complete W/O) ($)', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Complete W/O', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'V',   N'Contractual Obligation W/O ($)', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'<>', N'Complete W/O', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'W',   N'Patient Balance ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'X',   N'Patient WO ($)', N'DateofService', N'Cash', N'PatientAdjustments',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'Y',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'Y.1', N'No Response', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'Y.2', N'Fully Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'PCR', N'Y.3', N'Partially Denied ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'NOT IN', N'No Response,Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* -- RisingTides (RT) -- RowCode X collides with PMS; Source=Cash ------ */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'RT' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'RT', N'X',   N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'Y',   N'Unbilled ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'BilledUnbilled', N'=', N'Unbilled', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'Z',   N'Insurance Payment (fully paid) ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AA',  N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Paid', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AB',  N'Patient Payment ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AC',  N'Fully Adjusted (Complete W/O) ($)', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Complete W/O', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AD',  N'Contractual Obligation W/O ($)', N'DateofService', N'Cash', N'InsuranceAdjustments',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'<>', N'Complete W/O', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AE',  N'Patient Balance ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AF',  N'Patient WO ($)', N'DateofService', N'Cash', N'PatientAdjustments',
     N'BilledUnbilled', N'=', N'Billed', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AG',  N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Denied', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AG1', N'No Response', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'No Response', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AG2', N'Fully Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Fully Denied', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'RT', N'AG3', N'Partially Denied', N'DateofService', N'Cash', N'InsuranceBalance',
     N'BilledUnbilled', N'=', N'Billed', N'ClaimStatus', N'=', N'Partially Denied', NULL,NULL,NULL, NULL,NULL,NULL);
GO

/* -- NorthWest (NW) -- skip AC.2 (=0) and ARIA 30-day scalars ---------- */
DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'NW' AND Source = N'Cash';
INSERT INTO dbo.LisDrillRowDef
    (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
     Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3, Col4, Op4, Val4)
VALUES
 (N'NW', N'T',    N'Total Billed ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed Amount 0', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL),
 (N'NW', N'T.1',  N'Total Charge of Claims Billed in Webpm', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed Amount 0', N'ClaimType', N'=', N'Webpm', NULL,NULL,NULL),
 (N'NW', N'T.2',  N'Total Charge of Claims Billed in Daqbilling', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed Amount 0', N'ClaimType', N'=', N'Daqbilling', NULL,NULL,NULL),
 (N'NW', N'T.3',  N'Total Charge of Claims Billed in Emedix', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'<>', N'', N'ClaimStatus', N'<>', N'Billed Amount 0', N'ClaimType', N'=', N'Emedix', NULL,NULL,NULL),
 (N'NW', N'U',    N'Total Unbilled ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'=', N'', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'U.1',  N'Unbilled in Webpm PR', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'=', N'', N'ClaimStatus', N'=', N'Unbilled in Webpm PR', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL),
 (N'NW', N'U.2',  N'Unbilled in Webpm', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'=', N'', N'ClaimStatus', N'=', N'Unbilled in Webpm', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL),
 (N'NW', N'U.3',  N'Unbilled in Daq', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'=', N'', N'ClaimStatus', N'=', N'Unbilled in Daq', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL),
 (N'NW', N'U.4',  N'Unbilled in Daq - PR', N'DateofService', N'Cash', N'ChargeAmount',
     N'FirstBilledDate', N'=', N'', N'ClaimStatus', N'=', N'Unbilled in Daq - PR', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL),
 (N'NW', N'V',    N'Test Patients Entries ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'ClaimType', N'=', N'Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'W',    N'ADCS Claims ($)', N'DateofService', N'Cash', N'ChargeAmount',
     N'ClaimType', N'=', N'ADCS - Invoice', NULL,NULL,NULL, NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'X',    N'Insurance Payment ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'=', N'Fully Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'X.1',  N'Actual Payments', N'DateofService', N'Cash', N'ActualPayment',
     N'ClaimStatus', N'=', N'Fully Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'X.2',  N'Duplicate Payments', N'DateofService', N'Cash', N'DuplicatePayment',
     N'ClaimStatus', N'=', N'Fully Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'Y',    N'Patient Responsibility ($)', N'DateofService', N'Cash', N'PatientBalance',
     N'FirstBilledDate', N'<>', N'', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'Z',    N'Adjustments / Write Off ($)', N'DateofService', N'Cash', N'InsuranceAdjustments+PatientAdjustments',
     N'FirstBilledDate', N'<>', N'', N'ClaimType', N'IN', N'Webpm,Daqbilling', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'AA',   N'Partially Paid ($)', N'DateofService', N'Cash', N'InsurancePayment',
     N'ClaimStatus', N'=', N'Partially Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'AA.1', N'Actual Payments', N'DateofService', N'Cash', N'ActualPayment',
     N'ClaimStatus', N'=', N'Partially Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'AA.2', N'Duplicate Payments', N'DateofService', N'Cash', N'DuplicatePayment',
     N'ClaimStatus', N'=', N'Partially Paid', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'AB',   N'Patient Paid ($)', N'DateofService', N'Cash', N'PatientPayment',
     N'FirstBilledDate', N'<>', N'', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'AC',   N'Insurance Balance ($)', N'DateofService', N'Cash', N'InsuranceBalance',
     N'FirstBilledDate', N'<>', N'', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'AC.1', N'Denials', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'Fully Denied', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL),
 (N'NW', N'AC.3', N'No Response from Payor', N'DateofService', N'Cash', N'InsuranceBalance',
     N'ClaimStatus', N'=', N'No Response', N'ClaimType', N'NOT IN', N'ADCS - Invoice,Test Patient Entries', NULL,NULL,NULL, NULL,NULL,NULL);
GO

PRINT 'LisDrillRowDef_Cash.sql completed (Source=Cash seeds).';
GO

/* =====================================================================
   Insurance Balance ($) — attach Sec1/2/3 subcategory series so Insight
   Monthly Trend can render stacked bars (Fully Denied / Partially Denied /
   No Response). Safe to re-run; only updates Cash Insurance Balance parents.
   ===================================================================== */
UPDATE dbo.LisDrillRowDef SET
    Sec1Name = N'Fully Denied', Sec1Col = N'ClaimStatus', Sec1Vals = N'Fully Denied',
    Sec2Name = N'Partially Denied', Sec2Col = N'ClaimStatus', Sec2Vals = N'Partially Denied',
    Sec3Name = N'No Response', Sec3Col = N'ClaimStatus', Sec3Vals = N'No Response'
WHERE Source = N'Cash' AND RowTitle = N'Insurance Balance ($)'
  AND LabPrefix IN (N'BT', N'Phi', N'RT', N'PCR');

UPDATE dbo.LisDrillRowDef SET
    Sec1Name = N'Fully Denied', Sec1Col = N'ClaimStatus', Sec1Vals = N'Fully Denied',
    Sec2Name = N'Partially Denied', Sec2Col = N'ClaimStatus', Sec2Vals = N'Partially Denied,Partial Paid',
    Sec3Name = N'No Response', Sec3Col = N'ClaimStatus', Sec3Vals = N'No Response'
WHERE Source = N'Cash' AND RowTitle = N'Insurance Balance ($)' AND LabPrefix = N'Aug';

UPDATE dbo.LisDrillRowDef SET
    Sec1Name = N'Fully Denied', Sec1Col = N'ClaimStatus', Sec1Vals = N'Denied',
    Sec2Name = N'Partially Denied', Sec2Col = N'ClaimStatus', Sec2Vals = N'Partially Denied',
    Sec3Name = N'No Response', Sec3Col = N'ClaimStatus', Sec3Vals = N'No Response'
WHERE Source = N'Cash' AND RowTitle = N'Insurance Balance ($)' AND LabPrefix = N'Cert';

UPDATE dbo.LisDrillRowDef SET
    Sec1Name = N'Fully Denied', Sec1Col = N'ClaimStatus', Sec1Vals = N'Fully Denied',
    Sec2Name = N'Partially Denied', Sec2Col = N'ClaimStatus',
    Sec2Vals = N'Partially Denied,Partially Adjusted,Partially Paid,Patient Payment,Patient Responsibility',
    Sec3Name = N'No Response', Sec3Col = N'ClaimStatus', Sec3Vals = N'No Response,No Response-Client'
WHERE Source = N'Cash' AND RowTitle = N'Insurance Balance ($)' AND LabPrefix = N'Cove';

UPDATE dbo.LisDrillRowDef SET
    Sec1Name = N'Denials', Sec1Col = N'ClaimStatus', Sec1Vals = N'Denied',
    Sec2Name = N'Partially Denied', Sec2Col = N'ClaimStatus',
    Sec2Vals = N'Partially Denied,Partially Paid,Partially Adjusted,Patient Responsibility',
    Sec3Name = N'No Response', Sec3Col = N'ClaimStatus', Sec3Vals = N'No Response'
WHERE Source = N'Cash' AND RowTitle = N'Insurance Balance ($)' AND LabPrefix = N'Elix';

UPDATE dbo.LisDrillRowDef SET
    Sec1Name = N'Denials', Sec1Col = N'ClaimStatus', Sec1Vals = N'FullyDenied',
    Sec2Name = N'Partially Denied', Sec2Col = N'ClaimStatus', Sec2Vals = N'Partially Denied',
    Sec3Name = N'No Response', Sec3Col = N'ClaimStatus', Sec3Vals = N'No Response'
WHERE Source = N'Cash' AND RowTitle = N'Insurance Balance ($)' AND LabPrefix = N'Inh';

UPDATE dbo.LisDrillRowDef SET
    Sec1Name = N'Denials', Sec1Col = N'ClaimStatus', Sec1Vals = N'Fully Denied',
    Sec2Name = NULL, Sec2Col = NULL, Sec2Vals = NULL,
    Sec3Name = N'No Response', Sec3Col = N'ClaimStatus', Sec3Vals = N'No Response'
WHERE Source = N'Cash' AND RowTitle = N'Insurance Balance ($)' AND LabPrefix = N'NW';

PRINT 'LisDrillRowDef_Cash.sql — Insurance Balance Sec1/2/3 stacked series applied.';
GO

/* =============================================================================
   NorthWest - Executive Summary: client logic on BilledUnbilled
   File     : 44_NW_ExecutiveSummary_BilledUnbilled.sql
   Database : NWL_LRN
   Replaces : the row logic of 30 (usp_RefreshNW_ExecutiveSummary), 31 (usp_GetNW_ExecutiveSummary),
              33 (usp_RefreshNW_ExecutiveSummary_LIS_Alt), 34/35 (cell drill SPs).

   Every row is defined once:
     fn_NW_ES_LisRowCodes   - LIS Breakdown rows a LIMSMaster sample belongs to (A-F)
     fn_NW_ES_ClaimRowCodes - PMS / Cash rows a ClaimLevelData claim belongs to (G-AC)
   usp_NW_ES_Build aggregates them (month, year = (Y,0), grand total = (0,0)) and adds the
   derived rows; the snapshot refresh, the filtered page and the cell drills all use it.

   LIS Breakdown (LIMSMaster; every row requires Incorrect DOS = blank)
     A  Total Samples
     B  Billable Samples        Bill To = Insurance Bill            (+ B.{PanelType})
     C  Billed                  B + Bill Status = Billed            C.1-C.5 by Final Status
     D  Unbilled                B + Bill Status = Unbilled
        D.1 Charge Not Created  (.W / .DQ by Source; .NC / .UP = Webpm + Charges not entered status)
        D.2 Excluded PAP Codes; D.3 Excluded Validity Codes (Final Status matches the label)
        D.4 Excluded Organizations; D.5 Charges Created and Not Submitted (.W / .DQ by Source)
     E  ADCS Samples            Bill To = ADCS Claims
     F  Other Samples           Bill To not in (Insurance Bill, ADCS Claims)
        F.1 Yet to be validate, F.2 Self pay, F.3 Client Bills,
        F.4 Rejections (Bill To = Rejections), F.5 System Test (Bill To = System Test)

   PMS / Cash (ClaimLevelData)
     Std  = Claim Type not in (ADCS - Invoice, Test Patient Entries)
     Src  = Claim Type in (Claim Submitted in Webpm, Claim Submitted in Daqbilling, Manually Pushed in Emedix)
     G    BilledUnbilled = Billed, Src, Claim Status <> Billed Amount 0   (G.1-G.3 by Claim Type)
     H    Std, Claim Status in Billed Amount 0 / Unbilled in Daq / Daq PR / Webpm / Webpm PR
          H.1-H.5 use the same Claim Type and Claim Status rules (no BilledUnbilled filter)
     I    G - LIS C
     J/K  Test Patient Entries / ADCS - Invoice
     M-S  Std + Claim Status; S.1/S.3 Aria rows (see below)
     T/T.x = G/G.x Charge; U = H Charge; U.1-U.4 Std + status (no BilledUnbilled filter)
     V/W  Test Patient / ADCS Charge; X, X.1, X.2 Fully Paid Insurance / Actual / Duplicate payment
     Y    Billed + Src PatientBalance
     AA   Billed + Src + Partially Paid, InsurancePayment
          AA.1 ActualPayment, or InsurancePayment when ActualPayment is 0 (Daqbilling / Emedix leave it blank)
     AB   Billed + Src PatientPayment; AC Billed + Src InsuranceBalance
     AC.1 Fully Denied; AC.2 Claim Status not in (Fully Denied, No Response); AC.3 No Response
     Z    T - X - AA - AB - Y - AC
   Aria (S.1 / S.3 counts, AC.1 / AC.3 Insurance Balance): ClaimLevelData has no Last Billed Date,
   so FirstBilledDate is used. As-of date = latest FirstBilledDate of that status within the
   DOS period; "submitted" = billed within 30 days of it; % = submitted / not submitted.
   Averages: AD = (X + AA + AB) / G, AE = (X + AA + AB) / (M + Q + R),
             AF = (X + AA) / (M + O + S.1 + S.2 + Q + P + R + N).

   Filter lists from the page are comma-delimited. 12/31/1899 is the file's blank-date placeholder.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'44_NW_ExecutiveSummary_BilledUnbilled.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

/* -----------------------------------------------------------------------------
   Keep the current definitions as *_bkp20261015 for rollback
   ----------------------------------------------------------------------------- */
DECLARE @name SYSNAME, @def NVARCHAR(MAX);
DECLARE bkp CURSOR LOCAL FAST_FORWARD FOR
    SELECT v.name
    FROM (VALUES (N'usp_RefreshNW_ExecutiveSummary'),
                 (N'usp_RefreshNW_ExecutiveSummary_LIS_Alt'),
                 (N'usp_GetNW_ExecutiveSummary'),
                 (N'usp_GetExecutiveSummaryDetail_LIS'),
                 (N'usp_GetExecutiveSummaryDetail_PMSCash')) v(name)
    WHERE OBJECT_ID(N'dbo.' + v.name, N'P') IS NOT NULL
      AND OBJECT_ID(N'dbo.' + v.name + N'_bkp20261015', N'P') IS NULL;
OPEN bkp;
FETCH NEXT FROM bkp INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.' + @name));
    SET @def = STUFF(@def, CHARINDEX(@name, @def), LEN(@name), @name + N'_bkp20261015');
    EXEC sys.sp_executesql @def;
    PRINT N'Backed up dbo.' + @name + N' as dbo.' + @name + N'_bkp20261015';
    FETCH NEXT FROM bkp INTO @name;
END;
CLOSE bkp;
DEALLOCATE bkp;
GO

/* -----------------------------------------------------------------------------
   Row list, labels and display order
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_ES_RowDefs()
RETURNS TABLE
AS
RETURN
    SELECT Category, RowCode, Description, Seq
    FROM (VALUES
        (N'LIS',  N'A',       N'Total No. of Samples',                                         10),
        (N'LIS',  N'B',       N'Billable Samples',                                             20),
        (N'LIS',  N'C',       N'No. of Billed Claims',                                         30),
        (N'LIS',  N'C.1',     N'  Claim Submitted in Webpm',                                   31),
        (N'LIS',  N'C.2',     N'  Claim Submitted in Daqbilling',                              32),
        (N'LIS',  N'C.3',     N'  Claim Submitted in Daq & Webpm',                             33),
        (N'LIS',  N'C.4',     N'  Non Billable - Excluded Organizations',                      34),
        (N'LIS',  N'C.5',     N'  Manually Pushed in Emedix',                                  35),
        (N'LIS',  N'D',       N'No. of Unbilled Claims',                                       40),
        (N'LIS',  N'D.1',     N'  Unbilled - Charge Not Created',                              41),
        (N'LIS',  N'D.1.W',   N'    Charge Not Created - Webpm',                               42),
        (N'LIS',  N'D.1.NC',  N'    Charge Not Created -No Charges found in Webpm',            43),
        (N'LIS',  N'D.1.UP',  N'    Charge Not Created -Unposted Charges in Webpm',            44),
        (N'LIS',  N'D.1.DQ',  N'    Charge Not Created -Daqbilling',                           45),
        (N'LIS',  N'D.2',     N'  Unbilled - Non Billable (Excluded PAP Codes)',               46),
        (N'LIS',  N'D.3',     N'  Unbilled - Non Billable (Excluded Validity Codes)',          47),
        (N'LIS',  N'D.4',     N'  Unbilled - Non Billable (Excluded Organizations)',           48),
        (N'LIS',  N'D.5',     N'  Unbilled - Charges Created and Not Submitted',               49),
        (N'LIS',  N'D.5.W',   N'    Charges Not Submitted - Webpm',                            50),
        (N'LIS',  N'D.5.DQ',  N'    Charges Not Submitted - Daqbilling',                       51),
        (N'LIS',  N'E',       N'No. of ADCS Claims',                                           60),
        (N'LIS',  N'F',       N'No. of Other Claims',                                          70),
        (N'LIS',  N'F.1',     N'  Other - Yet to be validate',                                 71),
        (N'LIS',  N'F.2',     N'  Other - Self pay',                                           72),
        (N'LIS',  N'F.3',     N'  Other - Client Bills',                                       73),
        (N'LIS',  N'F.4',     N'  Other - Rejections',                                         74),
        (N'LIS',  N'F.5',     N'  Other - System Test',                                        75),

        (N'PMS',  N'G',       N'No. of Billed Claims',                                        100),
        (N'PMS',  N'G.1',     N'  Claim Submitted in Webpm',                                  101),
        (N'PMS',  N'G.2',     N'  Claim Submitted in Daqbilling',                             102),
        (N'PMS',  N'G.3',     N'  Manually Pushed in Emedix',                                 103),
        (N'PMS',  N'H',       N'No. of Unbilled Claims',                                      110),
        (N'PMS',  N'H.1',     N'  Unbilled in Webpm PR',                                      111),
        (N'PMS',  N'H.2',     N'  Unbilled in Webpm',                                         112),
        (N'PMS',  N'H.3',     N'  Unbilled in Daq',                                           113),
        (N'PMS',  N'H.4',     N'  Unbilled in Daq - PR',                                      114),
        (N'PMS',  N'H.5',     N'  Billed amount 0',                                           115),
        (N'PMS',  N'I',       N'Billed Mismatches - Other samples billed / LIS Accessions NA', 120),
        (N'PMS',  N'J',       N'Test Patient Entries',                                        130),
        (N'PMS',  N'K',       N'ADCS Claims',                                                 140),
        (N'PMS',  N'M',       N'No. of Fully Paid Claims',                                    150),
        (N'PMS',  N'N',       N'No. of Fully Patient Responsibility Claims',                  160),
        (N'PMS',  N'O',       N'No. of Adjusted/Written Off Claims',                          170),
        (N'PMS',  N'P',       N'No. of Partially Adjusted Claim',                             180),
        (N'PMS',  N'Q',       N'No. of Partially Paid Claims',                                190),
        (N'PMS',  N'R',       N'No. of Patient Paid Claims',                                  200),
        (N'PMS',  N'S',       N'No. of Insurance Balance Claims',                             210),
        (N'PMS',  N'S.1',     N'  No. of Fully Denied Claims',                                211),
        (N'PMS',  N'S.1.A1',  N'    Aria Submitted in the last 30 Days',                      212),
        (N'PMS',  N'S.1.A2',  N'    Aria not submitted in the last 30 Days',                  213),
        (N'PMS',  N'S.1.AP',  N'    % of the claim submitted in the last 30 Days',            214),
        (N'PMS',  N'S.2',     N'  No. of Partially Denied Claims',                            215),
        (N'PMS',  N'S.3',     N'  No. of No Response from Payor',                             216),
        (N'PMS',  N'S.3.A1',  N'    Claim filed by ARIA in the last 30 days',                 217),
        (N'PMS',  N'S.3.A2',  N'    Claims not filed in the last 30 days',                    218),
        (N'PMS',  N'S.3.AP',  N'    % of the claim submitted in the last 30 Days',            219),

        (N'Cash', N'T',       N'Total Billed ($)',                                            300),
        (N'Cash', N'T.1',     N'  Claim Submitted in Webpm',                                  301),
        (N'Cash', N'T.2',     N'  Claim Submitted in Daqbilling',                             302),
        (N'Cash', N'T.3',     N'  Manually Pushed in Emedix',                                 303),
        (N'Cash', N'U',       N'Total Unbilled ($)',                                          310),
        (N'Cash', N'U.1',     N'  Unbilled in Webpm PR',                                      311),
        (N'Cash', N'U.2',     N'  Unbilled in Webpm',                                         312),
        (N'Cash', N'U.3',     N'  Unbilled in Daq',                                           313),
        (N'Cash', N'U.4',     N'  Unbilled in Daq - PR',                                      314),
        (N'Cash', N'V',       N'Test Patients Entries ($)',                                   320),
        (N'Cash', N'W',       N'ADCS Claims ($)',                                             330),
        (N'Cash', N'X',       N'Insurance Payment ($)',                                       340),
        (N'Cash', N'X.1',     N'  Actual Payments ($)',                                       341),
        (N'Cash', N'X.2',     N'  Duplicate Payments ($)',                                    342),
        (N'Cash', N'Y',       N'Patient Responsibility ($)',                                  350),
        (N'Cash', N'Z',       N'Adjustments / Write Off ($)',                                 360),
        (N'Cash', N'AA',      N'Partially Paid ($)',                                          370),
        (N'Cash', N'AA.1',    N'  Actual Payments ($)',                                       371),
        (N'Cash', N'AA.2',    N'  Duplicate Payments ($)',                                    372),
        (N'Cash', N'AB',      N'Patient Paid ($)',                                            380),
        (N'Cash', N'AC',      N'Insurance Balance ($)',                                       390),
        (N'Cash', N'AC.1',    N'  Denials',                                                   391),
        (N'Cash', N'AC.1.A1', N'    Claim filed by ARIA in the last 30 days',                 392),
        (N'Cash', N'AC.1.A2', N'    Claims not filed in the last 30 days',                    393),
        (N'Cash', N'AC.1.AP', N'    % of the claim submitted in the last 30 Days',            394),
        (N'Cash', N'AC.2',    N'  Partially Denied',                                          395),
        (N'Cash', N'AC.3',    N'  No Response from Payor',                                    396),
        (N'Cash', N'AC.3.A1', N'    Claim filed by ARIA in the last 30 days',                 397),
        (N'Cash', N'AC.3.A2', N'    Claims not filed in the last 30 days',                    398),
        (N'Cash', N'AC.3.AP', N'    % of the claim submitted in the last 30 Days',            399),

        (N'Avg',  N'AD',      N'Average Payment ($) - Total Pay/Billed Claims',               400),
        (N'Avg',  N'AE',      N'Average Payment ($) - Total Pay/Paid Claims',                 410),
        (N'Avg',  N'AF',      N'Average Payment ($) - Total Pay/Adjudicated Claims',          420)
    ) d(Category, RowCode, Description, Seq);
GO

/* -----------------------------------------------------------------------------
   LIS Breakdown rows a LIMSMaster sample counts in
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_ES_LisRowCodes
(
    @IncorrectDOS      NVARCHAR(500),
    @BilledTo          NVARCHAR(500),
    @BillStatus        NVARCHAR(500),
    @FinalStatus       NVARCHAR(500),
    @Source            NVARCHAR(500),
    @ChargesNotEntered NVARCHAR(500),
    @PanelType         NVARCHAR(500)
)
RETURNS TABLE
AS
RETURN
    SELECT m.RowCode
    FROM (SELECT
            Ok  = IIF(NULLIF(LTRIM(RTRIM(@IncorrectDOS)), N'') IS NULL, 1, 0),
            Bt  = LTRIM(RTRIM(ISNULL(@BilledTo,          N''))),
            Bs  = LTRIM(RTRIM(ISNULL(@BillStatus,        N''))),
            Fs  = LTRIM(RTRIM(ISNULL(@FinalStatus,       N''))),
            Src = LTRIM(RTRIM(ISNULL(@Source,            N''))),
            Cne = LTRIM(RTRIM(ISNULL(@ChargesNotEntered, N''))),
            Pn  = LTRIM(RTRIM(ISNULL(@PanelType,         N'')))) v
    CROSS APPLY (SELECT Ins = IIF(v.Ok = 1 AND v.Bt = N'Insurance Bill', 1, 0)) b
    CROSS APPLY (SELECT
            C = IIF(b.Ins = 1 AND v.Bs = N'Billed',   1, 0),
            D = IIF(b.Ins = 1 AND v.Bs = N'Unbilled', 1, 0)) s
    CROSS APPLY (SELECT
            D1 = IIF(s.D = 1 AND v.Fs = N'Charge Not Created',                1, 0),
            D5 = IIF(s.D = 1 AND v.Fs = N'Charges Created and Not Submitted', 1, 0)) u
    CROSS APPLY (VALUES
        (N'A',      v.Ok),
        (N'B',      b.Ins),
        (LEFT(N'B.' + v.Pn, 100), IIF(b.Ins = 1 AND v.Pn <> N'', 1, 0)),
        (N'C',      s.C),
        (N'C.1',    IIF(s.C = 1 AND v.Fs = N'Claim Submitted in Webpm',              1, 0)),
        (N'C.2',    IIF(s.C = 1 AND v.Fs = N'Claim Submitted in Daqbilling',         1, 0)),
        (N'C.3',    IIF(s.C = 1 AND v.Fs = N'Claim Submitted in Daq & Webpm',        1, 0)),
        (N'C.4',    IIF(s.C = 1 AND v.Fs = N'Non Billable - Excluded Organizations', 1, 0)),
        (N'C.5',    IIF(s.C = 1 AND v.Fs = N'Manually Pushed in Emedix',             1, 0)),
        (N'D',      s.D),
        (N'D.1',    u.D1),
        (N'D.1.W',  IIF(u.D1 = 1 AND v.Src = N'Webpm', 1, 0)),
        (N'D.1.NC', IIF(u.D1 = 1 AND v.Src = N'Webpm' AND v.Cne = N'No Charges found in Webpm', 1, 0)),
        (N'D.1.UP', IIF(u.D1 = 1 AND v.Src = N'Webpm' AND v.Cne = N'Unposted Charges in Webpm', 1, 0)),
        (N'D.1.DQ', IIF(u.D1 = 1 AND v.Src = N'Daqbilling', 1, 0)),
        (N'D.2',    IIF(s.D = 1 AND v.Fs = N'Non Billable - Excluded PAP Codes',      1, 0)),
        (N'D.3',    IIF(s.D = 1 AND v.Fs = N'Non Billable - Excluded Validity Codes', 1, 0)),
        (N'D.4',    IIF(s.D = 1 AND v.Fs = N'Non Billable - Excluded Organizations',  1, 0)),
        (N'D.5',    u.D5),
        (N'D.5.W',  IIF(u.D5 = 1 AND v.Src = N'Webpm',      1, 0)),
        (N'D.5.DQ', IIF(u.D5 = 1 AND v.Src = N'Daqbilling', 1, 0)),
        (N'E',      IIF(v.Ok = 1 AND v.Bt = N'ADCS Claims', 1, 0)),
        (N'F',      IIF(v.Ok = 1 AND v.Bt NOT IN (N'Insurance Bill', N'ADCS Claims'), 1, 0)),
        (N'F.1',    IIF(v.Ok = 1 AND v.Bt = N'Yet to be validate', 1, 0)),
        (N'F.2',    IIF(v.Ok = 1 AND v.Bt = N'Self pay',           1, 0)),
        (N'F.3',    IIF(v.Ok = 1 AND v.Bt = N'Client Bills',       1, 0)),
        (N'F.4',    IIF(v.Ok = 1 AND v.Bt = N'Rejections',         1, 0)),
        (N'F.5',    IIF(v.Ok = 1 AND v.Bt = N'System Test',        1, 0))
    ) m(RowCode, Hit)
    WHERE m.Hit = 1;
GO

/* -----------------------------------------------------------------------------
   PMS (Value = 1) and Cash (Value = amount) rows a ClaimLevelData claim counts in
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_ES_ClaimRowCodes
(
    @BilledUnbilled NVARCHAR(500),
    @ClaimType      NVARCHAR(500),
    @ClaimStatus    NVARCHAR(500),
    @Charge         DECIMAL(18,2),
    @InsPay         DECIMAL(18,2),
    @ActualPay      DECIMAL(18,2),
    @DuplicatePay   DECIMAL(18,2),
    @PatientPay     DECIMAL(18,2),
    @InsBalance     DECIMAL(18,2),
    @PatBalance     DECIMAL(18,2)
)
RETURNS TABLE
AS
RETURN
    SELECT m.Category, m.RowCode, m.Value
    FROM (SELECT
            Bu = LTRIM(RTRIM(ISNULL(@BilledUnbilled, N''))),
            Ct = LTRIM(RTRIM(ISNULL(@ClaimType,      N''))),
            Cs = LTRIM(RTRIM(ISNULL(@ClaimStatus,    N'')))) v
    CROSS APPLY (SELECT
            Billed   = IIF(v.Bu = N'Billed', 1, 0),
            Std      = IIF(v.Ct IN (N'ADCS - Invoice', N'Test Patient Entries'), 0, 1),
            Src      = CASE WHEN v.Ct = N'Claim Submitted in Webpm' THEN 1
                            WHEN v.Ct IN (N'Claim Submitted in Daqbilling', N'Claim Submitted in Daq Billing') THEN 2
                            WHEN v.Ct = N'Manually Pushed in Emedix' THEN 3
                            ELSE 0 END,
            Cs       = CASE WHEN v.Cs IN (N'Unbilled in Webpm PR', N'Unbilled in Webpm - PR', N'Unbilled in Webpm -PR') THEN N'Unbilled in Webpm PR'
                            WHEN v.Cs IN (N'Unbilled in Daq PR',   N'Unbilled in Daq - PR',   N'Unbilled in Daq -PR')   THEN N'Unbilled in Daq PR'
                            WHEN v.Cs IN (N'Partially Paid', N'Partial Paid') THEN N'Partially Paid'
                            ELSE v.Cs END) f
    CROSS APPLY (SELECT
            G  = IIF(f.Billed = 1 AND f.Src <> 0 AND f.Cs <> N'Billed Amount 0', 1, 0),
            Gs = IIF(f.Billed = 1 AND f.Cs <> N'Billed Amount 0', f.Src, 0),
            H  = IIF(f.Std = 1 AND f.Cs IN (N'Billed Amount 0', N'Unbilled in Daq', N'Unbilled in Daq PR',
                                            N'Unbilled in Webpm', N'Unbilled in Webpm PR'), 1, 0),
            Bs = IIF(f.Billed = 1 AND f.Src <> 0, 1, 0)) k
    CROSS APPLY (VALUES
        (N'PMS',  N'G',    k.G,                                                         CAST(1 AS DECIMAL(18,2))),
        (N'PMS',  N'G.1',  IIF(k.Gs = 1, 1, 0),                                         1),
        (N'PMS',  N'G.2',  IIF(k.Gs = 2, 1, 0),                                         1),
        (N'PMS',  N'G.3',  IIF(k.Gs = 3, 1, 0),                                         1),
        (N'PMS',  N'H',    k.H,                                                         1),
        (N'PMS',  N'H.1',  IIF(f.Std = 1 AND f.Cs = N'Unbilled in Webpm PR', 1, 0),      1),
        (N'PMS',  N'H.2',  IIF(f.Std = 1 AND f.Cs = N'Unbilled in Webpm',    1, 0),      1),
        (N'PMS',  N'H.3',  IIF(f.Std = 1 AND f.Cs = N'Unbilled in Daq',      1, 0),      1),
        (N'PMS',  N'H.4',  IIF(f.Std = 1 AND f.Cs = N'Unbilled in Daq PR',   1, 0),      1),
        (N'PMS',  N'H.5',  IIF(f.Std = 1 AND f.Cs = N'Billed Amount 0',      1, 0),      1),
        (N'PMS',  N'J',    IIF(v.Ct = N'Test Patient Entries', 1, 0),                   1),
        (N'PMS',  N'K',    IIF(v.Ct = N'ADCS - Invoice',       1, 0),                   1),
        (N'PMS',  N'M',    IIF(f.Std = 1 AND f.Cs = N'Fully Paid',         1, 0),       1),
        (N'PMS',  N'N',    IIF(f.Std = 1 AND f.Cs = N'Pat Responsibility', 1, 0),       1),
        (N'PMS',  N'O',    IIF(f.Std = 1 AND f.Cs = N'Fully Adjusted',     1, 0),       1),
        (N'PMS',  N'P',    IIF(f.Std = 1 AND f.Cs = N'Partially Adjusted', 1, 0),       1),
        (N'PMS',  N'Q',    IIF(f.Std = 1 AND f.Cs = N'Partially Paid',     1, 0),       1),
        (N'PMS',  N'R',    IIF(f.Std = 1 AND f.Cs = N'Patient Paid',       1, 0),       1),
        (N'PMS',  N'S',    IIF(f.Std = 1 AND f.Cs IN (N'Fully Denied', N'Partially Denied', N'No Response'), 1, 0), 1),
        (N'PMS',  N'S.1',  IIF(f.Std = 1 AND f.Cs = N'Fully Denied',       1, 0),       1),
        (N'PMS',  N'S.2',  IIF(f.Std = 1 AND f.Cs = N'Partially Denied',   1, 0),       1),
        (N'PMS',  N'S.3',  IIF(f.Std = 1 AND f.Cs = N'No Response',        1, 0),       1),

        (N'Cash', N'T',    k.G,                                                         @Charge),
        (N'Cash', N'T.1',  IIF(k.Gs = 1, 1, 0),                                         @Charge),
        (N'Cash', N'T.2',  IIF(k.Gs = 2, 1, 0),                                         @Charge),
        (N'Cash', N'T.3',  IIF(k.Gs = 3, 1, 0),                                         @Charge),
        (N'Cash', N'U',    k.H,                                                         @Charge),
        (N'Cash', N'U.1',  IIF(f.Std = 1 AND f.Cs = N'Unbilled in Webpm PR', 1, 0),     @Charge),
        (N'Cash', N'U.2',  IIF(f.Std = 1 AND f.Cs = N'Unbilled in Webpm',    1, 0),     @Charge),
        (N'Cash', N'U.3',  IIF(f.Std = 1 AND f.Cs = N'Unbilled in Daq',      1, 0),     @Charge),
        (N'Cash', N'U.4',  IIF(f.Std = 1 AND f.Cs = N'Unbilled in Daq PR',   1, 0),     @Charge),
        (N'Cash', N'V',    IIF(v.Ct = N'Test Patient Entries', 1, 0),                   @Charge),
        (N'Cash', N'W',    IIF(v.Ct = N'ADCS - Invoice',       1, 0),                   @Charge),
        (N'Cash', N'X',    IIF(f.Std = 1 AND f.Cs = N'Fully Paid', 1, 0),               @InsPay),
        (N'Cash', N'X.1',  IIF(f.Std = 1 AND f.Cs = N'Fully Paid', 1, 0),               @ActualPay),
        (N'Cash', N'X.2',  IIF(f.Std = 1 AND f.Cs = N'Fully Paid', 1, 0),               @DuplicatePay),
        (N'Cash', N'Y',    k.Bs,                                                        @PatBalance),
        (N'Cash', N'AA',   IIF(k.Bs = 1 AND f.Cs = N'Partially Paid', 1, 0),            @InsPay),
        (N'Cash', N'AA.1', IIF(k.Bs = 1 AND f.Cs = N'Partially Paid', 1, 0),            IIF(@ActualPay <> 0, @ActualPay, @InsPay)),
        (N'Cash', N'AA.2', IIF(k.Bs = 1 AND f.Cs = N'Partially Paid', 1, 0),            @DuplicatePay),
        (N'Cash', N'AB',   k.Bs,                                                        @PatientPay),
        (N'Cash', N'AC',   k.Bs,                                                        @InsBalance),
        (N'Cash', N'AC.1', IIF(k.Bs = 1 AND f.Cs = N'Fully Denied', 1, 0),              @InsBalance),
        (N'Cash', N'AC.2', IIF(k.Bs = 1 AND f.Cs NOT IN (N'Fully Denied', N'No Response'), 1, 0), @InsBalance),
        (N'Cash', N'AC.3', IIF(k.Bs = 1 AND f.Cs = N'No Response', 1, 0),               @InsBalance)
    ) m(Category, RowCode, Hit, Value)
    WHERE m.Hit = 1;
GO

/* -----------------------------------------------------------------------------
   LIMSMaster / ClaimLevelData rows after the page filters
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_ES_LisSamples
(
    @YearFrom  INT,           @YearTo  INT,
    @MonthFrom INT,           @MonthTo INT,
    @DosFrom   DATE,          @DosTo   DATE,
    @Panels    NVARCHAR(MAX), @Clinics NVARCHAR(MAX), @Providers NVARCHAR(MAX)
)
RETURNS TABLE
AS
RETURN
    SELECT
        l.Accession,
        ServiceDate = l.RequestCollectDate,
        ESYear      = YEAR(l.RequestCollectDate),
        ESMonth     = MONTH(l.RequestCollectDate),
        l.IncorrectDOS, l.BilledTo, l.BillStatus, l.FinalStatus,
        Source      = l.SourceSystem,
        l.ChargesNotEnteredStatus,
        l.PanelType
    FROM dbo.LIMSMaster l
    WHERE l.RequestCollectDate IS NOT NULL
      AND (ISNULL(@YearFrom,  0) = 0 OR YEAR(l.RequestCollectDate)  >= @YearFrom)
      AND (ISNULL(@YearTo,    0) = 0 OR YEAR(l.RequestCollectDate)  <= @YearTo)
      AND (ISNULL(@MonthFrom, 0) = 0 OR MONTH(l.RequestCollectDate) >= @MonthFrom)
      AND (ISNULL(@MonthTo,   0) = 0 OR MONTH(l.RequestCollectDate) <= @MonthTo)
      AND (@DosFrom IS NULL OR l.RequestCollectDate >= @DosFrom)
      AND (@DosTo   IS NULL OR l.RequestCollectDate <= @DosTo)
      AND (NULLIF(LTRIM(RTRIM(@Panels)), N'') IS NULL
           OR LTRIM(RTRIM(l.PanelType)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Panels, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Clinics)), N'') IS NULL
           OR LTRIM(RTRIM(l.ClinicName)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Clinics, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NULL
           OR LTRIM(RTRIM(l.ReferringProvider)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Providers, N',')));
GO

CREATE OR ALTER FUNCTION dbo.fn_NW_ES_Claims
(
    @YearFrom   INT,           @YearTo     INT,
    @MonthFrom  INT,           @MonthTo    INT,
    @DosFrom    DATE,          @DosTo      DATE,
    @BilledFrom DATE,          @BilledTo   DATE,
    @Panels     NVARCHAR(MAX), @Clinics    NVARCHAR(MAX),
    @Providers  NVARCHAR(MAX), @Reps       NVARCHAR(MAX)
)
RETURNS TABLE
AS
RETURN
    SELECT
        ClaimID         = LTRIM(RTRIM(c.ClaimID)),
        AccessionNumber = LTRIM(RTRIM(c.AccessionNumber)),
        DateofService   = d.Dos,
        FirstBilledDate = d.FirstBill,
        ESYear          = YEAR(d.Dos),
        ESMonth         = MONTH(d.Dos),
        BilledUnbilled  = LTRIM(RTRIM(ISNULL(c.BilledUnbilled, N''))),
        ClaimType       = LTRIM(RTRIM(ISNULL(CAST(c.ClaimType AS NVARCHAR(500)), N''))),
        ClaimStatus     = LTRIM(RTRIM(ISNULL(c.ClaimStatus, N''))),
        ChargeAmount         = ISNULL(TRY_CAST(c.ChargeAmount           AS DECIMAL(18,2)), 0),
        InsurancePayment     = ISNULL(TRY_CAST(c.InsurancePayment       AS DECIMAL(18,2)), 0),
        ActualPayment        = ISNULL(TRY_CAST(c.ActualPayment          AS DECIMAL(18,2)), 0),
        DuplicatePayment     = ISNULL(TRY_CAST(c.DuplicatePaymentPosted AS DECIMAL(18,2)), 0),
        PatientPayment       = ISNULL(TRY_CAST(c.PatientPayment         AS DECIMAL(18,2)), 0),
        InsuranceAdjustments = ISNULL(TRY_CAST(c.InsuranceAdjustments   AS DECIMAL(18,2)), 0),
        PatientAdjustments   = ISNULL(TRY_CAST(c.PatientAdjustments     AS DECIMAL(18,2)), 0),
        InsuranceBalance     = ISNULL(TRY_CAST(c.InsuranceBalance       AS DECIMAL(18,2)), 0),
        PatientBalance       = ISNULL(TRY_CAST(c.PatientBalance         AS DECIMAL(18,2)), 0)
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateofService,   101), TRY_CAST(c.DateofService   AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE))) p
    CROSS APPLY (SELECT
        Dos       = CASE WHEN p.Dos       >= '19010101' THEN p.Dos       END,
        FirstBill = CASE WHEN p.FirstBill >= '19010101' THEN p.FirstBill END) d
    WHERE d.Dos IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(c.AccessionNumber)), N'') IS NOT NULL
      AND (ISNULL(@YearFrom,  0) = 0 OR YEAR(d.Dos)  >= @YearFrom)
      AND (ISNULL(@YearTo,    0) = 0 OR YEAR(d.Dos)  <= @YearTo)
      AND (ISNULL(@MonthFrom, 0) = 0 OR MONTH(d.Dos) >= @MonthFrom)
      AND (ISNULL(@MonthTo,   0) = 0 OR MONTH(d.Dos) <= @MonthTo)
      AND (@DosFrom    IS NULL OR d.Dos       >= @DosFrom)
      AND (@DosTo      IS NULL OR d.Dos       <= @DosTo)
      AND (@BilledFrom IS NULL OR d.FirstBill >= @BilledFrom)
      AND (@BilledTo   IS NULL OR d.FirstBill <= @BilledTo)
      AND (NULLIF(LTRIM(RTRIM(@Panels)), N'') IS NULL
           OR LTRIM(RTRIM(c.PanelType)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Panels, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Clinics)), N'') IS NULL
           OR LTRIM(RTRIM(c.ClinicName)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Clinics, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NULL
           OR LTRIM(RTRIM(c.ReferringProvider)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Providers, N',')))
      AND (NULLIF(LTRIM(RTRIM(@Reps)), N'') IS NULL
           OR LTRIM(RTRIM(c.SalesRepname)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Reps, N',')));
GO

/* -----------------------------------------------------------------------------
   All Executive Summary rows for the given filters.
   Result: RowCode, Category, Description, BillYear, BillMonth, MetricValue (page contract),
           then Seq, ClaimCount, Amount (snapshot columns).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_NW_ES_Build
    @YearFrom   INT           = NULL,
    @YearTo     INT           = NULL,
    @MonthFrom  INT           = NULL,
    @MonthTo    INT           = NULL,
    @DosFrom    DATE          = NULL,
    @DosTo      DATE          = NULL,
    @BilledFrom DATE          = NULL,
    @BilledTo   DATE          = NULL,
    @Panels     NVARCHAR(MAX) = NULL,
    @Clinics    NVARCHAR(MAX) = NULL,
    @Providers  NVARCHAR(MAX) = NULL,
    @Reps       NVARCHAR(MAX) = NULL,
    @LisOnly    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Agg
    (
        Category NVARCHAR(10)  COLLATE DATABASE_DEFAULT NOT NULL,
        RowCode  NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear   INT           NOT NULL,
        ESMonth  INT           NOT NULL,
        Cnt      BIGINT        NOT NULL,
        Amt      DECIMAL(19,2) NOT NULL
    );

    CREATE TABLE #Periods
    (
        Kind    NVARCHAR(3) COLLATE DATABASE_DEFAULT NOT NULL,
        ESYear  INT         NOT NULL,
        ESMonth INT         NOT NULL
    );

    CREATE TABLE #Out
    (
        Category    NVARCHAR(10)  COLLATE DATABASE_DEFAULT NOT NULL,
        RowCode     NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
        Seq         INT           NOT NULL,
        ESYear      INT           NOT NULL,
        ESMonth     INT           NOT NULL,
        ClaimCount  BIGINT        NOT NULL,
        Amount      DECIMAL(19,6) NOT NULL
    );

    /* ---- LIS Breakdown ---- */
    INSERT INTO #Agg (Category, RowCode, ESYear, ESMonth, Cnt, Amt)
    SELECT N'LIS', r.RowCode,
           IIF(GROUPING(l.ESYear)  = 1, 0, l.ESYear),
           IIF(GROUPING(l.ESMonth) = 1, 0, l.ESMonth),
           COUNT_BIG(*), 0
    FROM dbo.fn_NW_ES_LisSamples(@YearFrom, @YearTo, @MonthFrom, @MonthTo, @DosFrom, @DosTo,
                                 @Panels, @Clinics, @Providers) l
    CROSS APPLY dbo.fn_NW_ES_LisRowCodes(l.IncorrectDOS, l.BilledTo, l.BillStatus, l.FinalStatus,
                                         l.Source, l.ChargesNotEnteredStatus, l.PanelType) r
    GROUP BY GROUPING SETS ((r.RowCode, l.ESYear, l.ESMonth), (r.RowCode, l.ESYear), (r.RowCode));

    INSERT INTO #Periods (Kind, ESYear, ESMonth)
    SELECT DISTINCT N'LIS', ESYear, ESMonth FROM #Agg WHERE Category = N'LIS'
    UNION
    SELECT N'LIS', 0, 0;

    /* ---- PMS / Cash ---- */
    IF @LisOnly = 0
    BEGIN
        SELECT ESYear, ESMonth, FirstBilledDate, BilledUnbilled, ClaimType, ClaimStatus,
               ChargeAmount, InsurancePayment, ActualPayment, DuplicatePayment,
               PatientPayment, InsuranceBalance, PatientBalance
        INTO #C
        FROM dbo.fn_NW_ES_Claims(@YearFrom, @YearTo, @MonthFrom, @MonthTo, @DosFrom, @DosTo,
                                 @BilledFrom, @BilledTo, @Panels, @Clinics, @Providers, @Reps);

        INSERT INTO #Agg (Category, RowCode, ESYear, ESMonth, Cnt, Amt)
        SELECT r.Category, r.RowCode,
               IIF(GROUPING(c.ESYear)  = 1, 0, c.ESYear),
               IIF(GROUPING(c.ESMonth) = 1, 0, c.ESMonth),
               COUNT_BIG(*), SUM(r.Value)
        FROM #C c
        CROSS APPLY dbo.fn_NW_ES_ClaimRowCodes(c.BilledUnbilled, c.ClaimType, c.ClaimStatus,
                                               c.ChargeAmount, c.InsurancePayment, c.ActualPayment,
                                               c.DuplicatePayment, c.PatientPayment,
                                               c.InsuranceBalance, c.PatientBalance) r
        GROUP BY GROUPING SETS ((r.Category, r.RowCode, c.ESYear, c.ESMonth),
                                (r.Category, r.RowCode, c.ESYear),
                                (r.Category, r.RowCode));

        INSERT INTO #Periods (Kind, ESYear, ESMonth)
        SELECT DISTINCT N'CLM', ESYear, ESMonth FROM #C
        UNION SELECT DISTINCT N'CLM', ESYear, 0 FROM #C
        UNION SELECT N'CLM', 0, 0;

        /* Aria cohorts: S.1 (Fully Denied) and S.3 (No Response) claims */
        SELECT r.RowCode, c.ESYear, c.ESMonth, c.FirstBilledDate, c.InsuranceBalance
        INTO #Aria
        FROM #C c
        CROSS APPLY dbo.fn_NW_ES_ClaimRowCodes(c.BilledUnbilled, c.ClaimType, c.ClaimStatus,
                                               c.ChargeAmount, c.InsurancePayment, c.ActualPayment,
                                               c.DuplicatePayment, c.PatientPayment,
                                               c.InsuranceBalance, c.PatientBalance) r
        WHERE r.RowCode IN (N'S.1', N'S.3');
    END;

    /* ---- Every row for every period of its source ---- */
    INSERT INTO #Out (Category, RowCode, Description, Seq, ESYear, ESMonth, ClaimCount, Amount)
    SELECT d.Category, d.RowCode, d.Description, d.Seq, p.ESYear, p.ESMonth,
           IIF(d.Category IN (N'LIS', N'PMS'), ISNULL(a.Cnt, 0), 0),
           IIF(d.Category = N'Cash', ISNULL(a.Amt, 0), 0)
    FROM dbo.fn_NW_ES_RowDefs() d
    JOIN #Periods p
      ON p.Kind = IIF(d.Category = N'LIS', N'LIS', N'CLM')
    LEFT JOIN #Agg a
      ON a.Category = d.Category AND a.RowCode = d.RowCode
     AND a.ESYear = p.ESYear AND a.ESMonth = p.ESMonth;

    INSERT INTO #Out (Category, RowCode, Description, Seq, ESYear, ESMonth, ClaimCount, Amount)
    SELECT N'LIS', a.RowCode, N'  ' + SUBSTRING(a.RowCode, 3, 100), 21, a.ESYear, a.ESMonth, a.Cnt, 0
    FROM #Agg a
    WHERE a.Category = N'LIS' AND a.RowCode LIKE N'B.%';

    IF @LisOnly = 0
    BEGIN
        /* I = G - LIS C */
        UPDATE i
        SET i.ClaimCount = g.ClaimCount - ISNULL(c.ClaimCount, 0)
        FROM #Out i
        JOIN #Out g      ON g.Category = N'PMS' AND g.RowCode = N'G' AND g.ESYear = i.ESYear AND g.ESMonth = i.ESMonth
        LEFT JOIN #Out c ON c.Category = N'LIS' AND c.RowCode = N'C' AND c.ESYear = i.ESYear AND c.ESMonth = i.ESMonth
        WHERE i.Category = N'PMS' AND i.RowCode = N'I';

        /* Z = T - X - AA - AB - Y - AC */
        WITH v AS (
            SELECT ESYear, ESMonth,
                   Z = SUM(CASE RowCode WHEN N'T' THEN Amount
                                        WHEN N'X' THEN -Amount WHEN N'AA' THEN -Amount
                                        WHEN N'AB' THEN -Amount WHEN N'Y' THEN -Amount
                                        WHEN N'AC' THEN -Amount ELSE 0 END)
            FROM #Out
            WHERE Category = N'Cash'
            GROUP BY ESYear, ESMonth)
        UPDATE o SET o.Amount = v.Z
        FROM #Out o
        JOIN v ON v.ESYear = o.ESYear AND v.ESMonth = o.ESMonth
        WHERE o.Category = N'Cash' AND o.RowCode = N'Z';

        /* Aria: as-of = latest FirstBilledDate of the status within the DOS period */
        SELECT a.RowCode,
               ESYear  = IIF(GROUPING(a.ESYear)  = 1, 0, a.ESYear),
               ESMonth = IIF(GROUPING(a.ESMonth) = 1, 0, a.ESMonth),
               AsOf    = MAX(a.FirstBilledDate)
        INTO #AsOf
        FROM #Aria a
        GROUP BY GROUPING SETS ((a.RowCode, a.ESYear, a.ESMonth), (a.RowCode, a.ESYear), (a.RowCode));

        WITH w AS (
            SELECT a.RowCode, k.ESYear, k.ESMonth,
                   InCnt  = SUM(IIF(DATEDIFF(DAY, a.FirstBilledDate, s.AsOf) BETWEEN 0 AND 30, 1, 0)),
                   OutCnt = SUM(IIF(DATEDIFF(DAY, a.FirstBilledDate, s.AsOf) BETWEEN 0 AND 30, 0, 1)),
                   InBal  = SUM(IIF(DATEDIFF(DAY, a.FirstBilledDate, s.AsOf) BETWEEN 0 AND 30, a.InsuranceBalance, 0)),
                   OutBal = SUM(IIF(DATEDIFF(DAY, a.FirstBilledDate, s.AsOf) BETWEEN 0 AND 30, 0, a.InsuranceBalance))
            FROM #Aria a
            CROSS APPLY (VALUES (a.ESYear, a.ESMonth), (a.ESYear, 0), (0, 0)) k(ESYear, ESMonth)
            JOIN #AsOf s ON s.RowCode = a.RowCode AND s.ESYear = k.ESYear AND s.ESMonth = k.ESMonth
            GROUP BY a.RowCode, k.ESYear, k.ESMonth)
        UPDATE o
        SET o.ClaimCount = CASE WHEN o.Category = N'PMS' AND m.Part = N'A1' THEN w.InCnt
                                WHEN o.Category = N'PMS' AND m.Part = N'A2' THEN w.OutCnt
                                ELSE 0 END,
            o.Amount     = CASE m.Part
                               WHEN N'A1' THEN CAST(IIF(o.Category = N'Cash', w.InBal, 0) AS DECIMAL(19,6))
                               WHEN N'A2' THEN CAST(IIF(o.Category = N'Cash', w.OutBal, 0) AS DECIMAL(19,6))
                               ELSE CAST(IIF(o.Category = N'Cash',
                                        IIF(w.OutBal <> 0, CAST(w.InBal AS FLOAT) / CAST(w.OutBal AS FLOAT), 0),
                                        IIF(w.OutCnt <> 0, CAST(w.InCnt AS FLOAT) / w.OutCnt, 0)) AS DECIMAL(19,6))
                           END
        FROM #Out o
        JOIN (VALUES
                (N'PMS',  N'S.1.A1',  N'S.1', N'A1'), (N'PMS',  N'S.1.A2',  N'S.1', N'A2'), (N'PMS',  N'S.1.AP',  N'S.1', N'AP'),
                (N'PMS',  N'S.3.A1',  N'S.3', N'A1'), (N'PMS',  N'S.3.A2',  N'S.3', N'A2'), (N'PMS',  N'S.3.AP',  N'S.3', N'AP'),
                (N'Cash', N'AC.1.A1', N'S.1', N'A1'), (N'Cash', N'AC.1.A2', N'S.1', N'A2'), (N'Cash', N'AC.1.AP', N'S.1', N'AP'),
                (N'Cash', N'AC.3.A1', N'S.3', N'A1'), (N'Cash', N'AC.3.A2', N'S.3', N'A2'), (N'Cash', N'AC.3.AP', N'S.3', N'AP')
             ) m(Category, RowCode, Cohort, Part)
          ON m.Category = o.Category AND m.RowCode = o.RowCode
        JOIN w ON w.RowCode = m.Cohort AND w.ESYear = o.ESYear AND w.ESMonth = o.ESMonth;

        /* Averages (ClaimCount = denominator) */
        WITH v AS (
            SELECT ESYear, ESMonth,
                   PayAll  = SUM(IIF(Category = N'Cash' AND RowCode IN (N'X', N'AA', N'AB'), Amount, 0)),
                   PayIns  = SUM(IIF(Category = N'Cash' AND RowCode IN (N'X', N'AA'),        Amount, 0)),
                   Billed  = SUM(IIF(Category = N'PMS'  AND RowCode = N'G', ClaimCount, 0)),
                   Paid    = SUM(IIF(Category = N'PMS'  AND RowCode IN (N'M', N'Q', N'R'), ClaimCount, 0)),
                   Adjud   = SUM(IIF(Category = N'PMS'  AND RowCode IN (N'M', N'O', N'S.1', N'S.2', N'Q', N'P', N'R', N'N'), ClaimCount, 0))
            FROM #Out
            GROUP BY ESYear, ESMonth)
        UPDATE o
        SET o.ClaimCount = x.Den,
            o.Amount     = IIF(x.Den > 0, x.Num / x.Den, 0)
        FROM #Out o
        JOIN v ON v.ESYear = o.ESYear AND v.ESMonth = o.ESMonth
        CROSS APPLY (SELECT
            Num = CAST(IIF(o.RowCode = N'AF', v.PayIns, v.PayAll) AS DECIMAL(19,6)),
            Den = CASE o.RowCode WHEN N'AD' THEN v.Billed WHEN N'AE' THEN v.Paid ELSE v.Adjud END) x
        WHERE o.Category = N'Avg';
    END;

    SELECT RowCode, Category, Description,
           BillYear    = ESYear,
           BillMonth   = ESMonth,
           MetricValue = IIF(Category IN (N'LIS', N'PMS') AND RowCode NOT LIKE N'%.AP',
                             CAST(ClaimCount AS DECIMAL(19,6)), Amount),
           SortOrder   = CAST(DENSE_RANK() OVER (
                             ORDER BY CASE Category WHEN N'LIS' THEN 1 WHEN N'PMS' THEN 2 WHEN N'Cash' THEN 3 ELSE 4 END,
                                      Seq, RowCode) AS INT),
           ClaimCount, Amount
    FROM #Out
    ORDER BY ESYear, ESMonth,
             CASE Category WHEN N'LIS' THEN 1 WHEN N'PMS' THEN 2 WHEN N'Cash' THEN 3 ELSE 4 END,
             Seq, RowCode;
END;
GO

/* -----------------------------------------------------------------------------
   Snapshot refresh (all four tables) and LIS-only refresh
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        RowCode     NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        Category    NVARCHAR(10)  COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
        BillYear    INT           NOT NULL,
        BillMonth   INT           NOT NULL,
        MetricValue DECIMAL(19,6) NOT NULL,
        Seq         INT           NOT NULL,
        ClaimCount  BIGINT        NOT NULL,
        Amount      DECIMAL(19,6) NOT NULL
    );

    INSERT INTO #R
    EXEC dbo.usp_NW_ES_Build;

    DECLARE @now DATETIME = GETDATE();

    BEGIN TRAN;

    TRUNCATE TABLE dbo.NW_ES_LIS;
    TRUNCATE TABLE dbo.NW_ES_PMS;
    TRUNCATE TABLE dbo.NW_ES_Cash;
    TRUNCATE TABLE dbo.NW_ES_Avg;

    INSERT INTO dbo.NW_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RowCode, Description, BillYear, BillMonth, ClaimCount, 0, @now
    FROM #R WHERE Category = N'LIS'
    ORDER BY BillYear, BillMonth, Seq, RowCode;

    INSERT INTO dbo.NW_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RowCode, Description, BillYear, BillMonth, ClaimCount, Amount, @now
    FROM #R WHERE Category = N'PMS'
    ORDER BY BillYear, BillMonth, Seq;

    INSERT INTO dbo.NW_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RowCode, Description, BillYear, BillMonth, ClaimCount, Amount, @now
    FROM #R WHERE Category = N'Cash'
    ORDER BY BillYear, BillMonth, Seq;

    INSERT INTO dbo.NW_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RowCode, Description, BillYear, BillMonth, ClaimCount, Amount, @now
    FROM #R WHERE Category = N'Avg'
    ORDER BY BillYear, BillMonth, Seq;

    COMMIT;

    PRINT N'usp_RefreshNW_ExecutiveSummary completed.';
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        RowCode     NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        Category    NVARCHAR(10)  COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(500) COLLATE DATABASE_DEFAULT NOT NULL,
        BillYear    INT           NOT NULL,
        BillMonth   INT           NOT NULL,
        MetricValue DECIMAL(19,6) NOT NULL,
        Seq         INT           NOT NULL,
        ClaimCount  BIGINT        NOT NULL,
        Amount      DECIMAL(19,6) NOT NULL
    );

    INSERT INTO #R
    EXEC dbo.usp_NW_ES_Build @LisOnly = 1;

    DECLARE @now DATETIME = GETDATE();

    BEGIN TRAN;

    TRUNCATE TABLE dbo.NW_ES_LIS;

    INSERT INTO dbo.NW_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
    SELECT RowCode, Description, BillYear, BillMonth, ClaimCount, 0, @now
    FROM #R
    ORDER BY BillYear, BillMonth, Seq, RowCode;

    UPDATE i
    SET i.ESMonthClaimCount = g.ESMonthClaimCount - ISNULL(c.ESMonthClaimCount, 0)
    FROM dbo.NW_ES_PMS i
    JOIN dbo.NW_ES_PMS g     ON g.RoleID = N'G' AND g.ESYear = i.ESYear AND g.ESMonth = i.ESMonth
    LEFT JOIN dbo.NW_ES_LIS c ON c.RoleID = N'C' AND c.ESYear = i.ESYear AND c.ESMonth = i.ESMonth
    WHERE i.RoleID = N'I';

    COMMIT;

    PRINT N'usp_RefreshNW_ExecutiveSummary_LIS_Alt completed.';
END;
GO

/* -----------------------------------------------------------------------------
   Page read: snapshot when unfiltered, live build when filtered
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ExecutiveSummary
(
    @YearFrom     INT           = 0,
    @YearTo       INT           = 0,
    @MonthFrom    INT           = 0,
    @MonthTo      INT           = 0,
    @DosFrom      DATE          = NULL,
    @DosTo        DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    @Panels       NVARCHAR(MAX) = NULL,
    @Clinics      NVARCHAR(MAX) = NULL,
    @Providers    NVARCHAR(MAX) = NULL,
    @Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@YearFrom, 0) = 0 AND ISNULL(@YearTo, 0) = 0
       AND ISNULL(@MonthFrom, 0) = 0 AND ISNULL(@MonthTo, 0) = 0
       AND @DosFrom IS NULL AND @DosTo IS NULL
       AND @BilledFrom IS NULL AND @BilledTo IS NULL
       AND NULLIF(LTRIM(RTRIM(@Panels)),    N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@Clinics)),   N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@Reps)),      N'') IS NULL
    BEGIN
        -- Aria % rows are recomputed from A1 / A2: the table column keeps 2 decimals.
        WITH t AS (
            SELECT RowCode = RoleID, Category = N'LIS', Description, BillYear = ESYear, BillMonth = ESMonth,
                   V = CAST(ESMonthClaimCount AS DECIMAL(19,6)), CatOrder = 1, Id
            FROM dbo.NW_ES_LIS
            UNION ALL
            SELECT RoleID, N'PMS', Description, ESYear, ESMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(19,6)), 2, Id
            FROM dbo.NW_ES_PMS
            UNION ALL
            SELECT RoleID, N'Cash', Description, ESYear, ESMonth,
                   CAST(ESMonthChargeAmount AS DECIMAL(19,6)), 3, Id
            FROM dbo.NW_ES_Cash
            UNION ALL
            SELECT RoleID, N'Avg', Description, ESYear, ESMonth,
                   CAST(ESMonthChargeAmount AS DECIMAL(19,6)), 4, Id
            FROM dbo.NW_ES_Avg),
        r AS (
            SELECT Category, RowCode, FirstId = MIN(Id), CatOrder = MIN(CatOrder)
            FROM t GROUP BY Category, RowCode),
        o AS (
            SELECT Category, RowCode, SortOrder = CAST(DENSE_RANK() OVER (ORDER BY CatOrder, FirstId) AS INT)
            FROM r)
        SELECT t.RowCode, t.Category, t.Description, t.BillYear, t.BillMonth,
               MetricValue = IIF(a1.RowCode IS NULL, t.V, ISNULL(a1.V / NULLIF(a2.V, 0), 0)),
               o.SortOrder
        FROM t
        JOIN o ON o.Category = t.Category AND o.RowCode = t.RowCode
        LEFT JOIN t a1
          ON t.Category IN (N'PMS', N'Cash') AND t.RowCode LIKE N'%.AP'
         AND a1.Category = t.Category AND a1.BillYear = t.BillYear AND a1.BillMonth = t.BillMonth
         AND a1.RowCode = LEFT(t.RowCode, IIF(LEN(t.RowCode) > 2, LEN(t.RowCode) - 2, 0)) + N'A1'
        LEFT JOIN t a2
          ON a1.RowCode IS NOT NULL
         AND a2.Category = t.Category AND a2.BillYear = t.BillYear AND a2.BillMonth = t.BillMonth
         AND a2.RowCode = LEFT(t.RowCode, IIF(LEN(t.RowCode) > 2, LEN(t.RowCode) - 2, 0)) + N'A2'
        ORDER BY t.BillYear, t.BillMonth, t.CatOrder, t.Id;
        RETURN;
    END;

    EXEC dbo.usp_NW_ES_Build
        @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
        @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
        @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;
END;
GO

/* -----------------------------------------------------------------------------
   Cell drills: the samples / claims behind a cell (@Year / @Month = 0 -> all)
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LIS
(
    @RowCode  NVARCHAR(100) = N'',
    @Year     INT           = 0,
    @Month    INT           = 0,
    @Category NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        OrderID     = l.Accession,
        l.ServiceDate,
        l.IncorrectDOS,
        l.BilledTo,
        l.BillStatus,
        l.FinalStatus,
        l.Source,
        l.ChargesNotEnteredStatus,
        PanelName   = l.PanelType
    FROM dbo.fn_NW_ES_LisSamples(NULLIF(@Year, 0), NULLIF(@Year, 0), NULLIF(@Month, 0), NULLIF(@Month, 0),
                                 NULL, NULL, NULL, NULL, NULL) l
    WHERE EXISTS (SELECT 1
                  FROM dbo.fn_NW_ES_LisRowCodes(l.IncorrectDOS, l.BilledTo, l.BillStatus, l.FinalStatus,
                                                l.Source, l.ChargesNotEnteredStatus, l.PanelType) r
                  WHERE r.RowCode = @RowCode)
    ORDER BY l.ServiceDate, l.Accession;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PMSCash
(
    @RowCode  NVARCHAR(100) = N'',
    @Year     INT           = 0,
    @Month    INT           = 0,
    @Category NVARCHAR(50)  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Derived rows list the claims they are calculated from.
    DECLARE @Codes NVARCHAR(200) = CASE @RowCode
        WHEN N'I'  THEN N'G'
        WHEN N'Z'  THEN N'T'
        WHEN N'AD' THEN N'G'
        WHEN N'AE' THEN N'M,Q,R'
        WHEN N'AF' THEN N'M,O,S.1,S.2,Q,P,R,N'
        WHEN N'S.1.A1'  THEN N'S.1' WHEN N'S.1.A2'  THEN N'S.1' WHEN N'S.1.AP'  THEN N'S.1'
        WHEN N'S.3.A1'  THEN N'S.3' WHEN N'S.3.A2'  THEN N'S.3' WHEN N'S.3.AP'  THEN N'S.3'
        WHEN N'AC.1.A1' THEN N'S.1' WHEN N'AC.1.A2' THEN N'S.1' WHEN N'AC.1.AP' THEN N'S.1'
        WHEN N'AC.3.A1' THEN N'S.3' WHEN N'AC.3.A2' THEN N'S.3' WHEN N'AC.3.AP' THEN N'S.3'
        ELSE @RowCode END;

    -- Aria: 1 = submitted in the last 30 days, 2 = not submitted, NULL = both
    DECLARE @AriaPart INT = CASE WHEN @RowCode LIKE N'%.A1' THEN 1 WHEN @RowCode LIKE N'%.A2' THEN 2 END;

    SELECT c.*
    INTO #D
    FROM dbo.fn_NW_ES_Claims(NULLIF(@Year, 0), NULLIF(@Year, 0), NULLIF(@Month, 0), NULLIF(@Month, 0),
                             NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) c
    WHERE EXISTS (SELECT 1
                  FROM dbo.fn_NW_ES_ClaimRowCodes(c.BilledUnbilled, c.ClaimType, c.ClaimStatus,
                                                  c.ChargeAmount, c.InsurancePayment, c.ActualPayment,
                                                  c.DuplicatePayment, c.PatientPayment,
                                                  c.InsuranceBalance, c.PatientBalance) r
                  WHERE r.RowCode IN (SELECT value FROM STRING_SPLIT(@Codes, N',')));

    DECLARE @AsOf DATE = (SELECT MAX(FirstBilledDate) FROM #D);

    SELECT
        d.ClaimID,
        d.AccessionNumber,
        d.DateofService,
        d.FirstBilledDate,
        d.BilledUnbilled,
        d.ClaimType,
        d.ClaimStatus,
        d.ChargeAmount,
        d.InsurancePayment,
        d.ActualPayment,
        d.DuplicatePayment,
        d.PatientPayment,
        d.InsuranceAdjustments,
        d.PatientAdjustments,
        d.InsuranceBalance,
        d.PatientBalance
    FROM #D d
    WHERE @AriaPart IS NULL
       OR (@AriaPart = 1 AND DATEDIFF(DAY, d.FirstBilledDate, @AsOf) BETWEEN 0 AND 30)
       OR (@AriaPart = 2 AND NOT (ISNULL(DATEDIFF(DAY, d.FirstBilledDate, @AsOf), -1) BETWEEN 0 AND 30))
    ORDER BY d.DateofService, d.AccessionNumber;
END;
GO

/* -----------------------------------------------------------------------------
   Rebuild the snapshot
   ----------------------------------------------------------------------------- */
EXEC dbo.usp_RefreshNW_ExecutiveSummary;
GO

PRINT N'44_NW_ExecutiveSummary_BilledUnbilled.sql completed.';
GO

/* =============================================================================
   NorthWest - Executive Summary: client validation 10/29/2026
   File     : 52_NW_ExecutiveSummary_Validation1029.sql
   Database : NWL_LRN
   Requires : 44_NW_ExecutiveSummary_BilledUnbilled.sql, 50_NW_ExecutiveSummary_CellRows.sql
   Source   : NW Executive Summary Validation 10292026.xlsx,
              North West_StandardReport_Logics_v1.9_10.29.2026.xlsx (Executive Summary)

   Changes to 44:
   1. Billed claims ("Bs") = BilledUnbilled = Billed AND Claim Type NOT IN (ADCS - Invoice,
      Test Patient Entries). Was: Claim Type IN (Claim Submitted in Webpm / Daqbilling,
      Manually Pushed in Emedix), which left out billed claims typed "Unbilled in Webpm".
        G  = Bs AND Claim Status <> Billed Amount 0;  T = Charge of G
        G.1 / T.1  Claim Type contains Webpm   (Claim Submitted in Webpm, Unbilled in Webpm)
        G.2 / T.2  Claim Type contains Daq     (Claim Submitted in Daqbilling, Unbilled in Daqbilling)
        G.3 / T.3  Claim Type contains Emedix  (Manually Pushed in Emedix)
        AA (.1/.2), AB, AC, AC.1, AC.2, AC.3 use Bs.
        Y (Patient Responsibility $) uses G, i.e. also Claim Status <> Billed Amount 0: the
        validation file leaves out a Billed Amount 0 claim with a $160 patient balance.
   2. Aria rows: "Last Billed Date <= 30 days". The NorthWest file's Last Billed Date is loaded
      into FirstBilledDate. The 30 days run back from one as-of date for every period: the
      latest FirstBilledDate in ClaimLevelData (fn_NW_ES_AriaAsOf).
        S.1.A1 / S.3.A1      parent claims billed within the 30 days
        AC.1.A1 / AC.3.A1    Insurance Balance of those parent claims
        .A2                  parent - A1
        .AP (% submitted)    A1 / parent   (was A1 / A2)
      Parents: PMS S.1 Fully Denied, S.3 No Response; Cash AC.1 Denials, AC.3 No Response.
   3. Averages, as the validation file's formulas (numerator Insurance Payment $ X + Partially Paid $ AA):
        AD = (X + AA) / G
        AE = (X + AA) / (M + Q)
        AF = (X + AA) / (K + M + N + O + P + R + Q + S.1 + S.2)
      Was: AD / AE with Patient Paid $ (AB), AE over M + Q + R, AF without K.
   The snapshot is rebuilt at the end. Run 50 again afterwards (popup rules).
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'52_NW_ExecutiveSummary_Validation1029.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* -----------------------------------------------------------------------------
   Aria as-of date: latest Last Billed Date (FirstBilledDate) in the data
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_ES_AriaAsOf()
RETURNS TABLE
AS
RETURN
    SELECT AsOf = MAX(d.FirstBill)
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101),
                                             TRY_CAST(c.FirstBilledDate AS DATE))) d
    WHERE d.FirstBill >= '19010101'
      AND d.FirstBill <= CAST(GETDATE() AS DATE);
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
            Src      = CASE WHEN v.Ct LIKE N'%Webpm%'  THEN 1
                            WHEN v.Ct LIKE N'%Daq%'    THEN 2
                            WHEN v.Ct LIKE N'%Emedix%' THEN 3
                            ELSE 0 END,
            Cs       = CASE WHEN v.Cs IN (N'Unbilled in Webpm PR', N'Unbilled in Webpm - PR', N'Unbilled in Webpm -PR') THEN N'Unbilled in Webpm PR'
                            WHEN v.Cs IN (N'Unbilled in Daq PR',   N'Unbilled in Daq - PR',   N'Unbilled in Daq -PR')   THEN N'Unbilled in Daq PR'
                            WHEN v.Cs IN (N'Partially Paid', N'Partial Paid') THEN N'Partially Paid'
                            ELSE v.Cs END) f
    CROSS APPLY (SELECT
            Bs = IIF(f.Billed = 1 AND f.Std = 1, 1, 0)) b
    CROSS APPLY (SELECT
            G  = IIF(b.Bs = 1 AND f.Cs <> N'Billed Amount 0', 1, 0),
            H  = IIF(f.Std = 1 AND f.Cs IN (N'Billed Amount 0', N'Unbilled in Daq', N'Unbilled in Daq PR',
                                            N'Unbilled in Webpm', N'Unbilled in Webpm PR'), 1, 0)) k
    CROSS APPLY (SELECT Gs = IIF(k.G = 1, f.Src, 0)) s
    CROSS APPLY (VALUES
        (N'PMS',  N'G',    k.G,                                                         CAST(1 AS DECIMAL(18,2))),
        (N'PMS',  N'G.1',  IIF(s.Gs = 1, 1, 0),                                         1),
        (N'PMS',  N'G.2',  IIF(s.Gs = 2, 1, 0),                                         1),
        (N'PMS',  N'G.3',  IIF(s.Gs = 3, 1, 0),                                         1),
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
        (N'Cash', N'T.1',  IIF(s.Gs = 1, 1, 0),                                         @Charge),
        (N'Cash', N'T.2',  IIF(s.Gs = 2, 1, 0),                                         @Charge),
        (N'Cash', N'T.3',  IIF(s.Gs = 3, 1, 0),                                         @Charge),
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
        (N'Cash', N'Y',    k.G,                                                         @PatBalance),
        (N'Cash', N'AA',   IIF(b.Bs = 1 AND f.Cs = N'Partially Paid', 1, 0),            @InsPay),
        (N'Cash', N'AA.1', IIF(b.Bs = 1 AND f.Cs = N'Partially Paid', 1, 0),            IIF(@ActualPay <> 0, @ActualPay, @InsPay)),
        (N'Cash', N'AA.2', IIF(b.Bs = 1 AND f.Cs = N'Partially Paid', 1, 0),            @DuplicatePay),
        (N'Cash', N'AB',   b.Bs,                                                        @PatientPay),
        (N'Cash', N'AC',   b.Bs,                                                        @InsBalance),
        (N'Cash', N'AC.1', IIF(b.Bs = 1 AND f.Cs = N'Fully Denied', 1, 0),              @InsBalance),
        (N'Cash', N'AC.2', IIF(b.Bs = 1 AND f.Cs NOT IN (N'Fully Denied', N'No Response'), 1, 0), @InsBalance),
        (N'Cash', N'AC.3', IIF(b.Bs = 1 AND f.Cs = N'No Response', 1, 0),               @InsBalance)
    ) m(Category, RowCode, Hit, Value)
    WHERE m.Hit = 1;
GO

/* -----------------------------------------------------------------------------
   All Executive Summary rows for the given filters (44, with the Aria rows above).
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

        /* Aria parents: PMS S.1 / S.3 claims, Cash AC.1 / AC.3 Insurance Balance */
        DECLARE @AsOf DATE = (SELECT AsOf FROM dbo.fn_NW_ES_AriaAsOf());

        SELECT r.Category, Parent = r.RowCode, c.ESYear, c.ESMonth,
               InWindow = IIF(DATEDIFF(DAY, c.FirstBilledDate, @AsOf) BETWEEN 0 AND 30, 1, 0),
               Value    = r.Value
        INTO #Aria
        FROM #C c
        CROSS APPLY dbo.fn_NW_ES_ClaimRowCodes(c.BilledUnbilled, c.ClaimType, c.ClaimStatus,
                                               c.ChargeAmount, c.InsurancePayment, c.ActualPayment,
                                               c.DuplicatePayment, c.PatientPayment,
                                               c.InsuranceBalance, c.PatientBalance) r
        WHERE (r.Category = N'PMS'  AND r.RowCode IN (N'S.1', N'S.3'))
           OR (r.Category = N'Cash' AND r.RowCode IN (N'AC.1', N'AC.3'));
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

        /* Aria: A1 = parent claims billed within 30 days of @AsOf, A2 = parent - A1, % = A1 / parent */
        WITH w AS (
            SELECT a.Category, a.Parent, k.ESYear, k.ESMonth,
                   InCnt  = SUM(CAST(a.InWindow AS BIGINT)),
                   AllCnt = COUNT_BIG(*),
                   InVal  = SUM(IIF(a.InWindow = 1, a.Value, 0)),
                   AllVal = SUM(a.Value)
            FROM #Aria a
            CROSS APPLY (VALUES (a.ESYear, a.ESMonth), (a.ESYear, 0), (0, 0)) k(ESYear, ESMonth)
            GROUP BY a.Category, a.Parent, k.ESYear, k.ESMonth)
        UPDATE o
        SET o.ClaimCount = CASE WHEN o.Category = N'PMS' AND m.Part = N'A1' THEN w.InCnt
                                WHEN o.Category = N'PMS' AND m.Part = N'A2' THEN w.AllCnt - w.InCnt
                                ELSE 0 END,
            -- Every branch DECIMAL(19,6): a DECIMAL(38,2) branch would round the % to 2 decimals.
            o.Amount     = CASE m.Part
                               WHEN N'A1' THEN CAST(IIF(o.Category = N'Cash', w.InVal, 0) AS DECIMAL(19,6))
                               WHEN N'A2' THEN CAST(IIF(o.Category = N'Cash', w.AllVal - w.InVal, 0) AS DECIMAL(19,6))
                               ELSE CAST(IIF(o.Category = N'Cash',
                                        IIF(w.AllVal <> 0, CAST(w.InVal AS FLOAT) / CAST(w.AllVal AS FLOAT), 0),
                                        IIF(w.AllCnt <> 0, CAST(w.InCnt AS FLOAT) / w.AllCnt, 0)) AS DECIMAL(19,6))
                           END
        FROM #Out o
        JOIN (VALUES
                (N'PMS',  N'S.1.A1',  N'S.1',  N'A1'), (N'PMS',  N'S.1.A2',  N'S.1',  N'A2'), (N'PMS',  N'S.1.AP',  N'S.1',  N'AP'),
                (N'PMS',  N'S.3.A1',  N'S.3',  N'A1'), (N'PMS',  N'S.3.A2',  N'S.3',  N'A2'), (N'PMS',  N'S.3.AP',  N'S.3',  N'AP'),
                (N'Cash', N'AC.1.A1', N'AC.1', N'A1'), (N'Cash', N'AC.1.A2', N'AC.1', N'A2'), (N'Cash', N'AC.1.AP', N'AC.1', N'AP'),
                (N'Cash', N'AC.3.A1', N'AC.3', N'A1'), (N'Cash', N'AC.3.A2', N'AC.3', N'A2'), (N'Cash', N'AC.3.AP', N'AC.3', N'AP')
             ) m(Category, RowCode, Parent, Part)
          ON m.Category = o.Category AND m.RowCode = o.RowCode
        JOIN w ON w.Category = m.Category AND w.Parent = m.Parent AND w.ESYear = o.ESYear AND w.ESMonth = o.ESMonth;

        /* Averages (ClaimCount = denominator), numerator X + AA for all three */
        WITH v AS (
            SELECT ESYear, ESMonth,
                   Pay     = SUM(IIF(Category = N'Cash' AND RowCode IN (N'X', N'AA'), Amount, 0)),
                   Billed  = SUM(IIF(Category = N'PMS'  AND RowCode = N'G', ClaimCount, 0)),
                   Paid    = SUM(IIF(Category = N'PMS'  AND RowCode IN (N'M', N'Q'), ClaimCount, 0)),
                   Adjud   = SUM(IIF(Category = N'PMS'  AND RowCode IN (N'K', N'M', N'N', N'O', N'P', N'R', N'Q', N'S.1', N'S.2'), ClaimCount, 0))
            FROM #Out
            GROUP BY ESYear, ESMonth)
        UPDATE o
        SET o.ClaimCount = x.Den,
            o.Amount     = IIF(x.Den > 0, x.Num / x.Den, 0)
        FROM #Out o
        JOIN v ON v.ESYear = o.ESYear AND v.ESMonth = o.ESMonth
        CROSS APPLY (SELECT
            Num = CAST(v.Pay AS DECIMAL(19,6)),
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
        -- Aria % rows are recomputed as A1 / parent (S.1, S.3, AC.1, AC.3): the table column keeps 2 decimals.
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
               MetricValue = IIF(a1.RowCode IS NULL, t.V, ISNULL(a1.V / NULLIF(p.V, 0), 0)),
               o.SortOrder
        FROM t
        JOIN o ON o.Category = t.Category AND o.RowCode = t.RowCode
        LEFT JOIN t a1
          ON t.Category IN (N'PMS', N'Cash') AND t.RowCode LIKE N'%.AP'
         AND a1.Category = t.Category AND a1.BillYear = t.BillYear AND a1.BillMonth = t.BillMonth
         AND a1.RowCode = LEFT(t.RowCode, IIF(LEN(t.RowCode) > 2, LEN(t.RowCode) - 2, 0)) + N'A1'
        LEFT JOIN t p
          ON a1.RowCode IS NOT NULL
         AND p.Category = t.Category AND p.BillYear = t.BillYear AND p.BillMonth = t.BillMonth
         AND p.RowCode = LEFT(t.RowCode, IIF(LEN(t.RowCode) > 3, LEN(t.RowCode) - 3, 0))
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
   Legacy cell drill (PMS / Cash): same Aria split
   ----------------------------------------------------------------------------- */
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
        WHEN N'AE' THEN N'M,Q'
        WHEN N'AF' THEN N'K,M,N,O,P,R,Q,S.1,S.2'
        WHEN N'S.1.A1'  THEN N'S.1'  WHEN N'S.1.A2'  THEN N'S.1'  WHEN N'S.1.AP'  THEN N'S.1'
        WHEN N'S.3.A1'  THEN N'S.3'  WHEN N'S.3.A2'  THEN N'S.3'  WHEN N'S.3.AP'  THEN N'S.3'
        WHEN N'AC.1.A1' THEN N'AC.1' WHEN N'AC.1.A2' THEN N'AC.1' WHEN N'AC.1.AP' THEN N'AC.1'
        WHEN N'AC.3.A1' THEN N'AC.3' WHEN N'AC.3.A2' THEN N'AC.3' WHEN N'AC.3.AP' THEN N'AC.3'
        ELSE @RowCode END;

    -- Aria: 1 = billed in the last 30 days, 2 = not, NULL = both
    DECLARE @AriaPart INT = CASE WHEN @RowCode LIKE N'%.A1' THEN 1 WHEN @RowCode LIKE N'%.A2' THEN 2 END;
    DECLARE @AsOf DATE = (SELECT AsOf FROM dbo.fn_NW_ES_AriaAsOf());

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

SET NOEXEC OFF;
GO

PRINT N'52_NW_ExecutiveSummary_Validation1029.sql completed.';
GO

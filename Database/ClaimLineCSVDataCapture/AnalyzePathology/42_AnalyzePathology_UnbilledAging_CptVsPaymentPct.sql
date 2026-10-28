/* =============================================================================
   Analyze Pathology - Unbilled X Aging filter + CPT vs Payment % on Line Level
   File     : 42_AnalyzePathology_UnbilledAging_CptVsPaymentPct.sql
   Database : AnalyzePathology        Prefix : AnP
   Requires : 09_AnalyzePathology_UnbilledAging.sql, 38_AnalyzePathology_CollectionSummary_ClientFixes4.sql

   Production Summary - 5. Unbilled X Aging
     Source  : Claim Level
     Filter  : Bill Status in (Unbilled, Unbilled - Self Pay) AND ClaimStatus <> '0 Billed Amount'
     Rows    : Panel Name          Columns : DOS Aging (AgingDOS)
     Values  : Count of unique ClaimID, Sum of ChargeAmount; sorted by claim count
     (Bill Status "Unbilled%" = IsBilled 0 in vw_AnP_ProductionClaims; only the two values exist.)

   Collection Summary - 10. CPT vs Payment %
     Source  : Line Level Data (was Claim Level, InsurancePayment > 0)
     Filter  : none (CPTCode not blank); dashboard filters apply through the line's claim
     Rows    : Panel Name (the line's claim Panelname - LineLevelData.Panelname is blank)
               -> CPTCode, both sorted by Claim Count (unique ClaimID) DESC
     Values  : Sum of Units          = SUM(Units)
               Average Payment %     = AVG(line InsurancePayment / ChargeAmount x 100), lines with
                                       ChargeAmount > 0 (Line Level Data has no PaymentPercent)
               TotalPaymentPct       = the same average over every line in the result
     Result  : RowType 'P' panel / 'C' CPT under the panel, PanelName, CPTCode, NoOfClaims, SumUnits,
               AvgPaymentPct, TotalPaymentPct, SortOrder (the dashboard reads SumUnits as the units column).
   ============================================================================= */

IF DB_NAME() <> N'AnalyzePathology'
BEGIN
    RAISERROR(N'42_AnalyzePathology_UnbilledAging_CptVsPaymentPct.sql must run on AnalyzePathology.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   Production Summary - Unbilled X Aging
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @ForceLive       BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PanelName, AgingBucket, ClaimCount, TotalCharges
        FROM   dbo.AnP_UnbilledAging
        ORDER  BY PanelName, AgingBucket;
        RETURN;
    END;

    SELECT CAST(PanelName AS NVARCHAR(500)) AS PanelName,
           CAST(AgingDOS  AS NVARCHAR(100)) AS AgingBucket,
           COUNT(DISTINCT ClaimID)          AS ClaimCount,
           SUM(ChargeAmount)                AS TotalCharges
    FROM   dbo.fn_AnP_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsBilled = 0
      AND  ClaimStatus <> N'0 Billed Amount'
    GROUP  BY PanelName, AgingDOS
    ORDER  BY PanelName, AgingBucket;
END
GO

/* =============================================================================
   Collection Summary - CPT vs Payment % (Line Level Data)
   ============================================================================= */
DROP TABLE IF EXISTS dbo.AnP_CS2_CptVsPaymentPct;
CREATE TABLE dbo.AnP_CS2_CptVsPaymentPct
(
    RowType         CHAR(1)        NOT NULL,
    PanelName       NVARCHAR(500)  NULL,
    CPTCode         NVARCHAR(500)  NULL,
    NoOfClaims      INT            NOT NULL,
    SumUnits        DECIMAL(18,2)  NOT NULL,
    AvgPaymentPct   DECIMAL(9,2)   NOT NULL,
    TotalPaymentPct DECIMAL(9,2)   NOT NULL,
    SortOrder       INT            NOT NULL,
    RefreshedAt     DATETIME2(0)   NOT NULL CONSTRAINT DF_AnP_CS2_CptVsPaymentPct_RefreshedAt DEFAULT SYSDATETIME()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_AnP_CS_CptVsPaymentPct_Compute
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Claims that pass the dashboard filters, with their panel (one panel per ClaimID).
    CREATE TABLE #k (ClaimKey NVARCHAR(450) NOT NULL PRIMARY KEY, PanelName NVARCHAR(500) NOT NULL);
    INSERT INTO #k (ClaimKey, PanelName)
    SELECT LEFT(ClaimKey, 450), MAX(PanelName)
    FROM dbo.fn_AnP_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                              @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE ClaimKey IS NOT NULL
    GROUP BY LEFT(ClaimKey, 450)
    OPTION (RECOMPILE);

    SELECT ClaimKey  = k.ClaimKey,
           PanelName = k.PanelName,
           CPTCode   = LTRIM(RTRIM(l.CPTCode)),
           Units     = ISNULL(TRY_CAST(l.Units AS DECIMAL(18,2)), 0),
           LinePct   = CASE WHEN v.Chg > 0 THEN v.InsPay / v.Chg * 100 END
    INTO #l
    FROM dbo.LineLevelData l
    JOIN #k k ON k.ClaimKey = LEFT(LTRIM(RTRIM(l.ClaimID)), 450)
    CROSS APPLY (SELECT InsPay = ISNULL(TRY_CAST(l.InsurancePayment AS DECIMAL(18,2)), 0),
                        Chg    = TRY_CAST(l.ChargeAmount AS DECIMAL(18,2))) v
    WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), N'') IS NOT NULL;

    DECLARE @TotalPct DECIMAL(38,6) = (SELECT AVG(LinePct) FROM #l);

    WITH panel AS (
        SELECT PanelName,
               NoOfClaims = COUNT(DISTINCT ClaimKey),
               SumUnits   = SUM(Units),
               AvgPct     = AVG(LinePct),
               PanelOrd   = ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT ClaimKey) DESC, SUM(Units) DESC, PanelName)
        FROM #l
        GROUP BY PanelName
    ),
    cpt AS (
        SELECT PanelName, CPTCode,
               NoOfClaims = COUNT(DISTINCT ClaimKey),
               SumUnits   = SUM(Units),
               AvgPct     = AVG(LinePct),
               CptOrd     = ROW_NUMBER() OVER (PARTITION BY PanelName
                                               ORDER BY COUNT(DISTINCT ClaimKey) DESC, SUM(Units) DESC, CPTCode)
        FROM #l
        GROUP BY PanelName, CPTCode
    ),
    rowsOut AS (
        SELECT RowType = CAST('P' AS CHAR(1)), p.PanelName, CPTCode = CAST(NULL AS NVARCHAR(500)),
               p.NoOfClaims, p.SumUnits, p.AvgPct, p.PanelOrd, CptOrd = CAST(0 AS BIGINT)
        FROM panel p
        UNION ALL
        SELECT 'C', c.PanelName, c.CPTCode, c.NoOfClaims, c.SumUnits, c.AvgPct, p.PanelOrd, c.CptOrd
        FROM cpt c
        JOIN panel p ON p.PanelName = c.PanelName
    )
    SELECT RowType,
           PanelName       = CAST(PanelName AS NVARCHAR(500)),
           CPTCode         = CAST(CPTCode AS NVARCHAR(500)),
           NoOfClaims,
           SumUnits        = CAST(SumUnits AS DECIMAL(18,2)),
           AvgPaymentPct   = CAST(ROUND(ISNULL(AvgPct, 0), 2) AS DECIMAL(9,2)),
           TotalPaymentPct = CAST(ROUND(ISNULL(@TotalPct, 0), 2) AS DECIMAL(9,2)),
           SortOrder       = CAST(ROW_NUMBER() OVER (ORDER BY PanelOrd, CptOrd) AS INT)
    FROM rowsOut
    ORDER BY SortOrder;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_CptVsPaymentPct
    @PayerNames NVARCHAR(MAX) = NULL, @PanelNames NVARCHAR(MAX) = NULL,
    @DosFrom DATE = NULL, @DosTo DATE = NULL,
    @FirstBillFrom DATE = NULL, @FirstBillTo DATE = NULL,
    @CheckDateFrom DATE = NULL, @CheckDateTo DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF dbo.fn_AnP_CS_HasFilter(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                               @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) = 0
       AND EXISTS (SELECT 1 FROM dbo.AnP_CS2_CptVsPaymentPct)
    BEGIN
        SELECT RowType, PanelName, CPTCode, NoOfClaims, SumUnits, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM dbo.AnP_CS2_CptVsPaymentPct
        ORDER BY SortOrder;
        RETURN;
    END;

    EXEC dbo.usp_AnP_CS_CptVsPaymentPct_Compute
        @PayerNames = @PayerNames, @PanelNames = @PanelNames,
        @DosFrom = @DosFrom, @DosTo = @DosTo,
        @FirstBillFrom = @FirstBillFrom, @FirstBillTo = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom, @CheckDateTo = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #r
    (
        RowType CHAR(1), PanelName NVARCHAR(500), CPTCode NVARCHAR(500), NoOfClaims INT,
        SumUnits DECIMAL(18,2), AvgPaymentPct DECIMAL(9,2), TotalPaymentPct DECIMAL(9,2), SortOrder INT
    );

    INSERT INTO #r
    EXEC dbo.usp_AnP_CS_CptVsPaymentPct_Compute;

    BEGIN TRAN;
        DELETE FROM dbo.AnP_CS2_CptVsPaymentPct;
        INSERT INTO dbo.AnP_CS2_CptVsPaymentPct
            (RowType, PanelName, CPTCode, NoOfClaims, SumUnits, AvgPaymentPct, TotalPaymentPct, SortOrder)
        SELECT RowType, PanelName, CPTCode, NoOfClaims, SumUnits, AvgPaymentPct, TotalPaymentPct, SortOrder
        FROM #r;
    COMMIT;
END
GO

/* =============================================================================
   Rebuild the snapshots
   ============================================================================= */
EXEC dbo.usp_RefreshAnP_UnbilledAging;
GO
EXEC dbo.usp_RefreshAnP_CS_CptVsPaymentPct;
GO

SET NOEXEC OFF;
GO

PRINT '42_AnalyzePathology_UnbilledAging_CptVsPaymentPct.sql completed.';
GO

/* =============================================================================
   NorthWest - Production Summary - CPT Breakdown claim count
   File     : 47_NW_CPTBreakdown_LineCount.sql
   Database : NWL_LRN
   Requires : 41_NW_ProductionSummary_BilledUnbilled.sql

   Issue : CPTCount was COUNT(DISTINCT ClaimID) per Source x CPT x month, so a
           claim with the same CPT on two lines counted once. The client pivot
           counts Claim ID per line:
             SELECT COUNT(ClaimID) FROM LineLevelData
             WHERE CPTCode IS NOT NULL AND Source = 'DAQ'     -- 344,851 (page showed 344,841)
           WebPM: 1,050,410 (page showed 1,045,130). Charges already matched.
   Fix   : CPTCount = COUNT(ClaimID). Same definition as section 7 of
           41_NW_ProductionSummary_BilledUnbilled.sql. usp_RefreshNW_CPTBreakdownBySource
           is unchanged; it is executed below to rebuild the snapshot.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'47_NW_CPTBreakdown_LineCount.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CPTBreakdownBySource
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT SourceName, CPTCode, BilledYearMonth, CPTCount, BilledUnits, TotalCharges
        FROM dbo.NW_CPTBreakdownBySource
        ORDER BY SourceName, CPTCode, BilledYearMonth;
        RETURN;
    END;

    ;WITH Lines AS
    (
        SELECT
            SourceName        = CASE
                                    WHEN UPPER(LTRIM(RTRIM(ISNULL(l.Source, N'')))) LIKE N'WEBPM%'
                                        THEN N'WebPM'
                                    WHEN UPPER(LTRIM(RTRIM(ISNULL(l.Source, N'')))) LIKE N'DAQ%'
                                        THEN N'DAQ'
                                END,
            CPTCode           = LTRIM(RTRIM(l.CPTCode)),
            ChargeEnteredDate = TRY_CAST(l.ChargeEnteredDate AS DATE),
            BilledDate        = TRY_CAST(NULLIF(LTRIM(RTRIM(l.FirstBilledDate)), N'') AS DATE),
            DateOfService     = TRY_CAST(l.DateOfService AS DATE),
            ClaimID           = NULLIF(LTRIM(RTRIM(l.ClaimID)), N''),
            PayerName         = LTRIM(RTRIM(ISNULL(l.PayerName_Raw, N'Unknown'))),
            PanelName         = LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(l.Panelname)), N''), N'Unknown'))),
            UnitsValue        = TRY_CAST(l.Units AS DECIMAL(18,2)),
            ChargeAmountValue = TRY_CAST(l.ChargeAmount AS DECIMAL(18,2))
        FROM dbo.LineLevelData l
        WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), N'') IS NOT NULL
    )
    SELECT
        SourceName,
        CPTCode,
        BilledYearMonth = CONVERT(NVARCHAR(7), ChargeEnteredDate, 120),
        CPTCount        = COUNT(ClaimID),
        BilledUnits     = ISNULL(SUM(UnitsValue), 0),
        TotalCharges    = ISNULL(SUM(ChargeAmountValue), 0)
    FROM Lines
    WHERE SourceName IS NOT NULL
      AND ChargeEnteredDate IS NOT NULL
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom         IS NULL OR DateOfService     >= @DosFrom)
      AND (@DosTo           IS NULL OR DateOfService     <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR ChargeEnteredDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR ChargeEnteredDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR BilledDate        >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR BilledDate        <= @FirstBilledTo)
    GROUP BY SourceName, CPTCode, CONVERT(NVARCHAR(7), ChargeEnteredDate, 120)
    ORDER BY SourceName, CPTCode, BilledYearMonth
    OPTION (RECOMPILE);
END;
GO

EXEC dbo.usp_RefreshNW_CPTBreakdownBySource;
GO

SET NOEXEC OFF;
GO

PRINT '47_NW_CPTBreakdown_LineCount.sql completed.';
GO

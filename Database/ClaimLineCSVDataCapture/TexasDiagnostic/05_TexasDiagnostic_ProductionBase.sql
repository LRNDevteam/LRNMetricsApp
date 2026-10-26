/* =============================================================================
   TexasDiagnostic - Production Summary base objects
   Database : TexasDiagnostic        Prefix : TD_
   Source   : dbo.ClaimLevelData, dbo.LineLevelData

   Client logic:
     Billed   = FirstBilledDate is a date
     Unbilled = ClaimStatus = Unbilled
     Measures = COUNT(DISTINCT ClaimID), SUM(ChargeAmount)
                (CPT Breakdown: COUNT(ClaimID), SUM(ChargeAmount))
     Rows     = Panelname / PayerName_Raw
     Columns  = ChargeEnteredDate month / year
     Weekly   = Friday-Thursday week of ChargeEnteredDate, EntryWeek not blank
     Aging    = Aging; AgingDOS when Aging is blank (Aging is empty on the current file)

   Every Production Summary read SP (usp_GetTD_*) selects from
   fn_TD_ProductionClaims / fn_TD_ProductionLines.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
	RAISERROR('Run 05_TexasDiagnostic_ProductionBase.sql on the TexasDiagnostic database.', 16, 1);
	SET NOEXEC ON;
END
GO

CREATE OR ALTER VIEW dbo.vw_TD_ProductionClaims
AS
SELECT
    NULLIF(LTRIM(RTRIM(c.ClaimID)), '')                                     AS ClaimID,
    ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)), ''), 'Unknown')                AS PanelName,
    ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), ''), 'Unknown')            AS PayerName,
    TRY_CAST(c.DateofService     AS DATE)                                   AS DateOfService,
    TRY_CAST(c.ChargeEnteredDate AS DATE)                                   AS ChargeEnteredDate,
    TRY_CAST(c.FirstBilledDate   AS DATE)                                   AS FirstBilledDate,
    ISNULL(TRY_CAST(c.ChargeAmount AS DECIMAL(18,2)), 0)                    AS ChargeAmount,
    CAST(CASE WHEN TRY_CAST(c.FirstBilledDate AS DATE) IS NOT NULL
              THEN 1 ELSE 0 END AS BIT)                                     AS IsBilled,
    CAST(CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(c.ClaimStatus, '')))) = 'UNBILLED'
              THEN 1 ELSE 0 END AS BIT)                                     AS IsUnbilled,
    COALESCE(NULLIF(LTRIM(RTRIM(c.Aging)), ''),
             NULLIF(LTRIM(RTRIM(c.AgingDOS)), ''), 'Unknown')               AS Aging,
    NULLIF(LTRIM(RTRIM(c.EntryWeek)), '')                                   AS EntryWeek
FROM dbo.ClaimLevelData c;
GO

CREATE OR ALTER VIEW dbo.vw_TD_ProductionLines
AS
SELECT
    NULLIF(LTRIM(RTRIM(l.ClaimID)), '')                                     AS ClaimID,
    LTRIM(RTRIM(l.CPTCode))                                                 AS CPTCode,
    ISNULL(NULLIF(LTRIM(RTRIM(l.PayerName_Raw)), ''), 'Unknown')            AS PayerName,
    TRY_CAST(l.DateofService     AS DATE)                                   AS DateOfService,
    TRY_CAST(l.ChargeEnteredDate AS DATE)                                   AS ChargeEnteredDate,
    TRY_CAST(l.FirstBilledDate   AS DATE)                                   AS FirstBilledDate,
    ISNULL(TRY_CAST(l.ChargeAmount AS DECIMAL(18,2)), 0)                    AS ChargeAmount
FROM dbo.LineLevelData l
WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), '') IS NOT NULL;
GO

CREATE OR ALTER FUNCTION dbo.fn_TD_ProductionClaims
(
    @PayerNames      NVARCHAR(MAX),
    @PanelNames      NVARCHAR(MAX),
    @DosFrom         DATE,
    @DosTo           DATE,
    @FirstBillFrom   DATE,
    @FirstBillTo     DATE,
    @FirstBilledFrom DATE,
    @FirstBilledTo   DATE
)
RETURNS TABLE
AS
RETURN
    SELECT c.*
    FROM dbo.vw_TD_ProductionClaims c
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR c.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR c.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom         IS NULL OR c.DateOfService   >= @DosFrom)
      AND (@DosTo           IS NULL OR c.DateOfService   <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR c.FirstBilledDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR c.FirstBilledDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR c.FirstBilledDate >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR c.FirstBilledDate <= @FirstBilledTo);
GO

CREATE OR ALTER FUNCTION dbo.fn_TD_ProductionLines
(
    @PayerNames      NVARCHAR(MAX),
    @PanelNames      NVARCHAR(MAX),
    @DosFrom         DATE,
    @DosTo           DATE,
    @FirstBillFrom   DATE,
    @FirstBillTo     DATE,
    @FirstBilledFrom DATE,
    @FirstBilledTo   DATE
)
RETURNS TABLE
AS
RETURN
    SELECT l.*
    FROM dbo.vw_TD_ProductionLines l
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR l.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR EXISTS (SELECT 1
                      FROM dbo.vw_TD_ProductionClaims c
                      WHERE c.ClaimID = l.ClaimID
                        AND c.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|'))))
      AND (@DosFrom         IS NULL OR l.DateOfService   >= @DosFrom)
      AND (@DosTo           IS NULL OR l.DateOfService   <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR l.FirstBilledDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR l.FirstBilledDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR l.FirstBilledDate >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR l.FirstBilledDate <= @FirstBilledTo);
GO

PRINT '05_TexasDiagnostic_ProductionBase.sql completed.';
GO

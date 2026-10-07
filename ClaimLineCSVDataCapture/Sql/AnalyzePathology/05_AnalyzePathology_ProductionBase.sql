/* =============================================================================
   Analyze Pathology - Production Summary base objects
   Database : AnalyzePathology        Prefix : AnP_
   Source   : dbo.ClaimLevelData, dbo.LineLevelData

   Client logic (AnalyzePathology_StandardReports_Logic_v1.0_10.05.2026.xlsx):
     Billed   = BilledStatus NOT LIKE 'Unbilled%'   (Billed, Billed - Self Pay)
     Unbilled = BilledStatus LIKE 'Unbilled%'       (Unbilled, Unbilled -  Self Pay)
     Measures = COUNT(DISTINCT ClaimID), SUM(ChargeAmount)
     Rows     = Panel Name (Panelname) / Payer Name (PayerName_Raw)

   Every Production Summary read SP (usp_GetAnP_*) selects from
   fn_AnP_ProductionClaims / fn_AnP_ProductionLines, and every refresh SP
   (usp_RefreshAnP_*) fills its snapshot table from the same read SP, so the
   unfiltered snapshot and the filtered live result always use the same rules.

   Filter parameters (same contract as the other labs' Production read SPs):
     @PayerNames / @PanelNames : '|' separated lists
     @DosFrom / @DosTo         : DateofService
     @FirstBill* / @FirstBilled*: FirstBilledDate
   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW dbo.vw_AnP_ProductionClaims
AS
SELECT
    NULLIF(LTRIM(RTRIM(c.ClaimID)), '')                                     AS ClaimID,
    COALESCE(NULLIF(LTRIM(RTRIM(c.AccessionNumber)), ''),
             NULLIF(LTRIM(RTRIM(c.ClaimID)), ''))                           AS VisitKey,
    ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)), ''), 'Unknown')                AS PanelName,
    ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), ''), 'Unknown')            AS PayerName,
    TRY_CAST(c.DateofService   AS DATE)                                     AS DateOfService,
    TRY_CAST(c.FirstBilledDate AS DATE)                                     AS FirstBilledDate,
    ISNULL(TRY_CAST(c.ChargeAmount AS DECIMAL(18,2)), 0)                    AS ChargeAmount,
    CAST(CASE WHEN LTRIM(RTRIM(ISNULL(c.BilledStatus, ''))) LIKE 'Unbilled%'
              THEN 0 ELSE 1 END AS BIT)                                     AS IsBilled,
    ISNULL(NULLIF(LTRIM(RTRIM(c.AgingDOS)), ''), 'Unknown')                 AS AgingDOS,
    LTRIM(RTRIM(ISNULL(c.CPTCodeXUnitsXModifier, '')))                      AS CPTCodeXUnitsXModifier,
    CAST(CASE WHEN NULLIF(LTRIM(RTRIM(c.LastBilledDate)), '') IS NULL
              THEN 0 ELSE 1 END AS BIT)                                     AS HasLastBilledDate
FROM dbo.ClaimLevelData c;
GO

CREATE OR ALTER VIEW dbo.vw_AnP_ProductionLines
AS
SELECT
    NULLIF(LTRIM(RTRIM(l.ClaimID)), '')                                     AS ClaimID,
    LTRIM(RTRIM(l.CPTCode))                                                 AS CPTCode,
    ISNULL(NULLIF(LTRIM(RTRIM(l.PayerName_Raw)), ''), 'Unknown')            AS PayerName,
    TRY_CAST(l.DateofService   AS DATE)                                     AS DateOfService,
    TRY_CAST(l.FirstBilledDate AS DATE)                                     AS FirstBilledDate,
    ISNULL(TRY_CAST(l.Units        AS DECIMAL(18,2)), 0)                    AS Units,
    ISNULL(TRY_CAST(l.ChargeAmount AS DECIMAL(18,2)), 0)                    AS ChargeAmount
FROM dbo.LineLevelData l
WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), '') IS NOT NULL;
GO

CREATE OR ALTER FUNCTION dbo.fn_AnP_ProductionClaims
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
    FROM dbo.vw_AnP_ProductionClaims c
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

-- LineLevelData.Panelname is not populated for Analyze Pathology, so the panel
-- filter goes through the claim row.
CREATE OR ALTER FUNCTION dbo.fn_AnP_ProductionLines
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
    FROM dbo.vw_AnP_ProductionLines l
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR l.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR EXISTS (SELECT 1
                      FROM dbo.vw_AnP_ProductionClaims c
                      WHERE c.ClaimID = l.ClaimID
                        AND c.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|'))))
      AND (@DosFrom         IS NULL OR l.DateOfService   >= @DosFrom)
      AND (@DosTo           IS NULL OR l.DateOfService   <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR l.FirstBilledDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR l.FirstBilledDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR l.FirstBilledDate >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR l.FirstBilledDate <= @FirstBilledTo);
GO

PRINT '05_AnalyzePathology_ProductionBase.sql completed.';

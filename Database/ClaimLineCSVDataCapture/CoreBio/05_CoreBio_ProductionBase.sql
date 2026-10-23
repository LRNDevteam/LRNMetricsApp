/* =============================================================================
   CoreBio - Production Summary base objects
   Database : CoreBio        Prefix : CB_
   Source   : dbo.ClaimLevelData, dbo.LineLevelData

   Client logic:
     Billed   = BilledStatus = Billed
     Unbilled = BilledStatus = Unbilled
     Measures = COUNT(DISTINCT ClaimID), SUM(ChargeAmount)
     Rows     = Panelname / PayerName_Raw
     Weekly   = Wednesday-Tuesday week of FirstBilledDate, BilledWeek not blank
     Aging    = AgingDOS (the Aging column is empty on this file)

   Every Production Summary read SP (usp_GetCB_*) selects from
   fn_CB_ProductionClaims / fn_CB_ProductionLines.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'CoreBio'
BEGIN
	RAISERROR('Run 05_CoreBio_ProductionBase.sql on the CoreBio database.', 16, 1);
	SET NOEXEC ON;
END
GO

CREATE OR ALTER VIEW dbo.vw_CB_ProductionClaims
AS
SELECT
    NULLIF(LTRIM(RTRIM(c.ClaimID)), '')                                     AS ClaimID,
    ISNULL(NULLIF(LTRIM(RTRIM(c.Panelname)), ''), 'Unknown')                AS PanelName,
    ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), ''), 'Unknown')            AS PayerName,
    TRY_CAST(c.DateofService   AS DATE)                                     AS DateOfService,
    TRY_CAST(c.FirstBilledDate AS DATE)                                     AS FirstBilledDate,
    ISNULL(TRY_CAST(c.ChargeAmount AS DECIMAL(18,2)), 0)                    AS ChargeAmount,
    CAST(CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(c.BilledStatus, '')))) = 'BILLED'
              THEN 1 ELSE 0 END AS BIT)                                     AS IsBilled,
    CAST(CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(c.BilledStatus, '')))) = 'UNBILLED'
              THEN 1 ELSE 0 END AS BIT)                                     AS IsUnbilled,
    ISNULL(NULLIF(LTRIM(RTRIM(c.AgingDOS)), ''), 'Unknown')                 AS AgingDOS,
    NULLIF(LTRIM(RTRIM(c.BilledWeek)), '')                                  AS BilledWeek
FROM dbo.ClaimLevelData c;
GO

CREATE OR ALTER VIEW dbo.vw_CB_ProductionLines
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

CREATE OR ALTER FUNCTION dbo.fn_CB_ProductionClaims
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
    FROM dbo.vw_CB_ProductionClaims c
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

CREATE OR ALTER FUNCTION dbo.fn_CB_ProductionLines
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
    FROM dbo.vw_CB_ProductionLines l
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR l.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR EXISTS (SELECT 1
                      FROM dbo.vw_CB_ProductionClaims c
                      WHERE c.ClaimID = l.ClaimID
                        AND c.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|'))))
      AND (@DosFrom         IS NULL OR l.DateOfService   >= @DosFrom)
      AND (@DosTo           IS NULL OR l.DateOfService   <= @DosTo)
      AND (@FirstBillFrom   IS NULL OR l.FirstBilledDate >= @FirstBillFrom)
      AND (@FirstBillTo     IS NULL OR l.FirstBilledDate <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR l.FirstBilledDate >= @FirstBilledFrom)
      AND (@FirstBilledTo   IS NULL OR l.FirstBilledDate <= @FirstBilledTo);
GO

PRINT '05_CoreBio_ProductionBase.sql completed.';
GO

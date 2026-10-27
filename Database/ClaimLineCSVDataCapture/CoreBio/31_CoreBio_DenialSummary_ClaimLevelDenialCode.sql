/* =============================================================================
   CoreBio - Denial Summary: Denial Code = ClaimLevelData.ClaimLevelDenialCode
   Database : CoreBio        Run after 30_CoreBio_DenialSummary.sql

   Client logic change (2026-10-27): every Denial Summary tab reads
   ClaimLevelDenialCode instead of DenialCode. Rules are otherwise unchanged:
     Monthly / Weekly : ClaimLevelDenialCode not blank and not OA-102 / PI-148 / PR-51;
                        InsuranceBalance > 0; rows PayerName_Raw by Total Insurance
                        Balance, Top 3 denial codes; CheckDate month / Wed-Tue week.
     Denial List      : ClaimLevelDenialCode not blank; InsuranceBalance > 0.
   Row labels keep DenialDescription ("code - description").
   Filter options (Denial Code list) follow vw_CB_DenialClaims, so they change too.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'CoreBio'
BEGIN
    RAISERROR('Run 31_CoreBio_DenialSummary_ClaimLevelDenialCode.sql on the CoreBio database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER VIEW dbo.vw_CB_DenialClaims
AS
SELECT
    CAST(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), '') AS NVARCHAR(200))            AS ClaimID,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), c.PayerName_Raw))), ''), 'Unknown') AS NVARCHAR(500)) AS PayerName,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.PayerType))), ''), 'Unknown') AS NVARCHAR(200))     AS PayerType,
    CAST(NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode))), '') AS NVARCHAR(400)) AS DenialCode,
    COALESCE(TRY_CONVERT(DATE, c.CheckDate, 101), TRY_CAST(c.CheckDate AS DATE))                  AS DenialDate,
    ISNULL(TRY_CONVERT(DECIMAL(18,2),
                       REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), '$', ''), ',', '')), 0)
                                                                                                  AS TotalInsuranceBalance
FROM dbo.ClaimLevelData c;
GO

CREATE OR ALTER FUNCTION dbo.fn_CB_DenialSummaryClaims()
RETURNS TABLE
AS
RETURN
    SELECT NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'')                AS ClaimKey,
           CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), c.PayerName_Raw), N''))) AS NVARCHAR(500)) AS PayerName,
           CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.PayerType), N''))) AS NVARCHAR(200))     AS PayerType,
           CAST(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode))) AS NVARCHAR(400)) AS DenialCode,
           LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(4000), c.DenialDescription), N'')))     AS DenialDescription,
           COALESCE(TRY_CONVERT(DATE, c.CheckDate, 101), TRY_CAST(c.CheckDate AS DATE)) AS DenialDate,
           ISNULL(b.Bal, 0)                                                             AS Bal
    FROM   dbo.ClaimLevelData c
    CROSS  APPLY (SELECT TRY_CONVERT(DECIMAL(18,2),
                         REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), N'$', N''), N',', N'')) AS Bal) b
    WHERE  LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode), N''))) <> N''
      AND  UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(400), c.ClaimLevelDenialCode)))) NOT IN (N'OA-102', N'PI-148', N'PR-51')
      AND  ISNULL(b.Bal, 0) > 0;
GO

-- fn_CB_DenialClaims selects d.* from the view; refresh its column metadata.
EXEC sp_refreshsqlmodule N'dbo.fn_CB_DenialClaims';
GO

EXEC dbo.usp_RefreshCB_DenialMonthly;
EXEC dbo.usp_RefreshCB_DenialWeekly;
EXEC dbo.usp_RefreshCB_DenialList;
GO

PRINT '31_CoreBio_DenialSummary_ClaimLevelDenialCode.sql completed.';
GO

SET NOEXEC OFF;
GO

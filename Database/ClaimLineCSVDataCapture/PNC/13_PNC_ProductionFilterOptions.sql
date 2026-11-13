/* =============================================================================
   PNC - Production Summary filter dropdowns
   Database : PNC        Requires : 08_PNC_PayerBreakdown.sql

   Payer and Panel lists for the Production Summary filters, read from the
   aggregate tables the refresh SPs build (billed claims only, same as the grids).

   Result sets:
     1. PayerName   - dbo.PNC_PayerBreakdown
     2. PanelName   - dbo.PNC_PayerByPanel
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'PNC'
BEGIN
	RAISERROR('Run 13_PNC_ProductionFilterOptions.sql on the PNC database.', 16, 1);
	SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_ProductionFilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT LTRIM(RTRIM(PayerName)) AS PayerName
    FROM   dbo.PNC_PayerBreakdown
    WHERE  NULLIF(LTRIM(RTRIM(PayerName)), N'') IS NOT NULL
    ORDER  BY 1;

    SELECT DISTINCT CAST(LTRIM(RTRIM(PanelType)) AS NVARCHAR(500)) AS PanelName
    FROM   dbo.PNC_PayerByPanel
    WHERE  NULLIF(LTRIM(RTRIM(PanelType)), N'') IS NOT NULL
    ORDER  BY 1;
END
GO

PRINT '13_PNC_ProductionFilterOptions.sql completed.';
GO

/* =============================================================================
   PNC - Collection Summary filter dropdowns
   Database : PNC        Prefix : PNC

   Payer (PayerName_Raw) and Panel (Panelname) lists for the Collection Summary
   filters, so the page reads them through an SP instead of an inline DISTINCT.

   Result sets:
     1. PayerName
     2. PanelName
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'PNC'
BEGIN
    RAISERROR('Run 15_PNC_CS_FilterOptions.sql on the PNC database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_CS_FilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT CAST(LTRIM(RTRIM(PayerName_Raw)) AS NVARCHAR(500)) AS PayerName
    FROM   dbo.ClaimLevelData
    WHERE  NULLIF(LTRIM(RTRIM(PayerName_Raw)), N'') IS NOT NULL
    ORDER  BY 1;

    SELECT DISTINCT CAST(LTRIM(RTRIM(Panelname)) AS NVARCHAR(500)) AS PanelName
    FROM   dbo.ClaimLevelData
    WHERE  NULLIF(LTRIM(RTRIM(Panelname)), N'') IS NOT NULL
    ORDER  BY 1;
END
GO

PRINT '15_PNC_CS_FilterOptions.sql completed.';
GO

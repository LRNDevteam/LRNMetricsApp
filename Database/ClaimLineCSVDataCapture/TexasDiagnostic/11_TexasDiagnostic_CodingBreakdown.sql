/* =============================================================================
   TexasDiagnostic - Coding Breakdown (Production Summary Excel)
   Database : TexasDiagnostic        Requires : nothing

   Texas Diagnostic has no Coding report (the Production Summary Coding tab is
   hidden). The Production Summary Excel export still calls
   usp_Get{prefix}CodingBreakdown for every lab, so this procedure returns the
   standard two result sets with no rows and the workbook gets no Coding sheet.

   Result sets (same contract as usp_GetAnP_CodingBreakdown):
     1. PanelName, ClaimCount, TotalCharges
     2. PanelName, CPTCodeXUnitsXModifier, ClaimCount, TotalCharges
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
    RAISERROR('Run 11_TexasDiagnostic_CodingBreakdown.sql on the TexasDiagnostic database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetTD_CodingBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(N'' AS NVARCHAR(500)) AS PanelName,
           CAST(0 AS INT)             AS ClaimCount,
           CAST(0 AS DECIMAL(18,2))   AS TotalCharges
    WHERE  1 = 0;

    SELECT CAST(N'' AS NVARCHAR(500))  AS PanelName,
           CAST(N'' AS NVARCHAR(1000)) AS CPTCodeXUnitsXModifier,
           CAST(0 AS INT)              AS ClaimCount,
           CAST(0 AS DECIMAL(18,2))    AS TotalCharges
    WHERE  1 = 0;
END
GO

PRINT '11_TexasDiagnostic_CodingBreakdown.sql completed.';
GO

SET NOEXEC OFF;
GO

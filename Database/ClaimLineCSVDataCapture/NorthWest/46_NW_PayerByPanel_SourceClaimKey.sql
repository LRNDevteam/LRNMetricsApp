/* =============================================================================
   NorthWest - Production Summary - Panel X Payer unique claim count
   File     : 46_NW_PayerByPanel_SourceClaimKey.sql
   Database : NWL_LRN
   Requires : 38_NW_ProductionSummary_ClientLogic.sql, 41_NW_ProductionSummary_BilledUnbilled.sql

   Issue : Panel X Payer counted COUNT(DISTINCT ClaimID) per payer x panel.
           Daq and WebPM number ClaimID independently, so one ClaimID can be two
           different claims (different Accession / DOS / Source). Those were
           collapsed into one, e.g. Toxicology 232,909 instead of 233,306
           (SELECT COUNT(ClaimID) FROM ClaimLevelData
            WHERE BilledUnbilled = 'Billed' AND PanelType = 'Toxicology').
   Fix   : Unique claim = Source + ClaimID (Source from AdditionalFields).
           Month-grain tabs (Monthly, Weekly, Panel/Payer Breakdown) are not
           affected because the reused ClaimIDs fall in different months.
           Same definition as section 3 of 38_NW_ProductionSummary_ClientLogic.sql.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'46_NW_PayerByPanel_SourceClaimKey.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PayerByPanel
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
        SELECT PayerName, PanelName = PanelType, ClaimCount, TotalCharges
        FROM dbo.NW_PayerByPanel
        ORDER BY PayerName, PanelName;
        RETURN;
    END;

    SELECT
        c.PayerName,
        PanelName    = c.PanelType,
        ClaimCount   = COUNT(DISTINCT CASE WHEN c.ClaimID IS NOT NULL
                                           THEN CONCAT(k.SourceKey, N'|', c.ClaimID) END),
        TotalCharges = ISNULL(SUM(c.ChargeAmount), 0)
    FROM dbo.fn_NW_BilledClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) c
    CROSS APPLY (
        SELECT SourceValue = UPPER(LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(c.AdditionalFields, 'Source'), N''))))
    ) s
    CROSS APPLY (
        SELECT SourceKey = CASE
                               WHEN s.SourceValue LIKE N'DAQ%'   THEN N'DAQ'
                               WHEN s.SourceValue LIKE N'WEBPM%' THEN N'WEBPM'
                               ELSE s.SourceValue
                           END
    ) k
    GROUP BY c.PayerName, c.PanelType
    ORDER BY c.PayerName, PanelName
    OPTION (RECOMPILE);
END;
GO

-- Rebuild the snapshot the page reads (usp_RefreshNW_PayerByPanel is unchanged).
EXEC dbo.usp_RefreshNW_PayerByPanel;
GO

SET NOEXEC OFF;
GO

PRINT '46_NW_PayerByPanel_SourceClaimKey.sql completed.';
GO

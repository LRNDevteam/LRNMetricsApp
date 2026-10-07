/*
    dbo.DenialClaimLevelInsight - "$ Impact (%)" as text.
    Run against EACH LAB database (not LRNMaster).

    ImpactPercentageText  the "$ Impact (%)" cell exactly as the workbook displayed it ("57%").
                          Reading it as a number misread percent-formatted and pasted cells, so
                          the import now keeps the text and the page shows it unchanged.

    The old ImpactPercentage DECIMAL column is left in place and no longer written. A row whose
    ImpactPercentageText is NULL predates this change, and the app falls back to showing the old
    decimal for it; once a row is imported or saved again the text column takes over.

    Re-runnable. LabMetricsDashboard also adds the column itself on first use, so this script is
    for deploying ahead of the app.
*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimLevelInsight', 'ImpactPercentageText') IS NULL
BEGIN
    ALTER TABLE dbo.DenialClaimLevelInsight
        ADD ImpactPercentageText NVARCHAR(100) NULL;
    PRINT 'Added ImpactPercentageText.';
END
GO

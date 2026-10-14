/*
    dbo.DenialClaimLevelInsight - Denial Insight template v1.0
    (Templates/DenialInsights_Template_v1.0.xlsx).
    Run against EACH LAB database (not LRNMaster).

    The v1.0 template adds three columns:

      InsuranceNoOfDenials  the second "# of Denials", inside the impact group: denials for the
                            highest-impact insurance alone (NoOfDenials stays the code's total)
      Data                  free-text figures behind the observation
      Status                Open / In Progress / Closed ...

    Re-runnable: each column is added only when it is missing. LabMetricsDashboard also adds them
    itself on first use, so this script is for deploying ahead of the app.
*/

SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimLevelInsight', 'InsuranceNoOfDenials') IS NULL
BEGIN
    ALTER TABLE dbo.DenialClaimLevelInsight
        ADD InsuranceNoOfDenials INT NOT NULL CONSTRAINT DF_DCLI_InsuranceNoOfDenials DEFAULT 0;
    PRINT 'Added InsuranceNoOfDenials.';
END
GO

IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimLevelInsight', 'Data') IS NULL
BEGIN
    ALTER TABLE dbo.DenialClaimLevelInsight
        ADD Data NVARCHAR(MAX) NULL;
    PRINT 'Added Data.';
END
GO

IF OBJECT_ID('dbo.DenialClaimLevelInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.DenialClaimLevelInsight', 'Status') IS NULL
BEGIN
    ALTER TABLE dbo.DenialClaimLevelInsight
        ADD Status NVARCHAR(50) NULL;
    PRINT 'Added Status.';
END
GO

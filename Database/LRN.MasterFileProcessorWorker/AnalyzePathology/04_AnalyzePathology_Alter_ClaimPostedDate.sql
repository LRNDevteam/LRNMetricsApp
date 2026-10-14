/*
    Analyze Pathology - claim-level Posted Date.
    Run against the ANALYZE PATHOLOGY lab database. Re-runnable.

    Run this BEFORE deploying the updated AnalyzePathologyFieldMappings.json: the bulk copy fails
    outright when a mapped SqlColumn is missing from the table.

    The claim sheet's "Posted Date" now reaches the claim CSV as "Payment Posted Date" and loads into
    the same two columns it already loads into at line level:
      Posted Date -> PostingDate, PaymentPostedDate
*/

SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.ClaimLevelData', 'PostingDate') IS NULL        ALTER TABLE dbo.ClaimLevelData ADD PostingDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'PaymentPostedDate') IS NULL  ALTER TABLE dbo.ClaimLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
GO

PRINT 'Analyze Pathology claim-level Posted Date columns added.';
GO

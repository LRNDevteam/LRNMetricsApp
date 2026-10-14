/*
Run this in every LAB database that has DenialInsight / DenialTaskBoard
Example: NWL_LRN, Augustus_LRN, Certus_LRN, etc.
*/

IF COL_LENGTH('dbo.DenialInsight', 'AssignedTo') IS NULL
BEGIN
    ALTER TABLE dbo.DenialInsight ADD AssignedTo nvarchar(255) NULL;
END
GO

/* Optional compatibility column if older code uses ResponsibilityReviewer */
IF COL_LENGTH('dbo.DenialInsight', 'ResponsibilityReviewer') IS NULL
BEGIN
    ALTER TABLE dbo.DenialInsight ADD ResponsibilityReviewer nvarchar(255) NULL;
END
GO

/* Backfill DenialInsight assignment from DenialTaskBoard using DenialCode + HighImpactInsurance/PayerName */
;WITH Assigned AS
(
    SELECT
        LTRIM(RTRIM(ISNULL(DenialCode, ''))) AS DenialCode,
        LTRIM(RTRIM(ISNULL(COALESCE(PayerNameNormalized, PayerName), ''))) AS PayerName,
        MAX(NULLIF(LTRIM(RTRIM(AssignedTo)), '')) AS AssignedTo,
        LabId,
        RunId
    FROM dbo.DenialTaskBoard
    WHERE NULLIF(LTRIM(RTRIM(ISNULL(AssignedTo, ''))), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(DenialCode, ''))),
        LTRIM(RTRIM(ISNULL(COALESCE(PayerNameNormalized, PayerName), ''))),
        LabId,
        RunId
)
UPDATE di
SET
    di.AssignedTo = a.AssignedTo,
    di.ResponsibilityReviewer = a.AssignedTo
FROM dbo.DenialInsight di
INNER JOIN Assigned a
    ON LTRIM(RTRIM(ISNULL(di.DenialCodes, ''))) = a.DenialCode
   AND LTRIM(RTRIM(ISNULL(di.HighImpactInsurance, ''))) = a.PayerName
   AND (di.LabId = a.LabId OR di.LabId IS NULL OR a.LabId IS NULL)
   AND (ISNULL(di.RunId, '') = ISNULL(a.RunId, '') OR ISNULL(di.RunId, '') = '' OR ISNULL(a.RunId, '') = '');
GO

CREATE INDEX IX_DenialInsight_Assignment
ON dbo.DenialInsight (LabId, RunId, DenialCodes, HighImpactInsurance)
INCLUDE (AssignedTo, ResponsibilityReviewer);
GO

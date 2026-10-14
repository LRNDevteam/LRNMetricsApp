/* Run in the newly rebuilt target lab database. Set the expected lab id. */
:setvar ExpectedLabId "0"

SET NOCOUNT ON;

SELECT DB_NAME() AS DatabaseName, TRY_CONVERT(int,N'$(ExpectedLabId)') AS ExpectedLabId;

-- Required table inventory.
DECLARE @Required TABLE(TableName sysname PRIMARY KEY);
INSERT @Required(TableName) VALUES
(N'DenialAnalysisRunLog'),(N'DenialInsight'),(N'DenialLineItem'),(N'DenialTaskBoard'),
(N'DenialStatusMaster'),(N'DenialActionCategoryMaster'),(N'DenialTaskHistory'),(N'DenialVerificationTask'),
(N'DenialClaimEscalations'),(N'DenialClaimNotes'),(N'DenialClaimDocuments'),
(N'DenialClosedClaims'),(N'DenialClosedClaimsHistory'),(N'DenialCodeMaster'),
(N'DenialCodeActionChangeBatch'),(N'DenialCodeActionChangeVerification'),
(N'DenialMapperLabMaster'),(N'DenialMapperLabOverride');

SELECT r.TableName,
       CASE WHEN t.object_id IS NULL THEN 'MISSING' ELSE 'OK' END AS ValidationStatus,
       ISNULL(p.RowCount,0) AS RowCount
FROM @Required r
LEFT JOIN sys.tables t ON t.name=r.TableName AND t.schema_id=SCHEMA_ID(N'dbo')
OUTER APPLY(SELECT SUM(rows) RowCount FROM sys.partitions WHERE object_id=t.object_id AND index_id IN(0,1)) p
ORDER BY CASE WHEN t.object_id IS NULL THEN 0 ELSE 1 END,r.TableName;

-- Required workflow columns used by the API.
SELECT v.TableName,v.ColumnName,
       CASE WHEN COL_LENGTH(N'dbo.'+v.TableName,v.ColumnName) IS NULL THEN 'MISSING' ELSE 'OK' END AS ValidationStatus
FROM (VALUES
(N'DenialTaskBoard',N'LabId'),(N'DenialTaskBoard',N'ClaimID'),(N'DenialTaskBoard',N'TaskID'),
(N'DenialTaskBoard',N'UniqueTrackId'),(N'DenialTaskBoard',N'AssignedTo'),(N'DenialTaskBoard',N'Status'),
(N'DenialTaskBoard',N'WorkFlowStatus'),(N'DenialTaskBoard',N'DenialCode'),
(N'DenialTaskBoard',N'ICDComplianceStatus'),(N'DenialTaskBoard',N'CoverageStatus'),
(N'DenialTaskBoard',N'ActionCode'),(N'DenialTaskBoard',N'ActionCategory'),(N'DenialTaskBoard',N'Task'),
(N'DenialTaskBoard',N'ShortCategory'),(N'DenialLineItem',N'LabId'),(N'DenialLineItem',N'ClaimUID'),
(N'DenialInsight',N'LabId')) v(TableName,ColumnName)
ORDER BY ValidationStatus,v.TableName,v.ColumnName;

-- Detect accidental Northwest operational data leakage or wrong lab scoping.
SELECT 'DenialInsight' TableName,COUNT_BIG(*) WrongLabRows FROM dbo.DenialInsight WHERE LabId<>TRY_CONVERT(int,N'$(ExpectedLabId)')
UNION ALL SELECT 'DenialLineItem',COUNT_BIG(*) FROM dbo.DenialLineItem WHERE LabId<>TRY_CONVERT(int,N'$(ExpectedLabId)')
UNION ALL SELECT 'DenialTaskBoard',COUNT_BIG(*) FROM dbo.DenialTaskBoard WHERE LabId<>TRY_CONVERT(int,N'$(ExpectedLabId)');

-- Index and seeded-status checks.
SELECT OBJECT_NAME(i.object_id) TableName,COUNT(*) IndexCount
FROM sys.indexes i
WHERE OBJECT_NAME(i.object_id) IN (SELECT TableName FROM @Required) AND i.index_id>0
GROUP BY i.object_id ORDER BY TableName;

SELECT StatusName,IsClosedStatus,IsVerificationStatus,SortOrder,IsActive
FROM dbo.DenialStatusMaster ORDER BY SortOrder,StatusName;

IF EXISTS(SELECT 1 FROM @Required r LEFT JOIN sys.tables t ON t.name=r.TableName AND t.schema_id=SCHEMA_ID(N'dbo') WHERE t.object_id IS NULL)
    THROW 51010,'Denial Workflow validation failed: one or more required tables are missing.',1;
IF TRY_CONVERT(int,N'$(ExpectedLabId)')<=0
    THROW 51011,'Set ExpectedLabId before validation.',1;

PRINT 'Denial Workflow structural validation completed.';

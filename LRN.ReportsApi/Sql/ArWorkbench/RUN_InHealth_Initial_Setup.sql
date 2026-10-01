/* ============================================================================================
   AR Workbench - INITIAL SETUP RUNBOOK: LRNMaster + InHealth (Inhealth_DTR, LabId 2)

   Runs every AR Workbench script in order, each against the right database:
     STEP 1  LRNMaster       LRNMaster_01_ARWB_Roles_Access.sql   roles, permissions, dbo.ARWB_UserScope
     STEP 2  InHealthDTRLRN  pre-flight checks                    source tables present and not empty
     STEP 3  InHealthDTRLRN  00_ARWB_Drop_Existing_Objects.sql    DELETES the old arwb schema and all workbench data
     STEP 4  InHealthDTRLRN  01 ... 07 (ARWB_Lab_Database_Setup_Merged.sql)
     STEP 5  InHealthDTRLRN  08_ARWB_Optional_SourceIndex.sql     index on dbo.LineLevelData(ClaimID)
     STEP 6  InHealthDTRLRN  first sync: dbo.ARWB_usp_LoadClaimsFromSource
     STEP 7  InHealthDTRLRN  verification queries
     STEP 8  LRNMaster       (commented) give users their AR Workbench roles for LabId 2

   HOW TO RUN
     SSMS: Query > SQLCMD Mode (must be ON), connect to the managed instance that hosts both
           LRNMaster and InHealthDTRLRN, check ScriptDir below, then Execute (F5).
     Command line:
       sqlcmd -S lrnanalytics-sqlmi.public.4e3a76f4ed99.database.windows.net,3342 -U sqladmin -P <password>
              -d master -i RUN_InHealth_Initial_Setup.sql
     The script stops at the first error (:on error exit).

   STEP 3 IS DESTRUCTIVE for the workbench only: assignments, follow-ups, QA, CIP and activity in the
   old arwb tables are deleted. dbo.ClaimLevelData, dbo.LineLevelData and dbo.Denial* are untouched.
   Every other step is idempotent and can be re-run.
   ============================================================================================ */

:on error exit
:setvar ScriptDir "C:\Users\lrndev2\source\repos\LRNDevteam\LRNMetricsApp\LRN.ReportsApi\Sql\ArWorkbench"
:setvar MasterDb  "LRNMaster"
:setvar LabDb     "InHealthDTRLRN"
:setvar LabId     "2"

SET NOCOUNT ON;
GO

/* ============================================================================================
   STEP 1 - LRNMaster: roles, permissions, dbo.ARWB_UserScope (once per environment)
   ============================================================================================ */
USE [$(MasterDb)];
GO
IF DB_NAME() <> N'$(MasterDb)' THROW 53001, 'Not connected to the master database.', 1;
PRINT '=== STEP 1: ' + DB_NAME() + ' - roles and access';
GO
:r $(ScriptDir)\LRNMaster_01_ARWB_Roles_Access.sql

/* ============================================================================================
   STEP 2 - InHealth lab database: pre-flight
   ============================================================================================ */
USE [$(LabDb)];
GO
IF DB_NAME() <> N'$(LabDb)' THROW 53002, 'Not connected to the InHealth lab database.', 1;
PRINT '=== STEP 2: ' + DB_NAME() + ' - pre-flight';
IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NULL THROW 53003, 'dbo.ClaimLevelData is missing in this database.', 1;
IF NOT EXISTS (SELECT TOP (1) 1 FROM dbo.ClaimLevelData) THROW 53004, 'dbo.ClaimLevelData is empty - load the master file first.', 1;

SELECT  ClaimLevelRows      = (SELECT COUNT_BIG(*) FROM dbo.ClaimLevelData),
        DistinctClaims      = (SELECT COUNT_BIG(DISTINCT LTRIM(RTRIM(ClaimID))) FROM dbo.ClaimLevelData),
        LineLevelRows       = CASE WHEN OBJECT_ID(N'dbo.LineLevelData', N'U') IS NULL THEN NULL ELSE (SELECT COUNT_BIG(*) FROM dbo.LineLevelData) END,
        LegacyArwbObjects   = (SELECT COUNT(*) FROM sys.objects WHERE schema_id = SCHEMA_ID(N'arwb') AND parent_object_id = 0),
        ExistingArwbTables  = (SELECT COUNT(*) FROM sys.tables WHERE name LIKE N'ARWB[_]%'),
        HasDenialCodeMaster = CASE WHEN OBJECT_ID(N'dbo.DenialCodeMaster', N'U') IS NULL THEN 0 ELSE 1 END;
GO

/* ============================================================================================
   STEP 3 - InHealth: drop the legacy arwb schema and any ARWB_ objects (DESTRUCTIVE)
   ============================================================================================ */
PRINT '=== STEP 3: ' + DB_NAME() + ' - drop existing AR Workbench objects';
GO
:r $(ScriptDir)\00_ARWB_Drop_Existing_Objects.sql

/* ============================================================================================
   STEP 4 - InHealth: tables, functions, master data, procedures, views (scripts 01-07)
   ============================================================================================ */
IF DB_NAME() <> N'$(LabDb)' THROW 53002, 'Not connected to the InHealth lab database.', 1;
PRINT '=== STEP 4: ' + DB_NAME() + ' - create ARWB_ objects';
GO
:r $(ScriptDir)\ARWB_Lab_Database_Setup_Merged.sql

/* ============================================================================================
   STEP 5 - InHealth: optional index on the source line table (recommended for the full sync)
   ============================================================================================ */
PRINT '=== STEP 5: ' + DB_NAME() + ' - optional source index';
GO
:r $(ScriptDir)\08_ARWB_Optional_SourceIndex.sql

/* ============================================================================================
   STEP 6 - InHealth: first sync (every claim and every line). Can take several minutes.
   ============================================================================================ */
IF DB_NAME() <> N'$(LabDb)' THROW 53002, 'Not connected to the InHealth lab database.', 1;
PRINT '=== STEP 6: ' + DB_NAME() + ' - initial load';
EXEC dbo.ARWB_usp_LoadClaimsFromSource @RunBy = N'setup', @Note = N'InHealth initial load';
GO

/* ============================================================================================
   STEP 7 - InHealth: verification
   ============================================================================================ */
PRINT '=== STEP 7: ' + DB_NAME() + ' - verification';

-- Run summary: SourceClaimRows should equal DistinctClaims from step 2 (minus blank / >200-char IDs).
SELECT TOP (1) RefreshRunId, RunStatus, SourceClaimRows, SourceDeniedClaims, SourceLineRows, SourceDeniedLines,
       LineOnlyClaims, ClaimsInserted, ClaimsLinesReloaded, InsightsBuilt, SourcePeriodStart, SourcePeriodEnd, ErrorMessage
FROM dbo.ARWB_RefreshRun ORDER BY RefreshRunId DESC;

-- Every claim is in exactly one queue.
SELECT q.QueueLabel, SubQueue = sq.QueueLabel, Claims = COUNT(*), InsuranceAR = SUM(c.RemainingAR)
FROM dbo.ARWB_Claim c
LEFT JOIN dbo.ARWB_ArQueue q  ON q.QueueId  = c.ArQueueId
LEFT JOIN dbo.ARWB_ArQueue sq ON sq.QueueId = c.ArSubQueueId
GROUP BY q.QueueLabel, sq.QueueLabel, q.SortOrder, sq.SortOrder
ORDER BY q.SortOrder, sq.SortOrder;

SELECT ClaimsWithoutQueue = COUNT(*) FROM dbo.ARWB_Claim WHERE ArQueueId IS NULL;   -- expect 0

-- Denial codes on InHealth claims that have no category yet ('Other'): send to the business owner.
SELECT TOP (50) PrimaryDenialCode, Claims = COUNT(*), InsuranceAR = SUM(RemainingAR)
FROM dbo.ARWB_Claim
WHERE PrimaryDenialCode IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.ARWB_DenialCodeCategoryMap m WHERE m.DenialCode = PrimaryDenialCode)
GROUP BY PrimaryDenialCode
ORDER BY COUNT(*) DESC;

-- Current-week insights (Dashboard / Data Processing)
SELECT TOP (10) DenialCode, DenialCategory, OutstandingClaims, OutstandingBalance, TopPayer, ImpactPct, Observation
FROM dbo.ARWB_vw_DenialInsight ORDER BY OutstandingBalance DESC;
GO

/* ============================================================================================
   STEP 8 - LRNMaster: give users an AR Workbench role (edit and uncomment)
   Users also need InHealth (LabId 2) in dbo.UserLabs to open the lab.
   ============================================================================================ */
USE [$(MasterDb)];
GO
PRINT '=== STEP 8: ' + DB_NAME() + ' - user roles (commented template; nothing assigned)';
/*
-- Role names: 'AR Workbench - System Administrator' | '- RCM Manager' | '- Senior AR Analyst / Team Lead'
--             '- AR Agent' | '- QA Reviewer' | '- Client Viewer' | '- Clinic Viewer' | '- Provider Viewer'
INSERT INTO dbo.UserRoles (LabUserID, RoleID)
SELECT u.LabUserID, r.RoleID
FROM dbo.LabUsers u
CROSS JOIN dbo.Roles r
WHERE u.UserName = N'<user.name>'
  AND r.RoleName = N'AR Workbench - RCM Manager'
  AND NOT EXISTS (SELECT 1 FROM dbo.UserRoles x WHERE x.LabUserID = u.LabUserID AND x.RoleID = r.RoleID);

-- Clinic Viewer only: the InHealth clinic they see (must match ClaimLevelData.ClinicName exactly)
INSERT INTO dbo.ARWB_UserScope (LabUserID, LabId, ClinicName, CreatedBy)
SELECT u.LabUserID, $(LabId), N'<Clinic name>', N'setup'
FROM dbo.LabUsers u
WHERE u.UserName = N'<user.name>'
  AND NOT EXISTS (SELECT 1 FROM dbo.ARWB_UserScope s WHERE s.LabUserID = u.LabUserID AND s.LabId = $(LabId));
*/

-- Who already has an AR Workbench role, and whether they can open InHealth
SELECT u.UserName, r.RoleName,
       HasInHealthLab = CASE WHEN EXISTS (SELECT 1 FROM dbo.UserLabs ul WHERE ul.LabUserID = u.LabUserID AND ul.LabId = $(LabId)) THEN 1 ELSE 0 END
FROM dbo.UserRoles ur
INNER JOIN dbo.LabUsers u ON u.LabUserID = ur.LabUserID
INNER JOIN dbo.Roles r    ON r.RoleID    = ur.RoleID
WHERE r.RoleName LIKE N'AR Workbench - %'
ORDER BY r.RoleName, u.UserName;
GO

PRINT '=== AR Workbench setup for InHealth (LabId $(LabId)) complete.';
GO

/* =====================================================================
   Payer Master role setup (Requirements Spec v1.0 §2)
   Target database: LRNMaster

   Inserts the roles used by the Payer Policy Insurance Master and
   Lab Insurance Master screens and the approval workflow:

     - Payer Policy Admin   (Payer Policy master: add/edit/deactivate/approve)
     - Reports Analyst      (both masters: add/edit/deactivate, subject to approval)
     - Reports Manager      (Lab Insurance master: add/edit/deactivate/approve)
     - ETL                  (both masters: view only, receives notifications)

   NOTE: "LRN Admin" is NOT inserted. The existing "Admin" role (RoleID 1)
   is treated as LRN Admin by both LabMetricsDashboard and LRN.ReportsApi,
   so existing Admin users automatically get full LRN Admin access.

   Idempotent - safe to run multiple times.
   ===================================================================== */
USE [LRNMaster];
GO
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = 'Payer Policy Admin')
    INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy) VALUES ('Payer Policy Admin', 1, 'system');

IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = 'Reports Analyst')
    INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy) VALUES ('Reports Analyst', 1, 'system');

IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = 'Reports Manager')
    INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy) VALUES ('Reports Manager', 1, 'system');

IF NOT EXISTS (SELECT 1 FROM dbo.Roles WHERE RoleName = 'ETL')
    INSERT INTO dbo.Roles (RoleName, IsActive, CreatedBy) VALUES ('ETL', 1, 'system');

SELECT RoleID, RoleName, IsActive, CreatedDate, CreatedBy
FROM dbo.Roles
WHERE RoleName IN ('Admin', 'Payer Policy Admin', 'Reports Analyst', 'Reports Manager', 'ETL')
ORDER BY RoleID;
GO

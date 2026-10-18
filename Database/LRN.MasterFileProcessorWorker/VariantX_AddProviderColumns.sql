/* =====================================================================
   VariantX — add BillingProvider and ReferringProvider to the claim and line tables.

   Run on [VariantX_LRN] BEFORE the next LRN.MasterFileProcessorWorker run: VariantXFieldMappings.Json
   now maps both columns, and the bulk copy fails if the table does not have them.
   Safe to re-run.

   Values (built by the worker from the VariantX lab schemas):
     ReferringProvider = "<Ordering Physician Last Name>, <Ordering Physician First Name>"
     BillingProvider   = "<Rendering Physician Last Name>, <Rendering Physician First Name>"
   ===================================================================== */
USE [VariantX_LRN];
GO

IF COL_LENGTH('dbo.ClaimLevelData', 'BillingProvider') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD BillingProvider NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ReferringProvider') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD ReferringProvider NVARCHAR(500) NULL;

IF COL_LENGTH('dbo.LineLevelData', 'BillingProvider') IS NULL
    ALTER TABLE dbo.LineLevelData ADD BillingProvider NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ReferringProvider') IS NULL
    ALTER TABLE dbo.LineLevelData ADD ReferringProvider NVARCHAR(500) NULL;
GO

-- The TVP types named in VariantXFieldMappings.Json are not used by the bulk load (it copies
-- straight into the tables), so they are left unchanged.

/* =====================================================================
   Payer Policy Mapper - run scope (idempotent)
   Adds Scope to dbo.PayerMapperRun:
     UnmappedPending - scheduled hourly runs (new + pending-review rows only)
     AllUnmapped     - rules-change / nightly runs (includes No Match Found)
     All             - manual full scan (mapped rows are revalidated audit-only)
   ===================================================================== */
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.PayerMapperRun', 'Scope') IS NULL
BEGIN
    ALTER TABLE dbo.PayerMapperRun ADD Scope NVARCHAR(30) NULL;
END
GO

-- Backfill runs recorded before the scope existed.
UPDATE dbo.PayerMapperRun SET Scope = 'AllUnmapped' WHERE Scope IS NULL;
GO

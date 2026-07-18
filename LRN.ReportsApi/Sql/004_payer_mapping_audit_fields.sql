/* =====================================================================
   Payer mapping - test-team remediation (idempotent)
   - MappedSource / MappedOn columns on LabInsuranceMaster (audit of who/when/how a payer got mapped)
     (MappedBy already exists from 001_payer_mapper_additions.sql)
   - PayerFamilyRule: add 'UNITED HEALTHCARE' (one word) to the UHC family so
     "United Healthcare" no longer falls through as Unmapped (failure #10)
   ===================================================================== */
SET NOCOUNT ON;
GO

-- 1. Mapping-audit columns ------------------------------------------------
IF COL_LENGTH('dbo.LabInsuranceMaster', 'MappedSource') IS NULL
    ALTER TABLE dbo.LabInsuranceMaster ADD MappedSource NVARCHAR(20) NULL;   -- 'System' / 'User'
GO
IF COL_LENGTH('dbo.LabInsuranceMaster', 'MappedOn') IS NULL
    ALTER TABLE dbo.LabInsuranceMaster ADD MappedOn DATETIME2 NULL;          -- when the mapping was applied
GO

-- Backfill source for rows already mapped: an auto-match string => System, anything else with a
-- confirmed Global Payer ID => User. MappedOn best-effort backfilled from ModifiedOn.
UPDATE dbo.LabInsuranceMaster
SET MappedSource = CASE
        WHEN GlobalPayerID IS NULL THEN NULL
        WHEN MappedBy LIKE 'System%' THEN 'System'
        ELSE 'User' END,
    MappedOn = CASE WHEN GlobalPayerID IS NOT NULL THEN ModifiedOn ELSE NULL END
WHERE MappedSource IS NULL AND GlobalPayerID IS NOT NULL;
GO

-- 2. United Healthcare family rule (failure #10) --------------------------
-- "United Healthcare" canonicalizes to "UNITED HEALTHCARE" (one space), which matched neither
-- the existing "UNITED HEALTH CARE" nor "UNITEDHEALTHCARE" alternatives. Add it so the payer is
-- classified into the UHC family instead of staying Unmapped. Priority 50 = standard brand.
IF NOT EXISTS (SELECT 1 FROM dbo.PayerFamilyRule WHERE Family = 'UHC' AND Pattern LIKE '%UNITED HEALTHCARE%')
    UPDATE dbo.PayerFamilyRule
    SET Pattern = Pattern + N'|UNITED HEALTHCARE'
    WHERE Family = 'UHC' AND IsActive = 1;
GO

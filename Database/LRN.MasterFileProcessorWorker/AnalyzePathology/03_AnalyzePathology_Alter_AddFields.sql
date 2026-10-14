/*
    Analyze Pathology - columns for the source fields that were landing in AdditionalFields.
    Run against the ANALYZE PATHOLOGY lab database. Re-runnable.

    Run this BEFORE deploying the updated AnalyzePathologyFieldMappings.json: the bulk copy fails
    outright when a mapped SqlColumn is missing from the table.

    ClaimLevelData                              LineLevelData
      Charge CPT Code         -> CPTCodeList    Charge To Date             -> ChargeToDate
      Charge Units            -> UnitsList      Charge Total Payments      -> ChargeTotalPayments
      Charge Modifier List    -> ModifierList   Charge Total Adjustments   -> ChargeTotalAdjustments
      CPT Units               -> CptWithUnits     Claim Ordering Provider ID -> OrderingProviderID
      Charge To Date          -> ChargeToDate     T/F                        -> TF
      Charge Total Payments   -> ChargeTotalPayments
      Charge Total Adjustments-> ChargeTotalAdjustments
      Claim Ordering Provider ID -> OrderingProviderID
*/

SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.ClaimLevelData', 'CPTCodeList') IS NULL          ALTER TABLE dbo.ClaimLevelData ADD CPTCodeList NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'UnitsList') IS NULL            ALTER TABLE dbo.ClaimLevelData ADD UnitsList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ModifierList') IS NULL         ALTER TABLE dbo.ClaimLevelData ADD ModifierList NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'CptWithUnits') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD CptWithUnits NVARCHAR(MAX) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeToDate') IS NULL           ALTER TABLE dbo.ClaimLevelData ADD ChargeToDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalPayments') IS NULL    ALTER TABLE dbo.ClaimLevelData ADD ChargeTotalPayments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'ChargeTotalAdjustments') IS NULL ALTER TABLE dbo.ClaimLevelData ADD ChargeTotalAdjustments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.ClaimLevelData', 'OrderingProviderID') IS NULL     ALTER TABLE dbo.ClaimLevelData ADD OrderingProviderID NVARCHAR(500) NULL;
GO

IF COL_LENGTH('dbo.LineLevelData', 'ChargeToDate') IS NULL            ALTER TABLE dbo.LineLevelData ADD ChargeToDate NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeTotalPayments') IS NULL     ALTER TABLE dbo.LineLevelData ADD ChargeTotalPayments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'ChargeTotalAdjustments') IS NULL  ALTER TABLE dbo.LineLevelData ADD ChargeTotalAdjustments NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'OrderingProviderID') IS NULL      ALTER TABLE dbo.LineLevelData ADD OrderingProviderID NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.LineLevelData', 'TF') IS NULL                      ALTER TABLE dbo.LineLevelData ADD TF NVARCHAR(10) NULL;
GO

PRINT 'Analyze Pathology AdditionalFields columns added.';
GO

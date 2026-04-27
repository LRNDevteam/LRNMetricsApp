-- Alter script: add lab-specific columns to existing LineLevelData and LineLevelDataArchive tables
-- Run this against the target database that already contains the LineLevel CSV tables.

SET NOCOUNT ON;

-- Add columns to LineLevelData if they do not exist
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'UID')
ALTER TABLE dbo.LineLevelData ADD
    [UID] NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'T_F')
ALTER TABLE dbo.LineLevelData ADD
    [T_F] NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatientName')
ALTER TABLE dbo.LineLevelData ADD
    [PatientName] NVARCHAR(1000) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CombinedLineLevelICD')
ALTER TABLE dbo.LineLevelData ADD
    [CombinedLineLevelICD] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'SubscriberId')
ALTER TABLE dbo.LineLevelData ADD
    [SubscriberId] NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ClaimAmount')
ALTER TABLE dbo.LineLevelData ADD
    [ClaimAmount] NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CptWithUnits')
ALTER TABLE dbo.LineLevelData ADD
    [CptWithUnits] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Proc')
ALTER TABLE dbo.LineLevelData ADD
    [Proc] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EnteredStatus')
ALTER TABLE dbo.LineLevelData ADD
    [EnteredStatus] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BilledStatus')
ALTER TABLE dbo.LineLevelData ADD
    [BilledStatus] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ProcTotalBal')
ALTER TABLE dbo.LineLevelData ADD
    [ProcTotalBal] NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'UpdatedDenialCode')
ALTER TABLE dbo.LineLevelData ADD
    [UpdatedDenialCode] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CombinedLineLevelDenialCode')
ALTER TABLE dbo.LineLevelData ADD
    [CombinedLineLevelDenialCode] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Loc')
ALTER TABLE dbo.LineLevelData ADD
    [Loc] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ProcInsLastRefiledDeniedReason')
ALTER TABLE dbo.LineLevelData ADD
    [ProcInsLastRefiledDeniedReason] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ProcInsResponsibleCarrierOriginalFilingDate')
ALTER TABLE dbo.LineLevelData ADD
    [ProcInsResponsibleCarrierOriginalFilingDate] NVARCHAR(100) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ProcInsStatus')
ALTER TABLE dbo.LineLevelData ADD
    [ProcInsStatus] NVARCHAR(MAX) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ProcInsLastRefiledDeniedDate')
ALTER TABLE dbo.LineLevelData ADD
    [ProcInsLastRefiledDeniedDate] NVARCHAR(100) NULL;

-- Add same columns to LineLevelDataArchive if they do not exist
IF OBJECT_ID('dbo.LineLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'UID')
    ALTER TABLE dbo.LineLevelDataArchive ADD [UID] NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'T_F')
    ALTER TABLE dbo.LineLevelDataArchive ADD [T_F] NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PatientName')
    ALTER TABLE dbo.LineLevelDataArchive ADD [PatientName] NVARCHAR(1000) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CombinedLineLevelICD')
    ALTER TABLE dbo.LineLevelDataArchive ADD [CombinedLineLevelICD] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'SubscriberId')
    ALTER TABLE dbo.LineLevelDataArchive ADD [SubscriberId] NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ClaimAmount')
    ALTER TABLE dbo.LineLevelDataArchive ADD [ClaimAmount] NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CptWithUnits')
    ALTER TABLE dbo.LineLevelDataArchive ADD [CptWithUnits] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Proc')
    ALTER TABLE dbo.LineLevelDataArchive ADD [Proc] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'EnteredStatus')
    ALTER TABLE dbo.LineLevelDataArchive ADD [EnteredStatus] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BilledStatus')
    ALTER TABLE dbo.LineLevelDataArchive ADD [BilledStatus] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ProcTotalBal')
    ALTER TABLE dbo.LineLevelDataArchive ADD [ProcTotalBal] NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'UpdatedDenialCode')
    ALTER TABLE dbo.LineLevelDataArchive ADD [UpdatedDenialCode] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CombinedLineLevelDenialCode')
    ALTER TABLE dbo.LineLevelDataArchive ADD [CombinedLineLevelDenialCode] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Loc')
    ALTER TABLE dbo.LineLevelDataArchive ADD [Loc] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ProcInsLastRefiledDeniedReason')
    ALTER TABLE dbo.LineLevelDataArchive ADD [ProcInsLastRefiledDeniedReason] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ProcInsResponsibleCarrierOriginalFilingDate')
    ALTER TABLE dbo.LineLevelDataArchive ADD [ProcInsResponsibleCarrierOriginalFilingDate] NVARCHAR(100) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ProcInsStatus')
    ALTER TABLE dbo.LineLevelDataArchive ADD [ProcInsStatus] NVARCHAR(MAX) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ProcInsLastRefiledDeniedDate')
    ALTER TABLE dbo.LineLevelDataArchive ADD [ProcInsLastRefiledDeniedDate] NVARCHAR(100) NULL;
END

PRINT 'Alter script completed.\nNote: this script adds columns to LineLevelData and LineLevelDataArchive.\nTo update the TVP type (LineLevelDataTVP) and stored procedure (usp_BulkInsertLineLevelData) to include these fields, run the updated recreate script: ClaimLineCSVDataCapture/Sql/04_Recreate_LineLevelDataTVP_And_UpdateSP.sql (it drops and recreates the TVP and SP).'

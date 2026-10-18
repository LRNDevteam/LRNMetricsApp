/*
    Analyze Pathology - registration in LRNMaster.dbo.Labs.
    Run against LRNMaster (NOT the lab database).

    dbo.Labs is the shared lab registry (Master File Processor, Denial Processor, LRN Metrics, LRN API).
    LabRegistry reads LabId, LabName, ConnectionKey and IsActive from it; without a row the worker
    falls back to MasterFileProcessor:Labs in appsettings.json, so this is not a hard prerequisite
    for the load itself.

    CONFIRM BEFORE RUNNING:
      @LabId          26 is provisional - the next id not used anywhere in this repo. It must match
                      "LabId" in appsettings.json (MasterFileProcessor:Labs) and
                      Schemas/LabMappings/AnalyzePathologyFieldMappings.json.
      @ConnectionKey  Key Vault secret / ConnectionStrings entry holding the lab database
                      connection string (AnalyzePathology_LRN).

    dbo.Labs may carry further NOT NULL columns on your server that are not listed here; add them to
    the INSERT if it fails. Nothing is changed when the LabId already exists.
*/

SET NOCOUNT ON;

DECLARE @LabId         INT           = 26;
DECLARE @LabName       NVARCHAR(200) = N'Analyze Pathology';
DECLARE @ConnectionKey NVARCHAR(200) = N'AnalyzePathologyConnStr';

IF OBJECT_ID('dbo.Labs', 'U') IS NULL
BEGIN
    PRINT 'dbo.Labs does not exist on this server - nothing to register (the worker uses appsettings.json).';
END
ELSE IF EXISTS (SELECT 1 FROM dbo.Labs WHERE LabId = @LabId)
BEGIN
    SELECT LabId, LabName, ConnectionKey, IsActive FROM dbo.Labs WHERE LabId = @LabId;
    PRINT 'LabId already registered - left unchanged. Check the row above is Analyze Pathology.';
END
ELSE
BEGIN
    -- LabId is an explicit, agreed id, so it is inserted as-is whether or not the column is an identity.
    DECLARE @insert NVARCHAR(MAX) =
        N'INSERT INTO dbo.Labs (LabId, LabName, ConnectionKey, IsActive) VALUES (@LabId, @LabName, @ConnectionKey, 1);';

    IF COLUMNPROPERTY(OBJECT_ID('dbo.Labs'), 'LabId', 'IsIdentity') = 1
        SET @insert = N'SET IDENTITY_INSERT dbo.Labs ON; ' + @insert + N' SET IDENTITY_INSERT dbo.Labs OFF;';

    EXEC sp_executesql @insert,
        N'@LabId INT, @LabName NVARCHAR(200), @ConnectionKey NVARCHAR(200)',
        @LabId = @LabId, @LabName = @LabName, @ConnectionKey = @ConnectionKey;

    PRINT 'Registered Analyze Pathology in dbo.Labs.';
END

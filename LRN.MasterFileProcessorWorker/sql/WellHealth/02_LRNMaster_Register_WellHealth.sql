/*
    WellHealth - registration in LRNMaster.dbo.Labs.
    Run against LRNMaster (NOT the lab database). Re-runnable.

    dbo.Labs is the shared lab registry (Master File Processor, Denial Processor, LRN Metrics, LRN API).
    LabRegistry reads LabId, LabName, ConnectionKey and IsActive from it; without a row the worker
    falls back to MasterFileProcessor:Labs in appsettings.json.

      @LabId          27 - must match "LabId" in LRN.MasterFileProcessorWorker/appsettings.json and
                      Schemas/LabMappings/WellHealthFieldMappings.json.
      @LabName        "WellHealth" - the configured LabName (it also names output files and folders).
      @ConnectionKey  Key Vault secret / ConnectionStrings entry for the WellHealth lab database.

    The INSERT is built from the columns this server's dbo.Labs actually has: ConnectionKey, IsActive,
    CreatedBy and CreatedDate are each written only when present, and IDENTITY_INSERT is toggled only
    when LabId really is an identity. Nothing is inserted when the lab is already registered; the
    script stops if the name is registered under another id or the id belongs to another lab.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @LabId         INT           = 27;
DECLARE @LabName       NVARCHAR(200) = N'WellHealth';
DECLARE @ConnectionKey NVARCHAR(200) = N'WellHealthConnStr';
DECLARE @Msg           NVARCHAR(400);

IF OBJECT_ID(N'dbo.Labs', 'U') IS NULL
BEGIN
    SET @Msg = N'dbo.Labs was not found in "' + DB_NAME() + N'". Are you connected to LRNMaster?';
    RAISERROR(@Msg, 16, 1);
    RETURN;
END

DECLARE @HasIdentity      BIT = CASE WHEN COLUMNPROPERTY(OBJECT_ID(N'dbo.Labs'), 'LabId', 'IsIdentity') = 1 THEN 1 ELSE 0 END;
DECLARE @HasConnectionKey BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'ConnectionKey') IS NULL THEN 0 ELSE 1 END;
DECLARE @HasIsActive      BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'IsActive')      IS NULL THEN 0 ELSE 1 END;
DECLARE @HasCreatedBy     BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'CreatedBy')     IS NULL THEN 0 ELSE 1 END;
DECLARE @HasCreatedDate   BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'CreatedDate')   IS NULL THEN 0 ELSE 1 END;

IF @HasConnectionKey = 0
    PRINT N'WARNING: dbo.Labs has no ConnectionKey column - the worker will use LabDbConnectionKey from appsettings.json.';

DECLARE @ExistingId   INT           = (SELECT TOP (1) LabId   FROM dbo.Labs WHERE LabName = @LabName);
DECLARE @IdTakenByLab NVARCHAR(200) = (SELECT TOP (1) LabName FROM dbo.Labs WHERE LabId   = @LabId);

IF @ExistingId IS NOT NULL AND @ExistingId <> @LabId
BEGIN
    SET @Msg = N'"' + @LabName + N'" already exists with LabId ' + CAST(@ExistingId AS NVARCHAR(10))
             + N', but appsettings.json expects ' + CAST(@LabId AS NVARCHAR(10)) + N'. Reconcile them first.';
    THROW 51101, @Msg, 1;
END

IF @ExistingId IS NULL AND @IdTakenByLab IS NOT NULL
BEGIN
    SET @Msg = N'LabId ' + CAST(@LabId AS NVARCHAR(10)) + N' is already used by "' + @IdTakenByLab
             + N'". Pick another id and update appsettings.json and WellHealthFieldMappings.json to match.';
    THROW 51102, @Msg, 1;
END

IF @ExistingId IS NOT NULL
BEGIN
    PRINT N'"' + @LabName + N'" is already registered as LabId ' + CAST(@LabId AS NVARCHAR(10)) + N' - left unchanged.';
END
ELSE
BEGIN
    DECLARE @cols NVARCHAR(MAX) = N'LabId, LabName';
    DECLARE @vals NVARCHAR(MAX) = N'@LabId, @LabName';

    IF @HasConnectionKey = 1 SELECT @cols += N', ConnectionKey', @vals += N', @ConnectionKey';
    IF @HasIsActive      = 1 SELECT @cols += N', IsActive',      @vals += N', 1';
    IF @HasCreatedBy     = 1 SELECT @cols += N', CreatedBy',     @vals += N', N''system''';
    IF @HasCreatedDate   = 1 SELECT @cols += N', CreatedDate',   @vals += N', SYSUTCDATETIME()';

    DECLARE @sql NVARCHAR(MAX) = N'INSERT INTO dbo.Labs (' + @cols + N') VALUES (' + @vals + N');';

    -- IDENTITY_INSERT is only legal when LabId really is an identity.
    IF @HasIdentity = 1
        SET @sql = N'SET IDENTITY_INSERT dbo.Labs ON; ' + @sql + N' SET IDENTITY_INSERT dbo.Labs OFF;';

    EXEC sp_executesql @sql,
        N'@LabId INT, @LabName NVARCHAR(200), @ConnectionKey NVARCHAR(200)',
        @LabId = @LabId, @LabName = @LabName, @ConnectionKey = @ConnectionKey;

    PRINT N'Registered "' + @LabName + N'" in dbo.Labs as LabId ' + CAST(@LabId AS NVARCHAR(10)) + N'.';
END

SELECT * FROM dbo.Labs WHERE LabId = @LabId;

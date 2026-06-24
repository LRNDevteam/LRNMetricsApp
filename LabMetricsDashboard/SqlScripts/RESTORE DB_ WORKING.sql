USE master;
GO

--RESTORE FILELISTONLY
--FROM DISK = N'D:\LRN\SQLBackUp\CoveLRN_14Jan2026.bak';

DECLARE @BackupFile NVARCHAR(4000) = N'D:\LRN\Automation\NWL_LRN_21Apr\NWL_LRN_21Apr.bak';
DECLARE @TargetDb   SYSNAME        = N'NWL_LRN';

DECLARE @DataPath NVARCHAR(4000);
DECLARE @LogPath  NVARCHAR(4000);

SELECT @DataPath = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name)) + 1)
FROM master.sys.master_files
WHERE database_id = 1 AND file_id = 1;

SELECT @LogPath = LEFT(physical_name, LEN(physical_name) - CHARINDEX('\', REVERSE(physical_name)) + 1)
FROM master.sys.master_files
WHERE database_id = 1 AND file_id = 2;

DECLARE @DataFile NVARCHAR(4000) = @DataPath + N'NWL_LRN.mdf';
DECLARE @LogFile  NVARCHAR(4000) = @LogPath  + N'NWL_LRN_log.ldf';

IF DB_ID(@TargetDb) IS NOT NULL
BEGIN
    EXEC('ALTER DATABASE [' + @TargetDb + '] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;');
    EXEC('DROP DATABASE [' + @TargetDb + '];');
END

-- ✅ These must match the backup's logical names
DECLARE @LogicalData SYSNAME = N'NWL_LRN';
DECLARE @LogicalLog  SYSNAME = N'NWL_LRN_log';

RESTORE DATABASE NWL_LRN
FROM DISK = @BackupFile
WITH
    MOVE @LogicalData TO @DataFile,
    MOVE @LogicalLog  TO @LogFile,
    REPLACE,
    RECOVERY,
    STATS = 10;
GO

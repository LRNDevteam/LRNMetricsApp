-- LRN Averages Import Worker — RunId tracking / dedup table.
-- The only new DB object required. CPTAverage, PanelAverage and
-- sp_GetRecentSuccessRunByLab already exist in LRNMaster.
USE LRNMaster;
GO

IF OBJECT_ID('dbo.AverageImportLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AverageImportLog
    (
        ImportLogId INT IDENTITY(1,1) PRIMARY KEY,
        RunId NVARCHAR(50) NOT NULL,
        LabId INT NOT NULL,
        LabName NVARCHAR(250) NULL,
        FileType NVARCHAR(50) NOT NULL,        -- 'CptAverage' | 'PanelAverage'
        FileName NVARCHAR(500) NULL,
        RecordCount INT NULL,
        Status NVARCHAR(20) NOT NULL,          -- 'Success' | 'Failed'
        ErrorMessage NVARCHAR(MAX) NULL,
        ImportedOn DATETIME NOT NULL DEFAULT(GETDATE())
    );

    -- At most one Success per RunId + LabId + FileType; Failed attempts never block a retry.
    CREATE UNIQUE INDEX UX_AverageImportLog_Run
        ON dbo.AverageImportLog(RunId, LabId, FileType) WHERE Status = 'Success';
END
GO

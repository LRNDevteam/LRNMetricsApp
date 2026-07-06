IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LIMSMaster
    (
        Accession NVARCHAR(50) NULL,
        PatientName NVARCHAR(255) NULL,
        RequestCollectDate DATE NULL,
        IncorrectDOS NVARCHAR(255) NULL,
        RequestReceivedDate DATE NULL,
        BillType NVARCHAR(255) NULL,
        ResultStatus NVARCHAR(255) NULL,
        BilledTo NVARCHAR(255) NULL,
        BillStatus NVARCHAR(255) NULL,
        FinalStatus NVARCHAR(255) NULL,
        Category NVARCHAR(255) NULL,
        SourceFile NVARCHAR(260) NULL,
        RunId VARCHAR(30) NULL,
        CreatedOn DATETIME NOT NULL CONSTRAINT DF_LIMSMaster_CreatedOn DEFAULT (GETDATE())
    );
END;

IF COL_LENGTH('dbo.LIMSMaster', 'SourceFile') IS NULL
BEGIN
    ALTER TABLE dbo.LIMSMaster ADD SourceFile NVARCHAR(260) NULL;
END;

IF COL_LENGTH('dbo.LIMSMaster', 'RunId') IS NULL
BEGIN
    ALTER TABLE dbo.LIMSMaster ADD RunId VARCHAR(30) NULL;
END;

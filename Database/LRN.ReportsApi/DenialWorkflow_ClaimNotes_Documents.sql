IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimNotes
    (
        NoteId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimNotes PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        TaskId nvarchar(100) NULL,
        CptCode nvarchar(50) NULL,
        NoteLevel nvarchar(20) NOT NULL, -- Claim / Line
        NoteText nvarchar(max) NOT NULL,
        CreatedBy nvarchar(256) NOT NULL,
        CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClaimNotes_CreatedOn DEFAULT SYSUTCDATETIME(),
        IsDeleted bit NOT NULL CONSTRAINT DF_DenialClaimNotes_IsDeleted DEFAULT 0
    );

    CREATE INDEX IX_DenialClaimNotes_Claim ON dbo.DenialClaimNotes(LabId, ClaimId, NoteLevel, CreatedOn DESC);
    CREATE INDEX IX_DenialClaimNotes_Line ON dbo.DenialClaimNotes(LabId, ClaimId, TaskId, CptCode, CreatedOn DESC);
END;

IF OBJECT_ID('dbo.DenialClaimDocuments','U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialClaimDocuments
    (
        DocumentId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DenialClaimDocuments PRIMARY KEY,
        LabId int NOT NULL,
        ClaimId nvarchar(150) NOT NULL,
        OriginalFileName nvarchar(260) NOT NULL,
        StoredFileName nvarchar(260) NOT NULL,
        ContentType nvarchar(150) NULL,
        FileSizeBytes bigint NOT NULL,
        FilePath nvarchar(1000) NOT NULL,
        Comment nvarchar(1000) NULL,
        UploadedBy nvarchar(256) NOT NULL,
        UploadedOn datetime2(0) NOT NULL CONSTRAINT DF_DenialClaimDocuments_UploadedOn DEFAULT SYSUTCDATETIME(),
        IsDeleted bit NOT NULL CONSTRAINT DF_DenialClaimDocuments_IsDeleted DEFAULT 0
    );

    CREATE INDEX IX_DenialClaimDocuments_Claim ON dbo.DenialClaimDocuments(LabId, ClaimId, UploadedOn DESC);
END;

\
IF OBJECT_ID('dbo.BillingFrequencyFileStatus','U') IS NULL
BEGIN
    CREATE TABLE dbo.BillingFrequencyFileStatus
    (
        LabId           int             NOT NULL,
        DriveId         nvarchar(200)    NOT NULL,
        ItemId          nvarchar(200)    NOT NULL,
        ETagKey         nvarchar(300)    NOT NULL,
        FileName        nvarchar(400)    NOT NULL,
        SharePointPath  nvarchar(1000)   NOT NULL,
        LastModifiedUtc datetimeoffset   NULL,

        Status          nvarchar(30)     NOT NULL,
        StatusMessage   nvarchar(max)    NULL,

        Attempts        int             NOT NULL CONSTRAINT DF_BFFS_Attempts DEFAULT(0),
        FirstSeenUtc    datetimeoffset   NOT NULL CONSTRAINT DF_BFFS_FirstSeen DEFAULT(SYSUTCDATETIME()),
        LastAttemptUtc  datetimeoffset   NOT NULL CONSTRAINT DF_BFFS_LastAttempt DEFAULT(SYSUTCDATETIME()),
        ProcessedAtUtc  datetimeoffset   NULL,

        CONSTRAINT PK_BillingFrequencyFileStatus PRIMARY KEY (LabId, ItemId, ETagKey)
    );

    CREATE INDEX IX_BFFS_Status ON dbo.BillingFrequencyFileStatus(Status);
END
GO

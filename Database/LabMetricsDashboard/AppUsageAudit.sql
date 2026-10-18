IF OBJECT_ID('dbo.AppUsageAudit', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AppUsageAudit
    (
        UsageAuditId BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        OccurredOnUtc DATETIME2(0) NOT NULL CONSTRAINT DF_AppUsageAudit_OccurredOnUtc DEFAULT SYSUTCDATETIME(),
        UserName NVARCHAR(256) NULL,
        BrowserId NVARCHAR(100) NOT NULL,
        TabId NVARCHAR(100) NULL,
        PageName NVARCHAR(200) NULL,
        Path NVARCHAR(400) NULL,
        QueryString NVARCHAR(1200) NULL,
        IpAddress NVARCHAR(64) NULL,
        UserAgent NVARCHAR(1000) NULL,
        ActivityType NVARCHAR(50) NULL
    );
END;

IF OBJECT_ID('dbo.AppUsagePageSession', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AppUsagePageSession
    (
        PageSessionId NVARCHAR(220) NOT NULL PRIMARY KEY,
        BrowserId NVARCHAR(100) NOT NULL,
        TabId NVARCHAR(100) NOT NULL,
        UserName NVARCHAR(256) NULL,
        PageName NVARCHAR(200) NULL,
        Path NVARCHAR(400) NULL,
        QueryString NVARCHAR(1200) NULL,
        IpAddress NVARCHAR(64) NULL,
        UserAgent NVARCHAR(1000) NULL,
        LastLocationText NVARCHAR(255) NULL,
        LastLatitude DECIMAL(9,6) NULL,
        LastLongitude DECIMAL(9,6) NULL,
        FirstSeenOnUtc DATETIME2(0) NOT NULL CONSTRAINT DF_AppUsagePageSession_FirstSeenOnUtc DEFAULT SYSUTCDATETIME(),
        LastSeenOnUtc DATETIME2(0) NOT NULL CONSTRAINT DF_AppUsagePageSession_LastSeenOnUtc DEFAULT SYSUTCDATETIME(),
        LastActionOnUtc DATETIME2(0) NULL,
        CurrentIdleSeconds INT NOT NULL CONSTRAINT DF_AppUsagePageSession_CurrentIdle DEFAULT(0),
        MaxIdleSeconds INT NOT NULL CONSTRAINT DF_AppUsagePageSession_MaxIdle DEFAULT(0)
    );
END;

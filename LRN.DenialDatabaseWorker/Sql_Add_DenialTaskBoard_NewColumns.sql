IF COL_LENGTH('dbo.DenialTaskBoard', 'ICDCodes') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ICDCodes NVARCHAR(MAX) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'CoverageStatus') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD CoverageStatus NVARCHAR(200) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'ICDComplianceStatus') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ICDComplianceStatus NVARCHAR(200) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'DenialValidity') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD DenialValidity NVARCHAR(MAX) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'ClaimUID') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ClaimUID NVARCHAR(600) NULL;
END;

IF COL_LENGTH('dbo.DenialLineItem', 'ClaimUID') IS NULL
BEGIN
    ALTER TABLE dbo.DenialLineItem ADD ClaimUID NVARCHAR(600) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'WorkFlowStatus') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD WorkFlowStatus NVARCHAR(100) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'ClaimFrom') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD ClaimFrom NVARCHAR(50) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'Units') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD Units INT NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'Modifier') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD Modifier NVARCHAR(50) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'Source') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD Source NVARCHAR(50) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'PatName') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD PatName NVARCHAR(250) NULL;
END;

IF COL_LENGTH('dbo.DenialTaskBoard', 'SubscriberId') IS NULL
BEGIN
    ALTER TABLE dbo.DenialTaskBoard ADD SubscriberId NVARCHAR(50) NULL;
END;

IF COL_LENGTH('dbo.DenialLineItem', 'AssignedTo') IS NULL
BEGIN
    ALTER TABLE dbo.DenialLineItem ADD AssignedTo NVARCHAR(200) NULL;
END;

IF COL_LENGTH('dbo.DenialLineItem', 'WorkFlowStatus') IS NULL
BEGIN
    ALTER TABLE dbo.DenialLineItem ADD WorkFlowStatus NVARCHAR(100) NULL;
END;

IF COL_LENGTH('dbo.DenialLineItem', 'ClaimFrom') IS NULL
BEGIN
    ALTER TABLE dbo.DenialLineItem ADD ClaimFrom NVARCHAR(50) NULL;
END;

IF COL_LENGTH('dbo.DenialLineItem', 'Source') IS NULL
BEGIN
    ALTER TABLE dbo.DenialLineItem ADD Source NVARCHAR(50) NULL;
END;

IF COL_LENGTH('dbo.DenialLineItem', 'PatName') IS NULL
BEGIN
    ALTER TABLE dbo.DenialLineItem ADD PatName NVARCHAR(250) NULL;
END;

IF COL_LENGTH('dbo.DenialLineItem', 'SubscriberId') IS NULL
BEGIN
    ALTER TABLE dbo.DenialLineItem ADD SubscriberId NVARCHAR(50) NULL;
END;

IF OBJECT_ID('dbo.DenialVerification', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialVerification
    (
        DenialVerificationId INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        ClaimUID NVARCHAR(600) NOT NULL,
        TaskID NVARCHAR(100) NULL,
        ClaimID NVARCHAR(100) NULL,
        UniqueTrackId NVARCHAR(450) NULL,
        LabId INT NOT NULL,
        LabName NVARCHAR(200) NULL,
        RunId NVARCHAR(100) NULL,
        AssignedTo NVARCHAR(200) NULL,
        Status NVARCHAR(100) NULL,
        VerificationStatus NVARCHAR(100) NOT NULL,
        CreatedOn DATETIME2 NOT NULL
    );
END;

-- Create tables for user/role management (LRNMaster)
-- Run against the LRNMaster database (DefaultConnection)

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'LabUsers')
BEGIN
    CREATE TABLE dbo.LabUsers (
        LabUserID INT IDENTITY(1,1) PRIMARY KEY,
        UserName NVARCHAR(200) NOT NULL,
        PasswordHash NVARCHAR(500) NULL,
        FirstName NVARCHAR(200) NULL,
        LastName NVARCHAR(200) NULL,
        MiddleName NVARCHAR(200) NULL,
        Email NVARCHAR(255) NULL,
        Mobile NVARCHAR(50) NULL,
        IsExternalUser BIT NOT NULL DEFAULT 0,
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedDate DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedDate DATETIME2 NULL,
        CreatedBy NVARCHAR(100) NULL,
        ModifiedBy NVARCHAR(100) NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Roles')
BEGIN
    CREATE TABLE dbo.Roles (
        RoleID INT IDENTITY(1,1) PRIMARY KEY,
        RoleName NVARCHAR(200) NOT NULL,
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedDate DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedDate DATETIME2 NULL,
        CreatedBy NVARCHAR(100) NULL,
        ModifiedBy NVARCHAR(100) NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'UserRoles')
BEGIN
    CREATE TABLE dbo.UserRoles (
        UserRoleId INT IDENTITY(1,1) PRIMARY KEY,
        LabUserID INT NOT NULL CONSTRAINT FK_UserRoles_LabUsers FOREIGN KEY REFERENCES dbo.LabUsers(LabUserID),
        RoleID INT NOT NULL CONSTRAINT FK_UserRoles_Roles FOREIGN KEY REFERENCES dbo.Roles(RoleID)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'UserLabs')
BEGIN
    CREATE TABLE dbo.UserLabs (
        ULID INT IDENTITY(1,1) PRIMARY KEY,
        LabId INT NOT NULL, -- references existing Labs table
        LabUserID INT NOT NULL CONSTRAINT FK_UserLabs_LabUsers FOREIGN KEY REFERENCES dbo.LabUsers(LabUserID)
    );
END
GO

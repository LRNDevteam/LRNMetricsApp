-- Creates dbo.RoleFeatureAccess: per-role Enable/Disable for screen elements that are NOT
-- navbar menu items and so cannot be granted through dbo.UserRoleMenu.
--
-- Today that is the Reimbursement Insights chat icon in the header and the "Ask about
-- reimbursement rates" shortcut inside the floating help chat bubble. Both are edited in
-- Admin > Role Menu Mapping, under "Other screen access".
--
-- A missing row means "not decided": the application falls back to the role's menu access
-- for ReimbursementChat/Index, which is exactly how both elements behaved before this table
-- existed. So this script changes nothing on its own - it only makes the override possible.
--
-- Resolution across a user's roles: any role that enables a feature wins over a role that
-- disables it, matching how menu access is a union across roles.
--
-- FeatureKey values are defined in code (LRN.ReportsApi MenuFeatureCatalog). A row whose key
-- is not in that catalogue is ignored on read, so a removed feature cannot resurrect itself.
--
-- Idempotent: safe to run more than once.
USE LRNMaster;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID(N'dbo.RoleFeatureAccess', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.RoleFeatureAccess
    (
        RoleFeatureAccessId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_RoleFeatureAccess PRIMARY KEY,
        RoleId              INT               NOT NULL,
        FeatureKey          NVARCHAR(100)     NOT NULL,
        IsEnabled           BIT               NOT NULL CONSTRAINT DF_RoleFeatureAccess_Enabled DEFAULT(1),
        CreatedBy           NVARCHAR(100)     NOT NULL CONSTRAINT DF_RoleFeatureAccess_CreatedBy DEFAULT(N'system'),
        CreatedOn           DATETIME2(0)      NOT NULL CONSTRAINT DF_RoleFeatureAccess_CreatedOn DEFAULT(SYSDATETIME()),
        ModifiedBy          NVARCHAR(100)     NULL,
        ModifiedOn          DATETIME2(0)      NULL,

        CONSTRAINT FK_RoleFeatureAccess_Role FOREIGN KEY (RoleId) REFERENCES dbo.Roles(RoleID),
        CONSTRAINT UX_RoleFeatureAccess UNIQUE (RoleId, FeatureKey)
    );

    PRINT 'Created table dbo.RoleFeatureAccess.';
END
ELSE
    PRINT 'dbo.RoleFeatureAccess already exists - nothing to do.';
GO

/* ------------------------------------------------------------------- Verify */
SELECT fa.RoleId, r.RoleName, fa.FeatureKey, fa.IsEnabled, fa.ModifiedBy, fa.ModifiedOn
FROM dbo.RoleFeatureAccess fa
LEFT JOIN dbo.Roles r ON r.RoleID = fa.RoleId
ORDER BY r.RoleName, fa.FeatureKey;
GO

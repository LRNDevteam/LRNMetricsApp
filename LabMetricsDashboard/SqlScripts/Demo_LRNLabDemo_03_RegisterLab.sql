/* ============================================================================
   Demo lab step 3 of 3 - register LRNLabDemo in LRNMaster.

   RUN AGAINST LRNMaster. The USE below does that for you.

   dbo.Labs is the single global lab registry - the Denial Dashboard, Denial
   Workflow, Master Values and Denial Mapper all resolve LabId from it. The id
   here MUST match the LabsID entry in both appsettings.json files, or the
   dashboard and the API will disagree about which lab the user is looking at.

   LabId 99 is reserved for demo/training labs: well clear of the real ids
   (2-24) so it never collides as new clients are added.

   SCHEMA-TOLERANT. dbo.Labs predates LabMaster_CreateTable.sql on some servers,
   so this script does not assume its shape:
     * LabId may or may not be an IDENTITY column - IDENTITY_INSERT is only
       toggled when it actually is one.
     * The audit columns (CreatedBy/CreatedDate/ModifiedBy/ModifiedDate) are
       written only if they exist.
   It reports what it found, so a surprising schema is visible rather than silent.

   RE-RUNNABLE. It only inserts what is missing, and never touches the lab's
   data - so re-running after a step 1 refresh is safe and quick.

   Access model: LRNLabDemo is listed under LabConfig:DemoLabs in appsettings,
   which keeps it OUT of the "admins see every lab" shortcut. It appears only
   for users explicitly assigned it below - admins included. That is deliberate:
   a lab whose data is deliberately frozen reads as a stalled pipeline on the
   Report Control Board for anyone who is not expecting it.
   ============================================================================ */

USE LRNMaster;
GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

DECLARE @DemoLabId   INT           = 99;
DECLARE @DemoLabName NVARCHAR(200) = N'LRNLabDemo';

/* Optional: the demo login to assign the lab to. Leave @DemoUserName NULL to skip
   the user part and do it in Admin > Manage Users / Assign User Labs instead
   (which is the better route, because the UI hashes the password properly). */
DECLARE @DemoUserName NVARCHAR(200) = NULL;   -- e.g. N'demo.user'

/* RAISERROR substitutions must be constants or variables - a function call such as
   DB_NAME() there is a parse error, which kills the whole batch before it runs. */
DECLARE @Msg NVARCHAR(1000);

/* ── What does dbo.Labs actually look like here? ─────────────────────────── */
IF OBJECT_ID(N'dbo.Labs', N'U') IS NULL
BEGIN
    SET @Msg = N'dbo.Labs was not found in "' + DB_NAME() + N'". Are you connected to LRNMaster?';
    RAISERROR(@Msg, 16, 1);
    RETURN;
END

DECLARE @HasIdentity     BIT = CASE WHEN COLUMNPROPERTY(OBJECT_ID(N'dbo.Labs'), 'LabId', 'IsIdentity') = 1 THEN 1 ELSE 0 END;
DECLARE @HasIsActive     BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'IsActive')     IS NULL THEN 0 ELSE 1 END;
DECLARE @HasCreatedBy    BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'CreatedBy')    IS NULL THEN 0 ELSE 1 END;
DECLARE @HasCreatedDate  BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'CreatedDate')  IS NULL THEN 0 ELSE 1 END;
DECLARE @HasModifiedBy   BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'ModifiedBy')   IS NULL THEN 0 ELSE 1 END;
DECLARE @HasModifiedDate BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'ModifiedDate') IS NULL THEN 0 ELSE 1 END;

PRINT N'dbo.Labs: LabId is ' + CASE WHEN @HasIdentity = 1 THEN N'an IDENTITY column' ELSE N'a plain column' END
    + N'; IsActive ' + CASE WHEN @HasIsActive = 1 THEN N'present' ELSE N'ABSENT' END + N'.';

DECLARE @sql NVARCHAR(MAX);

BEGIN TRANSACTION;

BEGIN TRY
    /* ── 1. The lab row ──────────────────────────────────────────────────── */
    DECLARE @ExistingId   INT = (SELECT LabId FROM dbo.Labs WHERE LabName = @DemoLabName);
    DECLARE @IdTakenByLab NVARCHAR(200) = (SELECT LabName FROM dbo.Labs WHERE LabId = @DemoLabId);

    IF @ExistingId IS NOT NULL
    BEGIN
        IF @ExistingId <> @DemoLabId
        BEGIN
            /* Registered under a different id: appsettings would point at the wrong lab.
               Fixing the id here would orphan any data already keyed to it, so stop and
               let a human decide. */
            SET @Msg = N'"' + @DemoLabName + N'" already exists with LabId ' + CAST(@ExistingId AS NVARCHAR(10))
                     + N', but this script and appsettings expect ' + CAST(@DemoLabId AS NVARCHAR(10))
                     + N'. Reconcile them before continuing.';
            THROW 51101, @Msg, 1;
        END

        IF @HasIsActive = 1
        BEGIN
            SET @sql = N'UPDATE dbo.Labs SET IsActive = 1'
                     + CASE WHEN @HasModifiedBy   = 1 THEN N', ModifiedBy = N''system''' ELSE N'' END
                     + CASE WHEN @HasModifiedDate = 1 THEN N', ModifiedDate = SYSUTCDATETIME()' ELSE N'' END
                     + N' WHERE LabId = @Id AND ISNULL(IsActive, 0) = 0;';
            EXEC sp_executesql @sql, N'@Id INT', @Id = @DemoLabId;
        END

        PRINT N'Lab "' + @DemoLabName + N'" already registered as LabId ' + CAST(@DemoLabId AS NVARCHAR(10)) + N'.';
    END
    ELSE IF @IdTakenByLab IS NOT NULL
    BEGIN
        SET @Msg = N'LabId ' + CAST(@DemoLabId AS NVARCHAR(10)) + N' is already used by "' + @IdTakenByLab
                 + N'". Pick a different reserved id and update BOTH appsettings.json files to match.';
        THROW 51102, @Msg, 1;
    END
    ELSE
    BEGIN
        /* Build the INSERT from the columns this server's table actually has.
           IDENTITY_INSERT is only legal when LabId really is an identity - toggling
           it unconditionally is what failed with Msg 8106 before. */
        DECLARE @Cols NVARCHAR(500) = N'LabId, LabName';
        DECLARE @Vals NVARCHAR(500) = N'@Id, @Name';

        IF @HasIsActive    = 1 BEGIN SET @Cols += N', IsActive';    SET @Vals += N', 1'; END
        IF @HasCreatedBy   = 1 BEGIN SET @Cols += N', CreatedBy';   SET @Vals += N', N''system'''; END
        IF @HasCreatedDate = 1 BEGIN SET @Cols += N', CreatedDate'; SET @Vals += N', SYSUTCDATETIME()'; END

        SET @sql = CASE WHEN @HasIdentity = 1 THEN N'SET IDENTITY_INSERT dbo.Labs ON; ' ELSE N'' END
                 + N'INSERT INTO dbo.Labs (' + @Cols + N') VALUES (' + @Vals + N');'
                 + CASE WHEN @HasIdentity = 1 THEN N' SET IDENTITY_INSERT dbo.Labs OFF;' ELSE N'' END;

        EXEC sp_executesql @sql, N'@Id INT, @Name NVARCHAR(200)', @Id = @DemoLabId, @Name = @DemoLabName;

        PRINT N'Registered lab "' + @DemoLabName + N'" as LabId ' + CAST(@DemoLabId AS NVARCHAR(10)) + N'.';
    END

    /* ── 2. Assign the lab to the demo user, if one was named ────────────── */
    IF @DemoUserName IS NOT NULL
    BEGIN
        DECLARE @DemoUserId INT = (SELECT TOP (1) LabUserID FROM dbo.LabUsers WHERE UserName = @DemoUserName ORDER BY LabUserID);

        IF @DemoUserId IS NULL
        BEGIN
            SET @Msg = N'User "' + @DemoUserName + N'" was not found. Create it in Admin > Manage Users first '
                     + N'(so the password is hashed correctly), then re-run.';
            THROW 51103, @Msg, 1;
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.UserLabs WHERE LabUserID = @DemoUserId AND LabId = @DemoLabId)
        BEGIN
            INSERT INTO dbo.UserLabs (LabId, LabUserID) VALUES (@DemoLabId, @DemoUserId);
            PRINT N'Assigned ' + @DemoLabName + N' to user "' + @DemoUserName + N'".';
        END
        ELSE
            PRINT N'User "' + @DemoUserName + N'" already has ' + @DemoLabName + N'.';
    END
    ELSE
        PRINT N'No @DemoUserName set - assign the lab in Admin > Assign User Labs.';

    COMMIT TRANSACTION;
    PRINT N'Demo lab registration committed.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    PRINT N'Demo lab registration rolled back: ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/* ------------------------------------------------------------------- Verify
   Only the two columns every version of dbo.Labs is guaranteed to have, so the
   check itself cannot fail on a schema difference. */
SELECT l.LabId, l.LabName,
       (SELECT COUNT(*) FROM dbo.UserLabs ul WHERE ul.LabId = l.LabId) AS AssignedUsers
FROM dbo.Labs l
WHERE l.LabName = N'LRNLabDemo';

SELECT u.UserName, r.RoleName
FROM dbo.UserLabs ul
JOIN dbo.LabUsers u        ON u.LabUserID = ul.LabUserID
LEFT JOIN dbo.UserRoles ur ON ur.LabUserID = u.LabUserID
LEFT JOIN dbo.Roles r      ON r.RoleID = ur.RoleID
WHERE ul.LabId = 99
ORDER BY u.UserName, r.RoleName;
GO

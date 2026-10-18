-- ============================================================
-- Script  : 07_Create_NotesResponsibleParty_Master.sql
-- Feature : Executive Summary Notes & Insights
-- Purpose : Master table for the "Responsible Party" field so the
--           Notes Add/Edit form drives it from a managed list
--           instead of free text. (Risk is already master-driven
--           by dbo.NotesRiskLevel.)
--             - dbo.NotesResponsibleParty        (master + seed)
--             - usp_NotesResponsibleParty_GetAll (dropdown feed)
--             - usp_NotesResponsibleParty_Upsert (manage master)
--             - usp_NotesResponsibleParty_Delete (soft delete)
-- Run     : After 01-06 scripts. Idempotent.
-- Design  : All access via stored procedures only.
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- dbo.NotesResponsibleParty  (master list of people/teams)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.NotesResponsibleParty', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesResponsibleParty
    (
        ResponsiblePartyId INT           IDENTITY(1,1) NOT NULL,
        PartyName          NVARCHAR(200)               NOT NULL,
        IsActive           BIT                         NOT NULL DEFAULT 1,
        SortOrder          INT                         NOT NULL DEFAULT 0,
        CreatedDateTime    DATETIME                    NOT NULL DEFAULT GETDATE(),

        CONSTRAINT PK_NotesResponsibleParty PRIMARY KEY CLUSTERED (ResponsiblePartyId),
        CONSTRAINT UQ_NotesResponsibleParty_Name UNIQUE (PartyName)
    );
    PRINT 'dbo.NotesResponsibleParty created.';
END
ELSE
    PRINT 'dbo.NotesResponsibleParty already exists - skipped.';
GO

-- Seed common values (idempotent) — matches the reference mockup.
IF NOT EXISTS (SELECT 1 FROM dbo.NotesResponsibleParty)
BEGIN
    INSERT INTO dbo.NotesResponsibleParty (PartyName, SortOrder)
    VALUES ('Billing Team',            1),
           ('AR Manager',              2),
           ('Client Manager',          3),
           ('Payer Follow-up Team',    4),
           ('Operations Team',         5),
           ('Coding Team',             6),
           ('Compliance Team',         7),
           ('Lab Admin',               8);
    PRINT 'dbo.NotesResponsibleParty seeded.';
END
GO

-- ------------------------------------------------------------
-- usp_NotesResponsibleParty_GetAll  (dropdown feed)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesResponsibleParty_GetAll', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesResponsibleParty_GetAll;
GO
CREATE PROCEDURE dbo.usp_NotesResponsibleParty_GetAll
    @IncludeInactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ResponsiblePartyId, PartyName, IsActive, SortOrder
    FROM   dbo.NotesResponsibleParty
    WHERE  (@IncludeInactive = 1 OR IsActive = 1)
    ORDER BY SortOrder, PartyName;
END
GO

-- ------------------------------------------------------------
-- usp_NotesResponsibleParty_Upsert  (add / update a master value)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesResponsibleParty_Upsert', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesResponsibleParty_Upsert;
GO
CREATE PROCEDURE dbo.usp_NotesResponsibleParty_Upsert
    @ResponsiblePartyId INT           = NULL,   -- NULL = insert
    @PartyName          NVARCHAR(200),
    @IsActive           BIT           = 1,
    @SortOrder          INT           = 0,
    @OutId              INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ResponsiblePartyId IS NULL
    BEGIN
        -- reactivate if the name already exists, otherwise insert
        IF EXISTS (SELECT 1 FROM dbo.NotesResponsibleParty WHERE PartyName = @PartyName)
        BEGIN
            UPDATE dbo.NotesResponsibleParty
            SET IsActive = @IsActive, SortOrder = @SortOrder
            WHERE PartyName = @PartyName;
            SET @OutId = (SELECT ResponsiblePartyId FROM dbo.NotesResponsibleParty WHERE PartyName = @PartyName);
        END
        ELSE
        BEGIN
            INSERT INTO dbo.NotesResponsibleParty (PartyName, IsActive, SortOrder)
            VALUES (@PartyName, @IsActive, @SortOrder);
            SET @OutId = SCOPE_IDENTITY();
        END
    END
    ELSE
    BEGIN
        UPDATE dbo.NotesResponsibleParty
        SET PartyName = @PartyName, IsActive = @IsActive, SortOrder = @SortOrder
        WHERE ResponsiblePartyId = @ResponsiblePartyId;
        SET @OutId = @ResponsiblePartyId;
    END
END
GO

-- ------------------------------------------------------------
-- usp_NotesResponsibleParty_Delete  (soft delete)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesResponsibleParty_Delete', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesResponsibleParty_Delete;
GO
CREATE PROCEDURE dbo.usp_NotesResponsibleParty_Delete
    @ResponsiblePartyId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.NotesResponsibleParty SET IsActive = 0 WHERE ResponsiblePartyId = @ResponsiblePartyId;
END
GO

PRINT '== 07_Create_NotesResponsibleParty_Master.sql complete ==';
GO

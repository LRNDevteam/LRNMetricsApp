-- ============================================================
-- Script  : 06_Create_SP_NotesTemplateLibrary.sql
-- Feature : Executive Summary Notes & Insights — Template Library
-- Purpose : Governs report-specific Notes templates (column name,
--           column type Text/Date/Dropdown, dropdown values). The
--           Notes grid and Excel import read column definitions
--           from here rather than allowing ad-hoc Add Column.
--             - usp_NotesTemplate_GetByReport
--             - usp_NotesTemplate_Upsert
--             - usp_NotesTemplateColumn_Upsert
--             - usp_NotesTemplateColumn_Delete
-- Run     : After 01-05 scripts.
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- usp_NotesTemplate_GetByReport
--   Returns the active template header, its columns, and dropdown
--   values for a report (three result sets).
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesTemplate_GetByReport', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesTemplate_GetByReport;
GO
CREATE PROCEDURE dbo.usp_NotesTemplate_GetByReport
    @ReportKeyId INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TemplateId, ReportKeyId, TemplateName, IsActive,
           CreatedBy, CreatedDateTime, LastEditedBy, LastEditedDateTime
    FROM   dbo.NotesTemplate
    WHERE  ReportKeyId = @ReportKeyId AND IsActive = 1;

    SELECT c.ColumnId, c.TemplateId, c.ColumnName, c.ColumnType,
           c.IsRequired, c.SortOrder, c.IsActive
    FROM   dbo.NotesTemplateColumn c
    INNER JOIN dbo.NotesTemplate t ON t.TemplateId = c.TemplateId
    WHERE  t.ReportKeyId = @ReportKeyId AND t.IsActive = 1 AND c.IsActive = 1
    ORDER BY c.SortOrder;

    SELECT v.ColumnValueId, v.ColumnId, v.DropdownValue, v.SortOrder, v.IsActive
    FROM   dbo.NotesTemplateColumnValue v
    INNER JOIN dbo.NotesTemplateColumn c ON c.ColumnId = v.ColumnId
    INNER JOIN dbo.NotesTemplate t ON t.TemplateId = c.TemplateId
    WHERE  t.ReportKeyId = @ReportKeyId AND t.IsActive = 1
       AND c.IsActive = 1 AND v.IsActive = 1
    ORDER BY v.ColumnId, v.SortOrder;
END
GO

-- ------------------------------------------------------------
-- usp_NotesTemplate_Upsert
--   Creates or updates a template header. Returns TemplateId.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesTemplate_Upsert', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesTemplate_Upsert;
GO
CREATE PROCEDURE dbo.usp_NotesTemplate_Upsert
    @TemplateId   INT           = NULL,   -- NULL = insert
    @ReportKeyId  INT,
    @TemplateName NVARCHAR(200),
    @IsActive     BIT           = 1,
    @EditedBy     NVARCHAR(200),
    @OutTemplateId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @TemplateId IS NULL
    BEGIN
        INSERT INTO dbo.NotesTemplate (ReportKeyId, TemplateName, IsActive, CreatedBy, CreatedDateTime)
        VALUES (@ReportKeyId, @TemplateName, @IsActive, @EditedBy, GETDATE());
        SET @OutTemplateId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE dbo.NotesTemplate
        SET TemplateName = @TemplateName,
            IsActive     = @IsActive,
            LastEditedBy = @EditedBy,
            LastEditedDateTime = GETDATE()
        WHERE TemplateId = @TemplateId;
        SET @OutTemplateId = @TemplateId;
    END
END
GO

-- ------------------------------------------------------------
-- usp_NotesTemplateColumn_Upsert
--   Creates or updates a template column and (optionally) replaces
--   its dropdown values from a delimited list. Date-type columns
--   render date pickers; Dropdown-type columns render the values.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesTemplateColumn_Upsert', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesTemplateColumn_Upsert;
GO
CREATE PROCEDURE dbo.usp_NotesTemplateColumn_Upsert
    @ColumnId       INT           = NULL,  -- NULL = insert
    @TemplateId     INT,
    @ColumnName     NVARCHAR(200),
    @ColumnType     NVARCHAR(20),          -- Text / Date / Dropdown
    @IsRequired     BIT           = 0,
    @SortOrder      INT           = 0,
    @DropdownValues NVARCHAR(MAX) = NULL,  -- pipe-delimited when ColumnType = Dropdown
    @OutColumnId    INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ColumnType NOT IN ('Text', 'Date', 'Dropdown')
    BEGIN
        RAISERROR('ColumnType must be Text, Date or Dropdown.', 16, 1);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @ColumnId IS NULL
        BEGIN
            INSERT INTO dbo.NotesTemplateColumn (TemplateId, ColumnName, ColumnType, IsRequired, SortOrder, IsActive)
            VALUES (@TemplateId, @ColumnName, @ColumnType, @IsRequired, @SortOrder, 1);
            SET @OutColumnId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.NotesTemplateColumn
            SET ColumnName = @ColumnName,
                ColumnType = @ColumnType,
                IsRequired = @IsRequired,
                SortOrder  = @SortOrder
            WHERE ColumnId = @ColumnId;
            SET @OutColumnId = @ColumnId;
        END

        -- refresh dropdown values for Dropdown columns
        IF @ColumnType = 'Dropdown'
        BEGIN
            UPDATE dbo.NotesTemplateColumnValue SET IsActive = 0 WHERE ColumnId = @OutColumnId;

            IF @DropdownValues IS NOT NULL AND LTRIM(RTRIM(@DropdownValues)) <> ''
            BEGIN
                ;WITH parsed AS
                (
                    SELECT LTRIM(RTRIM(value)) AS DropdownValue,
                           ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS Ord
                    FROM STRING_SPLIT(@DropdownValues, '|')
                    WHERE LTRIM(RTRIM(value)) <> ''
                )
                INSERT INTO dbo.NotesTemplateColumnValue (ColumnId, DropdownValue, SortOrder, IsActive)
                SELECT @OutColumnId, DropdownValue, Ord, 1 FROM parsed;
            END
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ------------------------------------------------------------
-- usp_NotesTemplateColumn_Delete
--   Soft-deactivates a template column and its dropdown values.
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.usp_NotesTemplateColumn_Delete', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_NotesTemplateColumn_Delete;
GO
CREATE PROCEDURE dbo.usp_NotesTemplateColumn_Delete
    @ColumnId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE dbo.NotesTemplateColumnValue SET IsActive = 0 WHERE ColumnId = @ColumnId;
        UPDATE dbo.NotesTemplateColumn      SET IsActive = 0 WHERE ColumnId = @ColumnId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

PRINT '== 06_Create_SP_NotesTemplateLibrary.sql complete ==';
GO

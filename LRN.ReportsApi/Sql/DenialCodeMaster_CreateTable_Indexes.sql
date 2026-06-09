/* Denial Code Master - AR Manager only workflow master table */
IF OBJECT_ID('dbo.DenialCodeMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DenialCodeMaster
    (
        DenialCode nvarchar(100) NOT NULL,
        DenialDescription nvarchar(1000) NULL,
        DenialClassification nvarchar(255) NULL,
        CoverageStatus nvarchar(255) NOT NULL,
        ICDComplianceStatus nvarchar(255) NOT NULL,
        DenialValidity nvarchar(255) NULL,
        ActionCode nvarchar(100) NULL,
        RecommendedAction nvarchar(1000) NULL,
        ActionCategory nvarchar(255) NULL,
        Task nvarchar(500) NULL,
        ShortCategory nvarchar(255) NULL,
        Priority nvarchar(100) NULL,
        SLADays nvarchar(100) NULL,
        NotesComments nvarchar(2000) NULL,
        CreatedOn datetime2 NOT NULL CONSTRAINT DF_DenialCodeMaster_CreatedOn DEFAULT SYSUTCDATETIME(),
        CreatedBy nvarchar(100) NULL,
        UpdatedOn datetime2 NULL,
        UpdatedBy nvarchar(100) NULL,
        CONSTRAINT PK_DenialCodeMaster PRIMARY KEY CLUSTERED (DenialCode, CoverageStatus, ICDComplianceStatus)
    );
END;
GO

IF OBJECT_ID('dbo.DenialCodeMaster', 'U') IS NOT NULL
   AND EXISTS (
       SELECT 1
       FROM sys.columns c
       JOIN sys.types t ON c.user_type_id = t.user_type_id
       WHERE c.object_id = OBJECT_ID('dbo.DenialCodeMaster')
         AND c.name = 'SLADays'
         AND t.name <> 'nvarchar'
   )
BEGIN
    ALTER TABLE dbo.DenialCodeMaster ALTER COLUMN SLADays nvarchar(100) NULL;
END;
GO

IF OBJECT_ID('dbo.DenialCodeMaster', 'U') IS NOT NULL
BEGIN
    UPDATE dbo.DenialCodeMaster
    SET CoverageStatus = N''
    WHERE CoverageStatus IS NULL;

    UPDATE dbo.DenialCodeMaster
    SET ICDComplianceStatus = N''
    WHERE ICDComplianceStatus IS NULL;

    ;WITH DuplicateKeys AS
    (
        SELECT *,
               ROW_NUMBER() OVER
               (
                   PARTITION BY DenialCode, CoverageStatus, ICDComplianceStatus
                   ORDER BY COALESCE(UpdatedOn, CreatedOn) DESC, CreatedOn DESC
               ) AS RowNumber
        FROM dbo.DenialCodeMaster
    )
    DELETE FROM DuplicateKeys
    WHERE RowNumber > 1;

    ALTER TABLE dbo.DenialCodeMaster ALTER COLUMN CoverageStatus nvarchar(255) NOT NULL;
    ALTER TABLE dbo.DenialCodeMaster ALTER COLUMN ICDComplianceStatus nvarchar(255) NOT NULL;
END;
GO

IF OBJECT_ID('dbo.DenialCodeMaster', 'U') IS NOT NULL
BEGIN
    DECLARE @ExistingPrimaryKey sysname;

    SELECT @ExistingPrimaryKey = kc.name
    FROM sys.key_constraints kc
    WHERE kc.parent_object_id = OBJECT_ID('dbo.DenialCodeMaster')
      AND kc.[type] = 'PK';

    IF @ExistingPrimaryKey IS NOT NULL
    BEGIN
        DECLARE @DropPrimaryKeySql nvarchar(max) = N'ALTER TABLE dbo.DenialCodeMaster DROP CONSTRAINT ' + QUOTENAME(@ExistingPrimaryKey) + N';';
        EXEC sp_executesql @DropPrimaryKeySql;
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM sys.key_constraints kc
        JOIN sys.index_columns ic1 ON ic1.object_id = kc.parent_object_id AND ic1.index_id = kc.unique_index_id AND ic1.key_ordinal = 1
        JOIN sys.columns c1 ON c1.object_id = ic1.object_id AND c1.column_id = ic1.column_id
        JOIN sys.index_columns ic2 ON ic2.object_id = kc.parent_object_id AND ic2.index_id = kc.unique_index_id AND ic2.key_ordinal = 2
        JOIN sys.columns c2 ON c2.object_id = ic2.object_id AND c2.column_id = ic2.column_id
        JOIN sys.index_columns ic3 ON ic3.object_id = kc.parent_object_id AND ic3.index_id = kc.unique_index_id AND ic3.key_ordinal = 3
        JOIN sys.columns c3 ON c3.object_id = ic3.object_id AND c3.column_id = ic3.column_id
        WHERE kc.parent_object_id = OBJECT_ID('dbo.DenialCodeMaster')
          AND kc.[type] = 'PK'
          AND c1.name = 'DenialCode'
          AND c2.name = 'CoverageStatus'
          AND c3.name = 'ICDComplianceStatus'
    )
    BEGIN
        ALTER TABLE dbo.DenialCodeMaster
        ADD CONSTRAINT PK_DenialCodeMaster PRIMARY KEY CLUSTERED (DenialCode, CoverageStatus, ICDComplianceStatus);
    END;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialCodeMaster_Classification' AND object_id = OBJECT_ID('dbo.DenialCodeMaster'))
    CREATE NONCLUSTERED INDEX IX_DenialCodeMaster_Classification
    ON dbo.DenialCodeMaster (DenialClassification, CoverageStatus)
    INCLUDE (ActionCode, ActionCategory, Priority, SLADays);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialCodeMaster_Action' AND object_id = OBJECT_ID('dbo.DenialCodeMaster'))
    CREATE NONCLUSTERED INDEX IX_DenialCodeMaster_Action
    ON dbo.DenialCodeMaster (ActionCode, ActionCategory)
    INCLUDE (DenialClassification, CoverageStatus, Task);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialCodeMaster_Lookups' AND object_id = OBJECT_ID('dbo.DenialCodeMaster'))
    CREATE NONCLUSTERED INDEX IX_DenialCodeMaster_Lookups
    ON dbo.DenialCodeMaster (DenialValidity, ICDComplianceStatus, Task)
    INCLUDE (DenialClassification, CoverageStatus, ActionCode, ActionCategory);
GO

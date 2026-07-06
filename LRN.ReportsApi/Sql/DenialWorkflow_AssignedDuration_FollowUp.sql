/* Run once in each lab denial database. Safe to rerun. */
IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard','AssignedOn') IS NULL
        ALTER TABLE dbo.DenialTaskBoard ADD AssignedOn datetime2 NULL;

    /* Defer compilation until after ALTER TABLE has added AssignedOn. */
    EXEC sys.sp_executesql N'
        UPDATE dbo.DenialTaskBoard
        SET AssignedOn=COALESCE(ReviewerUpdatedOn,CreatedOn,SYSDATETIME())
        WHERE NULLIF(LTRIM(RTRIM(ISNULL(AssignedTo,''''))),'''') IS NOT NULL
          AND AssignedOn IS NULL;';

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.DenialTaskBoard') AND name='IX_DenialTaskBoard_AssignedOn')
        EXEC sys.sp_executesql N'
            CREATE INDEX IX_DenialTaskBoard_AssignedOn
            ON dbo.DenialTaskBoard(AssignedOn,AssignedTo)
            INCLUDE(ClaimID,TaskID,CPTCode,Status);';
END;

IF OBJECT_ID('dbo.DenialClaimNotes','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialClaimNotes','FollowUpReason') IS NULL
        ALTER TABLE dbo.DenialClaimNotes ADD FollowUpReason nvarchar(250) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.DenialClaimNotes') AND name='IX_DenialClaimNotes_FollowUpNotification')
        EXEC sys.sp_executesql N'
            CREATE INDEX IX_DenialClaimNotes_FollowUpNotification
            ON dbo.DenialClaimNotes(LabId,NextFollowUpDate,IsDeleted)
            INCLUDE(ClaimId,TaskId,CptCode,Status,FollowUpReason,CreatedOn);';
END;

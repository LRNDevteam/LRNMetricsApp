/* =============================================================================
   NorthWest - ClaimLevelData.BilledUnbilled
   File     : 40_NW_ClaimLevelData_BilledUnbilled.sql
   Database : NWL_LRN

   BilledUnbilled (NVARCHAR(250) NULL):
     1. FirstBilledDate is a date                                   -> 'Billed'
     2. FirstBilledDate blank and EmedixSubmissionDate is a date    -> 'Billed'
     3. FirstBilledDate blank and EmedixSubmissionDate blank        -> 'UnBilled'
     ClaimType does not affect the value. Any other value (non-date text) is UnBilled.
     Stored text stays 'UnBilled' so existing filters keep matching.

   DeniedStatus (NVARCHAR(500) NULL), set by the same procedure:
     'Denied' when DenialCodeNormalized has a code AND InsuranceBalance > 0
              AND ClaimStatus IN ('Fully Denied','Partially Denied','Partially Paid' / 'Partial Paid');
     otherwise NULL.

   dbo.usp_UpdateNW_ClaimLevelData_BilledUnbilled recalculates every row and
   writes only rows whose value changed, so FirstBilledDate / EmedixSubmissionDate
   updated by a later file are picked up. ClaimLineCSVDataCapture runs it as the
   first step after a new NorthWest RunId. Every run (success or failure) is
   written to dbo.NW_BilledUnbilled_UpdateLog.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'40_NW_ClaimLevelData_BilledUnbilled.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'BilledUnbilled') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD BilledUnbilled NVARCHAR(250) NULL;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'DeniedStatus') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD DeniedStatus NVARCHAR(500) NULL;
GO

IF OBJECT_ID(N'dbo.NW_BilledUnbilled_UpdateLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.NW_BilledUnbilled_UpdateLog
    (
        LogId              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_NW_BilledUnbilled_UpdateLog PRIMARY KEY,
        RunId              NVARCHAR(500)     NULL,
        TriggeredBy        NVARCHAR(100)     NOT NULL,
        StartedAt          DATETIME2(0)      NOT NULL,
        EndedAt            DATETIME2(0)      NULL,
        DurationMs         INT               NULL,
        Status             VARCHAR(20)       NOT NULL,   -- Running / Success / Failed
        TotalRows          INT               NULL,
        BilledFirstBilled  INT               NULL,       -- condition 1
        BilledEmedix       INT               NULL,       -- condition 2
        UnBilledBlank      INT               NULL,       -- condition 3
        UnBilledOther      INT               NULL,       -- non-date text
        RowsUpdated        INT               NULL,
        ErrorMessage       NVARCHAR(4000)    NULL
    );
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UpdateNW_ClaimLevelData_BilledUnbilled
    @RunId       NVARCHAR(500) = NULL,
    @TriggeredBy NVARCHAR(100) = N'Manual'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Started DATETIME2(3) = SYSDATETIME();
    DECLARE @LogId INT;
    DECLARE @Updated INT = 0;

    INSERT INTO dbo.NW_BilledUnbilled_UpdateLog (RunId, TriggeredBy, StartedAt, Status)
    VALUES (@RunId, ISNULL(NULLIF(LTRIM(RTRIM(@TriggeredBy)), N''), N'Manual'), @Started, 'Running');
    SET @LogId = SCOPE_IDENTITY();

    BEGIN TRY
        ;WITH Src AS
        (
            SELECT
                cl.BilledUnbilled,
                NewValue = CASE
                    WHEN d.FirstBilled IS NOT NULL
                        THEN N'Billed'
                    WHEN d.FirstBilled IS NULL AND d.Emedix IS NOT NULL
                        THEN N'Billed'
                    ELSE N'UnBilled'
                END
            FROM dbo.ClaimLevelData cl
            CROSS APPLY (SELECT
                FirstRaw = NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), N''),
                EmedixRaw = NULLIF(LTRIM(RTRIM(cl.EmedixSubmissionDate)), N'')) r
            CROSS APPLY (SELECT
                FirstBilled = TRY_CAST(r.FirstRaw AS DATE),
                Emedix      = TRY_CAST(r.EmedixRaw AS DATE)) d
        )
        UPDATE Src
        SET    BilledUnbilled = NewValue
        WHERE  BilledUnbilled IS NULL OR BilledUnbilled <> NewValue;

        SET @Updated = @@ROWCOUNT;

        ;WITH Den AS
        (
            SELECT
                cl.DeniedStatus,
                NewValue = CASE
                    WHEN NULLIF(LTRIM(RTRIM(cl.DenialCodeNormalized)), N'') IS NOT NULL
                     AND TRY_CAST(cl.InsuranceBalance AS DECIMAL(18,2)) > 0
                     AND LTRIM(RTRIM(cl.ClaimStatus)) IN (N'Fully Denied', N'Partially Denied',
                                                          N'Partially Paid', N'Partial Paid')
                        THEN N'Denied'
                END
            FROM dbo.ClaimLevelData cl
        )
        UPDATE Den
        SET    DeniedStatus = NewValue
        WHERE  ISNULL(DeniedStatus, N'') <> ISNULL(NewValue, N'');

        DECLARE @Total INT, @B1 INT, @B2 INT, @U3 INT, @UX INT;
        SELECT
            @Total = COUNT(*),
            @B1 = SUM(CASE WHEN d.FirstBilled IS NOT NULL THEN 1 ELSE 0 END),
            @B2 = SUM(CASE WHEN d.FirstBilled IS NULL AND d.Emedix IS NOT NULL THEN 1 ELSE 0 END),
            @U3 = SUM(CASE WHEN r.FirstRaw IS NULL AND r.EmedixRaw IS NULL THEN 1 ELSE 0 END)
        FROM dbo.ClaimLevelData cl
        CROSS APPLY (SELECT
            FirstRaw = NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), N''),
            EmedixRaw = NULLIF(LTRIM(RTRIM(cl.EmedixSubmissionDate)), N'')) r
        CROSS APPLY (SELECT
            FirstBilled = TRY_CAST(r.FirstRaw AS DATE),
            Emedix      = TRY_CAST(r.EmedixRaw AS DATE)) d;
        SET @UX = @Total - ISNULL(@B1, 0) - ISNULL(@B2, 0) - ISNULL(@U3, 0);

        UPDATE dbo.NW_BilledUnbilled_UpdateLog
        SET    EndedAt           = SYSDATETIME(),
               DurationMs        = DATEDIFF(MILLISECOND, @Started, SYSDATETIME()),
               Status            = 'Success',
               TotalRows         = @Total,
               BilledFirstBilled = ISNULL(@B1, 0),
               BilledEmedix      = ISNULL(@B2, 0),
               UnBilledBlank     = ISNULL(@U3, 0),
               UnBilledOther     = @UX,
               RowsUpdated       = @Updated
        WHERE  LogId = @LogId;

        SELECT LogId = @LogId, TotalRows = @Total, BilledFirstBilled = ISNULL(@B1, 0),
               BilledEmedix = ISNULL(@B2, 0), UnBilledBlank = ISNULL(@U3, 0),
               UnBilledOther = @UX, RowsUpdated = @Updated,
               DurationMs = DATEDIFF(MILLISECOND, @Started, SYSDATETIME());
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        UPDATE dbo.NW_BilledUnbilled_UpdateLog
        SET    EndedAt      = SYSDATETIME(),
               DurationMs   = DATEDIFF(MILLISECOND, @Started, SYSDATETIME()),
               Status       = 'Failed',
               RowsUpdated  = 0,
               ErrorMessage = LEFT(ERROR_MESSAGE(), 4000)
        WHERE  LogId = @LogId;

        THROW;
    END CATCH;
END;
GO

EXEC dbo.usp_UpdateNW_ClaimLevelData_BilledUnbilled @TriggeredBy = N'40_NW_ClaimLevelData_BilledUnbilled.sql';
GO

PRINT '40_NW_ClaimLevelData_BilledUnbilled.sql completed.';
GO

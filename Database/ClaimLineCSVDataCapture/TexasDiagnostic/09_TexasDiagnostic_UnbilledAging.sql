/* =============================================================================
   TexasDiagnostic - Unbilled X Aging
   Database : TexasDiagnostic        Requires : 05_TexasDiagnostic_ProductionBase.sql

   Filter  : ClaimStatus = Unbilled
   Rows    : PayerName_Raw
   Columns : Aging (AgingDOS when Aging is blank - Aging is empty on the current file)
   Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract: PayerName, AgingBucket, ClaimCount, TotalCharges
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
	RAISERROR('Run 09_TexasDiagnostic_UnbilledAging.sql on the TexasDiagnostic database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.TD_UnbilledAging', N'U') IS NULL
CREATE TABLE dbo.TD_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    AgingBucket  NVARCHAR(100)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetTD_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL,
    @ForceLive       BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @ForceLive = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo) IS NULL
    BEGIN
        SELECT PayerName, AgingBucket, ClaimCount, TotalCharges
        FROM   dbo.TD_UnbilledAging
        ORDER  BY SUM(ClaimCount) OVER (PARTITION BY PayerName) DESC, PayerName, AgingBucket;
        RETURN;
    END;

    SELECT CAST(PayerName AS NVARCHAR(500)) AS PayerName,
           CAST(Aging     AS NVARCHAR(100)) AS AgingBucket,
           COUNT(DISTINCT ClaimID)          AS ClaimCount,
           SUM(ChargeAmount)                AS TotalCharges
    FROM   dbo.fn_TD_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsUnbilled = 1
    GROUP  BY PayerName, Aging
    ORDER  BY SUM(COUNT(DISTINCT ClaimID)) OVER (PARTITION BY PayerName) DESC, PayerName, AgingBucket;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PayerName NVARCHAR(500), AgingBucket NVARCHAR(100), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetTD_UnbilledAging @ForceLive = 1;

    TRUNCATE TABLE dbo.TD_UnbilledAging;

    INSERT INTO dbo.TD_UnbilledAging (PayerName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshTD_UnbilledAging completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshTD_UnbilledAging;
GO

PRINT '09_TexasDiagnostic_UnbilledAging.sql completed.';
GO

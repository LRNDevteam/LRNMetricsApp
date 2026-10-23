/* =============================================================================
   CoreBio - Unbilled X Aging
   Database : CoreBio        Requires : 05_CoreBio_ProductionBase.sql

   Filter  : BilledStatus = Unbilled
   Rows    : PayerName_Raw
   Columns : AgingDOS (Current / 30+ / 60+ / 90+ / 120+). The Aging column is empty.
   Values  : COUNT(DISTINCT ClaimID), SUM(ChargeAmount); sorted by claim count

   Result contract: PayerName, AgingBucket, ClaimCount, TotalCharges
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'CoreBio'
BEGIN
	RAISERROR('Run 09_CoreBio_UnbilledAging.sql on the CoreBio database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.CB_UnbilledAging', N'U') IS NULL
CREATE TABLE dbo.CB_UnbilledAging
(
    SummaryId    INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PayerName    NVARCHAR(500)   NOT NULL,
    AgingBucket  NVARCHAR(100)   NOT NULL,
    ClaimCount   INT             NOT NULL DEFAULT 0,
    TotalCharges DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt  DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCB_UnbilledAging
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
        FROM   dbo.CB_UnbilledAging
        ORDER  BY SUM(ClaimCount) OVER (PARTITION BY PayerName) DESC, PayerName, AgingBucket;
        RETURN;
    END;

    SELECT CAST(PayerName AS NVARCHAR(500)) AS PayerName,
           CAST(AgingDOS  AS NVARCHAR(100)) AS AgingBucket,
           COUNT(DISTINCT ClaimID)          AS ClaimCount,
           SUM(ChargeAmount)                AS TotalCharges
    FROM   dbo.fn_CB_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                       @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  IsUnbilled = 1
    GROUP  BY PayerName, AgingDOS
    ORDER  BY SUM(COUNT(DISTINCT ClaimID)) OVER (PARTITION BY PayerName) DESC, PayerName, AgingBucket;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCB_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Rows TABLE (PayerName NVARCHAR(500), AgingBucket NVARCHAR(100), ClaimCount INT, TotalCharges DECIMAL(18,2));

    INSERT INTO @Rows
    EXEC dbo.usp_GetCB_UnbilledAging @ForceLive = 1;

    TRUNCATE TABLE dbo.CB_UnbilledAging;

    INSERT INTO dbo.CB_UnbilledAging (PayerName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT PayerName, AgingBucket, ClaimCount, TotalCharges, GETDATE()
    FROM   @Rows;

    PRINT 'usp_RefreshCB_UnbilledAging completed - ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshCB_UnbilledAging;
GO

PRINT '09_CoreBio_UnbilledAging.sql completed.';
GO

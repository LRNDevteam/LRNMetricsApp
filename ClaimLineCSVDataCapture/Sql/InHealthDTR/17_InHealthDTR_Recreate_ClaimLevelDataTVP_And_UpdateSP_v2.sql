SET NOCOUNT ON;
GO

PRINT 'Dropping stored procedure dbo.usp_BulkInsertClaimLevelData if it exists...';
IF OBJECT_ID('dbo.usp_BulkInsertClaimLevelData', 'P') IS NOT NULL
BEGIN
	DROP PROCEDURE dbo.usp_BulkInsertClaimLevelData;
END
GO

PRINT 'Dropping type dbo.ClaimLevelDataTVP if it exists...';
IF TYPE_ID('dbo.ClaimLevelDataTVP') IS NOT NULL
BEGIN
	DROP TYPE dbo.ClaimLevelDataTVP;
END
GO

PRINT 'Creating type dbo.ClaimLevelDataTVP (InHealthDTR v2)...';
-- Column order MUST match the field order in InHealthDTRFieldMappings.json ClaimLevel > Fields.
-- System columns (FileLogId..RowHash) are always first; then all mapped SQL columns in JSON order.
-- v2 adds: PanelNameLIS, PanelNameBasedOnCPT, TotalWO, BillStatus, AgingDOS, AgingDOE,
--          ResponsibleParty, SubscriberID, ClientAccNum, EndDOS, DODWeek, CheckNumber,
--          LineLevelICD, Facility.
CREATE TYPE dbo.ClaimLevelDataTVP AS TABLE
(
	-- System columns (injected by the application)
	FileLogId                        NVARCHAR(500),
	RunId                            NVARCHAR(500),
	WeekFolder                       NVARCHAR(500),
	SourceFullPath                   NVARCHAR(1000),
	FileName                         NVARCHAR(500),
	FileType                         NVARCHAR(100),
	RowHash                          NVARCHAR(64),

	-- CSV-mapped columns (in InHealthDTRFieldMappings.json ClaimLevel field order)
	LabID                            NVARCHAR(500),
	LabName                          NVARCHAR(500),
	ClaimID                          NVARCHAR(500),
	AccessionNumber                  NVARCHAR(500),
	SourceFileID                     NVARCHAR(1000),
	IngestedOn                       NVARCHAR(500),
	CsvRowHash                       NVARCHAR(500),
	PayerName_Raw                    NVARCHAR(500),
	PayerName                        NVARCHAR(500),
	Payer_Code                       NVARCHAR(500),
	Payer_Common_Code                NVARCHAR(500),
	Payer_Group_Code                 NVARCHAR(500),
	Global_Payer_ID                  NVARCHAR(500),
	PayerType                        NVARCHAR(500),
	BillingProvider                  NVARCHAR(500),
	ReferringProvider                NVARCHAR(500),
	ClinicName                       NVARCHAR(500),
	SalesRepname                     NVARCHAR(500),
	PatientID                        NVARCHAR(500),
	PatientDOB                       NVARCHAR(500),
	DateofService                    NVARCHAR(500),
	ChargeEnteredDate                NVARCHAR(500),
	FirstBilledDate                  NVARCHAR(500),
	Panelname                        NVARCHAR(500),
	PanelNameLIS                     NVARCHAR(500),
	PanelNameBasedOnCPT              NVARCHAR(500),
	CPTCodeXUnitsXModifierOrginal    NVARCHAR(MAX),
	CPTCodeXUnitsXModifier           NVARCHAR(MAX),
	POS                              NVARCHAR(500),
	TOS                              NVARCHAR(500),
	ChargeAmount                     NVARCHAR(500),
	AllowedAmount                    NVARCHAR(500),
	InsurancePayment                 NVARCHAR(500),
	PatientPayment                   NVARCHAR(500),
	TotalPayments                    NVARCHAR(500),
	InsuranceAdjustments             NVARCHAR(500),
	PatientAdjustments               NVARCHAR(500),
	TotalAdjustments                 NVARCHAR(500),
	InsuranceBalance                 NVARCHAR(500),
	PatientBalance                   NVARCHAR(500),
	TotalBalance                     NVARCHAR(500),
	TotalWO                          NVARCHAR(500),
	CheckDate                        NVARCHAR(500),
	ClaimStatus                      NVARCHAR(500),
	DenialCode                       NVARCHAR(MAX),
	ICDCode                          NVARCHAR(500),
	DaystoDOS                        NVARCHAR(500),
	RollingDays                      NVARCHAR(500),
	DaystoBill                       NVARCHAR(500),
	DaystoPost                       NVARCHAR(500),
	ICDPointer                       NVARCHAR(500),
	PatientName                      NVARCHAR(1000),
	BillStatus                       NVARCHAR(200),
	Modifier                         NVARCHAR(500),
	PaymentPercent                   NVARCHAR(100),
	AgingDOS                         NVARCHAR(100),
	BilledWeek                       NVARCHAR(500),
	PostedWeek                       NVARCHAR(500),
	FullyPaidCount                   NVARCHAR(500),
	FullyPaidAmount                  NVARCHAR(500),
	AdjudicatedCount                 NVARCHAR(500),
	AdjudicatedAmount                NVARCHAR(500),
	Days30Count                      NVARCHAR(500),
	Days30Amount                     NVARCHAR(500),
	Days60Count                      NVARCHAR(500),
	Days60Amount                     NVARCHAR(500),
	ResponsibleParty                 NVARCHAR(500),
	SubscriberID                     NVARCHAR(500),
	ClientAccNum                     NVARCHAR(500),
	EndDOS                           NVARCHAR(500),
	DODWeek                          NVARCHAR(500),
	CheckNumber                      NVARCHAR(500),
	LineLevelICD                     NVARCHAR(MAX),
	AgingDOE                         NVARCHAR(100),
	Facility                         NVARCHAR(500)
);
GO

CREATE PROCEDURE dbo.usp_BulkInsertClaimLevelData
	@Rows                dbo.ClaimLevelDataTVP READONLY,
	@LabName             NVARCHAR(500),
	@WeekFolder          NVARCHAR(500),
	@SourceFilePath      NVARCHAR(1000),
	@RunId               NVARCHAR(500),
	@FileName            NVARCHAR(500),
	@FileCreatedDateTime DATETIME = NULL,
	@ChunkSize           INT = 5000
AS
BEGIN
	SET NOCOUNT ON;

	IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'claimlevel')
	BEGIN
		SELECT 0 AS InsertedCount;
		RETURN;
	END

	DECLARE @FileLogId INT;

	INSERT INTO dbo.LineClaimFileLogs
		(RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
	VALUES
		(@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'claimlevel', @FileCreatedDateTime);

	SET @FileLogId = SCOPE_IDENTITY();

	-- Full replacement load
	IF EXISTS (SELECT 1 FROM dbo.ClaimLevelData)
	BEGIN
		DELETE FROM dbo.ClaimLevelData;
	END

	DECLARE @InsertOffset INT = 0;
	DECLARE @InsertBatch  INT = 1;

	WHILE @InsertBatch > 0
	BEGIN
		INSERT INTO dbo.ClaimLevelData
		(
			FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
			LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
			PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
			BillingProvider, ReferringProvider, ClinicName, SalesRepname,
			PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
			Panelname, PanelNameLIS, PanelNameBasedOnCPT,
			CPTCodeXUnitsXModifierOrginal, CPTCodeXUnitsXModifier, POS, TOS,
			ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
			InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
			InsuranceBalance, PatientBalance, TotalBalance, TotalWO,
			CheckDate, ClaimStatus, DenialCode, ICDCode,
			DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
			PatientName, BillStatus, Modifier, PaymentPercent,
			AgingDOS, BilledWeek, PostedWeek,
			FullyPaidCount, FullyPaidAmount, AdjudicatedCount, AdjudicatedAmount,
			Days30Count, Days30Amount, Days60Count, Days60Amount,
			ResponsibleParty, SubscriberID, ClientAccNum, EndDOS, DODWeek, CheckNumber,
			LineLevelICD, AgingDOE, Facility
		)
		SELECT
			CAST(@FileLogId AS NVARCHAR(500)), RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
			LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
			PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
			BillingProvider, ReferringProvider, ClinicName, SalesRepname,
			PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
			Panelname, PanelNameLIS, PanelNameBasedOnCPT,
			CPTCodeXUnitsXModifierOrginal, CPTCodeXUnitsXModifier, POS, TOS,
			ChargeAmount, AllowedAmount, InsurancePayment, PatientPayment, TotalPayments,
			InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
			InsuranceBalance, PatientBalance, TotalBalance, TotalWO,
			CheckDate, ClaimStatus, DenialCode, ICDCode,
			DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
			PatientName, BillStatus, Modifier, PaymentPercent,
			AgingDOS, BilledWeek, PostedWeek,
			FullyPaidCount, FullyPaidAmount, AdjudicatedCount, AdjudicatedAmount,
			Days30Count, Days30Amount, Days60Count, Days60Amount,
			ResponsibleParty, SubscriberID, ClientAccNum, EndDOS, DODWeek, CheckNumber,
			LineLevelICD, AgingDOE, Facility
		FROM @Rows
		ORDER BY (SELECT NULL)
		OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

		SET @InsertBatch  = @@ROWCOUNT;
		SET @InsertOffset = @InsertOffset + @ChunkSize;
	END

	SELECT @InsertOffset AS InsertedCount;
END;
GO

PRINT 'InHealthDTR ClaimLevel TVP/SP recreate script (v2) completed.';

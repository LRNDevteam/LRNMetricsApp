IF OBJECT_ID('dbo.LabMedians', 'U') IS NULL
BEGIN
	CREATE TABLE LabMedians
	(
		PayerName NVARCHAR(250) NULL,
		PanelName NVARCHAR(250) NULL,
		CPTCode NVARCHAR(50) NULL,
		AllowedAmount DECIMAL(18,2) DEFAULT(0.0),
		InsurancePayment DECIMAL(18,2) DEFAULT(0.0),
		DistinctAllowedPaymentCount INT,
		MedianAllowedAmount DECIMAL(18,2) DEFAULT(0.0),
		MedianInsurancePaymentAmount DECIMAL(18,2) DEFAULT(0.0),
		AllowedAmountPerUnitMedian DECIMAL(18,2) DEFAULT(0.0),
		InsurancePaymentPerUnitMedian DECIMAL(18,2) DEFAULT(0.0),
		LabName NVARCHAR(50) NOT NULL,
		LabId INT NOT NULL,
		RunID NVARCHAR(50),
		CreatedOn DATETIME DEFAULT(GETDATE()),
		RollingDays NVARCHAR(20) NULL,
		MinDateofService DATE NULL,
		MaxDateofService DATE NULL,
		AsOfDate DATE NULL
	);
END
GO

IF OBJECT_ID('dbo.LabModes', 'U') IS NULL
BEGIN
	CREATE TABLE LabModes
	(
		PayerName NVARCHAR(250) NULL,
		PanelName NVARCHAR(250) NULL,
		CPTCode NVARCHAR(50) NULL,
		AllowedAmount DECIMAL(18,2) DEFAULT(0.0),
		InsurancePayment DECIMAL(18,2) DEFAULT(0.0),
		DistinctAllowedPaymentCount INT,
		ModeAllowedAmount DECIMAL(18,2) DEFAULT(0.0),
		ModeInsurancePaymentAmount DECIMAL(18,2) DEFAULT(0.0),
		AllowedAmountPerUnitMode DECIMAL(18,2) DEFAULT(0.0),
		InsurancePaymentPerUnitMode DECIMAL(18,2) DEFAULT(0.0),
		LabName NVARCHAR(50) NOT NULL,
		LabId INT NOT NULL,
		RunID NVARCHAR(50),
		CreatedOn DATETIME DEFAULT(GETDATE()),
		RollingDays NVARCHAR(20) NULL,
		MinDateofService DATE NULL,
		MaxDateofService DATE NULL,
		AsOfDate DATE NULL
	);
END
GO

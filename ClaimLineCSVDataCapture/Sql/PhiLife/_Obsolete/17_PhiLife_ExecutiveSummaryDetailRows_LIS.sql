-- ============================================================
-- PhiLife – Executive Summary LIS Detail-Rows SP
-- File : 17_PhiLife_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : PhiLife_LRN
--
-- Returns the underlying ClaimLevelData rows that drive a given
-- LIS RowCode from the Executive Summary (Total, A, A.<Panelname>,
-- A1-A8 incl. sub-rows, B, B1-B5 incl. sub-rows).
--
-- PhiLife has no dbo.LIMSMaster table, so (unlike PCRLOA's LIS detail
-- SP) this is sourced directly from dbo.ClaimLevelData using the same
-- #Base shape/IsResulted computation as 15/16.
--
-- @Year/@Month: 0 = all years / all months (matches grand-total period)
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_ExecutiveSummaryDetail_LIS
(
    @RowCode NVARCHAR(20),
    @Year    INT = 0,
    @Month   INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    -- Dynamic 'A.<Panelname>' sub-rows: extract the panel name after 'A.'
    DECLARE @PanelFilter NVARCHAR(300) = NULL;
    IF @RowCode LIKE 'A.%'
        SET @PanelFilter = SUBSTRING(@RowCode, 3, 300);

    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        PatientName,
        PayerName,
        ISNULL(Panelname, '')                   AS Panelname,
        ClinicName,
        BillingProvider,
        DateofService,
        FirstBilledDate,
        ISNULL(BilledUnbilled, '')               AS BilledUnbilled,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')    AS ClaimStatus,
        ISNULL(PayerType,  '')                   AS PayerType,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
        CASE
            WHEN FirstBilledDate IS NOT NULL THEN 1
            WHEN ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> '' THEN 1
            ELSE 0
        END AS IsResulted
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND (@Year=0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
      AND (@Month=0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);

    SELECT
        b.AccessionNumber AS VisitNumber,
        b.PatientName,
        b.PayerName,
        b.Panelname        AS PanelName,
        b.ClinicName,
        b.BillingProvider,
        b.DateofService,
        b.FirstBilledDate,
        b.BilledUnbilled,
        b.ClaimStatus,
        b.PayerType,
        b.ChargeAmount,
        b.InsurancePayment,
        b.PatientPayment,
        b.InsuranceBalance,
        b.PatientBalance,
        b.IsResulted        AS ResultedNot
    FROM #Base b
    WHERE
           (@RowCode = 'Total')
        OR (@RowCode = 'A'    AND b.IsResulted = 1)
        OR (@PanelFilter IS NOT NULL AND b.IsResulted = 1 AND LTRIM(RTRIM(b.Panelname)) = @PanelFilter COLLATE DATABASE_DEFAULT)
        OR (@RowCode = 'A1'   AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed' AND b.BilledUnbilled = 'Billed')
        OR (@RowCode = 'A1.1' AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed' AND b.BilledUnbilled = 'Billed')
        OR (@RowCode = 'A2'   AND b.IsResulted = 1 AND b.ClaimStatus = 'Not Entered in AMD' AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance')
        OR (@RowCode = 'A2.1' AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD'))
        OR (@RowCode = 'A2.2' AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Billing Review Required')
        OR (@RowCode = 'A2.3' AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Collected')
        OR (@RowCode = 'A3'   AND b.IsResulted = 1 AND b.BilledUnbilled = 'Unbilled' AND b.ClaimStatus = 'Entered')
        OR (@RowCode = 'A4'   AND b.IsResulted = 1 AND b.PayerType = 'Client Bill')
        OR (@RowCode = 'A4.1' AND b.IsResulted = 1 AND b.PayerType = 'Client Bill' AND b.ClaimStatus = 'Not Entered in AMD')
        OR (@RowCode = 'A4.2' AND b.IsResulted = 1 AND b.PayerType = 'Client Bill' AND b.ClaimStatus = 'Billed')
        OR (@RowCode = 'A5'   AND b.IsResulted = 1 AND b.PayerType = 'Self Pay')
        OR (@RowCode = 'A5.1' AND b.IsResulted = 1 AND b.PayerType = 'Self Pay' AND b.ClaimStatus = 'Billed')
        OR (@RowCode = 'A5.2' AND b.IsResulted = 1 AND b.PayerType = 'Self Pay' AND b.ClaimStatus = 'Not Entered in AMD')
        OR (@RowCode = 'A6'   AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Test Entries')
        OR (@RowCode = 'A6.1' AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Not Entered in AMD')
        OR (@RowCode = 'A6.2' AND b.IsResulted = 1 AND b.PayerType <> 'No Bill' AND b.ClaimStatus = 'Billed')
        OR (@RowCode = 'A7'   AND b.IsResulted = 1 AND b.ClaimStatus = 'Rejected')
        OR (@RowCode = 'A7.1' AND b.IsResulted = 1 AND b.ClaimStatus = 'Not Entered in AMD')
        OR (@RowCode = 'A7.2' AND b.IsResulted = 1 AND b.ClaimStatus = 'Billed')
        OR (@RowCode = 'A8'   AND b.IsResulted = 1 AND b.PayerType = 'No Bill')
        OR (@RowCode = 'B'    AND b.IsResulted = 0)
        OR (@RowCode = 'B1'   AND b.IsResulted = 0 AND b.ClaimStatus = 'Not Entered in AMD' AND b.PayerType = 'Insurance')
        OR (@RowCode = 'B1.1' AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD'))
        OR (@RowCode = 'B1.2' AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Collected')
        OR (@RowCode = 'B2'   AND b.IsResulted = 0 AND b.PayerType = 'Client Bill')
        OR (@RowCode = 'B3'   AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Test Entries')
        OR (@RowCode = 'B4'   AND b.IsResulted = 0 AND b.PayerType = 'Insurance' AND b.ClaimStatus = 'Rejected')
        OR (@RowCode = 'B5'   AND b.IsResulted = 0 AND b.PayerType = 'No Bill')
    ORDER BY b.AccessionNumber;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '17_PhiLife_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO

-- ============================================================
-- Cove Collection Summary - AvgPayments ClientLogic procedure
--
-- ClaimLineCSVDataCapture runs dbo.usp_RefreshCove_CS_AvgPayments_ClientLogic
-- after every Cove import. The corrected logic (v3.1) lives in
-- dbo.usp_RefreshCove_CS_AvgPayments, so this procedure runs it.
-- Safe to re-run.
-- ============================================================
USE CoveLRN;
GO
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_AvgPayments_ClientLogic
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RefreshCove_CS_AvgPayments;
END
GO

EXEC dbo.usp_RefreshCove_CS_AvgPayments_ClientLogic;
GO

SELECT COUNT(*) AS AvgPaymentsRows, MAX(RefreshedAt) AS LastRefreshed
FROM dbo.Cove_CS_AvgPayments;
GO

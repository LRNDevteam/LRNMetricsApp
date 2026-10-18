/* =====================================================================================
   InHealth DTR - Production Summary > Unbilled X Aging (14 Oct 2026)
   Database : InHealthDTRLRN

   Filter is BillStatus = 'Unbilled' only, matching the client's manual pivot.
   It was "FirstBilledDate blank OR BillStatus = 'Unbilled'", which also counted
   claims with a blank FirstBilledDate under another BillStatus.
   Rows PayerName_Raw, columns AgingDOS - unchanged. The Coding tab keeps IsUnbilled.
   Same code as InHealthDTR_ProductionSummary.sql. Safe to rerun.
   ===================================================================================== */
USE InHealthDTRLRN;
GO

/* ---- 6) Unbilled x Aging: (PayerName, AgingBucket, ClaimCount INT, TotalCharges) - buckets from AgingDOS ----
   BillStatus = 'Unbilled' only (client pivot); a blank FirstBilledDate alone does not count here. */
CREATE OR ALTER PROCEDURE dbo.usp_GetInH_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(ISNULL(PayerName, N'(blank)') AS NVARCHAR(1000)) AS PayerName,
           CAST(AgingDOS AS NVARCHAR(200))                      AS AgingBucket,
           CAST(COUNT(ClaimID) AS INT)                          AS ClaimCount,
           CAST(SUM(ChargeAmount) AS DECIMAL(18,2))             AS TotalCharges
    FROM   dbo.fn_InH_ProductionClaims(@PayerNames, @PanelNames, @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @FirstBilledFrom, @FirstBilledTo)
    WHERE  BillStatus = N'Unbilled'
    GROUP BY ISNULL(PayerName, N'(blank)'), AgingDOS
    ORDER BY PayerName, AgingBucket;
END
GO

EXEC dbo.usp_GetInH_UnbilledAging;
GO

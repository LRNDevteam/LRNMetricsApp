CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelAverages_ClientLogic
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @HasFilter BIT = 0;
    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, PayerName,
               ClaimCount AS NoOfClaims,
               ClaimCount,
               TotalCharges, CarrierPayment,
               FullyPaidCount, FullyPaidAmount,
               AdjudicatedCount, AdjudicatedAmount,
               Days30Count, Days30Amount,
               Days60Count, Days60Amount
        FROM dbo.Cove_CS_PanelAverages
        ORDER BY PanelName, PayerName;
        RETURN;
    END
END

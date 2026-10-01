/* =====================================================================================
   InHealth DTR - usp_RefreshInH_MonthlyBilledProductionSummary (aggregate table fix)
   Database : InHealthDTRLRN
   Requires : dbo.fn_InH_ProductionClaims (InHealthDTR_ProductionSummary.sql)

   Fills dbo.InH_MonthlyBilledProductionSummary with the same rules as the Monthly Summary
   tab (usp_GetInH_MonthlyBilledProductionSummary):
     Filter : (FirstBilledDate is a date OR BillStatus = 'Billed')
              AND FirstBilledDate not blank AND ChargeEnteredDate is a date
              (blank PayerName_Raw is kept as "(blank)", as in the client's Monthly pivot)
     Rows   : PanelNameBasedOnCPT > PayerName_Raw (all payers, ranked per panel)
     Column : ChargeEnteredDate yyyy-MM, Count of ClaimID, Sum of ChargeAmount
   The old version labelled blank payers "Unknown" and used DENSE_RANK, so ties shared a rank.
   ===================================================================================== */
USE InHealthDTRLRN;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshInH_MonthlyBilledProductionSummary
AS
BEGIN
    SET NOCOUNT ON;

    SELECT PanelName, ISNULL(PayerName, N'(blank)') AS PayerName, EnteredMonth, ClaimID, ChargeAmount
    INTO   #Base
    FROM   dbo.fn_InH_ProductionClaims(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
    WHERE  IsBilled = 1
      AND  FirstBilledDate IS NOT NULL
      AND  EnteredMonth IS NOT NULL;

    ;WITH PayerRanks AS
    (
        SELECT PanelName, PayerName,
               ROW_NUMBER() OVER (PARTITION BY PanelName
                                  ORDER BY COUNT(ClaimID) DESC, SUM(ChargeAmount) DESC, PayerName) AS PayerRank
        FROM   #Base
        GROUP BY PanelName, PayerName
    )
    SELECT b.PanelName,
           b.PayerName,
           CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT) AS PayerRank,
           b.EnteredMonth                     AS BilledYearMonth,
           COUNT(b.ClaimID)                   AS ClaimCount,
           CAST(SUM(b.ChargeAmount) AS DECIMAL(18,2)) AS TotalCharges
    INTO   #Final
    FROM   #Base b
    JOIN   PayerRanks r ON r.PanelName = b.PanelName AND r.PayerName = b.PayerName
    GROUP BY b.PanelName, b.PayerName, r.PayerRank, b.EnteredMonth;

    DECLARE @Rows INT;

    BEGIN TRANSACTION;
        TRUNCATE TABLE dbo.InH_MonthlyBilledProductionSummary;

        INSERT INTO dbo.InH_MonthlyBilledProductionSummary
            (PanelType, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, RefreshedAt)
        SELECT PanelName, PayerName, PayerRank, BilledYearMonth, ClaimCount, TotalCharges, GETDATE()
        FROM   #Final
        ORDER BY PanelName, PayerRank, BilledYearMonth;

        SET @Rows = @@ROWCOUNT;
    COMMIT TRANSACTION;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Final;

    PRINT 'usp_RefreshInH_MonthlyBilledProductionSummary completed - ' + CAST(@Rows AS NVARCHAR(20)) + ' rows.';
END
GO

EXEC dbo.usp_RefreshInH_MonthlyBilledProductionSummary;
GO

-- Check: totals must equal the Monthly Summary tab (78,801 claims / 26,906,214.81 on 2026-10-01 data)
SELECT PanelType, SUM(ClaimCount) AS Claims, SUM(TotalCharges) AS Charges
FROM   dbo.InH_MonthlyBilledProductionSummary
GROUP BY ROLLUP(PanelType)
ORDER BY GROUPING(PanelType), Claims DESC;
GO

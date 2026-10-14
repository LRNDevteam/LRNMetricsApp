-- ============================================================
-- Cove — CP Exception PanelType children: drop empty CROSS JOIN rows
-- Date: 2026-09-08
-- Run on CoveLRN.
--
-- Executive Summary was listing every LIMSMaster PanelType under
-- CP Exception (CGx, GI + RPP, …). Only panels that actually have
-- SubStatus = 'CP Exception' should appear:
--   Fungus, GI, PGx, RPP, STI, Tox, Urinalysis, UTI, Women's Health, Wound
--
-- This deletes snapshot children whose grand-total claim count is 0.
-- The website/Excel also filter these in C#; this keeps the table clean.
-- ============================================================

SET NOCOUNT ON;
GO

DECLARE @CpRole NVARCHAR(80);
SELECT TOP (1) @CpRole = RoleID
FROM   dbo.Cove_ES_LIS
WHERE  LTRIM(RTRIM(Description)) = 'CP Exception';

IF @CpRole IS NULL
BEGIN
    PRINT 'No CP Exception parent row in Cove_ES_LIS — nothing to prune.';
    RETURN;
END

PRINT 'CP Exception RoleID = ' + @CpRole;

;WITH emptyKids AS
(
    SELECT RoleID
    FROM   dbo.Cove_ES_LIS
    WHERE  RoleID LIKE @CpRole + '.%'
    GROUP BY RoleID
    HAVING SUM(ESMonthClaimCount) = 0
)
DELETE t
FROM   dbo.Cove_ES_LIS t
INNER JOIN emptyKids e ON e.RoleID = t.RoleID;

PRINT 'Deleted empty CP Exception panel rows: ' + CAST(@@ROWCOUNT AS VARCHAR(20));

SELECT RoleID, Description, SUM(ESMonthClaimCount) AS ClaimCount
FROM   dbo.Cove_ES_LIS
WHERE  ESYear = 0 AND ESMonth = 0
  AND  (RoleID = @CpRole OR RoleID LIKE @CpRole + '.%')
GROUP BY RoleID, Description
ORDER BY Description;
GO

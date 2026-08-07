/* =============================================================================
   Run_Certus_CodingFix.sql   — run on the CERTUS database (Certus_LRN)
   -----------------------------------------------------------------------------
   PREREQUISITE: deploy 08_CodingValidation_Certus_ExpectedCpt_2026-07-31.sql FIRST
   (that CREATE OR ALTERs the procedure). This script then (1) proves the live
   procedure is the fixed one, (2) FORCE-rebuilds the aggregates, (3) shows the
   YTD result so you can eyeball it against the client's correct values.
   ============================================================================= */
SET NOCOUNT ON;

-- 1) Is the fixed procedure actually deployed? Must return HasFix = 1.
SELECT HasFix = CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.usp_RefreshCodingAggregates'))
                          LIKE '%CERTUS-ECPT%' THEN 1 ELSE 0 END;

-- 2) FORCE a rebuild. @OnlyIfEmpty = 0 is REQUIRED — with 1 the proc no-ops
--    because CodingAgg_YtdSummary already has rows.
EXEC dbo.usp_RefreshCodingAggregates @LabName = 'Certus', @OnlyIfEmpty = 0;

-- 3) Inspect the rebuilt YTD Summary (should be the 6 panels with corrected counts).
SELECT ServiceYear, PanelName, TotalClaims, TotalBilledCharges
FROM dbo.CodingAgg_YtdSummary
WHERE ServiceYear = 2026
ORDER BY PanelName;

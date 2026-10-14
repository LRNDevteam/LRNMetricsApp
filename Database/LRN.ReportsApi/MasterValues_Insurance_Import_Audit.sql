/*
  Run against LRNMaster before retrying an insurance-payer import that timed out.
  Set the UTC window to the start of the failed request. This script is read-only.
*/

DECLARE @ImportWindowStartUtc datetime2 = '2026-06-29T03:00:00';

SELECT
    RowsChangedInWindow = COUNT_BIG(1),
    InsertedInWindow = SUM(CASE WHEN CreatedOn >= @ImportWindowStartUtc THEN 1 ELSE 0 END),
    UpdatedInWindow = SUM(CASE WHEN ModifiedOn >= @ImportWindowStartUtc THEN 1 ELSE 0 END)
FROM dbo.LabInsuranceMaster
WHERE CreatedOn >= @ImportWindowStartUtc
   OR ModifiedOn >= @ImportWindowStartUtc;

SELECT
    LabInsuranceMasterId,
    PayerCode,
    PayerNameRaw,
    PayerNameNormalized,
    GlobalPayerID,
    LabId,
    LabName,
    CreatedBy,
    CreatedOn,
    ModifiedBy,
    ModifiedOn
FROM dbo.LabInsuranceMaster
WHERE CreatedOn >= @ImportWindowStartUtc
   OR ModifiedOn >= @ImportWindowStartUtc
ORDER BY COALESCE(ModifiedOn, CreatedOn), LabInsuranceMasterId;

SELECT
    PayerNameNormalized,
    GlobalPayerID,
    DuplicateCount = COUNT_BIG(1)
FROM dbo.LabInsuranceMaster
WHERE NULLIF(LTRIM(RTRIM(PayerNameNormalized)), '') IS NOT NULL
  AND GlobalPayerID IS NOT NULL
GROUP BY PayerNameNormalized, GlobalPayerID
HAVING COUNT_BIG(1) > 1;

SELECT
    PayerCode,
    LabId,
    DuplicateCount = COUNT_BIG(1)
FROM dbo.LabInsuranceMaster
WHERE NULLIF(LTRIM(RTRIM(PayerCode)), '') IS NOT NULL
  AND LabId IS NOT NULL
GROUP BY PayerCode, LabId
HAVING COUNT_BIG(1) > 1
ORDER BY DuplicateCount DESC, PayerCode, LabId;

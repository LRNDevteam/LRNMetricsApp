-- Lab State backfill for dbo.LabInsuranceMaster (LRNMaster).
-- Diagnosis (2026-07-16): Lab State is a property of the LAB, but it is populated on only part
-- of each lab's rows. Verified counts: NWL 1075 with / 230 missing, Cove 345/155, Elixir 133/104,
-- Certus 241/61, Augustus 183/30, PCR Labs of America 30/1, Northwest 1/1 -- and every one of
-- those labs has exactly ONE distinct non-blank Lab State, so the missing rows can safely inherit
-- it from sibling rows of the same lab.
-- Labs with NO state on any row (Beech Tree, InHealth-DTR, Phi Life, Prism, Rising Tides) cannot
-- be derived and need the consolidated master file load (recommendation #8).
--
-- Step 1 (review): shows what would change.
SELECT lab.LabName,
       FillState = src.LabState,
       FillStateCode = src.LabStateCode,
       RowsToFill = COUNT(1)
FROM dbo.LabInsuranceMaster lab
JOIN (
    SELECT LabName = LTRIM(RTRIM(LabName)),
           LabState = MAX(NULLIF(LTRIM(RTRIM(ISNULL(LabState,''))),'')),
           LabStateCode = MAX(NULLIF(LTRIM(RTRIM(ISNULL(LabStateCode,''))),''))
    FROM dbo.LabInsuranceMaster
    GROUP BY LTRIM(RTRIM(LabName))
    HAVING COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ISNULL(LabState,''))),'')) = 1
) src ON src.LabName = LTRIM(RTRIM(lab.LabName))
WHERE NULLIF(LTRIM(RTRIM(ISNULL(lab.LabState,''))),'') IS NULL
GROUP BY lab.LabName, src.LabState, src.LabStateCode
ORDER BY RowsToFill DESC;

-- Step 2 (apply): run inside a transaction after reviewing step 1.
/*
BEGIN TRANSACTION;

UPDATE lab
SET lab.LabState = src.LabState,
    lab.LabStateCode = COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(lab.LabStateCode,''))),''), src.LabStateCode),
    lab.ModifiedBy = 'LabStateBackfill_005',
    lab.ModifiedOn = SYSUTCDATETIME()
FROM dbo.LabInsuranceMaster lab
JOIN (
    SELECT LabName = LTRIM(RTRIM(LabName)),
           LabState = MAX(NULLIF(LTRIM(RTRIM(ISNULL(LabState,''))),'')),
           LabStateCode = MAX(NULLIF(LTRIM(RTRIM(ISNULL(LabStateCode,''))),''))
    FROM dbo.LabInsuranceMaster
    GROUP BY LTRIM(RTRIM(LabName))
    HAVING COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ISNULL(LabState,''))),'')) = 1
) src ON src.LabName = LTRIM(RTRIM(lab.LabName))
WHERE NULLIF(LTRIM(RTRIM(ISNULL(lab.LabState,''))),'') IS NULL;

-- Expect ~582 rows (NWL 230 + Cove 155 + Elixir 104 + Certus 61 + Augustus 30 + PCR LoA 1 + Northwest 1).
COMMIT TRANSACTION;
*/

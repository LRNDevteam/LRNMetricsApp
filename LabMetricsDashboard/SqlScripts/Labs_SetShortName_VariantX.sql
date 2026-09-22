/* ============================================================================
   dbo.Labs.ShortName for VariantX (LabId 25).

   Fixes the Master File Processor crash:
     sp_LRN_NextRunId: no ShortName for LabId 25 / LabName "VariantX".

   ShortName is the per-lab prefix in every generated RunId, so it has to be set
   before the worker can start a run for this lab. Existing labs use a 3-letter
   code: INH, COV, PAL, PCO, RST, BCT, PHY, PLA, ELX, CRT, NWL, AUG.

   VTX is chosen to match that shape. It ends up in RunIds and therefore in the
   Report Board and every run log, so change it here BEFORE the first run if the
   team prefers another code - renaming it afterwards leaves historical RunIds
   carrying the old prefix.

   RE-RUNNABLE, and deliberately will not overwrite a ShortName already set.
   ============================================================================ */

SET NOCOUNT ON;
GO

DECLARE @LabId     INT         = 25;
DECLARE @ShortName VARCHAR(10) = 'VTX';

IF NOT EXISTS (SELECT 1 FROM dbo.Labs WHERE LabId = @LabId)
BEGIN
    RAISERROR('LabId %d is not in dbo.Labs - register the lab first.', 16, 1, @LabId);
END
ELSE IF EXISTS (SELECT 1 FROM dbo.Labs
                WHERE ShortName = @ShortName AND LabId <> @LabId)
BEGIN
    -- Two labs sharing a prefix makes RunIds ambiguous, which is worse than a failed script.
    RAISERROR('ShortName ''%s'' is already used by another lab. Pick a different code.', 16, 1, @ShortName);
END
ELSE
BEGIN
    UPDATE dbo.Labs
    SET    ShortName    = @ShortName,
           ModifiedBy   = 'system',
           ModifiedDate = SYSUTCDATETIME()
    WHERE  LabId = @LabId
      AND  (ShortName IS NULL OR LTRIM(RTRIM(ShortName)) = '');

    IF @@ROWCOUNT > 0
        PRINT 'VariantX ShortName set to ' + @ShortName + '.';
    ELSE
        PRINT 'VariantX already has a ShortName - left unchanged.';
END
GO

SELECT LabId, LabName, ShortName, IsActive
FROM   dbo.Labs
WHERE  ShortName IS NULL OR LabId = 25
ORDER  BY LabId;
GO

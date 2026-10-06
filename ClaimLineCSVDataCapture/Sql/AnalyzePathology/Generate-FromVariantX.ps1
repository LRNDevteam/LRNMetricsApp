$ErrorActionPreference = 'Stop'
$root = "D:\Office\LRN\GITApps\LRNDev\LRNDevteam\LRNMetricsApp\ClaimLineCSVDataCapture\Sql"
$src  = Join-Path $root "VariantX"
$dst  = Join-Path $root "AnalyzePathology"
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$files = @(
  '12_VariantX_CollectionSummary.sql',
  '12b_VariantX_CollectionSummary_Fix_BrokenProcs.sql',
  '14b_VariantX_CollectionSummary_ReadSPs_Fix.sql',
  '15_VariantX_ExecutiveSummary_Tables.sql',
  '16_VariantX_ExecutiveSummary_Aggregate.sql',
  '17b_VariantX_ExecutiveSummary_Read_Fix.sql',
  '18_VariantX_ExecutiveSummary_Detail.sql',
  '19_VariantX_ExecutiveSummary_LIS_Alt.sql',
  '20_VariantX_ExecutiveSummaryDetailRows_LIS.sql',
  '21b_VariantX_ExecutiveSummaryDetailRows_PMSCash_Fix.sql',
  '22_VariantX_ExecutiveSummary_FilterOptions.sql',
  '22b_VariantX_ExecutiveSummary_FilterOptions_Fix.sql',
  '23_VariantX_CS_AvgPayments_DateOfService.sql',
  '24_VariantX_MappingFixes.sql'
)

# Ordered (pattern, replacement) pairs. Regex, case-sensitive.
$rules = [ordered]@{
  'VariantX_LRN'  = 'AnalyzePathology'
  'VariantX Labs' = 'Analyze Pathology'
  'VariantX'      = 'AnalyzePathology'
  'VarX'          = 'AnP'

  # ClaimLevelData flag columns: VariantX name -> Analyze Pathology name
  '\bAdjucticatedCount\b'  = 'Adjudicated'
  '\bAdjucticatedAmount\b' = 'AdjudicatedAmount'
  '\bBucket30Count\b'      = 'Bucket30'
  '\bBucket60Count\b'      = 'Bucket60'

  # Billed / Unbilled comes from ClaimLevelData.BilledStatus
  # (Billed / Billed - Self Pay / Unbilled / Unbilled -  Self Pay), never from ClaimStatus.
  "COL_LENGTH\(N'dbo\.ClaimLevelData', N'BillStatus'\) IS NOT NULL(\s+)THEN N'ISNULL\(BillStatus, ''''\)'" =
      "COL_LENGTH(N'dbo.ClaimLevelData', N'BilledStatus') IS NOT NULL`$1THEN N'CASE WHEN LTRIM(RTRIM(ISNULL(BilledStatus, ''''))) LIKE ''Unbilled%'' THEN ''Unbilled'' ELSE ''Billed'' END'"
  "LTRIM\(RTRIM\(ISNULL\(ClaimStatus, ''''\)\)\) IN \(''Unbilled'',''Unbilled - PB''\)" =
      "LTRIM(RTRIM(ISNULL(BilledStatus, ''''))) LIKE ''Unbilled%''"
  "LTRIM\(RTRIM\(ISNULL\(ClaimStatus, ''\)\)\) IN \('Unbilled','Unbilled - PB'\)" =
      "LTRIM(RTRIM(ISNULL(BilledStatus, ''))) LIKE 'Unbilled%'"
  "b\.ClaimStatus IN \('Unbilled','Unbilled - PB'\)" = "b.BilledUnbilled = 'Unbilled'"

  # ClaimStatus spellings used by Analyze Pathology
  "ClaimStatus = 'Denied'"                          = "ClaimStatus IN ('Denied','Fully Denied')"
  "IN \('Denied','No Response','Partially Denied'\)" = "IN ('Denied','Fully Denied','No Response','Partially Denied')"
  "'Billed Amount 0'"                               = "'Billed Amount 0','0 Billed Amount'"

  # LIMSMaster values used by Analyze Pathology
  "BillCategory = 'Not Billed'"         = "BillCategory IN ('Not Billed','Unbilled')"
  "NewStatus = 'Yet to be validated'"   = "NewStatus IN ('Yet to be validated','Yet to Be Validate')"
  # LIMSMaster.PanelCategory exists but is always NULL; PanelName holds the panel.
  "AND name IN \('PanelCategory',"      = "AND name IN ("
}

# Rules that only apply to one source file.
$fileRules = @{
  # 12b ends by executing the refresh SPs. Its CS_PanelAverages builds dynamic SQL from
  # non-MAX pieces (cut at 4000 chars) and is replaced by script 24, so leave the refresh
  # to 99_AnalyzePathology_ExecuteAllAggregates.sql.
  '12b_VariantX_CollectionSummary_Fix_BrokenProcs.sql' = [ordered]@{
    '(?s)-- Optional: refresh aggregates now.*?\r?\nGO\r?\n' = ''
  }
  # VariantX ClaimLevelData has PanelType; Analyze Pathology has Panelname.
  '22b_VariantX_ExecutiveSummary_FilterOptions_Fix.sql' = [ordered]@{
    '\bPanelType\b' = 'Panelname'
  }
}

$totals = [ordered]@{}
foreach ($k in $rules.Keys) { $totals[$k] = 0 }

foreach ($f in $files) {
  $text = [IO.File]::ReadAllText((Join-Path $src $f))
  foreach ($k in $rules.Keys) {
    $n = ([regex]::Matches($text, $k)).Count
    $totals[$k] += $n
    $text = [regex]::Replace($text, $k, $rules[$k])
  }
  if ($fileRules.ContainsKey($f)) {
    foreach ($k in $fileRules[$f].Keys) {
      $n = ([regex]::Matches($text, $k)).Count
      if ($n -eq 0) { throw "File rule '$k' matched nothing in $f" }
      $text = [regex]::Replace($text, $k, $fileRules[$f][$k])
      "  $f : $n x $k"
    }
  }
  $banner = @"
/* =============================================================================
   Analyze Pathology (prefix AnP_) - GENERATED from Sql/VariantX/$f
   by Generate-FromVariantX.ps1. Edit the VariantX script or the generator, not this file.
   Database: AnalyzePathology

   Analyze Pathology mappings applied on top of the VariantX logic:
     ClaimLevelData.AdjucticatedCount / Bucket30Count / Bucket60Count
         -> Adjudicated / Bucket30 / Bucket60  (AdjucticatedAmount -> AdjudicatedAmount)
     Billed / Unbilled from ClaimLevelData.BilledStatus LIKE 'Unbilled%'
     ClaimStatus 'Fully Denied' counts as 'Denied', '0 Billed Amount' as 'Billed Amount 0'
     LIMSMaster.BillCategory 'Unbilled' counts as 'Not Billed',
         NewStatus 'Yet to Be Validate' as 'Yet to be validated'
     LIMSMaster panel column: PanelName (PanelCategory is never populated)
   Comments further down were written for VariantX ("AnalyzePathology" there
   was substituted for "VariantX").
   ============================================================================= */

"@
  $banner = $banner -replace "`r?`n", "`r`n"
  $outName = $f -replace 'VariantX', 'AnalyzePathology'
  [IO.File]::WriteAllText((Join-Path $dst $outName), $banner + $text, (New-Object Text.UTF8Encoding($false)))
  "wrote $outName"
}
""
"Replacement counts:"
foreach ($k in $totals.Keys) { "{0,5}  {1}" -f $totals[$k], $k }

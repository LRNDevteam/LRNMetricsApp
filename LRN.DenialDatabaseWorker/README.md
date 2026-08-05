# DenialDatabaseProcessorWorker (.NET 8)

What it does (per LAB):

**Output columns**: includes ALL original PayerPolicy columns (same order) + new columns (DenialCode_Original, DenialCode_Normalized, validation flags, Status Action Code, Task Guidance). The DenialCode column itself is replaced with the normalized value.

1. Loads the denial source:
   - **Denial rows come from SQL, not from a file.** For every lab, the worker reads
     `[<LabDatabase>].[dbo].[PayerValidationReport]` where `PayStatus = 'Denied'`
     (table/status configurable via `PayerValidationReportTable` / `DeniedPayStatus`).
     The upstream process no longer publishes `*_Payer_Policy_ValidationReport.xlsx`.
     SQL columns are re-keyed to the old Excel header names, so all downstream mapping is unchanged.
   - The RunId, WeekFolder and SourceFullPath columns supply the run identity that used to be
     parsed out of the workbook file name and folder path. With `ProcessLatestRunOnly = true`
     only the newest RunId is processed; a RunId already present in `dbo.DenialAnalysisRunLog` is skipped.
   - ClaimActionMapper is still an Excel file (must contain a denial prefix column like
     "Denial Code_Prefix" / "Denial code_prefix" and the mapping columns)
2. Normalizes `PayerPolicyFile.DenialCode`:
   - split by comma
   - uppercase
   - remove spaces and '-' (e.g., "CO 55", "CO-56" -> "CO55", "CO56")
   - remove these "generic" codes anywhere they appear:
     PR1, CO1, PI1, PR2, CO2, PI2, PR3, CO3, PI3, PR45, CO45, PI45, PR253, CO253, PI253
3. Enriches each PayerPolicy row by mapping denial codes against ClaimActionMapper:
   - For each denial code (after split + normalize), match against ClaimActionMapper.Denail code_prefix
   - Collect distinct values per column and join with comma for:
     Denial Description, Denial Classification, Denial Type,
     Payer Policy Validation Required, CPT Validation Required, ICD Validation Required,
     Frequency Validation Required, Gender Validation Required, MUE Validation Required,
     Payability, Status Action Code, Recommended Action, Task Guidance
4. Copies the result into the LAB database (this is the primary output):
   DenialInsight, DenialLineItem and DenialTaskBoard, plus a RunLog row in LRNMaster.
5. Optionally outputs the export package per lab (xlsx + line-item csv + zip):
   <OutputRoot>\<LabName>\<Year>\<Month>\<Week>\<RunId>_<LabName>_DenialAnalysisReport_<Week>.zip
   **Off by default.** Controlled by `DenialDatabaseProcessor:GenerateOutputFiles`; when false the
   worker performs the SQL copy only and writes no files. `UploadOutputsToSharePoint` gates the
   SharePoint upload of that package and is ignored when `GenerateOutputFiles` is false.
6. Step-by-step CSV logging:
   Log columns:
   LabName,LabId,StepDescription,LogType,PayerPolicyFilePath,ClaimActionMapperFilePath,ErrorInfo,LogDateTime,OutputPath
   (PayerPolicyFilePath now holds the SQL source label, e.g.
   `NWL_LRN.dbo.PayerValidationReport (RunId=..., PayStatus=Denied, Rows=...)`)
7. Optional SharePoint upload (Graph API):
   Upload to: <SharePointUploadPath base folder>/<LABNAME>/<Month>/<MMDDYYYY>/LabName_DenialDatabase_MMDDYYYY.xlsx

---

## Run locally
```bash
dotnet restore
dotnet run
```

## Install as Windows Service
Publish:
```bash
dotnet publish -c Release -r win-x64 --self-contained false
```

Create service:
```powershell
sc.exe create "LRN - Denial Database Processor" binPath= "C:\path\to\DenialDatabaseProcessorWorker.exe"
sc.exe start  "LRN - Denial Database Processor"
```

---

## SharePoint upload configuration (Graph)
Set in appsettings.json:
- DenialDatabaseProcessor:SharePoint:Enabled = true
- TenantId, ClientId, ClientSecret (App Registration)
- SiteUrl (e.g. https://tenant.sharepoint.com/sites/SiteName)

Permissions needed for the app registration (typical):
- Microsoft Graph -> Application permissions -> Sites.ReadWrite.All (or Sites.Selected if you prefer tighter)
Then grant admin consent.

> NOTE: Your `SharePointUploadPath` is a "AllItems.aspx?id=..." link. The worker automatically extracts the folder from the `id=` query string and uploads into that library folder.


## Mapping format update
- When a PayerPolicy row has multiple denial codes (e.g., CO55,CO56), mapped columns are written as `CODE - Value` pairs joined with comma+space.
  Example: `CO55 - Description A, CO56 - Description B`
- Current ClaimActionMapper mappings are applied only where **Denial Type = Claim Level Denial**.

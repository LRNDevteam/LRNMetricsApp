# LIS Summary patch

Add the files into the same folders in `LabMetricsDashboard`.

## Files
- `Models/LisSummaryViewModel.cs`
- `Services/ILisSummaryRepository.cs`
- `Services/SqlLisSummaryRepository.cs`
- `Views/Dashboard/LisSummary.cshtml`

## Existing file changes
### Program.cs
Add:
```csharp
builder.Services.AddScoped<ILisSummaryRepository, SqlLisSummaryRepository>();
```
near:
```csharp
builder.Services.AddScoped<IProductionReportRepository, SqlProductionReportRepository>();
```

### DashboardController.cs
1. Add field:
```csharp
private readonly ILisSummaryRepository _lisSummaryRepo;
```
2. Add constructor parameter:
```csharp
ILisSummaryRepository lisSummaryRepo,
```
3. Assign:
```csharp
_lisSummaryRepo = lisSummaryRepo;
```
4. Paste the action from `Controllers_Patch/DashboardController_LisSummary_Action.cs` inside the controller class.

### Views/Shared/_Layout.cshtml
Add the menu item from `Views/Shared_Patch/_Layout_StandardReports_Insert.cshtml.txt` inside the **Standard Reports** dropdown.

## Notes
- Uses `dbo.LIMSMaster`.
- Uses `RequestCollectDate` as the page filter and month/year axis.
- Counts distinct `OrderID` for Beech Tree logic and distinct `Accession` for PCRLOA/PhiLife/Rising Tides logic.
- Maps lab name by contains:
  - Beech → Beech Tree sheet
  - PCRLOA / PCR Labs → PCRLOA sheet
  - PhiLife / Phi Life → PhiLife sheet
  - Rising → Rising Tides sheet
  - Default → Beech Tree

# Lab-Specific Feature Toggles Implementation

## Overview
This document describes the implementation of lab-specific feature toggles that enable/disable navigation menu items and controller actions based on JSON configuration.

## Feature Toggle Keys

The following boolean properties control feature availability per lab:

| Property Name | Default Value | Controls |
|--------------|---------------|----------|
| `EnableCoding` | `true` | Coding Summary page (Analytics menu) |
| `EnablePrediction` | `true` | Prediction Analysis page (Analytics menu) |
| `EnableForcast` | `true` | Forecasting Summary page (Analytics menu) |
| `EnableClinicsummary` | `true` | Clinic Summary page (Analytics menu) |
| `EnableSalesRepsummary` | `true` | Sales Rep Summary page (Analytics menu) |
| `EnableProductionReport` | `true` | Production Report page (Standard Reports menu) |
| `EnableCollectionReport` | `true` | Collection Summary page (Standard Reports menu) |

## JSON Configuration Example

```json
{
  "PCRLabsofAmerica": {
    "ProductionMasterCsvPath": "E:\\LRN-Data\\CodingMaster\\...",
    "PayerPolicyValidationReportPath": "E:\\LRN-Data\\PayerPolicy_v2\\...",
    "DBEnabled": true,
    "LineClaimEnable": true,
    "DbConnectionString": "Server=...;Database=...;...",
    "InsightPath": "",
    "RCMJsonpath": "E:\\LRN-Data\\PayerPolicy_v2\\...",
    "Reports": "E:\\LRN-Data\\CodingMaster\\...",
    "CollectionOutput": "table1",
    
    "EnableCoding": true,
    "EnablePrediction": true,
    "EnableForcast": true,
    "EnableClinicsummary": true,
    "EnableSalesRepsummary": true,
    "EnableProductionReport": true,
    "EnableCollectionReport": true
  }
}
```

## Implementation Details

### 1. Model Changes (`LabMetricsDashboard\Models\LabConfig.cs`)

Added feature toggle properties to `LabCsvConfig`:

```csharp
public sealed class LabCsvConfig
{
    // ... existing properties ...

    public bool EnableCoding { get; init; } = true;
    public bool EnablePrediction { get; init; } = true;
    public bool EnableForcast { get; init; } = true;
    public bool EnableClinicsummary { get; init; } = true;
    public bool EnableSalesRepsummary { get; init; } = true;
    public bool EnableProductionReport { get; init; } = true;
    public bool EnableCollectionReport { get; init; } = true;
}
```

### 2. Layout Changes (`LabMetricsDashboard\Views\Shared\_Layout.cshtml`)

#### Navigation Menu Logic

The layout reads the lab configuration and conditionally renders menu items:

```csharp
// Get lab-specific feature toggles
LabCsvConfig? labConfig = null;
if (!string.IsNullOrEmpty(activeLab) && LabSettingsInstance.Labs.ContainsKey(activeLab))
{
    labConfig = LabSettingsInstance.Labs[activeLab];
}
```

#### Disabled Menu Items

When a feature is disabled, the menu item is shown but not clickable:

```razor
@if (labConfig?.EnableProductionReport ?? true)
{
    <li>
        <a class="dropdown-item" asp-controller="Dashboard" asp-action="ProductionReport">
            <i class="bi bi-bar-chart-fill"></i> Production Report
        </a>
    </li>
}
else
{
    <li>
        <span class="dropdown-item disabled" title="This feature is not enabled for the selected lab">
            <i class="bi bi-bar-chart-fill"></i> Production Report
        </span>
    </li>
}
```

#### CSS Styling

Added CSS for disabled menu items:

```css
.lmd-navbar .dropdown-item.disabled {
    color: rgba(255, 255, 255, .3) !important;
    background: transparent;
    cursor: not-allowed;
    pointer-events: none;
}
```

### 3. Controller Changes

Each controller action checks the feature toggle before processing requests:

#### DashboardController.cs

**ProductionReport Action:**
```csharp
if (!config.EnableProductionReport)
{
    return View(new ProductionReportViewModel
    {
        AvailableLabs = availableLabs,
        SelectedLab   = selectedLab,
        ErrorMessage  = $"Production Report feature is not enabled for {selectedLab}. Please contact your administrator.",
    });
}
```

**ClinicSummary Action:**
```csharp
if (!config.EnableClinicsummary)
{
    return View(new ClinicSummaryViewModel
    {
        AvailableLabs = availableLabs,
        SelectedLab   = selectedLab,
        ErrorMessage  = $"Clinic Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
    });
}
```

**SalesRepSummary Action:**
```csharp
if (!config.EnableSalesRepsummary)
{
    return View(new SalesRepSummaryViewModel
    {
        AvailableLabs = availableLabs,
        SelectedLab   = selectedLab,
        ErrorMessage  = $"Sales Rep Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
    });
}
```

#### PredictionController.cs

**Index Action (Prediction Analysis):**
```csharp
if (labConfig?.EnablePrediction == false)
{
    return View(new PredictionAnalysisViewModel
    {
        AvailableLabs        = availableLabs,
        SelectedLab          = selectedLab,
        PredictionAvailable  = false,
        ErrorMessage         = $"Prediction Analysis feature is not enabled for {selectedLab}. Please contact your administrator.",
        CurrentWeekStartDate = DateOnly.FromDateTime(DateTime.Today),
    });
}
```

**ForecastingSummary Action:**
```csharp
if (labConfig?.EnableForcast == false)
{
    return View(new ForecastingSummaryViewModel
    {
        AvailableLabs       = availableLabs,
        SelectedLab         = selectedLab,
        PredictionAvailable = false,
        ErrorMessage        = $"Forecasting Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
    });
}
```

#### CollectionSummaryController.cs

```csharp
if (!config.EnableCollectionReport)
{
    return View(new CollectionSummaryViewModel
    {
        AvailableLabs = availableLabs,
        SelectedLab = selectedLab,
        ErrorMessage = $"Collection Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
    });
}
```

#### CodingController.cs

```csharp
if (!config.EnableCoding)
{
    return View(new CodingSummaryViewModel
    {
        LabName       = selectedLab,
        AvailableLabs = availableLabs,
        ErrorMessage  = $"Coding Summary feature is not enabled for {selectedLab}. Please contact your administrator.",
    });
}
```

### 4. View Model Changes

Added `ErrorMessage` property to view models that didn't have one:

- `PredictionAnalysisViewModel.cs` - Added `ErrorMessage` property
- `ForecastingSummaryViewModel.cs` - Added `ErrorMessage` property

## User Experience

### When Feature is Enabled
- Menu item is clickable and displays normally
- User can access the page
- All functionality works as expected

### When Feature is Disabled
- Menu item appears grayed out with reduced opacity
- Tooltip shows: "This feature is not enabled for the selected lab"
- Menu item is not clickable (pointer-events: none)
- Direct URL access is blocked by controller-level validation
- User sees a friendly error message: "XYZ feature is not enabled for {LabName}. Please contact your administrator."

### When User Changes Lab Selection
- The navigation menu updates immediately
- Disabled features are visually indicated
- No page reload required for menu state changes

## Benefits

1. **Granular Control**: Enable/disable features per lab without code changes
2. **Backward Compatible**: All features default to `true` (enabled)
3. **Security**: Both UI and controller-level protection
4. **User-Friendly**: Clear visual feedback when features are disabled
5. **Maintainable**: Configuration-driven approach is easy to update
6. **Flexible**: Can enable different features for different labs

## Testing Scenarios

### Test Case 1: All Features Enabled
1. Set all `Enable*` flags to `true` in lab config
2. Select the lab from dropdown
3. Verify all menu items are clickable
4. Verify all pages load successfully

### Test Case 2: Selective Feature Disable
1. Set `EnableCoding` to `false`
2. Select the lab from dropdown
3. Verify "Coding Summary" menu item is grayed out
4. Try accessing `/Coding/Summary?lab=LabName` directly
5. Verify error message is displayed

### Test Case 3: Multiple Features Disabled
1. Set multiple `Enable*` flags to `false`
2. Select the lab from dropdown
3. Verify all disabled features are grayed out
4. Verify direct URL access is blocked for all disabled features

### Test Case 4: Lab Switch
1. Start with Lab A (has all features enabled)
2. Navigate to a feature page
3. Switch to Lab B (has that feature disabled)
4. Verify menu updates to show grayed-out state

## Configuration Guidelines

### Recommended Settings

**For Production Labs with Full Data:**
```json
"EnableCoding": true,
"EnablePrediction": true,
"EnableForcast": true,
"EnableClinicsummary": true,
"EnableSalesRepsummary": true,
"EnableProductionReport": true,
"EnableCollectionReport": true
```

**For Labs with Limited Data:**
```json
"EnableCoding": false,
"EnablePrediction": true,
"EnableForcast": true,
"EnableClinicsummary": false,
"EnableSalesRepsummary": false,
"EnableProductionReport": true,
"EnableCollectionReport": true
```

**For Test/Demo Labs:**
```json
"EnableCoding": false,
"EnablePrediction": false,
"EnableForcast": false,
"EnableClinicsummary": false,
"EnableSalesRepsummary": false,
"EnableProductionReport": true,
"EnableCollectionReport": false
```

## Future Enhancements

1. **Role-Based Toggles**: Combine with user authentication to enable/disable based on user roles
2. **Temporary Toggles**: Add date-based feature availability
3. **Feature Metrics**: Track which features are most used per lab
4. **Admin UI**: Create an admin interface to manage feature toggles
5. **Audit Logging**: Log when features are enabled/disabled

## Support

For questions or issues related to feature toggles:
1. Check the lab's JSON configuration file
2. Verify the feature flag is set correctly (true/false)
3. Restart the application after configuration changes
4. Check application logs for any errors during configuration loading

## Related Files

- `LabMetricsDashboard\Models\LabConfig.cs` - Model definition
- `LabMetricsDashboard\Views\Shared\_Layout.cshtml` - Navigation menu
- `LabMetricsDashboard\Controllers\DashboardController.cs` - Feature checks
- `LabMetricsDashboard\Controllers\PredictionController.cs` - Feature checks
- `LabMetricsDashboard\Controllers\CollectionSummaryController.cs` - Feature checks
- `LabMetricsDashboard\Controllers\CodingController.cs` - Feature checks
- `[LabConfigFolder]\[LabName].json` - Configuration files

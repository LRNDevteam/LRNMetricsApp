# Dashboard KPI Data Flow - Complete Diagram

## Overview
The Revenue Dashboard displays KPIs (Total Claims, Total Charges, Total Payments, Outstanding Balance, Collection Rate, Denial Rate, Adjustment Rate, Outstanding Charge %) that are sourced from **SQL Server database tables** populated by **CSV data capture workers**.

---

## Data Flow Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           SOURCE: CSV FILES (Weekly Uploads)                      │
│  - Claim-Level CSV: Contains claim header data (Patient, Payer, Amounts, Status) │
│  - Line-Level CSV: Contains CPT line items per claim                             │
└───────────────────────────────┬─────────────────────────────────────────────────┘
								│
								▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    STEP 1: ClaimLineCSVDataCapture Worker                        │
│  Project: ClaimLineCSVDataCapture.csproj                                         │
│  Purpose: Parse CSV files and bulk-load into SQL Server                          │
│                                                                                   │
│  Key Components:                                                                 │
│  ├─ CsvFileWatcherService.cs - Monitors for new CSV files                       │
│  ├─ ClaimCsvProcessor.cs - Parses claim-level CSV rows                          │
│  ├─ LineCsvProcessor.cs - Parses line-level CSV rows                            │
│  └─ SqlBulkCopyService.cs - Bulk inserts into database                          │
└───────────────────────────────┬─────────────────────────────────────────────────┘
								│
								▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                STEP 2: SQL Stored Procedures (Bulk Insert)                       │
│  Stored Procedure: dbo.usp_BulkInsertClaimLevelData                             │
│  Location: ClaimLineCSVDataCapture/Sql/{LabName}/                               │
│           04_{LabName}_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql              │
│                                                                                   │
│  Process:                                                                        │
│  1. Archive existing data to ClaimLevelDataArchive                              │
│  2. Truncate dbo.ClaimLevelData                                                 │
│  3. Bulk INSERT new data from TVP (Table-Valued Parameter)                      │
│  4. Log file metadata in LineClaimFileLogs                                      │
└───────────────────────────────┬─────────────────────────────────────────────────┘
								│
								▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    STEP 3: DATABASE TABLES (SQL Server)                          │
│                                                                                   │
│  ┌────────────────────────────────────────────────────────────────────────┐    │
│  │ dbo.ClaimLevelData (Active/Current Data)                                │    │
│  │                                                                          │    │
│  │ Key Columns Used by Dashboard:                                          │    │
│  │  - ChargeAmount          → Total Charges                                │    │
│  │  - TotalPayments         → Total Payments                               │    │
│  │  - TotalBalance          → Outstanding Balance                          │    │
│  │  - AllowedAmount         → Collection Rate Numerator (when paid)       │    │
│  │  - InsuranceAdjustments  → Adjustment Rate Numerator                    │    │
│  │  - ClaimStatus           → Used to classify claims:                     │    │
│  │      • 'Fully Paid', 'Partially Paid', 'Patient Responsibility'         │    │
│  │        → Collection Rate calculation                                    │    │
│  │      • 'Fully Denied', 'Partially Denied'                               │    │
│  │        → Denial Rate calculation                                        │    │
│  │      • 'Complete W/O', 'Partially Adjusted'                             │    │
│  │        → Adjustment Rate calculation                                    │    │
│  │      • 'No Response'                                                     │    │
│  │        → Outstanding Charge % calculation                               │    │
│  │  - PayerName, PanelName, ClinicName → Filters and breakdowns           │    │
│  │  - DateofService, FirstBilledDate → Date filters                        │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                   │
│  ┌────────────────────────────────────────────────────────────────────────┐    │
│  │ dbo.LineLevelData (CPT Line Items)                                       │    │
│  │  - Used for line-level analysis, CPT charge breakdown                   │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
└───────────────────────────────┬─────────────────────────────────────────────────┘
								│
								▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│              STEP 4: Dashboard Repository (Data Aggregation)                     │
│  Class: SqlDashboardRepository.cs                                                │
│  Location: LabMetricsDashboard/Services/SqlDashboardRepository.cs               │
│  Method: GetDashboardAsync(...)                                                  │
│                                                                                   │
│  SQL Queries Executed:                                                           │
│  ┌──────────────────────────────────────────────────────────────────────┐      │
│  │ KPI Query (lines 76-93):                                              │      │
│  │                                                                        │      │
│  │ SELECT                                                                 │      │
│  │   COUNT(*)                              AS TotalClaims,                │      │
│  │   SUM(TRY_CAST(ChargeAmount, DECIMAL))  AS TotalCharges,              │      │
│  │   SUM(TRY_CAST(TotalPayments, DECIMAL)) AS TotalPayments,             │      │
│  │   SUM(TRY_CAST(TotalBalance, DECIMAL))  AS TotalBalance,              │      │
│  │                                                                        │      │
│  │   SUM(CASE WHEN ClaimStatus IN ('Fully Paid','Partially Paid',        │      │
│  │        'Patient Responsibility','Patient Payment')                     │      │
│  │        THEN TRY_CAST(AllowedAmount, DECIMAL) ELSE 0 END)               │      │
│  │     AS CollectionNumerator,                                            │      │
│  │                                                                        │      │
│  │   SUM(CASE WHEN ClaimStatus IN ('Fully Denied','Partially Denied')    │      │
│  │        THEN TRY_CAST(ChargeAmount, DECIMAL) ELSE 0 END)                │      │
│  │     AS DenialNumerator,                                                │      │
│  │                                                                        │      │
│  │   SUM(CASE WHEN ClaimStatus IN ('Complete W/O','Partially Adjusted')  │      │
│  │        THEN TRY_CAST(InsuranceAdjustments, DECIMAL) ELSE 0 END)        │      │
│  │     AS AdjustmentNumerator,                                            │      │
│  │                                                                        │      │
│  │   SUM(CASE WHEN ClaimStatus = 'No Response'                            │      │
│  │        THEN TRY_CAST(ChargeAmount, DECIMAL) ELSE 0 END)                │      │
│  │     AS OutstandingNumerator                                            │      │
│  │ FROM dbo.ClaimLevelData                                                │      │
│  │ WHERE {filters applied: payer, panel, clinic, dates, etc.}            │      │
│  └──────────────────────────────────────────────────────────────────────┘      │
│                                                                                   │
│  Additional Queries:                                                             │
│  - Claim Status Breakdown (Fully Paid, Denied, etc.)                            │
│  - Payer-Level Insights (charges/payments per payer)                            │
│  - Panel-Level Insights (charges/payments per panel)                            │
│  - Monthly Trends (DOS, First Bill Date)                                        │
│  - Top CPT Codes (from LineLevelData)                                           │
└───────────────────────────────┬─────────────────────────────────────────────────┘
								│
								▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                   STEP 5: Dashboard Controller & View                            │
│  Controller: DashboardController.cs                                              │
│  Action: Index(...filters...)                                                    │
│  View: Views/Dashboard/Index.cshtml                                              │
│                                                                                   │
│  Controller Logic:                                                               │
│  1. Resolve selected lab and filters                                            │
│  2. Call _dashboardRepo.GetDashboardAsync(connectionString, filters)            │
│  3. Build DashboardViewModel with KPIs and breakdowns                           │
│  4. Return View(viewModel)                                                       │
│                                                                                   │
│  View Rendering:                                                                 │
│  - Displays 4 main KPI cards (Claims, Charges, Payments, Balance)              │
│  - Displays 4 rate cards (Collection %, Denial %, Adjustment %, Outstanding %)  │
│  - Renders charts and breakdowns                                                │
└───────────────────────────────┬─────────────────────────────────────────────────┘
								│
								▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        FINAL OUTPUT: Browser UI                                  │
│                                                                                   │
│  ┌──────────────────────┬──────────────────────┬──────────────────────┐        │
│  │   Total Claims       │   Total Charges      │   Total Payments     │        │
│  │      28,267          │  $45,508,370.28      │  $11,584,132.90      │        │
│  └──────────────────────┴──────────────────────┴──────────────────────┘        │
│  ┌──────────────────────────────────────────────────────────────────────┐      │
│  │   Outstanding Balance                                                 │      │
│  │      $13,392,551.00                                                   │      │
│  └──────────────────────────────────────────────────────────────────────┘      │
│                                                                                   │
│  ┌──────────────────┬──────────────────┬──────────────────┬─────────────┐      │
│  │ Collection Rate  │ Denial Rate      │ Adjustment Rate  │ Outstanding │      │
│  │     28.2%        │     9.8%         │     0.0%         │    9.0%     │      │
│  └──────────────────┴──────────────────┴──────────────────┴─────────────┘      │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Detailed KPI Calculation Logic

### 1. **Total Claims**
```sql
COUNT(*) FROM dbo.ClaimLevelData WHERE {filters}
```
- Simple row count of all claims matching filters

### 2. **Total Charges**
```sql
SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))) FROM dbo.ClaimLevelData WHERE {filters}
```
- Sum of all billed charges across all claims

### 3. **Total Payments**
```sql
SUM(TRY_CAST(TotalPayments AS DECIMAL(18,2))) FROM dbo.ClaimLevelData WHERE {filters}
```
- Sum of insurance payments + patient payments

### 4. **Outstanding Balance**
```sql
SUM(TRY_CAST(TotalBalance AS DECIMAL(18,2))) FROM dbo.ClaimLevelData WHERE {filters}
```
- Sum of unpaid balances (insurance + patient)

### 5. **Collection Rate**
```
Numerator: SUM(AllowedAmount) WHERE ClaimStatus IN (
  'Fully Paid', 'Partially Paid', 'Patient Responsibility', 'Patient Payment'
)
Denominator: Total Charges
Calculation: (CollectionNumerator / TotalCharges) * 100
```
- Represents percentage of allowed amounts collected

### 6. **Denial Rate**
```
Numerator: SUM(ChargeAmount) WHERE ClaimStatus IN ('Fully Denied', 'Partially Denied')
Denominator: Total Charges
Calculation: (DenialNumerator / TotalCharges) * 100
```
- Represents percentage of charges denied

### 7. **Adjustment Rate**
```
Numerator: SUM(InsuranceAdjustments) WHERE ClaimStatus IN (
  'Complete W/O', 'Partially Adjusted'
)
Denominator: Total Charges
Calculation: (AdjustmentNumerator / TotalCharges) * 100
```
- Represents percentage adjusted/written off

### 8. **Outstanding Charge %**
```
Numerator: SUM(ChargeAmount) WHERE ClaimStatus = 'No Response'
Denominator: Total Charges
Calculation: (OutstandingNumerator / TotalCharges) * 100
```
- Represents percentage with no payer response

---

## Key Files Reference

### Data Capture
| File | Purpose |
|------|---------|
| `ClaimLineCSVDataCapture/Program.cs` | Worker service entry point |
| `ClaimLineCSVDataCapture/Services/CsvFileWatcherService.cs` | Monitors for new CSV files |
| `ClaimLineCSVDataCapture/Services/ClaimCsvProcessor.cs` | Parses claim CSV |
| `ClaimLineCSVDataCapture/Sql/{Lab}/04_{Lab}_Recreate_ClaimLevelDataTVP_And_UpdateSP.sql` | Bulk insert SP |

### Dashboard Display
| File | Purpose |
|------|---------|
| `LabMetricsDashboard/Controllers/DashboardController.cs` | Controller logic |
| `LabMetricsDashboard/Services/SqlDashboardRepository.cs` | SQL queries (lines 76-93 for KPIs) |
| `LabMetricsDashboard/Models/DashboardViewModel.cs` | View model |
| `LabMetricsDashboard/Views/Dashboard/Index.cshtml` | UI rendering |

### Database
| Object | Purpose |
|--------|---------|
| `dbo.ClaimLevelData` | Active claim data table |
| `dbo.LineLevelData` | CPT line items table |
| `dbo.ClaimLevelDataArchive` | Historical claim data |
| `dbo.LineClaimFileLogs` | File upload tracking |
| `dbo.usp_BulkInsertClaimLevelData` | Bulk insert stored procedure |

---

## Important Notes

1. **Data Refresh**: The dashboard shows data from the **most recent CSV upload**. When new CSV files are processed, the old data is archived and replaced.

2. **No Real-Time Updates**: This is **not a live connection** to a billing system. It's a snapshot based on weekly/periodic CSV exports.

3. **ClaimStatus Values**: The specific claim status strings must match exactly what's in your CSV files for the rate calculations to work correctly.

4. **Filters**: All filters (payer, panel, clinic, dates) are applied at the SQL query level in `SqlDashboardRepository.cs`.

5. **Performance**: The queries use `TRY_CAST` to handle potentially invalid numeric strings in the CSV data without crashing.

---

## Troubleshooting

### If KPIs show zero or incorrect values:

1. **Check CSV upload**: Verify files are being processed
   ```sql
   SELECT TOP 10 * FROM dbo.LineClaimFileLogs ORDER BY InsertedDateTime DESC
   ```

2. **Check ClaimLevelData**: Verify data exists
   ```sql
   SELECT COUNT(*), SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))) 
   FROM dbo.ClaimLevelData
   ```

3. **Check ClaimStatus values**: Verify status strings match expected values
   ```sql
   SELECT DISTINCT ClaimStatus, COUNT(*) 
   FROM dbo.ClaimLevelData 
   GROUP BY ClaimStatus
   ```

4. **Check data types**: Ensure amounts are numeric
   ```sql
   SELECT TOP 100 ChargeAmount, TotalPayments, TotalBalance 
   FROM dbo.ClaimLevelData 
   WHERE ISNUMERIC(ChargeAmount) = 0
   ```

---

## Summary

**Data Source**: CSV Files → Worker Service → SQL Server → Dashboard Repository → Controller → View

**No Stored Procedure for KPIs**: The KPI calculations are done via **inline SQL queries** in `SqlDashboardRepository.cs`, **not** via stored procedures. The only stored procedure involved is `usp_BulkInsertClaimLevelData` which handles the data **upload**, not the dashboard **display**.

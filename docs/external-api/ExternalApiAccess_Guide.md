# LRN Analytics API — integration guide

**Version:** 1.0 · **Status:** Current · **Audience:** External integrators · **Last reviewed:** 2026-08-16

> This markdown file is the **source of truth**. `LRN_Analytics_API_Guide.pdf` in this folder is the
> formatted copy sent to partners — regenerate it from here rather than editing it directly.
> Internal provisioning steps live in [ExternalApiAccess_Onboarding.md](ExternalApiAccess_Onboarding.md).

Read-only HTTP API for LRN reference data:

* **CPT & Panel Lookup** — CPT- and panel-level averages with mode and median rates, by payer and time window
* **Payer Policy Insurance Master** — the global payer policy catalogue
* **Insurance Payer Master** — lab-level payer records and their mapping to the global catalogue

All data endpoints are `GET` and return JSON. Every request needs a bearer token; get one from the
token endpoint first.

**Base URL** — `https://<host>/LRNApi` (confirm the exact host with your LRN contact).
All paths below are relative to it.

---

## 1. Authentication

You are issued a **client id** and **client secret**. Exchange them for a short-lived JWT, then send
that token on every data request. The secret itself is never sent to a data endpoint.

### Get a token

```
POST /api/auth/token
Content-Type: application/json

{
  "clientId": "your-client-id",
  "clientSecret": "your-client-secret"
}
```

`grantType` may be included as `"client_credentials"`; it is the only grant supported and may be omitted.

**200 OK**

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "expires_at_utc": "2026-08-14T16:05:36.999Z",
  "roles": ["ETL"]
}
```

| Status | Meaning |
|---|---|
| `400` | `clientId` or `clientSecret` missing, or an unsupported `grantType` |
| `401` | Client id or secret is not valid, or the client is disabled |
| `429` | Too many failed attempts. The client id is locked out for a short period |
| `500` | Server-side signing configuration problem — contact LRN support |

### Use the token

Send it as a bearer token on every data request:

```
Authorization: Bearer <access_token>
```

A missing, expired or invalid token returns **401** with a JSON body explaining which.

### Handling expiry

`expires_in` is seconds (default one hour). **Cache the token and reuse it until it is close to
expiry** — do not request a new one per call. Re-request when it has under ~5 minutes left, or when
a call returns `401`. Repeated failed token requests will lock the client id out temporarily.

### Worked example

```bash
TOKEN=$(curl -s -X POST https://<host>/LRNApi/api/auth/token \
  -H "Content-Type: application/json" \
  -d '{"clientId":"your-client-id","clientSecret":"your-client-secret"}' \
  | jq -r .access_token)

curl -s "https://<host>/LRNApi/api/analytics/cpt-lookup?windowType=YTD&pageSize=100" \
  -H "Authorization: Bearer $TOKEN"
```

```python
import requests

BASE = "https://<host>/LRNApi"

token = requests.post(f"{BASE}/api/auth/token", json={
    "clientId": "your-client-id",
    "clientSecret": "your-client-secret",
}, timeout=30).json()["access_token"]

headers = {"Authorization": f"Bearer {token}"}

page = 1
while True:
    r = requests.get(f"{BASE}/api/analytics/cpt-lookup",
                     params={"windowType": "YTD", "page": page, "pageSize": 500},
                     headers=headers, timeout=120)
    r.raise_for_status()
    body = r.json()
    for row in body["items"]:
        ...  # handle row
    if page >= body["totalPages"]:
        break
    page += 1
```

```csharp
using var http = new HttpClient { BaseAddress = new Uri("https://<host>/LRNApi/") };

var auth = await http.PostAsJsonAsync("api/auth/token", new
{
    clientId = "your-client-id",
    clientSecret = "your-client-secret"
});
var token = (await auth.Content.ReadFromJsonAsync<JsonElement>())
    .GetProperty("access_token").GetString();

http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
var rows = await http.GetFromJsonAsync<JsonElement>(
    "api/analytics/cpt-lookup?windowType=YTD&pageSize=500");
```

---

## 2. Conventions

**Paging.** List endpoints take `page` (1-based) and `pageSize`, and return an envelope:

```json
{ "items": [ ... ], "page": 1, "pageSize": 50, "totalCount": 1234, "totalPages": 25 }
```

`pageSize` is clamped to **10–1000** on every list endpoint — a larger value is silently reduced and
a smaller one silently raised to 10. Always page off `totalPages` rather than assuming a fixed count.

**Sorting.** `sortColumn` plus `sortDirection` (`asc` | `desc`). Only the columns listed per
endpoint are accepted; anything else falls back to that endpoint's default order.

**Filters.** All filter parameters are optional and combine with AND. Omitted or empty means
"no restriction" — omitting `labId` returns every lab.

**Nulls.** A `null` numeric means the value does not exist for that combination, not zero. Mode
and median rates come from different source tables than the averages and the payer names only
partly overlap, so a missing rate on a row that has averages is normal.

**Errors.** `401` unauthenticated, `403` the token's role cannot view this resource, `404` unknown
id, `500` server error (the response carries an `X-Correlation-ID` header — quote it to support).

**Dates** are ISO-8601 UTC.

---

## 3. CPT & Panel Lookup

Source: `CPTAverage` and `PanelAverage` (averages) joined to `LabModes` and `LabMedians` (mode and
median rates). Windows are `YTD`, `Rolling180`, `Rolling90`; omit `windowType` for all three.

### `GET /api/analytics/cpt-lookup`

CPT-level rows.

| Parameter | Type | Notes |
|---|---|---|
| `cptCode` | string | Exact CPT code |
| `panelName` | string | |
| `payer` | string | Matches the payer display name |
| `windowType` | string | `YTD` \| `Rolling180` \| `Rolling90` |
| `labId` | int | Omit for all labs |
| `sortColumn` | string | See below |
| `sortDirection` | string | `asc` \| `desc` |
| `page`, `pageSize` | int | Default `1` / `50`, max `1000` |

Sortable: `cptCode`, `panelName`, `payerDisplayName`, `windowType`, `labName`, `avgUnits`,
`avgChargeAmountPerUnit`, `avgAllowedAmountPerUnit`, `avgPaidAmountPerUnit`, `medianPaidAmount`,
`paidLineCount`, `totalLineCount`, `deniedLineCount`, `modeAllowedAmount`,
`modeInsurancePaymentAmount`, `allowedAmountPerUnitMode`, `insurancePaymentPerUnitMode`,
`medianAllowedAmount`, `medianInsurancePaymentAmount`, `allowedAmountPerUnitMedian`,
`insurancePaymentPerUnitMedian`, `denialRate`.

**Response** — the standard envelope plus a `summary` block, with `items` of:

| Field | Type | Notes |
|---|---|---|
| `labId`, `labName` | int, string | |
| `cptCode`, `panelName` | string | |
| `payerDisplayName`, `payerCommonCode`, `globalPayerId` | string, string, int | |
| `windowType`, `startDate`, `endDate`, `asOfDate` | string, date | Window the figures cover |
| `avgUnits` | int | |
| `avgChargeAmountPerUnit`, `avgAllowedAmountPerUnit`, `avgPaidAmountPerUnit`, `avgPatientResponsibilityPerUnit` | decimal | Per unit |
| `medianPaidAmount`, `p25PaidAmount`, `p75PaidAmount` | decimal | Paid distribution |
| `paidLineCount`, `totalLineCount`, `deniedLineCount`, `adjustedLineCount` | int | |
| `denialRate` | decimal | `deniedLineCount / totalLineCount` as a percentage, 1 dp; `null` when there are no lines |
| `modeAllowedAmount`, `modeInsurancePaymentAmount`, `allowedAmountPerUnitMode`, `insurancePaymentPerUnitMode` | decimal | From `LabModes` |
| `medianAllowedAmount`, `medianInsurancePaymentAmount`, `allowedAmountPerUnitMedian`, `insurancePaymentPerUnitMedian` | decimal | From `LabMedians` |
| `modeMatch`, `medianMatch` | string | **How the rate was resolved** — `"payer"` = this payer's own rate; `"lab"` = the lab-wide fallback because no row exists for this payer; `null` = no rate at all. Treat `"lab"` as materially less specific than `"payer"` |

`summary` carries `rowCount`, `avgAllowed`, `avgPaid` and `denialRate` computed over **every** row
matching the filters, not just the current page.

### `GET /api/analytics/panel-lookup`

Panel-level rows. Same parameters minus `cptCode`. Sortable: `panelName`, `payerId`,
`payerDisplayName`, `windowType`, `labName`, `avgChargeAmount`, `avgAllowedAmount`, `avgPaidAmount`,
`medianPaidAmount`, `p25PaidAmount`, `p75PaidAmount`, `paidLineCount`, `totalLineCount`,
`deniedLineCount`, `modeAllowedAmount`, `modeInsurancePaymentAmount`, `modeCptCount`, `denialRate`.

Items carry `labId`, `labName`, `panelName`, `payerId`, `payerDisplayName`, the window fields,
`avgChargeAmount`, `avgAllowedAmount`, `avgPaidAmount`, `avgPatientResponsibility`,
`medianPaidAmount`, `p25PaidAmount`, `p75PaidAmount`, the four line counts, `denialRate`,
`modeAllowedAmount`, `modeInsurancePaymentAmount`, `modeCptCount` and `modeMatch`.

> `LabModes` is CPT-level, so panel mode figures are the **average of the per-CPT modes** across the
> panel. `modeCptCount` says how many CPTs that average covers — a value of 1 is not a broad panel rate.

### `GET /api/analytics/cpt-lookup/windows` · `GET /api/analytics/panel-lookup/windows`

Every window (`YTD`, `Rolling180`, `Rolling90`) for one combination, for side-by-side comparison.
Takes the same filters; returns a plain array of the row shape above, not an envelope.

### `GET /api/analytics/cpt-lookup/options` · `GET /api/analytics/panel-lookup/options`

Autocomplete values. `field` = `cptCode` | `panelName` | `payer` (`panelName` | `payer` on the panel
endpoint), plus optional `term` and `labId`. Returns a JSON array of strings.

### `GET /api/analytics/lookup-labs`

Labs that have averages data: `[{ "labId": 4, "labName": "Cove" }, ...]`.

> `labName` is **not unique** — two different `labId`s can both be named "NorthWest". Always key on
> `labId` and treat the name as a label.

### Lab Modes and Lab Medians

`GET /api/analytics/lab-modes` and `GET /api/analytics/lab-medians` expose the rate tables directly.
Filters: `payerName`, `panelName`, `cptCode`, `labId`, `sortColumn`, `sortDirection`, `page`,
`pageSize` (default 25). `GET /api/analytics/labs` lists the labs present in those two tables.

Rows carry `payerName`, `panelName`, `cptCode`, `allowedAmount`, `insurancePayment`,
`distinctAllowedPaymentCount`, `labName`, plus `modeAllowedAmount`, `modeInsurancePaymentAmount`,
`allowedAmountPerUnitMode`, `insurancePaymentPerUnitMode` (modes) or the `median*` equivalents.

---

## 4. Payer Policy Insurance Master

The **global** payer catalogue. Requires a role with policy view rights.

### `GET /api/master-values/payer-policy-insurance`

| Parameter | Type | Notes |
|---|---|---|
| `search` | string | Free text across the main name/code columns |
| `globalPayerCode`, `payerName`, `payerShortCode`, `planType`, `payerState` | string | |
| `globalPayerId` | int | |
| `isActive` | string | |
| `sortColumn`, `sortDirection` | string | See below |
| `page`, `pageSize` | int | Default `1` / `25` |

Sortable: `globalPayerId`, `globalPayerCode`, `payerGroupCode`, `benefitAdminCode`,
`benefitAdministrator`, `payerNameRaw` (or `payerName`), `payerNameNormalized`, `payerShortCode`,
`planType`, `payerState`, `isActive`, `remarks`, `payerFamily`, `payerFamilySource`.
Default order is `ppInsuranceMasterId` descending.

Standard envelope; `items` of:

| Field | Type |
|---|---|
| `ppInsuranceMasterId` | int (primary key) |
| `globalPayerId` | int |
| `globalPayerCode` | string (always present) |
| `payerGroupCode` | int |
| `benefitAdminCode`, `benefitAdministrator` | string |
| `payerNameRaw`, `payerNameNormalized`, `payerShortCode` | string |
| `planType`, `payerState`, `isActive`, `remarks` | string |
| `payerFamily`, `payerFamilySource` | string (brand-family classification) |

### `GET /api/master-values/payer-policy-insurance/{id}`

One record by `ppInsuranceMasterId`. `404` when it does not exist.

---

## 5. Insurance Payer Master

**Lab-level** payer records and how each maps to the global catalogue. Requires a role with lab view
rights.

### `GET /api/master-values/insurance-payers`

| Parameter | Type | Notes |
|---|---|---|
| `search` | string | Free text |
| `labId` | int | |
| `payerCode`, `payerName` | string | |
| `globalPayerId` | int | |
| `isActive` | string | |
| `mappingStatus` | string | `Mapped` \| `Unmapped` \| `Unmapped - Pending Review` \| `No Match Found` |
| `sortColumn`, `sortDirection` | string | See below |
| `page`, `pageSize` | int | Default `1` / `25` |

Sortable: `payerCode`, `payerNameRaw`, `payerNameNormalized`, `globalPayerID`, `payerGroupCode`,
`payerCommonCode`, `parent`, `planType`, `mcoType`, `payerState`, `isActive`, `benefitAdminCode`,
`benefitAdministrator`, `labName`, `labState`, `labStateCode`, `remarks`, `mappingStatus`,
`mappedSource`, `mappedBy`, `mappedOn`. Default order is `labInsuranceMasterId` descending.

Standard envelope; `items` of:

| Field | Type | Notes |
|---|---|---|
| `labInsuranceMasterId` | int | Primary key |
| `payerCode`, `payerNameRaw`, `payerNameNormalized` | string | |
| `globalPayerID` | int | Link to the policy master. **`null` means unmapped** |
| `payerGroupCode`, `payerCommonCode`, `parent` | string | |
| `planType`, `mcoType`, `payerState`, `isActive` | string | |
| `benefitAdminCode`, `benefitAdministrator`, `remarks` | string | |
| `labName`, `labId`, `labState`, `labStateCode` | string, int | |
| `mappingStatus`, `mappedBy`, `mappedSource`, `mappedOn` | string, date | `mappedSource` is `System` or `User` |

Join `globalPayerID` here to `globalPayerId` on the policy master to resolve a lab payer to its
global record.

### `GET /api/master-values/insurance-payers/{id}`

One record by `labInsuranceMasterId`. `404` when it does not exist.

### `GET /api/master-values/insurance-payers/labs`

Labs present in the master: `[{ "labId": 4, "labName": "Cove" }, ...]`.

---

## 6. Practical notes

**Access is read-only.** Standard external credentials are issued with a view-only role. `POST`,
`PUT` and import endpoints exist on these routes for internal use and will return **403**.

**Lab scope.** Your token may name specific labs, but the endpoints above do not currently filter
by it — omitting `labId` returns rows for every lab. Pass `labId` explicitly if you only want yours.

**Volume.** Unfiltered CPT lookup spans every lab, payer and window and is large. Filter by
`labId` and `windowType` where you can, use `pageSize=500`–`1000`, and page sequentially rather
than in parallel.

**Timeouts.** Broad queries can take tens of seconds. Use a client timeout of at least 120 seconds
and retry on `500`/`503` with exponential backoff. Do not retry `400`, `401` or `403`.

**Stability.** Fields may be **added** to responses without notice — deserialize tolerantly and
ignore unknown properties. Removals or renames will be announced in advance.

**Support.** Quote the `X-Correlation-ID` response header, the endpoint, the exact query string and
the UTC timestamp.

---

## Endpoint summary

| Method | Path | Returns |
|---|---|---|
| `POST` | `/api/auth/token` | Bearer token |
| `GET` | `/api/analytics/cpt-lookup` | Paged CPT rows + summary |
| `GET` | `/api/analytics/cpt-lookup/windows` | All windows for one combination |
| `GET` | `/api/analytics/cpt-lookup/options` | Autocomplete values |
| `GET` | `/api/analytics/panel-lookup` | Paged panel rows + summary |
| `GET` | `/api/analytics/panel-lookup/windows` | All windows for one combination |
| `GET` | `/api/analytics/panel-lookup/options` | Autocomplete values |
| `GET` | `/api/analytics/lookup-labs` | Labs with averages data |
| `GET` | `/api/analytics/lab-modes` | Paged mode rates |
| `GET` | `/api/analytics/lab-medians` | Paged median rates |
| `GET` | `/api/analytics/labs` | Labs in the rate tables |
| `GET` | `/api/master-values/payer-policy-insurance` | Paged policy payers |
| `GET` | `/api/master-values/payer-policy-insurance/{id}` | One policy payer |
| `GET` | `/api/master-values/insurance-payers` | Paged lab payers |
| `GET` | `/api/master-values/insurance-payers/{id}` | One lab payer |
| `GET` | `/api/master-values/insurance-payers/labs` | Labs in the payer master |

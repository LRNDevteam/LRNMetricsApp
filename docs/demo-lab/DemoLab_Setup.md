# LRNLabDemo — demo lab setup

A demo lab for the product team, cloned from **PCRLabsofAmerica** and de-identified.

- **Lab key:** `LRNLabDemo`
- **LabId:** `99` (reserved for demo/training labs — real labs are 2–24)
- **Database:** `LRNLabDemo` on the same instance as the PCR database

---

## What is already done (in the repo)

These are committed; they ship with the next deploy.

| Change | File |
|---|---|
| Lab registered in the dashboard | `LabMetricsDashboard/appsettings.json` — `LabConfig.Labs`, `LabConfig.LabsID` |
| Lab registered in the API | `LRN.ReportsApi/appsettings.json` — same two keys |
| Lab registered in the report worker | `LRN.ReportWorker/appsettings.json` — `ReportWorker.Labs` |
| Demo lab hidden from admins by default | new `LabConfig.DemoLabs` key + `LabConfigOptions.VisibleLabs()` |
| No "report not generated" alerts | `ReportBoard.NoMissingReportWarning` |
| Same reports offered as PCR | `ReportAvailability.Reports."Coding Validation"` |
| Clone / de-identify / register scripts | `LabMetricsDashboard/SqlScripts/Demo_LRNLabDemo_0*.sql` |
| Lab config template | `docs/demo-lab/LRNLabDemo.json.template` |

### About the "hidden" behaviour

`LabConfig.DemoLabs` takes any lab out of the *"admins see every lab"* shortcut. A demo lab
now shows up **only for users explicitly assigned it** in Admin → Assign User Labs — admins
included. Applied in four places, which is everywhere the shortcut existed: the navbar lab
picker, the static menu fallback, the Report Control Board, and the JWT handed to the Denial
Workflow React app.

To retire the demo lab later, delete `"LRNLabDemo"` from `DemoLabs` to make it a normal lab,
or from `LabConfig.Labs` / `LabsID` to remove it entirely.

---

## What you need to do

### 1. Clone the database

Run **`Demo_LRNLabDemo_01_CloneDatabase.sql`** on the instance hosting the PCR database, as a
login with `dbcreator` and backup rights.

Check the four settings at the top first — `@SourceDb` (defaults to `PCRLOA_LRN`), `@DemoDb`,
`@BackupFolder`, `@DataFolder`. The backup folder must be writable **by the SQL Server service
account**, not by you.

It refuses to overwrite an existing demo database until you set
`@IAmSureIWantToOverwriteTheDemo = 1`. That is also the **refresh** path: re-run it any time
the product team wants a clean demo, then re-run step 2.

#### On SQL Server Express

Express works, with two consequences the script handles for you:

- **No backup compression.** It is an Enterprise/Standard feature; asking for it on Express
  fails the whole backup with `Msg 1844`. The script detects the edition and omits it, so
  expect a full-size `.bak` — check you have the disk space for it.
- **10 GB data cap per database** (log excluded). A restore that would exceed it fails partway
  through, which on a large lab is a long wait for a dead end. The script measures the source
  first and stops with the actual size if it will not fit. If you hit that: clone onto a
  **Developer edition** instance instead — it is free and has no size cap — or build the demo
  from a trimmed subset rather than a full clone.

The script now stops at the **first** failure. If you see a single error and nothing else
attempted, that error is the real one.

> The restored copy is a byte-for-byte clone and **still contains real patient data** until
> step 2 has run. Do not hand out the demo account in between.

### 2. De-identify

Run **`Demo_LRNLabDemo_02_Deidentify.sql`**. It opens with `USE LRNLabDemo;` so it targets the
right database regardless of what your SSMS dropdown says — if you cloned to a different name,
change that one line. A guard still refuses any database whose name lacks "Demo".

Run it once with `@Apply = 0` (the default). It reports every column it matched as a patient
identifier and changes nothing — **read that list**. If a column you expected is missing, add
its name to the `#PhiColumn` table at the top. Then set `@Apply = 1` and run again.

What it does:

- **Patient ids, MRNs, member/subscriber ids, policy numbers** → a deterministic pseudonym
  derived from the original. The same patient gets the same fake id in every table, so claims,
  line items, tasks, notes and escalations still join up and the demo tells a coherent story.
- **Names** → `Demo Patient <n>`, consistent across tables the same way.
- **Dates of birth** → shifted by a fixed offset and flattened to the 1st of the month. A DOB
  held as *text* rather than a date type (common in these CSV-loaded tables) is reported as
  `DOBTEXT` and set to a fixed placeholder instead, since there is no reliable format to shift.

All replacement values are length-clamped to the column, so a narrow `char(8)` date column
truncates rather than failing the update.

Watch for `!! FAILED` lines in the output — a column can refuse the rewrite (a unique index the
pseudonym collides with, for example). The script keeps going deliberately, so one awkward
column does not leave everything else identifiable, but you must go back and handle those by hand.

### 3. Lab config file

All three apps now read the **same** folder — the dashboard and API moved off `C:\LRN-Files\...`
onto the worker's E: drive in commit `e74e276`, so there is one file to place, not two:

```
E:\LRN-Data\PayerPolicy_v2\2026\ReportsDashboard\Application\Configs\LRNLabDemo.json
```

Copy the real `PCRLabsofAmerica.json` in that folder to `LRNLabDemo.json`, then change only the
keys listed in `LRNLabDemo.json.template` — rename the root property to `LRNLabDemo`, set
`DbLabName`, repoint `DbConnectionString` at the demo database, and **repoint every file path
at a demo folder**.

> `RcmWatcherService` reads this folder too, but has its own explicit `Labs` list that does not
> include `LRNLabDemo`, so it will ignore the file.

> Starting from PCR's file rather than the template is deliberate: the demo then inherits PCR's
> exact feature flags and report rules, so it behaves identically in the UI.

> The paths matter as much as the connection string. If they still point at PCR's folders, the
> demo reads PCR's live CSVs and Excel exports and you are showing production data again — the
> database scrub does not help you there. Copy the files across once into a demo folder.

### 4. Register the lab

Run **`Demo_LRNLabDemo_03_RegisterLab.sql`** — it opens with `USE LRNMaster;`. It inserts
LabId 99 explicitly so the id matches what appsettings expects, and stops with a clear error if
99 is already taken (in which case pick another reserved id and change **both** appsettings
files to match).

`dbo.Labs` predates `LabMaster_CreateTable.sql` on some servers, so the script inspects the
table before writing to it: `IDENTITY_INSERT` is toggled only if `LabId` really is an identity
column, and the audit columns (`CreatedBy` / `CreatedDate` / `ModifiedBy` / `ModifiedDate`) are
written only if they exist. It prints what it found, so a surprising schema is visible rather
than silent.

### 5. Demo users

In the dashboard UI, so passwords hash correctly:

1. **Admin → Manage Users** — create the demo accounts.
2. **Admin → Assign User Role** — give them whatever role you want the demo to show. `Lab User`
   is the read-only role if you want the demo to be look-but-don't-touch; `AR Manager` if you
   want the product team to demo assignment and workflow actions.
3. **Admin → Assign User Labs** — assign `LRNLabDemo`. **Without this nobody sees the lab at
   all, including admins** — that is the hiding behaviour working as intended.

Anyone who should demo the lab needs step 3 explicitly, even if they are an Admin.

### 6. Deploy and restart

Deploy the updated `appsettings.json` files, then recycle:

- LabMetricsDashboard (dashboard)
- LRN.ReportsApi
- LRN.ReportWorker service

Lab config files reload on change, but `LabConfig:Labs` / `LabsID` / `DemoLabs` in appsettings
are read at startup — a restart is required.

---

## Verify

1. Sign in as a demo user → the header shows `LRNLabDemo` (as a highlighted pill, not a
   dropdown, if it is their only lab).
2. Sign in as an admin **not** assigned the demo lab → `LRNLabDemo` must **not** appear in the
   lab picker or on the Report Control Board.
3. Open a claim on the Denial Dashboard as the demo user → patient names read `Demo Patient …`
   and ids read `DP……`.
4. Spot-check that claim counts and dollar totals still look like a real lab — if a report is
   empty, the usual cause is `DbLabName` in the lab config not matching the `LabName` values
   inside the cloned data.

---

## Residual risk — read before demoing externally

The scrub removes **direct** identifiers: names, patient/member/subscriber ids, policy numbers
and dates of birth. Two things it deliberately does not do:

- **Service, billing, check and posting dates are left alone.** Shifting them would move every
  claim out of the aging buckets and reporting windows the demo exists to show. Dates of service
  are quasi-identifiers, so what remains is a claims data set rather than identifiable patient
  records — but this is **not** a formal HIPAA Safe Harbor de-identification.
- **Free-text fields are not scrubbed.** Reviewer comments, note text and escalation comments can
  contain anything a human typed, including names and phone numbers. Spot-check
  `DenialClaimNotes`, `DenialClaimEscalations` and reviewer comment columns before any demo
  outside the company.

Payer names, clinic names, provider names and sales rep names also survive the scrub. That is
usually what you want in a demo — but it does identify **PCR's** business relationships, which
may matter if you are demoing to one of their competitors.

If the demo is going to prospects or conferences, get this signed off by whoever owns HIPAA
compliance rather than treating the scrub as sufficient on its own.

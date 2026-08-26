"""Convert legacy Three-Pillar resultSets JSON to titled charts (UI graph titles)."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(r"e:\LRN-Data\LRN.AzBlobSync")


def project(rows: list[dict], *cols: str) -> list[dict]:
    if not rows or not cols:
        return rows
    out = []
    for row in rows:
        lower = {k.lower(): (k, v) for k, v in row.items()}
        copy = {}
        for col in cols:
            hit = lower.get(col.lower())
            if hit:
                copy[hit[0]] = hit[1]
        out.append(copy)
    return out


def chart(title: str, subtitle: str, scope: str, rows: list[dict]) -> dict:
    return {
        "graphTitle": title,
        "subtitle": subtitle,
        "scope": scope,
        "rowCount": len(rows),
        "rows": rows,
    }


def set_or_empty(sets: list, index: int) -> list[dict]:
    if 0 <= index < len(sets) and isinstance(sets[index], list):
        return sets[index]
    return []


def build_lis(sets: list, trailing: int, scope: str) -> list[dict]:
    monthly = set_or_empty(sets, 0)
    backlog_summary = set_or_empty(sets, 1)
    backlog_buckets = set_or_empty(sets, 2)
    funnel = set_or_empty(sets, 3)
    return [
        chart(
            "Monthly Collected Sample Volume",
            "Total Samples trend · Check #1",
            scope,
            project(monthly, "MonthLabel", "TotalSamples", "SortYear", "SortMonth"),
        ),
        chart(
            f"Total Samples & % Resulted — Last {trailing} Months",
            "Bars = volume · % Resulted (right axis)",
            scope,
            project(monthly, "MonthLabel", "TotalSamples", "Resulted", "PctResulted"),
        ),
        chart(
            "Sample-to-Claim Funnel (Full Period)",
            "Collected → Resulted → Billed over the selected comparable window",
            scope,
            project(
                funnel,
                "Collected",
                "Resulted",
                "BilledToInsurance",
                "PctResulted",
                "PctBilledOfCollected",
                "PctBilledOfResulted",
            ),
        ),
        chart(
            "Backlog Age — Resulted Samples Never Entered in PMS",
            "Check #2 · open Resulted / Not-in-AMD backlog as of WeekRange end",
            scope,
            backlog_summary,
        ),
        chart(
            "Backlog Age Buckets",
            "0–7 / 8–14 / 15–30 / 31–60 / 60+",
            scope,
            project(backlog_buckets, "AgeBucket", "SortOrder", "SampleCount"),
        ),
        chart(
            "% of Resulted Samples Billed to Insurance",
            "Resulted → billed pipeline rate by month",
            scope,
            project(monthly, "MonthLabel", "Resulted", "BilledToInsurance", "PctBilledOfResulted"),
        ),
        chart(
            "Not Resulted Samples — Monthly Trend",
            "Latest month often Check #1 partial-period spike",
            scope,
            project(monthly, "MonthLabel", "NotResulted"),
        ),
        chart(
            "Self Pay % vs Client Bill % of Total Samples",
            "Check #6 status-transition",
            scope,
            project(
                monthly,
                "MonthLabel",
                "TotalSamples",
                "SelfPay",
                "ClientBill",
                "SelfPayPct",
                "ClientBillPct",
            ),
        ),
        chart(
            "LIS Monthly Detail",
            "Month-by-month breakdown for the selected comparable window",
            scope,
            monthly,
        ),
    ]


def build_pms(sets: list, scope: str) -> list[dict]:
    reconciliation = set_or_empty(sets, 0)
    fully_adjusted = set_or_empty(sets, 1)
    write_off = set_or_empty(sets, 2)
    fully_paid = set_or_empty(sets, 3)
    ib = set_or_empty(sets, 4)
    panel_avg = set_or_empty(sets, 5)
    panel_mom = set_or_empty(sets, 6)
    maturity = set_or_empty(sets, 7)
    denial = set_or_empty(sets, 8)
    top_denial = set_or_empty(sets, 9)
    return [
        chart(
            "1. Billed Claims Reconciliation — LIS vs PMS",
            "Reconciliation Gap = PMS Billed Claims − LIS Billed to Insurance",
            scope,
            project(reconciliation, "MonthLabel", "PmsBilled", "LisBilledToInsurance", "Gap"),
        ),
        chart(
            "2. Fully Adjusted % of Billed Claims (PMS)",
            "% Fully Adjusted = Fully Adjusted ÷ Billed Claims × 100",
            scope,
            project(fully_adjusted, "MonthLabel", "BilledClaims", "FullyAdjusted", "PctFullyAdjusted"),
        ),
        chart(
            "3. Top Write-Off Reason Codes",
            "Reason-code counts from BTWOSummary",
            scope,
            project(write_off, "TransactionCodeCombined", "MatchingCount"),
        ),
        chart(
            "4. Insurance Balance % of Billed Claims — Headline PMS Finding",
            "% IB = IB claims ÷ Billed × 100 · composition Fully Denied / No Response / Partially Denied",
            scope,
            project(
                ib,
                "MonthLabel",
                "BilledClaims",
                "InsuranceBalanceClaims",
                "PctInsuranceBalance",
                "FullyDeniedClaims",
                "NoResponseClaims",
                "PartiallyDeniedClaims",
                "InsuranceBalanceAmt",
            ),
        ),
        chart(
            "4b. Insurance Balance Composition (% of open claims)",
            "Fully Denied / No Response / Partially Denied share of open",
            scope,
            project(
                ib,
                "MonthLabel",
                "FullyDeniedClaims",
                "NoResponseClaims",
                "PartiallyDeniedClaims",
                "InsuranceBalanceClaims",
            ),
        ),
        chart(
            "5. Fully Paid % of Billed Claims (PMS)",
            "% Fully Paid = Fully Paid ÷ Billed Claims × 100",
            scope,
            project(fully_paid, "MonthLabel", "BilledClaims", "FullyPaid", "PctFullyPaid"),
        ),
        chart(
            "6. Panel — Avg Allowed vs Avg Paid",
            "Claim-level supplement by panel / DOS month",
            scope,
            project(
                panel_avg,
                "Panelname",
                "MonthLabel_DOS",
                "AvgAllowed",
                "AllowedClaimCount",
                "AvgPaidByPaymentDate",
                "PaidClaimCount",
            ),
        ),
        chart(
            "Avg $ Paid per Claim — Panel (MOM by DOS)",
            "Panel × payer month-over-month",
            scope,
            panel_mom,
        ),
        chart(
            "DOS-Cohort Maturity Curve",
            "Pct allowed paid by days since DOS",
            scope,
            project(maturity, "DOSMonthLabel", "DaySinceDOS", "PctAllowedPaid"),
        ),
        chart(
            "Denial Rate by Carrier — Ratio-Driver Breakdown",
            "Denied allowed ÷ total allowed",
            scope,
            project(denial, "PayerName", "TotalAllowed", "DeniedAllowed", "DenialRatePct"),
        ),
        chart(
            "Fastest-Escalating Denial Reasons by Payer — MOM",
            "Top denial reasons by payer / month",
            scope,
            project(top_denial, "PayerName", "DenialCode", "MonthLabel", "DenialCount"),
        ),
    ]


def build_cash(sets: list, scope: str) -> list[dict]:
    headline = set_or_empty(sets, 0)
    write_off = set_or_empty(sets, 1)
    return [
        chart(
            "1. Total Billed $ — Monthly Trend",
            "Monthly $ Billed = SUM(ChargeAmount) WHERE Billed · GROUP BY DOS month",
            scope,
            project(headline, "MonthLabel", "TotalBilledAmt"),
        ),
        chart(
            "2. Partially Paid $ — Monthly Trend",
            "Partially Paid $ ÷ Total Billed $ × 100",
            scope,
            project(headline, "MonthLabel", "PartiallyPaidAmt", "PctPartiallyPaidOfBilled", "TotalBilledAmt"),
        ),
        chart(
            "3. Collection Rate — Insurance Payment / Total Billed",
            "Fully Paid Ins $ ÷ Total Billed $ × 100",
            scope,
            project(
                headline,
                "MonthLabel",
                "InsurancePaymentFullyPaid",
                "TotalBilledAmt",
                "CollectionRatePct",
            ),
        ),
        chart(
            "4a. % Insurance Balance $ of Total Billed",
            "IB $ ÷ Total Billed $ × 100",
            scope,
            project(
                headline,
                "MonthLabel",
                "InsuranceBalanceAmt",
                "PctInsuranceBalanceOfBilled",
                "TotalBilledAmt",
            ),
        ),
        chart(
            "4b. Insurance Balance $ Composition",
            "Fully Denied / No Response / Partially Denied share of open IB $",
            scope,
            project(
                headline,
                "MonthLabel",
                "FullyDeniedIBAmt",
                "NoResponseIBAmt",
                "PartiallyDeniedIBAmt",
                "InsuranceBalanceAmt",
                "NoResponseSharePct",
            ),
        ),
        chart(
            "5. Patient Write-Off vs Patient Balance",
            "Patient WO $ / Patient Balance $ / Patient Payment $",
            scope,
            project(
                headline,
                "MonthLabel",
                "PatientWOAmt",
                "PatientBalanceAmt",
                "PatientPaymentAmt",
                "WriteOffRatioPct",
                "PatientCollectionRatePct",
            ),
        ),
        chart(
            "6. Fully Adjusted $ — Write-Off Reason Pareto",
            "Write-off reason codes from BTWOSummary",
            scope,
            project(write_off, "TransactionCodeCombined", "MatchingCount"),
        ),
        chart(
            "Cash monthly detail",
            "Full monthly cash headline metrics for the selected comparable window",
            scope,
            headline,
        ),
    ]


SECTION = {
    "LIS": "Pillar 1 — Pipeline Health (LIS Breakdown)",
    "PMS": "Pillar 2 — Revenue Realization (PMS)",
    "Cash": "Pillar 3 — Leakage & Risk (Cash)",
}


def convert(path: Path) -> None:
    data = json.loads(path.read_text(encoding="utf-8"))
    pillar = data.get("pillar", path.stem)
    trailing = int(data.get("trailingMonths") or 12)
    day = data.get("dayWindow")
    scope = data.get("scope") or f"Last {trailing} months · DayWindow 1–{day}"
    sets = data.get("resultSets") or []

    if pillar == "LIS":
        charts = build_lis(sets, trailing, scope)
    elif pillar == "PMS":
        charts = build_pms(sets, scope)
    else:
        charts = build_cash(sets, scope)

    out = {
        "pillar": pillar,
        "pillarSection": SECTION.get(pillar, pillar),
        "labName": data.get("labName"),
        "weekFolder": data.get("weekFolder"),
        "asOfDate": data.get("asOfDate"),
        "dayWindow": data.get("dayWindow"),
        "trailingMonths": trailing,
        "scope": scope,
        "generatedUtc": data.get("generatedUtc"),
        "storedProcedure": data.get("storedProcedure"),
        "elapsedMs": data.get("elapsedMs"),
        "charts": charts,
    }
    path.write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(f"Converted {path.name}: {len(charts)} charts with graphTitle")


def main() -> None:
    for name in ("LIS.json", "PMS.json", "Cash.json"):
        p = ROOT / name
        if not p.exists():
            print(f"Missing: {p}")
            continue
        convert(p)


if __name__ == "__main__":
    main()

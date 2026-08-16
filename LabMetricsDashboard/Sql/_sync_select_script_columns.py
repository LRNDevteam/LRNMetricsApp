# Sync lab Details SPs + C# catalog from Sql/Select_Script.
# Skip only ingest/file columns. Everything else (including LabID) stays in the SP.
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SELECT_DIR = ROOT / "Sql" / "Select_Script"
SP_DIR = ROOT / "Sql" / "ClaimLineDetails_SPs"
CATALOG = ROOT / "Services" / "LabClaimLineColumnCatalog.cs"

SKIP = {
    "RecordId", "FileLogId", "RunId", "WeekFolder",
    "SourceFullPath", "FileName", "FileType", "RowHash",
}

LABS = {
    "Augustus": ("Augustus_ClaimLevelData.sql", "Augustus_LineLevelData.sql"),
    "BeechTree": ("BeechTree_ClaimLevelData.sql", "BeechTree_LineLevelData.sql"),
    "Certus": ("Certus_ClaimLevel Data.sql", "Certus_LineleveData.sql"),
    "Cove": ("Cove_ClaimLevelData.sql", "Cove_LineLevel.sql"),
    "Elixir": ("Elixir_ClaimLevelData.sql", "Elixir_LineLevelData.sql"),
    "InHealth": ("InHealth ClaimLevel Dataa.sql", "InHealthDTRLRN_LineLevel.sql"),
    "NorthWest": ("NorthWest_ClaimLevel.sql", "NorthWest_LineLevel.sql"),
    "PCRAL": ("PCRAL_ClaimLevelData.sql", "PCRAL_LineLevel.sql"),
    "PCRCO": ("PCRCO_ClaimLevel.sql", "PCRCO_LineLevel.sql"),
    "PCRLOA": ("PCRLOA_ClaimLevel.sql", "PCRLOA_LineLevel.sql"),
    "PhiLife": ("Philife_ClaimLevel.sql", "PhiLife_LineLevel.sql"),
    "RisingTides": ("Rishing_Tides_ClaimLevel.sql", "Rishing_Tides_LineLevel.sql"),
}

TRIM = {
    "PayerName", "PayerType", "ClinicName", "Panelname", "PanelName",
    "ClaimStatus", "PayStatus", "SalesRepname", "SalesRepName", "CPTCode",
}
SKIP_MONEY = ("percent", "count", "days", "entered", "posted", "date")


def parse_cols(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8-sig")
    m = re.search(r"SELECT\s+(.*?)\s+FROM\s+", text, re.S | re.I)
    if not m:
        raise SystemExit(f"No SELECT in {path.name}")
    cols = re.findall(r"\[([^\]]+)\]", m.group(1))
    out = [c for c in cols if c not in SKIP]
    if not out:
        raise SystemExit(f"No business columns in {path.name}")
    return out


def is_money(col: str) -> bool:
    cl = col.lower()
    if any(s in cl for s in SKIP_MONEY):
        return False
    if col in ("Units", "ServiceUnit"):
        return False
    return (
        "Amount" in col
        or "Balance" in col
        or "Payment" in col
        or "Charge" in col
        or col.endswith("WO")
        or col in ("ProcTotalBal", "ClaimAmount", "ActualPayment", "BilledAmounts")
    )


def bracket(col: str) -> str:
    return "[" + col.replace("]", "]]") + "]"


def format_col(col: str, is_line: bool) -> str:
    b = bracket(col)
    if col in ("ClaimID", "PatientID") or (is_line and col in ("CPTCode", "Modifier")):
        return (
            f"CASE WHEN {b} LIKE '%.00' THEN LEFT({b}, LEN({b})-3) "
            f"ELSE ISNULL(LTRIM(RTRIM({b})),'') END AS {b}"
        )
    if is_line and col == "Units":
        return f"ISNULL(FLOOR(TRY_CAST({b} AS DECIMAL(18,2))), 0) AS {b}"
    if is_money(col):
        return f"ISNULL(TRY_CAST({b} AS DECIMAL(18,2)), 0) AS {b}"
    if col in TRIM:
        return f"ISNULL(LTRIM(RTRIM({b})),'') AS {b}"
    return b


def select_sql(cols: list[str], is_line: bool) -> str:
    return "            " + ",\n            ".join(format_col(c, is_line) for c in cols)


def replace_select(text: str, kind: str, cols: list[str], is_line: bool) -> str:
    table = "LineLevelData" if is_line else "ClaimLevelData"
    pattern = (
        rf"(    /\* ==== .*? {kind} columns.*?==== \*/\n    SELECT\n)"
        rf"(.*?)"
        rf"(\n    FROM dbo\.{table})"
    )
    m = re.search(pattern, text, re.S)
    if not m:
        raise SystemExit(f"Could not find {kind} SELECT block")
    return text[: m.start(2)] + select_sql(cols, is_line) + text[m.end(2) :]


def csharp_array(cols: list[str], indent: str = "            ") -> str:
    lines = [f"{indent}["]
    row: list[str] = []
    for c in cols:
        row.append(f'"{c}"')
        if len(row) == 6:
            lines.append(indent + "    " + ", ".join(row) + ",")
            row = []
    if row:
        lines.append(indent + "    " + ", ".join(row))
    else:
        lines[-1] = lines[-1].rstrip(",")
    lines.append(indent + "]")
    return "\n".join(lines)


def replace_dict(text: str, name: str, labs: dict[str, list[str]]) -> str:
    m = re.search(
        rf"(    private static readonly Dictionary<string, string\[\]> {name} = new\(StringComparer.OrdinalIgnoreCase\)\n    \{{\n)(.*?)(\n    \}};)",
        text,
        re.S,
    )
    if not m:
        raise SystemExit(f"Could not find {name}")
    parts = []
    for lab, cols in labs.items():
        parts.append(f'        ["{lab}"] =\n{csharp_array(cols)},')
    body = "\n".join(parts)
    return text[: m.start(2)] + body + text[m.end(2) :]


def main() -> None:
    claim_by_lab: dict[str, list[str]] = {}
    line_by_lab: dict[str, list[str]] = {}
    for lab, (claim_file, line_file) in LABS.items():
        claim_cols = parse_cols(SELECT_DIR / claim_file)
        line_cols = parse_cols(SELECT_DIR / line_file)
        claim_by_lab[lab] = claim_cols
        line_by_lab[lab] = line_cols
        sp_path = SP_DIR / f"{lab}_Details.sql"
        text = sp_path.read_text(encoding="utf-8")
        text = replace_select(text, "ClaimLevel", claim_cols, False)
        text = replace_select(text, "LineLevel", line_cols, True)
        sp_path.write_text(text, encoding="utf-8")
        print(f"{lab:12} claim {len(claim_cols):3}  line {len(line_cols):3}  "
              f"+claim {[c for c in claim_cols if c in ('LabID','LabName','SourceFileID','IngestedOn','CsvRowHash','ClaimUID','AgingDOE','AgingDOS','PanelNameLIS','PanelNameBasedOnCPT')]}")

    cat = CATALOG.read_text(encoding="utf-8")
    cat = replace_dict(cat, "ClaimByLab", claim_by_lab)
    cat = replace_dict(cat, "LineByLab", line_by_lab)
    CATALOG.write_text(cat, encoding="utf-8")
    print("updated catalog")


if __name__ == "__main__":
    main()

"""Generate BeechTree Three-Pillar Foundry Agents plan PDF (Calibri / Segoe UI)."""
from __future__ import annotations

from reportlab.lib.colors import HexColor, white
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Flowable,
    Frame,
    NextPageTemplate,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.platypus.tableofcontents import TableOfContents

NAVY = HexColor("#0F2C4C")
TEAL = HexColor("#1A6B7A")
GOLD = HexColor("#C4A35A")
SLATE = HexColor("#334155")
MUTED = HexColor("#64748B")
RULE = HexColor("#CBD5E1")
ROW_ALT = HexColor("#F1F5F9")
BOX_BG = HexColor("#F8FAFC")
LIS = HexColor("#1D4ED8")
PMS = HexColor("#B45309")
CASH = HexColor("#047857")

PAGE_W, PAGE_H = letter
LEFT = 0.72 * inch
RIGHT = 0.72 * inch
TOP = 0.82 * inch
BOTTOM = 0.72 * inch

FONTS = r"C:\Windows\Fonts"
pdfmetrics.registerFont(TTFont("Calibri", f"{FONTS}\\calibri.ttf"))
pdfmetrics.registerFont(TTFont("Calibri-Bold", f"{FONTS}\\calibrib.ttf"))
pdfmetrics.registerFont(TTFont("Calibri-Italic", f"{FONTS}\\calibrii.ttf"))
pdfmetrics.registerFont(TTFont("Calibri-BoldItalic", f"{FONTS}\\calibriz.ttf"))
pdfmetrics.registerFont(TTFont("Segoe", f"{FONTS}\\segoeui.ttf"))
pdfmetrics.registerFont(TTFont("Segoe-Bold", f"{FONTS}\\segoeuib.ttf"))
pdfmetrics.registerFont(TTFont("Segoe-Italic", f"{FONTS}\\segoeuii.ttf"))
pdfmetrics.registerFont(TTFont("Consolas", f"{FONTS}\\consola.ttf"))
pdfmetrics.registerFontFamily(
    "Calibri",
    normal="Calibri",
    bold="Calibri-Bold",
    italic="Calibri-Italic",
    boldItalic="Calibri-BoldItalic",
)


def draw_cover(canvas, doc):
    canvas.saveState()
    c = canvas
    c.setFillColor(NAVY)
    c.rect(0, 0, PAGE_W, PAGE_H, fill=1, stroke=0)
    c.setFillColor(TEAL)
    c.rect(0, 0, 18, PAGE_H, fill=1, stroke=0)
    c.setFillColor(GOLD)
    c.rect(18, 0, 6, PAGE_H, fill=1, stroke=0)

    c.setFillColor(GOLD)
    c.setFont("Segoe-Bold", 9.5)
    c.drawCentredString(PAGE_W / 2 + 8, PAGE_H - 108, "LRN   ·   LAB REVENUE NAVIGATOR")
    c.setStrokeColor(GOLD)
    c.setLineWidth(1)
    c.line(PAGE_W / 2 - 92, PAGE_H - 120, PAGE_W / 2 + 108, PAGE_H - 120)

    c.setFillColor(white)
    c.setFont("Segoe-Bold", 24)
    y = PAGE_H - 172
    for line in [
        "BeechTree Executive Summary",
        "Three-Pillar Diagnostics",
        "Two-Agent Pipeline",
    ]:
        c.drawCentredString(PAGE_W / 2 + 8, y, line)
        y -= 32

    c.setFillColor(HexColor("#D6E4EE"))
    c.setFont("Segoe-Italic", 11.5)
    c.drawCentredString(
        PAGE_W / 2 + 8, y - 4,
        "Microsoft Foundry design — JSON generation and model insights",
    )

    c.setFillColor(GOLD)
    c.roundRect(PAGE_W / 2 - 78, 214, 188, 28, 4, fill=1, stroke=0)
    c.setFillColor(NAVY)
    c.setFont("Segoe-Bold", 9.5)
    c.drawCentredString(PAGE_W / 2 + 16, 223, "PLANNING DOCUMENT")

    c.setFillColor(HexColor("#E2E8F0"))
    c.setFont("Calibri", 11)
    meta = [
        "Agent 1   ·   Generate Three-Pillar JSON",
        "Agent 2   ·   Generate insights using Foundry models",
        "Trigger   ·   New Executive Summary refresh  +  weekly schedule",
        "16 August 2026",
    ]
    my = 168
    for m in meta:
        c.drawCentredString(PAGE_W / 2 + 8, my, m)
        my -= 16

    c.setFillColor(HexColor("#94A3B8"))
    c.setFont("Calibri", 8.5)
    c.drawCentredString(PAGE_W / 2 + 8, 48, "Internal use  ·  Includes table of contents and term index")
    c.restoreState()


def draw_header_footer(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(NAVY)
    canvas.rect(0, PAGE_H - 26, PAGE_W, 26, fill=1, stroke=0)
    canvas.setFillColor(GOLD)
    canvas.rect(0, PAGE_H - 29, PAGE_W, 3, fill=1, stroke=0)
    canvas.setFillColor(white)
    canvas.setFont("Segoe", 8)
    canvas.drawString(LEFT, PAGE_H - 18, "LRN  |  BeechTree Three-Pillar Agent Pipeline")
    canvas.drawRightString(PAGE_W - RIGHT, PAGE_H - 18, "Microsoft Foundry Design")

    canvas.setFillColor(NAVY)
    canvas.rect(0, 0, PAGE_W, 32, fill=1, stroke=0)
    canvas.setFillColor(GOLD)
    canvas.rect(0, 32, PAGE_W, 2, fill=1, stroke=0)
    canvas.setFillColor(white)
    canvas.setFont("Calibri", 8)
    canvas.drawString(LEFT, 13, "Confidential  ·  Internal planning document  ·  16 August 2026")
    canvas.drawRightString(PAGE_W - RIGHT, 13, f"Page {doc.page}")
    canvas.restoreState()


class HeadingCollectorDoc(BaseDocTemplate):
    def afterFlowable(self, flowable):
        if not isinstance(flowable, Paragraph):
            return
        if flowable.style.name == "Chapter":
            self.notify("TOCEntry", (0, flowable.getPlainText(), self.page))


class SectionRule(Flowable):
    """Teal underline under section headings, matching the screenshot."""

    def __init__(self, width):
        super().__init__()
        self.width = width
        self.height = 5

    def draw(self):
        self.canv.setStrokeColor(TEAL)
        self.canv.setLineWidth(0.9)
        self.canv.line(0, 3, self.width, 3)


def styles():
    ss = getSampleStyleSheet()
    ss.add(ParagraphStyle(
        name="TocTitle", fontName="Segoe-Bold", fontSize=16, leading=20,
        textColor=NAVY, spaceBefore=4, spaceAfter=8,
    ))
    ss.add(ParagraphStyle(
        name="Chapter", fontName="Segoe-Bold", fontSize=15, leading=19,
        textColor=NAVY, spaceBefore=4, spaceAfter=9,
    ))
    ss.add(ParagraphStyle(
        name="Section", fontName="Segoe-Bold", fontSize=11.5, leading=15,
        textColor=TEAL, spaceBefore=11, spaceAfter=2,
    ))
    ss.add(ParagraphStyle(
        name="Body", fontName="Calibri", fontSize=10.5, leading=14.5,
        textColor=SLATE, alignment=TA_JUSTIFY, spaceAfter=8,
    ))
    ss.add(ParagraphStyle(
        name="BodyLeft", fontName="Calibri", fontSize=10.5, leading=14.5,
        textColor=SLATE, alignment=TA_LEFT, spaceAfter=5,
    ))
    ss.add(ParagraphStyle(
        name="BulletBody", fontName="Calibri", fontSize=10.5, leading=14.5,
        textColor=SLATE, leftIndent=16, firstLineIndent=0, spaceAfter=5,
        bulletIndent=0, alignment=TA_LEFT,
    ))
    ss.add(ParagraphStyle(
        name="Callout", fontName="Calibri-Italic", fontSize=10.5, leading=14.5,
        textColor=NAVY, leftIndent=4, rightIndent=4, spaceBefore=2, spaceAfter=2,
    ))
    ss.add(ParagraphStyle(
        name="Caption", fontName="Calibri-Italic", fontSize=8.5, leading=11,
        textColor=MUTED, alignment=TA_CENTER, spaceBefore=4, spaceAfter=10,
    ))
    ss.add(ParagraphStyle(
        name="TableHead", fontName="Segoe-Bold", fontSize=8.5, leading=11.5,
        textColor=white, alignment=TA_LEFT,
    ))
    ss.add(ParagraphStyle(
        name="TableCell", fontName="Calibri", fontSize=9, leading=12,
        textColor=SLATE, alignment=TA_LEFT,
    ))
    ss.add(ParagraphStyle(
        name="TableCellBold", fontName="Calibri-Bold", fontSize=9, leading=12,
        textColor=NAVY, alignment=TA_LEFT,
    ))
    ss.add(ParagraphStyle(
        name="CodeBlock", fontName="Consolas", fontSize=8, leading=11.5,
        textColor=HexColor("#0F172A"), leftIndent=2, rightIndent=2,
    ))
    ss.add(ParagraphStyle(
        name="TOCLevel0", fontName="Calibri", fontSize=11, leading=16,
        textColor=NAVY, spaceBefore=3, spaceAfter=0,
    ))
    ss.add(ParagraphStyle(
        name="TOCLevel1", fontName="Calibri", fontSize=10, leading=14,
        textColor=SLATE, leftIndent=16, spaceBefore=1, spaceAfter=0,
    ))
    ss.add(ParagraphStyle(
        name="FooterNote", fontName="Calibri-Italic", fontSize=9, leading=12,
        textColor=MUTED, alignment=TA_LEFT, spaceAfter=6, spaceBefore=8,
    ))
    return ss


def bullets(ss, items):
    """Real disc bullets — never the word 'bullet'."""
    flow = []
    for text in items:
        flow.append(Paragraph(f"<font color='#1A6B7A'><b>•</b></font>&nbsp;&nbsp;{text}", ss["BulletBody"]))
    flow.append(Spacer(1, 4))
    return flow


def numbered(ss, items):
    flow = []
    for i, text in enumerate(items, 1):
        flow.append(Paragraph(f"<b>{i}.</b>&nbsp;&nbsp;{text}", ss["BodyLeft"]))
    flow.append(Spacer(1, 4))
    return flow


def section(ss, title, usable):
    return [Paragraph(title, ss["Section"]), SectionRule(usable), Spacer(1, 6)]


def make_table(ss, headers, rows, col_widths):
    head = [Paragraph(h, ss["TableHead"]) for h in headers]
    data = [head]
    for row in rows:
        cells = []
        for i, val in enumerate(row):
            style = "TableCellBold" if i == 0 else "TableCell"
            cells.append(Paragraph(str(val), ss[style]))
        data.append(cells)
    t = Table(data, colWidths=col_widths, repeatRows=1)
    cmds = [
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 7),
        ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("GRID", (0, 0), (-1, -1), 0.3, RULE),
    ]
    for r in range(1, len(data)):
        cmds.append(("BACKGROUND", (0, r), (-1, r), ROW_ALT if r % 2 == 0 else white))
    t.setStyle(TableStyle(cmds))
    t.hAlign = "LEFT"
    return t


def callout_table(ss, text):
    inner = Paragraph(text, ss["Callout"])
    t = Table([[inner]], colWidths=[PAGE_W - LEFT - RIGHT])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), HexColor("#E8F4F6")),
        ("BOX", (0, 0), (-1, -1), 1.1, TEAL),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
    ]))
    t.hAlign = "LEFT"
    return t


def flowchart_table(ss):
    steps = [
        ("1", "SOURCE EVENT", "ClaimLineCSVDataCapture — BeechTree Executive Summary refresh succeeds (STEP 16 new RunId, or STEP 14 TransactionDetail)."),
        ("2", "EVENT + SCHEDULE", "HTTP webhook or Service Bus message to Logic App. Optional Monday weekly recurrence as a safety net."),
        ("3", "AGENT 1 — JSON", "Azure Function calls LIS, PMS, and Cash stored procedures. Writes one JSON file to Blob Storage."),
        ("4", "VALIDATE HANDOFF", "Logic App checks that lis, pms, and cash sections are present. Fail and alert if not."),
        ("5", "AGENT 2 — INSIGHTS", "Foundry model reads the JSON and diagnostic playbook. Emits structured findings (risk, evidence, action)."),
        ("6", "PERSIST + NOTIFY", "Save insights JSON to Blob. Insert rows via usp_NotesInsight_Insert. Optional email / Teams."),
    ]
    colors = [NAVY, TEAL, LIS, HexColor("#7C3AED"), PMS, CASH]
    data = [[
        Paragraph("<b>#</b>", ss["TableHead"]),
        Paragraph("<b>Stage</b>", ss["TableHead"]),
        Paragraph("<b>What happens</b>", ss["TableHead"]),
    ]]
    for num, title, body in steps:
        data.append([
            Paragraph(num, ss["TableHead"]),
            Paragraph(title, ss["TableCellBold"]),
            Paragraph(body, ss["TableCell"]),
        ])
    usable = PAGE_W - LEFT - RIGHT
    t = Table(data, colWidths=[0.42 * inch, 1.65 * inch, usable - 2.07 * inch], repeatRows=1)
    cmds = [
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 7),
        ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
        ("GRID", (0, 1), (-1, -1), 0.4, RULE),
        ("ALIGN", (0, 1), (0, -1), "CENTER"),
    ]
    for i, col in enumerate(colors, start=1):
        cmds.append(("BACKGROUND", (0, i), (0, i), col))
        cmds.append(("TEXTCOLOR", (0, i), (0, i), white))
        cmds.append(("BACKGROUND", (1, i), (-1, i), white if i % 2 else ROW_ALT))
    t.setStyle(TableStyle(cmds))
    t.hAlign = "LEFT"
    return t


def code_block(ss, text):
    inner = Paragraph(text.replace(" ", "&nbsp;").replace("\n", "<br/>"), ss["CodeBlock"])
    t = Table([[inner]], colWidths=[PAGE_W - LEFT - RIGHT])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), BOX_BG),
        ("BOX", (0, 0), (-1, -1), 0.6, RULE),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ("RIGHTPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 7),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
    ]))
    t.hAlign = "LEFT"
    return t


def build():
    out_path = r"E:\LRN-GitHub\2026\LRNDevTeam\docs\beechtree-threepillar\BeechTree_ThreePillar_Foundry_Agents_Plan.pdf"
    ss = styles()
    usable = PAGE_W - LEFT - RIGHT

    doc = HeadingCollectorDoc(
        out_path,
        pagesize=letter,
        title="BeechTree Three-Pillar Two-Agent Pipeline — Microsoft Foundry Plan",
        author="LRN Dev Team",
        subject="Scheduled Agent 1 JSON export and Agent 2 Foundry insights",
        creator="LRN planning document",
    )

    cover_frame = Frame(LEFT, BOTTOM, usable, 20, id="cover")
    body_frame = Frame(LEFT, BOTTOM + 8, usable, PAGE_H - TOP - BOTTOM - 6, id="body")
    doc.addPageTemplates([
        PageTemplate(id="Cover", frames=[cover_frame], onPage=draw_cover),
        PageTemplate(id="Body", frames=[body_frame], onPage=draw_header_footer),
    ])

    story = []
    story.append(Spacer(1, 1))
    story.append(NextPageTemplate("Body"))
    story.append(PageBreak())

    story.append(Paragraph("Contents", ss["TocTitle"]))
    story.append(Paragraph(
        "This document is the implementation plan for a scheduled two-agent pipeline: "
        "Agent 1 generates BeechTree Three-Pillar diagnostic values as JSON; Agent 2 uses "
        "Microsoft Foundry models to produce insights. Use the Contents below to open a chapter. "
        "Section 11 is an alphabetical index of tools and terms with context.",
        ss["Body"],
    ))
    toc = TableOfContents()
    toc.levelStyles = [ss["TOCLevel0"], ss["TOCLevel1"]]
    toc.dotsMinLevel = 0
    toc.rightColumnWidth = 28
    story.append(toc)
    story.append(PageBreak())

    story.append(Paragraph("1.  Purpose and outcome", ss["Chapter"]))
    story.append(Paragraph(
        "The goal is a production pipeline that runs when a new BeechTree Executive Summary is generated, "
        "exports the Three-Pillar diagnostic values to a JSON file, and immediately hands that file to a second "
        "agent that writes insights using a Foundry-hosted model. A weekly schedule is a safety net if the "
        "event is missed.",
        ss["Body"],
    ))
    story.extend(section(ss, "Intended outcome", usable))
    story.extend(bullets(ss, [
        "Agent 1 produces one JSON file whose LIS, PMS, and Cash numbers match the Three-Pillar Diagnostic page.",
        "Agent 2 starts only after that JSON exists and validates — the file is the contract between the agents.",
        "Insights are stored (Blob plus Executive Summary Notes) so operators can review them with the weekly report.",
        "Microsoft Foundry supplies models for Agent 2; Azure Logic Apps is the conductor (schedule + event + sequence).",
    ]))
    story.append(callout_table(ss,
        "Do not combine both jobs in one agent, and do not use Foundry’s visual workflow designer for this build. "
        "Microsoft is retiring that designer (1 December 2026). Use Logic Apps Standard to orchestrate Foundry agents."
    ))

    story.append(Paragraph("2.  Recommended architecture", ss["Chapter"]))
    story.append(Paragraph(
        "Treat Agent 1 as a deterministic exporter and Agent 2 as the model. Logic Apps receives the Executive Summary "
        "refresh event, calls Agent 1, validates the Blob JSON, then runs Agent 2. This keeps billed dollars and claim "
        "counts exact, and spends model tokens only on interpretation.",
        ss["Body"],
    ))
    story.extend(section(ss, "Handoff rule", usable))
    story.append(Paragraph(
        "Agent 2 must not run on its own timer against stale or missing data. It starts only when Agent 1 has written "
        "a valid JSON object containing <b>lis</b>, <b>pms</b>, and <b>cash</b> sections.",
        ss["Body"],
    ))
    story.extend(section(ss, "Why not scrape the dashboard", usable))
    story.append(Paragraph(
        "The Three-Pillar page already loads from three stored procedures on BeechTree_LRN. Agent 1 should call those "
        "procedures (or a thin JSON API that wraps them). HTML scraping would drift from the page and is slower to operate.",
        ss["Body"],
    ))
    story.extend(section(ss, "What already exists in LRN", usable))
    story.append(make_table(ss,
        ["Pillar", "Stored procedure", "Dashboard load"],
        [
            ["LIS — sample to claim", "usp_GetBeechTree_ThreePillarLisDiagnostic", "Main Three-Pillar page"],
            ["PMS — revenue realization", "usp_GetBeechTree_ThreePillarPmsDiagnostic", "PMS tab (lazy load)"],
            ["Cash — leakage and risk", "usp_GetBeechTree_ThreePillarCashDiagnostic", "Cash tab (lazy load)"],
        ],
        [1.65 * inch, 3.2 * inch, usable - 4.85 * inch],
    ))
    story.append(Spacer(1, 8))
    story.append(Paragraph(
        "Page today: /ExecutiveSummary/ThreePillarDiagnostic?lab=Beech_Tree&amp;months=12. "
        "Shared window: trailing months (3 / 6 / 9 / 12 / 19) plus comparable day cutoff from WeekRange end. "
        "Executive Summary aggregates already refresh in ClaimLineCSVDataCapture after new lab data.",
        ss["Body"],
    ))

    story.append(Paragraph("3.  Process flowchart", ss["Chapter"]))
    story.append(Paragraph(
        "Read the table top to bottom. Each stage waits for the previous stage. The JSON Blob between stages 3 and 5 "
        "is the only payload Agent 2 is allowed to reason over.",
        ss["Body"],
    ))
    story.append(flowchart_table(ss))
    story.append(Paragraph(
        "Figure 1.  End-to-end BeechTree Three-Pillar agent pipeline (event-driven, with weekly backup).",
        ss["Caption"],
    ))
    story.extend(section(ss, "Trigger sources on the Logic App", usable))
    story.append(make_table(ss,
        ["Trigger", "When it fires", "Why it exists"],
        [
            ["ES refresh event (primary)", "ClaimLineCSVDataCapture STEP 16 (new RunId) or STEP 14 (new TransactionDetail file), after BeechTree ES SPs succeed", "Insights follow the real weekly Executive Summary"],
            ["Weekly recurrence (backup)", "For example Monday 07:00", "Catches a missed webhook; Agent 2 still waits for fresh JSON"],
        ],
        [1.85 * inch, 2.7 * inch, usable - 4.55 * inch],
    ))

    story.append(Paragraph("4.  Agent responsibilities", ss["Chapter"]))
    story.append(make_table(ss,
        ["", "Agent 1 — JSON Generator", "Agent 2 — Insights"],
        [
            ["Job", "Pull Three-Pillar numbers", "Interpret those numbers"],
            ["Brain", "No LLM. Deterministic code (Azure Function)", "Foundry-deployed chat model"],
            ["Input", "Lab Beech_Tree, months, as-of / day window", "The JSON file from Agent 1 plus a diagnostic playbook"],
            ["Output", "One JSON file in Blob Storage", "Insights JSON and Notes rows"],
            ["Foundry role", "Optional OpenAPI wrapper around the Function", "Primary agent: instructions, model, structured output"],
            ["Why split", "Numbers must match the dashboard", "Wording and diagnosis are the model’s job"],
        ],
        [1.15 * inch, (usable - 1.15 * inch) / 2, (usable - 1.15 * inch) / 2],
    ))
    story.append(Spacer(1, 8))
    story.append(callout_table(ss,
        "Agent 1 must not use a language model to invent metrics. Registering the Function as a Foundry OpenAPI tool "
        "is optional and only for catalog/visibility. The Function remains the source of truth."
    ))
    story.extend(section(ss, "Agent 1 JSON contract (sketch)", usable))
    story.append(code_block(ss,
        "{<br/>"
        "&nbsp;&nbsp;\"meta\": { \"lab\": \"Beech_Tree\", \"trailingMonths\": 12,<br/>"
        "&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\"asOfDate\": \"...\", \"dayWindow\": 23, \"weekFolder\": \"...\" },<br/>"
        "&nbsp;&nbsp;\"lis\":&nbsp;&nbsp;{ \"monthly\": [], \"funnelPeriod\": {}, \"backlogSummary\": {}, \"backlogBuckets\": [] },<br/>"
        "&nbsp;&nbsp;\"pms\":&nbsp;&nbsp;{ \"reconciliation\": [], \"fullyAdjusted\": [], \"fullyPaid\": [], \"denialByCarrier\": [] },<br/>"
        "&nbsp;&nbsp;\"cash\": { \"headline\": [], \"writeOffReasons\": [] }<br/>"
        "}"
    ))
    story.append(Paragraph(
        "Shape should follow ExecSummaryThreePillarViewModel so a reviewer can compare JSON to the page field-for-field. "
        "Blob path example: beech-tree/three-pillar/{weekFolder}/three-pillar.json.",
        ss["Body"],
    ))
    story.extend(section(ss, "Agent 2 insights contract (sketch)", usable))
    story.append(code_block(ss,
        "{<br/>"
        "&nbsp;&nbsp;\"lab\": \"Beech_Tree\", \"weekFolder\": \"...\",<br/>"
        "&nbsp;&nbsp;\"findings\": [{<br/>"
        "&nbsp;&nbsp;&nbsp;&nbsp;\"pillar\": \"LIS\", \"risk\": \"Red\", \"title\": \"...\",<br/>"
        "&nbsp;&nbsp;&nbsp;&nbsp;\"insight\": \"...\", \"evidence\": \"cite JSON fields\",<br/>"
        "&nbsp;&nbsp;&nbsp;&nbsp;\"action\": \"...\", \"responsibleParty\": \"Billing\"<br/>"
        "&nbsp;&nbsp;}]<br/>"
        "}"
    ))
    story.append(Paragraph(
        "Use Foundry structured outputs so every run returns this schema. Agent 2 instructions: do not invent metrics; "
        "cite evidence from the JSON; classify risk as Red / Yellow / Green; propose a concrete action and owner.",
        ss["Body"],
    ))

    story.append(Paragraph("5.  Tools required", ss["Chapter"]))
    story.extend(section(ss, "5.1  Azure platform", usable))
    story.append(make_table(ss,
        ["Tool", "Role in this pipeline"],
        [
            ["Azure subscription", "Host all resources"],
            ["Microsoft Foundry (project + model deployment)", "Agent 2 models and agent definition"],
            ["Azure Logic Apps (Standard)", "Event + schedule + Agent 1 then Agent 2 sequence"],
            ["Azure Functions", "Agent 1: call three SPs, write JSON"],
            ["Azure Blob Storage", "JSON handoff and insights archive"],
            ["Azure Key Vault", "SQL connection string and API keys — never in prompts"],
            ["BeechTree_LRN (existing SQL)", "Source data for Three-Pillar procedures"],
            ["Entra ID / Managed Identity", "Function to SQL/Blob; Logic App to Foundry"],
            ["Application Insights", "Run logs, failures, duration"],
        ],
        [2.55 * inch, usable - 2.55 * inch],
    ))
    story.extend(section(ss, "5.2  Foundry (Agent 2)", usable))
    story.append(make_table(ss,
        ["Tool", "Role in this pipeline"],
        [
            ["Deployed chat model", "Write insights from the JSON"],
            ["Structured outputs", "Force a fixed insights JSON schema"],
            ["Instructions + diagnostic playbook", "How to read LIS / PMS / Cash (funnel, gap, collection rate, write-off ratio)"],
            ["OpenAPI tool (optional)", "Save insights via a small HTTP API"],
        ],
        [2.55 * inch, usable - 2.55 * inch],
    ))
    story.extend(section(ss, "5.3  Already in the LRN repository", usable))
    story.append(make_table(ss,
        ["Piece", "Role in this pipeline"],
        [
            ["Three BeechTree Three-Pillar stored procedures", "Authoritative numbers for Agent 1"],
            ["ClaimLineCSVDataCapture STEP 16 / STEP 14", "“New Executive Summary generated” event"],
            ["usp_NotesInsight_Insert", "Store insights on Executive Summary Notes"],
            ["ExecSummaryThreePillarViewModel", "JSON field map matching the dashboard"],
        ],
        [2.55 * inch, usable - 2.55 * inch],
    ))
    story.extend(section(ss, "5.4  Optional later", usable))
    story.append(make_table(ss,
        ["Tool", "Role"],
        [
            ["Azure Service Bus", "Reliable event instead of a raw HTTP call"],
            ["Teams or Outlook connector", "Notify when insights are ready"],
            ["API Management", "HTTPS + API key in front of the Function"],
        ],
        [2.55 * inch, usable - 2.55 * inch],
    ))
    story.append(Spacer(1, 8))
    story.append(callout_table(ss,
        "You do not need Playwright, browser login, or Foundry portal workflows for this design. "
        "Agent 1 talks to SQL; Agent 2 talks to JSON; Logic Apps sequences them."
    ))

    story.append(Paragraph("6.  Build plan — step by step", ss["Chapter"]))
    story.append(Paragraph(
        "Work in this order. Each phase has a testable exit. Do not enable the weekly schedule until a manual Logic App run has written Notes rows.",
        ss["Body"],
    ))
    story.extend(section(ss, "Phase 0 — Azure foundation", usable))
    story.extend(numbered(ss, [
        "Create a resource group, for example rg-lrn-threepillar-agents.",
        "Create a Foundry resource and project; deploy one mid-size GPT-class model.",
        "Create a Storage account and container named three-pillar.",
        "Create Key Vault; store BeechTreeConnStr there. Do not put connection strings in agent prompts or git.",
        "Create a Function App with Managed Identity; grant Key Vault read, Blob write, and SQL access.",
    ]))
    story.extend(section(ss, "Phase 1 — Agent 1 (JSON exporter)", usable))
    story.extend(numbered(ss, [
        "Add a Function, for example POST /api/beech-tree/three-pillar-json.",
        "Inputs: lab=Beech_Tree, months=12 (allowed: 3 / 6 / 9 / 12 / 19).",
        "Call the three existing stored procedures with the same asOf date and dayWindow the dashboard uses (WeekRange end).",
        "Write Blob: beech-tree/three-pillar/{weekFolder}/three-pillar.json.",
        "Return { blobUri, generatedAt, lisRows, pmsRows, cashRows } so Logic Apps can validate without opening the file twice.",
        "Test once from an HTTP client and confirm JSON counts match the Three-Pillar page for the same months window.",
    ]))
    story.extend(section(ss, "Phase 2 — Fire when Executive Summary is new", usable))
    story.extend(numbered(ss, [
        "In ClaimLineCSVDataCapture, after BeechTree Executive Summary refresh succeeds (STEP 16 and STEP 14), POST a small event payload: lab, event=ExecutiveSummaryRefreshed, weekFolder, refreshedAt.",
        "Target the Logic App HTTP trigger (swap to Service Bus later if volume or reliability requires it).",
        "Send the event only when the ES stored procedures succeeded. Do not start Agent 1 on a failed refresh.",
    ]))
    story.extend(section(ss, "Phase 3 — Agent 2 (Foundry insights)", usable))
    story.extend(numbered(ss, [
        "In Foundry, create agent BeechTree-ThreePillar-Insights.",
        "Instructions: read LIS / PMS / Cash JSON; do not invent metrics; emit findings with risk (Red / Yellow / Green), evidence (cite JSON fields), and recommended action.",
        "Enable structured output using the insights schema in section 4.",
        "Ground the agent with Three-Pillar diagnostic rules: sample-to-claim funnel drop, LIS vs PMS reconciliation gap, collection rate, insurance balance composition, write-off ratio, patient collections reality.",
    ]))
    story.extend(section(ss, "Phase 4 — Logic App (schedule and chain)", usable))
    story.extend(numbered(ss, [
        "Create Logic App Standard workflow BeechTree-ThreePillar-Pipeline.",
        "Attach both triggers to the same workflow: HTTP or Service Bus (primary), and Recurrence (weekly safety net).",
        "Action 1: call Agent 1 Function; wait until the Blob exists.",
        "Action 2: get Blob content; validate lis, pms, and cash.",
        "Action 3: if invalid, fail, alert, and stop.",
        "Action 4: Agent action — run Foundry Agent 2; pass the JSON as the user message (do not ask the model to fetch the Blob itself).",
        "Action 5: save insights JSON beside the source file in Blob.",
        "Action 6: call usp_NotesInsight_Insert (or a small save-insights Function) so notes appear on Executive Summary.",
        "Action 7 (optional): email or Teams “insights ready”.",
        "Retry Agent 1 and Agent 2 up to three times. Alert if still failing.",
    ]))
    story.extend(section(ss, "Phase 5 — Prove it, then turn on the schedule", usable))
    story.extend(numbered(ss, [
        "Manual test: run Agent 1 Function; confirm the Blob.",
        "Manual test: run Agent 2 in Foundry with that JSON; confirm the insight schema.",
        "Manual test: run the Logic App once; confirm Notes rows on the BeechTree Executive Summary page.",
        "Enable the ClaimLineCSVDataCapture webhook.",
        "Enable the weekly recurrence last.",
    ]))

    story.append(Paragraph("7.  Trigger versus schedule", ss["Chapter"]))
    story.append(Paragraph(
        "Use both. The event is the real weekly clock (data landed). The schedule is only insurance. Agent 2 is never independently scheduled.",
        ss["Body"],
    ))
    story.append(make_table(ss,
        ["Mechanism", "Owner", "Starts Agent 2?"],
        [
            ["ES refresh event", "ClaimLineCSVDataCapture after successful BeechTree ES SPs", "Only after Agent 1 JSON validates"],
            ["Weekly Logic App recurrence", "Logic Apps", "Only after Agent 1 JSON validates"],
            ["Foundry agent timer", "Do not use", "No — would run without fresh ES data"],
        ],
        [2.15 * inch, 2.5 * inch, usable - 4.65 * inch],
    ))

    story.append(Paragraph("8.  Cost and design notes", ss["Chapter"]))
    story.extend(bullets(ss, [
        "Agent 1 as an Azure Function is cheap and exact. Making Agent 1 a Foundry chat agent adds token cost and can hallucinate numbers.",
        "Agent 2 is where model tokens are spent. Keep the prompt tight; pass JSON, not screenshots or PDFs of the dashboard.",
        "Logic Apps Standard plus Foundry is the Microsoft-supported production pattern for event → agent → next agent.",
        "Foundry portal workflows (visual designer) are not a new-solution option; they retire 1 December 2026. Do not start this project there.",
        "Pass JSON into Agent 2 as the user message from Logic Apps. That is more reliable than giving Agent 2 a Blob tool and hoping it fetches the right file.",
        "Reuse usp_NotesInsight_Insert so insights show on the existing Executive Summary Notes &amp; Insights UI instead of a side-channel spreadsheet.",
    ]))

    story.append(Paragraph("9.  First build slice", ss["Chapter"]))
    story.append(Paragraph(
        "When implementation starts, deliver these four items before polish (Service Bus, Teams, API Management):",
        ss["Body"],
    ))
    story.extend(numbered(ss, [
        "Azure Function that writes the Three-Pillar JSON to Blob.",
        "Logic App: HTTP trigger → Function → Blob.",
        "Foundry Agent 2 that consumes that JSON with structured output.",
        "Hook ClaimLineCSVDataCapture STEP 16 / STEP 14 to the Logic App after a successful BeechTree ES refresh.",
    ]))
    story.extend(section(ss, "Decision to confirm at kickoff", usable))
    story.append(Paragraph(
        "Keep Agent 1 as a Function only (recommended), or also register it as a Foundry agent that wraps the same Function via OpenAPI. "
        "The Function remains mandatory either way.",
        ss["Body"],
    ))

    story.append(Paragraph("10.  Appendix — existing refresh points", ss["Chapter"]))
    story.append(Paragraph(
        "These are the code locations that already mean “a new Executive Summary was generated” for BeechTree. "
        "The webhook in Phase 2 should fire only after these paths succeed.",
        ss["Body"],
    ))
    story.append(make_table(ss,
        ["Path", "When", "What runs"],
        [
            ["STEP 16", "New RunId or ClaimLineRefresh is true", "usp_RefreshBT_ExecutiveSummary and usp_RefreshBT_ExecutiveSummary_LIS_Alt via RefreshExecutiveSummaryByPrefix"],
            ["STEP 14", "No RunId change, but a new TransactionDetail file loaded", "usp_RefreshBT_ExecutiveSummary_OnNewFile (BTWOSummary + Executive Summary)"],
        ],
        [1.05 * inch, 2.25 * inch, usable - 3.3 * inch],
    ))
    story.append(Spacer(1, 8))
    story.append(Paragraph(
        "LabMetricsDashboard already maps Three-Pillar result sets in SqlPhiExecutiveSummaryRepository "
        "(GetBeechTreeThreePillarLisAsync, GetBeechTreeThreePillarPmsAsync, GetBeechTreeThreePillarCashAsync). "
        "Agent 1 should reuse that mapping, either by extracting a shared library or by duplicating the same column-to-JSON contract.",
        ss["Body"],
    ))
    story.extend(section(ss, "Diagnostic rules Agent 2 should apply", usable))
    story.extend(bullets(ss, [
        "LIS: sample-to-claim funnel (collected → resulted → billed to insurance); backlog age; % billed of resulted; self-pay / client-bill mix; not resulted.",
        "PMS: reconciliation gap (PMS billed vs LIS billed to insurance); fully adjusted % and reason Pareto; fully paid %; insurance balance composition; panel avg allowed vs paid; denial rate by carrier.",
        "Cash: collection rate (fully paid insurance $ ÷ total billed $); partially paid share; insurance balance $ mix (fully denied / no response / partially denied); patient write-off vs balance; patient collection rate; fully adjusted $.",
    ]))

    story.append(PageBreak())
    story.append(Paragraph("11.  Index of terms and tools", ss["Chapter"]))
    story.append(Paragraph(
        "Alphabetical index of names used in this plan. Use this with the Contents at the front when handing the PDF to another agent or engineer.",
        ss["Body"],
    ))

    index_entries = [
        ("A2A (agent-to-agent)", "Lightweight Foundry agent calling; not required for this sequential pipeline."),
        ("Agent 1 — JSON Generator", "Deterministic Azure Function that calls Three-Pillar SPs and writes Blob JSON."),
        ("Agent 2 — Insights", "Foundry agent that reads Agent 1 JSON and emits structured findings."),
        ("Application Insights", "Logging and failure tracking for Function and Logic App runs."),
        ("asOf / dayWindow", "Comparable-month cutoff from WeekRange end; must match the dashboard."),
        ("Azure Blob Storage", "Handoff store for three-pillar.json and insights JSON."),
        ("Azure Functions", "Runtime for Agent 1 exporter API."),
        ("Azure Key Vault", "Secret store for BeechTree SQL connection string."),
        ("Azure Logic Apps Standard", "Orchestrator: event, schedule, validate, call Agent 2."),
        ("BeechTree_LRN", "Lab SQL database hosting Three-Pillar stored procedures."),
        ("BeechTree-ThreePillar-Insights", "Suggested Foundry agent name for Agent 2."),
        ("BeechTree-ThreePillar-Pipeline", "Suggested Logic App workflow name."),
        ("ClaimLineCSVDataCapture", "Ingestion worker; STEP 14 / STEP 16 are the ES-ready events."),
        ("Collection rate", "Cash formula: fully paid insurance $ ÷ total billed $."),
        ("Entra ID / Managed Identity", "Auth from Function and Logic App to SQL, Blob, and Foundry."),
        ("ExecSummaryThreePillarViewModel", "C# model that defines the JSON field map."),
        ("Executive Summary Notes", "UI/table destination for Agent 2 via usp_NotesInsight_Insert."),
        ("Foundry structured outputs", "Forces Agent 2 to return a fixed insights JSON schema."),
        ("Foundry visual workflows", "Do not use; retiring 1 December 2026. Use Logic Apps instead."),
        ("LIS pillar", "Sample-to-claim funnel, backlog, billed-of-resulted, self-pay / client bill."),
        ("Microsoft Foundry", "Host for Agent 2 model, instructions, and optional OpenAPI tools."),
        ("OpenAPI tool", "Optional Foundry wrapper so an agent can call the Function or save-insights API."),
        ("PMS pillar", "Reconciliation gap, fully adjusted/paid, denials, maturity, panel averages."),
        ("Cash pillar", "Dollar leakage: collection, IB mix, patient WO, fully adjusted $."),
        ("Service Bus", "Optional reliable replacement for the HTTP webhook."),
        ("STEP 14", "ES refresh when only a new TransactionDetail file arrived."),
        ("STEP 16", "ES aggregate refresh after a new RunId / claim-line change."),
        ("Three-Pillar Diagnostic page", "Dashboard URL used to visually verify Agent 1 JSON."),
        ("usp_GetBeechTree_ThreePillarCashDiagnostic", "Cash stored procedure."),
        ("usp_GetBeechTree_ThreePillarLisDiagnostic", "LIS stored procedure."),
        ("usp_GetBeechTree_ThreePillarPmsDiagnostic", "PMS stored procedure."),
        ("usp_NotesInsight_Insert", "Writes an insight row onto Executive Summary Notes."),
        ("usp_RefreshBT_ExecutiveSummary", "BeechTree Executive Summary aggregate refresh."),
        ("WeekRange", "Billed week folder; end date anchors asOf and dayWindow."),
    ]

    idx_data = [[
        Paragraph("<b>Term</b>", ss["TableHead"]),
        Paragraph("<b>Context</b>", ss["TableHead"]),
    ]]
    for term, ctx in index_entries:
        idx_data.append([
            Paragraph(term.replace("_", "_ "), ss["TableCellBold"]),
            Paragraph(ctx, ss["TableCell"]),
        ])
    idx = Table(idx_data, colWidths=[2.65 * inch, usable - 2.65 * inch], repeatRows=1)
    idx_cmds = [
        ("BACKGROUND", (0, 0), (-1, 0), NAVY),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("GRID", (0, 0), (-1, -1), 0.3, RULE),
    ]
    for r in range(1, len(idx_data)):
        idx_cmds.append(("BACKGROUND", (0, r), (-1, r), ROW_ALT if r % 2 == 0 else white))
    idx.setStyle(TableStyle(idx_cmds))
    idx.hAlign = "LEFT"
    story.append(idx)
    story.append(Paragraph(
        "End of document. Next action: confirm Agent 1 as Function-only versus Foundry-wrapped Function, then begin Phase 0.",
        ss["FooterNote"],
    ))

    doc.multiBuild(story)
    return out_path


if __name__ == "__main__":
    print(build())

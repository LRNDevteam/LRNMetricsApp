"""Generate BeechTree Three-Pillar cost-analysis PDF (Calibri / Segoe UI)."""
from __future__ import annotations

from reportlab.lib.colors import HexColor, white
from reportlab.lib.enums import TA_JUSTIFY, TA_LEFT
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
GREEN = HexColor("#047857")
AMBER = HexColor("#B45309")

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
        "BeechTree Three-Pillar",
        "Two-Agent Pipeline",
        "Cost Analysis",
    ]:
        c.drawCentredString(PAGE_W / 2 + 8, y, line)
        y -= 32

    c.setFillColor(HexColor("#D6E4EE"))
    c.setFont("Segoe-Italic", 11.5)
    c.drawCentredString(
        PAGE_W / 2 + 8, y - 4,
        "Technologies, where costs occur, and approximate monthly spend",
    )

    c.setFillColor(GOLD)
    c.roundRect(PAGE_W / 2 - 88, 214, 208, 28, 4, fill=1, stroke=0)
    c.setFillColor(NAVY)
    c.setFont("Segoe-Bold", 9.5)
    c.drawCentredString(PAGE_W / 2 + 16, 223, "IMPLEMENTATION COST BRIEF")

    c.setFillColor(HexColor("#E2E8F0"))
    c.setFont("Calibri", 11)
    meta = [
        "Companion to the Foundry two-agent planning document",
        "Workload  ·  ~4–8 runs per month (weekly ES + backup)",
        "Lean path  ·  about $5–$20 / month",
        "Standard path  ·  about $190–$220 / month",
        "16 August 2026  ·  USD list-price estimates",
    ]
    my = 172
    for m in meta:
        c.drawCentredString(PAGE_W / 2 + 8, my, m)
        my -= 16

    c.setFillColor(HexColor("#94A3B8"))
    c.setFont("Calibri", 8.5)
    c.drawCentredString(PAGE_W / 2 + 8, 48, "Internal use  ·  Not a vendor quote  ·  Verify on the Azure pricing calculator")
    c.restoreState()


def draw_header_footer(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(NAVY)
    canvas.rect(0, PAGE_H - 26, PAGE_W, 26, fill=1, stroke=0)
    canvas.setFillColor(GOLD)
    canvas.rect(0, PAGE_H - 29, PAGE_W, 3, fill=1, stroke=0)
    canvas.setFillColor(white)
    canvas.setFont("Segoe", 8)
    canvas.drawString(LEFT, PAGE_H - 18, "LRN  |  Three-Pillar Agent Pipeline — Cost Analysis")
    canvas.drawRightString(PAGE_W - RIGHT, PAGE_H - 18, "Microsoft Foundry Design")

    canvas.setFillColor(NAVY)
    canvas.rect(0, 0, PAGE_W, 32, fill=1, stroke=0)
    canvas.setFillColor(GOLD)
    canvas.rect(0, 32, PAGE_W, 2, fill=1, stroke=0)
    canvas.setFillColor(white)
    canvas.setFont("Calibri", 8)
    canvas.drawString(LEFT, 13, "Confidential  ·  Internal estimate  ·  16 August 2026  ·  USD")
    canvas.drawRightString(PAGE_W - RIGHT, 13, f"Page {doc.page}")
    canvas.restoreState()


class HeadingCollectorDoc(BaseDocTemplate):
    def afterFlowable(self, flowable):
        if isinstance(flowable, Paragraph) and flowable.style.name == "Chapter":
            self.notify("TOCEntry", (0, flowable.getPlainText(), self.page))


class SectionRule(Flowable):
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
        textColor=SLATE, leftIndent=16, spaceAfter=5, alignment=TA_LEFT,
    ))
    ss.add(ParagraphStyle(
        name="Callout", fontName="Calibri-Italic", fontSize=10.5, leading=14.5,
        textColor=NAVY, leftIndent=4, rightIndent=4,
    ))
    ss.add(ParagraphStyle(
        name="Caption", fontName="Calibri-Italic", fontSize=8.5, leading=11,
        textColor=MUTED, alignment=TA_LEFT, spaceBefore=3, spaceAfter=8,
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
        name="Money", fontName="Calibri-Bold", fontSize=9, leading=12,
        textColor=GREEN, alignment=TA_LEFT,
    ))
    ss.add(ParagraphStyle(
        name="MoneyWarn", fontName="Calibri-Bold", fontSize=9, leading=12,
        textColor=AMBER, alignment=TA_LEFT,
    ))
    ss.add(ParagraphStyle(
        name="TOCLevel0", fontName="Calibri", fontSize=11, leading=16,
        textColor=NAVY, spaceBefore=3, spaceAfter=0,
    ))
    ss.add(ParagraphStyle(
        name="TOCLevel1", fontName="Calibri", fontSize=10, leading=14,
        textColor=SLATE, leftIndent=16,
    ))
    ss.add(ParagraphStyle(
        name="FooterNote", fontName="Calibri-Italic", fontSize=9, leading=12,
        textColor=MUTED, spaceBefore=8, spaceAfter=6,
    ))
    return ss


def bullets(ss, items):
    flow = []
    for text in items:
        flow.append(Paragraph(
            f"<font color='#1A6B7A'><b>•</b></font>&nbsp;&nbsp;{text}",
            ss["BulletBody"],
        ))
    flow.append(Spacer(1, 4))
    return flow


def section(ss, title, usable):
    return [Paragraph(title, ss["Section"]), SectionRule(usable), Spacer(1, 6)]


def make_table(ss, headers, rows, col_widths, money_cols=None, warn_cols=None):
    money_cols = money_cols or set()
    warn_cols = warn_cols or set()
    head = [Paragraph(h, ss["TableHead"]) for h in headers]
    data = [head]
    for row in rows:
        cells = []
        for i, val in enumerate(row):
            if i in warn_cols:
                style = "MoneyWarn"
            elif i in money_cols:
                style = "Money"
            elif i == 0:
                style = "TableCellBold"
            else:
                style = "TableCell"
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


def callout(ss, text):
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


def warn_box(ss, text):
    inner = Paragraph(text, ss["Callout"])
    t = Table([[inner]], colWidths=[PAGE_W - LEFT - RIGHT])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), HexColor("#FEF3C7")),
        ("BOX", (0, 0), (-1, -1), 1.1, AMBER),
        ("LEFTPADDING", (0, 0), (-1, -1), 10),
        ("RIGHTPADDING", (0, 0), (-1, -1), 10),
        ("TOPPADDING", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
    ]))
    t.hAlign = "LEFT"
    return t


def build():
    out_path = r"E:\LRN-GitHub\2026\LRNDevTeam\docs\beechtree-threepillar\BeechTree_ThreePillar_Cost_Analysis.pdf"
    ss = styles()
    usable = PAGE_W - LEFT - RIGHT

    doc = HeadingCollectorDoc(
        out_path,
        pagesize=letter,
        title="BeechTree Three-Pillar Two-Agent Pipeline — Cost Analysis",
        author="LRN Dev Team",
        subject="Technologies and approximate Azure cost to implement the pipeline",
        creator="LRN cost brief",
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
        "This brief answers three questions: which technologies are required to implement the "
        "BeechTree Three-Pillar two-agent pipeline, whether they cost money, and approximately how much "
        "per month. Companion document: BeechTree_ThreePillar_Foundry_Agents_Plan.pdf. "
        "Section 8 is an index of cost terms.",
        ss["Body"],
    ))
    toc = TableOfContents()
    toc.levelStyles = [ss["TOCLevel0"], ss["TOCLevel1"]]
    toc.dotsMinLevel = 0
    toc.rightColumnWidth = 28
    story.append(toc)
    story.append(PageBreak())

    # 1 Summary
    story.append(Paragraph("1.  Executive summary", ss["Chapter"]))
    story.append(Paragraph(
        "Yes — there are Azure costs. For this design they stay small if you stay on pay-as-you-go. "
        "The only line that can jump is Logic Apps Standard hosting, which bills even when the pipeline is idle.",
        ss["Body"],
    ))
    story.append(Paragraph(
        "This pipeline runs about 4–8 times a month (BeechTree Executive Summary refresh plus a weekly backup). "
        "It is not a 24/7 chatbot. Microsoft does not charge extra to create a Foundry agent or write prompts. "
        "You pay for what it uses: model tokens, Logic Apps, storage, and secrets.",
        ss["Body"],
    ))
    story.append(make_table(ss,
        ["Path", "When to use", "Approx / month"],
        [
            ["Lean (recommended)", "Weekly BeechTree only; Logic Apps Consumption + Functions Consumption", "$5 – $20"],
            ["Logic Apps Standard", "Only if you need VNet or the Foundry Agent designer action", "$190 – $220"],
        ],
        [1.7 * inch, 3.55 * inch, usable - 5.25 * inch],
        money_cols={2},
        warn_cols=set(),
    ))
    story.append(Spacer(1, 6))
    # mark second row as warn by rebuilding? The Standard path should be amber.
    # I'll add a note instead.
    story.append(callout(ss,
        "Bottom line: technologies are Foundry + Logic Apps + Functions + Blob + Key Vault. "
        "Cost is real but small on weekly volume — unless you turn on Logic Apps Standard, "
        "which is where about $180/month appears even when the pipeline barely runs."
    ))
    story.append(Paragraph(
        "Figures are USD list-price ballparks for East US as of August 2026. They are not a Microsoft quote. "
        "Region, Enterprise Agreement discount, and model choice will move the number. Confirm on the Azure pricing calculator before creating the resource group.",
        ss["Caption"],
    ))

    # 2 Tech
    story.append(Paragraph("2.  Technologies required", ss["Chapter"]))
    story.extend(section(ss, "Already in LRN — no new license", usable))
    story.append(make_table(ss,
        ["Piece", "Role", "New cost?"],
        [
            ["BeechTree_LRN SQL", "Source of Three-Pillar numbers", "No"],
            ["Three-Pillar stored procedures", "Agent 1 data (LIS, PMS, Cash)", "No"],
            ["ClaimLineCSVDataCapture STEP 14 / 16", "“New Executive Summary” trigger", "No"],
            ["LabMetricsDashboard", "Verify JSON vs the page", "No"],
            ["usp_NotesInsight_Insert", "Store Agent 2 insights", "No"],
        ],
        [2.35 * inch, 3.35 * inch, usable - 5.7 * inch],
        money_cols={2},
    ))
    story.extend(section(ss, "Must add in Azure — billed", usable))
    story.append(make_table(ss,
        ["Technology", "Role", "Billed?"],
        [
            ["Azure subscription", "Host everything", "Account only"],
            ["Microsoft Foundry (project + model)", "Agent 2 insights", "Yes — tokens"],
            ["Azure Logic Apps", "Schedule + chain Agent 1 → Agent 2", "Yes"],
            ["Azure Functions", "Agent 1 JSON export", "Yes, usually ~$0"],
            ["Azure Blob Storage", "JSON handoff file", "Yes, pennies"],
            ["Azure Key Vault", "SQL connection string", "Yes, pennies"],
            ["Entra ID / Managed Identity", "Authentication", "Typically included"],
            ["Application Insights", "Run logs and failures", "Small"],
        ],
        [2.55 * inch, 2.7 * inch, usable - 5.25 * inch],
    ))
    story.extend(section(ss, "Do not buy for this design", usable))
    story.extend(bullets(ss, [
        "Playwright or browser login — Agent 1 calls SQL, not the dashboard UI.",
        "Foundry hosted-agent containers — extra vCPU-hour; not needed if Agent 1 is a Function and Agent 2 is a native Foundry agent.",
        "Foundry visual workflows — retiring 1 December 2026.",
        "Azure OpenAI PTU (reserved capacity) — for high constant volume, not weekly runs.",
        "API Management — only later if you expose a public API.",
    ]))

    # 3 Where money
    story.append(Paragraph("3.  Where the money is", ss["Chapter"]))
    story.append(Paragraph(
        "Microsoft does not charge extra to create a Foundry agent or write prompts. You pay for consumption downstream of the weekly event.",
        ss["Body"],
    ))
    story.append(make_table(ss,
        ["Stage", "Component", "What is billed"],
        [
            ["Trigger", "Logic Apps", "Hosting (Standard) or per-action (Consumption)"],
            ["Agent 1", "Azure Function + SQL + Blob", "Function executions (usually free grant) + tiny storage"],
            ["Handoff", "Blob Storage", "A few KB–MB of JSON per week"],
            ["Agent 2", "Foundry model tokens", "Input tokens (JSON + instructions) + output tokens (insights)"],
            ["Optional tools", "Bing, File Search, Code Interpreter", "Skip unless you add them"],
            ["Secrets / logs", "Key Vault + Application Insights", "Low fixed / usage"],
        ],
        [1.15 * inch, 2.2 * inch, usable - 3.35 * inch],
    ))
    story.append(Spacer(1, 8))
    story.append(warn_box(ss,
        "Watch-out: Logic Apps Standard bills for the server being on, not for weekly runs. "
        "Same 8 runs can cost pennies on Consumption or about $180 on Standard WS1. "
        "For this workload, prefer Consumption unless you have a hard requirement for Standard."
    ))

    # 4 Lean
    story.append(Paragraph("4.  Lean path — recommended monthly estimate", ss["Chapter"]))
    story.append(Paragraph(
        "Use Logic Apps Consumption + Functions Consumption + Foundry pay-as-you-go. "
        "The Logic App calls Foundry over HTTP (or a small Function), not a 24/7 Standard plan. "
        "Assumption: about 8 runs per month; JSON about 20–80 KB; Agent 2 on a GPT-4.1-class model "
        "(about $2 per 1M input tokens and $8 per 1M output tokens).",
        ss["Body"],
    ))
    story.append(make_table(ss,
        ["Where", "What you pay for", "Approx / month"],
        [
            ["Foundry Agent 2", "Model tokens", "$1 – $8"],
            ["Logic Apps Consumption", "Triggers + actions (first 4,000 actions free)", "$0 – $2"],
            ["Azure Functions", "Agent 1 runs (1M executions free / month)", "~$0"],
            ["Blob Storage", "JSON + insights files", "&lt;$1"],
            ["Key Vault", "Secrets + operations", "$1 – $3"],
            ["Application Insights", "Logs", "$0 – $5"],
            ["Total lean", "Weekly BeechTree pipeline", "$5 – $20"],
        ],
        [2.15 * inch, 3.35 * inch, usable - 5.5 * inch],
        money_cols={2},
    ))
    story.extend(section(ss, "Token example (Agent 2)", usable))
    story.extend(bullets(ss, [
        "One run at ~25,000 input tokens + ~3,000 output tokens ≈ $0.07.",
        "Eight runs ≈ $0.60 per month.",
        "A large JSON (~200,000 input tokens) is still only a few dollars a month at weekly volume.",
        "Start with a mid-size model. Switch to a mini model if quality is acceptable — that can cut token cost about 5–10×.",
    ]))

    # 5 Standard
    story.append(Paragraph("5.  Logic Apps Standard path — the $180 line", ss["Chapter"]))
    story.append(Paragraph(
        "Microsoft’s Foundry-in-the-designer path often wants Logic Apps Standard. That plan bills for reserved compute whether or not the workflow ran. "
        "WS1 in East US is typically about $180–$200 per month, plus the same small token and storage costs.",
        ss["Body"],
    ))
    story.append(make_table(ss,
        ["Where", "Approx / month"],
        [
            ["Logic Apps Standard WS1 (always on)", "$180 – $200"],
            ["Foundry tokens + storage + Key Vault", "$5 – $15"],
            ["Total Standard", "$190 – $220"],
        ],
        [4.4 * inch, usable - 4.4 * inch],
        money_cols={1},
        warn_cols={1},
    ))
    story.append(Spacer(1, 8))
    story.append(Paragraph(
        "Same 8 runs as the lean path. Most of the $200 is idle compute. Choose Standard only if you need VNet isolation, many workflows on one plan, or the native Foundry Agent designer action. "
        "Otherwise keep Consumption and invoke Agent 2 via HTTP.",
        ss["Body"],
    ))

    # 6 Drivers
    story.append(Paragraph("6.  What actually drives cost", ss["Chapter"]))
    story.append(make_table(ss,
        ["Choice", "Effect on bill"],
        [
            ["Weekly BeechTree only", "Cheap. Tokens stay tiny."],
            ["Logic Apps Standard", "Largest bill. Avoid until you need VNet / many workflows."],
            ["Making Agent 1 a chat agent", "Extra tokens and risk of invented numbers. Keep it a Function."],
            ["GPT-4o / GPT-5 vs mini", "Mini can cut token cost about 5–10×. Start mid, drop to mini if quality is OK."],
            ["Hosted agents (containers)", "Extra vCPU-hour. Not needed here."],
            ["Bing / File Search / Code Interpreter", "Extra per search or per GB. Skip unless you add them."],
            ["More labs or daily runs later", "Tokens scale with runs. Still usually under $50 until volume is high."],
        ],
        [2.45 * inch, usable - 2.45 * inch],
    ))
    story.append(Spacer(1, 8))
    story.append(Paragraph(
        "Existing SQL Server (BeechTree_LRN) and LabMetricsDashboard do not add Azure cost for this pipeline. "
        "Staff time to build Agent 1, the Logic App, and Agent 2 instructions is an internal labour cost, not an Azure meter.",
        ss["Body"],
    ))

    # 7 Budget
    story.append(Paragraph("7.  Practical budget by phase", ss["Chapter"]))
    story.append(make_table(ss,
        ["Phase", "What to run", "Expect / month"],
        [
            ["Pilot (1 lab, weekly)", "Lean stack", "~$10"],
            ["Production BeechTree only", "Same lean stack", "$10 – $25"],
            ["Same design, Logic Apps Standard", "Only if you need that SKU", "~$200"],
            ["Later: more labs, daily runs", "Tokens scale with runs", "Usually still under $50"],
        ],
        [2.2 * inch, 2.55 * inch, usable - 4.75 * inch],
        money_cols={2},
    ))
    story.extend(section(ss, "Kickoff decision", usable))
    story.extend(bullets(ss, [
        "Lock lean vs Standard before creating the resource group. That single choice is most of the monthly bill.",
        "Keep Agent 1 as an Azure Function (not a Foundry chat agent).",
        "Do not enable Bing, File Search, or hosted agents in the pilot.",
        "Set an Azure budget alert at $25 (lean) or $250 (Standard) so a misconfigured loop cannot surprise you.",
        "Confirm list prices in the Azure pricing calculator for your region and offer (PAYG vs Enterprise Agreement).",
    ]))
    story.append(callout(ss,
        "Recommended start: lean path. Create rg-lrn-threepillar-agents with Foundry (one model), "
        "Functions Consumption, Logic Apps Consumption, one Blob container, and Key Vault. "
        "Expect about $10/month while you prove Agent 1 JSON and Agent 2 insights."
    ))

    # 8 Index
    story.append(PageBreak())
    story.append(Paragraph("8.  Index of cost terms", ss["Chapter"]))
    story.append(Paragraph(
        "Alphabetical index of technologies and meters used in this brief.",
        ss["Body"],
    ))
    index_entries = [
        ("Application Insights", "Log store. Small monthly cost; often $0–$5 at this volume."),
        ("Azure Blob Storage", "Handoff for three-pillar.json. Pennies per month."),
        ("Azure Functions Consumption", "Agent 1 runtime. 1 million executions free per month; this pipeline is far below that."),
        ("Azure Key Vault", "Holds BeechTree SQL connection string. About $1–$3/month."),
        ("Azure subscription", "Required account. No extra fee just to exist if resources are pay-as-you-go."),
        ("Entra ID / Managed Identity", "Auth from Function and Logic App. Typically no extra meter."),
        ("Foundry Agent Service", "No extra charge to create/run native agents; you pay model tokens and optional tools."),
        ("Foundry hosted agents", "Container vCPU/memory hours. Do not use for this design."),
        ("Foundry model tokens", "Main AI cost. Input + output billed separately (example GPT-4.1 ~$2 / $8 per 1M)."),
        ("Logic Apps Consumption", "Pay per action. First 4,000 actions free. Right SKU for weekly runs."),
        ("Logic Apps Standard WS1", "Always-on plan ~$180–$200/month. Only if VNet or designer Agent action is required."),
        ("PTU (provisioned throughput)", "Reserved model capacity. Not needed at weekly volume."),
        ("SQL BeechTree_LRN", "Existing on-prem / lab database. No incremental Azure cost."),
        ("Token (input)", "JSON + system instructions sent to Agent 2."),
        ("Token (output)", "Insights JSON Agent 2 writes back."),
    ]
    idx_data = [[
        Paragraph("<b>Term</b>", ss["TableHead"]),
        Paragraph("<b>Cost context</b>", ss["TableHead"]),
    ]]
    for term, ctx in index_entries:
        idx_data.append([
            Paragraph(term, ss["TableCellBold"]),
            Paragraph(ctx, ss["TableCell"]),
        ])
    idx = Table(idx_data, colWidths=[2.35 * inch, usable - 2.35 * inch], repeatRows=1)
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
        "End of cost brief. Next action: choose lean vs Standard, then begin Phase 0 in the planning PDF.",
        ss["FooterNote"],
    ))

    doc.multiBuild(story)
    return out_path


if __name__ == "__main__":
    print(build())

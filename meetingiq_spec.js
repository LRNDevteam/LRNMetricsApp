const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  Header, Footer, AlignmentType, HeadingLevel, BorderStyle, WidthType,
  ShadingType, VerticalAlign, PageNumber, PageBreak, LevelFormat,
  TableOfContents
} = require('/usr/local/lib/node_modules_global/lib/node_modules/docx');
const fs = require('fs');

// ─── Color palette ────────────────────────────────────────────────────────────
const C = {
  indigo:  "4F46E5",
  indigoL: "EEF2FF",
  navy:    "1E1B4B",
  slate:   "475569",
  slateL:  "F8FAFC",
  grey:    "94A3B8",
  white:   "FFFFFF",
  black:   "0F172A",
  border:  "CBD5E1",
};

// ─── Helpers ──────────────────────────────────────────────────────────────────
const sp = (before = 0, after = 0) => ({ before, after });
const gap = (n = 160) => new Paragraph({ spacing: sp(n, 0), children: [] });

function h1(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_1,
    spacing: sp(360, 160),
    children: [new TextRun({ text, font: "Arial", size: 36, bold: true, color: C.navy })],
  });
}
function h2(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_2,
    spacing: sp(280, 120),
    children: [new TextRun({ text, font: "Arial", size: 28, bold: true, color: C.indigo })],
  });
}
function h3(text) {
  return new Paragraph({
    heading: HeadingLevel.HEADING_3,
    spacing: sp(200, 80),
    children: [new TextRun({ text, font: "Arial", size: 24, bold: true, color: C.slate })],
  });
}
function para(text) {
  return new Paragraph({
    spacing: sp(80, 80),
    children: [new TextRun({ text, font: "Arial", size: 22, color: C.black })],
  });
}
function bullet(text, level = 0) {
  return new Paragraph({
    numbering: { reference: "bullets", level },
    spacing: sp(60, 60),
    children: [new TextRun({ text, font: "Arial", size: 22, color: C.black })],
  });
}
function numbered(text, level = 0) {
  return new Paragraph({
    numbering: { reference: level === 0 ? "numbers" : "numbers2" , level: 0 },
    spacing: sp(60, 60),
    children: [new TextRun({ text, font: "Arial", size: 22, color: C.black })],
  });
}
function noteBox(text) {
  const border = { style: BorderStyle.SINGLE, size: 4, color: C.indigo };
  return new Table({
    width: { size: 9360, type: WidthType.DXA },
    columnWidths: [9360],
    rows: [new TableRow({ children: [new TableCell({
      borders: { top: border, bottom: border, left: border, right: border },
      shading: { fill: C.indigoL, type: ShadingType.CLEAR },
      margins: { top: 120, bottom: 120, left: 200, right: 200 },
      width: { size: 9360, type: WidthType.DXA },
      children: [new Paragraph({
        spacing: sp(0,0),
        children: [new TextRun({ text, font: "Arial", size: 20, color: C.navy, italic: true })],
      })],
    })]})],
  });
}

const BD = { style: BorderStyle.SINGLE, size: 1, color: C.border };
const BORD = { top: BD, bottom: BD, left: BD, right: BD };

function makeRow(cells, widths, isHeader) {
  return new TableRow({ children: cells.map((text, i) => new TableCell({
    borders: BORD,
    shading: { fill: isHeader ? C.indigo : C.white, type: ShadingType.CLEAR },
    margins: { top: 80, bottom: 80, left: 120, right: 120 },
    width: { size: widths[i], type: WidthType.DXA },
    children: [new Paragraph({ spacing: sp(0,0), children: [
      new TextRun({ text, font: "Arial", size: isHeader ? 20 : 20, bold: isHeader, color: isHeader ? C.white : C.black })
    ]})],
  }))});
}

function twoColTable(rows) {
  return new Table({
    width: { size: 9360, type: WidthType.DXA },
    columnWidths: [2520, 6840],
    rows: rows.map((r, i) => makeRow(r, [2520, 6840], i === 0)),
  });
}
function threeColTable(rows, widths) {
  const w = widths || [2080, 5200, 2080];
  return new Table({
    width: { size: 9360, type: WidthType.DXA },
    columnWidths: w,
    rows: rows.map((r, i) => makeRow(r, w, i === 0)),
  });
}
function sixColTable(rows, widths) {
  return new Table({
    width: { size: 9360, type: WidthType.DXA },
    columnWidths: widths,
    rows: rows.map((r, i) => makeRow(r, widths, i === 0)),
  });
}

// ─── Document ─────────────────────────────────────────────────────────────────
const doc = new Document({
  numbering: {
    config: [
      { reference: "bullets", levels: [
        { level: 0, format: LevelFormat.BULLET, text: "•", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 720, hanging: 360 } } } },
        { level: 1, format: LevelFormat.BULLET, text: "◦", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 1080, hanging: 360 } } } },
      ]},
      { reference: "numbers", levels: [
        { level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 720, hanging: 360 } } } },
      ]},
      { reference: "numbers2", levels: [
        { level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 720, hanging: 360 } } } },
      ]},
    ],
  },
  styles: {
    default: { document: { run: { font: "Arial", size: 22, color: C.black } } },
    paragraphStyles: [
      { id: "Heading1", name: "Heading 1", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 36, bold: true, font: "Arial", color: C.navy },
        paragraph: { spacing: sp(360, 160), outlineLevel: 0 } },
      { id: "Heading2", name: "Heading 2", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 28, bold: true, font: "Arial", color: C.indigo },
        paragraph: { spacing: sp(280, 120), outlineLevel: 1 } },
      { id: "Heading3", name: "Heading 3", basedOn: "Normal", next: "Normal", quickFormat: true,
        run: { size: 24, bold: true, font: "Arial", color: C.slate },
        paragraph: { spacing: sp(200, 80), outlineLevel: 2 } },
    ],
  },
  sections: [
    // ── COVER PAGE ─────────────────────────────────────────────────────────
    {
      properties: {
        page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } },
      },
      children: [
        gap(2200),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: sp(0, 100), children: [
          new TextRun({ text: "MeetingIQ", font: "Arial", size: 88, bold: true, color: C.indigo })
        ]}),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: sp(0, 400), children: [
          new TextRun({ text: "Meeting Intelligence Platform", font: "Arial", size: 40, color: C.slate })
        ]}),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: sp(0, 120), children: [
          new TextRun({ text: "Functional Specification", font: "Arial", size: 32, bold: true, color: C.navy })
        ]}),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: sp(0, 600), children: [
          new TextRun({ text: "Version 1.0  •  May 2026", font: "Arial", size: 22, color: C.grey })
        ]}),
        gap(600),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: sp(0, 60), children: [
          new TextRun({ text: "Prepared by: LRN Development Team", font: "Arial", size: 20, color: C.navy })
        ]}),
        new Paragraph({ alignment: AlignmentType.CENTER, spacing: sp(0, 0), children: [
          new TextRun({ text: "Classification: Internal  •  Status: Draft", font: "Arial", size: 20, color: C.slate })
        ]}),
        new Paragraph({ children: [new PageBreak()] }),
      ],
    },

    // ── BODY ───────────────────────────────────────────────────────────────
    {
      properties: {
        page: { size: { width: 12240, height: 15840 }, margin: { top: 1440, right: 1440, bottom: 1440, left: 1440 } },
      },
      headers: {
        default: new Header({ children: [new Paragraph({
          spacing: sp(0,0),
          border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: C.border, space: 1 } },
          tabStops: [{ type: "right", position: 9360 }],
          children: [
            new TextRun({ text: "MeetingIQ  —  Functional Specification", font: "Arial", size: 18, color: C.slate }),
            new TextRun({ text: "\t\tVersion 1.0  |  May 2026", font: "Arial", size: 18, color: C.grey }),
          ],
        })]}),
      },
      footers: {
        default: new Footer({ children: [new Paragraph({
          alignment: AlignmentType.CENTER,
          spacing: sp(0,0),
          border: { top: { style: BorderStyle.SINGLE, size: 4, color: C.border, space: 1 } },
          children: [
            new TextRun({ text: "Page ", font: "Arial", size: 18, color: C.grey }),
            new TextRun({ children: [PageNumber.CURRENT], font: "Arial", size: 18, color: C.grey }),
            new TextRun({ text: " of ", font: "Arial", size: 18, color: C.grey }),
            new TextRun({ children: [PageNumber.TOTAL_PAGES], font: "Arial", size: 18, color: C.grey }),
          ],
        })]}),
      },
      children: [

        new TableOfContents("Table of Contents", { hyperlink: true, headingStyleRange: "1-3" }),
        new Paragraph({ children: [new PageBreak()] }),

        // 1. EXECUTIVE SUMMARY
        h1("1. Executive Summary"),
        para("MeetingIQ is a centralized Meeting Intelligence Platform designed to ensure that no decision, action item, or key commitment made in a Microsoft Teams meeting is ever lost. The platform automatically processes meeting transcripts using artificial intelligence to extract structured information, assigns tasks to the right people, and provides leaders and teams with a single place to track accountability and progress."),
        gap(),
        para("Senior leaders such as CEOs, CFOs, and department heads often attend back-to-back meetings and cannot act on every point discussed in real time. MeetingIQ solves this by acting as a persistent, intelligent assistant that captures the full context of every meeting and converts it into actionable intelligence that the whole team can act on."),
        gap(),
        noteBox("Core promise: Every meeting produces a structured action plan. Every action plan is tracked to completion. No conversation point is ever forgotten."),
        gap(240),

        // 2. PROBLEM STATEMENT
        h1("2. Problem Statement"),
        h2("2.1  The Challenge"),
        para("Organizations that rely on Microsoft Teams for internal collaboration face a recurring set of problems after every meeting:"),
        gap(60),
        bullet("Key decisions discussed in meetings are not formally recorded and are forgotten or misremembered by different attendees."),
        bullet("Action items assigned verbally during meetings are not tracked and frequently slip through the cracks."),
        bullet("Senior executives who attend many meetings each day cannot retain or follow up on every commitment made."),
        bullet("Meeting notes, when taken manually, are inconsistent in quality, depth, and format across the organization."),
        bullet("There is no single system of record for what was decided, who is responsible, and by when."),
        bullet("Teams lack visibility into each other's commitments and workloads, making accountability difficult to enforce."),
        bullet("Reminders for follow-up actions are either absent or buried in long email threads."),
        gap(),

        h2("2.2  Business Impact"),
        para("When meeting outcomes are not systematically captured and tracked:"),
        gap(60),
        bullet("Projects are delayed because next steps are unclear or duplicated."),
        bullet("Leadership time is wasted re-discussing items that were already decided."),
        bullet("Relationships with clients, partners, and regulators are damaged when commitments are not honored."),
        bullet("Financial decisions discussed but never formalized lead to budget overruns or missed revenue opportunities."),
        bullet("Employee morale suffers when accountability is inconsistent or perceived as unfair."),
        gap(240),

        // 3. OBJECTIVES
        h1("3. Objectives"),
        para("MeetingIQ is designed to achieve the following outcomes:"),
        gap(60),
        numbered("Automatically extract structured information from every Teams meeting transcript without requiring manual effort from participants."),
        numbered("Provide a centralized dashboard where every meeting, its extracted insights, and all resulting action items are visible to authorized users."),
        numbered("Auto-assign tasks to team members based on who was mentioned or committed to something during the meeting."),
        numbered("Send automated reminders and escalations so that deadlines are not missed."),
        numbered("Give leadership a real-time view of team accountability, workload, and completion rates."),
        numbered("Surface financial mentions, risk signals, and open questions so that nothing of strategic importance is overlooked."),
        numbered("Provide reports that show trends in meeting productivity and action item completion over time."),
        gap(240),

        // 4. TARGET USERS & PERSONAS
        h1("4. Target Users & Personas"),
        h2("4.1  Primary Personas"),
        gap(80),
        new Table({
          width: { size: 9360, type: WidthType.DXA },
          columnWidths: [1920, 3720, 3720],
          rows: [
            ["Persona", "Description", "Primary Need"],
            ["Executive (CEO / CFO)", "Attends multiple meetings daily. Needs a high-level summary of what was decided and what is owed to them without reading full transcripts.", "Instant meeting digest and visibility over all open commitments"],
            ["Department Head / Director", "Responsible for their team's delivery. Needs to know what tasks were assigned in meetings and whether they are on track.", "Team task board and accountability scoring"],
            ["Team Member / Contributor", "Assigned tasks in meetings they may or may not have attended. Needs to know what is expected of them and by when.", "Personal task list and deadline reminders"],
            ["Meeting Organizer / Host", "Responsible for running meetings and ensuring outcomes are captured and distributed.", "Post-meeting action plan and participant assignment tools"],
            ["Admin / Operations Manager", "Manages the platform, onboards users, and configures organizational settings.", "User management and platform configuration"],
          ].map((r, i) => makeRow(r, [1920, 3720, 3720], i === 0)),
        }),
        gap(),
        h2("4.2  Usage Context"),
        para("MeetingIQ is designed for use inside mid-to-large organizations where Microsoft Teams is the primary meeting platform, meetings involve a mix of senior leaders and operational staff, and accountability and follow-through on commitments is a known organizational pain point."),
        gap(240),

        // 5. PRODUCT OVERVIEW
        h1("5. Product Overview"),
        h2("5.1  How It Works"),
        para("MeetingIQ operates in three stages:"),
        gap(60),
        numbered("Capture — The platform connects to Microsoft Teams and retrieves the transcript of a meeting once it ends. No manual upload is required; the process is automatic for any meeting the system is authorized to monitor."),
        numbered("Extract — Artificial intelligence reads the full transcript and identifies structured items including decisions, action items, reminders, risks, open questions, financial mentions, agenda items for the next meeting, and project status updates. Each item is labeled, linked to the speaker who raised it, and categorized."),
        numbered("Act — Extracted items are published to the MeetingIQ web application. Action items are auto-assigned to the team members identified in the transcript. Reminders are scheduled. Dashboards are updated. Notifications are sent to assignees and stakeholders."),
        gap(),
        noteBox("MeetingIQ does not require attendees to take notes, fill in forms, or do anything differently during the meeting. Everything happens automatically after the meeting ends."),
        gap(200),

        h2("5.2  What MeetingIQ Captures"),
        para("From every meeting transcript, MeetingIQ automatically identifies and categorizes the following eight information types:"),
        gap(80),
        threeColTable([
          ["Category", "What Is Captured", "Example"],
          ["Decisions", "Formal or informal choices agreed to during the meeting.", "\"We will move forward with Vendor A for the billing module.\""],
          ["Action Items", "Tasks committed to by a named individual, including implied deadlines.", "\"Sarah will send the revised pricing by Friday.\""],
          ["Reminders", "Time-sensitive notices or follow-ups that need to happen at a future point.", "\"Remind the team that the audit starts on June 10th.\""],
          ["Risks & Escalations", "Issues flagged as blockers, concerns, or issues requiring attention.", "\"The API dependency from the vendor is still not resolved.\""],
          ["Open Questions", "Questions raised during the meeting that were not answered or were deferred.", "\"What is the maximum approved budget for Phase 2?\""],
          ["Financial Mentions", "Any reference to amounts, budgets, invoices, forecasts, or revenue figures.", "\"Q3 target is $2.4 million based on current run rate.\""],
          ["Next Meeting Agenda", "Items explicitly proposed for discussion in a follow-up meeting.", "\"We should revisit the timeline once the report is ready.\""],
          ["Project Status Updates", "Progress reports or milestone announcements mentioned during discussion.", "\"The onboarding module is 80% complete as of this week.\""],
        ], [2080, 4480, 2800]),
        gap(240),

        // 6. FUNCTIONAL REQUIREMENTS
        h1("6. Functional Requirements"),
        h2("6.1  Meeting Capture & Processing"),
        h3("6.1.1  Automatic Transcript Retrieval"),
        bullet("The system shall automatically retrieve the transcript of any Teams meeting configured for MeetingIQ monitoring within 15 minutes of the meeting ending."),
        bullet("Transcripts shall be retained in the system for a minimum of 12 months."),
        bullet("If a transcript is not available, the system shall notify the meeting organizer and provide a manual upload option."),
        bullet("Users with appropriate permissions shall be able to manually upload a transcript file in supported formats: VTT, DOCX, or TXT."),
        gap(),

        h3("6.1.2  AI Extraction"),
        bullet("The system shall process each transcript and extract items across all eight capture categories defined in Section 5.2."),
        bullet("Each extracted item shall include: the text of the item, the speaker who said it (if identifiable), the category, a confidence level, and the timestamp within the meeting."),
        bullet("Action items shall include an identified assignee and an inferred or stated due date."),
        bullet("The system shall present a structured meeting summary at the top of each Meeting Detail page, including a one-paragraph plain-language overview of the meeting."),
        bullet("Users shall be able to edit, reclassify, or delete any extracted item after processing."),
        bullet("Users shall be able to manually add items to any category after the fact."),
        gap(),

        h2("6.2  Dashboard"),
        h3("6.2.1  Executive Dashboard"),
        bullet("The main dashboard shall display summary statistics: total meetings this month, total open action items, overall action completion rate, and overdue items count."),
        bullet("The dashboard shall include a list of the five most recent meetings with their status and a count of open action items."),
        bullet("A priority actions section shall highlight the three to five most urgent or overdue items requiring attention."),
        bullet("A key decisions section shall surface the most significant decisions from meetings in the current week."),
        bullet("Dashboard content shall update in real time as meetings are processed and tasks change status."),
        gap(),

        h3("6.2.2  Personalization"),
        bullet("Each user shall see dashboard content filtered to meetings they attended or are responsible for, unless they have a role granting organization-wide visibility."),
        bullet("Executives and admins shall have access to an organization-wide view toggle showing all meetings and tasks."),
        gap(),

        h2("6.3  Meeting List"),
        bullet("The Meeting List shall display all meetings the user has access to, sorted by date descending."),
        bullet("Each meeting entry shall show: meeting title, date and time, duration, number of attendees, number of open action items, and a status badge (Processed, Processing, Failed, or Pending)."),
        bullet("Users shall be able to filter meetings by date range, attendee, status, and keyword search on the meeting title."),
        bullet("Users shall be able to sort the list by date, title, or number of open actions."),
        gap(),

        h2("6.4  Meeting Detail"),
        bullet("The Meeting Detail page shall display: meeting title, date, time, duration, list of attendees, and a link to the original transcript."),
        bullet("A plain-language AI summary paragraph shall appear at the top of the page."),
        bullet("All eight extraction categories shall be displayed in labeled sections below the summary."),
        bullet("Each action item shall show: description, assigned person, due date, current status, and priority level."),
        bullet("Financial mentions shall display the amount and the context sentence from the transcript."),
        bullet("Users shall be able to click any extracted item to expand it and see the original quote from the transcript."),
        bullet("The page shall include a button to export the meeting summary and action plan as a PDF or Word document."),
        bullet("The page shall include a button to share the meeting summary with participants or other users via email notification."),
        gap(),

        h2("6.5  Action Board"),
        h3("6.5.1  Kanban View"),
        bullet("The Action Board shall display all action items across all meetings in a four-column Kanban layout: To Do, In Progress, In Review, and Done."),
        bullet("Each action card shall show: task title, assignee avatar and name, due date, originating meeting name, and priority level (High, Medium, Low) indicated by a colored marker."),
        bullet("Users shall be able to drag and drop cards between columns to update the task status."),
        bullet("A progress bar on each card shall indicate completion percentage where applicable."),
        bullet("Overdue tasks shall be visually highlighted in red."),
        gap(),

        h3("6.5.2  Filtering and Sorting"),
        bullet("The Action Board shall allow filtering by: assignee, meeting, priority, due date range, and status."),
        bullet("Users shall be able to switch between Kanban view and a flat list view."),
        bullet("The board shall support bulk actions: mark multiple items as done, reassign to another person, or change due date."),
        gap(),

        h2("6.6  My Tasks"),
        bullet("The My Tasks page shall display all action items assigned to the currently logged-in user, grouped into three sections: Overdue, Due This Week, and Upcoming."),
        bullet("Each task shall show: description, due date, originating meeting, priority, and current status."),
        bullet("Users shall be able to update the status of their own tasks directly from this page."),
        bullet("A meeting timeline section shall show the user's recent and upcoming meetings in chronological order with action item counts."),
        bullet("The page shall display a completion score for the current week showing percentage of tasks completed on time."),
        gap(),

        h2("6.7  Reminders"),
        h3("6.7.1  Automatic Reminders"),
        bullet("The system shall automatically send a reminder notification to the assignee of any action item 48 hours before its due date."),
        bullet("A second reminder shall be sent 24 hours before the due date if the task is still open."),
        bullet("When a task becomes overdue, the system shall send a notification to the assignee and an escalation notification to their manager."),
        bullet("All reminders shall be sent via email and as in-app notifications."),
        gap(),

        h3("6.7.2  Reminders Page"),
        bullet("The Reminders page shall list all active reminders for the current user, showing the reminder text, related meeting, and scheduled time."),
        bullet("Users shall be able to snooze a reminder for 1 hour, 4 hours, 1 day, or dismiss it entirely."),
        bullet("Users shall be able to manually create a reminder from any meeting item."),
        gap(),

        h2("6.8  Team View"),
        bullet("The Team View page shall display a workload summary for all members of the user's team showing: name, number of open tasks, tasks due this week, tasks completed this month, and an accountability score."),
        bullet("The accountability score shall be calculated based on the percentage of tasks completed on time over the last 30 days."),
        bullet("Managers shall be able to click on any team member to see a drill-down of their assigned tasks and meeting participation."),
        bullet("The page shall display a workload comparison chart across team members."),
        gap(),

        h2("6.9  Reports"),
        h3("6.9.1  Standard Reports"),
        bullet("Meeting Volume Report: number of meetings per week or month over a selected time range."),
        bullet("Action Item Completion Report: total tasks created vs. completed vs. overdue, by person and by team."),
        bullet("Accountability Score Trend: accountability scores for each team member over the last three months."),
        bullet("Decision Log: all decisions extracted from meetings within a date range, searchable and exportable."),
        bullet("Risk and Escalation Report: all items flagged as risks or escalations, with current status."),
        bullet("Financial Mentions Report: all financial figures captured across meetings, filterable by date and meeting."),
        gap(),

        h3("6.9.2  Export"),
        bullet("All reports shall be exportable as PDF or Excel."),
        bullet("Individual meeting summaries shall be exportable as PDF or Word."),
        bullet("The Decision Log shall be exportable as Excel."),
        gap(240),

        // 7. USER WORKFLOWS
        h1("7. User Workflows"),
        h2("7.1  End-to-End Meeting Flow"),
        numbered("A Teams meeting takes place and the transcript is automatically recorded by Teams."),
        numbered("Within 15 minutes of the meeting ending, MeetingIQ retrieves the transcript."),
        numbered("The AI extraction engine processes the transcript and identifies all eight category types."),
        numbered("A Meeting Detail record is created in MeetingIQ with the full extracted summary."),
        numbered("Action items are auto-assigned to the identified individuals."),
        numbered("Assignees receive an email and in-app notification with their new tasks."),
        numbered("The meeting appears on the Dashboard and Meeting List for all authorized users."),
        numbered("Stakeholders can review the meeting summary, edit extracted items, and confirm task assignments."),
        numbered("Assignees update their task statuses as work progresses."),
        numbered("The system sends reminder notifications as due dates approach."),
        numbered("Completed tasks move to Done on the Action Board."),
        numbered("Meeting and task data feeds into the weekly and monthly reports."),
        gap(),

        h2("7.2  Executive Workflow"),
        numbered("Executive opens MeetingIQ and reviews the summary of the last three meetings at a glance on the Dashboard."),
        numbered("Executive clicks on a specific meeting to see decisions made, their own action items, and key financial mentions."),
        numbered("Executive reviews the Team View to assess whether commitments from last week's meetings have been followed through."),
        numbered("Executive uses the Reports page to present a monthly accountability summary in a leadership meeting."),
        gap(),

        h2("7.3  Team Member Workflow"),
        numbered("Team member receives an email notification after a meeting ends listing the tasks assigned to them."),
        numbered("Team member opens MeetingIQ and navigates to My Tasks."),
        numbered("Team member reviews their overdue and this-week tasks, updates statuses, and adds comments."),
        numbered("Team member receives a reminder 48 hours before a deadline and marks the task as In Review once complete."),
        numbered("Manager reviews the task and moves it to Done on the Action Board."),
        gap(),

        h2("7.4  Admin Workflow"),
        numbered("Admin onboards new users and assigns roles."),
        numbered("Admin configures which Teams channels and meetings are included in MeetingIQ monitoring."),
        numbered("Admin sets up the reporting hierarchy for escalation notifications."),
        numbered("Admin reviews the platform audit log to monitor system activity."),
        numbered("Admin configures organization-level notification preferences."),
        gap(240),

        // 8. USER ROLES & PERMISSIONS
        h1("8. User Roles & Permissions"),
        para("MeetingIQ uses a role-based access control model. Each user is assigned one primary role that determines what they can see and do within the platform."),
        gap(80),
        sixColTable([
          ["Role", "Description", "View All Meetings", "Manage Tasks", "View Reports", "Admin Access"],
          ["Administrator",  "Full platform access",                "Yes",       "Yes (all users)",  "Yes",         "Yes"],
          ["Executive",      "Org-wide visibility, read-only most", "Yes",       "Own tasks only",   "Yes",         "No"],
          ["Manager",        "Team meetings and reports",           "Own team",  "Team tasks",       "Team only",   "No"],
          ["Team Member",    "Attended meetings only",              "Own only",  "Own tasks",        "No",          "No"],
          ["Observer",       "Read-only access to assigned scope",  "Scoped",    "None",             "No",          "No"],
        ], [1700, 2560, 1400, 1400, 1200, 1100]),
        gap(240),

        // 9. NOTIFICATION SYSTEM
        h1("9. Notification System"),
        h2("9.1  Notification Types"),
        gap(80),
        threeColTable([
          ["Notification",          "Trigger",                                                  "Recipients"],
          ["Meeting Processed",     "AI extraction completes for a meeting",                    "Meeting organizer and attendees"],
          ["New Task Assigned",     "An action item is assigned from a meeting",                "Assignee"],
          ["Task Reminder (48h)",   "48 hours before a task due date",                         "Assignee"],
          ["Task Reminder (24h)",   "24 hours before a task due date",                         "Assignee"],
          ["Task Overdue",          "Task passes its due date without completion",              "Assignee and Manager"],
          ["Task Status Changed",   "Assignee updates a task status",                           "Meeting organizer"],
          ["Meeting Summary Shared","Organizer shares meeting summary",                         "All specified recipients"],
          ["Escalation Alert",      "Item flagged as a risk or blocker",                        "Assignee and Manager"],
          ["Weekly Digest",         "Every Monday morning",                                     "All active users"],
        ], [2400, 4200, 2760]),
        gap(),
        h2("9.2  Notification Preferences"),
        bullet("Each user shall be able to configure their notification preferences from their profile settings."),
        bullet("Users shall be able to enable or disable individual notification types."),
        bullet("Users shall be able to choose delivery channels: email only, in-app only, or both."),
        bullet("Admins shall be able to set organization-level defaults that users may override within permitted bounds."),
        gap(240),

        // 10. SEARCH & NAVIGATION
        h1("10. Search & Navigation"),
        bullet("A global search bar shall be present on every page, allowing users to search across meeting titles, attendee names, extracted item text, and task descriptions."),
        bullet("Search results shall be grouped by type: Meetings, Tasks, Decisions, and People."),
        bullet("Clicking a search result shall navigate directly to the relevant meeting or task detail page."),
        bullet("The application shall have a persistent left sidebar navigation with links to: Dashboard, All Meetings, Action Board, My Tasks, Reminders, Team View, and Reports."),
        bullet("The current page shall be visually highlighted in the sidebar."),
        bullet("A breadcrumb trail shall appear on all detail pages so users can navigate back to the parent list."),
        gap(240),

        // 11. DATA MANAGEMENT & RETENTION
        h1("11. Data Management & Retention"),
        h2("11.1  Data Ownership"),
        bullet("All meeting data, transcripts, and extracted items belong to the organization and are stored within the organization's configured data boundary."),
        bullet("Individual users do not own data; the organization's administrator controls data access and retention policies."),
        gap(),

        h2("11.2  Retention Policies"),
        bullet("Transcripts shall be retained for a minimum of 12 months by default. Admins may extend or shorten this period within regulatory bounds."),
        bullet("Extracted items shall be retained for a minimum of 24 months."),
        bullet("Deleted items shall be moved to an archive state for 30 days before permanent deletion."),
        bullet("Completed tasks shall be retained indefinitely as part of the accountability record."),
        gap(),

        h2("11.3  Privacy"),
        bullet("Meeting transcripts shall only be visible to the meeting organizer, attendees, and users whose role explicitly grants broader access."),
        bullet("Extracted items inherit the visibility of their source meeting."),
        bullet("Admins shall be able to flag any meeting or transcript as restricted, limiting access to named individuals only."),
        bullet("Users shall be able to request deletion of their personal data in accordance with applicable privacy regulations."),
        gap(240),

        // 12. INTEGRATION SCOPE
        h1("12. Integration Scope"),
        para("The following integrations are required for MeetingIQ to function. This section describes what each integration does from a user perspective."),
        gap(80),
        twoColTable([
          ["Integration", "Purpose"],
          ["Microsoft Teams", "Automatically retrieves meeting transcripts once meetings end. Reads attendee lists and meeting metadata such as title, date, and duration."],
          ["Email (Office 365 / SMTP)", "Delivers all notification emails to users including task assignments, reminders, digests, and escalations."],
          ["Azure Active Directory", "Used for user authentication and to retrieve organizational hierarchy for reporting and escalation routing."],
          ["Outlook Calendar", "Reads meeting invites to correlate transcripts with calendar events and pre-populate expected attendees."],
          ["Export (PDF / Word / Excel)", "Generates downloadable export files from meeting summaries, decision logs, and reports on demand."],
        ]),
        gap(),
        noteBox("Future integrations under consideration: Slack (notifications), Jira or Azure DevOps (task synchronization), Salesforce (meeting-to-CRM linkage for client meetings), and mobile push notifications."),
        gap(240),

        // 13. NON-FUNCTIONAL REQUIREMENTS
        h1("13. Non-Functional Requirements"),
        h2("13.1  Usability"),
        bullet("The application shall be usable by non-technical users without training. All primary workflows shall be completable in three clicks or fewer."),
        bullet("The user interface shall use plain language with no technical jargon visible to end users."),
        bullet("All pages shall load within three seconds on a standard corporate network connection."),
        bullet("The application shall be fully functional on the latest two versions of Google Chrome, Microsoft Edge, and Apple Safari."),
        gap(),

        h2("13.2  Accessibility"),
        bullet("The application shall conform to WCAG 2.1 Level AA accessibility standards."),
        bullet("All form fields shall have labels. All images shall have alternative text. All interactive elements shall be reachable via keyboard navigation."),
        bullet("Color shall not be the only visual indicator of status or priority; shape or text labels shall always accompany color-coded elements."),
        gap(),

        h2("13.3  Availability"),
        bullet("The application shall target 99.5% uptime during business hours (6:00 AM to 10:00 PM, Monday through Friday, local time)."),
        bullet("Scheduled maintenance shall be communicated at least 48 hours in advance and performed outside of business hours."),
        bullet("Meeting processing failures shall not block access to the rest of the application."),
        gap(),

        h2("13.4  Performance"),
        bullet("Meeting transcripts shall be processed and results available within 15 minutes of meeting end for meetings up to two hours in duration."),
        bullet("The dashboard shall display up-to-date data within 60 seconds of any change to an underlying task or meeting."),
        bullet("Search results shall return within two seconds for queries across the full data set."),
        gap(),

        h2("13.5  Scalability"),
        bullet("The platform shall support a minimum of 500 concurrent users without degradation in performance."),
        bullet("The platform shall handle a minimum of 200 meetings per day across the organization."),
        gap(240),

        // 14. ASSUMPTIONS & CONSTRAINTS
        h1("14. Assumptions & Constraints"),
        h2("14.1  Assumptions"),
        bullet("Microsoft Teams transcription is enabled for the organization's tenant and is available for all meetings configured for MeetingIQ."),
        bullet("Users have a valid organizational email address and authenticate via the organization's identity provider."),
        bullet("The organization has a defined reporting hierarchy configured in Azure Active Directory."),
        bullet("Meeting titles are descriptive enough to be meaningful in the Meeting List."),
        gap(),

        h2("14.2  Constraints"),
        bullet("MeetingIQ can only process meetings for which a transcript was generated. Meetings without transcripts must be handled via manual upload."),
        bullet("AI extraction accuracy depends on transcript quality. Poor audio quality may reduce extraction confidence."),
        bullet("The platform does not record audio or video; it only processes text transcripts."),
        bullet("Real-time in-meeting processing is not in scope for Version 1.0. Processing occurs only after the meeting ends."),
        gap(240),

        // 15. OUT OF SCOPE
        h1("15. Out of Scope (Version 1.0)"),
        bullet("Real-time in-meeting assistant or live transcription display."),
        bullet("Integration with non-Teams platforms such as Zoom, Google Meet, or WebEx (planned for a future release)."),
        bullet("Automated task synchronization with external tools such as Jira, Asana, or Azure DevOps."),
        bullet("Mobile application for iOS or Android. Web-only for Version 1.0. Mobile-responsive browser access is supported."),
        bullet("Natural language task creation via a chat or conversational interface."),
        bullet("Multi-language transcript processing beyond English."),
        bullet("AI-generated formal meeting minutes formatted for external distribution."),
        gap(240),

        // 16. GLOSSARY
        h1("16. Glossary"),
        gap(80),
        twoColTable([
          ["Term", "Definition"],
          ["Action Item", "A task committed to by a named person during a meeting, extracted and tracked by MeetingIQ."],
          ["Accountability Score", "A percentage score calculated for each user based on the proportion of tasks they completed on time within the last 30 days."],
          ["AI Extraction", "The automated process by which MeetingIQ reads a transcript and identifies structured information across the eight capture categories."],
          ["Assignee", "The team member to whom an action item has been assigned, either automatically by MeetingIQ or manually by a user."],
          ["Capture Category", "One of the eight types of information MeetingIQ identifies from meeting transcripts: Decisions, Action Items, Reminders, Risks and Escalations, Open Questions, Financial Mentions, Next Meeting Agenda, and Project Status Updates."],
          ["Decision", "A formal or informal agreement reached during a meeting, recorded as a structured item by MeetingIQ."],
          ["Escalation", "An item flagged as a blocker, significant risk, or issue requiring management attention."],
          ["Executive", "A MeetingIQ user role with organization-wide read access and elevated visibility over all meetings and tasks."],
          ["Meeting Detail", "The MeetingIQ page that displays the full extracted summary, all eight category items, and all action items for a specific meeting."],
          ["MeetingIQ", "The Meeting Intelligence Platform described in this document."],
          ["Open Question", "A question raised during a meeting that was not answered or was explicitly deferred for later resolution."],
          ["Reminder", "A time-sensitive notification, either auto-generated by MeetingIQ based on task due dates or manually created by a user."],
          ["Transcript", "The text record of a Teams meeting, generated automatically by Microsoft Teams when transcription is enabled."],
          ["Weekly Digest", "An automated email sent every Monday to each user summarizing open tasks, overdue items, and upcoming deadlines for the coming week."],
        ]),
        gap(400),

        new Paragraph({
          alignment: AlignmentType.CENTER,
          spacing: sp(200, 0),
          border: { top: { style: BorderStyle.SINGLE, size: 4, color: C.border, space: 1 } },
          children: [
            new TextRun({ text: "End of Document  —  MeetingIQ Functional Specification v1.0  —  May 2026", font: "Arial", size: 18, color: C.grey, italic: true }),
          ],
        }),

      ],
    },
  ],
});

Packer.toBuffer(doc).then(buffer => {
  fs.writeFileSync("/sessions/hopeful-blissful-dirac/mnt/LRNDevTeam/MeetingIQ_FunctionalSpec.docx", buffer);
  console.log("Done: MeetingIQ_FunctionalSpec.docx written.");
});

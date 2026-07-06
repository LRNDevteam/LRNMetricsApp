namespace LabMetricsDashboard.Models.Notes;

/// <summary>
/// Report/period context a Notes component is scoped to. For Executive
/// Summary the ReportName is fixed ("Executive Summary") while RunId and
/// WeekRange come from the report banner (see PhiExecutiveSummaryViewModel).
/// </summary>
public sealed class NotesContext
{
    public int    ReportKeyId    { get; set; }
    public string ReportName     { get; set; } = "Executive Summary";
    public string? ReportRunId   { get; set; }
    public string? WeekRangeText { get; set; }
    public DateTime? WeekRangeStart { get; set; }
    public DateTime? WeekRangeEnd   { get; set; }
}

/// <summary>One note/insight entry (active or archived).</summary>
public sealed class NoteInsight
{
    public int      NoteId            { get; set; }
    public int?     EntryNo           { get; set; }
    public int      ReportKeyId       { get; set; }
    public string   ReportName        { get; set; } = string.Empty;
    public string?  ReportRunId       { get; set; }
    public string?  WeekRangeText     { get; set; }
    public DateTime? WeekRangeStart   { get; set; }
    public DateTime? WeekRangeEnd     { get; set; }

    public string   RiskCode          { get; set; } = "Yellow";
    public string?  RiskLabel         { get; set; }
    public string?  ColorHex          { get; set; }
    public string?  ResponsibleParty  { get; set; }
    public string?  Insights          { get; set; }
    public int?     NoOfSamples       { get; set; }
    public string?  DataLink          { get; set; }
    public string?  ActionSolution    { get; set; }
    public string?  FeedbackResponse  { get; set; }
    public string?  Responsibility    { get; set; }
    public DateTime? DiscussionDate   { get; set; }
    public DateTime? ETA              { get; set; }
    public DateTime? ClosedDate       { get; set; }
    public string   StatusCode        { get; set; } = "Open";
    public string?  StatusLabel       { get; set; }

    public string   ArchiveStatus     { get; set; } = "Active";
    public DateTime? ArchivedDate     { get; set; }
    public int      VersionNumber     { get; set; } = 1;
    public string?  CreatedBy         { get; set; }
    public DateTime? CreatedDateTime  { get; set; }
    public string?  LastEditedBy      { get; set; }
    public DateTime? LastEditedDateTime { get; set; }

    public bool     IsOverdueETA      { get; set; }
    public bool     IsEditable        { get; set; } = true;
}

/// <summary>A single revision/audit event on a note.</summary>
public sealed class NoteRevision
{
    public int      RevisionId      { get; set; }
    public int      NoteId          { get; set; }
    public int      VersionNumber   { get; set; }
    public string   EventType       { get; set; } = string.Empty;
    public string?  SourceAction    { get; set; }
    public string?  RevisionSummary { get; set; }
    public string?  EventUser       { get; set; }
    public DateTime? EventDateTime  { get; set; }
}

/// <summary>Lookup lists for Risk/Status/Responsible Party dropdowns.</summary>
public sealed class NotesLookups
{
    public List<NotesLookupItem> Risks             { get; set; } = [];
    public List<NotesLookupItem> Statuses          { get; set; } = [];
    public List<string>          ResponsibleParties { get; set; } = [];
}

public sealed class NotesLookupItem
{
    public int    Id    { get; set; }
    public string Code  { get; set; } = string.Empty;
    public string Label { get; set; } = string.Empty;
    public string? ColorHex { get; set; }
}

/// <summary>Archive summary card values.</summary>
public sealed class NotesArchiveSummary
{
    public int       TotalArchived    { get; set; }
    public int       RedRiskArchived  { get; set; }
    public int       ClosedThisMonth  { get; set; }
    public DateTime? LastArchivedDate { get; set; }
}

/// <summary>Payload posted from the Add/Edit note form.</summary>
public sealed class NoteSaveRequest
{
    public int?     NoteId           { get; set; }   // null = insert
    public string   ReportName       { get; set; } = "Executive Summary";
    public string?  ReportRunId      { get; set; }
    public string?  WeekRangeText    { get; set; }
    public DateTime? WeekRangeStart  { get; set; }
    public DateTime? WeekRangeEnd    { get; set; }

    public string   RiskCode         { get; set; } = "Yellow";
    public string?  ResponsibleParty { get; set; }
    public string?  Insights         { get; set; }
    public int?     NoOfSamples      { get; set; }
    public string?  DataLink         { get; set; }
    public string?  ActionSolution   { get; set; }
    public string?  FeedbackResponse { get; set; }
    public string?  Responsibility   { get; set; }
    public DateTime? DiscussionDate  { get; set; }
    public DateTime? ETA             { get; set; }
    public DateTime? ClosedDate      { get; set; }
    public string   StatusCode       { get; set; } = "Open";
}

/// <summary>Generic result for write operations.</summary>
public sealed class NotesResult
{
    public bool    Success { get; set; }
    public int     NoteId  { get; set; }
    public string? Message { get; set; }
}

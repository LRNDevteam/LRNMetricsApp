using ClosedXML.Excel;
using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services;

public interface IDenialMapperExcelService
{
    Task<byte[]> ExportAsync(CancellationToken ct);
    byte[] BuildImportTemplate();
}

// Mirrors DenialCodeMasterExcelService's export/template pattern for the Super Master. Header
// text must keep matching what DenialMapperService.ImportSuperMasterAsync's name-based column
// lookup recognizes, so a Super Master exported here re-imports cleanly via POST .../upload.
public sealed class DenialMapperExcelService : IDenialMapperExcelService
{
    private const string SheetName = "Denial Classifier";
    private const string TitleText = "DENIAL - ACTION SUPER MASTER";
    private const int DenialDescriptionColumn = 2;
    private const double DenialDescriptionMinWidth = 45;

    private static readonly string[] TemplateHeaders =
    [
        "Denial Code", "Denial Description", "Denial Classification", "Coverage Status", "ICD Compliance Status",
        "Denial Validity", "Action Code", "Recommended Action", "Action Category", "Task", "SLA (Days)", "Priority"
    ];

    private readonly IDenialMapperRepository _repository;

    public DenialMapperExcelService(IDenialMapperRepository repository)
    {
        _repository = repository;
    }

    public async Task<byte[]> ExportAsync(CancellationToken ct)
    {
        var records = await GetAllSuperMasterRecordsAsync(ct);

        using var workbook = new XLWorkbook();
        var sheet = BuildSheetWithHeader(workbook);

        var row = 3;
        foreach (var record in records)
        {
            sheet.Cell(row, 1).Value = record.DenialCode;
            sheet.Cell(row, 2).Value = record.DenialDescription;
            sheet.Cell(row, 3).Value = record.DenialClassification;
            sheet.Cell(row, 4).Value = record.CoverageStatus;
            sheet.Cell(row, 5).Value = record.ICDComplianceStatus;
            sheet.Cell(row, 6).Value = record.DenialValidity;
            sheet.Cell(row, 7).Value = record.ActionCode;
            sheet.Cell(row, 8).Value = record.RecommendedAction;
            sheet.Cell(row, 9).Value = record.ActionCategory;
            sheet.Cell(row, 10).Value = record.Task;
            sheet.Cell(row, 11).Value = record.SLA;
            sheet.Cell(row, 12).Value = record.Priority;
            row++;
        }

        return Finish(workbook, sheet);
    }

    public byte[] BuildImportTemplate()
    {
        using var workbook = new XLWorkbook();
        var sheet = BuildSheetWithHeader(workbook);

        // One illustrative sample row. ImportSuperMasterAsync skips rows with a blank Denial Code
        // and Action Code, so leaving, replacing, or deleting this row before uploading is safe.
        string[] sample =
        [
            "CO-16", "Claim/service lacks information", "Documentation Denial", "Covered", "Compliant",
            "Valid", "AC-01", "Review and resubmit the claim with required documentation", "Rebill",
            "Review and rebill claim", "30", "High"
        ];
        for (var i = 0; i < sample.Length; i++) sheet.Cell(3, i + 1).Value = sample[i];

        return Finish(workbook, sheet);
    }

    private async Task<List<DenialMapperRecord>> GetAllSuperMasterRecordsAsync(CancellationToken ct)
    {
        var records = new List<DenialMapperRecord>();
        for (var page = 1; ; page++)
        {
            var batch = await _repository.SuperMasterAsync(null, null, page, 200, ct);
            records.AddRange(batch.Items);
            if (batch.Items.Count < 200) break;
        }
        return records;
    }

    private static IXLWorksheet BuildSheetWithHeader(XLWorkbook workbook)
    {
        var sheet = workbook.Worksheets.Add(SheetName);
        DenialExcelTheme.ApplyDefaults(sheet);
        sheet.TabColor = DenialExcelTheme.TabGreen;
        sheet.Cell(1, 1).Value = TitleText;
        var titleRange = sheet.Range(1, 1, 1, TemplateHeaders.Length).Merge();
        titleRange.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Font.SetFontSize(DenialExcelTheme.FontSizeTitle);
        titleRange.Style.Fill.SetBackgroundColor(DenialExcelTheme.TitleBg);
        titleRange.Style.Alignment.SetVertical(XLAlignmentVerticalValues.Center);

        for (var i = 0; i < TemplateHeaders.Length; i++)
            DenialExcelTheme.StyleHeaderCell(sheet.Cell(2, i + 1).SetValue(TemplateHeaders[i]));

        return sheet;
    }

    private static byte[] Finish(XLWorkbook workbook, IXLWorksheet sheet)
    {
        sheet.SheetView.FreezeRows(2);
        sheet.Columns().AdjustToContents();
        if (sheet.Column(DenialDescriptionColumn).Width < DenialDescriptionMinWidth)
            sheet.Column(DenialDescriptionColumn).Width = DenialDescriptionMinWidth;

        using var stream = new MemoryStream();
        workbook.SaveAs(stream);
        return stream.ToArray();
    }
}

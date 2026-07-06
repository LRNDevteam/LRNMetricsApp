using DenialDatabaseProcessorWorker.Models;
using Microsoft.Extensions.Logging;

namespace DenialDatabaseProcessorWorker.Services.SharePoint;

public sealed class SharePointUploader : ISharePointUploader
{
    private readonly SharePointGraphClient _graph;
    private readonly ILogger<SharePointUploader> _logger;

    public SharePointUploader(SharePointGraphClient graph, ILogger<SharePointUploader> logger)
    {
        _graph = graph;
        _logger = logger;
    }

    public async Task UploadIfEnabledAsync(LabConfig lab, string localFilePath, DateTime localDateTime, CancellationToken ct)
    {
        if (!_graph.Enabled)
        {
            _logger.LogInformation("SharePoint upload disabled. Skipping upload for {LabName}", lab.LabName);
            return;
        }

        var baseFolder = SharePointPathParser.ExtractFolderPathFromLink(lab.SharePointUploadPath);
        if (string.IsNullOrWhiteSpace(baseFolder))
            throw new InvalidOperationException($"SharePointUploadPath could not be parsed for lab '{lab.LabName}'.");

        var monthFolder = localDateTime.ToString("MMMM-yyyy");
        var dateFolder = localDateTime.ToString("MMddyyyy");

        var sub = $"{lab.LabName}/{monthFolder}/{dateFolder}";

        await _graph.UploadAsync(baseFolder, sub, localFilePath, ct);
    }
}

namespace LRN.MasterFileProcessorWorker.SharePoint;

public sealed class SharePointPublishedFile
{
    public string? FileName { get; set; }
    public string? LocalPath { get; set; }
    public string? RelativeSharePointPath { get; set; }
    public string? WebUrl { get; set; }
    public string? ShareLinkUrl { get; set; }

    public string? NotificationUrl =>
        !string.IsNullOrWhiteSpace(ShareLinkUrl) ? ShareLinkUrl :
        !string.IsNullOrWhiteSpace(WebUrl) ? WebUrl :
        LocalPath;
}

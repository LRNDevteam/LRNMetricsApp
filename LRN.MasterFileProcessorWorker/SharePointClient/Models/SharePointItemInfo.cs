namespace LRN.SharePointClient.Models;

public record SharePointItemInfo(
    string Id,
    string Name,
    bool IsFolder,
    DateTimeOffset LastModifiedUtc,
    long? SizeBytes
);

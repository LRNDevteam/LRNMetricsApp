using LRN.SharePointClient.Models;

namespace LRN.MasterFileProcessorWorker.Services;

public sealed record MasterFileDiscoveryResult(
    string EffectiveFolderPath,
    SharePointItemInfo File
);

namespace LRN.AzBlobSync.Models;

public sealed class BlobSyncOptions
{
    public const string Section = "BlobSync";

    /// <summary>Local Three-Pillar root. Week-range folders are created under this path.</summary>
    public string WatchPath { get; set; } = string.Empty;

    /// <summary>Local JSON that stores the most recently uploaded week-folder name.</summary>
    public string StateJsonPath { get; set; } = string.Empty;

    /// <summary>Text log file. Date is appended (azblob-sync-20260819.log).</summary>
    public string LogPath { get; set; } = string.Empty;

    public int LogRetainDays { get; set; } = 30;

    /// <summary>Wait until LIS/PMS/Cash have not been written for this many seconds.</summary>
    public int SettleSeconds { get; set; } = 8;

    public List<string> RequiredJsonFiles { get; set; } = ["LIS.json", "PMS.json", "Cash.json"];

    public string KeyVaultUri { get; set; } = string.Empty;

    public string SecretName { get; set; } = string.Empty;

    /// <summary>Optional fallback. Prefer Key Vault SAS. Do not commit an account key.</summary>
    public string ConnectionString { get; set; } = string.Empty;

    public string ContainerName { get; set; } = "threepillar";

    /// <summary>Virtual folder under the container. Created on first upload if missing.</summary>
    public string BlobPrefix { get; set; } = "Beech_Tree_inputs";
}

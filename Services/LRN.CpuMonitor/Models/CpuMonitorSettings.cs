namespace LRN.CpuMonitor.Models;

public sealed class CpuMonitorSettings
{
    public const string SectionName = "CpuMonitorSettings";

    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Breach threshold. Compared against the same figure Task Manager's CPU column
    /// shows: processor time as a percentage of the whole machine, subject to
    /// <see cref="NormalizeByCoreCount"/>. 90 means "eating nearly every core".
    /// </summary>
    public double CpuThresholdPercent { get; set; } = 90;

    /// <summary>
    /// When true (default) a process saturating every core reads 100%, matching Task
    /// Manager. When false a single saturated core reads 100%, so the value can reach
    /// 100 * core count, which is what catches one runaway thread on a big box.
    /// </summary>
    public bool NormalizeByCoreCount { get; set; } = true;

    /// <summary>
    /// Logs the top consumers together when TOTAL machine CPU exceeds this, even if
    /// no single process crosses <see cref="CpuThresholdPercent"/>. Load spread across
    /// many processes cannot be caught by a per-process rule at any setting, which is
    /// the common case for a server that is busy but has no single culprit. Zero
    /// disables it.
    /// </summary>
    public double MachineCpuThresholdPercent { get; set; } = 85;

    /// <summary>How many consumers to name in a machine-level alert.</summary>
    public int MachineTopConsumers { get; set; } = 5;

    /// <summary>
    /// Length of the measurement window. CPU percentage is meaningless without one:
    /// it is always a rate measured between two readings of total processor time.
    /// </summary>
    public int SampleWindowSeconds { get; set; } = 5;

    /// <summary>Idle time between the end of one measurement window and the next.</summary>
    public int PollIntervalSeconds { get; set; } = 10;

    /// <summary>
    /// How many back-to-back windows a process must stay over the threshold before it
    /// is reported. One means report the first window that breaches, which is what
    /// "log it when it goes over" normally means. Raise it only if short start-up or
    /// report-render spikes turn out to be noise.
    /// </summary>
    public int ConsecutiveSamplesBeforeAlert { get; set; } = 1;

    /// <summary>
    /// Suppresses repeat alerts for the same PID while it stays hot. Zero logs every
    /// breaching window, so the log shows how long the process stayed over.
    /// </summary>
    public int AlertCooldownMinutes { get; set; } = 0;

    /// <summary>
    /// How often to log the current top CPU consumers even when nothing breaches.
    /// Without this a quiet server and a broken service produce identical logs, and
    /// it is also the easiest way to see what your real usage looks like before
    /// settling on a threshold. Zero disables it.
    /// </summary>
    public int HeartbeatMinutes { get; set; } = 10;

    /// <summary>Process names to never report, without the .exe (case-insensitive).</summary>
    public string[] IgnoreProcessNames { get; set; } = ["Idle", "System", "Memory Compression"];

    /// <summary>Machine-readable breach log, newline-delimited JSON. Blank disables it.</summary>
    public string BreachLogPath { get; set; } = "";

    /// <summary>Process names that trigger the SQL Server probe, without the .exe.</summary>
    public string[] SqlProcessNames { get; set; } = ["sqlservr"];

    /// <summary>
    /// Connection string used only to read CPU-attribution DMVs. The login needs
    /// VIEW SERVER STATE. Prefer Integrated Security so no password is stored here.
    /// Blank disables the probe.
    /// </summary>
    public string SqlConnectionString { get; set; } = "";

    /// <summary>How many live requests to report, highest CPU first.</summary>
    public int SqlTopSessions { get; set; } = 5;

    /// <summary>Process names that trigger the Office launch probe, without the .exe.</summary>
    public string[] OfficeProcessNames { get; set; } = ["EXCEL", "WINWORD", "POWERPNT", "MSACCESS", "OUTLOOK"];
}

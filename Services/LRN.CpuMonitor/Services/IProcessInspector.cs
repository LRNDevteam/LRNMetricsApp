using LRN.CpuMonitor.Models;

namespace LRN.CpuMonitor.Services;

public interface IProcessInspector
{
    /// <summary>
    /// Resolves name, path, command line, owner and parent chain for a PID. Returns
    /// null if the process exited before it could be inspected.
    /// </summary>
    ProcessDetails? Describe(int pid);

    /// <summary>
    /// Works out why an Office process is running -- COM automation, a document open,
    /// or an interactive launch -- and names plausible automation clients.
    /// </summary>
    OfficeLaunchOrigin ExplainOfficeLaunch(ProcessDetails details);
}

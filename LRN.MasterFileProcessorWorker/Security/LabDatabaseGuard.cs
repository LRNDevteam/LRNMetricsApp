using Microsoft.Data.SqlClient;

namespace LRN.MasterFileProcessorWorker.Security;

/// <summary>A lab's data was about to be written to a database that is not that lab's.</summary>
public sealed class LabRoutingException : InvalidOperationException
{
    public const string ErrorCode = "LAB_ROUTING_MISMATCH";

    public LabRoutingException(string message) : base(message) { }
}

/// <summary>
/// HIPAA checklist MF-05: before a lab's rows are written, confirm the target database is that lab's
/// own. Loading one lab's patients into another lab's database is the worst failure this worker can
/// have - it is a disclosure to the wrong covered entity, not just bad data.
/// <para>
/// The lab's database is reached through a Key Vault secret chosen by <c>LabDbConnectionKey</c>, so
/// a secret copied from another lab, or a key pointing at the wrong secret, would send the file to
/// the wrong place with nothing else noticing. The lab's <c>*FieldMappings.json</c> names the
/// database it belongs to (<c>DatabaseName</c>); this compares the two and refuses on any mismatch.
/// </para>
/// <para>
/// Checked twice: against the connection string before anything is written (so not even a
/// LineClaimFileLogs row lands in the wrong place), and against <see cref="SqlConnection.Database"/>
/// once the load's connection is open (so a login whose default database differs is caught too).
/// </para>
/// </summary>
public static class LabDatabaseGuard
{
    /// <summary>Throws <see cref="LabRoutingException"/> unless the connection string targets the lab's database.</summary>
    public static void EnsureConnectionTargetsLab(int labId, string? expectedDatabase, string connectionString)
    {
        string catalog;

        try
        {
            catalog = new SqlConnectionStringBuilder(connectionString).InitialCatalog;
        }
        catch (ArgumentException)
        {
            catalog = "";
        }

        EnsureDatabaseIsLabs(labId, expectedDatabase, catalog);
    }

    /// <summary>Throws <see cref="LabRoutingException"/> unless the open connection is on the lab's database.</summary>
    public static void EnsureOpenConnectionIsLabs(int labId, string? expectedDatabase, SqlConnection openConnection) =>
        EnsureDatabaseIsLabs(labId, expectedDatabase, openConnection.Database);

    /// <summary>The mismatch message, or null when <paramref name="actualDatabase"/> is the lab's database.</summary>
    public static string? Check(int labId, string? expectedDatabase, string? actualDatabase)
    {
        if (string.IsNullOrWhiteSpace(expectedDatabase))
        {
            return $"Lab {labId}: its *FieldMappings.json has no \"DatabaseName\", so the target database " +
                   "cannot be confirmed as this lab's. Add the lab's database name to the mapping file.";
        }

        if (string.IsNullOrWhiteSpace(actualDatabase))
        {
            return $"Lab {labId}: the connection string names no database (Initial Catalog), so the target " +
                   $"cannot be confirmed as '{expectedDatabase}'. Add it to the lab's Key Vault secret.";
        }

        if (!string.Equals(expectedDatabase.Trim(), actualDatabase.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            return $"Lab {labId}: refusing to load - the lab's connection targets database '{actualDatabase}', " +
                   $"but this lab's data belongs in '{expectedDatabase}' (DatabaseName in its *FieldMappings.json). " +
                   "Check the lab's LabDbConnectionKey and the Key Vault secret it names.";
        }

        return null;
    }

    private static void EnsureDatabaseIsLabs(int labId, string? expectedDatabase, string? actualDatabase)
    {
        var problem = Check(labId, expectedDatabase, actualDatabase);

        if (problem is not null)
            throw new LabRoutingException(problem);
    }
}

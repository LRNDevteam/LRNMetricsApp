using LRN.AI.Application.Common;

namespace LRN.AI.Application.Abstractions;

/// <summary>
/// HIPAA audit-control sink (45 CFR 164.312(b)): records who used the AI platform, when, for what and with
/// what outcome. Phase 1 writes to a dedicated log category; Phase 2 persists to the LRNAI database.
/// </summary>
public interface IAiAuditLogger
{
    void Record(AiAuditEvent auditEvent);
}

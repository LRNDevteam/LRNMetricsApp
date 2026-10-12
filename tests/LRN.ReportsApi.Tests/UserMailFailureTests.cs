using LRN.ReportsApi.Models;
using LRN.ReportsApi.Services.UserMail;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace LRN.ReportsApi.Tests;

/// <summary>A mail failure must never stop user creation: it is reported and logged as failed.</summary>
public class UserMailFailureTests
{
    private const string Guid1 = "0cde51ec-0000-4000-8000-000000000001";
    private const string Guid2 = "b13b3674-0000-4000-8000-000000000002";

    [Fact]
    public void Usable_credentials_pass() =>
        Assert.Null(GraphUserMailSender.CredentialProblem(Guid2, Guid1, "secret", "noreply@lrn.com"));

    [Fact]
    public void Tenant_domain_is_accepted() =>
        Assert.Null(GraphUserMailSender.CredentialProblem("contoso.onmicrosoft.com", Guid1, "secret", "noreply@lrn.com"));

    [Theory]
    [InlineData(null, Guid1, "s", "a@b.com", "TenantId")]
    [InlineData(Guid2, null, "s", "a@b.com", "ClientId")]
    [InlineData(Guid2, Guid1, null, "a@b.com", "ClientSecret")]
    [InlineData(Guid2, Guid1, "s", null, "SenderMailbox")]
    [InlineData("b13b367440d-bb61-bef34ac2ddf3", Guid1, "s", "a@b.com", "tenant ID is not valid")]
    [InlineData(Guid2, "not-a-guid", "s", "a@b.com", "client ID is not valid")]
    public void Bad_or_missing_credentials_are_reported(string? tenant, string? client, string? secret, string? sender, string expected) =>
        Assert.Contains(expected, GraphUserMailSender.CredentialProblem(tenant, client, secret, sender));

    private static UserInvitationService Service(FakeRepository repo, IUserMailSender sender) =>
        new(repo, sender, new StaticOptions(new UserMailOptions { FirstLoginUrl = "https://example.test/Account/SetPassword" }),
            NullLogger<UserInvitationService>.Instance);

    [Fact]
    public async Task A_sender_that_throws_is_logged_as_failed_and_never_thrown()
    {
        var repo = new FakeRepository();
        var (sent, error) = await Service(repo, new ThrowingSender()).SendInvitationAsync(7, UserMailApplications.ArWorkbench, "admin", false, default);

        Assert.False(sent);
        Assert.NotNull(error);
        var log = Assert.Single(repo.Logs);
        Assert.False(log.Sent);
        Assert.Equal("new.user@lab.com", log.To);
    }

    [Fact]
    public async Task A_failed_send_is_logged_as_failed()
    {
        var repo = new FakeRepository();
        var (sent, error) = await Service(repo, new FailingSender("Could not get a Graph token")).SendInvitationAsync(7, UserMailApplications.LrnMetrics, "admin", false, default);

        Assert.False(sent);
        Assert.Equal("Could not get a Graph token", error);
        var log = Assert.Single(repo.Logs);
        Assert.False(log.Sent);
        Assert.Equal("Could not get a Graph token", log.Error);
    }

    [Fact]
    public async Task Missing_invitation_tables_do_not_throw()
    {
        var repo = new FakeRepository { FailCreateInvitation = true, FailLog = true };
        var (sent, error) = await Service(repo, new FailingSender("x")).SendInvitationAsync(7, UserMailApplications.ArWorkbench, "admin", false, default);
        Assert.False(sent);
        Assert.Contains("could not be sent", error);
    }

    [Fact]
    public void Support_emails_merge_the_list_and_the_legacy_setting()
    {
        var o = new UserMailOptions
        {
            SupportEmails = ["Prasanna@labrevenuenavigator.com", " Jameel@labrevenuenavigator.com ", ""],
            SupportEmail = "jameel@labrevenuenavigator.com"
        };
        Assert.Equal(["Prasanna@labrevenuenavigator.com", "Jameel@labrevenuenavigator.com"], o.AllSupportEmails());
    }

    [Fact]
    public void Invitation_lists_every_support_contact()
    {
        var html = UserInvitationService.BuildHtml(UserMailApplications.ArWorkbench, "new.user", ["AR Agent"], ["InHealth"], "ABCD2345",
            "https://example.test/x?token=t", 72, null, null, ["Prasanna@labrevenuenavigator.com", "Jameel@labrevenuenavigator.com"]);
        Assert.Contains("Need help signing in? Contact LRN Support at", html);
        Assert.Contains("mailto:Prasanna@labrevenuenavigator.com", html);
        Assert.Contains("mailto:Jameel@labrevenuenavigator.com", html);
        Assert.Contains("</a> or <a", html);
    }

    [Fact]
    public void Invitation_without_support_contacts_falls_back_to_the_administrator()
    {
        var html = UserInvitationService.BuildHtml(UserMailApplications.LrnMetrics, "u", [], [], "ABCD2345", "https://e.test/x?token=t", 72, null, null, []);
        Assert.DoesNotContain("Need help signing in", html);
        Assert.Contains("your LRN administrator", html);
    }

    private sealed class StaticOptions(UserMailOptions value) : IOptionsMonitor<UserMailOptions>
    {
        public UserMailOptions CurrentValue => value;
        public UserMailOptions Get(string? name) => value;
        public IDisposable? OnChange(Action<UserMailOptions, string?> listener) => null;
    }

    private sealed class ThrowingSender : IUserMailSender
    {
        public string? SenderAddress => throw new InvalidOperationException("no sender");
        public Task<(bool Sent, string? Error)> SendAsync(string to, string subject, string htmlBody, CancellationToken ct)
            => throw new ArgumentException("Invalid tenant id provided.");
    }

    private sealed class FailingSender(string error) : IUserMailSender
    {
        public string? SenderAddress => "noreply@lrn.com";
        public Task<(bool Sent, string? Error)> SendAsync(string to, string subject, string htmlBody, CancellationToken ct)
            => Task.FromResult<(bool, string?)>((false, error));
    }

    private sealed record LogEntry(string To, bool Sent, string? Error);

    private sealed class FakeRepository : IUserMailRepository
    {
        public bool FailCreateInvitation { get; init; }
        public bool FailLog { get; init; }
        public List<LogEntry> Logs { get; } = new();

        public Task<UserMailTarget?> GetTargetAsync(int labUserId, CancellationToken ct) =>
            Task.FromResult<UserMailTarget?>(new UserMailTarget(labUserId, "new.user", "new.user@lab.com", true, ["AR Workbench - AR Agent"], [2], ["InHealth"]));

        public Task CreateInvitationAsync(int labUserId, string application, string tokenHash, string otpHash, DateTime expiresUtc, string createdBy, CancellationToken ct) =>
            FailCreateInvitation ? throw new InvalidOperationException("Invalid object name 'dbo.UserInvitation'.") : Task.CompletedTask;

        public Task WriteEmailLogAsync(int? labUserId, string? userName, string application, string emailType, string toAddress, string? fromAddress,
            string subject, string? bodyHtml, bool sent, string? error, string? sentBy, CancellationToken ct)
        {
            if (FailLog) throw new InvalidOperationException("Invalid object name 'dbo.EmailLog'.");
            Logs.Add(new LogEntry(toAddress, sent, error));
            return Task.CompletedTask;
        }

        public Task<Dictionary<int, ArWorkbenchInviteStatus>> GetInviteStatusesAsync(IReadOnlyCollection<int> labUserIds, CancellationToken ct) => throw new NotImplementedException();
        public Task<UserEmailLogPage> GetEmailLogAsync(UserEmailLogQuery query, IReadOnlyCollection<int>? labIds, CancellationToken ct) => throw new NotImplementedException();
        public Task<UserEmailDetail?> GetEmailAsync(long emailLogId, IReadOnlyCollection<int>? labIds, CancellationToken ct) => throw new NotImplementedException();
        public Task<IReadOnlyList<EmailTypeSummary>> GetEmailTypesAsync(IReadOnlyCollection<int>? labIds, CancellationToken ct) => throw new NotImplementedException();
    }
}

// ---------------------------------------------------------------------
// ADD THIS TO YOUR EXISTING WEB APP (not the new backend proxy).
//
// What it does: when a signed-in user's browser asks for it, this hands
// back a small signed ticket proving "this person is logged in, as of
// right now." The chat widget's JavaScript fetches one of these before
// every question and sends it on to the reimbursement backend, which
// checks it before answering. The ticket expires after 30 minutes, so a
// copied/stolen ticket stops working on its own shortly after.
//
// This assumes your app already has sign-in working (it must, since you
// already require a login) — this endpoint just piggybacks on whatever
// authentication you already have configured.
//
// If your app uses top-level Program.cs statements (typical for new
// ASP.NET Core apps), paste the two blocks below into it: the config
// block near your other configuration reads, and the endpoint block
// after app.UseAuthorization().
//
// If your app uses Controllers instead, put the endpoint logic inside a
// [Authorize] action method on any controller instead of app.MapGet.
// ---------------------------------------------------------------------

// --- packages needed (skip any already present) ---
// dotnet add package System.IdentityModel.Tokens.Jwt
// dotnet add package Microsoft.IdentityModel.Tokens

using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Microsoft.IdentityModel.Tokens;

// --- configuration block: add near your other configuration reads ---
// Add the matching section to this app's appsettings.json:
//
// "ChatToken": {
//   "SigningKey": "REPLACE_WITH_A_LONG_RANDOM_SECRET_SHARED_WITH_THE_WEB_APP",
//   "Issuer": "ReimbursementWebApp",
//   "Audience": "ReimbursementAgentProxy"
// }
//
// IMPORTANT: "SigningKey" must be the EXACT same string configured on the
// ReimbursementAgentProxy App Service. Generate one long random value once
// (e.g. a 32+ character password generator output) and use it in both places.
var chatTokenKey = builder.Configuration["ChatToken:SigningKey"]
    ?? throw new InvalidOperationException("ChatToken:SigningKey is not configured.");
var chatTokenIssuer = builder.Configuration["ChatToken:Issuer"] ?? "ReimbursementWebApp";
var chatTokenAudience = builder.Configuration["ChatToken:Audience"] ?? "ReimbursementAgentProxy";

// --- endpoint block: add after app.UseAuthentication() / app.UseAuthorization() ---
app.MapGet("/api/chat-token", (ClaimsPrincipal user) =>
{
    if (user.Identity is null || !user.Identity.IsAuthenticated)
    {
        return Results.Unauthorized();
    }

    var signingKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(chatTokenKey));
    var credentials = new SigningCredentials(signingKey, SecurityAlgorithms.HmacSha256);

    var token = new JwtSecurityToken(
        issuer: chatTokenIssuer,
        audience: chatTokenAudience,
        claims: new[] { new Claim(ClaimTypes.Name, user.Identity.Name ?? "unknown") },
        expires: DateTime.UtcNow.AddMinutes(30),
        signingCredentials: credentials);

    var tokenString = new JwtSecurityTokenHandler().WriteToken(token);
    return Results.Ok(new { token = tokenString, expiresInSeconds = 1800 });
}).RequireAuthorization();

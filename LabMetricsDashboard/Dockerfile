# LabMetricsDashboard - the ASP.NET Core MVC app from LabMetricsDashboard.sln (net9.0).
#
# BUILD FROM THE REPOSITORY ROOT, not from this folder:
#
#   docker build -f LabMetricsDashboard/Dockerfile -t lrn-dashboard .
#
# The project references ..\LRN.ProductionReports and ..\LRN.ReportQueue.Shared, so a
# context rooted at this directory cannot see them.
#
# Note on global.json: LabMetricsDashboard/global.json pins SDK 9.0.312. It is NOT in
# scope here because the build runs with the working directory at /src (the repo root)
# and the SDK resolver walks up from the working directory, not from the project. If you
# ever move WORKDIR into the project folder, the SDK image must be >= 9.0.312.

# ── Build ────────────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src

# Restore first, against the project files alone. This layer is cached until a
# .csproj changes, so ordinary source edits skip the NuGet download entirely.
COPY ["LabMetricsDashboard/LabMetricsDashboard.csproj", "LabMetricsDashboard/"]
COPY ["LRN.ProductionReports/LRN.ProductionReports.csproj", "LRN.ProductionReports/"]
COPY ["LRN.ReportQueue.Shared/LRN.ReportQueue.Shared.csproj", "LRN.ReportQueue.Shared/"]
RUN dotnet restore "LabMetricsDashboard/LabMetricsDashboard.csproj"

COPY . .
RUN dotnet publish "LabMetricsDashboard/LabMetricsDashboard.csproj" \
    -c "$BUILD_CONFIGURATION" \
    -o /app/publish \
    --no-restore \
    /p:UseAppHost=false

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS final

# ClosedXML calls AdjustToContents() in the Excel export builders (LIS Summary,
# Collection Summary, Denial Dashboard). Auto-fitting a column means measuring the
# text, which SixLabors.Fonts does against real font files - on a bare image there
# are none and the export throws. DejaVu covers the metrics; fontconfig lets the
# library enumerate what is installed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends fontconfig fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -f

WORKDIR /app
COPY --from=build /app/publish .

# Three paths the app writes to or reads at runtime. They are created here and
# handed to the non-root app user; docker-compose mounts volumes over them.
#
#   dpkeys     DataProtection key ring. MUST outlive the container - a new ring on
#              every redeploy invalidates every auth cookie and logs everyone out.
#   logs       Logging:File:LogDirectory (appsettings.json defaults to a Windows path).
#   labconfigs LabConfig:LabConfigFolder - per-lab JSON, deliberately kept outside the
#              image so a stale copy with a plaintext DB password is never baked in.
RUN mkdir -p /var/lrn/dpkeys /var/lrn/logs /var/lrn/labconfigs \
    && chown -R $APP_UID:$APP_UID /var/lrn

ENV ASPNETCORE_ENVIRONMENT=Production \
    ASPNETCORE_HTTP_PORTS=8080 \
    DataProtection__KeysPath=/var/lrn/dpkeys \
    Logging__File__LogDirectory=/var/lrn/logs \
    LabConfig__LabConfigFolder=/var/lrn/labconfigs/ \
    DOTNET_gcServer=1

EXPOSE 8080

# TLS terminates at the ingress/reverse proxy. Program.cs already calls
# UseHttpsRedirection only in Development for exactly this reason, so the container
# serves plain HTTP and lets the proxy own the certificate.
USER $APP_UID

ENTRYPOINT ["dotnet", "LabMetricsDashboard.dll"]

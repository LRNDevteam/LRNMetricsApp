# Copies dist/ to the deployment folder (DEPLOY_DIR, default C:\inetpub\wwwroot\ARWorkbench).
# An existing config.js there is KEPT: it holds that environment's URLs (Test vs Production), so a
# redeploy must not reset it. Delete it from the target first to take the new default.
$ErrorActionPreference = 'Stop'
$dest = if ($env:DEPLOY_DIR) { $env:DEPLOY_DIR } else { 'C:\inetpub\wwwroot\ARWorkbench' }
$dist = Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'
if (-not (Test-Path (Join-Path $dist 'index.html'))) { throw "Build first: $dist has no index.html." }

New-Item -ItemType Directory -Force -Path $dest | Out-Null
$keep = Join-Path $dest 'config.js'
$saved = if (Test-Path $keep) { [IO.File]::ReadAllBytes($keep) } else { $null }

Copy-Item -Path (Join-Path $dist '*') -Destination $dest -Recurse -Force
if ($saved) {
    [IO.File]::WriteAllBytes($keep, $saved)
    Write-Output "Published to $dest (kept its existing config.js)."
} else {
    Write-Output "Published to $dest (new config.js - set its URLs for this environment)."
}

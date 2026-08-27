# Coding Summary Loading Overlay - Production Troubleshooting

## Issue
The loading overlay works in local IIS but not on production server (lrnanalytics.com).

## Recent Changes
1. Removed all inline `style` attributes from the loading overlay
2. Moved styles to proper CSS classes in a `<style>` block
3. Changed from `style.display` manipulation to CSS class toggle (`.active`)
4. Added console logging for debugging

## Troubleshooting Steps

### 1. Clear Browser Cache
**The most common issue is browser caching the old version!**

```
Chrome/Edge:
- Hard refresh: Ctrl + Shift + R (Windows) or Cmd + Shift + R (Mac)
- Or: F12 → Network tab → Check "Disable cache" → Refresh

Firefox:
- Hard refresh: Ctrl + Shift + R or Ctrl + F5

Clear all cache:
- Chrome: Settings → Privacy → Clear browsing data → Cached images and files
```

### 2. Clear IIS Server Cache
On the production server:

```powershell
# Recycle the application pool
Restart-WebAppPool -Name "YourAppPoolName"

# Or restart IIS completely
iisreset

# Clear ASP.NET Temporary Files
Remove-Item "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\Temporary ASP.NET Files\*" -Recurse -Force
```

### 3. Check Browser Console
1. Open the Coding Summary page on production
2. Open browser DevTools (F12)
3. Go to Console tab
4. You should see these messages:
   ```
   [Coding Summary] Script loaded at: 2026-01-15T10:30:45.123Z
   [Coding Summary] Loading overlay element exists: true
   ```
5. Click a tab and look for:
   ```
   [Coding Summary] Tab clicked, overlay element: <div id="csTabLoadingOverlay">
   [Coding Summary] Adding active class to overlay
   [Coding Summary] Removing active class from overlay
   ```

### 4. Verify Element Exists
In browser console, run:
```javascript
document.getElementById('csTabLoadingOverlay')
```
Should return the div element, not `null`.

### 5. Check CSS Classes
In browser console, run:
```javascript
var overlay = document.getElementById('csTabLoadingOverlay');
console.log('Element:', overlay);
console.log('Classes:', overlay.className);
console.log('Display:', window.getComputedStyle(overlay).display);
```

Then click a tab and check again:
```javascript
overlay.classList.contains('active')  // Should be true briefly
```

### 6. Check CSP Headers
In browser DevTools:
1. Network tab
2. Refresh the page
3. Click the main document request
4. Look at Response Headers
5. Find `Content-Security-Policy`
6. Should include: `style-src 'self' 'unsafe-inline';`

### 7. Force Deploy New Version
If caching persists:

**Option A: Touch web.config**
```xml
<!-- Add or modify a setting to force recompilation -->
<configuration>
  <appSettings>
	<add key="DeployVersion" value="2026-01-15-v2" />
  </appSettings>
</configuration>
```

**Option B: Publish with Clean**
```powershell
# In Visual Studio
# Right-click LabMetricsDashboard project
# Publish → More Actions → Clean
# Then publish again
```

**Option C: Manual File Touch**
```powershell
# On production server, update the file timestamp
$file = "C:\inetpub\wwwroot\YourApp\Views\Coding\Summary.cshtml"
(Get-Item $file).LastWriteTime = Get-Date
```

## Expected Behavior After Fix

### Visual Check
1. Navigate to Coding Summary page
2. Click any tab button (e.g., "YTD Coding Insights")
3. Should see:
   - Semi-transparent dark overlay covering entire screen
   - White card in center with spinning blue circle
   - Text "Loading data..."
   - Overlay disappears after ~200ms

### Console Check
```
[Coding Summary] Script loaded at: 2026-01-15T...
[Coding Summary] Loading overlay element exists: true
[Coding Summary] Tab clicked, overlay element: [object HTMLDivElement]
[Coding Summary] Adding active class to overlay
[Coding Summary] Removing active class from overlay
```

## If Still Not Working

### Fallback: Check Old Code
If the production server still has the old inline-style version, you'll see in the HTML source:
```html
<div id="csTabLoadingOverlay" style="display:none;position:fixed;...">
```

### New Code Should Show
```html
<div id="csTabLoadingOverlay">
  <div class="loading-card">
	<div class="loading-spinner"></div>
	<div class="loading-text">Loading data...</div>
  </div>
</div>
```

## Common Production Issues

1. **IIS URL Rewrite caching**: Check if URL rewrite module is caching responses
2. **CDN/Proxy**: If using Cloudflare or similar, purge CDN cache
3. **Response Compression**: Ensure precompressed files (.gz, .br) are regenerated
4. **File Permissions**: Verify IIS can read the updated .cshtml file
5. **Precompiled Views**: If using runtime compilation, ensure it's enabled in production

## Contact
If none of these steps work, provide:
1. Browser console logs (full output)
2. Network tab screenshot showing the HTML request
3. View Source of the page (Ctrl+U) - search for "csTabLoadingOverlay"
4. IIS application pool settings and .NET version

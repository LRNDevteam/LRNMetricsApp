# LRN.WebUI - React Denial Workflow

This is an independent React/Vite UI for the Denial Workflow only.

## API URL
Set the API base URL in `.env` or IIS environment variable:

```env
VITE_DENIAL_API_BASE=https://localhost:62408/api/denialworkflow
```

If not set, the app defaults to `https://localhost:7091/api/denialworkflow`.

## Local run

```bash
npm install
npm run dev
```

Open: `http://localhost:5173`

## Publish

```bash
npm install
npm run build
```

Deploy the generated `dist` folder as a static site/application in IIS.

## Metrics app link

`Web/appsettings.json` now contains:

```json
"DenialWorkflowReactUrl": "http://localhost:5173"
```

Change this to the deployed React URL, for example:

```json
"DenialWorkflowReactUrl": "https://your-server/LRN.WebUI"
```

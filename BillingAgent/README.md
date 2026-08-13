# Billing Agent

An on-demand browser automation: log into the billing system and fill out a form, driven by Claude in Chrome using the steps below.

## How it's set up

- **`steps.json`** — the site URL and ordered list of form-fill steps. Safe to commit; no secrets.
- **`credentials.local.json`** — username/password. Gitignored, never committed. Edit this file directly rather than pasting credentials in chat.
- No schedule — this runs only when you ask ("run the billing agent").

## To use it

1. Open `credentials.local.json` and fill in `siteUrl`, `username`, `password`.
2. Open `steps.json` and replace the example with your real flow: the login field selectors/labels, then each step (navigate, type, select, click, verify) in order. If a value changes every run (like an amount or date), use a `{{placeholder}}` and tell Claude the value when you ask it to run.
3. Tell Claude: "run the billing agent" (optionally with the values for any `{{placeholders}}`). Claude reads both files, drives Chrome through the Claude in Chrome extension to log in and complete the steps, and reports back what happened at each step.

## Notes

- The Claude in Chrome browser extension needs to be connected for this to work.
- If the site has 2FA, Claude will pause and ask you to complete it in the browser before continuing.
- Review `steps.json` after the first live run — sites often need small selector adjustments (e.g., a button's visible label vs. its actual field name) once you see how the agent behaves against the real page.

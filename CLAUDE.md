# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small web app that helps Carrum Health Care Team members analyze patient call transcripts against the 8 Standard Operating Procedures from the case study PDF, returning multi-finding output (each transcript can trigger 0..N SOPs).

Two unrelated mini-projects coexist in this directory; don't confuse them:

- **SOP Recommender** (the active project): `server.ps1` + `sop-recommender.html` + `sops.json`
- **Futurepedia Bio** (legacy links page): `serve.ps1` + `index.html`

## Run / dev

The runtime here is **PowerShell 5.1 only** — Node.js, Python, deno, bun, dotnet, java are not installed. The backend uses `System.Net.HttpListener`, no package manager involved. There is no build step and no test suite.

```powershell
# Run the SOP backend (serves both the API and the static UI)
powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1
# Open http://localhost:4321/sop-recommender.html
```

Or start it via the Claude Code preview using `.claude/launch.json`:
- `carrum-sop` config → runs `server.ps1` (default for this project)
- `futurepedia-bio` config → runs the legacy `serve.ps1`

To enable Claude-powered analysis instead of the local heuristic: copy `.env.example` to `.env`, set `ANTHROPIC_API_KEY=sk-ant-...`, restart the server. The server reads `.env` on startup and selects the engine per request based on whether the key is present.

### Git / repository

Remote: `https://github.com/jstrifa-bit/Call-Transcript.git` (branch `main`).

`.gitignore` is **load-bearing for security**: it excludes `.env` (real Anthropic key), `.env.disabled`, `.claude/settings.local.json`, and the temp PDF-extraction files. Run `git check-ignore -v .env` before any commit if you've touched gitignore — leaking the key is the worst-case failure mode here. Never `git add -f .env`.

Windows + Git: line-ending warnings (`LF will be replaced by CRLF`) are expected and harmless. There is no `.gitattributes` yet; if cross-OS contributors join, add one (`* text=auto`, `*.ps1 text eol=crlf`).

### Smoke tests (no test suite — use the 3 inlined samples)

The Care Team case-study PDF supplies 3 transcripts that exercise different SOP combinations. They're inlined in `sop-recommender.html` (the `SAMPLES` object) and accessible via the **Load Sample** dropdown. Their expected dispositions:

| Sample | Expected disposition | Expected SOP findings |
|--------|---------------------|--------------------------------------------|
| Sarah  | **Revision Case**    | BAR-001 (prior bariatric → Revision Case), BAR-002 (no EGD → Action Required), BAR-003 (no RD → Hold) |
| Bob    | **Ineligible**       | JNT-002 (no PT → Ineligible), JNT-004 (daily opioid > 3mo → High Complexity) |
| Maria  | **Deferred**         | JNT-001 (active smoker → Deferred), JNT-003 (HbA1c > 7.0 → Review) |

After any change to `Invoke-LocalAnalysis`, `Invoke-ClaudeAnalysis`, the prompt, or `sops.json`, run all three through `/api/analyze` and confirm the dispositions still match. Claude mode may add reasonable extra findings (e.g. dental flags) but the dispositions above must hold.

## Architecture

**Data flow:**
```
sop-recommender.html ──fetch POST /api/analyze──▶ server.ps1
                                                    │
                                  apiKey set? ──┬───┴───┐
                                                ▼       ▼
                                  Invoke-ClaudeAnalysis  Invoke-LocalAnalysis
                                                │       │
                                                └───┬───┘
                                                    ▼
                                          Get-OverallDisposition
                                                    │
                       JSON {patient_summary, findings[], overall_disposition}
                                                    ▼
                                       renderResults() in browser
```

**API endpoints** (all served by `server.ps1`):
- `GET  /api/sops` — returns `sops.json`. Read by the SOP Reference sidebar at page load.
- `POST /api/crm/lookup` — body `{ name, patient_id }`. Used by the lookup form (step 1). Returns `{ ok, crm_record | null, note?, query? }`.
- `POST /api/analyze` — body `{ transcript, patient_name, patient_id }`. Returns `{ ok, engine, model, crm_record, patient_summary, findings[], overall_disposition, next_steps[], elapsed_ms }`.

**Key contract (the JSON shape returned by `/api/analyze`)** is shared between both engines and consumed by `renderResults()` in the HTML. Changing the shape requires touching all three: `Invoke-ClaudeAnalysis`, `Invoke-LocalAnalysis`, and `renderResults`.

**The page has a 2-step gated flow:**
1. **Patient Lookup** (top of page) — Specialist enters Name + Patient ID, clicks OK. The form locks immediately and a fake "Connecting to Carrum CRM…" visual plays for **a hard 5-second floor** (`Promise.all([api, sleep(5000)])` in `onLookup`) — drops it and the lookup feels jarringly fast even when the API is real. After the floor, `renderPersistentCRM` puts the CRM card in `#crmPanel` and `setAnalyzeGate(true)` unlocks the Analyze button. **`onLookupReset` clears the transcript too** — resetting the patient is meant to be a full reset of the working session, not just a name change.
2. **Transcript analysis** — only available after step 1. Analyze posts to `/api/analyze` with `{ transcript, patient_name, patient_id }` so the backend uses the same lookup the Specialist did. The frontend ignores any CRM card the analyze response would render — it stays at the top of the page, not in the results block.

**Render order in `renderResults()` is a fixed UX decision** (these are the *results-only* blocks; the CRM card lives separately at the top of the page):
1. Side-by-side row: Patient Summary  ┃  Recommendation
2. Next Steps (numbered list with 👍/👎 review gate + per-step CTAs)
3. Triggered SOP Findings (the cards)

If you reorder these blocks, you're changing user-visible behavior — verify with the user first.

**`crm_record` is a mock CRM integration.** Records live in `crm.json`. Two backend matchers exist:
- `Get-CrmByQuery $name $patientId` — used by `POST /api/crm/lookup` and the analyze endpoint when the frontend supplies patient identifiers. Patient ID match takes priority over name match.
- `Get-CrmMatch $transcript` — legacy transcript-scan fallback, only used by `/api/analyze` when no `patient_id`/`patient_name` is supplied (which shouldn't happen via the UI but keeps the API permissive).

Real production integration would resolve the patient by case ID set during call setup. The lookup-by-name and transcript-scan are prototype shortcuts. If `crm_record` is `null`, the frontend renders an empty-state card with the entered identifiers and a note that the demo only has records for the 3 sample patients.

**`next_steps` is part of the JSON contract.** Both engines must produce it:
- Claude mode: `next_steps` is requested in the prompt schema and Claude generates synthesized steps that may parallelize across SOPs.
- Local mode: `Build-LocalNextSteps` deterministically builds the list from findings — one step per finding (prefixed `[SOP-id]`), then a disposition-aware tail step, then a final "Document..." step.

Steps may begin with `[GEN-001]` / `[JNT-002]` / `[BAR-003]` (regex `^\[[A-Z]{2,4}-\d{3}\]`). Three places strip / match this prefix and must stay in sync — `formatNextStep` (renders it as a styled badge), `ctaForStep` (strips before matching CTA rules), and `onGeneratePatientEmail` (strips before adding to email body). Stale prefix regexes here have already shipped once and silently leaked `[BAR-003]` into the email body.

**Each Next Step renders with a review gate (👍 / 👎) and a context-aware CTA**. Mapping for the CTA labels lives in the `CTA_RULES` array in `sop-recommender.html`. Important properties:
- **Order matters — first match wins.** Put the more specific patterns higher in the list. Generic patterns like `/confirm|verify/` and `/schedule|consultation/` belong at the bottom or they'll swallow more specific intents.
- Each rule is `{ match: RegExp, label: string, action: string, patientFacing: boolean }`. The `action` string is what's shown in the demo toast (`"Demo: <action> initiated for step N"`); in production it would be a routing key for a deep-link. `patientFacing` decides whether the CTA fires immediately (false) or queues for the bundled email (true) — see "Patient-comm steps are batched…" below.
- `ctaForStep` strips the `[XXX-###]` prefix before matching, so don't include the bracket prefix in your patterns.
- The click handler is wired once via event delegation on `resultsContent` (not per-button), so re-rendering results works automatically — don't add per-button listeners. The same handler also catches `#nsGenerateEmailBtn`.
- These CTAs are **deliberately fake** for the prototype. Don't let a future request to "make them work" silently turn them into real integrations without explicit scoping.

**Each step has a 5-state state machine** stored as `data-step-state` on the `<li>`: `pending` → `approved` (👍) → `actioned` or `queued` (CTA clicked); or `pending` → `flagged` (👎). The CTA is disabled in any state other than `approved`. Thumbs clicks toggle (clicking 👍 again on an `approved` step returns it to `pending`). Once `actioned` or `queued`, both thumbs are disabled and the step is locked. `setStepState(li, state)` is the single source of truth for the visual transitions — don't manipulate the thumb / CTA / flag DOM directly.

**Patient-comm steps are batched into a single email instead of firing immediately.** Each `CTA_RULES` entry has a `patientFacing: boolean` flag. When the CTA on a `patientFacing` step is clicked, the step transitions to `queued` (held), not `actioned`. A "Generate Email to Patient" button appears at the bottom of the Next Steps card whenever any patient-facing step exists; it stays disabled until every other step is in `actioned` or `flagged`. Clicking it builds a draft email panel below the results from the queued steps' text (with the `[SOP-XXX-###]` prefix stripped) and transitions all queued steps to `actioned`. The draft is editable, has a Copy button and a Send Email button (demo only), and is wiped at the start of each new analyze run via `document.getElementById("emailDraftPanel")?.remove()`. `refreshBatchRow()` is the single source of truth for whether the button is enabled and what the status text says — call it from any state transition.

**The 8 SOPs in `sops.json`** are the load-bearing data. Each record has: `id` (e.g. `GEN-001`, `JNT-002`, `BAR-003`), `category` (General/Joint/Bariatric), `case_types` (which case types it applies to), `finding`, `status`, `action`. `trigger_concepts` and `evaluation_question` are only used internally by the analysis engines.

**Disposition priority** (most blocking first) is hardcoded in `Get-OverallDisposition`, mirroring the user-supplied `STATUS_PRIORITY`:
`Ineligible (1) > Deferred (2) > High Complexity (3) > Review (4) > Revision Case (5) > Hold (6) > Action Required (7) > Cleared`. The same ordering is duplicated in `Build-LocalNextSteps` for sorting findings; if you reorder one, reorder both. The frontend's status color palette mirrors `STATUS_COLORS`: red (Ineligible), orange (Deferred / High Complexity), yellow (Review / Revision Case), blue (Hold / Action Required), green (Cleared).

**Local heuristic mode** (`Invoke-LocalAnalysis`) is intentionally not pure keyword matching — each of the 8 SOPs has a hand-written guardrail block (the `switch ($sop.id)` in server.ps1) because the case-study SOPs require nuanced judgment that pure keyword scoring gets wrong:
- HbA1c > 7.0 needs an actual numeric extraction, not just the term "A1c"
- "No PT attempt" must fire even when patient says they "tried it" (e.g. 2 gym sessions)
- "No RD" must fire when patient says they saw a nutritionist once
- Active Smoker must NOT be excluded just because patient mentions "tried to quit last year" (failed attempt ≠ cessation)

When adjusting heuristics, always re-test all three sample transcripts (Sarah / Bob / Maria, defined inline in `sop-recommender.html`).

## PowerShell-specific gotchas (these have all bitten)

1. **PowerShell 5.1 reads UTF-8-without-BOM as Windows-1252.** Em-dashes, smart quotes, and other non-ASCII chars in `.ps1` files cause cryptic parse errors like `Array index expression is missing or not valid`. Stick to ASCII in PowerShell source.
2. **Backticks in single-quoted regex strings still confuse the parser.** To match literal triple-backticks, build the string from `[char]96` rather than embedding them.
3. **`$resp.OutputStream.Close()` in every code path.** HttpListener leaks if you don't, and the next request hangs. Both success and 404 paths must close.
4. **`if/else` returning a value, not ternary.** PowerShell 5.1 has no `?:` operator; use `if (cond) { val1 } else { val2 }`.
5. **`ConvertFrom-Json` returns `PSCustomObject`**, not a hashtable. To enumerate dynamic fields, use property access (`$obj.foo`) or `$obj.PSObject.Properties`.

### UTF-8 round-trip on the Claude API path (this took the most debugging)

The transcript can contain smart quotes, em-dashes, accented names. PS 5.1 will silently corrupt these on every encoding boundary unless every step is forced to UTF-8. **Three places** must each be explicit:

1. **Reading the request body in `Read-RequestBody`** — pass `[System.Text.Encoding]::UTF8` to `StreamReader`. The `$req.ContentEncoding` default can decode UTF-8 bytes as Windows-1252 surrogate-escape chars, which then fail JSON serialization downstream.
2. **Sending the body to Anthropic in `Invoke-ClaudeAnalysis`** — use `[System.Text.Encoding]::UTF8.GetBytes($bodyJson)` and pass the byte array as `-Body`, not the string. Otherwise Anthropic returns 400 with `"str is not valid UTF-8: surrogates not allowed"`.
3. **Decoding the response from Anthropic** — use `Invoke-WebRequest -UseBasicParsing` + `[System.Text.Encoding]::UTF8.GetString($rawResp.RawContentStream.ToArray())`. `Invoke-RestMethod` auto-decodes using the response's declared charset, but falls back to Latin-1 when implicit, mangling em-dashes Claude returns ("â" mojibake).

Treat the Anthropic API path as load-bearing for UTF-8. If you simplify any of these three steps "back to `Invoke-RestMethod`", non-ASCII transcripts will break.

### Surfacing API errors

The catch block around the Anthropic call must read `$_.Exception.Response.GetResponseStream()` to surface the actual error body. Without it, you get useless messages like "(400) Bad Request" — with it, you see the real cause (e.g. low credit balance, invalid model name, malformed body). Don't strip this out.

## Frontend gotchas

- The neural-network thinking animation uses `setInterval(tick, 33)` instead of `requestAnimationFrame` because rAF is throttled to zero in unfocused/headless tabs (the preview tool runs that way). Keep `setInterval`.
- The HTML is a single self-contained file (no bundler, no framework). State lives in module-level `let` variables. Keep it that way unless there's a strong reason to introduce dependencies — this is meant to be runnable with just PowerShell + a browser.

### Email-aware preprocessing (`preprocessEmail` in the HTML)

Care Specialists often receive transcripts as forwarded emails. `preprocessEmail` is a frontend-only step that runs on every paste / file upload / drag-drop and detects email content, returning `{ cleaned, wasEmail, removedLines, reasons[] }`. Triggered from `applyTranscript` (uploads) and the `paste` listener on the textarea (clipboard).

**Non-obvious load-bearing detail: in a forwarded email, the original transcript lives BELOW the forward marker (`-----Original Message-----`, `On Mon... wrote:`, `Begin forwarded message:`), not above.** A naive implementation that "cuts everything before the marker" preserves the cover note and DROPS the actual transcript. The current code finds the LAST forward marker, keeps everything after it, then re-runs the header-strip pass on the inner message (forwarded emails carry their own header block).

Other things it strips: outer email headers, quote prefixes (`> ...` lines), RFC sig delimiters (`-- \n...`), "Sent from my iPhone", `CONFIDENTIALITY NOTICE:` / `DISCLAIMER:` blocks. A purple notice appears in the UI showing what was stripped, with an Undo button that restores the raw text from `lastRawTranscript`.

If you're testing this, fabricate a forwarded email and verify both that headers are gone AND that the actual conversation lines (the part below the forward marker) are still present. The smoke is silent — the analysis would just return "Cleared / no findings" if the body got dropped.

The purple "Email content detected — stripped N lines…" notice only fires when `wasEmail && removedLines > 0`. Don't loosen this — CRLF→LF normalization on plain transcripts changes the string but isn't worth surfacing to the Specialist, and showing "stripped 0 lines" looked broken.

## Files to know

| File | Purpose |
|------|---------|
| `server.ps1` | Backend (HTTP + analysis engines). Single source of truth for the analysis logic. |
| `sops.json` | The 8 SOPs from the case-study PDF. Edit this to change the SOP library. |
| `crm.json`  | Mock CRM records (Age, Sex, Location, Height, Weight, Employer) for the 3 sample patients. Edit `name_aliases` to control which transcripts match. |
| `sop-recommender.html` | Single-page UI. Contains the 3 sample transcripts inline. |
| `.env.example` | Template — copy to `.env` and add `ANTHROPIC_API_KEY` to enable Claude mode. |
| `.gitignore` | Excludes `.env`, `.claude/settings.local.json`, temp PDF files. Don't loosen without auditing. |
| `.claude/launch.json` | Preview server configs (carrum-sop, futurepedia-bio). |
| `serve.ps1`, `index.html` | Legacy Futurepedia Bio project — unrelated. |

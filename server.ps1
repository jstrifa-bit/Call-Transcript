# ================================================================
# Carrum SOP Recommender - backend
# Serves the static UI plus a small JSON API:
#   GET  /api/sops          -> SOP library (sops.json)
#   POST /api/analyze       -> analyze a transcript, return findings
# ================================================================

$port = if ($env:PORT) { [int]$env:PORT } else { 4321 }
$root = $PSScriptRoot

# Load .env if present (simple KEY=VALUE parser, ignores comments)
$envPath = Join-Path $root ".env"
if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $name  = $Matches[1]
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            Set-Item -Path "env:$name" -Value $value
        }
    }
}

$apiKey = $env:ANTHROPIC_API_KEY
$model  = if ($env:ANTHROPIC_MODEL) { $env:ANTHROPIC_MODEL } else { "claude-sonnet-4-6" }

if ($apiKey) {
    Write-Host "[server] Anthropic key loaded - analysis will use Claude ($model)"
} else {
    Write-Host "[server] No ANTHROPIC_API_KEY set - analysis will use local heuristic mode"
    Write-Host "[server] Add a key to .env to enable Claude:  ANTHROPIC_API_KEY=sk-ant-..."
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "[server] Carrum SOP Recommender listening on http://localhost:$port/"
Write-Host "[server] Open: http://localhost:$port/sop-recommender.html"

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
function Write-Json($resp, $obj, [int]$code = 200) {
    $resp.StatusCode = $code
    $resp.ContentType = "application/json; charset=utf-8"
    $json = $obj | ConvertTo-Json -Depth 20 -Compress:$false
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Read-RequestBody($req) {
    # Force UTF-8 read regardless of what the browser/Content-Type advertised.
    # PS 5.1's ContentEncoding can default to a codepage that turns valid UTF-8
    # bytes into surrogate-escape chars, which then break downstream JSON output.
    $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    return $body
}

function Get-Sops {
    $sopsPath = Join-Path $root "sops.json"
    if (-not (Test-Path $sopsPath)) { return @() }
    $raw = Get-Content $sopsPath -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Get-CrmRecords {
    $crmPath = Join-Path $root "crm.json"
    if (-not (Test-Path $crmPath)) { return @() }
    $raw = Get-Content $crmPath -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

# Convert a CRM record into the dictionary shape we return over the wire.
# Drops the internal name_aliases field and adds matched_via to explain how
# the lookup resolved.
function ConvertTo-CrmPayload($record, $matchedVia) {
    $copy = @{}
    foreach ($prop in $record.PSObject.Properties) {
        if ($prop.Name -ne "name_aliases") { $copy[$prop.Name] = $prop.Value }
    }
    $copy["matched_via"] = $matchedVia
    return $copy
}

# Lookup-form match: prefer exact patient_id, fall back to name match.
# Used by POST /api/crm/lookup when the Specialist enters Name + Patient ID
# at the top of the tool.
function Get-CrmByQuery($name, $patientId) {
    $records = Get-CrmRecords
    if (-not $records) { return $null }

    if ($patientId) {
        $idLower = $patientId.ToString().Trim().ToLower()
        foreach ($r in $records) {
            if ($r.patient_id -and $r.patient_id.ToLower() -eq $idLower) {
                return (ConvertTo-CrmPayload $r "Matched by Patient ID '$($r.patient_id)'")
            }
        }
    }
    if ($name) {
        $nameLower = $name.ToString().Trim().ToLower()
        if ($nameLower) {
            foreach ($r in $records) {
                # full-name exact match
                if ($r.name -and $r.name.ToLower() -eq $nameLower) {
                    return (ConvertTo-CrmPayload $r "Matched by name '$($r.name)'")
                }
                # alias contains query (or vice versa) — looser fallback
                foreach ($alias in $r.name_aliases) {
                    $aliasLower = $alias.ToLower()
                    if ($aliasLower -eq $nameLower -or $aliasLower.Contains($nameLower) -or $nameLower.Contains($aliasLower)) {
                        return (ConvertTo-CrmPayload $r "Matched by name alias '$alias'")
                    }
                }
            }
        }
    }
    return $null
}

# Transcript-scan fallback (legacy): scan the transcript for any known
# patient name alias and return the first matching record. Used by
# /api/analyze when the frontend hasn't already supplied a patient_id.
function Get-CrmMatch($transcript) {
    $records = Get-CrmRecords
    if (-not $records -or $records.Count -eq 0) { return $null }
    $lower = $transcript.ToLower()
    foreach ($r in $records) {
        foreach ($alias in $r.name_aliases) {
            $aliasLower = $alias.ToLower()
            $escaped = [regex]::Escape($aliasLower)
            if ([regex]::IsMatch($lower, "\b$escaped\b")) {
                return (ConvertTo-CrmPayload $r "Name '$alias' detected in transcript")
            }
        }
    }
    return $null
}

# ----------------------------------------------------------------
# LOCAL HEURISTIC ANALYSIS (no LLM)
# ----------------------------------------------------------------
function Invoke-LocalAnalysis($transcript, $sops) {
    $lower = $transcript.ToLower()
    $findings = @()
    $facts = @()

    # Patient turns extraction (best-effort)
    $patientText = ""
    foreach ($line in ($transcript -split "`n")) {
        if ($line -match '^\s*(patient|member|caller|sarah|bob|maria|[a-z]+ ?[a-z]?)\s*:\s*(.*)$') {
            $role = $Matches[1].ToLower().Trim()
            if ($role -notmatch 'care team|specialist|agent|carrum|cs|rep') {
                $patientText += " " + $Matches[2]
            }
        }
    }
    if (-not $patientText) { $patientText = $transcript }
    $patientLower = $patientText.ToLower()

    foreach ($sop in $sops) {
        $hits = @()
        $score = 0
        foreach ($concept in $sop.trigger_concepts) {
            $cLower = $concept.ToLower()
            $escaped = [regex]::Escape($cLower)
            $pattern = "\b$escaped\b"
            $countAll = ([regex]::Matches($lower, $pattern)).Count
            $countPatient = ([regex]::Matches($patientLower, $pattern)).Count
            if ($countAll -gt 0) {
                $weight = if ($countPatient -gt 0) { 2 } else { 1 }
                $hits += @{ concept = $concept; count = $countAll; from_patient = ($countPatient -gt 0) }
                $score += $countAll * $weight
            }
        }

        if ($score -eq 0) { continue }

        # SOP-specific guardrails for the 8 case-study SOPs
        $triggered = $false
        $evidence = ""
        $confidence = "Medium"

        switch ($sop.id) {
            "GEN-001" {
                if ($lower -match 'no.{0,20}dent|haven.t.{0,30}dent|over.{0,10}year|overdue|pending.{0,20}(dent|tooth)|root canal|cavity') {
                    $triggered = $true
                    $confidence = "Medium"
                }
            }
            "JNT-001" {
                $activeSmoker  = ($lower -match "i smoke|i'm a smoker|active smoker|i'm active(\.| sm)|pack a day|half.?pack|smoking.{0,15}cigarette|currently smoking|i.m active.{0,30}smok")
                $recentQuit    = ($lower -match "quit.{0,30}(weeks? ago|months? ago)") -or ($lower -match "stopped.{0,30}(weeks? ago|months? ago)") -or ($lower -match "quit.{0,30}(last week|last month|two weeks ago|three weeks ago)")
                $longAgoQuit   = ($lower -match "quit.{0,15}(years? ago|decade)") -or ($lower -match "stopped smoking.{0,30}years? ago") -or ($lower -match "haven't smoked.{0,30}years")
                $neverSmoked   = ($lower -match "never smoked|don't smoke|i'm not a smoker|not a smoker")
                if (($activeSmoker -or $recentQuit) -and -not $longAgoQuit -and -not $neverSmoked) {
                    $triggered = $true
                    $confidence = "High"
                }
            }
            "JNT-002" {
                if ($lower -match "no.{0,20}(pt|physical therapy)|haven't.{0,30}(pt|therapy)|two sessions|couple sessions|few sessions|never tried.{0,20}(pt|therapy)|didn't (try|do).{0,20}(pt|therapy)") {
                    $triggered = $true
                    $confidence = "Medium"
                }
            }
            "JNT-003" {
                $rxA1c = [regex]::Matches($transcript, '(?i)(?:HbA1c|A1c|hemoglobin\s*a1c).{0,30}?(\d+(?:\.\d+)?)')
                foreach ($m in $rxA1c) {
                    $val = [double]$m.Groups[1].Value
                    if ($val -gt 7.0) {
                        $triggered = $true
                        $confidence = "High"
                        $evidence = "HbA1c reported: $val"
                        break
                    }
                }
                if (-not $triggered -and $lower -match 'a1c|hba1c|hemoglobin') {
                    $bare = [regex]::Matches($transcript, '\b(\d+\.\d)\b')
                    foreach ($m in $bare) {
                        $val = [double]$m.Groups[1].Value
                        if ($val -gt 7.0 -and $val -lt 15) {
                            $triggered = $true
                            $confidence = "Medium"
                            $evidence = "HbA1c likely: $val"
                            break
                        }
                    }
                }
            }
            "JNT-004" {
                if ($lower -match 'oxy|oxycodone|vicodin|hydrocodone|morphine|fentanyl|tramadol|percocet|opioid|narcotic|pain pill') {
                    if ($lower -match 'daily|every day|pretty much daily|year|years|months') {
                        $triggered = $true
                        $confidence = "High"
                    }
                }
            }
            "BAR-001" {
                if ($lower -match "lap band|gastric sleeve|gastric bypass|duodenal switch|prior.{0,20}bariatric|previous.{0,20}weight.loss|had.{0,20}(sleeve|bypass|band)|had.{0,30}weight.loss|prior weight-loss") {
                    $triggered = $true
                    $confidence = "High"
                }
            }
            "BAR-002" {
                if ($lower -match "need.{0,20}endoscopy|need.{0,20}egd|no.{0,20}endoscopy|haven't.{0,30}(endoscopy|egd)|schedule.{0,20}(endoscopy|egd)|will.{0,10}need.{0,20}endoscopy") {
                    $triggered = $true
                    $confidence = "Medium"
                }
            }
            "BAR-003" {
                if ($lower -match "don't.{0,20}have.{0,30}(rd|dietician|dietitian)|no.{0,20}(rd|registered diet)|nutritionist.{0,30}(once|twice|few times)|saw.{0,20}once") {
                    $triggered = $true
                    $confidence = "Medium"
                }
            }
        }

        if ($triggered) {
            if (-not $evidence) {
                $topHit = ($hits | Sort-Object -Property count -Descending | Select-Object -First 1)
                if ($topHit) {
                    $evidence = "Trigger phrase '$($topHit.concept)' present in transcript ($($topHit.count)x)"
                }
            }

            $findings += @{
                sop_id     = $sop.id
                category   = $sop.category
                finding    = $sop.finding
                status     = $sop.status
                action     = $sop.action
                evidence   = $evidence
                confidence = $confidence
            }
        }
    }

    # Patient summary (light extraction)
    if ($lower -match 'knee|hip|joint') { $facts += "Joint complaint mentioned" }
    if ($lower -match 'bariatric|weight.loss|sleeve|bypass|lap band') { $facts += "Bariatric / weight-loss context" }
    if ($lower -match 'smoke|cigarette') { $facts += "Smoking history discussed" }
    if ($lower -match 'a1c|hba1c|diabet') { $facts += "Glycemic / diabetes context discussed" }
    if ($lower -match 'oxy|opioid|narcotic|pain pill') { $facts += "Opioid use discussed" }

    $disposition = Get-OverallDisposition $findings
    $nextSteps   = Build-LocalNextSteps $findings $disposition
    $crmRecord   = Get-CrmMatch $transcript

    return @{
        ok = $true
        engine = "local"
        model = $null
        elapsed_ms = 0
        crm_record = $crmRecord
        patient_summary = @{
            category = (Get-PrimaryCategory $findings $lower)
            key_facts = $facts
            note = "Local heuristic mode. Configure ANTHROPIC_API_KEY for richer summaries."
        }
        findings = $findings
        overall_disposition = $disposition
        next_steps = $nextSteps
    }
}

function Get-PrimaryCategory($findings, $lower) {
    if ($findings.Count -gt 0) {
        $cats = $findings | ForEach-Object { $_.category } | Sort-Object -Unique
        if ($cats -contains "Bariatric") { return "Bariatric" }
        if ($cats -contains "Joint") { return "Joint" }
        return $cats[0]
    }
    if ($lower -match 'bariatric|weight.loss|sleeve|bypass') { return "Bariatric" }
    if ($lower -match 'knee|hip|joint|orthop') { return "Joint" }
    return "General"
}

function Build-LocalNextSteps($findings, $disposition) {
    # Deterministic Next Steps for local heuristic mode.
    # Order findings by how blocking each one is, then turn each required_action
    # into an actionable sentence prefixed by the SOP id.
    if (-not $findings -or $findings.Count -eq 0) {
        return @(
            "No SOP findings triggered - patient may proceed via the standard intake workflow.",
            "Confirm any remaining intake items per standard checklist.",
            "Document case as Cleared in the CRM with a brief summary of the conversation."
        )
    }

    # Same priority as Get-OverallDisposition (must stay in sync)
    $priority = @("Ineligible", "Deferred", "High Complexity", "Review", "Revision Case", "Hold", "Action Required")
    $rank = @{}
    for ($i = 0; $i -lt $priority.Count; $i++) { $rank[$priority[$i]] = $i }

    $sorted = $findings | Sort-Object -Property @{ Expression = { if ($rank.ContainsKey($_.status)) { $rank[$_.status] } else { 99 } } }

    $steps = @()
    foreach ($f in $sorted) {
        $steps += "[$($f.sop_id)] $($f.action)"
    }

    # Disposition-aware tail
    switch ($disposition.status) {
        "Deferred" {
            $steps += "Pause the case in the CRM and set a follow-up tickler at the end of the deferral window to reassess."
        }
        "Hold" {
            $steps += "Place the case on Hold in the CRM until the outstanding items above are confirmed complete."
        }
        "Ineligible" {
            $steps += "Mark the case Ineligible for now and route the patient back to the appropriate prerequisite pathway."
        }
        "High Complexity" {
            $steps += "Tag the case as High Complexity so the surgical and anesthesia teams can plan accordingly."
        }
        "Revision Case" {
            $steps += "Route to the specialized revision-surgery review queue rather than the standard bariatric pathway."
        }
        "Review" {
            $steps += "Hold scheduling until the Clinical MD review is complete."
        }
        "Action Required" {
            $steps += "Follow up with the patient until the action items above are confirmed complete."
        }
    }

    $steps += "Document the conversation, triggered SOPs, and current disposition in the patient record."
    return $steps
}

function Get-OverallDisposition($findings) {
    if (-not $findings -or $findings.Count -eq 0) {
        return @{
            status = "Cleared"
            summary = "No SOP findings triggered. Patient may proceed to Consultation pending standard workflow."
        }
    }

    # Severity priority (most blocking first) - per the SOP_RULES STATUS_PRIORITY:
    # 1 Ineligible > 2 Deferred > 3 High Complexity > 4 Review > 5 Revision Case > 6 Hold > 7 Action Required
    $priority = @("Ineligible", "Deferred", "High Complexity", "Review", "Revision Case", "Hold", "Action Required")
    $worst = $null
    foreach ($p in $priority) {
        if ($findings | Where-Object { $_.status -eq $p }) {
            $worst = $p
            break
        }
    }
    if (-not $worst) { $worst = $findings[0].status }

    $count = $findings.Count
    $plural = if ($count -gt 1) { "s" } else { "" }
    $summary = "$count SOP finding$plural triggered. Most blocking status: $worst. Care Team should resolve all flagged items before advancing the case."

    return @{
        status = $worst
        summary = $summary
    }
}

# ----------------------------------------------------------------
# CLAUDE-POWERED ANALYSIS
# ----------------------------------------------------------------
function Invoke-ClaudeAnalysis($transcript, $sops, $apiKey, $model) {
    $sopText = ($sops | ForEach-Object {
        $caseTypes = if ($_.case_types) { ($_.case_types -join ", ") } else { "any" }
        "[$($_.id)] Category: $($_.category) | Applies to: $caseTypes | Finding: $($_.finding) | Status: $($_.status) | Action: $($_.action) | Evaluation: $($_.evaluation_question)"
    }) -join "`n"

    $systemPrompt = @"
You are an extraction and reasoning engine for the Carrum Health Care Team. You read transcripts of conversations between Care Team members and patients, then identify which Standard Operating Procedures (SOPs) apply.

You are given an SOP library and a transcript. For each SOP, decide whether the transcript provides clear evidence that the SOP's condition is TRUE.

Critical rules:
- Only flag a SOP if the transcript provides specific, citable evidence. Do not guess.
- Quote the patient or care-team member verbatim when possible as evidence.
- A single transcript may trigger 0, 1, or many SOPs.
- If the patient denied a condition or evidence is absent, do NOT flag the SOP.
- For numeric thresholds (e.g. HbA1c > 7.0), require an actual number in the transcript that crosses the threshold.
- For 'No attempt at PT', a token attempt (e.g. 2 gym sessions) does NOT count as a meaningful conservative trial - flag it.
- For 'No Registered Dietician', a one-off nutritionist visit does NOT count as having an RD - flag it.
- A patient mentioning 'chronic infection' or 'recurrent UTIs' is NOT one of the listed SOPs - do not invent SOPs.
- Each SOP has an 'Applies to' field listing the case types it covers (joint, bariatric, or both). BAR-* SOPs only apply if the case is bariatric. JNT-* SOPs only apply if the case is a joint case. GEN-001 applies to both.
- Confidence: High if evidence is explicit, Medium if inferred, Low if ambiguous.

Return STRICT JSON only - no markdown fences, no prose. Use this exact schema:

{
  "patient_summary": {
    "category": "Joint" | "Bariatric" | "General" | "Unknown",
    "demographics": "short phrase, e.g. 'Sarah T., bariatric revision candidate'",
    "key_facts": ["bullet 1", "bullet 2", "..."]
  },
  "findings": [
    {
      "sop_id": "GEN-001 | JNT-001..JNT-004 | BAR-001..BAR-003",
      "evidence": "verbatim or near-verbatim quote from transcript",
      "confidence": "High" | "Medium" | "Low"
    }
  ],
  "overall_disposition": {
    "status": "Ineligible" | "Deferred" | "High Complexity" | "Review" | "Revision Case" | "Hold" | "Action Required" | "Cleared",
    "summary": "1-3 sentence narrative for the Care Team explaining what to do next"
  },
  "next_steps": [
    "Concrete action item the Care Team should take, in priority order. Be specific and actionable. Include the SOP id in brackets when the step comes from a triggered SOP, e.g. '[SOP-J-001] Refer patient to Smoking Cessation program.' Synthesize across findings - if two steps can run in parallel, say so. If the case is paused/deferred, include the reassessment timeline. Add a final 'Document...' step describing what to capture in the CRM."
  ]
}
"@

    $userPrompt = @"
SOP LIBRARY:
$sopText

---

TRANSCRIPT:
$transcript

---

Identify all applicable SOPs. Return strict JSON.
"@

    $bodyObj = @{
        model = $model
        max_tokens = 2000
        system = $systemPrompt
        messages = @(@{ role = "user"; content = $userPrompt })
    }
    # ConvertTo-Json on PS 5.1 escapes non-ASCII as \uXXXX which is fine,
    # but the catch is when transcript content survives as raw smart-quotes
    # or em-dashes; ensure we send UTF-8 bytes so Anthropic can't see invalid
    # surrogate pairs from a Windows-1252 round-trip.
    $bodyJson  = $bodyObj | ConvertTo-Json -Depth 10
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)

    try {
        $headers = @{
            "x-api-key"          = $apiKey
            "anthropic-version"  = "2023-06-01"
        }
        # Use Invoke-WebRequest so we can force UTF-8 decode on the response.
        # Invoke-RestMethod's auto-decode can fall back to Latin-1 when the
        # Content-Type charset is implicit, mangling em-dashes returned by Claude.
        $rawResp = Invoke-WebRequest -Method POST `
                                     -Uri "https://api.anthropic.com/v1/messages" `
                                     -Headers $headers `
                                     -ContentType "application/json; charset=utf-8" `
                                     -Body $bodyBytes `
                                     -TimeoutSec 60 `
                                     -UseBasicParsing
        $respJson = [System.Text.Encoding]::UTF8.GetString($rawResp.RawContentStream.ToArray())
        $resp = $respJson | ConvertFrom-Json

        $text = $resp.content[0].text
        # strip code fences if present (using char codes to avoid PS backtick issues)
        $clean = $text.Trim()
        $fence = [char]96 + [char]96 + [char]96
        if ($clean.StartsWith($fence)) {
            $clean = $clean.Substring($fence.Length)
            if ($clean.StartsWith("json")) { $clean = $clean.Substring(4) }
        }
        if ($clean.EndsWith($fence)) {
            $clean = $clean.Substring(0, $clean.Length - $fence.Length)
        }
        $clean = $clean.Trim()

        $parsed = $clean | ConvertFrom-Json

        $enriched = @()
        foreach ($f in $parsed.findings) {
            $sop = $sops | Where-Object { $_.id -eq $f.sop_id } | Select-Object -First 1
            if ($sop) {
                $enriched += @{
                    sop_id     = $sop.id
                    category   = $sop.category
                    finding    = $sop.finding
                    status     = $sop.status
                    action     = $sop.action
                    evidence   = $f.evidence
                    confidence = $f.confidence
                }
            }
        }

        $disposition = Get-OverallDisposition $enriched
        if ($parsed.overall_disposition -and $parsed.overall_disposition.summary) {
            $disposition.summary = $parsed.overall_disposition.summary
        }

        $keyFacts = @()
        if ($parsed.patient_summary -and $parsed.patient_summary.key_facts) {
            foreach ($k in $parsed.patient_summary.key_facts) { $keyFacts += [string]$k }
        }

        $nextSteps = @()
        if ($parsed.next_steps) {
            foreach ($s in $parsed.next_steps) { $nextSteps += [string]$s }
        }
        # Fallback if Claude omitted next_steps for any reason
        if (-not $nextSteps -or $nextSteps.Count -eq 0) {
            $nextSteps = (Build-LocalNextSteps $enriched $disposition)
        }

        $crmRecord = Get-CrmMatch $transcript

        return @{
            ok = $true
            engine = "claude"
            model = $model
            crm_record = $crmRecord
            patient_summary = @{
                category = $parsed.patient_summary.category
                demographics = $parsed.patient_summary.demographics
                key_facts = $keyFacts
            }
            findings = $enriched
            overall_disposition = $disposition
            next_steps = $nextSteps
        }
    } catch {
        $detail = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $bodyText = $reader.ReadToEnd()
                $reader.Close()
                if ($bodyText) { $detail = "$detail :: $bodyText" }
            } catch { }
        }
        Write-Host "[server] Claude API error: $detail"
        return @{
            ok = $false
            engine = "claude"
            error = "Claude API call failed: $detail"
        }
    }
}

# ----------------------------------------------------------------
# REQUEST LOOP
# ----------------------------------------------------------------
while ($listener.IsListening) {
    try {
        $ctx  = $listener.GetContext()
    } catch {
        break
    }
    $req  = $ctx.Request
    $resp = $ctx.Response
    $path = $req.Url.LocalPath

    try {
        if ($path -eq "/api/sops" -and $req.HttpMethod -eq "GET") {
            $sops = Get-Sops
            Write-Json $resp $sops
            continue
        }

        if ($path -eq "/api/crm/lookup" -and $req.HttpMethod -eq "POST") {
            $body = Read-RequestBody $req
            try { $payload = $body | ConvertFrom-Json } catch {
                Write-Json $resp @{ ok = $false; error = "Invalid JSON body" } 400
                continue
            }
            $name      = [string]$payload.name
            $patientId = [string]$payload.patient_id
            if (-not $name -and -not $patientId) {
                Write-Json $resp @{ ok = $false; error = "Patient name or patient_id is required" } 400
                continue
            }
            $record = Get-CrmByQuery $name $patientId
            if ($record) {
                Write-Json $resp @{ ok = $true; crm_record = $record }
            } else {
                Write-Json $resp @{
                    ok = $true
                    crm_record = $null
                    note = "No CRM record found. Demo CRM only has records for the 3 sample patients (Sarah Thompson / Bob Larson / Maria Vasquez)."
                    query = @{ name = $name; patient_id = $patientId }
                }
            }
            continue
        }

        if ($path -eq "/api/analyze" -and $req.HttpMethod -eq "POST") {
            $body = Read-RequestBody $req
            try {
                $payload = $body | ConvertFrom-Json
            } catch {
                Write-Json $resp @{ ok = $false; error = "Invalid JSON body" } 400
                continue
            }
            $transcript = [string]$payload.transcript
            if (-not $transcript -or $transcript.Trim().Length -lt 10) {
                Write-Json $resp @{ ok = $false; error = "Transcript is required (min 10 chars)" } 400
                continue
            }
            $reqPatientId = [string]$payload.patient_id
            $reqPatientName = [string]$payload.patient_name

            $sops = Get-Sops
            $startTime = Get-Date
            $apiKeyNow = $env:ANTHROPIC_API_KEY
            $modelNow  = if ($env:ANTHROPIC_MODEL) { $env:ANTHROPIC_MODEL } else { $model }

            if ($apiKeyNow) {
                $result = Invoke-ClaudeAnalysis $transcript $sops $apiKeyNow $modelNow
            } else {
                $result = Invoke-LocalAnalysis $transcript $sops
                Start-Sleep -Milliseconds 1200
            }

            # Prefer the explicit lookup the Specialist did up front; fall back to
            # transcript scan only if no patient_id/name was provided.
            if ($reqPatientId -or $reqPatientName) {
                $result.crm_record = Get-CrmByQuery $reqPatientName $reqPatientId
            }

            $result.elapsed_ms = [int]((Get-Date) - $startTime).TotalMilliseconds

            Write-Json $resp $result
            continue
        }

        # Static file serving
        $rel = $path.TrimStart('/')
        if (-not $rel) { $rel = "sop-recommender.html" }
        if ($rel.StartsWith(".") -or $rel.Contains("/..") -or $rel.Contains("\..")) {
            $resp.StatusCode = 404
            $resp.OutputStream.Close()
            continue
        }

        $file = Join-Path $root $rel
        if (Test-Path $file -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($file).ToLower()
            $resp.ContentType = switch ($ext) {
                '.html' { 'text/html; charset=utf-8' }
                '.css'  { 'text/css; charset=utf-8' }
                '.js'   { 'application/javascript; charset=utf-8' }
                '.mjs'  { 'application/javascript; charset=utf-8' }
                '.json' { 'application/json; charset=utf-8' }
                '.svg'  { 'image/svg+xml' }
                '.png'  { 'image/png' }
                '.jpg'  { 'image/jpeg' }
                '.jpeg' { 'image/jpeg' }
                default { 'application/octet-stream' }
            }
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $resp.ContentLength64 = $bytes.Length
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            $resp.OutputStream.Close()
        } else {
            $resp.StatusCode = 404
            $msg = [System.Text.Encoding]::UTF8.GetBytes("Not found: $rel")
            $resp.OutputStream.Write($msg, 0, $msg.Length)
            $resp.OutputStream.Close()
        }
    } catch {
        try {
            Write-Json $resp @{ ok = $false; error = "Server error: $($_.Exception.Message)" } 500
        } catch { }
        Write-Host "[server] Request error on $($path): $($_.Exception.Message)"
    }
}

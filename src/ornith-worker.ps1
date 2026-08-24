param(
    [string]$InstanceId = ('worker-{0}' -f $PID),
    [string]$Model = $(if ($env:LOCAL_MODEL) { $env:LOCAL_MODEL } elseif ($env:ORNITH_MODEL) { $env:ORNITH_MODEL } else { 'ornith:9b' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'load-env.ps1')

# Two distinct locations, not one: PackageSrcDir is where THIS script and its sibling
# .js files (ornith-client.js, prompts.js, task-sources.js, ...) live -- fixed, wherever
# the package is installed. PipelineDir is where the CONSUMER's queue/instances/temp data
# (and its own local task sources like agent-task-db.js) lives -- set via env var, since
# the package no longer lives inside the consumer's own repo.
$PackageSrcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $env:AGENT_MANAGER_REPO_ROOT) { throw 'AGENT_MANAGER_REPO_ROOT env var is required.' }
$PipelineDir = if ($env:AGENT_MANAGER_PIPELINE_DIR) { $env:AGENT_MANAGER_PIPELINE_DIR } else { $env:AGENT_MANAGER_REPO_ROOT }
$QueueDir = Join-Path $PipelineDir 'queue'
$SecondBrainDir = if ($env:SECOND_BRAIN_DIR) { $env:SECOND_BRAIN_DIR } else { $null }

$TempDir = Join-Path $env:TEMP 'ornith-worker'
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

# Deliberately OUTSIDE Inbox: task-sources.js scans SecondBrain\Inbox\*.md as a task
# source, and a live log living there got scanned back in as a "task" on the very
# first real run (the model drafted a plan for its own transcript file). The log is an
# observability artifact, not an input -- it lives at the vault root instead.
$LiveLogPath = if ($SecondBrainDir) { Join-Path $SecondBrainDir 'Ornith Live Log.md' } else { Join-Path $TempDir 'live-log.md' }

# All dynamic content (repo files, notes, the model's own output) is built as plain
# strings in Node (prompts.js, ornith-client.js) and only ever passed here as opaque
# variable values -- never spliced into a PowerShell string literal -- so there is no
# here-string delimiter or interpolation hazard from arbitrary file content.

$InstancesDir = Join-Path $PipelineDir 'instances'
New-Item -ItemType Directory -Force -Path $InstancesDir | Out-Null

. (Join-Path $PackageSrcDir 'agent-manager-common.ps1')

# Refuse to start if a live process already holds this InstanceId -- see
# agent-manager-common.ps1's Test-InstanceLiveness for the full rationale. 60s matches
# this loop's own idle-sleep tier (the longest gap between heartbeat writes when there's
# no work).
if (-not (Test-InstanceLiveness -InstanceId $InstanceId -TickSecs 60)) { exit 1 }

# All concurrent instances should normally use the SAME model tier -- Ollama keeps only
# one tier resident on typical hardware (OLLAMA_MAX_LOADED_MODELS effectively 1), so
# mixing model tiers across instances causes swap-load thrashing, not parallelism.
# LOCAL_MODEL is what local-client.js (the 2026-08-22 rename of ornith-client.js) reads;
# ORNITH_MODEL kept set too for anything legacy still watching the old name.
$env:LOCAL_MODEL = $Model
$env:ORNITH_MODEL = $Model

# Parallel reasoning lane (port of local-worker.sh's IS_CLAUDE_LANE, Brain Dump #77):
# any instance named worker-reasoning* claims ONLY tasks whose reasoning tier
# (model-provider.js's reasoningTierFor()) resolves to 'high' -- routed to Claude by
# default, or to a local model when the dashboard override forces one -- and every other
# worker-* instance skips those, leaving them for this lane. Pure naming convention;
# queue-watchdog.ps1's RESTART_MAP already matches any 'worker-*' generically, so a
# reasoning instance is auto-restart-eligible for free.
$IsClaudeLane = $InstanceId -like 'worker-reasoning*'
# So local-client.js/model-inflight-lock.js can stamp in-flight lock records with the
# holder's identity -- purely diagnostic (same export local-worker.sh does at startup).
$env:AGENT_MANAGER_INSTANCE_ID = $InstanceId

# Same-stage A/B candidates for the implement pass only (see Select-AbModel below). Unset
# or single-entry -- the default -- means every implement call uses $Model, byte-identical
# to before this existed. Only safe on a single worker instance, same reason as above:
# running distinct candidate lists across concurrent instances would thrash the model
# cache the same way mixed model tiers would.
$AbModelsRaw = if ($env:LOCAL_AB_MODELS) { $env:LOCAL_AB_MODELS } else { $env:ORNITH_AB_MODELS }
$AbCandidates = if ($AbModelsRaw) { $AbModelsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { @() }

# Per-instance drafting subfolder: the claim mechanism. Move-Item into it is atomic on
# the same volume, so two workers can never hold the same task file.
$MyDraftingDir = Join-Path (Join-Path $QueueDir 'drafting') $InstanceId
New-Item -ItemType Directory -Force -Path $MyDraftingDir | Out-Null

# Captured once at startup so the dashboard can show instance uptime.
$startedAt = (Get-Date).ToString('o')
$script:HeartbeatModel = $Model

function Write-Heartbeat {
    param([string]$Status, [string]$TaskId = $null, [string]$Pass = $null)
    Write-HeartbeatFile -InstanceId $InstanceId -Status $Status -Model $script:HeartbeatModel -TaskId $TaskId -Pass $Pass -StartedAt $startedAt
}

# Per-tick model refresh (port of local-worker.sh's refresh_active_model): picks up the
# dashboard Workers tab's per-instance model override from dashboard-settings.json, so a
# dropdown change takes effect on the very next tick with no restart. The reasoning
# lane's override can name EITHER backend -- 'claude:<model>' or 'ollama:<model>'
# (2026-08-18, Grimmethy: "I need to be able to select from both subscription and local
# models"); AGENT_MANAGER_FORCE_PROVIDER is model-provider.js's own hook for that, and
# adhoc/research's agentic Claude implement calls are unaffected either way (see
# model-provider.js's header). The plain local lane's override stays a bare model name.
function Update-ActiveModel {
    $override = $null
    try {
        $settingsPath = Join-Path (Split-Path -Parent $PackageSrcDir) 'dashboard-settings.json'
        if (Test-Path $settingsPath) {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            $overrides = $settings.workerModelOverrides
            if ($overrides -and $overrides.PSObject.Properties[$InstanceId]) { $override = [string]$overrides.$InstanceId }
        }
    } catch { }
    if ($IsClaudeLane) {
        if ($override -like 'ollama:*') {
            $env:LOCAL_MODEL = $override.Substring(7)
            $env:ORNITH_MODEL = $env:LOCAL_MODEL
            $env:AGENT_MANAGER_FORCE_PROVIDER = 'local'
            $script:HeartbeatModel = $env:LOCAL_MODEL
        } elseif ($override -like 'claude:*') {
            $env:CLAUDE_MODEL = $override.Substring(7)
            $env:AGENT_MANAGER_FORCE_PROVIDER = 'claude'
            $script:HeartbeatModel = $override
        } else {
            Remove-Item env:AGENT_MANAGER_FORCE_PROVIDER -ErrorAction SilentlyContinue
            $script:HeartbeatModel = 'claude:{0}' -f $(if ($env:CLAUDE_MODEL) { $env:CLAUDE_MODEL } else { 'sonnet' })
        }
    } else {
        Remove-Item env:AGENT_MANAGER_FORCE_PROVIDER -ErrorAction SilentlyContinue
        if ($override) {
            $env:LOCAL_MODEL = $override
            $env:ORNITH_MODEL = $override
        }
        $script:HeartbeatModel = $env:LOCAL_MODEL
    }
}
Update-ActiveModel

# Delegated draft: run the SAME node src/local-draft.js the Linux worker uses for a
# high-reasoning-tier task, so backend selection (Claude vs local, per task, plus the
# dashboard override via AGENT_MANAGER_FORCE_PROVIDER) behaves identically on Windows --
# including adhoc/research's real agentic Claude Code CLI drafting with tool access,
# which this script's inline passes cannot provide. local-draft.js mutates the task JSON
# in place and prints one {succeeded, blocked, ...} JSON line; this function only files
# the result (review/ or blocked/) and does the bounded-failure bookkeeping, mirroring
# local-worker.sh's process_drafting_file.
function Invoke-DelegatedDraft {
    param([string]$DraftingPath, [string]$TaskId)
    $name = Split-Path -Leaf $DraftingPath
    Write-Heartbeat -Status 'working' -TaskId $TaskId -Pass 'draft'
    $draftResult = $null
    try {
        $rawLines = Invoke-WithSafeEnv { & node (Join-Path $PackageSrcDir 'local-draft.js') $DraftingPath 2>&1 }
        # stderr is merged in (diagnostics), so pick the result line out: the last line
        # that parses as the JSON object local-draft.js writes to stdout.
        $jsonLine = @($rawLines | ForEach-Object { "$_" } | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
        if ($jsonLine) { $draftResult = $jsonLine | ConvertFrom-Json }
    } catch {
        Write-Host ('local-draft.js call failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
    if ($draftResult -and $draftResult.succeeded) {
        $destDir = if ($draftResult.blocked) { 'blocked' } else { 'review' }
        New-Item -ItemType Directory -Force -Path (Join-Path $QueueDir $destDir) | Out-Null
        Move-Item $DraftingPath (Join-Path (Join-Path $QueueDir $destDir) $name) -Force
        if ($draftResult.blocked) {
            Write-Host ('Delegated draft blocked {0}: {1}' -f $TaskId, $draftResult.blockedReason) -ForegroundColor Yellow
        } else {
            Write-Host ('Delegated draft ready for review: {0}' -f $TaskId) -ForegroundColor Green
        }
    } else {
        # The draft call itself failed (Claude CLI missing/rate-limited, Ollama down, a
        # thrown error) -- retried via the per-tick resume pass, bounded at 5 attempts
        # (local-worker.sh's DRAFT_FAILURE_RETRY_LIMIT), then given up to blocked/ so one
        # persistently failing task can't starve this lane forever.
        $reasonText = if ($draftResult -and $draftResult.reason) { [string]$draftResult.reason } else { 'no parseable result from local-draft.js' }
        try {
            $t = Read-TaskJson $DraftingPath
            $failCount = 1 + $(if ($t.PSObject.Properties['draftFailureCount'] -and $t.draftFailureCount) { [int]$t.draftFailureCount } else { 0 })
            $t | Add-Member -NotePropertyName 'draftFailureCount' -NotePropertyValue $failCount -Force
            if ($failCount -ge 5) {
                Set-TaskBlockedStage -Task $t -Reason ('draft call failed {0} times in a row (most recent: {1}) -- giving up rather than retrying every tick forever and starving this lane.' -f $failCount, $reasonText) -Stage 'draft'
                New-Item -ItemType Directory -Force -Path (Join-Path $QueueDir 'blocked') | Out-Null
                Write-TaskJson (Join-Path (Join-Path $QueueDir 'blocked') $name) $t
                Remove-Item $DraftingPath -Force
                Write-Host ('Giving up on {0} after {1} failed delegated draft attempts -- moved to blocked/.' -f $TaskId, $failCount) -ForegroundColor Red
            } else {
                Write-TaskJson $DraftingPath $t
                Write-Host ('Delegated draft failed for {0} (attempt {1}/5): {2} -- retrying via the per-tick resume pass.' -f $TaskId, $failCount, $reasonText) -ForegroundColor Yellow
            }
        } catch {
            Write-Host ('Delegated draft failed for {0} and its file could not be updated: {1}' -f $TaskId, $_.Exception.Message) -ForegroundColor Red
        }
    }
}

function Invoke-OrnithClient {
    param([string]$Prompt, [bool]$Think = $true, [double]$Temperature = 0.4, [int]$NumPredict = 1400, [string]$Format = $null, [string]$ModelOverride = $null)
    $reqPath = Join-Path $TempDir ('req-{0}.json' -f ([guid]::NewGuid()))
    $reqObj = [PSCustomObject]@{ prompt = $Prompt; think = $Think; temperature = $Temperature; numPredict = $NumPredict }
    if ($Format) { $reqObj | Add-Member -NotePropertyName 'format' -NotePropertyValue $Format }
    if ($ModelOverride) { $reqObj | Add-Member -NotePropertyName 'model' -NotePropertyValue $ModelOverride }
    [System.IO.File]::WriteAllText($reqPath, ($reqObj | ConvertTo-Json -Depth 10))
    $clientPath = Join-Path $PackageSrcDir 'local-client.js'
    # 2>&1 is load-bearing, not cosmetic: without it, `& node ...` in PowerShell only ever
    # captures stdout into $rawLines -- stderr goes straight to the console/host and is
    # NEVER present in the captured variable, confirmed empirically (a `console.error(...);
    # process.exit(1)` child produced a completely empty captured array without 2>&1, and
    # the real message with it). This is exactly why arch-discovery-community-3 blocked
    # with the undiagnosable reason "call exited 1: " (nothing after the colon) --
    # ornith-client.js's CLI entry writes its actual error via console.error (stderr) then
    # process.exit(1), and that text was silently discarded before reaching this throw.
    # NOTE: an earlier version of this comment claimed review-runner.ps1's matching
    # functions already had this fixed -- checked directly, they do not; they have the
    # identical gap. Fixed there too, see review-runner.ps1's Invoke-OrnithClient /
    # Invoke-OrnithMajorityVote.
    $rawLines = Invoke-WithSafeEnv { & node $clientPath $reqPath 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        throw ('ornith-client.js call exited {0}: {1}' -f $LASTEXITCODE, (($rawLines -join ' ').Trim()))
    }
    Remove-Item $reqPath -ErrorAction SilentlyContinue
    return ($rawLines -join "`n") | ConvertFrom-Json
}

# Deterministic hash of task.id -> same task always compares the same A/B candidate across
# its whole redraft lifecycle (a watchdog reject-retry keeps testing the same model, which
# is the correct comparison unit), with no persistent counter file needed.
function Select-AbModel {
    param([string]$TaskId, [string[]]$Candidates)
    if (-not $Candidates -or $Candidates.Count -le 1) { return $null }
    $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($TaskId))
    return $Candidates[[BitConverter]::ToUInt32($hash, 0) % $Candidates.Count]
}

function Invoke-OrnithToolClient {
    param([string]$Prompt, [int]$MaxTurns = 5)
    $reqPath = Join-Path $TempDir ('tool-req-{0}.json' -f ([guid]::NewGuid()))
    $reqObj = [PSCustomObject]@{ prompt = $Prompt; maxTurns = $MaxTurns }
    [System.IO.File]::WriteAllText($reqPath, ($reqObj | ConvertTo-Json -Depth 10))
    $clientPath = Join-Path $PackageSrcDir 'local-tool-client.js'
    $rawLines = Invoke-WithSafeEnv { & node $clientPath $reqPath }
    Remove-Item $reqPath -ErrorAction SilentlyContinue
    return ($rawLines -join "`n") | ConvertFrom-Json
}

function Get-PromptText {
    param([string]$TaskPath, [string]$Pass, [string]$PlanTextPath)
    $promptsPath = Join-Path $PackageSrcDir 'prompts.js'
    if ($Pass -eq 'implement') {
        $lines = & node $promptsPath $TaskPath $Pass $PlanTextPath
    } else {
        $lines = & node $promptsPath $TaskPath $Pass
    }
    return ($lines -join "`n")
}

function Add-LiveLogEntry {
    param([string]$TaskId, [string]$Title, [string]$Pass, [string]$Thinking, [string]$Response, [string]$Degenerate)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $status = if ($Degenerate) { 'DEGENERATE ({0})' -f $Degenerate } else { 'ok' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('')
    $lines.Add(('## {0} -- {1} -- {2} [{3}]' -f $stamp, $TaskId, $Pass, $status))
    $lines.Add(('**Task:** {0}' -f $Title))
    $lines.Add('')
    $lines.Add('<details><summary>Reasoning</summary>')
    $lines.Add('')
    $lines.Add('```')
    $lines.Add((Protect-LogSecrets $Thinking))
    $lines.Add('```')
    $lines.Add('</details>')
    $lines.Add('')
    $lines.Add('**Output:**')
    $lines.Add('```')
    $lines.Add((Protect-LogSecrets $Response))
    $lines.Add('```')
    $entry = [string]::Join("`n", $lines)
    Add-Content -Path $LiveLogPath -Value $entry -Encoding utf8
}

# --- Crash-resume scan (startup, before the main loop) --------------------------------
# Some machines hard-crash for real (WHEA errors etc), so orphaned claims MUST be
# recovered: any drafting subfolder whose owning instance is dead gets its task files
# moved back to pending/. A claim is left alone ONLY while its heartbeat pid is a
# running process (checked first, above -- that's the real "still working" signal and
# has no time limit), or for a short grace window after its last heartbeat once the PID
# is confirmed gone.
#
# That grace window is NOT about how long a legitimate Ornith call can run (a call
# timing out doesn't put us here at all -- ornith-client.js's own 4-min REQUEST_TIMEOUT_MS
# crashes the worker script, and Get-Process above already found the PID missing by the
# time this runs). It exists purely for the startup race: THIS scan runs when a worker
# is starting, and a just-restarted sibling could be mid-launch and not yet have written
# its first heartbeat under its own new PID. That race resolves in seconds (Start-Process
# is near-instant), not minutes.
#
# Previously 30 min, tightened to 10 min on 2026-07-18 (reasoning: comfortably above
# queue-watchdog's 5-min staleness threshold) -- but that reasoning conflated "how long
# until queue-watchdog notices a wedge" with "how long the startup race actually lasts."
# A confirmed-dead PID (Get-Process already said so) sitting on a fresh-looking heartbeat
# for 10 min is not an active race, it's exactly the stuck-drafting-claim backlog this
# scan exists to prevent -- reproduced live 2026-07-19 when a worker crashed on a call
# that exceeded 4 min and its claim sat unrecoverable for the full 10-min window before
# the next restart could pick it up. Tightened to 1 min: comfortably covers real process
# startup time without leaving a confirmed-dead claim orphaned for minutes.
$OrphanGraceMinutes = 1
try {
    $draftingRoot = Join-Path $QueueDir 'drafting'
    if (Test-Path $draftingRoot) {
        foreach ($sub in Get-ChildItem $draftingRoot -Directory -ErrorAction SilentlyContinue) {
            $claimId = $sub.Name
            $hbPath = Join-Path $InstancesDir ($claimId + '.json')

            $isDead = $true
            if (Test-Path $hbPath) {
                try {
                    $hbContent = [System.IO.File]::ReadAllText($hbPath) | ConvertFrom-Json
                    $pidVal = $hbContent.pid
                    $lastHbStr = $hbContent.lastHeartbeat

                    # Owning process still running -- claim is live, leave it alone.
                    if ($pidVal -and (Get-Process -Id $pidVal -ErrorAction SilentlyContinue)) {
                        continue
                    }

                    # Process gone but heartbeat fresh: could be a restart race -- give
                    # it the grace window before stealing. Unparseable timestamp = stale.
                    $lastHb = $null
                    try { $lastHb = [datetime]::Parse($lastHbStr) } catch { $lastHb = $null }
                    if ($lastHb -and ((Get-Date) - $lastHb).TotalMinutes -le $OrphanGraceMinutes) {
                        continue
                    }

                    $isDead = $true
                } catch {
                    $isDead = $true
                }
            }

            if ($isDead) {
                Write-Host ('Recovering orphaned claim from dead instance: {0}' -f $claimId) -ForegroundColor DarkYellow
                foreach ($file in Get-ChildItem $sub.FullName -Filter '*.json' -ErrorAction SilentlyContinue) {
                    Move-Item $file.FullName (Join-Path (Join-Path $QueueDir 'pending') $file.Name) -Force
                }
                Remove-Item $sub.FullName -Force
            }
        }

        # Legacy single-instance leftovers: *.json directly in queue/drafting/ predate
        # per-instance claim subfolders -- requeue them too.
        foreach ($legacyFile in Get-ChildItem $draftingRoot -Filter '*.json' -ErrorAction SilentlyContinue) {
            Move-Item $legacyFile.FullName (Join-Path (Join-Path $QueueDir 'pending') $legacyFile.Name) -Force
        }

        # The recovery above may have deleted this instance's own (stale) subfolder.
        New-Item -ItemType Directory -Force -Path $MyDraftingDir | Out-Null
    }
} catch {
    Write-Host ('Crash-resume scan error (continuing startup): {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
}

Write-Host ('Worker {0} (model {1}) starting. Close this window or Ctrl+C to stop.' -f $InstanceId, $Model) -ForegroundColor Cyan

if (-not (Test-Path $LiveLogPath)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LiveLogPath) | Out-Null
    [System.IO.File]::WriteAllText($LiveLogPath, "# Live Log`n`nAppended to continuously by ornith-worker.ps1.`n")
}

Write-Heartbeat -Status 'idle'

while ($true) {
    # Pick up a dashboard model-override change (or its removal) before this tick does
    # any real work -- see Update-ActiveModel's own comment above.
    Update-ActiveModel

    # Claude rate-limit gate (port of local-worker.sh's check_budget_healthy call): only
    # the reasoning lane needs this -- it's the only lane whose tasks route to Claude. A
    # local-model worker checking it too would wrongly stall local work every time
    # Claude's account-wide cap is hit. Skips straight to a 10-minute backoff (matching
    # review-runner.ps1/apply-runner.ps1's own 'budget' tier) rather than hammering a
    # known rate-limit window every tick.
    if ($IsClaudeLane) {
        $budget = $null
        try {
            $budgetScript = Join-Path (Split-Path -Parent $PackageSrcDir) 'budget-monitor.js'
            if (Test-Path $budgetScript) {
                $budgetJson = Invoke-WithSafeEnv { & node -e "try{const{isBudgetHealthy}=require(process.argv[1]);console.log(JSON.stringify(isBudgetHealthy()))}catch(e){console.log(JSON.stringify({healthy:true,reason:'budget-monitor error (treating as healthy): '+e.message}))}" $budgetScript 2>$null }
                $budget = (@($budgetJson) -join "`n") | ConvertFrom-Json
            }
        } catch { }
        if ($budget -and -not $budget.healthy) {
            Write-Host ('Claude budget not healthy: {0} -- sleeping 10 minutes.' -f $budget.reason) -ForegroundColor DarkYellow
            Write-Heartbeat -Status 'idle'
            Start-Sleep -Seconds 600
            continue
        }
    }

    # Per-tick crash-resume (parity with local-worker.sh's top-of-tick pass -- see
    # docs/linux-migration-2026-08-14.md item 8): a draft interrupted mid-call sits in
    # THIS instance's own drafting/ subfolder, where the startup-only orphan scan above
    # can't reach it (the owning process -- this one -- is alive). Without this, such a
    # task stays claimed-but-untouched until the next process restart. Resumed INSTEAD of
    # generating/claiming anything new, so backlog can't pile up in front of it.
    $resumeFile = Get-ChildItem $MyDraftingDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object CreationTime | Select-Object -First 1
    if ($resumeFile) {
        Write-Host ('Resuming interrupted draft from own drafting/: {0}' -f $resumeFile.Name) -ForegroundColor DarkYellow
        $next = $resumeFile
        $draftingPath = $resumeFile.FullName
    } else {
    # --tier scopes generation to this lane's own reasoning tier (see local-worker.sh's
    # own comment on why both lanes generate, each for its own tier): without it, one
    # lane's generation call can keep surfacing the OTHER tier's backlog candidate every
    # tick, never reaching its own tier's real work.
    node (Join-Path $PackageSrcDir 'task-sources.js') "--tier=$(if ($IsClaudeLane) { 'high' } else { 'low' })" | Write-Host

    # DB mirror: make sure every pending file has a row (idempotent upsert per file).
    $pendingDir = Join-Path $QueueDir 'pending'
    foreach ($pendingFile in Get-ChildItem $pendingDir -Filter '*.json' -ErrorAction SilentlyContinue) {
        Invoke-TaskDb 'created' $pendingFile.FullName
    }

    # Claim order must respect task priority, not just file age: a task queued AFTER a
    # lower-priority background task was already generated must still be claimed first --
    # otherwise the priority ladder (task-sources.js, editable via the dashboard's Job
    # List tab) only holds at GENERATION time, not at claim time, and a large pre-existing
    # backlog in pending/ can starve a newer, higher-priority task indefinitely. Confirmed
    # live 2026-07-25: a fresh brain_dump_sort task (priority 42) sat behind a 28-deep
    # deep_dive backlog (priority 82) because the old rank was only ever 0 (manual) vs 1
    # (everything else) -- brain_dump_sort and deep_dive shared the same tier-1 bucket and
    # fell back to oldest-CreationTime-first, which always favored the pre-existing backlog.
    # Rank is now the SAME numeric priority task-sources.js uses to pick which source
    # generates next (via `--priority-map`), so claim order and generation order agree;
    # oldest CreationTime is still the tiebreaker within equal priority.
    $priorityMapJson = node (Join-Path $PackageSrcDir 'task-sources.js') --priority-map 2>$null
    $priorityMap = $null
    try { $priorityMap = $priorityMapJson | ConvertFrom-Json } catch { }

    # DAG readiness (agent-engine's TaskGraph pattern, adapted 2026-07-26, ahead of real
    # need -- no built-in task source declares `deps` today; this exists so claim order
    # already respects it the moment one does, without another priority-ladder-shaped
    # retrofit later). A task not present in the map (the common case: no deps field, or
    # task-sources.js couldn't be reached) is treated as ready -- same fail-open reasoning
    # $priorityMap's own missing-name fallback already uses, so a readiness-check hiccup
    # degrades to "claim order ignores deps this tick," never to "nothing is claimable."
    $readinessMapJson = node (Join-Path $PackageSrcDir 'task-sources.js') --pending-readiness 2>$null
    $readinessMap = $null
    try { $readinessMap = $readinessMapJson | ConvertFrom-Json } catch { }

    # Reasoning-tier lane split (see $IsClaudeLane above): {taskId: 'low'|'high'} for
    # everything in pending/, from the SAME reasoningTierFor() local-draft.js routes
    # backends with, so claim-lane and backend decisions can never disagree. One batch
    # node call per tick, same split as --priority-map/--pending-readiness. A task absent
    # from the map counts as 'low' (fail-open to the ordinary local lane).
    $tiersMapJson = node (Join-Path $PackageSrcDir 'task-sources.js') --pending-tiers 2>$null
    $tiersMap = $null
    try { $tiersMap = $tiersMapJson | ConvertFrom-Json } catch { }

    $next = Get-ChildItem $pendingDir -Filter '*.json' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rank = 999
            $ready = $true
            $taskId = $_.BaseName
            if ($readinessMap -and $readinessMap.PSObject.Properties[$taskId] -and $readinessMap.$taskId -eq $false) {
                $ready = $false
            }
            # Lane filter: the reasoning lane claims ONLY high-tier tasks; every other
            # lane skips them, leaving them free for the reasoning lane to pick up.
            $tier = 'low'
            if ($tiersMap -and $tiersMap.PSObject.Properties[$taskId]) { $tier = [string]$tiersMap.$taskId }
            if ($IsClaudeLane) {
                if ($tier -ne 'high') { $ready = $false }
            } elseif ($tier -eq 'high') {
                $ready = $false
            }
            try {
                $task = Get-Content $_.FullName -Raw | ConvertFrom-Json
                # Mirrors task-source-registry.js's resolveSourceName(): most sources
                # register under the exact same name as task.source, but adhoc/secondbrain
                # key off task.domain instead, and unused_export's task.source is the
                # legacy 'deadcode_triage' name.
                $name = $task.source
                if ($task.domain -eq 'adhoc') { $name = 'adhoc' }
                elseif ($task.domain -eq 'secondbrain') { $name = 'secondbrain' }
                elseif ($task.source -eq 'deadcode_triage') { $name = 'unused_export' }
                if ($priorityMap -and $priorityMap.PSObject.Properties[$name]) {
                    $rank = $priorityMap.$name
                }
            } catch { }
            [PSCustomObject]@{ File = $_; Rank = $rank; CreationTime = $_.CreationTime; Ready = $ready }
        } |
        Where-Object { $_.Ready } |
        Sort-Object Rank, CreationTime |
        Select-Object -First 1 -ExpandProperty File

    if (-not $next) {
        Write-Host 'No pending work. Sleeping 60s.' -ForegroundColor DarkGray
        Write-Heartbeat -Status 'idle'
        Start-Sleep -Seconds 60
        continue
    }

    # Atomic claim: Move-Item into this instance's own drafting subfolder. On the same
    # volume the rename is atomic -- if two instances race, exactly one succeeds and the
    # loser lands here in the catch (not an error, just a lost race).
    $draftingPath = Join-Path $MyDraftingDir $next.Name
    try {
        Move-Item $next.FullName $draftingPath -Force -ErrorAction Stop
    } catch {
        # Reproduced live 2026-07-19: with no backoff here, a losing instance re-hits this
        # same race every loop iteration with zero delay -- a visible rapid-fire console
        # spam loop burning CPU for no reason until manually killed. 3s is deliberately
        # well under the 60s no-work sleep above (losing a race means there IS work, so
        # retrying should be faster than the idle poll) but not zero.
        #
        # This backoff is a hygiene fix for the SYMPTOM, not a fix for the underlying
        # cause: normal operation should never have two instances sharing one InstanceId
        # racing over the same claim in the first place (queue-watchdog.ps1's automatic
        # restart racing a manual restart is the mechanism observed live -- see
        # docs/pipeline-incident-2026-07-19.md). A lock/registry so only one process per
        # InstanceId can exist is the real fix for that; out of scope here.
        Write-Host ('Another instance claimed: {0}' -f $next.Name) -ForegroundColor DarkGray
        Start-Sleep -Seconds 3
        continue
    }
    } # end of the no-resume (generate + claim) path above

    # Per-task error isolation (2026-07-19, the real fix behind candidate AC-015's correct
    # diagnosis): before this try existed, ANY uncaught error in the pass sequence below --
    # most commonly ornith-client.js's 4-min REQUEST_TIMEOUT_MS surfacing as a thrown
    # exception under $ErrorActionPreference='Stop' -- killed the ENTIRE worker process.
    # That one mechanism drove every crash loop of the 2026-07-19 incident: process death
    # -> -NoExit zombie shell -> watchdog restart -> full task redo -> same wall. A failed
    # call is a TASK outcome, not a process outcome: the catch at the bottom of this loop
    # dispositions the task (retry via pending, or blocked after 3 failures) and the loop
    # lives on. Body deliberately not re-indented -- see the paired catch below.
    try {

    $task = Read-TaskJson $draftingPath

    # Repo-scoping guard (added 2026-07-27, see task-sources.js's writeTask() comment for
    # the incident): several sources resolve config paths that collapse to the SAME
    # absolute location regardless of which sibling repo AGENT_MANAGER_REPO_ROOT currently
    # points at, so a task generated under one repo can otherwise be claimed and drafted
    # against a totally different one if the pipeline gets repointed in between. Checked
    # here, immediately after claim and before the Plan pass spends any real Ornith
    # compute -- not silently skipped, blocked with a clear reason, same as every other
    # early-exit in this loop. A task with no generatedForRepoRoot at all predates this
    # fix and is let through unchanged (fail-open only for that legacy case, so shipping
    # this doesn't instantly block the existing real backlog) -- but a task that HAS the
    # field and doesn't match is a real, actionable mismatch, not an ambiguous one.
    if ($task.PSObject.Properties['generatedForRepoRoot'] -and
        $task.generatedForRepoRoot -and
        $task.generatedForRepoRoot -ne $env:AGENT_MANAGER_REPO_ROOT) {
        $reason = 'Task was generated for repo "{0}" but this worker is currently pointed at "{1}" -- refusing to draft against the wrong repo.' -f $task.generatedForRepoRoot, $env:AGENT_MANAGER_REPO_ROOT
        Set-TaskBlockedStage -Task $task -Reason $reason -Stage 'repo-scope-mismatch'
        $blockedPath = Join-Path (Join-Path $QueueDir 'blocked') $next.Name
        Write-TaskJson $blockedPath $task
        Remove-Item $draftingPath -Force
        Write-Host ('Blocked (repo-scope mismatch): {0}' -f $task.id) -ForegroundColor Yellow
        Invoke-TaskDb 'blocked' $blockedPath (@{ reason = $reason } | ConvertTo-Json -Compress)
        Write-Heartbeat -Status 'idle'
        continue
    }

    Write-Host ('Drafting: {0}' -f $task.title) -ForegroundColor Green
    Invoke-TaskDb 'claimed' $draftingPath (@{ instanceId = $InstanceId; model = $script:HeartbeatModel } | ConvertTo-Json -Compress)

    # Reasoning-tier dispatch: a high-tier task (and everything the reasoning lane holds,
    # including a resumed leftover) drafts through node local-draft.js -- the same module
    # the Linux worker uses -- which routes each pass to Claude or the local model via
    # model-provider.js's providerFor(). Low-tier tasks keep this script's native inline
    # passes below, which retain the arch_discovery/arch_import structural checks
    # local-draft.js deliberately omits.
    $resolvedTier = 'low'
    try {
        $tierLines = Invoke-WithSafeEnv { & node -e "require(process.argv[1]);const{reasoningTierFor}=require(process.argv[2]);const t=JSON.parse(require('fs').readFileSync(process.argv[3],'utf8'));console.log(reasoningTierFor(t))" (Join-Path $PackageSrcDir 'task-sources.js') (Join-Path $PackageSrcDir 'model-provider.js') $draftingPath 2>$null }
        if (((@($tierLines) -join '')).Trim() -eq 'high') { $resolvedTier = 'high' }
    } catch { }
    if ($IsClaudeLane -or $resolvedTier -eq 'high') {
        Invoke-DelegatedDraft -DraftingPath $draftingPath -TaskId $task.id
        Write-Heartbeat -Status 'idle'
        continue
    }

    # Pre-drafted task escape hatch: when the caller (a human, or an orchestrating agent
    # acting as architect) already knows the exact implementResponse and sets
    # preDrafted:true, skip Ornith's plan/implement/critique-revise passes entirely instead
    # of asking it to (re)generate what's already known. Added 2026-07-25 after Ornith
    # mangled a 2-line, fully-specified find/replace -- it paraphrased and truncated the
    # verbatim source it was given instead of copying it, on a task where there was nothing
    # left to figure out. Generation is where that failure mode lives; judging an
    # already-written diff is a comparatively reliable task, so this still routes through
    # review-runner's normal critique -- it only skips the drafting calls, not the safety
    # net. Requires a non-empty implementResponse (an empty pre-drafted task would just
    # rubber-stamp nothing into review).
    $isPreDrafted = $task.PSObject.Properties['preDrafted'] -and $task.preDrafted -and
        -not [string]::IsNullOrWhiteSpace($task.implementResponse)

    if ($isPreDrafted) {
        if (-not $task.PSObject.Properties['planResponse'] -or [string]::IsNullOrWhiteSpace($task.planResponse)) {
            $task | Add-Member -NotePropertyName 'planResponse' -NotePropertyValue 'Pre-drafted task: the exact implementResponse below was specified directly by the caller, not produced by a plan+implement pass.' -Force
        }
        $task | Add-Member -NotePropertyName 'draftedAt' -NotePropertyValue ((Get-Date).ToString('o')) -Force
        $task | Add-Member -NotePropertyName 'critiqueOutcome' -NotePropertyValue 'skipped-pre-drafted' -Force
        Invoke-TaskDb 'draft-done' $draftingPath (@{ critiqueOutcome = 'skipped-pre-drafted' } | ConvertTo-Json -Compress)

        $reviewPath = Join-Path (Join-Path $QueueDir 'review') $next.Name
        Write-TaskJson $reviewPath $task
        Remove-Item $draftingPath -Force
        Write-Host ('Ready for review (pre-drafted, no Ornith generation): {0}' -f $task.id) -ForegroundColor Cyan
        Invoke-TaskDb 'ready-for-review' $reviewPath

        Write-Heartbeat -Status 'idle'
        continue
    }

    # --- Plan pass ---
    Write-Heartbeat -Status 'working' -TaskId $task.id -Pass 'plan'
    $planSw = [System.Diagnostics.Stopwatch]::StartNew()

    # Skip-plan-on-retry, added 2026-08-04: when the LAST attempt's rejection came from a
    # deterministic gate (review-runner.ps1's non-implementation check or fixedLiterals
    # compliance check -- reviewProvider starts with 'deterministic-'), the plan itself was
    # never in question, only implement failed to follow it or copy given data verbatim.
    # Reusing the already-produced plan and going straight to a fresh implement (now also
    # informed by priorRejectionFeedback, see prompts.js) saves one full ~7-8min Ornith call
    # per retry. Deliberately does NOT apply when the last rejection came from genuine
    # Ornith review (reviewProvider='ornith') -- confirmed live this session that a real bug
    # (a wrong Prisma property name) originated in the PLAN text itself, not implement, so a
    # plan-quality judgment call from Ornith review must still get a fresh plan attempt, not
    # risk silently repeating a flawed one forever.
    $skipPlan = $task.ornithRejectCount -gt 0 -and
        $task.PSObject.Properties['reviewProvider'] -and
        $task.reviewProvider -like 'deterministic-*' -and
        $task.PSObject.Properties['planResponse'] -and
        -not [string]::IsNullOrWhiteSpace($task.planResponse)

    if ($skipPlan) {
        Write-Host ('Plan pass skipped (prior rejection was a deterministic gate, not a plan problem): {0}' -f $task.id) -ForegroundColor DarkCyan
        $planResult = [PSCustomObject]@{ response = $task.planResponse; thinking = ''; degenerate = $null; toolCallLog = $null }
    } else {
        $planPrompt = Get-PromptText -TaskPath $draftingPath -Pass 'plan'
        # arch_discovery's plan pass was wired to try a real, narrow, read-only codebase-search
        # tool (grep_codebase via ornith-tool-client.js's /api/chat tool-calling loop) instead
        # of the plain single-shot /api/generate call every other source uses. DISABLED
        # 2026-07-15: confirmed live that Ollama's /api/chat + tools hangs indefinitely on this
        # model/hardware (a standalone test with a trivial prompt never returned in 30 minutes),
        # and a real arch_discovery task through Invoke-OrnithToolClient stalled the whole
        # worker for 13+ minutes with no progress even AFTER the Node-side kill-switch file was
        # already in place -- the degrade-to-plain-call path did not actually unstick it. Rather
        # than keep debugging a known-broken feature live against the production queue, this
        # reverts arch_discovery to the same plain call every other source already uses, byte-
        # for-byte. Do not re-enable Invoke-OrnithToolClient here until the underlying hang is
        # root-caused and fixed in isolation, off the live queue.
        $planResult = Invoke-OrnithClient -Prompt $planPrompt -Think $true -Temperature 0.4 -NumPredict 1400
    }
    $planSw.Stop()
    # Invoke-OrnithToolClient's result shape is { response, toolCallLog, turnsUsed,
    # toolsDisabled } -- no .thinking or .degenerate fields, unlike Invoke-OrnithClient's
    # { response, thinking, degenerate, attempts }. Handle the shape mismatch defensively
    # rather than let a missing property crash the loop or silently miscompute degeneracy.
    $planThinking = if ($null -ne $planResult.thinking) { $planResult.thinking } else { '' }
    $planDegenerate = if ($null -ne $planResult.degenerate) {
        $planResult.degenerate
    } elseif ([string]::IsNullOrWhiteSpace($planResult.response)) {
        'empty'
    } else {
        $null
    }
    Add-LiveLogEntry -TaskId $task.id -Title $task.title -Pass 'Plan' -Thinking $planThinking -Response $planResult.response -Degenerate $planDegenerate

    # 'empty' specifically (not repeated-character/repetition-loop/non-ascii-gibberish) is
    # this model's documented thinking-budget-exhaustion failure mode: the hidden `thinking`
    # trace burns the entire num_predict allotment and leaves zero tokens for the actual
    # answer -- a real, silent empty response, not a transient glitch that a same-config
    # retry would fix (ornith-client.js's call() already retried 3x with thinking on before
    # returning here). See docs/ornith-delegation.md's own hard-won conclusion: "thinking
    # off -- don't just raise num_predict and hope it finishes." Retrying once WITHOUT
    # thinking frees the whole budget for the answer instead, before giving up and blocking.
    if ($planDegenerate -eq 'empty' -and -not $skipPlan) {
        Write-Host ('Plan empty with thinking on, retrying without thinking: {0}' -f $task.id) -ForegroundColor DarkYellow
        $planResult = Invoke-OrnithClient -Prompt $planPrompt -Think $false -Temperature 0.4 -NumPredict 1400
        $planThinking = if ($null -ne $planResult.thinking) { $planResult.thinking } else { '' }
        $planDegenerate = if ($null -ne $planResult.degenerate) {
            $planResult.degenerate
        } elseif ([string]::IsNullOrWhiteSpace($planResult.response)) {
            'empty'
        } else {
            $null
        }
        Add-LiveLogEntry -TaskId $task.id -Title $task.title -Pass 'Plan (no-think retry)' -Thinking $planThinking -Response $planResult.response -Degenerate $planDegenerate
    }

    if ($planDegenerate) {
        $reason = 'Plan pass degenerate: {0}' -f $planDegenerate
        Set-TaskBlockedStage -Task $task -Reason $reason
        $blockedPath = Join-Path (Join-Path $QueueDir 'blocked') $next.Name
        Write-TaskJson $blockedPath $task
        Remove-Item $draftingPath -Force
        Write-Host ('Blocked (degenerate plan): {0}' -f $task.id) -ForegroundColor Yellow
        Invoke-TaskDb 'blocked' $blockedPath (@{ reason = $reason } | ConvertTo-Json -Compress)
        Write-Heartbeat -Status 'idle'
        continue
    }

    if ($task.source -eq 'arch_discovery') {
        $task | Add-Member -NotePropertyName 'toolCallLog' -NotePropertyValue $planResult.toolCallLog -Force
    }

    # project_search's plan pass proposes search queries (text in/out -- Ornith has no
    # network access); the HARNESS runs them here, between plan and implement, and hands
    # real results to the implement pass. See ADR-0018 / docs/project-search-pipeline.md.
    # Must write the updated task back to $draftingPath before Get-PromptText's implement
    # call below, since prompts.js's CLI entry point re-reads the task fresh from disk on
    # every invocation rather than taking it as an in-memory argument.
    if ($task.source -eq 'project_search') {
        $queries = [regex]::Matches($planResult.response, '(?m)^QUERY:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ }
        $searchResults = @()
        if ($queries.Count -gt 0) {
            $queriesPath = Join-Path $TempDir ('project-search-queries-{0}.json' -f $task.id)
            [System.IO.File]::WriteAllText($queriesPath, (@{ queries = $queries } | ConvertTo-Json))
            try {
                $fetchScript = Join-Path $PackageSrcDir 'project-search-fetch.js'
                $rawResults = & node $fetchScript $queriesPath
                $parsed = ($rawResults -join "`n") | ConvertFrom-Json
                # ConvertFrom-Json on a real JSON array normally stays an array, but a
                # single-element result isn't guaranteed to -- force it back to an array so
                # downstream .Count/.length checks (both here and in prompts.js) don't
                # silently misbehave on exactly one result.
                $searchResults = @($parsed)
            } catch {
                Write-Host ('project-search-fetch failed (non-fatal, implement proceeds with no results): {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
            } finally {
                Remove-Item $queriesPath -ErrorAction SilentlyContinue
            }
        }
        $task.promptContext | Add-Member -NotePropertyName 'searchResults' -NotePropertyValue $searchResults -Force
        Write-TaskJson $draftingPath $task
    }

    # arch_import's plan pass proposes search terms for agent-manager's OWN repo (not
    # GitHub/Hugging Face) -- same two-call shape as project_search immediately above,
    # searching a different target. See ADR-0020 / docs/arch-import-pipeline.md.
    if ($task.source -eq 'arch_import') {
        # @() forces array-ness even when the plan proposes exactly ONE query (a valid,
        # explicitly-allowed shape per archImportPlanPrompt's "1 to 3" instruction) -- without
        # it, PowerShell's pipeline auto-collapses a single match to a plain scalar String.
        # ConvertTo-Json then serializes `queries` as a JSON STRING, not an array; arch-import-
        # fetch.js's `for (const query of queries)` iterates a STRING CHARACTER BY CHARACTER,
        # feeding grepCodebase() single letters like "p"/"i" as "queries". A single-letter
        # literal-substring match hits nearly every line, exploding into a huge, meaningless
        # hit set (reproduced live 2026-07-21: arch-import-autogen-microsoft-1's plan proposed
        # ONE query, "pipeline configuration module", and got 232 hits back tagged
        # query:"p"/"i"/etc against one arbitrary file -- garbage noise, not a real match).
        # Same PowerShell array-collapse gotcha already fixed on the OUTPUT side of
        # project_search's ConvertFrom-Json a few lines above ($searchResults = @($parsed));
        # this is the identical bug on the INPUT side of the analogous arch_import branch.
        $importQueries = @([regex]::Matches($planResult.response, '(?m)^QUERY:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ })
        $harnessHits = @()
        $harnessFiles = @()
        if ($importQueries.Count -gt 0) {
            $importQueriesPath = Join-Path $TempDir ('arch-import-queries-{0}.json' -f $task.id)
            [System.IO.File]::WriteAllText($importQueriesPath, (@{ queries = $importQueries } | ConvertTo-Json))
            try {
                $importFetchScript = Join-Path $PackageSrcDir 'arch-import-fetch.js'
                $rawImportResults = & node $importFetchScript $importQueriesPath
                $parsedImportResults = ($rawImportResults -join "`n") | ConvertFrom-Json
                if ($parsedImportResults.hits) { $harnessHits = @($parsedImportResults.hits) }
                if ($parsedImportResults.files) { $harnessFiles = @($parsedImportResults.files) }
            } catch {
                Write-Host ('arch-import-fetch failed (non-fatal, implement proceeds with no results): {0}' -f $_.Exception.Message) -ForegroundColor DarkYellow
            } finally {
                Remove-Item $importQueriesPath -ErrorAction SilentlyContinue
            }
        }
        $task.promptContext | Add-Member -NotePropertyName 'harnessHits' -NotePropertyValue $harnessHits -Force
        $task.promptContext | Add-Member -NotePropertyName 'harnessFiles' -NotePropertyValue $harnessFiles -Force
        Write-TaskJson $draftingPath $task
    }

    Invoke-TaskDb 'plan-done' $draftingPath (@{ planDurationMs = $planSw.ElapsedMilliseconds; planAttempts = $(if ($planResult.attempts) { $planResult.attempts } else { 1 }) } | ConvertTo-Json -Compress)

    $planTextPath = Join-Path $TempDir ('plan-{0}.txt' -f $task.id)
    [System.IO.File]::WriteAllText($planTextPath, $planResult.response)

    # --- Implement pass (small, scoped -- large one-shot generation degenerates; this
    # asks for one bounded artifact, not a whole feature) ---
    # A consumer's own JSON-producing sources (e.g. this pipeline's state_targets/
    # field_map_gap) should grammar-constrain the same way -- see README.md "Registering
    # a custom implement format." trouble_log/arch_review/adhoc ("Group B") are
    # JSON-constrained here since their implement pass emits a single
    # {mode, file, find/replace/content} object, or a JSON array of them for a multi-file
    # change (see prompts.js), applied deterministically by apply-group-b.js. Constrained
    # decoding requires Think=$false on this model class: think=$true + format:json can
    # return an EMPTY response, while think=$false + format:json returns clean parseable
    # JSON. The implement pass is mechanical (corrected plan -> JSON) so it does not need
    # the reasoning trace. Everything else's implement pass is prose/code -> leave it
    # unconstrained + thinking on.
    Write-Heartbeat -Status 'working' -TaskId $task.id -Pass 'implement'
    $abCandidate = Select-AbModel -TaskId $task.id -Candidates $AbCandidates

    # Resolve the selected candidate through model-strategies.js's named registry (chatdev's
    # ThinkingRegistration pattern, adapted 2026-07-26): a candidate can be a bare Ollama
    # model tag (today's exact ORNITH_AB_MODELS=ornith:9b,hermes3:8b usage, unchanged) or a
    # registered strategy NAME carrying its own temperature/numPredict/think overrides.
    # $abModel stays the resolved MODEL TAG either way (never a strategy name) -- every
    # downstream use (-ModelOverride, the stats DB's `model` column) expects a real tag.
    $abModel = $abCandidate
    $abStrategyTemperature = $null
    $abStrategyNumPredict = $null
    $abStrategyThink = $null
    if ($abCandidate) {
        try {
            $strategyJson = node (Join-Path $PackageSrcDir 'model-strategies.js') --resolve $abCandidate 2>$null
            $strategy = $strategyJson | ConvertFrom-Json
            if ($strategy -and $strategy.model) {
                $abModel = $strategy.model
                if ($null -ne $strategy.temperature) { $abStrategyTemperature = [double]$strategy.temperature }
                if ($null -ne $strategy.numPredict) { $abStrategyNumPredict = [int]$strategy.numPredict }
                if ($null -ne $strategy.think) { $abStrategyThink = [bool]$strategy.think }
            }
        } catch { }
    }

    $implSw = [System.Diagnostics.Stopwatch]::StartNew()

    # arch_import deterministic short-circuit: skip the implement call entirely when the
    # harness found NOTHING to ground a candidate in. Confirmed live 2026-07-21 across the
    # first ~14 real arch_import drafts: grep-codebase-tool.js does literal substring
    # matching, so a zero-hit harness result is the COMMON case here, not an edge case
    # (10/14) -- and archImportImplementPrompt's explicit "output the empty string if
    # nothing groundable was found" instruction was only reliably followed about 40% of
    # the time; the rest fabricated a candidate anyway (a hallucinated Python config
    # module, raw JSX, etc.) despite zero real files to ground it in. The structural check
    # (arch-discovery-structcheck.js) already catches every one of those before they reach
    # review, so nothing bad was ever going to ship -- but repeatedly trusting an
    # instruction this model demonstrably won't reliably follow, when the correct answer
    # is already deterministically knowable from the harness result alone, wastes a real
    # GPU call and a real block for an outcome that was never in doubt.
    $skipImplement = $task.source -eq 'arch_import' -and $task.promptContext.harnessHits.Count -eq 0 -and $task.promptContext.harnessFiles.Count -eq 0
    if ($skipImplement) {
        Write-Host ('arch_import: harness found nothing groundable, skipping implement call: {0}' -f $task.id) -ForegroundColor DarkGray
        $implResult = [PSCustomObject]@{ response = ''; thinking = ''; degenerate = $null; attempts = 0 }
    } else {
        $implPrompt = Get-PromptText -TaskPath $draftingPath -Pass 'implement' -PlanTextPath $planTextPath
        # brain_dump_sort added here (2026-07-22): its implement pass outputs a single JSON
        # classification object (see prompts.js's brainDumpSortImplementPrompt), not prose --
        # same "constrained decoding needs Think=$false on this model class" reasoning as
        # trouble_log/arch_review/adhoc's Group B JSON above (think=$true + format:json can
        # return an EMPTY response on this model; think=$false + format:json returns clean
        # parseable JSON).
        # Per-call defaults fall back to today's fixed values whenever the selected
        # strategy doesn't override that particular parameter -- an unset/bare-tag
        # ORNITH_AB_MODELS resolves to no overrides at all (model-strategies.js's own
        # backward-compatibility guarantee), so this is byte-identical to before the
        # registry existed unless a strategy explicitly opts into different settings.
        $implTemperature = if ($null -ne $abStrategyTemperature) { $abStrategyTemperature } else { 0.4 }
        $implNumPredict = if ($null -ne $abStrategyNumPredict) { $abStrategyNumPredict } else { 1400 }
        if ($task.source -in @('trouble_log', 'arch_review', 'brain_dump_sort') -or $task.domain -eq 'adhoc') {
            $implThink = if ($null -ne $abStrategyThink) { $abStrategyThink } else { $false }
            $implResult = Invoke-OrnithClient -Prompt $implPrompt -Think $implThink -Temperature $implTemperature -NumPredict $implNumPredict -Format 'json' -ModelOverride $abModel
        } else {
            $implThink = if ($null -ne $abStrategyThink) { $abStrategyThink } else { $true }
            $implResult = Invoke-OrnithClient -Prompt $implPrompt -Think $implThink -Temperature $implTemperature -NumPredict $implNumPredict -ModelOverride $abModel
        }
    }
    $implSw.Stop()
    Add-LiveLogEntry -TaskId $task.id -Title $task.title -Pass 'Implement' -Thinking $implResult.thinking -Response $implResult.response -Degenerate $implResult.degenerate

    $task | Add-Member -NotePropertyName 'planResponse' -NotePropertyValue $planResult.response -Force
    $task | Add-Member -NotePropertyName 'implementResponse' -NotePropertyValue $implResult.response -Force
    $task | Add-Member -NotePropertyName 'draftedAt' -NotePropertyValue ((Get-Date).ToString('o')) -Force

    $abCallId = [guid]::NewGuid().ToString()
    $task | Add-Member -NotePropertyName 'abCallId' -NotePropertyValue $abCallId -Force
    Invoke-ModelStatsDb 'record-call' @{
        callId = $abCallId
        taskId = $task.id
        stage = 'implement'
        model = $(if ($abModel) { $abModel } else { $Model })
        candidates = ($AbCandidates -join ',')
        startedAt = (Get-Date).ToString('o')
        latencyMs = $implSw.ElapsedMilliseconds
        evalDurationNs = $implResult.eval_duration
        promptEvalCount = $implResult.prompt_eval_count
        evalCount = $implResult.eval_count
        attempts = $implResult.attempts
        degenerate = $implResult.degenerate
        callError = $null
    }

    if ($implResult.degenerate) {
        $reason = 'Implement pass degenerate: {0}' -f $implResult.degenerate
        Set-TaskBlockedStage -Task $task -Reason $reason
        $blockedPath = Join-Path (Join-Path $QueueDir 'blocked') $next.Name
        Write-TaskJson $blockedPath $task
        Remove-Item $draftingPath -Force
        Write-Host ('Blocked (degenerate implement): {0}' -f $task.id) -ForegroundColor Yellow
        Invoke-TaskDb 'blocked' $blockedPath (@{ reason = $reason } | ConvertTo-Json -Compress)
        Write-Heartbeat -Status 'idle'
        continue
    }

    Invoke-TaskDb 'draft-done' $draftingPath (@{ implementDurationMs = $implSw.ElapsedMilliseconds; implementAttempts = $(if ($implResult.attempts) { $implResult.attempts } else { 1 }); tokensIn = $(if ($implResult.prompt_eval_count) { $implResult.prompt_eval_count } else { $null }); tokensOut = $(if ($implResult.eval_count) { $implResult.eval_count } else { $null }) } | ConvertTo-Json -Compress)

    # --- Critique + revision pass: a SECOND, independent model call reviews the drafter's
    # own Implement output with fresh eyes before it ever reaches queue/review/ (the final
    # gate). Catches issues earlier and cheaper. Bounded to one revision round -- the
    # review pass is still the final gate either way, so this is a quality pre-pass, not a
    # replacement for it. See prompts.js's buildCritiquePrompt/buildRevisionPrompt.
    $implTextPath = Join-Path $TempDir ('impl-{0}.txt' -f $task.id)
    [System.IO.File]::WriteAllText($implTextPath, $implResult.response)

    # Skip critique/revision entirely when the implement call itself was already
    # deterministically skipped ($skipImplement, arch_import's zero-harness-grounding
    # short-circuit above). Reproduced live 2026-07-21, the very first night this fix ran:
    # critique doesn't know an empty implementResponse here is an INTENTIONAL, correct
    # "nothing to write" outcome rather than a failure -- it just sees a blank draft and
    # (reasonably, from its own perspective) flags it as needing revision. The revision
    # pass then gets asked to fix a draft it was never given ("ORIGINAL IMPLEMENT DRAFT"
    # is empty) and produces confused meta-commentary asking for the missing draft --
    # which the structural check then correctly catches, but only after wasting two more
    # real Ornith calls turning a deliberately-correct empty response into garbage. If
    # there's genuinely nothing to write, there's nothing to critique either.
    if ($skipImplement) {
        $task | Add-Member -NotePropertyName 'critiqueOutcome' -NotePropertyValue 'skipped-no-grounding' -Force
    } else {
    Write-Heartbeat -Status 'working' -TaskId $task.id -Pass 'critique'

    $critiquePromptLines = & node (Join-Path $PackageSrcDir 'prompts.js') $draftingPath 'critique' $planTextPath $implTextPath
    $critiquePrompt = ($critiquePromptLines -join "`n")
    $critiqueResult = Invoke-OrnithClient -Prompt $critiquePrompt -Think $true -Temperature 0.4 -NumPredict 900
    Add-LiveLogEntry -TaskId $task.id -Title $task.title -Pass 'Critique' -Thinking $critiqueResult.thinking -Response $critiqueResult.response -Degenerate $critiqueResult.degenerate

    if ($critiqueResult.degenerate) {
        # Critic failed -- inconclusive, don't block the task over this.
        $task | Add-Member -NotePropertyName 'critiqueOutcome' -NotePropertyValue 'critique-degenerate' -Force
    } elseif (((($critiqueResult.response).Trim()).ToLower() -eq 'no issues found') -or (($critiqueResult.response).StartsWith('NO ISSUES FOUND'))) {
        # No real feedback -- skip revision.
        $task | Add-Member -NotePropertyName 'critiqueOutcome' -NotePropertyValue 'no-issues' -Force
    } else {
        # Real issues flagged -- one-round revision attempt (targeted-correction pattern).
        $task | Add-Member -NotePropertyName 'critiqueOutcome' -NotePropertyValue 'issues-flagged' -Force
        $task | Add-Member -NotePropertyName 'critiqueResponse' -NotePropertyValue $critiqueResult.response -Force

        $critiqueTextPath = Join-Path $TempDir ('critique-{0}.txt' -f $task.id)
        [System.IO.File]::WriteAllText($critiqueTextPath, $critiqueResult.response)

        $revisePromptLines = & node (Join-Path $PackageSrcDir 'prompts.js') $draftingPath 'revise' $planTextPath $implTextPath $critiqueTextPath
        $revisePrompt = ($revisePromptLines -join "`n")
        $reviseResult = Invoke-OrnithClient -Prompt $revisePrompt -Think $true -Temperature 0.4 -NumPredict 1400
        Add-LiveLogEntry -TaskId $task.id -Title $task.title -Pass 'Revision' -Thinking $reviseResult.thinking -Response $reviseResult.response -Degenerate $reviseResult.degenerate

        if (-not $reviseResult.degenerate) {
            # $task.implementResponse was already snapshotted from $implResult.response
            # earlier in the loop, before this block runs. Strings are copied by value in
            # PowerShell, so mutating $implResult.response here does NOT retroactively
            # update $task.implementResponse -- and it's $task.implementResponse that
            # review-runner.ps1 actually reads from the queued JSON file.
            $implResult.response = $reviseResult.response
            $task | Add-Member -NotePropertyName 'implementResponse' -NotePropertyValue $reviseResult.response -Force
            $task | Add-Member -NotePropertyName 'revisionApplied' -NotePropertyValue $true -Force
        } else {
            # Revision was degenerate -- bounded to one attempt, leave original draft intact.
            $task | Add-Member -NotePropertyName 'revisionApplied' -NotePropertyValue $false -Force
        }
    }
    }

    # Cleanup and DB mirror run unconditionally for all three critique outcomes -- not just
    # the issues-flagged path -- so a leaked temp file or a missing dashboard row doesn't
    # silently accumulate on the (majority) clean-draft case.
    Remove-Item $planTextPath -ErrorAction SilentlyContinue
    Remove-Item $implTextPath -ErrorAction SilentlyContinue
    if ($critiqueTextPath) {
        Remove-Item $critiqueTextPath -ErrorAction SilentlyContinue
    }
    Invoke-TaskDb 'draft-done' $draftingPath (@{ critiqueOutcome = $task.critiqueOutcome; revisionApplied = $(if ($task.PSObject.Properties['revisionApplied']) { $task.revisionApplied } else { $null }) } | ConvertTo-Json -Compress)

    # Structural sanity check for both markdown-candidate sources (arch_discovery AND
    # arch_import -- arch_import's implement output is the exact same "### AC-NNN · Title
    # / Strength / Files / Problem/Solution/Benefits" shape, just with an extra Source:
    # line), run AFTER critique/revision (so it sees the final, possibly-revised
    # implementResponse) and BEFORE review. Reproduced live 2026-07-21 on arch_discovery: a
    # Revision pass, asked to fix a critiqued draft, produced fluent English refusing to
    # verify the draft ("I cannot verify this draft...") instead of either fixing it or
    # outputting nothing -- coherent prose, not gibberish/empty/repeated-character, so
    # detectDegenerate() (ornith-client.js) never catches it. That exact response then won
    # a 2/3 APPROVE review vote and would have landed in the real candidates doc. Reuses
    # parseArchDiscoveryCandidates (the SAME parser apply-group-a.js's real apply step
    # uses for BOTH sources) via arch-discovery-structcheck.js, so "does this look like a
    # real candidate" is answered identically wherever it's asked -- a second, drifted
    # copy of this logic would just recreate the exact bug class this whole session has
    # been about. See arch-discovery-structcheck.js's own header comment for the full
    # incident.
    if (($task.source -eq 'arch_discovery' -or $task.source -eq 'arch_import') -and -not [string]::IsNullOrWhiteSpace($task.implementResponse)) {
        $structCheckTextPath = Join-Path $TempDir ('arch-discovery-structcheck-{0}.txt' -f $task.id)
        [System.IO.File]::WriteAllText($structCheckTextPath, $task.implementResponse)
        # The extra args (source, community/item id) let a FAILED check also record
        # exhaustion bookkeeping against community-coverage.json/import-coverage.json --
        # see arch-discovery-structcheck.js's recordArchDiscoveryStructFailure /
        # recordArchImportStructFailure for why this exists: a structural block never
        # accumulates toward queue-watchdog.ps1's own review-rejection exhaustion stamp
        # (blockedStage is left unset here, and Test-ReviewRejection only recognizes
        # blockedStage:'review'), so without this a community/item that always fails
        # structurally gets re-selected by the rotation FOREVER. Reproduced live 2026-07-21:
        # arch-discovery-community-0 hit the exact same structural failure 3 times in under
        # an hour, its lastReviewedAt frozen since the previous day.
        $structCheckId = if ($task.source -eq 'arch_discovery') { $task.promptContext.communityId } else { $task.promptContext.itemId }
        $structCheckArgs = @($structCheckTextPath)
        if ($null -ne $structCheckId) { $structCheckArgs += @($task.source, [string]$structCheckId) }
        $structCheckRaw = & node (Join-Path $PackageSrcDir 'arch-discovery-structcheck.js') @structCheckArgs
        Remove-Item $structCheckTextPath -ErrorAction SilentlyContinue
        $structCheck = ($structCheckRaw -join "`n") | ConvertFrom-Json

        if (-not $structCheck.ok) {
            $exhaustedNote = if ($structCheck.exhausted) { ' -- community/item now marked exhausted, rotation will move on' } else { '' }
            $reason = 'Structural check failed ({0}): {1}{2}' -f $task.source, $structCheck.reason, $exhaustedNote
            Set-TaskBlockedStage -Task $task -Reason $reason
            $blockedPath = Join-Path (Join-Path $QueueDir 'blocked') $next.Name
            Write-TaskJson $blockedPath $task
            Remove-Item $draftingPath -Force
            Write-Host ('Blocked (structural check failed): {0}' -f $task.id) -ForegroundColor Yellow
            Invoke-TaskDb 'blocked' $blockedPath (@{ reason = $reason } | ConvertTo-Json -Compress)
            Write-Heartbeat -Status 'idle'
            continue
        }
    }

    $reviewPath = Join-Path (Join-Path $QueueDir 'review') $next.Name
    Write-TaskJson $reviewPath $task
    Remove-Item $draftingPath -Force
    Write-Host ('Ready for review: {0}' -f $task.id) -ForegroundColor Cyan
    Invoke-TaskDb 'ready-for-review' $reviewPath

    Write-Heartbeat -Status 'idle'

    } catch {
        # Paired with the `try` at the top of this claim's processing (see comment there).
        # Disposition the failed task instead of dying: retry via pending/ up to 3 total
        # attempts, then blocked/ with stage 'call-failure' (NOT 'review' -- must never be
        # picked up by queue-watchdog's reject-retry, which only re-queues genuine
        # review-stage rejections).
        $errMsg = $_.Exception.Message
        Write-Host ('Task failed with an unhandled error -- worker survives: {0}' -f $errMsg) -ForegroundColor Red
        try {
            if (Test-Path $draftingPath) {
                $failedTask = $null
                try { $failedTask = Read-TaskJson $draftingPath } catch { }
                if ($failedTask) {
                    $crashCount = 1
                    if ($failedTask.PSObject.Properties['callFailureCount']) { $crashCount = [int]$failedTask.callFailureCount + 1 }
                    $failedTask | Add-Member -NotePropertyName 'callFailureCount' -NotePropertyValue $crashCount -Force
                    if ($crashCount -ge 3) {
                        Set-TaskBlockedStage -Task $failedTask -Reason ('call failure x{0}, latest: {1}' -f $crashCount, $errMsg) -Stage 'call-failure'
                        $destPath = Join-Path (Join-Path $QueueDir 'blocked') $next.Name
                        Write-TaskJson $destPath $failedTask
                        Write-Host ('Blocked after {0} call failures: {1}' -f $crashCount, $failedTask.id) -ForegroundColor Yellow
                        Invoke-TaskDb 'blocked' $destPath (@{ reason = $errMsg } | ConvertTo-Json -Compress)
                    } else {
                        $destPath = Join-Path (Join-Path $QueueDir 'pending') $next.Name
                        Write-TaskJson $destPath $failedTask
                        Write-Host ('Returned to pending for attempt {0}/3: {1}' -f ($crashCount + 1), $failedTask.id) -ForegroundColor Yellow
                    }
                } else {
                    # Task JSON unreadable -- park the raw file in blocked/ rather than lose it.
                    Move-Item $draftingPath (Join-Path (Join-Path $QueueDir 'blocked') $next.Name) -Force -ErrorAction SilentlyContinue
                }
                if (Test-Path $draftingPath) { Remove-Item $draftingPath -Force -ErrorAction SilentlyContinue }
            }
        } catch {
            Write-Host ('Cleanup after task failure also failed (loop continues anyway): {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
        Write-Heartbeat -Status 'idle'
        # Brief pause so a hard-down Ollama doesn't spin this loop through back-to-back
        # 4-minute timeout cycles at maximum churn.
        Start-Sleep -Seconds 5
    }
}

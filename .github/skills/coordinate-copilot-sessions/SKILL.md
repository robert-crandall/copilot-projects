---
name: coordinate-copilot-sessions
description: >-
  Use when the user asks to spawn, launch, coordinate, or spin off top-level Copilot Projects
  sessions/tabs — either to coordinate parallel work ("do X in a new session", "spawn separate
  sessions", "open a session for each", "queue up a session per item", "do these in parallel in
  the X project") or to fork a side question/tangent into a standalone tab ("extract this into a
  new session", "spin this off into a new session / tab", "fork this tangent / side question into
  a new session", "move this side quest to a new session so we don't distract from X"). Owns two
  modes: (1) Parallel Fleet Coordination, where the opening session stays strictly read-only,
  pre-creates disjoint worktrees, staggers child launches until running, steers via
  send-session-prompt, audits diffs for bloat, and drives PRs to ready-to-merge; and (2) Spin Off
  / Fork a Tangent (--no-parent), which hands off a self-contained <=8 KB prompt to the target
  project and returns focus to the current session.
---

# Coordinate or Spin Off Copilot Projects Sessions

This skill owns **both** modes of spawning top-level **Copilot Projects** tabs (rather than internal `task` subagents):

1. **Parallel Fleet Coordination (coordinator mode):** The opening session acts as a strictly read-only **coordinator** over child sessions (`--parent-session` / default `$COPILOT_PROJECTS_SESSION`). Launching the tabs is the start of the job, not the handoff — the coordinator staggers launches, monitors progress, steers via `send-session-prompt`, audits diffs for bloat, reconciles cross-PR review threads, and drives every track to ready-to-merge without ever editing or running tests inside a child track's worktree.
2. **Spin Off / Fork a Tangent (standalone handoff mode):** When the user wants to extract a side question, tangent, or follow-up track into a separate tab so the current session stays focused on its primary topic, launch a standalone top-level tab (`--no-parent`) in the most appropriate target project with a self-contained handoff prompt (`<= 8192` bytes), wait until it reaches `running`, report the Project, Tab Title, and Session ID, and immediately return focus to the current session's main work.

## When to Use This Skill

### Parallel Fleet Coordination
- "Do X in a new session."
- "Open a session for each item in the X project."
- "Spawn separate sessions to fix these in parallel."
- "Queue up a session per tag/track so we can do this faster."
- "Orchestrate the sessions you opened to get them to green."

### Spin Off / Fork a Tangent
- "Extract this into a new session."
- "Spin this off into a new session / tab."
- "Fork this tangent / side question into a new session."
- "Move this side quest to a new session so we don't distract from X."

## Hard Rules for the Coordinator

1. **Coordinator is strictly read-only on child worktrees (both newly spawned and already-open sessions):**
   - The coordinator may pre-create disjoint worktrees (`git worktree add -b <branch> ../<repo>-<slug> "$BASE_SHA"`) before launching child sessions, and may run read-only inspection (`git status`, `git diff`, `git log`, `gh pr view`/`list`) afterward.
   - Once a child session is launched (or when attaching to already-open child tabs), **never** edit files, run builds/tests, commit, push, or launch PR-management subagents for a child track from the coordinator session.
   - Route **all** follow-up work (unstuck nudges, PR review/CI iterations, conflict resolution, bloat trimming) to the spawned session via `coordinator.py send` (`send-session-prompt`).
2. **Stagger launches sequentially — wait for `running` before opening the next:**
   - Never fire multiple `new-copilot-session` commands in parallel or in a tight loop. Booting multiple Copilot CLI + MCP server trees simultaneously overloads the machine and causes startup timeouts.
   - Always use `coordinator.py launch` or `coordinator.py launch-batch`, which launches one session and polls `list-status` until that session transitions to `running` before returning.
3. **Zero bloat / zero over-engineering gate:**
   - Bake anti-bloat rules into every child prompt (see [`references/child-prompt-template.md`](references/child-prompt-template.md)).
   - Before declaring any child PR done, inspect its full merge-base diff (`git diff <merge-base>..HEAD`) from the coordinator. If the child added speculative edge-case guards, redundant fallbacks, dead plumbing, unnecessary abstractions, or cross-track duplication, send a `send-session-prompt` to that child session instructing it what to delete/simplify and re-validate.
4. **Cross-PR contract & review-thread reconciliation (multi-PR / cross-service fleets):**
   - When sibling child sessions touch coupled layers (e.g., proxy + backend, API + UI, producer + consumer), never audit their diffs or review threads only in isolation.
   - Inspect **all review threads (including resolved/dismissed ones)** and post-review commits across every sibling PR together. If one child narrowed a contract or excluded unsafe cases in response to review feedback while a sibling child dismissed the equivalent finding (e.g., claiming "downstream enforces it") or drifted out of sync, treat that divergence as a blocking bug and steer the sibling session via `coordinator.py send` to align the contract.
5. **Drive every PR to ready-to-merge:**
   - Oversee all spawned sessions until every track's PR has passed local tests and code review, has `0` unresolved review threads, green CI, no merge conflicts (`MERGEABLE`), and is marked ready for review (`gh pr ready`, unless the user explicitly requested drafts) — or is closed cleanly if verification disproved the premise.

## Workflow

`SKILL_DIR` is the directory this `SKILL.md` was loaded from (for example `~/.copilot/skills/coordinate-copilot-sessions` or `<repo>/.github/skills/coordinate-copilot-sessions`).

### 1. Resolve target project & pre-create disjoint worktrees

Resolve the target Copilot Projects project ID (defaults to `$COPILOT_PROJECTS_PROJECT`, or looks up / creates a named project):

```bash
# Current project from $COPILOT_PROJECTS_PROJECT (or active project in list-projects):
PROJECT_ID=$(python3 "$SKILL_DIR/scripts/coordinator.py" resolve-project)

# Named project (adds --create to create it if missing):
PROJECT_ID=$(python3 "$SKILL_DIR/scripts/coordinator.py" resolve-project --name "Reliability" --create)
```

For parallel coding tracks on the same repository, **always fetch `origin` first** (never trust a cached `origin/main` or `origin/master` ref), pin `BASE_SHA` from the freshly fetched remote-tracking ref, and pre-create a separate worktree and branch (`../<repo>-<slug>`) with a **disjoint file scope** for each track so sessions never contend on the same checkout or files or build against stale signatures/flags:

```bash
git -C "$REPO_DIR" fetch --quiet origin "+refs/heads/$BASE:refs/remotes/origin/$BASE" || exit 1
BASE_SHA=$(git -C "$REPO_DIR" rev-parse --verify "refs/remotes/origin/$BASE^{commit}") || exit 1
git -C "$REPO_DIR" worktree add -b "$HEAD_BRANCH" "$WORKTREE" "$BASE_SHA" || exit 1
```

### 2. Write self-contained child prompt files (`<= 8192` bytes)

Write one UTF-8 prompt file per track in the coordinator's session `files/` directory using [`references/child-prompt-template.md`](references/child-prompt-template.md). Every child prompt must be `<= 8192` bytes and include:
- Exact worktree path, repository, base branch + `BASE_SHA`, head branch, and GitHub account (when multiple `gh` accounts are configured).
- Strict non-overlapping file scope (`ONLY modify/create these paths`).
- Premise verification check (stop without opening a PR if disproven or already fixed).
- Explicit **anti-bloat / anti-over-engineering** contract (`<= 15` net production lines when addressing review feedback; prefer deleting/simplifying over adding guards/fallbacks/abstractions).
- Mandatory validation + PR lifecycle (targeted tests/linters, local review, opening the PR, and driving it through code review, CI, and `gh pr ready`).

### 3. Stagger session launches sequentially

Launch one session at a time, waiting for each session to reach `running` in `list-status` before launching the next. When launched in the same project on a grouping-capable `copilot-projects` build, spawned child sessions automatically group under the coordinator session via `$COPILOT_PROJECTS_SESSION` (or you can pass `--parent-session <id>` / `--no-parent` explicitly; `launch` and `launch-batch` record the requested `parent_session_id` in their JSON output and fall back to launching without the flag if an older `copilot-projects` binary rejects `--parent-session` / `--no-parent`):

```bash
# Single session (blocks until session transitions to running):
python3 "$SKILL_DIR/scripts/coordinator.py" launch \
  --project "$PROJECT_ID" \
  --title "Track 1: ..." \
  --prompt-file "$SESSION_FILES/prompt-1.md"

# Or launch a batch sequentially from a JSON manifest:
python3 "$SKILL_DIR/scripts/coordinator.py" launch-batch \
  --project "$PROJECT_ID" \
  --manifest "$SESSION_FILES/launch-manifest.json"
```

`launch-manifest.json` format:
```json
[
  {
    "title": "Track 1: ...",
    "prompt_file": "/abs/path/to/prompt-1.md",
    "worktree": "/abs/path/to/repo-track-1"
  }
]
```

### 4. Monitor progress & steer child sessions via `send-session-prompt`

Check all sessions and their worktrees (read-only):

```bash
python3 "$SKILL_DIR/scripts/coordinator.py" status --project "$PROJECT_ID"
```

When a child session needs a follow-up (e.g., it went `idle` before opening/cleaning its PR, needs to address review/CI feedback, hit a merge conflict, or needs to trim bloat), send the instruction directly to that spawned session:

```bash
python3 "$SKILL_DIR/scripts/coordinator.py" send \
  --project "$PROJECT_ID" \
  --session "$CHILD_SESSION_ID" \
  --prompt "Inspect the merge-base diff, remove the redundant fallback in foo.ts, re-run tests, and push."
```

Never perform those edits or test runs in the coordinator session.

### 5. Audit child diffs for bloat, reconcile cross-PR contracts, & drive to ready-to-merge

For every child PR opened by the fleet (including PRs that are already CI-green when the coordinator attaches):
1. Inspect `git -C "$WORKTREE" diff --stat "$(git -C "$WORKTREE" merge-base "origin/$BASE" HEAD)"` and read the full diff (read-only).
2. Verify there is **no bloat or over-engineering** (no speculative config flags, unnecessary wrapper classes/helpers, regex error-message parsers where typed unwrapping works, redundant validation layers, or >15-line defensive patches for hypothetical review nitpicks). If bloat is present, use `coordinator.py send` to have the owning session simplify the diff and re-run validation.
3. **Reconcile review threads and boundary assumptions across sibling PRs:** Read all review threads (including resolved/dismissed ones) across all PRs in the batch. Verify that no child dismissed a real security, authorization, or side-effect finding by punting to a companion PR ("the downstream/upstream service handles that"), and that any contract refinement made in one PR during review is reflected consistently in its sibling PRs.
4. Confirm `0` unresolved review threads on `HEAD`, green CI, `MERGEABLE`, and `isDraft == false` (`gh pr ready`, unless drafts were requested) before reporting completion.

## Mode 2: Spin Off / Fork a Tangent (Standalone Handoff)

Use this mode when a conversation uncovers a side question, skill idea, or follow-up track and the user wants to move it into its own tab without distracting from the current session's main work.

1. **Resolve the best target project for the tangent:**
   Pick the project that matches the tangent's domain (e.g., `Skills` for skill authoring, `Reliability`, `Quality`, `Features`, or fall back to the current project if none is more specific):
   ```bash
   PROJECT_ID=$(python3 "$SKILL_DIR/scripts/coordinator.py" resolve-project --name "Skills")
   ```
2. **Write a self-contained handoff prompt (`<= 8192` UTF-8 bytes):**
   Write a prompt file in the current session's `files/` directory so the user never has to repeat context in the new tab. Include:
   - **Why it was spun off** (and the originating session ID for reference only).
   - **Existing artifacts & state** already created during the tangent (commits, worktrees, file paths, PR URLs, or links).
   - **Exact open question or remaining tasks** that the new session now owns end-to-end.
3. **Launch with `--no-parent` and hand off cleanly:**
   Pass `--no-parent` so the spun-off tangent opens as a standalone top-level tab in its target project rather than a child grouped under the unrelated originating session:
   ```bash
   python3 "$SKILL_DIR/scripts/coordinator.py" launch \
     --project "$PROJECT_ID" \
     --no-parent \
     --title "<Short Tangent Title>" \
     --prompt-file "$SESSION_FILES/handoff-prompt.md"
   ```
   Once `coordinator.py launch` returns `status: "running"`, report the **Project**, **Tab Title**, and **Session ID** to the user and immediately return the current session's focus to its primary task. Do **not** poll, coordinate, or steer the spun-off tangent from the originating session.

## Remote SSH Host & Local macOS Parity

On remote SSH hosts configured in Copilot Projects, `~/.local/bin/copilot-projects` forwards `list-projects`, `list-status`, `new-copilot-session`, `close-session`, and `new-project` over the SSH-forwarded `$COPILOT_PROJECTS_SOCKET` (falling back to the newest `~/.local/state/copilot-projects/by-session/*/control.sock`). Forwarding transports control commands; it does **not** select the child's execution host. Child sessions use the target project's default host, or the local Mac if none is set. Resolve the host containing the pre-created worktrees or handoff artifacts and pass `--host <host-id>` to `coordinator.py launch` / `launch-batch` (or set `"host": "<host-id>"` per manifest item). Only omit this option after verifying that the target project's default host is correct, and include the execution host in each child or handoff prompt.

## References

- [`references/child-prompt-template.md`](references/child-prompt-template.md) — standard `<= 8192`-byte child prompt template.
- Helper tests: `python3 -m unittest discover -s tests -p 'test_*.py'` from this skill's directory.

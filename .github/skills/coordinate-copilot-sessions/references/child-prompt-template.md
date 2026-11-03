# Child Session Prompt Template (`<= 8192` UTF-8 bytes)

Use this template when writing each child session's `--prompt-file`. Keep total size under `8,192` UTF-8 bytes (`copilot-projects new-copilot-session` hard limit).

```markdown
# Task: <Short Track Title>

## Workspace & Isolation Contract
- **Worktree path:** `<abs/path/to/repo-slug>`
- **Repository:** `<owner>/<repo>` (remote `origin`)
- **Base branch / SHA:** `<base-branch>` at `<base-sha>`
- **Head branch:** `<head-branch>`
- **GitHub account:** `<github-user>` (`export GH_TOKEN="$(gh auth token --hostname github.com --user <github-user>)"`)
- **Strict non-overlapping file scope (ONLY modify/create these paths):**
  - `<path/to/file1>`
  - `<path/to/test_file1>`
  - Do NOT touch files outside this scope (other parallel sessions own sibling files).

## Problem & Evidence
<Concise root-cause description, exact file:line citations, and reproduction/telemetry evidence.>

## Mandatory Workflow & Anti-Bloat Rules
1. **Verify premise first:** Confirm the issue still exists at `<base-sha>`. If disproven or already satisfied on `<base-sha>`, stop and report your findings without opening a PR.
2. **Lean, surgical implementation (zero bloat / zero over-engineering):**
   - Fix the root cause with the smallest behavior-preserving change.
   - Prefer deleting or simplifying code over adding new abstractions, helper layers, configuration knobs, or speculative fallback paths.
   - When addressing review findings, apply the `<= 15` net production-line rule: prefer simplifying/deleting the code that provoked the finding rather than stacking defensive guards.
   - **Never use anti-bloat or a companion PR as an excuse to dismiss real security, authorization, or side-effect findings** (e.g., do not dismiss an overbroad route/permission check with "the downstream service enforces that"). Each layer must enforce its own contract accurately and stay aligned with any companion PRs.
3. **Pre-push validation & inner loop:**
   - Run targeted tests, formatter, and linter for your touched files.
   - Run your configured local code review skills (such as `adversarial-review`) on `merge-base..HEAD` until `0` actionable findings remain.
4. **Open & drive PR to ready-to-merge:**
   - Open the PR from `<abs/path/to/repo-slug>` (using `create-pr` if installed).
   - Request code review and watch CI (using `manage-pr` if installed), address any valid review feedback without adding bloat, resolve merge conflicts with `<base-branch>` only when `mergeable == CONFLICTING` or `mergeStateStatus == DIRTY` (never merge `<base-branch>` or push non-blocking follow-ups onto an already-`APPROVED`, `MERGEABLE` PR when the repo dismisses stale approvals on push), wait for green CI, and mark the PR ready to merge (`gh pr ready`).
```

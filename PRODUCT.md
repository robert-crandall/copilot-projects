# Copilot Projects

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS.

## Stack

SwiftUI and AppKit, with the existing SwiftTerm terminal renderer. The public
desktop host and shared packages remain separate from the remote integration
and native iOS client.

## Users

People managing parallel persistent coding-agent sessions, grouped by project,
and returning to those sessions throughout the working day.

## Product Purpose

Keep work organized, make attention states understandable, and return quickly
to the right live session.

## Operating Context

The Mac workspace leads the suite. New Copilot sessions open in Conversation,
with native drafts and completed turns. Terminal is one click away for CLI
interactions and stays mounted while hidden; plain shells open in Terminal.
The Terminal session-details drawer remains available. Project navigation,
session navigation, native window controls, and keyboard speed remain central.
The Two-Level Browser separates project navigation from vertically listed
sessions, with two-line names, explicit states, and a collapsible Projects rail.
This workspace change is macOS-only; web and iOS retain their established
conversation workflows rather than reproducing Mac chrome.

## Capabilities and Constraints

Preserve persistent terminals, project/session identity, keyboard shortcuts,
drag/reorder, native labels, attention states, creation/context actions, details
access, and session-ending safeguards. Projects can be hidden from the native
View menu or session header without restarting the terminal or losing its
identity; cross-project drops require Projects to be shown. Native sends use
existing receipt-bound SDK actions and a persisted intent, not terminal input.
Control leases, queues, and shared package contracts remain unchanged.

## Brand Commitments

Keep the Copilot Projects identity and native platform conventions. The user
selected Studio Console, grounded candidate 1 from seed `207346d7`, and
authorized implementation. This was code-led, with no approved pixel comp or
generated imagery. The approved language is layered graphite in dark appearance,
satin gray in light appearance, steel selection, readable system type, and
restrained attention colors, without glow or ornamental hardware.

## Evidence on Hand

The current `StudioStyle.swift`, `Views.swift`, `AppEntry.swift`, `HostLifetime.swift`,
and `TranscriptDrawer.swift` in `Sources/CopilotProjectsHost/` define the recorded
implementation. The selected Two-Level Browser is option 3, grounded candidate 5
from surface seed `2bd5ac36`, within the unchanged Studio Console world.

The rendered finish review accepted seven native before/after captures
(`afedb70` / `3ebd069`) with matched synthetic data, sizes, appearances, and
unfocused windows. After states cover dark/light 1280x800 and compact 820x520,
including compact Projects-hidden; observed terminal widths are 822pt, 420pt,
and 539pt respectively. These are real Metal terminal screenshots, not generated
mockups. `docs/workspace.png` matches the after-dark pixels; `docs/project-status.png`
is its disclosed crop, and both carry provenance.

Palette checks and automated container/process/focus-collapse assertions are
bounded evidence, not full interaction certification. Active windows, opened
details, high-contrast runtime, real drag/keyboard use, VoiceOver, and hardware
remain unapproved. Native inactive-sidebar dimming was present in the baseline;
it is not a new regression or an app-owned styling rule.

## Product Principles

- Keep the conversation primary for Copilot and the live terminal available on demand.
- Make selection and actionable status legible without moving the workspace.
- Preserve expert speed and native controls.
- Adapt companions to their platform and established workflows.

## Accessibility & Inclusion

Respect system appearance and increased contrast, retain readable primary and
secondary text, accessible selection/status labels, distinct select/end actions,
keyboard navigation, and Reduce Motion behavior. See [DESIGN.md](DESIGN.md) for
the extracted tokens and the [surface contract](.impeccable/surfaces/sources-copilotprojectshost-views-swift.md)
for this workspace's composition.

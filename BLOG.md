# Oopla: Building a macOS AI Command Bar

> **Code vs outline notes.** The root `README.md` still describes AI as stubbed behind `MockPlanner`. The running app does not: `OoplaApp` wires `ClaudePlanner` and `VisionPlanner` with a live Anthropic API key. "Token cap" in this post means API `max_tokens` (1024 text / 2048 vision) plus conversation windows (store 20 turns, send the last 10), not a separate token-budget system. A comment in `HotkeyService` still mentions Option+Space; the real hotkey is Cmd+Shift+Space.

---

Spotlight can search. The terminal can act. Most people live stuck between those two. You know what you want done, but typing it as a shell command is not how you think, and Spotlight will not open Chrome, go to a job posting, and tailor a resume for you. Oopla sits in that gap: a floating command bar that understands plain English and either launches something immediately or plans and runs a sequence of tools.

## What it is

Hit Cmd+Shift+Space. A borderless SwiftUI window appears near the top of the screen, Spotlight-style. Type a command.

Two paths kick in. Instant local: apps, files, calculator, system settings via `LocalSearchIndex`. AI path: Claude returns a structured JSON `ActionPlan`, `SafetyEvaluator` checks it, then `ToolRegistry` executes step by step. `CommandOrchestrator` owns that routing.

## Decision 1: the confidence gate

Not every keystroke should hit an LLM. Local opens should feel instant. API calls cost money and add latency.

`shouldEscalateToClaude(query:candidates:)` in `CommandOrchestrator` makes the call. Vision queries always escalate. Multi-step markers (`and`, `then`, `after`), mutating words (`create`, `delete`, `email`), and web keywords also escalate. Everything else checks the top local candidate.

Apps only short-circuit when the normalized query (after stripping `open` / `launch`) is at least three characters and closely matches the app title. Files and folders need a score of 0.8 or higher. Otherwise Claude plans.

That three-character rule exists because of a real bug. Typing a single letter like `r` still matched Raycast in local search. The gate treated it as a high-confidence open and launched the wrong app. The fix was simple: refuse local app matches under three characters, and stop accepting `normalized.hasPrefix(title)` so a short app name cannot swallow a long natural-language query. `LocalSearchIndex.fuzzyMatch` also refuses the reverse contains check for the same reason. `buildLocalPlan` only runs when the gate is sure.

## Decision 2: giving it eyes

Some commands need the screen. "Explain what's on my screen." "Tailor my resume for this job."

`requiresVision` looks for phrases like that. When true, `VisionPlanner` takes over. `ScreenCaptureService` grabs a native-resolution frame with ScreenCaptureKit. The JPEG goes to Claude as a multimodal message alongside a tool-schema prompt. The model returns the same JSON plan shape as text-only mode.

This failed once in a boring way. Early encoding squashed screenshots hard: 1 MB cap, shrink by 25% each pass down toward 600px. Claude misread on-screen text and confidently invented names, schools, and URLs. The fix was two parts. Capture and encode at higher fidelity: CoreGraphics pixel dimensions, a 4 MB budget, and a long-edge target of 1568 instead of aggressive downscaling. And prompt rules that say only report text you can actually read; if it is blurry, say "I can't read that clearly" instead of guessing.

Small text can still fail. The model is just less willing to invent an answer now.

## Decision 3: conversation, not one-shot

Follow-ups matter. After a screen explain, "what about that diagram?" should not force a full restart.

`CommandOrchestrator` keeps a `conversation` array of `ConversationTurn`s, capped at 20. Planners receive the last 10. Vision mode stores `activeConversationScreenBase64` and reuses it unless the query asks to look again (`look again`, `now`, `current screen`). That avoids a fresh capture on every follow-up and saves tokens. Recapture is still available when the screen actually changed.

API limits stay explicit: 1024 tokens for `ClaudePlanner`, 2048 for `VisionPlanner`. Enough for a plan and an explanation, not an essay.

## Decision 4: the safety layer

Every tool declares a `SafetyLevel`: `safe`, `confirmationRequired`, or `destructive`. `SafetyEvaluator.evaluate` walks the plan and keeps the strongest level. Safe plans run. Confirmation and destructive plans land in `pendingConfirmation` until the user approves.

That covers folder creates, mail compose, and PDF export. Resume tailoring adds a content rule, not just a confirmation gate. Both planner prompts say: use only real experience from the user's resume. Never invent jobs, skills, or qualifications. `pdf_create_tool` still requires confirmation before writing `Resume_[Company].pdf` to disk.

## Architecture

```
CommandBarView
      |
CommandBarViewModel
      |
CommandOrchestrator
      |-- LocalSearchIndex          (apps, Spotlight, calc, settings)
      |-- ClaudePlanner             (text -> JSON ActionPlan)
      |-- VisionPlanner             (screenshot + text -> ActionPlan)
      |-- SafetyEvaluator           (per-tool SafetyLevel)
      |-- ToolRegistry.execute      (app launch, files, browser, PDF, ...)
      |
ExecutionView
```

`OoplaApp` builds the graph once: registry, planners, capture service, orchestrator. The window is accessory (no Dock icon), borderless, floating, dismiss-on-resign. Status bar and hotkey share the same toggle.

## What's still rough

Several tools are stubs. Move, rename, and zip return "Not yet implemented." Notes, calendar, email draft, and DND are mocked. Mail send opens `mailto:` and cannot attach files natively.

The hotkey is Cmd+Shift+Space on purpose, to avoid fighting Spotlight. You need an Anthropic API key and Screen Recording permission for vision. Input Monitoring helps the global hotkey fire while other apps are frontmost. Tiny UI text still challenges the vision path even after the resolution fix.

## How I built it

I owned the architecture and product calls: local vs AI routing, vision only when needed, conversation reuse, safety before execution, resume rules that refuse fabrication. I used AI tools heavily for Swift and SwiftUI implementation. I can walk through every decision above from the code, including the Raycast false open and the screenshot hallucination, because those failures shaped the current gates.

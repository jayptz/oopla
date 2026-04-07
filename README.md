# Oopla - AI Command Bar for macOS (MVP)

Oopla is a macOS-first command bar that combines Spotlight-like instant local search with an agent orchestration layer for natural language actions.

## Current MVP status

### Fully working now
- SwiftUI desktop app shell with a polished command bar surface.
- Keyboard-first result list with arrow navigation and enter-to-run.
- Local-first search over apps + common file roots (`Desktop`, `Documents`, `Downloads`).
- Agent planning pipeline (`query -> action plan -> safety check -> execution`).
- Safety confirmation UI for non-safe actions.
- Step-by-step execution feedback (pending/running/success/failure).
- Working tool implementations:
  - `app_launcher_tool`
  - `file_search_tool`
  - `file_open_tool`
  - `folder_create_tool`
  - `browser_open_url_tool`
  - `web_search_tool`
  - `clipboard_read_tool`
  - `clipboard_write_tool`
  - `finder_reveal_tool`

### Mocked / placeholder in MVP
- Global hotkey is implemented as `Cmd + Shift + Space` monitor placeholder.
  - (Production-grade `Cmd + Space` replacement should use a robust hotkey registration path and conflict handling.)
- AI provider integration is stubbed behind protocols.
  - `MockPlanner` handles intent heuristics with deterministic parsing.
  - `StubAIProvider` marks where real LLM calls should plug in.
- Calendar, email, notes, DND, move/rename/zip are scaffolded tools with placeholder behavior.

## Architecture

The codebase is organized for modularity and future expansion:

- `App`
  - App bootstrap + root state.
- `Features/CommandBar`
  - Command bar UI and input handling view model.
- `Features/Execution`
  - Execution timeline/status rendering.
- `Features/Settings`
  - Settings panels for provider, shortcut, behavior, and permissions.
- `Core/Models`
  - Action plan, tool call, search result, execution state models.
- `Core/Protocols`
  - Testable interfaces for planner, search, tools, and AI provider.
- `Core/Services`
  - Orchestration, settings, hotkey service.
- `Core/Tools`
  - Tool registry + concrete tool implementations.
- `Core/AI`
  - Mock planner and provider abstraction.
- `Core/Search`
  - Local indexing and ranked retrieval.
- `Core/Safety`
  - Safety evaluator and confirmation policy.
- `Resources/Prompts`
  - Prompt templates and schema guidance.
- `Resources/Mocks`
  - Demo seed content.

## Data flow

1. User triggers command bar and types natural language.
2. `LocalSearchIndex` returns instant local suggestions.
3. `CommandOrchestrator` asks planner for an `ActionPlan`.
4. `SafetyEvaluator` classifies plan risk.
5. Safe actions run immediately, risky actions open confirmation sheet.
6. Tool calls execute through `ToolRegistry`.
7. `ExecutionView` streams progress and result messages.

## Build and run

Open in Xcode and run the `Oopla` executable target.

Or from terminal:

```bash
swift run
```

## Near-term roadmap

1. Replace `MockPlanner` with real LLM planner using strict JSON schema validation.
2. Add robust global hotkey registration and customizable key mapping persistence.
3. Expand index sources: recent docs, contacts, browser history, metadata ranking.
4. Implement real integrations for Calendar, Mail, Notes, and DND.
5. Add richer plan preview cards and retry/edit controls.
6. Add unit tests for planner parsing, safety policy, and tool execution.
7. Add permission diagnostics and onboarding flow.

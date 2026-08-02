# Pane ownership and lifecycle

Pane uses direct ownership rather than a general coordinator or event bus. The
following tree is the authoritative lifetime hierarchy:

```text
TerminalWorkspaceController
  └── owns TerminalTab[]
        └── each tab owns TerminalSession
              ├── owns PTYController
              ├── owns CompletionService
              ├── owns BlockLifecycleController
              ├── owns TerminalInteractionController
              └── coordinates FocusCoordinator
```

## State ownership

| Owner | Authoritative state | Derived, cached, or presentation state elsewhere |
| --- | --- | --- |
| `TerminalWorkspaceController` | Tab collection, selected tab ID, tab order, close decisions, and workspace restoration | Views derive selected-tab presentation and only dispatch workspace commands. |
| `TerminalSession` | Shell readiness, PTY generation, current directory, foreground process, secure-input state, alternate-screen state, session visibility, and the session's completion generation | Interaction and view state may present these values but cannot replace their shell/PTY truth. |
| `TerminalInteractionController` | Legal interaction-state transitions | It derives transitions from session facts and does not own shell readiness, secure input, or PTY state. |
| `BlockLifecycleController` | Active-block creation and finalization transitions | The session publishes the resulting timeline and selection presentation. |
| `FocusCoordinator` | Focus request generation and stale-request rejection | Terminal/composer focus targets are transient presentation effects. |
| `CompletionService` | One active completion request, its request generation, provider work, cancellation, and publication | `CompletionPipeline` is an immutable processor; suggestions carry canonical result IDs rather than owning identity. |
| `ProjectContextProvider` / `ComposerContextCoordinator` | Project discovery and Git caches | Sessions retain only prepared context needed for presentation and request construction. |

Fields that mirror authoritative state must have one of three explicit roles:
**derived** (recomputed from the owner), **cached** (invalidated by the owner), or
**presentation-only** (ephemeral UI state). A second mutable source of truth is
not permitted.

## Shutdown and cancellation

The workspace initiates application and bulk-tab shutdown. Closing a tab asks
its `TerminalSession` to shut down before releasing it. The session stops new
input, invalidates request generations, cancels session-owned work, awaits work
whose cleanup affects process or resource convergence, and finally terminates
its PTY. `CompletionService` owns and cancels its provider task group; stream
termination is a secondary cancellation path, not the primary lifecycle.

Session-owned task properties use responsibility-specific names. Required
cleanup follows `task?.cancel(); await task?.value; task = nil`. UI-only delay
tasks may be cancelled without awaiting when their cancellation has no resource
or process side effect.

## Restart and persistence boundaries

Shell restart preserves session identity, tab metadata, block history, and the
workspace selection/order. It replaces PTY generation and shell-derived facts,
and invalidates autocomplete and project-context generations. Workspace
snapshots contain workspace-global tab ordering/selection and the documented
restorable session state; live PTY state, focus requests, provider tasks, secure
input, and transient completion suggestions never survive restoration.

## Terminal view authority

`TerminalSession` owns the authoritative terminal model and PTY relationship.
`TerminalViewRepresentable` may mount that view, propagate size, bridge focus,
and forward coordinator callbacks. SwiftUI workspace and composer views may not
write terminal state, mutate the tab array, perform project discovery, or run
autocomplete orchestration directly.

## P2.2 cleanup metrics

The audit baseline is `b93766d`. Metrics are structural signals, not substitutes
for behavioral verification.

| Metric | Baseline | Current checkpoint |
| --- | ---: | ---: |
| Largest production file | `TerminalSession.swift`, 2,752 lines | `TerminalSession.swift`, 2,390 lines |
| Largest test file | `TerminalSessionIntegrationTests.swift`, 2,176 lines | `TerminalSessionIntegrationTests.swift`, 2,193 lines |
| Mixed autocomplete test file | 1,353 lines | 112-line shared spine; largest extracted responsibility is 381 lines |
| Request-less production ranking APIs/callers | 1 API and 1 caller | 0 |
| Completion source-conversion boundaries | Repeated switches across services and session feedback | 1 centralized mapping type |
| Lifecycle `DEBUG` print call sites | 10 | 10; structured diagnostics migration remains pending |
| Long-lived task properties | 8 | 8; completion ownership is now named `completionRequestTask` |

The current checkpoint has extracted autocomplete and lifecycle behavior into
cross-file `TerminalSession` extensions. Stored state remains in the main class;
the remaining block, focus, search, and diagnostics extractions are intentionally
tracked separately so each can pass its subsystem tests before the next move.

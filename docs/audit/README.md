# Fork audit and implementation record

The starting point is upstream commit `c17422457027c913c76c75a921fca1e623d2678e`. The implementation branch is `codex-and-audit` in [FilipJaskovic/99](https://github.com/FilipJaskovic/99).

## Scope

Filip requested a maintained personal fork that uses Codex, research into the appropriate integration, and a deep code audit by GPT-6.1 Sol subagents. Seven Sol agents independently investigated the existing code and integration choices. Their reports below distinguish reproduced baseline failures from follow-up fixes. Duplicate findings across reports are not separate defects.

The implementation uses native `codex exec`, prompt input over stdin, and the CLI's final-message output file. Codex is the default provider. Existing Codex authentication and model configuration remain usable without an SDK bridge or a new API key. The provider supports non-Git folders.

The safety requirements derived from the audit are that cancelled requests cannot apply late results, request output remains bound to its original project, and stale visual results cannot replace changed text. Context references must honor disable and exclusion options, resolve exact filenames, and remain inside the intended project. Reconfiguration and closed buffers must release resources without losing cancellation of other requests.

This work changes the fork checkout. It does not install the fork, change Filip's Neovim configuration, or edit his notes.

## Reports and resolutions

| Report | Implemented changes |
| --- | --- |
| [Codex research](../codex-integration-research.md) | CLI integration, existing login, optional model, operation-specific sandbox, guarded advanced arguments, provider-aware output prompts |
| [Process handling](process.md) | Terminal callback guards, captured cwd/provider/options, exclusive private output directories, cleanup, deadlines, bounded output, spawn errors, signal escalation, atomic persistence |
| [Visual edit safety](edit-safety.md) | Exact character and line bounds, UTF-8 endpoints, explicit block-selection rejection, creation-time snapshot, conflict detection, safe cleanup, visible failed application |
| [Context discovery](context.md) | Realpath confinement, literal exclusions, disabled references, exact paths, NUL-delimited Git output, quoted names, refreshed and request-scoped references, bounded rule reads |
| [UI and state](ui-state.md) | Timer and buffer cleanup, callbacks once, scoped worker persistence, tutorial history handles, strict quickfix parsing |
| [Tests and compatibility](tests.md) | macOS paths, real filesystem fixtures, Neovim 0.11.5 Linux/macOS CI, documented-setup evaluation, generated-document checks |
| [Public API](api.md) | Provider/model snapshots, reusable caller options, stale picker results, native completion scope and timers, repeated cmp setup, corrected API documentation |

Root-level fixes also stop old requests and status loops during setup, isolate each stop-all cleanup, and bind the history directory to the cwd at setup. The unsupported `auto_add_skills` annotation was removed. The logger bounds retained bytes per request. Core extension setup applies file-reference policy even if an optional completion adapter cannot load.

## Validation

The baseline had 103 passing tests and two failures: obsolete Cursor flags and macOS path canonicalization. Both are resolved. The combined branch passes all 205 tests on macOS with both Neovim 0.11.5 and Neovim 0.13.0-dev. `make pr_ready docs_check` passes on the installed build, including lint, formatting, documented-setup evaluation, and both generated README checks. `make lua_test docs_smoke` passes with the isolated 0.11.5 release. Logs are `/tmp/99-review-fix.log` and `/tmp/99-installed-final.log`.

A live Codex CLI 0.164.0 test used a disposable non-Git folder and synthetic text. Visual replacement changed exactly the selected first line, preserved the following line, and did not write the source file on disk. It used the existing ChatGPT login with `--ignore-user-config` to isolate the smoke test from custom tools and instructions. Ordinary plugin use preserves Codex configuration.

## Independent final review

Two fresh GPT-6.1 Sol agents reviewed the combined diff after implementation.

| Axis | Result |
| --- | --- |
| [Standards and regressions](final-standards.md) | No actionable findings. The reviewer independently ran 21 process and worker tests. |
| [Spec](final-spec.md) | One reproduced P2 finding: a missing completion adapter could retain old file-reference policy. Core setup now owns that policy. The reviewer reran the reproduction with the expected result inverted and verified all seven adapter tests. No unresolved findings remain in this review. |

The first macOS CI run exposed an existing status-window test's fixed 20 ms timing assumption. It now uses bounded condition waits. Both Linux and macOS CI passed that correction before the final adapter-policy fix was submitted. CI checks on the pull request are the source of truth for its latest commit.

## Remaining limits

- Visual conflict detection rejects any source-buffer change after capture, including edits outside the selection. Rejected response text is available in bounded request logs. Block selections are unsupported.
- Codex's default sandboxes are `read-only` for visual, search, and tutorial requests, and `workspace-write` for vibe. Explicit advanced arguments can override them. Configured MCP servers and external tools have their own permissions.
- Cancellation supervises the CLI process. It does not guarantee termination of every detached descendant. Cancelling a vibe request does not undo changes it already made.
- File discovery is synchronous and buffers Git's path output. It refreshes per request, without filesystem watches. Individual reads are bounded, but there is no aggregate byte budget for all explicit file and rule references.
- Successful history and diagnostic logs can retain sensitive content. Per-request temporary files are removed. Existing files left by the upstream implementation are not removed retrospectively.
- Atomic persistence avoids partially replaced files. It does not merge simultaneous writes from separate Neovim instances or promise crash durability through `fsync`.
- The local compatibility checks cover macOS. Linux CI is configured separately. Windows quickfix parsing is tested, but full Windows operation is not validated.
- Codex model discovery currently offers the CLI default. Select another model explicitly with `model` or `set_model`. App-server is the documented future option for account-aware model lists and interactive approvals.

These checks establish specific behavior. They are not a claim that the fork has no remaining defects.

# Provider and request lifecycle audit

Reviewed baseline `c17422457027c913c76c75a921fca1e623d2678e` on `codex-and-audit`. Source references in the findings use that revision. This report covers `providers.lua`, `prompt.lua`, `state/tracking.lua`, and request completion and cleanup.

All baseline reproductions used headless Neovim, local shell processes, and files under `/tmp/99-process-audit`. No model calls, installed configuration changes, or user-note changes were made by this owner. The historical reproduction is `/tmp/99-process-audit/repro.lua`. It points at the checkout, so restoring the baseline or pointing it at a baseline archive is necessary to reproduce the original failures:

```sh
nvim --headless -u NONE -i NONE -l /tmp/99-process-audit/repro.lua
```

## Implementation status

All seven findings below are addressed in the working branch. No commits or pushes were made by this owner.

- Request completion is guarded in both the base provider and `Prompt`. Cancellation completes immediately and suppresses late success and output, including custom-provider callbacks. Cleanup runs once and continues after a broken mark or callback.
- Request paths use exclusively reserved `fs_mkdtemp` directories with mode `0700`. Finalization is idempotent. Stop removes ephemeral output, and process exit retries removal if needed. Debug prompts remain in memory rather than separate files on disk.
- Context creation snapshots the canonical cwd, refreshed rules, provider, and extra args. Spawn uses that cwd and response paths are absolute. `Prompt.visual` captures the visual snapshot before prompt input opens.
- Synchronous builder, spawn, and setup failures produce a failed terminal result and notification. Completion-handler errors also produce failure and still clean up.
- Requests have a configured deadline, with a local fallback of 300,000 ms. They bound combined stdout and stderr, and final response files, with a local fallback of 4 MiB. Fast-event output is checked before scheduled delivery and coalesced. Stream log records contain byte totals, rather than full chunks. Diagnostics retain at most 8 KiB of stderr.
- Cancellation retains the process handle until exit. Normal providers receive TERM followed by KILL after 250 ms. Codex's signal override receives INT, TERM after 250 ms, then KILL after another 250 ms. A real TERM-resistant child is killed and reaped by the regression suite.
- Missing, blank, oversized, and non-regular final-response files fail. `response_mode = "stdout"` changes prompt instructions to request a final answer. Extraction still reads the CLI's final-message output file, including Codex's `--output-last-message` path.
- Claude, Cursor, and Kiro no longer receive automatic permission-bypass flags. Advanced opt-in arguments remain available. Gemini retains its documented `auto_edit` mode.

Related handoffs are also implemented. C10 in `context.md` now uses directory boundaries, realpath confinement, and a 256 KiB aggregate budget for automatic Markdown context. Deserialized tutorials drop session-local buffer and window handles. JSON persistence encodes before opening a file and uses the shared `Utils.write_file_atomic(path, contents)` helper, which creates the parent, closes its private temporary file, and renames it over the destination.

The process layer guarantees supervision of the spawned CLI only. It does not create or terminate a process group. Detached descendants and descendants that inherit pipes can outlive the CLI or delay its exit callback. A model's filesystem permissions are controlled by its CLI sandbox, not by prompt text. Existing files left by the baseline are not deleted retrospectively. Atomic persistence protects against partial replacement, but does not provide crash durability through `fsync` or merge simultaneous writes by separate Neovim instances.

Final focused validation used isolated scratch copies of the suites with no user init. All 48 tests across `lifecycle_spec.lua`, `providers_spec.lua`, `request_spec.lua`, `prompt_spec.lua`, `tracking_spec.lua`, and the Codex owner's `codex_spec.lua` passed. The 15 new lifecycle cases include the real resistant child, callback order, spawn errors, deadlines, stream bounds, snapshots, private paths, Markdown confinement, tutorial handles, and immediate persistence. The worker owner's suite passed five cases and failed its trailing-newline expectation in the reconfiguration case. That handoff is outside this owner's files. Logs are at `/tmp/99-process-final/results.log`.

Owned source and test files pass luacheck, StyLua, and `git diff --check`. Source is frozen for the parent's aggregate and minimum-Neovim checks.

## Verified findings

### P1: Cancelling between exit and response retrieval still delivers success

`lua/99/providers.lua:111-137` checks cancellation in the exit callback, then schedules response retrieval separately. The scheduled function does not check cancellation. `lua/99/prompt.lua:248-251` accepts the later success and overwrites `cancelled`.

When cancellation runs between those scheduled callbacks, an operation can apply a response after the user cancels it. The visual success handler at `lua/99/ops/over-range.lua:66-90` is one affected consumer. The provider's `once` wrapper prevents two callbacks, but does not prevent the wrong terminal result.

The reproduction queues a successful exit, cancellation, and retrieval in that order. The final state is `success`, with one `success` completion containing `LATE_SUCCESS`.

Focused regression: control the scheduler so that cancellation runs after the exit callback and before retrieval. Assert one `cancelled` completion, no response application, and one cleanup. Check cancellation again at the final delivery point.

### P1: Shared random output filenames can replace another request's response

`lua/99/utils.lua:32-34` chooses among only 10,000 filenames. `lua/99/prompt.lua:97` uses that name without reserving it. `lua/99/prompt.lua:456-461` then opens both files with `w`, which truncates existing files.

Concurrent requests or separate Neovim instances in the same project can share an output path. Starting the second request can erase the first response. A later write can cause both requests to read the second response and apply it to different selections. Completed request files also remain in that namespace.

With `math.randomseed(42)`, independently created contexts first collided after 144 contexts at `99-3893`. Preparing the second context erased `FIRST_RESPONSE`. Retrieving the first context then returned `SECOND_RESPONSE`.

Focused regression: force identical random values and create two requests in the same configured directory. Their exclusively reserved output paths must differ. Writing or cleaning one must leave the other intact. Use an exclusive file or per-request directory allocation rather than a larger random number alone.

### P1: Changing cwd can make a request read an unrelated project's output

`lua/99/state.lua:53-60` preserves relative `tmp_dir` paths, including the default `./tmp`. `lua/99/prompt.lua:97` stores the relative response path. `lua/99/providers.lua:35-36` resolves that path again at completion, against the editor's current cwd. The spawn options at `lua/99/providers.lua:80-110` also do not capture an explicit cwd.

Start a request in project A and change Neovim's cwd to B before it finishes. The child writes into A, while response retrieval reads B. A missing file causes failure. An existing matching file causes successful delivery of unrelated output. Changing cwd while the prompt-input window is open can also start the child in a different project than the source selection.

The reproduction launches a child that writes `RESPONSE_FROM_A` into A, plants a matching path in B, and changes cwd. Completion returns `success` with `UNRELATED_RESPONSE_FROM_B`; A's correct response remains unread.

Focused regression: start in A, change cwd to B during the request, and assert that the child cwd, prompt location, retrieval, and cleanup all remain bound to A. Snapshot the request cwd and normalize request paths to absolute paths when the context is created.

### P1: Spawn errors leave requests permanently active and skip cleanup

`lua/99/providers.lua:60` calls `on_start` before command construction and `vim.system`. `lua/99/prompt.lua:240-242` sets `requesting` and adds the context to tracking. Neither `lua/99/providers.lua:73-80` nor `lua/99/prompt.lua:304` catches synchronous command or spawn errors.

A missing executable, invalid spawn argument, or failing command builder raises out of the operation without `on_complete`. The active request and visual status timers remain until manual cancellation. There is no process handle to terminate.

Launching `/tmp/99-process-audit/DOES-NOT-EXIST` produced `ENOENT`, with state `requesting`, active count `1`, completion count `0`, and cleanup count `0`.

Focused regression: use a nonexistent executable and a throwing command builder. Assert one failed completion, zero active requests, stopped status timers, and one cleanup. Route synchronous setup failures through the same terminal path as asynchronous exit failures.

### P2: Cancellation abandons children that ignore SIGTERM

`lua/99/prompt.lua:326-336` sets `cancelled`, clears `_proc`, and sends one SIGTERM. There is no escalation or retained process handle. `lua/99/state/tracking.lua:85-101` then excludes the request from active tracking, so subsequent `stop_all_requests` calls cannot retry termination.

A hung CLI or tool that ignores SIGTERM continues running after cancellation and disappears from the active list. With no further output, `on_complete` never runs. The documented cancellation behavior at `README.md:186-188` promises to kill the underlying process.

The reproduction starts a shell that ignores TERM and executes `sleep 30`. After `stop()`, the PID is alive, `_proc` is nil, active count is `0`, and completion count is `0`. The reproduction explicitly sends SIGKILL afterward and waits for exit.

Focused regression: start a TERM-resistant local child, cancel, and assert bounded termination, one cancelled completion, and one cleanup. Keep the process handle through termination and use a bounded escalation. Process-tree termination also needs an explicit design because these CLIs launch tools.

### P2: Streaming output is retained without a byte limit in the default logger

`lua/99/providers.lua:84-98` logs every stdout and stderr chunk. The default logger is DEBUG at `lua/99/logger/logger.lua:384`. `lua/99/logger/logger.lua:224-260` limits the number of requests, while retaining every serialized log line within each request. Even a void sink retains these strings.

A noisy or stuck child can grow Neovim memory without a bound. The bounded status-line queue does not bound these logs. Captured response files are also read in full at `lua/99/providers.lua:35-50`.

The reproduction streams 4,194,304 stdout bytes into an observer that discards them. The logger still retains 4,213,981 bytes across 259 entries for that request.

Focused regression: send more than the chosen byte limit on stdout and stderr and assert bounded retained log bytes and a truncation marker. Include a response-file size limit if output files remain the transport.

### P2: A CLI that exits without producing a response is reported as successful

`lua/99/prompt.lua:456-461` creates an empty response file before spawning. `lua/99/providers.lua:128-135` treats a readable file as sufficient for success. A zero-exit child that ignores the output-file instruction therefore returns success with empty text.

This hides missing output, such as a CLI that prints its answer only to stdout. Search reports no results, tutorials can be empty, and the request is persisted as successful. The visual handler separately avoids applying blank output at `lua/99/ops/over-range.lua:76-79`, but the request still becomes successful.

The reproduction uses `/usr/bin/true`, which writes nothing. Completion returns `success` with `text = ""`.

Focused regression: use a zero-exit child that produces no output. Require a failed completion with a useful missing-response error. Define explicitly whether an intentionally empty response is supported. A native final-message output file can remove reliance on a model obeying file-writing instructions.

## Other verified behavior and limits

- There is no request deadline in the `vim.system` options at `lua/99/providers.lua:80-110`, or a watchdog in `Prompt:start_request`. A silent hung child remains `requesting` indefinitely until cancellation. A deadline test can use a sleeping local child and a short configured timeout.
- The provider commands bypass normal permission checks for Claude with `--dangerously-skip-permissions` at `lua/99/providers.lua:195`, Cursor with `--trust --force` at lines 242-243, and Kiro with `--trust-all-tools` at line 295. Gemini uses `auto_edit` at lines 319-322. The temp-file-only promise for visual, tutorial, and search requests is prompt text at `lua/99/prompt.lua:505-510`; the process layer does not enforce a filesystem boundary. These are verified command defaults, not a claim that an external CLI escaped its sandbox. A Codex provider should set an explicit operation-specific sandbox and approval policy.
- Prompt and response files survive success, failure, cancellation, and history clearing. `Prompt:stop` at `lua/99/prompt.lua:376-382` clears marks and registered callbacks. No file cleanup is registered by the request layer. `Tracking:clear_history` at `lua/99/state/tracking.lua:66-75` only drops references. Prompt files include code context and user input. Retention needs an explicit policy, especially before using a shared temp directory.
- `CleanUp.make_observer` at `lua/99/ops/clean-up.lua:25-30` discards completion-handler errors with `pcall`. A response application failure can leave a request marked successful without reporting the failure. Cleanup itself is scheduled afterward and is not guarded against throwing cleanup callbacks.
- The existing base provider guards `on_complete` with `once`. The cancellation race above is a wrong-result bug, rather than evidence of a duplicate completion in that provider. Custom providers do not get an equivalent request-level guard in `Prompt:_observer`.

## Existing test coverage

Ran isolated scratch copies of `providers_spec.lua`, `request_spec.lua`, `prompt_spec.lua`, and `tracking_spec.lua` with the installed Plenary runtime and no user init. Results were 20 passed, 1 failed. The existing Cursor command test at `lua/99/test/providers_spec.lua:55-61` expects no `--trust --force`, while the implementation includes both flags. This failure predates this audit.

The request tests use `99.test.test_utils.TestProvider`, which replaces `make_request` and never exercises `vim.system`. The existing cancellation test resolves that fake provider after cancellation. It does not cover spawn errors, queued response retrieval, resistant subprocesses, filename collisions, cwd changes, or output bounds.

The scratch reproductions above exercise the actual base provider and prompt code. Only the cancellation race substitutes `vim.system`, to control the exit callback order deterministically. The child-process cases use `/bin/sh`, `/bin/sleep`, `/usr/bin/true`, and local byte-generation commands.

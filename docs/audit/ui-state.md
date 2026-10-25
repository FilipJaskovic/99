# UI and state audit

Reviewed branch `codex-and-audit` at baseline `c17422457027c913c76c75a921fca1e623d2678e`. Scope includes `window/*`, request status and throbber timers, state persistence, the worker, quickfix parsing, and search, vibe, and tutorial workflows.

All reproductions ran in separate headless Neovim processes with `-u NONE -i NONE`. Scratch data and scripts are under `/tmp/99-ui-state-audit`. Tests use `99.test.test_utils.TestProvider`; no model calls, installed configuration changes, or real notes were involved. The installed executable reports Neovim `v0.13.0-dev-1375+g8e0e19c08b`.

## Resolution status

The findings below preserve the original baseline evidence and source locations. Implementation is complete in the shared working tree, with no commits from this agent.

- Finding 1 is resolved jointly. `RequestStatus` stops when its mark is invalid, releases its timer, and ignores queued callbacks from a previous run. The edit owner made mark cleanup tolerate deleted buffers, and root isolates failures while cancelling requests. The original reproduction now reports successful cancellation, both status objects stopped, the later request cancelled, and an empty error message.
- Finding 2 is resolved by root's retained status-window handle and setup lifecycle changes, together with the synchronous, idempotent `StatusWindow:stop()` implemented here. The original reconfiguration reproduction now reports zero old active requests and a cancelled old prompt. Stop also works when disabled or already stopped.
- Finding 3 is resolved by the process owner's removal of tutorial handles during deserialization and root's update of the live handles after reopening. The two-process reproduction now displays the saved tutorial and preserves the unrelated scratch buffer's `lua` filetype. `ops/tutorial.lua` required no change.
- Finding 4 is resolved by the process owner's `utils.write_file_atomic()`, also used by JSON persistence. The original reproduction now reads the expected 35-byte JSON immediately after sync, before garbage collection.
- Findings 5 and 6 are resolved in the worker. Its cache follows the absolute work-file path. Prompts capture their save destination, so switching projects cannot redirect an older prompt's save. The worker uses the shared atomic writer, which creates missing parents, and changes its cached task only after a successful save. Loading preserves the task text verbatim, including final newlines.
- Finding 7 is resolved by wiping owned floating buffers on hide and cleaning buffer and window handles independently. Window creation also deletes the scratch buffer when opening the float fails.
- Finding 8 is resolved by matching numeric location fields after the filename, preserving colon-containing paths, and rejecting malformed or out-of-range positive integers. The regression includes the exact Windows drive-path case and location-like text inside notes.
- All three additional lifecycle defects are resolved. Prompt submission, cancellation, and selection share one settlement function. Settlement removes the prompt augroup, closes its windows, and calls the callback once. Deferred setup checks that the prompt is still active and runs in its captured window. Popup cleanup detaches the old window list before closing, so a callback can open a replacement prompt safely.

Focused validation covered 30 passing tests across `window_spec.lua`, `qfix_helpers_spec.lua`, `ui_timers_spec.lua`, `worker_spec.lua`, `in_flight_spec.lua`, `request_status_spec.lua`, and `throbber_spec.lua`. The window, timer, and worker regressions failed on the original behavior before the fixes. Quickfix tests cover the Windows and colon-path failures established by the audit reproductions. The worker cache fixture uses binary `writefile` mode to express its intended exact contents without an implicit final newline. StyLua 2.5.2 checks pass, and LuaCheck reports zero warnings or errors for all 11 owned source and test files. `git diff --check` also passes for the owned paths.

No verified finding in this report is deferred. Root and the test owner handle aggregate repository validation. Native completion belongs to the API owner and was not changed here. All provider behavior in this work remains controlled by the test provider.

## Findings

### 1. P1: Wiping a visual request's buffer breaks cancellation of other requests

Locations: `lua/99/ops/request_status.lua:84-91`, `lua/99/ops/marks.lua:123-124,149-150`, `lua/99/prompt.lua:376-382`, and `lua/99/state/tracking.lua:78-81`.

Start a visual request, start a second request, wipe the visual buffer, and call `stop_all_requests()`. `Prompt:stop()` cancels the visual request, then `clear_marks()` throws `Invalid buffer id` before executing its cleanup callbacks. The exception also exits the loop over active requests, leaving the second request in `requesting` state. The visual request's two `RequestStatus` objects retain `running = true`. Their next ticks each throw while updating the deleted buffer.

Verified with `request-status-buffer.lua`: cancellation returned `false`, both status objects remained running, and the second request remained `requesting`. A real later provider process would therefore miss the cancellation attempt.

Focused regression: run two controlled requests, wipe the first buffer, and cancel all. Assert that every request receives cancellation, both status timers stop, and no scheduled callback raises. Cleanup must tolerate missing marks and buffers without preventing the remaining cleanup or cancellations.

### 2. P1: Reconfiguration loses the ability to cancel existing requests

Locations: `lua/99/init.lua:411-414,423-428,466-467`, `lua/99/init.lua:396-397`, and `lua/99/window/status-window.lua:66-73`.

Calling `setup()` while a request runs replaces `_99_state` without stopping the previous state's requests or status loop. `stop_all_requests()` subsequently visits only the new state. The old `StatusWindow` keeps its state reachable through its recurring closure, and `setup()` retains no handle with which to stop that loop. Exit callbacks also reference the new global state.

Verified with `reconfigure.lua`: after setup, request start, setup again, and cancellation, the old state still had one active request. The new state had zero, and the old prompt reported `is_cancelled() == false`. Timer scheduling continued. This matters for providers that can edit files after reconfiguration.

Focused regression: reconfigure with a controlled request in flight. Assert that the previous request is cancelled and its status loop stops, or that the request remains tracked and cancellable by the current state.

### 3. P2: Tutorial history reuses buffer IDs from a previous Neovim session

Locations: `lua/99/ops/tutorial.lua:15-22`, `lua/99/prompt.lua:114-136`, `lua/99/init.lua:288-295`, and `lua/99/window/init.lua:712-725`.

Tutorial data persists its numeric `buffer` handle. On restart, that number can identify a different buffer. `create_split()` accepts any valid buffer with that number, skips the saved tutorial content, and sets the unrelated buffer's filetype to `markdown`.

Verified across two real processes with `tutorial-save.lua` and `tutorial-restore.lua`. The first saved tutorial buffer 2. The second allocated buffer 2 for scratch Lua notes before loading history. Opening the restored tutorial displayed `local scratch_note = true`, while the persisted tutorial contained `# Tutorial`. The scratch buffer's filetype changed from `lua` to `markdown`.

Focused regression: deserialize a tutorial whose saved buffer number now belongs to another buffer. Opening it must show the saved tutorial and preserve the unrelated buffer's content and options. Persist tutorial content without session-local handles, or discard those handles during deserialization.

### 4. P2: State synchronization leaves its output buffered and its file handle open

Locations: `lua/99/state.lua:92-96` and `lua/99/utils.lua:62-75`.

`State:sync()` delegates to `write_file_json_safe()`, which opens with `"w"` and writes without closing or flushing the handle. A small state file remains truncated to zero bytes after synchronization returns. Reloading the state before garbage collection therefore loses the saved history. Repeated calls also retain open handles until garbage collection. The JSON encoding failure path leaves its handle open as well.

Verified with `persistence.lua`, with garbage collection paused to make the timing deterministic. Immediately after `sync()`, `99-state` had zero bytes and decoded as `nil`. An explicit garbage collection changed it to 35 bytes containing the expected JSON.

Focused regression: synchronize and immediately read or reconstruct the state, without forcing garbage collection. Assert that the written JSON matches the serialized state. Close the handle on both the success and failure paths.

### 5. P2: The worker caches another project's task and can overwrite the new project's work file

Locations: `lua/99/extensions/work/worker.lua:30-34,55-59,64-73,131-155`.

`M.current_work_item` is global to the module, while the persistence filename comes from the current state each time. After loading project A's task and configuring project B, hydration skips B's file because the cache is populated. `Worker.search()` and `Worker.vibe()` consequently build prompts containing A's task. Editing the preloaded task writes it into B's work file.

Verified with `workflows.lua` and separate scratch directories. B's controlled request contained `Project A secret task` and omitted the persisted `Project B task`. `update_work()` preloaded A's task, then replaced B's work file with the edited result.

Focused regression: switch between two configured temporary directories with distinct work files. Assert that each prompt and save uses the task for the active directory. Scope the cache to a resolved work-file path or reset it when the state changes.

### 6. P2: Saving the first work item fails when the temporary directory does not exist

Locations: `lua/99/extensions/work/worker.lua:64-75` and `lua/99/state.lua:52-60`.

A fresh project normally has no `./tmp` directory. `setup()` does not create it, and the worker opens `99-work-item` without creating its parent directory. Calling `set_work({ description = ... })` therefore raises `unable to save work item`. The interactive save closes the prompt before reaching the same error. The in-memory task is already updated even though persistence fails.

Verified with `persistence.lua` against an absent scratch directory: setup succeeded, the first worker save failed, and no work file existed. Existing worker tests create the directory in `before_each`, so they miss this path.

Focused regression: configure a nonexistent temporary directory, save the first work item, and reconstruct the worker's state from disk. Assert that the description survives.

### 7. P2: Manually closing status windows leaks loaded buffers

Locations: `lua/99/window/init.lua:151-162,646-654,669-673` and `lua/99/window/status-window.lua:75-78`.

Floating status buffers have no `bufhidden=wipe` setting. When a user closes a status window directly, `Window.close()` returns because the window is invalid, even though its buffer remains valid. `refresh_active_windows()` then drops the record. A running request recreates the status window, so each manual close can leave another loaded buffer behind.

Verified with `lifecycle.lua`: three status window closures increased the buffer count from one to four. All three discarded status buffers remained valid and loaded after `close()` and refresh.

Focused regression: close the status window through the Neovim API while a controlled request runs, allow recreation, and finish the request. Assert that every status buffer has been deleted and the buffer count returns to its starting value. Cleanup must handle window and buffer validity independently.

### 8. P2: Quickfix parsing sends valid colon-containing filenames to the wrong location

Location: `lua/99/ops/qfix-helpers.lua:5-16`.

The parser treats the first colon as the filename delimiter, then silently converts invalid coordinates to 1. A valid POSIX filename containing a colon is consequently parsed into a different filename and bogus coordinates. Windows drive-qualified paths have the same delimiter problem, even when the response follows the requested format.

Verified with `lifecycle.lua`: `/tmp/name:part.lua:42:7,1,note` became filename `/tmp/name`, line 1, column 1. Independently verified with `windows-qfix.lua`: `C:\vault\note.md:24:8,3,hello` became filename `C`, line 1, column 1, and text `hello`. The search and vibe workflows use these entries directly. The parser also accepts line 0 and negative columns, and Lua's `tonumber("NaN")` produces a non-finite column rather than rejecting it.

Focused regression: parse a colon-containing absolute filename and assert the exact filename, line 42, and column 7. Include `C:\vault\note.md:24:8,3,hello`, with explicit expected filename `C:\vault\note.md`, line 24, column 8, and text `hello`. Reject non-finite, non-integer, and non-positive coordinates. Match the numeric coordinate suffix rather than assuming the filename ends at its first colon.

## Additional verified lifecycle defects

- `lua/99/window/init.lua:535-536,565-567`: a selection's scheduled `on_load` runs after its buffer is deleted if the popup is closed before the next scheduled frame. `windows.lua` reproduces `Invalid buffer id` at line 566. A regression should open and immediately close a selector, advance one frame, and assert no error. Check the captured window and buffer before running deferred setup.
- `lua/99/window/init.lua:518-532,579-582`: pressing `q` calls the cancellation callback twice. Selecting with Enter calls `cb(false, "")` through `WinClosed`, followed by `cb(true, selected_line)`. `windows.lua` records both sequences. Existing internal consumers ignore the extra false callback, so this is lower priority than the failures above. A regression should assert one callback per exit path, including native close, submit, cancel, and selection.
- `lua/99/window/init.lua:507-515`: the `BufUnload` handler skips augroup deletion once the window is invalid. Buffer-local autocmds disappear with the buffer, but the `WinClosed` autocmd and its augroup remain. `lifecycle.lua` submits three prompts and observes three extra `WinClosed` autocmds afterward. A regression should compare groups and autocmds before and after repeated prompt lifecycles.

## Validation and limits

Copied the eight relevant existing spec files into scratch and ran them with Plenary using `/tmp/99-ui-state-audit/minimal.vim`. There were 18 passing tests and one failure. `open_spec.lua:100` compares `/tmp/bar.lua` with Neovim's resolved `/private/tmp/bar.lua` on macOS. That path expectation is separate from the product defects above. The existing throbber cycle and request-status callback tests passed.

The normal search and tutorial completion paths also ran with another prompt open. Those checks did not establish another concrete failure. No standalone production call path requiring repeated `Throbber:start()` or `RequestStatus:start()` was found, so timer duplication under repeated starts is not reported as a product defect.

A reproduction can be run as `nvim --headless -u NONE -i NONE -l /tmp/99-ui-state-audit/windows.lua`. The other scripts named above use the same command form. The tutorial restart reproduction requires `tutorial-save.lua` followed by `tutorial-restore.lua`.

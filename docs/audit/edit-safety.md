# Visual edit safety audit

Audited `codex-and-audit` at `c17422457027c913c76c75a921fca1e623d2678e`, which was also HEAD when the original verification ran. The six findings below describe that baseline: four P1 findings and two P2 findings. All six now have fixes in the working tree.

## Resolution in the working tree

- ES1 uses a creation-time snapshot of the selected text, exact boundary marks, and the buffer's changedtick. Application rejects missing or unloaded buffers, missing or moved marks, revision changes, and changed text. The first completed overlapping request advances the revision, so later responses cannot overwrite it.
- ES2 uses Neovim's selection geometry for complete UTF-8 characters, combining characters, reversed selections, and exclusive endpoints. Character selections preserve selected line breaks. Response extraction also preserves trailing newlines; only linewise replacement removes one terminal line separator. Block mode raises a clear unsupported-selection error before a request starts.
- ES3 replaces through the exact captured boundaries. Display marks no longer define the replacement range.
- ES4 makes mark validity checks, deletion, and virtual-text updates safe after buffer deletion. Shared lifecycle fixes belong to the process owner. The integrated regression verifies that wiping one source buffer does not prevent cancellation of another request.
- ES5 replaces linewise selections with `nvim_buf_set_lines()`. First-line and empty-line selections no longer insert a leading blank line.
- ES6 validates response types and nonempty output, checks `modifiable`, and reports application failures through the process owner's completion handler. Rejections retain the full string in `context.unapplied_response` and log an excerpt of at most 2,048 Unicode characters, subject to the logger's byte limit. The failure message points to `require("99").view_logs()` for recovery. That view includes the full retained response even when diagnostic logs are filtered, truncated, or evicted. Recovery lasts while the request remains in history. CLI response size remains bounded by `max_response_bytes`.

The conflict policy is deliberately conservative. Any source-buffer edit after capture aborts application, including unrelated edits and edits that are later undone. Changing the current buffer without editing the source remains safe. This version does not attempt to merge concurrent edits.

`Prompt.visual()` now calls `require("99.ops.marks").capture_visual(context)` immediately after constructing its data, before prompt input. The helper is idempotent and registers its marks in `context.marks`. Cancelling prompt input calls `context:stop()` through the root owner's input handling. The prompt and input integration changes were made by their owners.

The owned implementation files are `lua/99/geo.lua`, `lua/99/ops/marks.lua`, and `lua/99/ops/over-range.lua`. The actual marks path is under `ops`. Focused tests are in `geo_spec.lua`, `geo_visual_spec.lua`, `marks_spec.lua`, `visual_spec.lua`, and `visual_safety_spec.lua`. The existing `visual_context_bounds_spec.lua` was also formatted.

Final owned checks pass: all 60 focused tests, luacheck, Stylua, and whitespace checks. An isolated checkout also passed all 189 tests and luacheck across 71 files. Its `make pr_ready` stopped on formatting in `lua/99/extensions/pickers.lua`, outside this ownership. Logs are in `/tmp/99-edit-safety-fix-tests/`. A scratch comparison matched Neovim's native yank text for 69 character-selection cases across inclusive, exclusive, and old selection modes. No live model calls ran.

The root separately reports that the visual geometry and safety suites pass on the minimum supported Neovim 0.11.5. The local installed 0.11.4 binary could not launch because its tree-sitter dynamic library is missing. Local runtime verification used the working 0.13 build. No installed Neovim files were changed.

## Verification

Read `AGENTS.md`, the visual request path, geometry, extmarks, cleanup, tracking, and their tests. Reproductions used headless Neovim 0.13.0-dev-1375, real `Prompt`, `Range`, `Mark`, `over_range`, and `Tracking` code, and a manually resolved fake provider. The scratch state used a no-op `sync` and rule refresh. No model process ran.

Scratch artifacts are in `/tmp/99-edit-safety-audit/`:

- `repro.lua` and `results.txt` cover selection bounds, edits, moves, deletion, concurrent requests, switching buffers, cancellation, and response handling.
- `additional.lua` and `additional-results.txt` cover nonmodifiable buffers, unloaded buffers, and completion after a buffer wipe.
- `repo/` is a copied checkout used for `make lua_test`. `tests.log` records 103 passing tests, two failures, and zero test errors. The scoped suites pass: `visual_spec.lua` has five tests, `geo_spec.lua` has eight, and `marks_spec.lua` has eleven. The failures are the Cursor command expectation and `/tmp` versus `/private/tmp` quickfix filenames in `open_spec.lua`.

The reproductions run with:

```sh
nvim --headless --clean -u NONE -i NONE -n -l /tmp/99-edit-safety-audit/repro.lua
nvim --headless --clean -u NONE -i NONE -n -l /tmp/99-edit-safety-audit/additional.lua
```

The original audit wrote only this report. The implementation phase changed only the owned implementation, test, and report files listed above. No commits were made.

## ES1 · P1 · Extmark existence does not protect edited, deleted, or moved text

Sources: `lua/99/ops/over-range.lua:66-90`, `lua/99/ops/marks.lua:17-30,50-61`.

The success handler considers the target safe when both point extmarks still exist. Neovim moves or collapses those marks when text changes. These marks do not invalidate on deletion, and the handler never compares the current text with the text sent to the model. The upper mark also belongs to the preceding line, so moving the selected line separates the two anchors.

Confirmed triggers and results, with a request pending on `TARGET`:

- Start with `{"header", "TARGET", "tail"}`. Replace `TARGET` with `USER SAVED WORK`, then complete with `STALE`. The result is `{"header", "STALE", "tail"}`. The user's edit disappears.
- Delete the selected line. Both marks remain valid. Completion produces `{"header", "STALEtail"}`, recreating the deleted selection and joining it to the following line.
- Insert `NEW USER LINE` immediately before `TARGET`. Completion removes both that new line and `TARGET`.
- Start with `{"header", "TARGET", "middle", "tail"}` and execute `:2move 3`. Completion produces `{"header", "NEW", "tail"}`. The unrelated `middle` line disappears.
- Start two requests on the same selection. Complete the second with `NEWEST`, then the first with `STALE`. The result is `{"header", "NEWEST", "STALE", "tail"}`. The older request inserts a second answer after the newer one.

Impact: successful callbacks can silently discard user edits, delete unrelated text, or apply stale results after a newer request completes.

Focused regression: delay the fake provider, perform each mutation above, and resolve the request. Conflicting results must preserve the current buffer and remain available for review. Include one nonconflicting edit elsewhere to verify that safe edits can still proceed. A text snapshot or revision check must cover the actual replacement region. Extmark existence alone cannot establish safety.

## ES2 · P1 · Character and block selections expand beyond their right boundary

Source: `lua/99/geo.lua:237-283`, especially lines 277-283.

`Range.from_visual_selection()` reads the ending column, then always replaces it with the final line's byte length. It never checks `visualmode()` or the `selection` option. The linewise workaround therefore applies to character and block selections too.

Confirmed with actual visual-mode keys:

- In `pre αβγ post`, position the cursor on `α` and type `vl<Esc>`. The marks identify `αβ`, but `range:to_text()` returns `αβγ post`. The ending mark is byte column 7, while the generated exclusive endpoint is byte column 16.
- Select a two-column block across `ab111ZZ`, `cd222YY`, and `ef333XX` using `<C-v>2jl<Esc>` from the first digit. The captured text is `111ZZ\ncd222YY\nef333XX`. It includes the unselected suffixes and the entire intermediate row.

Impact: the prompt and replacement include text outside the user's selection. A block operation can overwrite unrelated columns on several lines.

Focused regression: assert captured text and final replacement for a character selection with a suffix, multibyte characters, reversed selection, and `selection=exclusive`. Test a rectangular block separately. Block mode needs per-row ranges or an explicit rejection before starting the request. A single contiguous range cannot represent the rectangle.

## ES3 · P1 · Replacement starts before the selected text

Sources: `lua/99/ops/over-range.lua:21-22,82-90`, `lua/99/ops/marks.lua:17-30`.

The prompt range starts at the selected column. The replacement range starts at the preceding line's end, or at column zero on the first line. The inserted empty string restores a line break but cannot restore the selected line's unselected prefix.

Confirmed with `{"header", "prefix TARGET suffix", "tail"}` and selection columns 8 through 13. The request captures `TARGET suffix`, and completion with `REPLACED` produces `{"header", "REPLACED", "tail"}`. The unselected `prefix ` disappears even though it was absent from the selection text sent for replacement. Fixing ES2 alone leaves this deletion intact.

Impact: character selections destroy unselected text before the selection. The same start-boundary mismatch affects block selections.

Focused regression: supply an exact range for `TARGET` in `prefix TARGET suffix` and complete with `NEW`. Assert `prefix NEW suffix`. Keep status-display marks separate from replacement-boundary marks.

## ES4 · P1 · Wiping one buffer prevents “stop all” from cancelling other requests

Sources: `lua/99/ops/marks.lua:149-150`, `lua/99/prompt.lua:376-382,516-519`, `lua/99/state/tracking.lua:78-81`. Related status callbacks are at `lua/99/ops/request_status.lua:78-95`.

`Mark:delete()` calls the buffer API without checking whether the buffer still exists. `Prompt:stop()` deletes marks before running cleanup callbacks. `Tracking:stop_all_requests()` does not isolate failures between requests.

Confirmed with request A in one buffer and request B in another. Wipe A's buffer, then call `tracking:stop_all_requests()`. A becomes cancelled, but mark deletion raises `Invalid buffer id`. The loop exits with B still `requesting`. Resolving B applies `UNWANTED` to its buffer despite the stop-all action.

Completion after a wipe also fails during scheduled cleanup. The completion callback's error is swallowed, the request remains `success`, and `context:stop()` raises at mark deletion. Cleanup callbacks do not run. A pending status callback can likewise call `set_virtual_text()` on the invalid buffer.

Impact: closing one source buffer can defeat cancellation of other requests and interrupt cleanup. Wiping and merely hiding a buffer have different behavior. Unloading a still-valid buffer did not make `stop_all_requests()` throw in this reproduction.

Focused regression: start two requests, wipe the first buffer, stop all, and resolve both fake providers. Both requests must stay cancelled and no surviving buffer may change. Assert every cleanup callback runs. Repeat for completion and a status update after the wipe. Mark deletion needs to tolerate already-deleted buffers, and one cleanup failure must not prevent other cancellations.

## ES5 · P2 · Every replacement beginning on the first line inserts an extra blank line

Sources: `lua/99/ops/marks.lua:21-26`, `lua/99/ops/over-range.lua:85-90`.

When the selection begins on line one, the upper mark is at that line's column zero. The success handler still prepends the empty string intended to restore the preceding line's newline.

Confirmed with `{"TARGET", "tail"}`. Replacing the first line with `NEW` produces `{"", "NEW", "tail"}`.

Impact: even a linewise selection changes text outside the intended result. This can invalidate a shebang by moving it off the first line.

Focused regression: replace a first-line selection in a one-line buffer and a multiline buffer. Assert exact lines with no leading empty line. Replacing through the real selection boundaries removes the need for the newline workaround.

## ES6 · P2 · Failed application remains a successful request without an error

Sources: `lua/99/prompt.lua:248-252`, `lua/99/ops/clean-up.lua:25-30`, `lua/99/ops/over-range.lua:76-90`.

`Prompt:_observer()` sets `state = "success"` before the visual edit runs. The cleanup observer discards the result and error returned by `pcall(obs.on_complete, ...)`. Neither an application error nor an aborted replacement changes the final state.

Confirmed by starting a normal request, setting its source buffer's `modifiable` option to false, then completing with `NEW`. The source remains unchanged, the marks disappear, the active count becomes zero, and the context reports `success`. The `nvim_buf_set_text()` error is suppressed. A whitespace-only response also leaves the request successful after explicitly aborting replacement. A nil response from a custom provider raises inside `vim.trim()` and disappears through the same unchecked `pcall`.

Impact: users cannot distinguish a completed edit from an answer that never applied. The lifecycle also loses the application error needed to diagnose the failure. Built-in providers return strings, so the nil case is a defensive boundary issue rather than a claim about their normal output.

Focused regression: make the source nonmodifiable before completion, then assert a failed or unapplied state, a reported error, and retained response text. Test empty and invalid response values separately. Successful process exit and successful buffer application need distinct handling.

## Behavior verified without a finding

Switching to an unrelated buffer during a request correctly edits the original buffer through its stored buffer ID and leaves the current buffer unchanged. Ordinary cancellation before resolution preserves the source buffer. A linewise empty-line selection captures an empty string without crashing on the tested Neovim version. Unicode selection marks use byte columns correctly in the reproduced case. The verified Unicode failure is the expanded endpoint in ES2, not an independent UTF-8 byte-splitting defect.

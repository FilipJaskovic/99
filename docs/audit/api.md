# Public API and extension audit

Reviewed `codex-and-audit` at baseline `c17422457027c913c76c75a921fca1e623d2678e`. This report covers the public API, model pickers, native and cmp completion adapters, provider options, and generated documentation. It records baseline behavior before implementation by the other reviewers.

Reproductions and logs are under `/tmp/99-api-audit.qtK1gb`. They use isolated headless Neovim, controlled providers, and synthetic files. No live model calls or installed Neovim changes were made. Documentation generation ran against a scratch copy.

## Verified findings

### A1. P2: Reusing operation options silently resubmits the previous prompt

Sources: `lua/99/init.lua:31-41`, `:248-255`, and `:333-340`. The same pattern affects `visual`, `vibe`, and `tutorial`.

`process_opts` returns the caller's table. The interactive submit callback writes `additional_prompt` and `additional_rules` into that table. A keymap that reuses an options table opens the prompt only on its first invocation. Later invocations dispatch the previous text immediately because `additional_prompt` now exists.

`extra_repro.lua` calls `search(opts)`, submits `first request`, and calls `search(opts)` again. The capture count remains one, the caller's table contains `additional_prompt = "first request"`, and the controlled provider receives that text again. With a modifying operation, this unexpectedly repeats a model request without another prompt.

Focused regression: reuse one options table across two interactive invocations. Both must capture input, and the original options must remain unchanged. Copy the options and the mutable `additional_rules` list before expanding or appending rules. Root owns this change.

### A2. P2: A provider switch redirects a pending prompt with its previous model

Sources: `lua/99/init.lua:333-340`, `:502-509`, `lua/99/prompt.lua:95`, and `:299-304`.

The context snapshots the model when the prompt opens, but request submission reads the current state's provider. Opening a search prompt, switching providers, and submitting therefore invokes the new provider with the old provider's model. This can reject the request or select an unintended backend.

`repro.lua` opens a prompt using the baseline default, switches to a controlled provider whose default is `new-provider-model`, and submits. The controlled provider receives `opencode/claude-sonnet-4-5`, while `get_model()` returns `new-provider-model`.

Focused regression: open a prompt, change the selected provider and model, then submit. The context must retain one consistent provider/model pair. Snapshot the resolved provider with the model at context creation. Root and Process own the shared change. Resolving `State.provider_override` to the fork's default Codex provider supports this contract.

### A3. P2: An asynchronous model picker assigns models to a different provider

Sources: `lua/99/extensions/pickers.lua:13-25`, `:57-59`, `lua/99/extensions/fzf_lua.lua:32-40`, and `lua/99/extensions/telescope.lua:33-47`.

Model results belong to the provider selected when fetching starts, but the callback reads the current global model. Selection then calls `set_model` without checking provider identity. Switching providers while fetching or while the picker remains open assigns the old provider's model to the new provider. Passing an explicit different provider to `select_model(provider)` has the same mismatch.

`extra_repro.lua` holds provider A's fetch callback, switches to B, returns A's results, and selects one. The active provider remains `ProviderB`, its model becomes `model-a-selected`, and the picker title misleadingly reports B's current model.

Focused regression: switch providers both before fetch completion and before selection. Stale callbacks must not update the active model. Bind the displayed model and selection callback to the fetched provider identity, with an explicit policy for the optional provider argument. The exported provider catalog already feeds both pickers, so exporting Codex includes it automatically.

### A4. P2: Native completion operates in an unrelated buffer after focus changes

Source: `lua/99/extensions/native.lua:45-90`.

The debounce callback verifies that the original prompt buffer is valid, but reads the current line and cursor and calls `complete` in whichever buffer is now current. Switching to another insert-mode buffer during the 100 ms delay can display 99's completion menu there. The prompt buffer need not be wiped.

`repro.lua` queues the real autocmd, switches from prompt buffer 2 to ordinary buffer 3, and intercepts `complete`. Completion runs in buffer 3. Only the mode query and completion sink are substituted to make the delayed state deterministic.

Focused regression: queue completion, switch buffers, and advance the timer. No completion may run outside the captured buffer. Also check current-buffer identity in the callback. Use the context reviewer's `Completions.find_active_reference(before)` for ordinary and quoted tokens rather than retaining the `%S*$` matcher.

### A5. P2: Native completion never closes its timer handles

Source: `lua/99/extensions/native.lua:39` and `:96-102`.

Every prompt allocates a libuv timer. `BufWipeout` stops it but never calls `close`. Repeated prompt lifecycles retain stopped native handles until Neovim exits.

`repro.lua` creates and wipes five buffers through the actual adapter, forces garbage collection, and enumerates libuv handles. Five additional non-closing timer handles remain. The reproduction closes those handles afterward.

Focused regression: compare live timer handles before and after repeated prompt lifecycles. Wiping each buffer must stop and close its timer. A callback already queued on the main loop must tolerate teardown.

### A6. P2: A missing cmp dependency aborts setup instead of using the advertised guard

Sources: `lua/99/extensions/init.lua:22-31` and `lua/99/extensions/cmp.lua:115-117`.

The protected `require` loads the 99 adapter, which does not import `cmp` at module load time. The actual dependency import occurs later in unprotected `init`. Selecting `source = "cmp"` without nvim-cmp therefore raises `module 'cmp' not found` and aborts `setup`, without the warning implemented for that condition.

`repro.lua` runs this configuration with a clean runtime. Setup fails, and the captured notification list is empty.

Focused regression: initialize with cmp absent and verify a controlled dependency error or fallback, with no partially initialized source. Check the dependency at the adapter boundary. Context owns extension routing, so coordinate dependency handling with that owner.

### A7. P2: The cmp adapter rejects a second setup call

Source: `lua/99/extensions/cmp.lua:91-95` and `:115-117`.

The module retains its registered source forever and asserts that it is nil during initialization. Reloading configuration with cmp, or switching away and back to cmp, fails after the first successful setup. The native adapter permits repeated setup, and the public API has no single-use restriction.

`repro.lua` substitutes a minimal cmp registration interface. The first setup succeeds. The second fails at line 92 with `the source must be nil when calling init on an completer`.

Focused regression: initialize twice with different rules and file options. Keep one registered source whose state and providers update to the latest configuration. This extension fix complements the separate reconfiguration cancellation finding in `ui-state.md`.

### A8. P2: Regenerating docs restores a broken setup example

Sources: `lua/99/init.lua:136-137`, `README.md:95-96`, `README_HEADER.md:29`, and `gen-docs:26-42`.

The checked-in README uses the valid `source = "native"`. Its generator input still uses `source = "cmp" | "blink"`. Running `./gen-docs` restores that expression and replaces the current completion guidance with the old statement that cmp is required.

`docs_repro.py` generates a scratch README, wraps its setup fragment in a Lua table, and invokes its config function against harmless stubs. The regenerated example fails with `attempt to perform arithmetic on a string value` on the installed Neovim. The checked-in example succeeds. The expression also does not represent a source choice in Neovim's Lua configuration contract.

Focused regression: generate the README in memory and validate its setup example. Make the annotated example and header authoritative before regenerating. Include `"native"` in `_99.Completion.source` at `lua/99/init.lua:46`, and update the fork repository and default-provider examples together. Root owns documentation changes.

### A9. P2: The documentation check examines a different output from the generation command

Sources: `docs/src/generate.ts:36`, `:62-75`, `docs/package.json:6-7`, and `gen-docs:7,39-42`.

`./gen-docs` writes the repository's `README.md`. The package's `check` command compares generated content against `docs/README.md`, which currently contains only two introductory lines. The failure tells contributors to run `./gen-docs`, but that command cannot update the file under comparison.

`docs_repro.py` runs generation successfully in scratch and immediately runs the check. It still exits 1 with `README.md is out of date. Run: ./gen-docs`. Conversely, updating only `docs/README.md` could satisfy the check while the public README remains stale.

Focused regression: the documented generate command followed by check must pass. Changing an input must fail check without writing output. Use one destination and the same header composition for both operations. Root owns this change.

## Independently verified overlaps and security defaults

These observations are already covered by the other reports and are not additional findings:

- Reconfiguration leaves old requests outside `stop_all_requests`. `repro.lua` records an old request still `requesting`, no simulated process kill, and zero requests in the new state. See the reconfiguration finding in `ui-state.md`.
- `completion.files.enabled = false` still returns file completion items and attaches a synthetic file through `Completions.parse`. `extra_repro.lua` verifies both paths. See C4 in `context.md`. A disable option must control resolution as well as the menu.
- Built command arrays unconditionally include Claude's `--dangerously-skip-permissions` at `lua/99/providers.lua:195`, Cursor's `--trust --force` at `:242-243`, and Kiro's `--trust-all-tools` at `:295`. Gemini uses `auto_edit` at `:319-322`. Public options provide no permission policy. Appending `provider_extra_args` at `:74-76` cannot remove these existing arguments. The process report describes the lack of an enforced operation boundary. These are verified defaults, not evidence of an external CLI escaping a sandbox.

The existing provider spec ran in isolation: 16 tests passed and one failed. `providers_spec.lua:55-61` expects Cursor's command without `--trust --force`; the baseline command includes them. Claude's command test explicitly expects the bypass flag. Tests therefore do not establish safe permission defaults. No external CLI was invoked.

## Small maintenance changes, separate from observed bugs

The fork can retain its current module structure. The useful seams are one resolved default provider, a provider/model pair captured per request, one completion-reference parser shared by adapters, and idempotent adapter initialization. A provider-specific permission policy needs a deliberate compatibility choice because the current file-output transport requires write access.

`auto_add_skills` is annotated in the baseline at `lua/99/init.lua:59`, but no implementation reads it. Removing the unsupported option is contract cleanup, not an additional demonstrated runtime failure.

## Scoped implementation handoff

After this report, implementation was authorized for the completion adapters, picker extensions, logger, and new focused specs. The extension changes address A3 through A7. Native completion uses the context owner's quoted-reference helper, checks buffer identity, and closes timers on wipe and repeated initialization. Cmp registers one reusable source and imports its dependency inside the router's protected load. Both model picker adapters bind selection to the provider that supplied the models. The exported Codex provider appears in their catalog.

The process report's retained-log finding was also assigned to this scope. Retained request logs now have a fixed 256 KiB limit and one valid JSON truncation notice. Configured sinks still receive complete log lines. Logger reset now releases both the cache and its request-order list. An independent reproduction confirmed that the previous reset left stale IDs and caused `Logger.logs()` to raise at baseline line 275.

New specs are `completion_adapters_spec.lua`, `picker_model_spec.lua`, and `logger_bounds_spec.lua`. All 14 focused tests pass on Neovim 0.11.5 and the installed 0.13 development build. Scoped Luacheck reports zero warnings or errors, and the scoped files pass StyLua formatting. A clean-process `require("99.extensions.native")` succeeds on both versions. Cmp, blink.compat, and picker interfaces use controlled stubs in these tests. No common specs, root setup/state files, context-owned modules, or generated documentation were edited in this implementation scope. No commits were made.

## Reproduction commands

```sh
nvim --headless --clean -i NONE -l /tmp/99-api-audit.qtK1gb/repro.lua
nvim --headless --clean -i NONE -l /tmp/99-api-audit.qtK1gb/extra_repro.lua
python3 /tmp/99-api-audit.qtK1gb/docs_repro.py
```

Logs are `repro.log`, `extra-repro.log`, `docs-repro.log`, and `providers-tests-isolated.log` in the same directory. The Lua scripts intentionally assert or display baseline failures. Re-run against the recorded baseline when checking those results after implementation.

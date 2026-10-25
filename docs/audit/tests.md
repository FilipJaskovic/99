# Testing, CI, and compatibility audit

Audited baseline `c17422457027c913c76c75a921fca1e623d2678e` on branch `codex-and-audit`. Read `AGENTS.md`. The initial review changed only this report. The implementation follow-up below lists subsequent authorized changes. All reproduction fixtures are under `/tmp/99-tests-audit`. No model calls, dependency installs, installed-plugin changes, commits, or user-note changes were made.

## Validation

- Reused the parent's baseline `make lua_test` output in `/tmp/99-baseline-tests.log`, as requested. It contains **103 successes, two assertion failures, and zero test errors** across 21 spec files.
- Both failures are independent of parser availability. The Cursor command assertion differs from the implementation. The `open()` assertion differs only in macOS path canonicalization. There are no missing-parser errors. The active test paths do not load `99.editor.lsp`; its import is commented out in `lua/99/editor/init.lua:2`.
- Used installed Neovim `v0.13.0-dev-1375+g8e0e19c08b-Homebrew`, with `--headless --noplugin -u NONE -i NONE`, for isolated reproductions. Production providers were replaced by `99.test.test_utils.TestProvider` or a stub.
- A setup with only a fake provider, isolated `tmp_dir`, and disabled status polling successfully injected `@plain.md` content in a directory without `.git`. Generic non-Git support works. Specific failures follow below.
- `node --experimental-strip-types docs/src/generate.ts --check` exits 1 because generated docs are stale. Generated README output was assembled in `/tmp`, without running the mutating `./gen-docs` script.
- `make pr_ready` was not duplicated. The parent owns its isolated luacheck and StyLua setup and the full readiness result. Neither tool was initially on PATH.

## Findings at baseline

### T1. P2: `completion.files.enabled = false` still injects file content

**Source:** `lua/99/extensions/files/init.lua:303-307`, `:324-355`; `lua/99/extensions/native.lua:32-35`.

`Files.setup` stores `config.enabled`, but discovery, completion, token validation, and resolution never read it. After `_99.setup({ completion = { files = { enabled = false } }, ... })`, a fake-provider search containing `@plain.md` still receives that file's content. This defeats an explicit configuration switch and can send local contents the user expected to disable.

**Evidence:** `/tmp/99-tests-audit/behavior.log` records `disabled_search_has_file_content=true`. The smaller reproduction records four completion items and one resolved reference while disabled.

**Regression:** Set the option through `_99.setup`, submit a prompt containing an existing file token through the fake provider, and assert no file content is injected and no file candidates are offered. `files_spec.lua` currently tests only enabled configurations.

### T2. P2: accepted completions for note names with spaces resolve to no context

**Source:** `lua/99/extensions/files/init.lua:332-335`; `lua/99/extensions/completions.lua:55-64`.

A plain vault containing `My Note.md` offers the completion `@My Note.md`. `Completions.parse` splits tokens with `%S+`, so the accepted completion is interpreted as `@My` and silently contributes no reference. This also affects directory names with spaces.

**Evidence:** `/tmp/99-tests-audit/repro.log` contains the offered completion, `space_token_refs={}`, and a successful `@plain.md` control.

**Regression:** Create a real non-Git fixture with a spaced filename, use its actual completion insertion text as the prompt, and assert the fake-provider query contains its content. Choose and document one escaping or quoting format shared by insertion and parsing.

### T3. P2: Git-quoted filenames are stored as nonexistent paths

**Source:** `lua/99/extensions/files/init.lua:85-118`.

The Git scanner consumes line-delimited `git ls-files` output as literal filenames. Git's default quoting turns `café.md` into a quoted path containing octal escapes and quotes filenames containing a literal double quote. Both appear in discovery with those extra characters, and `resolve` returns nil for the real filename. The same files work through filesystem discovery.

**Evidence:** A real temporary Git repository, without commits or changes to Git configuration, produced escaped filenames and `git_unicode_ref=nil` / `git_quote_ref=nil` in `repro.log`.

**Regression:** Use a temporary Git repository with Unicode, quoted, tabbed, and whitespace-edge filenames, and round-trip discovery through resolution. Use NUL-delimited Git output and preserve filename bytes. Current Git integration tests mock already-decoded plain paths at `lua/99/test/files_spec.lua:224-230`, so they cannot catch this failure.

### T4. P2: Windows drive paths become quickfix entries for a file named `C`

**Source:** `lua/99/ops/qfix-helpers.lua:5-16`.

Parsing `C:\vault\note.md:24:8,3,hello` returns `{filename = "C", lnum = 1, col = 1, text = "hello"}`. The first colon is treated as the filename separator. Search and vibe both use this parser, so otherwise valid absolute Windows results navigate to the wrong file and position.

**Evidence:** `windows_qfix` in `repro.log` shows this exact result. This parser failure is reproducible on macOS without claiming a Windows runtime test.

**Regression:** Assert filename, line, column, and notes for drive-letter paths, paths containing colons, and the existing Unix cases. Anchor numeric location fields while preserving the full path. `qfix_helpers_spec.lua:7-42` covers only paths without drive prefixes.

### T5. P2: new project files remain unavailable after request refresh

**Source:** `lua/99/extensions/files/init.lua:208-212`; `lua/99/extensions/native.lua:152-155`; `lua/99/state.lua:124-126`.

Once discovery returns at least one file, `get_files` never scans again. Creating a note and invoking the same `refresh_rules` path used before each request does not invalidate the cache. The new note cannot be completed or referenced until explicit rediscovery or another setup.

**Evidence:** `behavior.log` records `new_file_after_refresh=false` and `new_file_after_manual_discovery=true` for a new file in the temporary non-Git vault.

**Regression:** Discover a real fixture, create a file, then make another request and verify the new file is available. The cache test at `files_spec.lua:491-508` proves reuse but does not test invalidation after filesystem changes.

### T6. P2: README regeneration restores a broken basic setup

**Source:** `lua/99/init.lua:136-137`; `README_HEADER.md:29`; `gen-docs:30-43`; `.github/workflows/makefile.yml:74-75`.

The checked-in README uses valid `source = "native"`. Its source documentation still uses `source = "cmp" | "blink"`. Regenerating the README restores that expression. Evaluating the generated lazy-plugin config on the installed Neovim fails before `_99.setup` runs with `attempt to perform arithmetic on a string value`. The header also restores the obsolete claim that completion requires cmp.

**Evidence:** `/tmp/99-tests-audit/generated-README.md`, `generated-setup.lua`, and `docs-run.log`. The stub setup call count is zero. Current README setup compiles; generated setup evaluation fails. The docs freshness check also fails, and `pr_ready` contains no docs check.

**Regression:** Generate docs in memory, compare them with the checked-in artifacts, and evaluate the documented minimal config using a stub `_99.setup`. Fix the source comment and header together. A syntax-only check is insufficient on this Neovim version because the expression compiles before failing at runtime.

### T7. P2: two baseline assertions prevent a green readiness run

**Source:** `lua/99/test/providers_spec.lua:51-61`, `lua/99/providers.lua:235-247`; `lua/99/test/open_spec.lua:72-76`, `:100-104`.

The Cursor test expects a command without `--trust` and `--force`, while the provider emits both. Resolve the intended permission behavior before changing the expectation. This failure is a source/test mismatch, not a parser problem.

The `open()` test compares literal `/tmp/bar.lua` with Neovim's `/private/tmp/bar.lua` buffer name on macOS. The operation retains the correct location. Normalize expected and actual paths, or use a canonical temporary fixture path. Its example responses also omit the required range field, causing both the helper-derived expectation and actual quickfix entry to contain empty notes. Use valid responses and assert user-visible notes directly rather than deriving all expectations through the implementation helper.

**Regression:** Keep the command contract assertion after choosing the intended flags. Run the existing history/quickfix test with valid fixture responses and canonical paths on macOS and Linux. Baseline CI ran Linux only, so it missed the macOS assertion failure.

### T8. P3: non-Git discovery exceeds `max_files` after recursion

**Source:** `lua/99/extensions/files/init.lua:178-189`.

With `max_files = 1`, a directory containing `a/x.md` and `z.md` returns both files. After recursive discovery reaches the cap, the caller continues scanning and inserts another file before checking the count.

**Evidence:** `/tmp/99-tests-audit/max-files.log` contains both paths. The fixture is under `/tmp/99-tests-audit/max-files`.

**Regression:** Discover a real nested non-Git tree with a small limit and assert the global result count never exceeds it. Check the cap before every insertion or stop the parent loop after recursive scanning reaches it.

## Neovim compatibility boundary

The baseline workflow pins Neovim **0.11.5**, uses one Linux runner, and has no version matrix at `.github/workflows/makefile.yml:12-16`. The baseline README states no minimum Neovim version. Default native completion unconditionally assigns `completeopt = "menuone,noinsert,noselect,popup,fuzzy"` at `lua/99/extensions/native.lua:124-128`. The installed official Neovim changelog, `news-0.11.txt:307`, identifies `fuzzy` in `completeopt` as a 0.11 addition. Thus the documented default is not compatible with 0.10 unless that option is guarded. Setup-only tests miss this because the native buffer initializer runs when a prompt opens.

This agent did not install or execute a 0.10 or 0.11 binary. The follow-up workflow tests the supported minimum **0.11.5** on Linux and macOS. The local 0.13 development result does not establish a wider supported range. Treat the Windows parser reproduction separately from full Windows support.

## Reproduction artifacts

`/tmp/99-tests-audit/repro.lua` checks real Git and non-Git discovery, completion insertion/resolution, disabled completion, Windows result parsing, and a fake-provider non-Git search. `/tmp/99-tests-audit/behavior.lua` checks disabled content injection and new-file visibility. Their corresponding `.log` files contain observed values. All tests use temporary fixture contents.

## Implementation follow-up

- Fixed `open_spec.lua` with real temporary Lua files and canonical fixture paths. Valid response fixtures include the required range field. Expectations assert filenames, locations, and notes directly. Both focused tests pass on local macOS/Neovim 0.13 development. Fixtures and popup/quickfix windows are cleaned up after each case.
- Added `scripts/tests/docs_smoke.lua` and `make docs_smoke` to `pr_ready`. The script loads the exported API, replaces `_99.setup`, blocks `vim.system`, and evaluates the documented lazy.nvim setup in both README artifacts. It catches invalid expressions and unknown provider references without configuring 99 or calling a model. It needs only Neovim. Both the formatter and linter now include `scripts/tests/`.
- Extended the existing generator's `--check` mode to verify both `docs/README.md` and the root README composed from `README_HEADER.md`. `make docs_check` remains separate and requires Node 22.6+ for the existing TypeScript generator. CI runs it on Linux. Regeneration requires `node --experimental-strip-types docs/src/generate.ts && ./gen-docs`; generated artifacts remain the root owner's responsibility.
- Added a Linux/macOS matrix at pinned Neovim 0.11.5. Linux runs full `pr_ready`; macOS runs `lua_test docs_smoke`. Linux owns the platform-independent lint, formatting, and docs freshness checks. This also avoids depending on Homebrew's current Lua 5.5 for luacheck, which fails locally in `luacheck.standards` before reading project files.
- Removed CI parser installation and caching. Baseline tests passed every parser-related path without loading the parser-dependent editor module. Neither the existing suite nor this follow-up introduces a parser dependency. No installed parser or plugin was changed.
- Added `-i NONE` to the main test command to avoid reading or writing the user's ShaDa state.

Focused verification used `/tmp/99-lua51-tools/bin/luacheck` and the existing Mason StyLua executable. Both changed Lua files pass lint with zero warnings/errors and pass formatting checks. Scratch docs checks accept fresh artifacts, reject a stale root README, and reject stale `docs/README.md`. The smoke script accepts a valid setup and rejects the original string-expression failure and an unknown provider. Workflow YAML parses and all shell steps pass `bash -n`. The full docs targets remain expected to fail until the root owner regenerates both artifacts after source changes settle. This agent did not rerun the full concurrent test suite or launch CI.

The context owner handles T1, T2, T3, T5, and T8. The Windows quickfix reproduction T4 was sent to the UI owner. The process owner handles the Cursor command contract in T7. The root owner handles setup documentation and regeneration in T6.

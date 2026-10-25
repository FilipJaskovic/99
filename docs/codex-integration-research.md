# Codex integration for 99

Researched 2026-10-25 against 99 baseline `c17422457027c913c76c75a921fca1e623d2678e` and the installed `codex-cli 0.164.0`. Source line references below describe that baseline. No model requests, credential reads, user-note changes, or installed-Neovim changes were made.

## Implementation status

The fork now has the native provider factory in `lua/99/providers/codex.lua`. It uses stdin and `--output-last-message`, explicit operation sandboxes, ephemeral sessions, and SIGINT cancellation. `response_mode = "stdout"` selects the final-response prompt contract. The CLI's result file remains the source of replacement text. The internal model sentinel is `default`, which is never passed as a model ID.

`provider_extra_args` accepts config, profile, model, sandbox, enable, disable, add-dir, and local-provider options, plus the oss, ignore-user-config, ignore-rules, and strict-config switches. Long options accept `--name=value` or separate values. Explicit model and sandbox overrides replace their default flags. These are trusted advanced options: a broader sandbox or extra writable directory deliberately grants more access. The provider appends `approval_policy="never"` after advanced options to retain noninteractive behavior. It rejects output routing, output schema, JSON, bypass flags, subcommands, and positional prompts rather than allowing them to change the I/O contract.

Vibe selects its output instructions from the request's captured provider, so changing providers while a prompt is open does not change that request's protocol. Codex also uses the request's captured extra arguments, including an empty snapshot, instead of options changed later in shared state. Other providers retain the temporary-file contract. Shared process supervision, provider export, prompt finalization, and the default-provider switch are owned by the process and root agents.

The focused fake-CLI suite at `lua/99/test/codex_spec.lua` covers command construction, advanced-argument validation, exact large stdin, result-file extraction, cwd capture after a directory change, a non-Git vault, nonzero exit diagnostics, missing and empty output, response size limits, all four prompt contracts, captured-provider vibe routing, and extra-argument snapshots after mutable state changes. All 13 tests passed with `nvim --headless --noplugin -u scripts/tests/minimal.vim -c "PlenaryBustedFile lua/99/test/codex_spec.lua"`. It does not make model calls. Formatter and luacheck checks passed for the four owned Lua files.

## Recommendation

Implement a native Lua `CodexProvider` around `codex exec`, with the prompt on stdin and `--output-last-message` for the result. Keep the existing observer and result-file interface. Use explicit `read-only` sandboxing for visual, search, and tutorial operations, and `workspace-write` for vibe. Do not copy another provider's permission-bypass flags.

Existing Codex ChatGPT login can authenticate this provider. The parent confirmed an active ChatGPT login. There is no reason to require a new API key, read `auth.json`, or implement OAuth in Lua. Preserve `CODEX_HOME` and normal environment inheritance so Codex can find its own credential storage. [Codex authentication](https://developers.openai.com/codex/auth/)

The decisive change is the output contract: Codex returns the requested payload as its final assistant response, and the CLI writes that response to 99's result file. The model must not receive 99's instructions to write `TEMP_FILE`. The CLI host writes `-o` outside the model's tool sandbox, so a read-only agent can still return a result. This follows directly from the CLI's host-side `std::fs::write`. [0.164.0 output writer](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/exec/src/event_processor.rs#L31)

## Minimal invocation

Construct an argv array, without a shell:

```lua
local argv = {
	"codex", "exec",
	"--skip-git-repo-check",
	"--sandbox", context.operation == "vibe" and "workspace-write" or "read-only",
	"--color", "never",
	"--ephemeral",
	"--output-last-message", absolute_result_path,
}
-- Append { "--model", context.model } only for an explicit model selection.
-- Append supported user options before the stdin prompt marker.
table.insert(argv, "-")
-- vim.system(argv, { cwd = captured_cwd, stdin = query, text = true, ... })
```

`--ephemeral` avoids saving Codex conversation sessions and matches 99's independent-request behavior. It does not erase 99's own saved prompts or logs. Omit it only for an intentional session-resume feature. All displayed flags and stdin behavior were checked with installed `codex exec --help`. [Pinned CLI arguments](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/exec/src/cli.rs)

Capture an absolute working directory and absolute result path before spawning. Use the same captured directory to resolve relative result paths. Changing Neovim's cwd during the request must not redirect result retrieval. No `--add-dir` is necessary for the host's `-o` write. Use `--add-dir` only when vibe intentionally needs model write access beyond its working root.

Keep model selection optional. Omitting `--model` lets Codex honor its configured model and provider default. Do not pass `opencode/claude-sonnet-4-5`, an `openai/` prefix, or a fictitious `default` model to Codex. 99 currently fills a model during setup and provider switching at `lua/99/init.lua:432` and `:508`. Give Codex a deliberate representation of "use the CLI default" and omit `--model` for that representation. Avoid a hard-coded catalog as the source of account availability. Installed `codex debug models --bundled` is an offline bundled catalog, not proof of account access. A future app-server client can use `model/list`.

In 0.164.0, exec supplies headless `approval_policy = never` by default, with additional handling for configured automatic review. Do not assume interactive top-level `-a` is an exec option, and do not use older examples containing `--full-auto`, which is absent from this installed help. Explicit sandbox selection prevents silently relying on a user's configured default permissions. Managed requirements can still reject or constrain settings. Preserve the diagnostic and fail rather than retry with broader permissions. [Exec configuration](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/exec/src/lib.rs#L585), [permission override validation](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/core/src/config/mod.rs#L3476)

## Why this matches 99

99 already launches one process per request through `vim.system`, emits activity through observers, and reads `context.tmp_file` after a successful exit. See `lua/99/providers.lua:59`, `:80`, and `:127`. The provider can retain that architecture with a small hook for stdin, cwd, and Codex's output instructions. No JavaScript bridge or persistent server is needed.

The prompt changes must be intentional:

- `lua/99/prompt.lua:500` appends the temporary-file location. Lines 505-510 add the only-write-temp-file instructions to visual, tutorial, and search.
- `lua/99/prompt-settings.lua:118` prohibits conversational output and requests a file write. Lines 167-172 tell the model to finish after writing the file.
- Vibe embeds the same file-write contract in its operation prompt at `lua/99/prompt-settings.lua:110` even though `Prompt:finalize()` skips the generic restriction for vibe.

For Codex, replace those instructions at prompt construction with "Return only the requested payload as your final response." Preserve visual's raw replacement code, tutorial's Markdown, and search/vibe's existing quickfix line format. Vibe must still perform workspace edits and return the location report. Do not modify the completed query through broad string substitutions, because user text may contain the same strings. Keep other providers' current file-write protocol intact.

## Four integration failures to prevent

These are verified integration constraints, not claims that the baseline already contains a Codex provider.

1. **Read-only Codex with the existing prompt cannot satisfy the response contract.** Trigger: visual/search/tutorial with `--sandbox read-only`, retaining `only_tmp_file_change()`. The prompt demands a model tool write that the sandbox forbids, while discouraging the final response that `-o` captures. Impact: failed requests or explanation text instead of replacement code. The conflicting instructions are at `lua/99/prompt-settings.lua:118-123` and `lua/99/prompt.lua:500-510`. Test all four finalized Codex operation prompts, including vibe's embedded instructions, and verify that they request final-response output without changing another provider's contract.

2. **Non-Git vaults fail before useful work without the skip flag.** Trigger: running from an ordinary Obsidian vault without `.git`. Codex exec performs a Git-root check unless `--skip-git-repo-check` is present. Impact: a provider that works in this source repository fails in a common personal-notes workspace. Include the flag unconditionally and test an actual temporary non-Git directory through a stub executable. [Exec Git check](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/exec/src/lib.rs)

3. **An empty precreated result can conceal a host output-write failure.** 99 precreates the result at `lua/99/prompt.lua:456-461`, and `BaseProvider:_retrieve_response()` accepts any readable file at `lua/99/providers.lua:35-53`. Codex's `-o` writer prints write failures to stderr without returning a write error to its caller. Trigger: a successful model turn whose output file becomes unwritable. Impact: 99 can treat the old empty file as a successful response. Prefer a unique, initially absent Codex output file, or unlink Codex's empty placeholder before spawn. Require successful process exit and successful retrieval of the newly produced file. Missing or invalid output must not fall back to stdout. Visual already rejects blank replacement at `lua/99/ops/over-range.lua:76`, but that is not provider-level verification. Test zero exit with no output file, a failed exit with partial output, and operation-specific empty results. [Output writer](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/exec/src/event_processor.rs#L31)

4. **Cancellation must win over a queued successful read.** `lua/99/providers.lua:112` checks cancellation before scheduling result retrieval at line 127, but that scheduled function does not check again. Trigger: cancellation after process completion schedules the read and before the read callback executes. Impact: an observer can receive success after cancellation, including a buffer edit. Recheck cancellation immediately before result retrieval and success delivery. Test that exact scheduling order with a stub process and controlled Neovim callbacks. This concerns the shared lifecycle and remains the parent's implementation responsibility.

## Streaming, cancellation, and sessions

For the first implementation, omit `--json`. Default stdout contains the final answer, while progress and diagnostics go to stderr. `-o` remains the only result source. Existing stdout/stderr observers can display activity without parsing terminal output as replacement text. Bound retained diagnostics, surface spawn and nonzero-exit errors, and tolerate arbitrary callback chunk boundaries. [Exec output contract](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/exec/src/lib.rs#L1)

If structured progress is wanted, add `--json` and a buffered JSONL decoder. Exec events include `thread.started`, `item.completed`, `turn.completed`, and `turn.failed`. They are not the app-server protocol. In 0.164.0, exec's JSON processor emits assistant text as completed items rather than exposing the app-server's text deltas. Do not promise token-by-token UI updates from `--json`, or concatenate every assistant message into the payload. [Exec event mapping](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/exec/src/event_processor_with_jsonl_output.rs#L343)

99 currently cancels with SIGTERM at `lua/99/prompt.lua:321-336`. The installed npm launcher forwards SIGINT, SIGTERM, and SIGHUP to the native binary. Exec explicitly handles Ctrl-C/SIGINT by requesting `turn/interrupt`. Prefer a Codex-specific graceful SIGINT path, then bounded termination escalation if it fails to exit. Killing one PID alone is not evidence that every spawned tool descendant stopped. Cancelled requests must never apply late output. [Launcher signal forwarding](https://github.com/openai/codex/blob/rust-v0.164.0/codex-cli/bin/codex.js), [exec interrupt handling](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/exec/src/lib.rs#L1190)

Keep requests independent initially. If sessions become necessary, record the exact `thread.started.thread_id` and use `codex exec resume SESSION_ID -`. Never use `--last` in a plugin with concurrent requests, because it can select another request's conversation. Recheck permissions and cwd on resume rather than assuming the prior session matches the current operation. Persistence is incompatible with the proposed ephemeral mode.

Read-only limits writes by the agent's sandboxed tools. It does not mean the agent cannot read accessible notes, call configured MCP tools, or use other configured integrations. `workspace-write` intentionally permits project changes. Preserve normal Codex authentication and model configuration, but document that Codex loads its own instructions, tools, rules, and configuration as well as 99's prompt. A prompt restriction is not a replacement for the sandbox. Do not automatically add permission-bypass, hook-trust-bypass, network-enabling, or broad writable-root flags.

## Alternatives and upgrade path

**Codex app-server** is the right next step for interactive approvals, account-aware model discovery, persistent threads, turn steering, or true assistant-text deltas. It reuses Codex auth and the same underlying agent runtime. It costs a persistent process, bidirectional request routing, per-thread/turn state, approval responses, reconnect handling, and version compatibility. Local stdio avoids opening a network listener. The installed command is marked experimental.

The basic newline-delimited JSON protocol omits the `jsonrpc` field. Wait for each response before the dependent request:

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"neovim_99","version":"0.1.0"}}}
{"method":"initialized","params":{}}
{"id":2,"method":"thread/start","params":{"cwd":"/absolute/vault","sandbox":"read-only","approvalPolicy":"never","ephemeral":true}}
{"id":3,"method":"turn/start","params":{"threadId":"THREAD_ID_FROM_2","input":[{"type":"text","text":"FINALIZED_PROMPT"}]}}
{"id":4,"method":"turn/interrupt","params":{"threadId":"THREAD_ID_FROM_2","turnId":"TURN_ID_FROM_3"}}
```

The last request is only for cancellation. Consume `item/agentMessage/delta` for display, completed agent-message items for final content, and `turn/completed` for terminal status. A `turn/start` response means the turn started, not that it succeeded. Handle server-initiated approval requests if enabling an interactive approval policy. Generate schemas from the supported executable with `codex app-server generate-json-schema --out DIR`; do not copy protocol assumptions from a newer release. This command was run offline for 0.164.0, and its generated thread/turn fields match the example. [App-server protocol](https://developers.openai.com/codex/app-server/)

**Codex SDK** is useful when the host is already TypeScript or Python. In this release, the TypeScript SDK wraps `codex exec` and JSONL, including stdin, session resume, and abort signals. It adds Node.js 18+ and another process boundary to a Lua plugin without removing the underlying CLI contract. The current Python SDK instead controls app-server, reuses existing auth, and installs a matching runtime dependency. It supports streaming and multi-turn operation but introduces Python packaging and bridge maintenance here. Describing all current Codex SDKs as exec wrappers would be inaccurate. [TypeScript SDK](https://github.com/openai/codex/blob/rust-v0.164.0/sdk/typescript/README.md), [TypeScript process implementation](https://github.com/openai/codex/blob/rust-v0.164.0/sdk/typescript/src/exec.ts), [Python SDK](https://github.com/openai/codex/blob/rust-v0.164.0/sdk/python/README.md), [Python release compatibility](https://github.com/openai/codex/blob/rust-v0.164.0/sdk/python/docs/faq.md)

**OpenAI Agents SDK** manages general agent loops, tools, handoffs, and sessions. Its usual OpenAI-model path requires API credentials, not the user's existing Codex ChatGPT session. An experimental Codex tool can wrap the CLI, so saying the SDK can never use Codex login would also be inaccurate. That wrapper still adds an orchestration runtime around the same CLI and provides no necessary benefit for 99's one-shot provider. Choose it only if the product later needs a separate orchestrator agent. [Agents SDK quickstart](https://openai.github.io/openai-agents-python/quickstart/), [experimental Codex tool](https://openai.github.io/openai-agents-python/tools/#experimental-codex-tool)

The migration path is therefore native exec now, an internal result/observer contract shared with other providers, and a separate app-server implementation when interactive behavior justifies it. No mandatory SDK or new API key is needed.

## Focused verification

Use fake executables and headless Neovim with isolated configuration. No live model calls are needed for these checks:

- Verify argv, exact stdin bytes, captured cwd, paths containing spaces, and a large multiline prompt that would be unsuitable for argv.
- Cover explicit and omitted models, non-Git directories, all four operation sandbox choices, and the final-response prompt contract.
- Make the stub emit misleading stdout, write a different `-o` payload, and exit zero. Only the file payload may reach the operation.
- Cover spawn failure, nonzero exit, missing output, empty output policy, and partial diagnostic chunks.
- Cancel before output, during output, and after exit but before the scheduled result read. Assert one terminal callback and no buffer application after cancellation.

Existing `lua/99/test/providers_spec.lua` mainly checks command arrays, defaults, setup, and stored extra args. Those tests do not establish process I/O, output extraction, or cancellation behavior. The upstream Codex release has output-processor tests, including failure behavior, but those do not replace 99's integration tests.

Scratch evidence is under `/tmp/99-codex-research.SZvJJ2`: official source tag `rust-v0.164.0`, generated installed-CLI schemas, and the offline bundled model catalog. The tag resolves to commit `6aaac694803004a63c6f393d153c96d22521a6b9`. The research and fake-CLI checks made no model calls. The parent separately reported a successful live synthetic visual test in a non-Git directory, with the exact buffer replacement and no disk write.

# 99, Filip's fork

A personal fork of [ThePrimeagen/99](https://github.com/ThePrimeagen/99) with Codex as the default provider and fixes for request handling, visual edits, and context discovery.

Requires Neovim 0.11.5 or newer and the Codex CLI. Run `codex login` once, then use the setup below. An existing Codex ChatGPT login works. No separate API key or SDK is required. The integration was developed against Codex CLI 0.164.0.

See the [Codex integration decision](docs/codex-integration-research.md) and [audit record](docs/audit/README.md) for evidence and limits. This fork is experimental. Review generated edits before saving or committing them.

___DOCS___

## Context references

Use `@` to reference project files and `#` to reference configured rules. Native completion is the default. `cmp` and `blink` are optional alternatives.

Completion quotes paths that contain spaces, such as `@"My Note.md"`. Set `completion.files.enabled = false` to disable file references. Discovered file references must stay inside their project root after resolving symlinks. This restriction applies to 99's context collection, not to the Codex runtime's own read access.

## Providers

| Provider | CLI | Default model |
| --- | --- | --- |
| `CodexProvider` | `codex` | Your Codex configuration |
| `OpenCodeProvider` | `opencode` | `opencode/claude-sonnet-4-5` |
| `ClaudeCodeProvider` | `claude` | `claude-sonnet-4-5` |
| `CursorAgentProvider` | `cursor-agent` | `sonnet-4.5` |
| `KiroProvider` | `kiro-cli` | `claude-sonnet-4.5` |
| `GeminiCLIProvider` | `gemini` | `auto` |

Set `provider` to choose another backend. Set `model` to override its default. For Codex, `model = "default"` restores the CLI's configured model.

Codex receives the prompt over stdin and writes its final response through `--output-last-message`. This works in ordinary folders, including Obsidian vaults without Git. Each request is ephemeral and has a five-minute deadline. Set `request_timeout` in milliseconds to change the deadline, and `max_response_bytes` to change the 4 MiB response limit.

Visual, search, and tutorial requests use `read-only`. Vibe uses `workspace-write`. Codex runs without interactive approval prompts, so denied actions fail instead of waiting for terminal input. Its configured instructions, MCP servers, and other tools still apply. Read-only does not prevent access to every readable file or disable external tools.

`provider_extra_args` is advanced, trusted configuration. Codex accepts supported configuration flags and explicit sandbox overrides, but rejects arguments that replace its response transport or prompt. A sandbox override changes the permissions described above. Other providers retain their own permission models. Claude, Cursor, and Kiro no longer receive permission-bypass flags automatically.

## Pickers

With Telescope installed, use `require("99.extensions.telescope").select_provider()` or `.select_model()`. With fzf-lua, use `require("99.extensions.fzf_lua")` instead. Provider switching resets the selected model.

## Maintenance

The Git remote `upstream` points to ThePrimeagen/99. Keep upstream updates separate from feature changes so they can be reviewed and tested before adoption.

Run `make pr_ready` for lint, tests, formatting, and the documented setup check. Run `make docs_check` with Node.js 22.6 or newer to verify generated documentation. After changing API comments, regenerate both documentation files:

```sh
node --experimental-strip-types docs/src/generate.ts
./gen-docs
```

The implementation keeps successful history in the configured `tmp_dir`, which defaults to `./tmp` resolved at setup. Temporary request directories are private and removed on completion or cancellation. History and diagnostic logs can contain prompt text, file contents, and model responses. Review them before sharing. View in-memory request logs with `:lua require("99").view_logs()`. For rejected visual edits, this view also includes the full unapplied response while the request remains in history.

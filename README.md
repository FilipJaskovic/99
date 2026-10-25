# 99, Filip's fork

A personal fork of [ThePrimeagen/99](https://github.com/ThePrimeagen/99) with Codex as the default provider and fixes for request handling, visual edits, and context discovery.

Requires Neovim 0.11.5 or newer and the Codex CLI. Run `codex login` once, then use the setup below. An existing Codex ChatGPT login works. No separate API key or SDK is required. The integration was developed against Codex CLI 0.164.0.

See the [Codex integration decision](docs/codex-integration-research.md) and [audit record](docs/audit/README.md) for evidence and limits. This fork is experimental. Review generated edits before saving or committing them.

# 99
The AI Neovim experience

## _99
This fork uses Codex for visual replacements, project searches, tutorials,
and workspace edits. It requires Neovim 0.11.5 or newer and a signed-in
Codex CLI. The integration was developed against Codex CLI 0.164.0.

### Basic setup
```lua
{
	"FilipJaskovic/99",
	config = function()
		local _99 = require("99")
		_99.setup({
			provider = _99.Providers.CodexProvider,
			-- Omit model to use your Codex CLI configuration.
			completion = { source = "native" },
			md_files = { "AGENTS.md" },
		})
		vim.keymap.set("x", "<leader>9v", _99.visual)
		vim.keymap.set("n", "<leader>9s", _99.search)
		vim.keymap.set("n", "<leader>9x", _99.stop_all_requests)
	end,
}
```

### Usage
Select text and run `visual()` to request a replacement. The replacement
applies only if the source buffer has not changed since capture.
`search()` returns locations in the quickfix list. `tutorial()` opens a
Markdown explanation. `vibe()` lets Codex edit files in the workspace.
Visual, search, and tutorial requests use the read-only Codex sandbox.
Vibe uses workspace-write. Codex also loads its own configuration and tools.

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `setup` | `fun(opts?: _99.Options): nil` | - |
| `search` | `fun(opts: _99.ops.SearchOpts): _99.TraceID` | - |
| `vibe` | `fun(opts?: _99.ops.Opts): _99.TraceID \| nil` | - |
| `open` | `fun(): nil` | - |
| `visual` | `fun(opts: _99.ops.Opts): _99.TraceID` | - |
| `view_logs` | `fun(): nil` | - |
| `stop_all_requests` | `fun(): nil` | - |
| `clear_previous_requests` | `fun(): nil` | - |
| `Extensions` | `_99.Extensions` | - |

### API

#### setup
Sets up _99.  Must be called for this library to work.  This is how we setup
in flight request spinners, set default values, get completion to work the
way you want it to.

#### search
Performs a search across your project with the prompt you provide and return out a list of
locations with notes that will be put into your quick fix list.

#### vibe
will ask opencode or whatever provider currently being used to perform a vibe
session.

#### open
Opens a selection window for you to select the last interaction to open
and display its contents in a way that makes sense for its type.  For
search and vibe, it will open the qfix window.  For tutorial, it will open
the tutorial window.

#### visual
takes your current selection and sends that along with the prompt provided and replaces
your visual selection with the results

#### view_logs
view_logs allows you to select the request you want to see and then you
get to see the logs.

#### stop_all_requests
stops all in flight requests.  this means that the underlying process will
receive a termination signal, and late results are discarded

#### clear_previous_requests
clears all previous search and visual operations

#### Extensions
check out Worker for cool abstraction on search and vibe

## _99.Extensions.Worker
A persistent way to keep track of work.

this will likely be where the most change and focus goes into.  I would like
to take this into worktree territory and be able to swap between stuff super
slick.

Until then, it is going to be a single bit of work that you can provide
the description and then use search to find what is left that needs to be done.

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `set_work` | `fun(opts?: _99.WorkOpts): nil` | - |
| `search` | `fun(): nil` | - |

### API

#### set_work
will set the work for the project.  If opts provide a description then no
input capture of work description will be required

#### search
will use _99.search to find what is left to be done for this work item to be
considered done

## _99.Options
No description.

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `logger` | `_99.Logger.Options \| nil` | - |
| `model` | `string \| nil` | - |
| `in_flight_options` | `_99.StatusWindow.Opts \| nil` | - |
| `md_files` | `string[] \| nil` | - |
| `provider` | `_99.Providers.BaseProvider \| nil` | - |
| `provider_extra_args` | `string[] \| nil` | - |
| `display_errors` | `boolean \| nil` | - |
| `completion` | `_99.Completion \| nil` | - |
| `tmp_dir` | `string \| nil` | - |
| `request_timeout` | `number \| nil` | - |
| `max_response_bytes` | `number \| nil` | - |

### API

#### logger
No description.

#### model
No description.

#### in_flight_options
No description.

#### md_files
No description.

#### provider
No description.

#### provider_extra_args
No description.

#### display_errors
No description.

#### completion
No description.

#### tmp_dir
No description.

#### request_timeout
Request deadline in milliseconds. Default: 300000.

#### max_response_bytes
Maximum response file size. Default: 4194304.

## _99.State.Tracking
No description.

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `history` | `_99.Prompt[]` | - |
| `id_to_request` | `table<number, _99.Prompt>` | - |
| `setup` | `fun(opts: _99.State.Tracking.Config.Options): nil` | - |

### API

#### history
No description.

#### id_to_request
No description.

#### setup
No description.

## _99.ops.Opts
The options that are used throughout all the interations with 99.  This
includes search, visual, and others

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `additional_prompt` | `string \| nil` | - |
| `additional_rules` | `_99.Agents.Rule[] \| nil` | - |

### API

#### additional_prompt
by providing `additional_prompt` you will not be required to provide a prompt.
this allows you to define actions based on remaps

```lua
remap("n", "<leader>9d", function()
  --- this function could be used to auto debug your project
  _99.search({
    additional_prompt = [[
run `make test` and debug the test failures and provide me a comprehensive set of steps where
the tests are breaking ]]
  })
end)
```

This would kick off a search job that will run your tests in the background.
the resulting failures would be diagnosed and search results would be transfered
into a quick fix list.

#### additional_rules
can be used to provide extra args.  If you have a skill called "cloudflare" you could
provide the rule for cloudflare and its context will be injected into your request

## _99.ops.SearchOpts
See `_99.opts.Opts` for more information.

There are no properties yet.  But i would like to tweek some behavior based on opts

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| - | - | - |

### API
No properties.

## _99.WorkOpts
No description.

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `description` | `string \| nil` | - |

### API

#### description
No description.

## _99.Completion
No description.

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `source` | `"native" \| "cmp" \| "blink" \| nil` | - |
| `custom_rules` | `string[]` | - |
| `files` | `_99.Files.Config?` | - |

### API

#### source
No description.

#### custom_rules
No description.

#### files
No description.

## _99.Logger.Options
No description.

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `level` | `number?` | - |
| `type` | `"print" \| "void" \| "file" \| nil` | - |
| `path` | `string?` | - |
| `print_on_error` | `boolean \| nil` | - |
| `max_requests_cached` | `number \| nil` | - |

### API

#### level
No description.

#### type
No description.

#### path
No description.

#### print_on_error
No description.

#### max_requests_cached
No description.

## _99.StatusWindow.Opts
this is pure a class for testing.   helps controls timings

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `throbber_opts` | `_99.Throbber.Opts \| nil` | - |
| `in_flight_interval` | `number \| nil` | - |
| `enable` | `boolean \| nil` | - |

### API

#### throbber_opts
options for the throbber in the top left

#### in_flight_interval
frequency in which the in-flight interval checks to see if it should be
displayed / removed

#### enable
defaults to true

## _99.Agents.Rule
No description.

### Description
| Name | Type | Default Value |
| --- | --- | --- |
| `name` | `string` | - |
| `path` | `string` | - |
| `absolute_path` | `string?` | - |
| `root` | `string?` | - |

### API

#### name
No description.

#### path
No description.

#### absolute_path
No description.

#### root
Configured directory used to confine reads

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

The implementation keeps successful history in the configured `tmp_dir`, which defaults to `./tmp` resolved at setup. Temporary request directories are private and removed on completion or cancellation. History and diagnostic logs can contain prompt text, file contents, and model responses. Review them before sharing. View in-memory request logs with `:lua require("99").view_logs()`.

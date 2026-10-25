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
	branch = "codex-and-audit",
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

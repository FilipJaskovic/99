# Final spec review

Reviewed `git diff c17422457027c913c76c75a921fca1e623d2678e...a1b9e2f`, comprising `a1b9e2f feat: use Codex and harden requests, edits, and context`. Read `AGENTS.md`, the audit scope, and the Codex recommendation. Accepted documented limits were excluded from findings.

## P2: Unavailable completion adapters leave previous file permissions active

Spec, `docs/audit/README.md:11`: "Context references must honor disable and exclusion options, resolve exact filenames, and remain inside the intended project."

Sources: `lua/99/extensions/init.lua:60-65`, `:80-86`, and `lua/99/extensions/native.lua:145-151`. File configuration and reference-provider registration happen inside adapter initialization. If adapter discovery fails, setup continues without updating either. Previously registered file references retain the previous configuration.

Reproduced against `a1b9e2f`: initialize native completion, then call `setup()` with `completion = { source = "blink", files = { enabled = false } }` while `blink.compat` is unavailable. Submit a search containing `@private.txt`. The controlled provider receives the file's `PRIVATE_MARKER` content despite the new disabled setting. The dependency warning does not stop the request. This leaves the disable requirement partially fixed across reconfiguration.

Configure file policy and register context providers independently of the optional completion adapter, or prevent requests after adapter initialization fails. Verify that unavailable adapters cannot retain earlier enable or exclusion settings.

Reproduction uses synthetic files and a controlled provider, with no model calls:

```sh
nvim --headless --noplugin -u NONE -i NONE -l /tmp/99-final-spec-repro.lua
```

No other actionable Spec findings were verified in the bounded review of Codex invocation and response wiring, captured context, visual edit boundaries, and UI lifecycle handoffs. The parent's later test-only timing change was outside this pinned review. No source or configuration files were changed.

## Resolution verified

Independently verified the parent's subsequent working-tree fix. Core `Extensions.init` now applies file policy and registers reference providers before optional adapter discovery. `Extensions.refresh` also registers providers independently. Removing duplicate adapter responsibilities leaves native buffer setup and cmp source registration intact. No regression was identified in this change.

The original reproduction passes with its expectation inverted in `/tmp/99-final-spec-fixed.lua`: disabled content stays absent. The corrected `completion_adapters_spec.lua` suite passes all seven tests, including enabled controls, disabled files, and exclusions with missing cmp, missing Blink, and an unknown source. The initial completion-count assertion incorrectly included a legitimate state file and was corrected by the parent. No unresolved Spec findings remain from this review.

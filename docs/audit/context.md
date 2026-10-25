# Context discovery audit

Audited `codex-and-audit` at `c17422457027c913c76c75a921fca1e623d2678e`. This report covers file and rule extensions, completion resolution, and automatic Markdown context. Each finding below was reproduced locally. No live model calls were made.

## Resolution after implementation

The finding descriptions and line numbers below describe the baseline. The owned discovery and reference changes resolve C1-C9, C11, and C12. C10 belongs to the process agent's separate `prompt.lua` change and is outside this patch's verification claim.

- File reads check the current real path, directory boundary, exclusions, regular-file type, open-file identity, and byte limit. Links to allowed files inside the root work. External and excluded targets fail closed, including links retargeted after discovery.
- Exclusions match whole path components. `*` and `?` are the supported wildcard operators. Other pattern characters are literal. Configuration resets on setup and does not mutate the caller's exclusion list.
- Disabled file completion supplies no candidates or content. Real Git discovery uses argument-vector execution and NUL-delimited output without trimming. Git errors return no candidates rather than bypassing ignore rules with a filesystem scan.
- The recursive result cap applies before each insertion. Exact paths win over basename shortcuts. Ambiguous basenames and ambiguous bare rule names are rejected.
- Request refresh captures the current discovery root and invalidates the scan, including an empty scan. Explicit request cwd and rule snapshots passed through `make-prompt.lua` keep pending references independent of later global refreshes. Git subdirectory requests retain Git-root file paths and cwd-relative skill discovery.
- Completion insertion and parsing share JSON quotes, for example `@"My Note.md"`. Quotes, backslashes, tabs, and newlines round-trip. Unterminated or invalid quotes resolve no content. Repeated identical references are included once, in prompt order.
- Discovered rules are confined to the configured rule directory. Full rule reads have a 100 KiB limit, and previews read at most 4,096 bytes before applying the line limit. Skill discovery no longer interpolates configured paths into glob expressions.

The focused suites now pass 40 tests: 14 real-fixture discovery tests, 11 existing file tests, three existing agent tests, and 12 completion tests. The 12 former Git mocks supplied already-decoded newline output and fake filesystem metadata. Real Git fixtures now cover their meaningful contracts, including ordinary repositories, gitdir files, tracked and untracked files, empty results, caching, exclusion behavior, and failure handling. Filename and confinement regressions exercise the actual filesystem rather than those mocks.

Owned source and test files pass LuaCheck with zero warnings, StyLua's format check, and `git diff --check`. The root agent owns the aggregate readiness run.

Remaining limits are explicit. Git discovery still buffers the repository's path list before applying the result cap, with a ten-second process wait limit. Filesystem scans and rule previews remain synchronous. The cache refreshes at the next request rather than watching every filesystem event. A file or ignore rule changed while an existing prompt is open can therefore require a new refresh. There is no aggregate context-byte budget. Rule files above 100 KiB are omitted, and previews can truncate a long line. Explicitly configured rule directories can be outside the project, but discovered rules cannot escape their configured directory. General concurrent filesystem races are not eliminated by real-path and open-file identity checks.

## Findings

### C1. P1: A Git-discovered symlink bypasses exclusions and the project boundary

Sources: `lua/99/extensions/files/init.lua:103-118`, `:250-271`, and `:349-359`.

In a Git repository, create `notes.txt` as a symlink to an external `.env`. Git discovery accepts the link's innocuous name. `fs_stat` and `fs_open` then follow its target without checking the real path, the target's exclusions, or its file type. Parsing `@notes.txt` returned the synthetic secret from outside the project. An ordinary in-project `.env` reference was rejected under the fixture's `.gitignore` and default exclusions.

An apparently ordinary project reference can therefore attach sensitive external content to the prompt. A link retargeted after discovery has the same unchecked read path. The non-Git scanner skips symlink entries, so behavior also differs between scanners.

Focused regression: reference an in-repository link to an external synthetic `.env` and expect rejection. Check containment and file type at read time, including a link retargeted after discovery.

### C2. P1: Literal characters in exclusions can expose excluded files or abort discovery

Source: `lua/99/extensions/files/init.lua:39-46`.

The conversion escapes dots and expands stars but leaves other Lua pattern operators active. With `exclude = { "secrets-prod" }`, `secrets-prod/key.txt` remained discoverable and `@secrets-prod/key.txt` attached its content. Lua interprets the hyphen as a repetition operator. With `exclude = { "[" }`, discovery raised `malformed pattern (missing ']')`.

This affects configured exclusions and rule-directory paths appended by `setup` at `:314-318`. A valid directory name can silently defeat an exclusion or break completion and prompt preparation.

Focused regression: use literal directory names containing `-`, `[`, `+`, and `%`, plus the supported `*` wildcard. Excluded content must remain unavailable, and valid configuration must not raise pattern errors.

### C3. P1: A cwd change keeps resolving files from the previous project

Sources: `lua/99/init.lua:462-464`, `lua/99/extensions/init.lua:64-67`, `:80-85`, and `lua/99/extensions/native.lua:153-154`.

The project root is captured during setup. Rule refresh re-registers providers without updating that root. After initialization in project A, changing cwd to project B and refreshing still made `@same.lua` attach A's content. Both projects contained a different `same.lua`. This reproduction used the real extension initialization, refresh, and completion parser.

Users who change projects in one Neovim session can send content from the previous project while working in the new one. `README.md:99-100` already warns that cwd changes are broken. The concrete cross-project resolution is verified here.

Focused regression: initialize in A, switch to B, refresh, and parse the same relative filename. Test `:cd`, `:lcd`, and separate pending requests. Capture the intended root per request so later changes cannot redirect its references.

### C4. P2: `files.enabled = false` has no effect

Sources: `lua/99/extensions/files/init.lua:305`, `:328-354`, `lua/99/extensions/native.lua:32-34`, and `lua/99/extensions/cmp.lua:85-87`.

`setup` stores `config.enabled`, but no discovery or resolution code reads it. Both completion integrations register the file provider unconditionally. With `enabled = false`, a fixture file still appeared in completion and `@plain.txt` still attached its content.

Focused regression: initialize each completion integration with file completion disabled. Assert that it offers no file items and resolves no `@` references, while rule references still work.

### C5. P2: An exact root-relative path can resolve to another file's basename

Source: `lua/99/extensions/files/init.lua:291-295`.

With `a/main.lua` and root-level `main.lua`, sorted discovery puts `a/main.lua` first. `get_project_file("main.lua")` returns that entry because basename matching runs in the same first-match pass as exact path matching. Consequently, selecting the completion item whose `insertText` is `@main.lua` attaches `a/main.lua`.

This is deterministic but selects the wrong file even when the prompt contains an exact discovered path.

Focused regression: resolve both completion items in this fixture and verify each file's distinct content. Exact paths must win before basename fallback. Ambiguous bare basenames need an explicit policy.

### C6. P2: Cached discovery misses new files and keeps newly ignored files available

Sources: `lua/99/extensions/files/init.lua:208-212`, `:279-295`, and `lua/99/extensions/native.lua:153-154`.

Once the cache is nonempty, `get_files` never rescans. After the first scan, creating `new.txt` and adding the existing `old.txt` to `.gitignore` left `@new.txt` unresolved and `@old.txt` available. An explicit `discover_files()` immediately corrected both results. Normal rule refresh does not call it, and no file or ignore-change invalidation exists.

This produces stale completion and continues attaching a file after the user has excluded it with Git ignore rules.

Focused regression: scan an untracked file, change `.gitignore`, create another file, and use the normal next-request refresh path. Verify both invalidation cases without directly calling the scan implementation.

### C7. P2: Bare rule names validate successfully but never resolve

Sources: `lua/99/extensions/agents/init.lua:60-75`, `:152-160`, and `lua/99/ops/make-prompt.lua:18`.

For `skills/debug/SKILL.md`, `is_rule(rules, "debug")` returns true. The completion provider then calls `get_rule_by_path`, which accepts only the full path. `Completions.parse("#debug")` returned no references, while `#skills/debug/SKILL.md` returned the rule. The separate `Agents.by_name` implementation is not used by prompt construction.

An accepted rule shorthand silently omits its instructions. `agents_spec.lua:114-141` tests name validation without exercising resolution.

Focused regression: parse the bare name through the real provider and prompt builder. Cover duplicate names in two configured rule directories and define whether both resolve or ambiguity is rejected.

### C8. P2: Git's quoted output and whitespace trimming corrupt filenames

Source: `lua/99/extensions/files/init.lua:86-108`.

Discovery parses newline-delimited `git ls-files` output without `-z`, then trims each record. Under Git's default quoting, `café.lua` became the literal path `"caf\303\251.lua"`, which does not exist. A file named ` leading.lua` became `leading.lua`. The Unicode reference did not resolve.

Completion can therefore display unusable entries or omit valid project context. Names with tabs, newlines, and quotes use the same quoted-output mechanism.

Focused regression: create actual Git fixtures with Unicode, leading and trailing spaces, tabs, quotes, and newlines. Preserve exact filename bytes with NUL-delimited Git output and no trimming.

### C9. P2: Completion inserts paths containing spaces that the parser cannot consume

Sources: `lua/99/extensions/files/init.lua:334`, `lua/99/extensions/agents/init.lua:143`, and `lua/99/extensions/completions.lua:58-60`.

For `space name.lua`, the file provider can resolve the full path and offers `@space name.lua`. The parser's `%S+` tokenization reads only `space`, so parsing the inserted completion returned no references. Rule paths containing spaces have the same tokenization problem.

Focused regression: select an item whose path contains spaces and pass its exact inserted text to the parser. Add a supported quoting or escaping syntax that both insertion and parsing implement.

### C10. P2: Automatic Markdown discovery treats sibling path prefixes as descendants

Source: `lua/99/prompt.lua:412-436`.

The ancestor loop checks `dir:find(cwd, 1, true) == 1` without a directory boundary. With cwd `/tmp/.../prefix-project` and an originating buffer `/tmp/.../prefix-project-private/file.lua`, `_read_md_files` attached the sibling project's `AGENT.md`.

The configured project boundary therefore admits unrelated sibling instructions. The loop also reads complete files and follows symlinks without a byte limit or a real-path boundary check.

Focused regression: use adjacent `project` and `project-private` directories with distinct instruction markers. Assert no sibling content is attached. Also cover an instruction-file symlink outside the root and cwd changes between context creation and finalization.

### C11. P2: Recursive filesystem scanning exceeds `max_files`

Source: `lua/99/extensions/files/init.lua:155-190`.

With no Git repository, `max_files = 1`, and files `a/aa.txt` and `z.txt`, discovery returned both files. A recursive call consumes the budget, but the parent resumes its loop without checking the count before inserting the next file. Each returning ancestor can exceed the limit again.

Focused regression: scan a nested directory plus a later sibling file with limits of one and two. Assert the total never exceeds the configured limit, irrespective of traversal order.

### C12. P2: Rule previews synchronously read complete files without a byte bound

Sources: `lua/99/extensions/agents/helpers.lua:51-80` and `lua/99/extensions/agents/init.lua:136-146`.

Every rule-completion request calls `helpers.head` for every rule. That function reads `stat.size` bytes before selecting the first five lines. Instrumenting the real `fs_read` call for a one-line, 200,009-byte fixture confirmed a 200,009-byte read even with `count = 1`. The returned preview was also over 200 KB because line count does not bound bytes.

A large rule collection can block Neovim and allocate all rule contents whenever completion opens. Full rule resolution at `agents/init.lua:115-127` also has no size limit. `files.max_file_size` applies only to the separate file extension.

Focused regression: instrument preview reads for a large multiline file and a single oversized line. Assert a fixed byte budget as well as a line limit. Give full rule inclusion an explicit size policy.

## Verification and limits

The existing `files_spec.lua`, `agents_spec.lua`, and `completions_spec.lua` suites passed all 35 tests. They ran against a disposable archive of the baseline under `/tmp/99-context-audit.LiT4Y1/snapshot`, using `PlenaryBustedFile` and the repository's minimal init. These suites do not cover the failing cases above.

The separate reproduction script is `/tmp/99-context-audit.LiT4Y1/repro.lua`, with results in `/tmp/99-context-audit.LiT4Y1/repro.log`. It creates fresh synthetic fixtures per run. Reproduction command:

```sh
nvim --headless --noplugin -u NONE -i NONE -l /tmp/99-context-audit.LiT4Y1/repro.lua
```

The script exited successfully after asserting the reported failures. It also checked that direct `@../outside/.env` and `@.env` references are rejected through the normal parser. `read_file` itself accepts absolute and parent-relative paths, but the standard provider first requires a discovered project entry. C1 describes the verified way around that guard.

Ordinary discovery results are sorted. The main deterministic-selection failure is C5. File reads enforce the configured per-file byte limit, but discovery does not filter oversized files from completion. There is no aggregate context budget or reference deduplication in `Completions.parse`.

The original audit wrote only `docs/audit/context.md`. The implementation subsequently changed the owned file, rule, completion, extension-refresh, and prompt-builder modules and their targeted tests. No installed Neovim configuration, real user notes, commits, pushes, or pull requests were changed.

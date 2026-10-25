-- luacheck: globals describe it assert before_each after_each
local Files = require("99.extensions.files")
local Agents = require("99.extensions.agents")
local Helpers = require("99.extensions.agents.helpers")
local Completions = require("99.extensions.completions")
local Extensions = require("99.extensions")
local make_prompt = require("99.ops.make-prompt")
-- The minimal init uses a relative runtimepath. Load the source before changing cwd.
require("99.extensions.native")
local eq = assert.are.same

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path, "b")
end

local function git(...)
  local result = vim.system({ "git", ... }, { text = false }):wait()
  eq(0, result.code, result.stderr)
end

describe("context discovery with real fixtures", function()
  local root
  local cwd
  local function configure(path, opts)
    Files.setup(opts or {}, {})
    Files.set_project_root(path)
    Completions._reset()
    Completions.register(Files.completion_provider())
  end

  before_each(function()
    cwd = vim.fn.getcwd()
    local tmp = "/tmp/99-context-spec-" .. tostring(vim.uv.hrtime())
    vim.fn.mkdir(tmp, "p")
    root = vim.uv.fs_realpath(tmp)
    configure(root)
  end)

  after_each(function()
    vim.api.nvim_set_current_dir(cwd)
    Completions._reset()
    Files.setup({}, {})
    Files.set_project_root("")
    vim.fn.delete(root, "rf")
  end)

  it(
    "confines reads and rechecks symlink targets after discovery in both scanners",
    function()
      for _, use_git in ipairs({ false, true }) do
        local project = root .. (use_git and "/git" or "/plain")
        write(project .. "/safe.txt", "SAFE")
        write(project .. "/.env", "INSIDE_SECRET")
        write(root .. "/outside/.env", "OUTSIDE_SECRET")
        if use_git then
          git("init", "-q", project)
        end
        assert(
          vim.uv.fs_symlink(root .. "/outside/.env", project .. "/outside.txt")
        )
        assert(vim.uv.fs_symlink(project .. "/.env", project .. "/hidden.txt"))
        assert(
          vim.uv.fs_symlink(project .. "/safe.txt", project .. "/link.txt")
        )
        configure(project)
        local provider = Files.completion_provider()
        assert.is_nil(provider.resolve("outside.txt"))
        assert.is_nil(provider.resolve("hidden.txt"))
        assert.is_not_nil(provider.resolve("link.txt"))
        eq(nil, Files.read_file("../outside/.env"))
        eq(nil, Files.read_file(root .. "/outside/.env"))
        assert(vim.uv.fs_unlink(project .. "/link.txt"))
        assert(
          vim.uv.fs_symlink(root .. "/outside/.env", project .. "/link.txt")
        )
        assert.is_nil(provider.resolve("link.txt"))
      end
    end
  )

  it("rechecks directory links, file type, and size after discovery", function()
    write(root .. "/project/sub/note.md", "BEFORE")
    write(root .. "/outside/note.md", "OUTSIDE")
    configure(root .. "/project", { max_file_size = 8 })
    Files.discover_files()
    assert(vim.uv.fs_rename(root .. "/project/sub", root .. "/project/old"))
    assert(vim.uv.fs_symlink(root .. "/outside", root .. "/project/sub"))
    eq(nil, Files.completion_provider().resolve("sub/note.md"))
    write(root .. "/project/old/note.md", "TOO_LARGE_FOR_LIMIT")
    eq(nil, Files.read_file("old/note.md"))
    eq(nil, Files.read_file("old"))
  end)

  it(
    "matches literal exclusion characters and whole components without mutating options",
    function()
      local names = { "secrets-prod", "[", "a+b", "percent%", ".env", "build" }
      for _, name in ipairs(names) do
        write(root .. "/" .. name .. "/key.txt", "SECRET")
      end
      write(root .. "/builder.js", "BUILDER")
      write(root .. "/.github/workflows/test.yml", "WORKFLOW")
      write(root .. "/nested/skip.log", "LOG")
      local exclusions =
        vim.list_extend(vim.deepcopy(names), { ".git", "*.log" })
      configure(root, { exclude = exclusions })
      local files = Files.discover_files()
      eq(2, #files)
      eq(".github/workflows/test.yml", files[1].path)
      eq("builder.js", files[2].path)
      eq(8, #exclusions)
      git("init", "-q", root)
      eq(files, Files.discover_files())
      Files.setup({}, {})
      assert.is_true(Files.is_project_file("builder.js"))
    end
  )

  it(
    "honors disabled file references and resets configuration on setup",
    function()
      write(root .. "/note.md", "DO_NOT_ATTACH")
      configure(root, { enabled = false })
      eq({}, Files.get_files())
      eq({}, Completions.get_completions("@"))
      eq({}, Completions.parse("@note.md", root))
      eq(nil, Files.read_file("note.md"))
      Files.setup({}, {})
      eq(1, #Completions.parse("@note.md", root))
    end
  )

  it(
    "round-trips actual Git NUL filenames through completion insertion",
    function()
      git("init", "-q", root)
      local names = {
        "café.md",
        'a"b.md',
        " leading.md",
        "trailing.md ",
        "tab\tname.md",
        "line\nbreak.md",
        "back\\slash.md",
        "My Note.md",
      }
      for index, name in ipairs(names) do
        write(root .. "/" .. name, "CONTENT_" .. index)
      end
      configure(root)
      local items = Completions.get_completions("@")
      eq(#names, #items)
      for _, item in ipairs(items) do
        local refs = Completions.parse(item.insertText, root)
        eq(1, #refs, item.insertText)
        local expected = Files.read_file(item.detail)
        assert.is_truthy(refs[1].content:find(expected, 1, true))
      end
    end
  )

  it(
    "keeps Git-root file paths and cwd-relative rules correct from subdirectories",
    function()
      git("init", "-q", root)
      write(root .. "/top.md", "TOP")
      write(root .. "/sub/note.md", "SUB")
      write(root .. "/sub/skills/debug/SKILL.md", "SUB_RULE")
      vim.api.nvim_set_current_dir(root .. "/sub")
      local state = { completion = { custom_rules = { "skills" } }, rules = {} }
      state.rules = Agents.rules(state, root .. "/sub")
      Extensions.init(state)
      Extensions.refresh(state, root .. "/sub")
      eq(root, Files.get_project_root())
      eq(root, Files.project_root(root .. "/sub"))
      local refs = Completions.parse(
        "@top.md @sub/note.md #debug",
        root .. "/sub",
        state.rules
      )
      eq(3, #refs)
      assert.is_truthy(refs[1].content:find("TOP", 1, true))
      assert.is_truthy(refs[2].content:find("SUB", 1, true))
      assert.is_truthy(refs[3].content:find("SUB_RULE", 1, true))
      assert.is_false(Files.is_project_file("sub/skills/debug/SKILL.md"))
    end
  )

  it(
    "handles empty Git roots and caches scans until the next refresh",
    function()
      git("init", "-q", root)
      eq({}, Files.get_files())
      local empty = Files.get_files()
      assert.is_true(empty == Files.get_files())
      write(root .. "/tracked.md", "TRACKED")
      git("-C", root, "add", "tracked.md")
      Files.discover_files()
      eq(1, #Files.get_files())
      local cached = Files.get_files()
      assert.is_true(cached == Files.get_files())
      write(root .. "/new.md", "NEW")
      eq(cached, Files.get_files())
      local refreshed = Files.discover_files()
      eq(2, #refreshed)
      eq("new.md", refreshed[1].path)
      eq("tracked.md", refreshed[2].path)
      Files.set_project_root("")
      eq({}, Files.discover_files())
      eq(nil, Files.read_file("tracked.md"))
    end
  )

  it(
    "supports Git worktree-style gitdir files without a filesystem fallback",
    function()
      git(
        "init",
        "-q",
        "--separate-git-dir",
        root .. "/git-dir",
        root .. "/project"
      )
      write(root .. "/project/visible.md", "VISIBLE")
      write(root .. "/project/.gitignore", "ignored.md")
      write(root .. "/project/ignored.md", "IGNORED")
      configure(root .. "/project")
      assert.is_true(Files.is_project_file("visible.md"))
      assert.is_false(Files.is_project_file("ignored.md"))
      vim.fn.delete(root .. "/git-dir", "rf")
      eq({}, Files.discover_files())
    end
  )

  it(
    "enforces file caps after recursive scans and on real Git output",
    function()
      write(root .. "/a/x.md", "X")
      write(root .. "/z.md", "Z")
      for _, use_git in ipairs({ false, true }) do
        if use_git then
          git("init", "-q", root)
        end
        for _, limit in ipairs({ 0, 1, 2 }) do
          configure(root, { max_files = limit })
          eq(limit, #Files.discover_files())
        end
      end
    end
  )

  it("prefers exact paths and rejects ambiguous basename shortcuts", function()
    write(root .. "/a/main.lua", "NESTED")
    write(root .. "/b/main.lua", "OTHER")
    write(root .. "/main.lua", "ROOT")
    eq("main.lua", Files.get_project_file("main.lua").path)
    eq("a/main.lua", Files.get_project_file("a/main.lua").path)
    assert(vim.uv.fs_unlink(root .. "/main.lua"))
    Files.discover_files()
    eq(nil, Files.get_project_file("main.lua"))
  end)

  it(
    "invalidates discovery and Git ignore changes on normal request refresh",
    function()
      git("init", "-q", root)
      write(root .. "/old.md", "OLD")
      local state =
        { completion = { custom_rules = {} }, rules = { custom = {} } }
      Extensions.init(state)
      Extensions.refresh(state, root)
      assert.is_true(Files.is_project_file("old.md"))
      write(root .. "/new.md", "NEW")
      write(root .. "/.gitignore", "old.md")
      Extensions.refresh(state, root)
      assert.is_true(Files.is_project_file("new.md"))
      assert.is_false(Files.is_project_file("old.md"))
    end
  )

  it(
    "keeps captured file and rule references independent of later cwd and state",
    function()
      local first, second = root .. "/a", root .. "/b"
      for _, project in ipairs({ first, second }) do
        write(project .. "/same.md", project)
        write(project .. "/skills/debug/SKILL.md", project .. "_RULE")
      end
      local state = { completion = { custom_rules = { "skills" } }, rules = {} }
      state.rules = Agents.rules(state, first)
      local snapshot = vim.deepcopy(state.rules)
      Extensions.init(state)
      Extensions.refresh(state, first)
      local context = {
        cwd = first,
        rules = snapshot,
        _99 = {
          prompts = {
            prompts = {
              prompt = function(user)
                return user
              end,
            },
          },
        },
      }
      state.rules = Agents.rules(state, second)
      vim.api.nvim_set_current_dir(second)
      Extensions.refresh(state, second)
      local _, refs =
        make_prompt(context, "", { additional_prompt = "@same.md #debug" })
      eq(2, #refs)
      assert.is_truthy(refs[1].content:find(first, 1, true))
      assert.is_truthy(refs[2].content:find(first .. "_RULE", 1, true))
      local current = Completions.parse("@same.md #debug")
      assert.is_truthy(current[1].content:find(second, 1, true))
      assert.is_truthy(current[2].content:find(second .. "_RULE", 1, true))
      eq(second, Files.get_project_root())
    end
  )

  it(
    "confines configured rules, quotes spaced paths, and rejects ambiguous names",
    function()
      write(root .. "/skills/debug/SKILL.md", "DEBUG")
      write(root .. "/skills/My Skill/SKILL.md", "SPACED")
      write(root .. "/other/debug/SKILL.md", "OTHER")
      write(root .. "/outside/SKILL.md", "OUTSIDE")
      assert(vim.uv.fs_symlink(root .. "/outside", root .. "/skills/escape"))
      local state = { completion = { custom_rules = { "skills", "other" } } }
      state.rules = Agents.rules(state, root)
      eq(3, #state.rules.custom)
      Completions.register(Agents.completion_provider(state))
      eq({}, Completions.parse("#debug", root))
      for _, item in ipairs(Completions.get_completions("#")) do
        eq(1, #Completions.parse(item.insertText, root))
      end
      local rule = state.rules.custom[1]
      assert(vim.uv.fs_unlink(rule.absolute_path))
      assert(vim.uv.fs_symlink(root .. "/outside/SKILL.md", rule.absolute_path))
      eq(nil, Agents.get_rule_content(rule))
    end
  )

  it("bounds rule previews and full rule reads by bytes", function()
    write(root .. "/skills/large/SKILL.md", string.rep("X", 200000))
    local state = { completion = { custom_rules = { "skills" } } }
    local rule = Agents.rules(state, root).custom[1]
    eq(4096, #Helpers.head(rule.absolute_path, 1, rule.root))
    eq(nil, Agents.get_rule_content(rule))
    write(rule.absolute_path, "ONE\nTWO\nTHREE")
    eq("ONE\nTWO", Helpers.head(rule.absolute_path, 2, rule.root))
    assert.is_truthy(Agents.get_rule_content(rule):find("THREE", 1, true))
  end)
end)

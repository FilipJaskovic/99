lua_fmt:
	echo "===> Formatting"
	stylua lua/ scripts/tests/ --config-path=.stylua.toml

lua_fmt_check:
	echo "===> Checking format"
	stylua lua/ scripts/tests/ --config-path=.stylua.toml --check

lua_lint:
	echo "===> Linting"
	luacheck lua/ scripts/tests/ --globals vim

lua_test:
	echo "===> Testing"
	nvim --headless --noplugin -i NONE -u scripts/tests/minimal.vim \
        -c "PlenaryBustedDirectory lua/99 {minimal_init = 'scripts/tests/minimal.vim'}"

lua_clean:
	echo "===> Cleaning"
	rm /tmp/lua_*

docs_smoke:
	nvim --headless --noplugin -u NONE -i NONE -l scripts/tests/docs_smoke.lua

# Docs generation uses Node 22.6+. Keep it separate from the Lua checks.
docs_check:
	node --experimental-strip-types docs/src/generate.ts --check

pr_ready: lua_lint lua_test lua_fmt_check docs_smoke

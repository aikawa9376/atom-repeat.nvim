NVIM ?= nvim

.PHONY: test
test:
	XDG_STATE_HOME=/tmp/atom-repeat-nvim-state $(NVIM) --clean -n --headless -u tests/minimal_init.lua -c "luafile tests/run.lua"

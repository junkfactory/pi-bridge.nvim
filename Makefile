NVIM ?= nvim
INIT = scripts/minimal_init.lua
REPORTER = { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } }

# Redirect stdpath("state")/stdpath("log") (incl. pi-bridge.nvim.log) to a
# project-local dir so test runs never touch the real ~/.local/state/nvim.
# Inherits to the child neovim instances spawned by tests. Cleared before
# and after full runs (test, test_file).
TEST_STATE = $(CURDIR)/.deps/test-state
export XDG_STATE_HOME := $(TEST_STATE)

.PHONY: test test_file test-log test-context test-socket test-init test-launch test-placeholders test-dispatch test-ui test-health test-resolve

# Ensure test dependency is present
.deps/mini.nvim:
	@git clone --depth 1 https://github.com/echasnovski/mini.nvim $@

# Run all tests
test: .deps/mini.nvim
	rm -rf $(TEST_STATE)
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run($(REPORTER))"
	rm -rf $(TEST_STATE)

# Run a specific file: make test_file FILE=tests/test_socket.lua
test_file: .deps/mini.nvim
	rm -rf $(TEST_STATE)
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('$(FILE)', $(REPORTER))"
	rm -rf $(TEST_STATE)

# Run individual test files (shortcuts)
test-dispatch: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_dispatch.lua', $(REPORTER))"

test-ui: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_ui.lua', $(REPORTER))"

test-health: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_health.lua', $(REPORTER))"

test-log: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_log.lua', $(REPORTER))"

test-context: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_context.lua', $(REPORTER))"

test-socket: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_socket.lua', $(REPORTER))"

test-init: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_init.lua', $(REPORTER))"

test-launch: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_launch.lua', $(REPORTER))"

test-placeholders: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_placeholders.lua', $(REPORTER))"

test-resolve: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('tests/test_resolve.lua', $(REPORTER))"

NVIM ?= nvim
INIT = scripts/minimal_init.lua
REPORTER = { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } }

.PHONY: test test_file test-log test-context test-socket test-init test-launch test-placeholders test-dispatch test-ui test-health test-resolve

# Ensure test dependency is present
.deps/mini.nvim:
	@git clone --depth 1 https://github.com/echasnovski/mini.nvim $@

# Run all tests
test: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run($(REPORTER))"

# Run a specific file: make test_file FILE=tests/test_socket.lua
test_file: .deps/mini.nvim
	$(NVIM) --headless --noplugin -u $(INIT) -c "lua MiniTest.run_file('$(FILE)', $(REPORTER))"

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

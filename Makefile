.PHONY: test test-log test-context test-socket test-init test-launch test-dispatch test-ui

# Run all tests
test:
	nvim --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run({ execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })"

# Run individual test files
test-dispatch:	nvim --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('tests/test_dispatch.lua', { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })"

test-ui:	nvim --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('tests/test_ui.lua', { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })"

test-log:
	nvim --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('tests/test_log.lua', { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })"

test-context:
	nvim --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('tests/test_context.lua', { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })"

test-socket:
	nvim --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('tests/test_socket.lua', { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })"

test-init:
	nvim --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('tests/test_init.lua', { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })"

test-launch:
	nvim --headless --noplugin -u scripts/minimal_init.lua \
		-c "lua MiniTest.run_file('tests/test_launch.lua', { execute = { reporter = MiniTest.gen_reporter.stdout({ group_depth = 1 }) } })"

.PHONY: check
check:
	guile --no-auto-compile -L modules tests/mcp.scm

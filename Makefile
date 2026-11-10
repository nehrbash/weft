.PHONY: check
check:
	guile --no-auto-compile -L modules tests/runtime.scm
	guile --no-auto-compile -L modules tests/jobs.scm
	guile --no-auto-compile -L modules tests/mcp.scm

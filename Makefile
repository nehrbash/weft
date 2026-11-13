.PHONY: check
check:
	guile --no-auto-compile -L modules tests/runtime.scm
	guile --no-auto-compile -L modules tests/recovery.scm
	guile --no-auto-compile -L modules tests/sessions.scm
	guile --no-auto-compile -L modules tests/jobs.scm
	guile --no-auto-compile -L modules tests/agents.scm
	guile --no-auto-compile -L modules tests/orchestration.scm
	guile --no-auto-compile -L modules tests/daemon.scm
	guile --no-auto-compile -L modules tests/mcp.scm
	guile --no-auto-compile -L modules tests/isolated.scm

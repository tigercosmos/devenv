# devenv — one command to set up the development environment.
#
#   make install      install dependencies, skills, scripts, shell config, and cred-forward, then run the doctor
#   make deps         gh, codex, claude, cursor agent
#   make skills       codexmon, code-cortex-mcp, and the skills in skills/ (linked into ~/.claude/skills, synced to every agent)
#   make scripts      make the utility scripts executable (they go on PATH via `make shell`)
#   make shell        wire shell/devenv.sh into the login profile and verify the aliases
#   make cred-forward install the local credential server or remote client
#   make doctor       report what is installed and what is missing (devenv doctor)
#   make update       pull and upgrade everything to the latest release (devenv update)
#
# After `make install`, the `devenv` command manages the environment:
# `devenv status`, `devenv client on|off`, `devenv server on|off`,
# `devenv server gh use ACCOUNT`, `devenv gh check`.
#
# Everything is installed into the user's home directory (~/.local/bin,
# ~/.claude/skills, ...). Tools that are already present are skipped; set
# FORCE=1 (or run `make update`) to reinstall or upgrade them.

SHELL := /bin/bash
.DEFAULT_GOAL := help
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
export DEVENV_HOME := $(ROOT)

ifeq ($(OS),Windows_NT)
PS := powershell -NoProfile -ExecutionPolicy Bypass -File
endif

.PHONY: help install deps skills scripts shell cred-forward doctor update

help:
	@sed -n '2,15p' $(lastword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'

install: deps skills scripts shell cred-forward doctor

deps:
ifdef PS
	$(PS) "$(ROOT)/dependencies/install.ps1" $(if $(FORCE),-Force)
else
	bash "$(ROOT)/dependencies/install.sh"
endif

skills: scripts
ifdef PS
	$(PS) "$(ROOT)/skills/install.ps1" $(if $(FORCE),-Force)
else
	bash "$(ROOT)/skills/install.sh"
endif

scripts:
	@chmod +x "$(ROOT)"/scripts/devenv "$(ROOT)"/scripts/devenv-* "$(ROOT)"/*/install.sh 2>/dev/null || true
	@echo "scripts: $(ROOT)/scripts (added to PATH by 'make shell')"

shell:
ifdef PS
	$(PS) "$(ROOT)/shell/install.ps1"
else
	bash "$(ROOT)/shell/install.sh"
endif

cred-forward:
ifdef PS
	@echo "cred-forward: skipped (macOS and Linux only)"
else
	bash "$(ROOT)/cred-forward/install.sh"
endif

doctor:
ifdef PS
	-$(PS) "$(ROOT)/scripts/devenv.ps1" doctor
else
	bash "$(ROOT)/scripts/devenv" doctor
endif

update:
ifdef PS
	$(PS) "$(ROOT)/scripts/devenv.ps1" update
else
	bash "$(ROOT)/scripts/devenv" update
endif

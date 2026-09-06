# sparkling-clean — macOS disk triage toolkit
SHELL      := /bin/zsh
ROOT       := $(shell pwd)
LABEL      := com.sparklingclean.diskguard
PLIST_SRC  := launchd/$(LABEL).plist
PLIST_DST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

report: ## Full read-only health + space report
	@./bin/disk-report.zsh

brief: ## Headline numbers only
	@./bin/disk-report.zsh --brief

check: ## Run the guard once (exit 0/1/2)
	@./bin/disk-guard.zsh

dry: ## Show what tier 1+2 reclaim would free (removes nothing)
	@./bin/reclaim.zsh --tier 2

clean-safe: ## Reclaim tier 1 (regenerating caches only)
	@./bin/reclaim.zsh --apply

clean-more: ## Reclaim tier 1+2 (adds re-downloadable caches)
	@./bin/reclaim.zsh --tier 2 --apply

review: ## List tier-3 data candidates for manual decision
	@./bin/reclaim.zsh --tier 3

docker: ## Report Docker reclaimable space (never touches volumes)
	@./bin/docker-reclaim.zsh

docker-clean: ## Prune Docker build cache + untagged images, then compact
	@./bin/docker-reclaim.zsh --apply --compact

tm-status: ## Show which codified TM exclusions are applied
	@./bin/tm-exclude.zsh --status || true   # exit 1 = pending, meaningful to scripts, not a make failure

tm-exclude: ## Preview applying the codified TM exclusion list
	@./bin/tm-exclude.zsh

tm-exclude-apply: ## Apply the codified TM exclusion list (needs Full Disk Access)
	@./bin/tm-exclude.zsh --apply

install-guard: ## Install + load the launchd guard (checks every 2h)
	@mkdir -p $(HOME)/Library/LaunchAgents
	@sed 's|__SC_ROOT__|$(ROOT)|g' $(PLIST_SRC) > $(PLIST_DST)
	@launchctl unload $(PLIST_DST) 2>/dev/null || true
	@launchctl load  $(PLIST_DST)
	@echo "loaded $(LABEL) — checks every 2h, notifies on WARN/CRIT"
	@echo "log: ~/.local/state/sparkling-clean/sparkling-clean.log"

uninstall-guard: ## Unload + remove the launchd guard
	@launchctl unload $(PLIST_DST) 2>/dev/null || true
	@rm -f $(PLIST_DST)
	@echo "removed $(LABEL)"

guard-status: ## Is the guard loaded?
	@launchctl list | grep $(LABEL) || echo "not loaded (make install-guard)"

log: ## Tail the guard log
	@tail -30 $(HOME)/.local/state/sparkling-clean/sparkling-clean.log 2>/dev/null || echo "no log yet"

lint: ## Syntax-check every script
	@for f in bin/*.zsh bin/lib/*.zsh; do zsh -n $$f && echo "  ok  $$f"; done
	@plutil -lint $(PLIST_SRC)

.PHONY: help report brief check dry clean-safe clean-more review docker docker-clean tm-status tm-exclude tm-exclude-apply install-guard uninstall-guard guard-status log lint

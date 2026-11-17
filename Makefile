COMPOSE = docker compose
.DEFAULT_GOAL := help
SHELL := /bin/bash

# Default values (bisa di-override: make monitor INTERVAL=5)
INTERVAL ?= 10
DURATION ?= 0
TARGET   ?= http://192.168.0.108:8083
TOOL     ?= auto
ARGS     ?=

# Warna
GREEN  := \033[0;32m
YELLOW := \033[1;33m
CYAN   := \033[0;36m
NC     := \033[0m

##@ Bantuan
.PHONY: help
help: ## Tampilkan daftar perintah ini
	@echo ""
	@echo -e "  ${CYAN}██████╗  ██████╗ ██████╗ ████████╗ █████╗ ██╗${NC}"
	@echo -e "  ${CYAN}██╔══██╗██╔═══██╗██╔══██╗╚══██╔══╝██╔══██╗██║${NC}"
	@echo -e "  ${CYAN}██████╔╝██║   ██║██████╔╝   ██║   ███████║██║${NC}"
	@echo -e "  ${CYAN}██╔═══╝ ██║   ██║██╔══██╗   ██║   ██╔══██║██║${NC}"
	@echo -e "  ${CYAN}██║     ╚██████╔╝██║  ██║   ██║   ██║  ██║███████╗${NC}"
	@echo -e "  ${CYAN}╚═╝      ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚══════╝${NC}"
	@echo -e "  ${YELLOW}Portal Kampus - WordPress Docker Stack${NC}"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  ${GREEN}%-18s${NC} %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  ${YELLOW}Contoh:${NC}"
	@echo "    make up"
	@echo "    make seed"
	@echo "    make monitor INTERVAL=5 DURATION=3600"
	@echo "    make loadtest TARGET=http://192.168.0.108:8083"
	@echo "    make wpcli ARGS=\"plugin list\""
	@echo ""

##@ Stack Docker
.PHONY: up
up: ## Jalankan stack (tanpa Redis)
	@[ -f .env ] || (echo -e "${YELLOW}[WARN] .env tidak ditemukan. Copy dari .env.example dulu!${NC}" && exit 1)
	$(COMPOSE) up -d
	@echo -e "${GREEN}✓ WordPress berjalan di http://localhost:8083${NC}"

.PHONY: up-redis
up-redis: ## Jalankan stack + Redis Object Cache
	@[ -f .env ] || (echo -e "${YELLOW}[WARN] .env tidak ditemukan!${NC}" && exit 1)
	$(COMPOSE) --profile redis up -d
	@echo -e "${GREEN}✓ Stack + Redis berjalan${NC}"

.PHONY: down
down: ## Hentikan stack (DATA AMAN, volume tidak dihapus)
	@echo -e "${YELLOW}[WARN] Volumes TIDAK dihapus. Data database dan WordPress tetap aman.${NC}"
	@echo -e "${YELLOW}       Gunakan 'make nuke' untuk hapus semua data (tidak bisa dibatalkan!).${NC}"
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart semua service
	$(COMPOSE) restart

.PHONY: reset-wp
reset-wp: ## Restart container WordPress saja
	$(COMPOSE) restart wordpress
	@echo -e "${GREEN}✓ WordPress di-restart${NC}"

.PHONY: build
build: ## Build ulang semua image (--no-cache)
	$(COMPOSE) build --no-cache

.PHONY: pull
pull: ## Pull image terbaru dari registry
	$(COMPOSE) pull

##@ Monitoring & Status
.PHONY: status
status: ## Tampilkan status container + docker stats
	@echo ""
	@echo -e "${CYAN}=== Container Status ===${NC}"
	$(COMPOSE) ps
	@echo ""
	@echo -e "${CYAN}=== Docker Stats (snapshot) ===${NC}"
	@docker stats --no-stream --filter "name=portal" 2>/dev/null || \
		docker stats --no-stream 2>/dev/null | grep -E "NAME|wordpress|_db|redis" || true

.PHONY: logs
logs: ## Tampilkan semua log (follow)
	$(COMPOSE) logs -f

.PHONY: logs-wp
logs-wp: ## Tampilkan log WordPress saja
	$(COMPOSE) logs -f wordpress

.PHONY: logs-db
logs-db: ## Tampilkan log database saja
	$(COMPOSE) logs -f wordpress_db

##@ Shell
.PHONY: shell-wp
shell-wp: ## Masuk ke shell container WordPress
	$(COMPOSE) exec wordpress bash

.PHONY: shell-db
shell-db: ## Masuk ke shell container MariaDB
	$(COMPOSE) exec wordpress_db bash

##@ Konten & WP-CLI
.PHONY: seed
seed: ## Jalankan seed konten Portal Kampus (idempotent)
	@[ -f .env ] || (echo -e "${YELLOW}[ERROR] .env tidak ditemukan!${NC}" && exit 1)
	@echo -e "${CYAN}Menjalankan seed script...${NC}"
	$(COMPOSE) --profile tools run --rm wpcli bash /scripts/seed.sh

.PHONY: wpcli
wpcli: ## Jalankan perintah WP-CLI. Contoh: make wpcli ARGS="plugin list"
	$(COMPOSE) --profile tools run --rm wpcli wp $(ARGS)

##@ Data & Backup
.PHONY: backup
backup: ## Backup database + wp-content dengan timestamp
	bash scripts/backup.sh

.PHONY: monitor
monitor: ## Koleksi metrik skripsi. Contoh: make monitor INTERVAL=10 DURATION=3600
	bash scripts/monitor.sh $(INTERVAL) $(DURATION)

.PHONY: loadtest
loadtest: ## Uji beban bertahap (k6/wrk). Contoh: make loadtest TARGET=http://...
	bash scripts/loadtest.sh $(TARGET) $(TOOL)

##@ Deploy
.PHONY: deploy
deploy: ## Deploy ke server via rsync + SSH
	@[ -f .env.deploy ] || (echo -e "${YELLOW}[ERROR] .env.deploy tidak ditemukan! Copy dari .env.deploy.example${NC}" && exit 1)
	bash scripts/deploy.sh

.PHONY: deploy-dry
deploy-dry: ## Preview deploy (tidak ada yang diubah)
	bash scripts/deploy.sh --dry-run

##@ Berbahaya
.PHONY: nuke
nuke: ## HAPUS SEMUA data termasuk database dan volumes!
	@echo ""
	@echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
	@echo -e "${YELLOW}║  PERINGATAN: Semua data AKAN DIHAPUS PERMANEN!      ║${NC}"
	@echo -e "${YELLOW}║  Database, wp-content, dan semua volume akan hilang  ║${NC}"
	@echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
	@echo ""
	@read -p "Ketik 'YA HAPUS SEMUA' untuk konfirmasi: " CONFIRM && \
		[ "$$CONFIRM" = "YA HAPUS SEMUA" ] || (echo "Dibatalkan." && exit 1)
	$(COMPOSE) down -v
	@echo -e "${GREEN}Semua data dan volume telah dihapus.${NC}"


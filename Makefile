# Сборка Chaos MD и упаковка релизного архива.
#
# Для сборки нужен Docker (без rustup, без cross).
# На Apple Silicon сборка aarch64 нативная, x86_64 — через Rosetta 2 в Docker Desktop.
# На Intel Mac — наоборот.
#
# Цели:
#   make orch     — собрать оба Linux-бинарника + Mac + лаунчер в dist/ (нужен Docker)
#   make package  — orch + bash-архив (вызывает build.sh)
#   make dev / mac — только нативный Mac (cargo --release, без Docker); бинарник: chaos-md/target/release/chaos-md
#   make clean    — удалить dist/ и target/ Rust

ORCH    := chaos-md
DIST    := dist
IMAGE   := rust:slim    # Debian-based, glibc → добавим musl target внутри

# Cargo cache — именованные Docker volumes, чтобы не скачивать зависимости каждый раз.
CACHE_X86   := chaos-md-cargo-x86
CACHE_ARM64 := chaos-md-cargo-arm64
MAC_ARCH    := $(shell uname -m)

CARGO_SOURCES := $(shell find $(ORCH)/src -name '*.rs' 2>/dev/null) $(ORCH)/Cargo.toml

.PHONY: all orch package dev mac clean check-docker test-shell

all: orch

test-shell:
	bash tests/hosts-smoke.sh
	bash tests/grafana-annotations-smoke.sh
	python3 grafana/tests/dashboard-smoke.py

check-docker:
	@command -v docker >/dev/null 2>&1 || { echo "Нужен Docker: https://docs.docker.com/get-docker/"; exit 1; }

# ── x86_64 musl ─────────────────────────────────────────────────────────────
$(DIST)/$(ORCH).x86_64: $(CARGO_SOURCES) check-docker
	mkdir -p $(DIST)
	docker run --rm --platform linux/amd64 \
	    -v "$(abspath $(ORCH))":/work \
	    -v "$(abspath $(DIST))":/dist \
	    -v "$(CACHE_X86)":/root/.cargo/registry \
	    -w /work \
	    $(IMAGE) \
	    sh -c "apt-get update -qq && apt-get install -y -qq musl-tools > /dev/null \
	        && rustup target add x86_64-unknown-linux-musl 2>/dev/null \
	        && CARGO_TARGET_DIR=/tmp/target \
	           cargo build --release --target x86_64-unknown-linux-musl \
	        && cp /tmp/target/x86_64-unknown-linux-musl/release/$(ORCH) /dist/$(ORCH).x86_64"
	@echo "Собран: $(DIST)/$(ORCH).x86_64 ($$(wc -c < $(DIST)/$(ORCH).x86_64 | tr -d ' ') байт)"

# ── aarch64 musl ─────────────────────────────────────────────────────────────
$(DIST)/$(ORCH).aarch64: $(CARGO_SOURCES) check-docker
	mkdir -p $(DIST)
	docker run --rm --platform linux/arm64 \
	    -v "$(abspath $(ORCH))":/work \
	    -v "$(abspath $(DIST))":/dist \
	    -v "$(CACHE_ARM64)":/root/.cargo/registry \
	    -w /work \
	    $(IMAGE) \
	    sh -c "apt-get update -qq && apt-get install -y -qq musl-tools > /dev/null \
	        && rustup target add aarch64-unknown-linux-musl 2>/dev/null \
	        && CARGO_TARGET_DIR=/tmp/target \
	           cargo build --release --target aarch64-unknown-linux-musl \
	        && cp /tmp/target/aarch64-unknown-linux-musl/release/$(ORCH) /dist/$(ORCH).aarch64"
	@echo "Собран: $(DIST)/$(ORCH).aarch64 ($$(wc -c < $(DIST)/$(ORCH).aarch64 | tr -d ' ') байт)"

# ── macOS нативный бинарник (текущая архитектура Mac) ────────────────────────
$(DIST)/$(ORCH).darwin_$(MAC_ARCH): $(CARGO_SOURCES)
	mkdir -p $(DIST)
	cd $(ORCH) && cargo build --release
	cp $(ORCH)/target/release/$(ORCH) $(DIST)/$(ORCH).darwin_$(MAC_ARCH)
	@echo "Собран: $(DIST)/$(ORCH).darwin_$(MAC_ARCH) ($$(wc -c < $(DIST)/$(ORCH).darwin_$(MAC_ARCH) | tr -d ' ') байт)"

# ── Лаунчер ──────────────────────────────────────────────────────────────────
$(DIST)/$(ORCH): $(ORCH)/launcher.sh
	mkdir -p $(DIST)
	cp $(ORCH)/launcher.sh $@
	chmod +x $@

# ── Главные цели ─────────────────────────────────────────────────────────────
orch: $(DIST)/$(ORCH).x86_64 $(DIST)/$(ORCH).aarch64 $(DIST)/$(ORCH).darwin_$(MAC_ARCH) $(DIST)/$(ORCH)

# Локальная сборка на Mac (нативная архитектура, без Docker — самый быстрый вариант «только Mac»).
dev:
	cd $(ORCH) && cargo build --release
	@echo "Mac binary: $(ORCH)/target/release/$(ORCH)"

# Синоним dev (удобно искать по слову mac).
mac: dev

# Релизный архив.
package: orch
	./build.sh

clean:
	cd $(ORCH) && cargo clean || true
	rm -f $(DIST)/$(ORCH) $(DIST)/$(ORCH).* $(DIST)/$(ORCH).darwin_*

# Удалить и Docker cache-тома.
clean-all: clean
	docker volume rm $(CACHE_X86) $(CACHE_ARM64) 2>/dev/null || true

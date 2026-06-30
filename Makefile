VERSION := 0.1.0

INK    := zig-out/bin/ink
PREFIX ?= $(HOME)/.ink

# Host platform tag — must match the strings in src/home.zig.
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_S),Darwin)
  HOST_OS := macos
else
  HOST_OS := linux
endif
ifeq ($(filter arm64 aarch64,$(UNAME_M)),)
  HOST_ARCH := x64
else
  HOST_ARCH := arm64
endif
HOST := $(HOST_OS)-$(HOST_ARCH)

# Distributed platforms. Windows builds the core language only — IPC, the
# Jupyter kernel, and native FFI extensions are unavailable there.
PLATFORMS := macos-arm64 macos-x64 linux-arm64 linux-x64 windows-arm64 windows-x64

.PHONY: test build release all install data demo qa info clean

test:
	time zig build test
	$(INK) lib/stats.k
	$(INK) test/regex.k
	$(INK) test/fbx.k
	$(INK) test/usd.k
	zig build json
	$(INK) test/gltf.k
	# $(INK) test/font.k
	sh test/ipc.sh

build:
	time zig build -Doptimize=ReleaseFast -Dversion=$(VERSION)

release:
	time zig build -Doptimize=ReleaseFast -Dversion=$(VERSION)
	@echo "Total lines:" && find src -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Binary size:" && du -h zig-out/*/*

# Cross-compile the core ink binary (no native extensions) for every
# distributed platform, naming each output zig-out/bin/ink-<platform>.
all:
	@for p in $(PLATFORMS); do \
	  case $$p in \
	    macos-arm64) t=aarch64-macos ;; \
	    macos-x64)   t=x86_64-macos ;; \
	    linux-arm64)   t=aarch64-linux-musl ;; \
	    linux-x64)     t=x86_64-linux-musl ;; \
	    windows-arm64) t=aarch64-windows-gnu ;; \
	    windows-x64)   t=x86_64-windows-gnu ;; \
	    *) echo "unknown platform $$p"; exit 1 ;; \
	  esac; \
	  echo "==> ink-$$p ($$t)"; \
	  zig build bin -Dcore-only=true -Doptimize=ReleaseFast -Dversion=$(VERSION) \
	    -Dtarget=$$t -Dexe-name=ink-$$p || exit 1; \
	done
	@echo "Built:" && ls -1 zig-out/bin/ink-* | grep -v '\.pdb$$'

# Install ink into $(PREFIX) (~/.ink):
#   bin/             one binary per distributed platform
#   ink              symlink to the host binary
#   lib/             k source library (*.k, *.kb)
#   share/<host>/    host-platform native extensions (.dylib/.so)
# Shipping every platform's binary lets users `ink bundle -t <platform>` to
# cross-target their k programs.
install: build all
	@echo "Installing ink $(VERSION) -> $(PREFIX)"
	@mkdir -p $(PREFIX)/bin $(PREFIX)/lib $(PREFIX)/share/$(HOST)
	@cp zig-out/bin/ink-* $(PREFIX)/bin/
	@rm -f $(PREFIX)/bin/*.pdb
	@ln -sf bin/ink-$(HOST) $(PREFIX)/ink
	@(cd lib && find . \( -name '*.k' -o -name '*.kb' \) -print | tar -cf - -T -) | (cd $(PREFIX)/lib && tar -xf -)
	@cp zig-out/lib/*.dylib $(PREFIX)/share/$(HOST)/ 2>/dev/null || true
	@cp zig-out/lib/*.so    $(PREFIX)/share/$(HOST)/ 2>/dev/null || true
	@echo "Done. Host binary: $(PREFIX)/ink ($(HOST))"
	@echo "Add to PATH:  ln -sf $(PREFIX)/ink /usr/local/bin/ink   (or add $(PREFIX) to PATH)"

demo:
	$(INK) test/circle.k
	$(INK) test/drive.k
	$(INK) test/drawing.k
	$(INK) test/planes.k
	$(INK) test/sphere.k

qa:
	time zig build test
	$(INK) test/circle.k
	$(INK) test/walk.k
	$(INK) test/eyes.k

info:
	@echo "Ink lines /lib:" && find lib -name '*.k' | xargs wc -l | tail -n 1
	@echo "Zig lines /lib" && find lib -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Zig lines /src:" && find src -name '*.zig' | xargs wc -l | tail -n 1
	@echo "Binary size:" && du -h zig-out/bin/*

data:
	./data/taxi.sh -meta
	./data/taxi.sh -trip 2026

clean:
	rm -rf zig-out

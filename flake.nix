{
  description = "Ink — a polysemic array programming language (k-like) with a Zig runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Exact Zig toolchain, pinned in one place (see `zigVersion` below).  Using
    # the overlay rather than nixpkgs' `zig` keeps the version reproducible and
    # decoupled from nixpkgs bumps.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    let
      # Single source of truth for the release version.  Keep in sync with the
      # Makefile's VERSION and build.zig's default.
      version = "0.1.0";
      zigVersion = "0.16.0";

      # platform tag (matches src/home.zig / Makefile) -> zig target triple.
      # Core-only binaries link just libc, which Zig cross-compiles for every
      # one of these from any host, with no external package dependencies.
      crossTargets = {
        "macos-arm64" = "aarch64-macos";
        "macos-x64" = "x86_64-macos";
        "linux-arm64" = "aarch64-linux-musl";
        "linux-x64" = "x86_64-linux-musl";
        "windows-arm64" = "aarch64-windows-gnu";
        "windows-x64" = "x86_64-windows-gnu";
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zig = zig-overlay.packages.${system}.${zigVersion};

        # nixpkgs system tuple -> ink platform tag, for naming the host binary
        # and pointing INK_HOME at the right per-platform layout.
        hostPlatform = {
          "aarch64-darwin" = "macos-arm64";
          "x86_64-darwin" = "macos-x64";
          "aarch64-linux" = "linux-arm64";
          "x86_64-linux" = "linux-x64";
        }.${system} or (throw "unsupported system ${system}");

        # On Linux, build the host binary against the static musl triple (same as
        # ink-cross) so it has no dynamic loader dependency and runs everywhere —
        # a glibc-linked binary references an ELF interpreter that isn't present
        # in the pure Nix store.  macOS links libSystem (always present natively).
        hostTargetFlag =
          if pkgs.stdenv.isLinux
          then "-Dtarget=${crossTargets.${hostPlatform}}"
          else "";

        # Shared bits of the build: a writable Zig cache (the sandbox has no
        # network, but core-only needs none) and regenerated unicode data.
        zigCacheSetup = ''
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
          export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
          # lib/data.kb is generated (gitignored), so it is absent from the
          # flake's git-only source; regenerate it (pure host codegen).
          zig build data -Dcore-only=true -Doptimize=ReleaseFast
        '';

        # Install the k library (*.k + *.kb, preserving layout) into $out/lib,
        # and the k tools `ink <tool>` runs into $out/tools.  tools/repl.k IS the
        # interactive repl, so a package without it has no prompt at all.
        installLib = ''
          mkdir -p "$out/lib" "$out/tools"
          ( cd lib && find . \( -name '*.k' -o -name '*.kb' \) -print0 \
            | tar --null -cf - -T - ) | ( cd "$out/lib" && tar -xf - )
          ( cd tools && find . -name '*.k' -print0 \
            | tar --null -cf - -T - ) | ( cd "$out/tools" && tar -xf - )
        '';

        # The host package: a single core-only ink binary, the k library, and a
        # wrapper that sets INK_HOME (so module autoload + `ink bundle` find the
        # library) and puts `zig` on PATH (needed by `ink bundle --static`).
        ink = pkgs.stdenv.mkDerivation {
          pname = "ink";
          inherit version;
          src = self;
          nativeBuildInputs = [ zig pkgs.makeWrapper ];
          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            ${zigCacheSetup}
            zig build bin -Dcore-only=true -Doptimize=ReleaseFast \
              -Dversion=${version} ${hostTargetFlag} -Dexe-name=ink-${hostPlatform}
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/libexec"
            cp zig-out/bin/ink-${hostPlatform} "$out/libexec/ink"
            ${installLib}
            # Real binary lives in libexec; the wrapped $out/bin/ink sets the
            # runtime environment.  selfExePath() resolves to libexec/ink, so
            # `ink bundle` (trailer mode) copies a clean base binary.
            makeWrapper "$out/libexec/ink" "$out/bin/ink" \
              --set INK_HOME "$out" \
              --prefix PATH : ${zig}/bin
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Polysemic array programming language with a Zig runtime";
            homepage = "https://github.com/wrnrlr/ink-newjit";
            mainProgram = "ink";
            platforms = platforms.unix;
          };
        };

        # The release package: every distributed platform's core binary plus the
        # shared k library, laid out the way `make install` expects under
        # $out (bin/ink-<platform>, lib/).  One derivation, built on any host —
        # Zig cross-compiles all six core binaries with no external deps.
        ink-cross = pkgs.stdenv.mkDerivation {
          pname = "ink-cross";
          inherit version;
          src = self;
          nativeBuildInputs = [ zig ];
          dontConfigure = true;
          # The outputs are foreign binaries (cross ELF / Mach-O / PE).  Never let
          # the host's strip/patchelf touch them — on a Linux release runner the
          # native strip would corrupt the Mach-O and PE artifacts.
          dontStrip = true;
          dontPatchELF = true;

          buildPhase = ''
            runHook preBuild
            ${zigCacheSetup}
            ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (plat: triple: ''
              echo "==> ink-${plat} (${triple})"
              zig build bin -Dcore-only=true -Doptimize=ReleaseFast \
                -Dversion=${version} -Dtarget=${triple} -Dexe-name=ink-${plat}
            '') crossTargets)}
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            cp zig-out/bin/ink-* "$out/bin/"
            rm -f "$out"/bin/*.pdb
            ${installLib}
            runHook postInstall
          '';

          meta.description = "Ink core binaries for all distributed platforms";
        };
      in
      {
        packages = {
          default = ink;
          inherit ink ink-cross;
        };

        apps.default = {
          type = "app";
          program = "${ink}/bin/ink";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.gnumake
            pkgs.git
            pkgs.gh
            pkgs.watchexec
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            # The (macOS-only) GPU extension links system GLFW; provide it for
            # `make build`/`zig build` of the full extension graph on Darwin.
            pkgs.glfw
          ];
          shellHook = ''
            echo "ink dev shell — zig ${zigVersion}"
            echo "  zig build              # debug build"
            echo "  make build             # ReleaseFast"
            echo "  make test              # unit tests + lib checks"
            echo "  nix build .#ink-cross  # all platform binaries"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      })
    // {
      # Overlay so downstream flakes can add `ink` to their package set:
      #   nixpkgs.overlays = [ inputs.ink.overlays.default ];
      overlays.default = final: prev: {
        ink = self.packages.${final.system}.default;
      };
    };
}

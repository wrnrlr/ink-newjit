# Ink
Ink is an array programming language 

## Features
- Fast 
- Quick visual debugging with buildin screenshot command 
- Bundle files into small statically-linked executable for easy deployment.
- 

[Mastering Data Visualization in VegaLite](https://www.youtube.com/playlist?list=PLe9dkYfBBHFktHd5Tn2FAlADEbQ70kUSp)

### Improvements
- Per lambda scratch allocator
- I suspect — but haven't measured — that there's a meaningful tax across hot loops in `kernelVec` and similar from doing `xv.* = Impl.f(...)` style operations where each per-element step doesn't actually need refcounting, but the surrounding V manipulation still does.

Functional programming with APL2

### 3Blue1Brown Puzzles
- https://www.youtube.com/shorts/ZHXt0-_gSj4

- [ngn/k jit](https://codeberg.org/fiuzeri/k/src/commit/bac6dc52fa7ed56a4ab329b5cbb7fdafe0115814/b.c)
- [Variadic functions in Q](https://bodonferenc.github.io/2026/05/13/Variadic-Functions.html)
- [SIMD: making every cycle count](https://lv1.sh/blog/simd-making-every-cycle-count/)
- [Leveraging APL and SPIR-V languages to write network functions to be deployed on Vulkan compatible GPUs](https://juuso.dev/papers/msc-thesis-lorraine/msc-thesis-lorraine.html)
- [InfiniteDiffusion: Open-World Terrain Generation](https://xandergos.github.io/terrain-diffusion/)
- [Writing Bindless GPU Abstraction layer](https://www.kevin-gibson.com/blog/writing-a-bindless-gpu-abstraction-layer/)

```
 M:2 2#!4
 g:(::; |:; +:; |+:; +|:; +|+:; |+|:; +|+|:)
 g@\:M
```

## Dev Enviroment
```sh
watchexec -r -e k -- ./zig-out/bin/ink test/planes.k
```

build docs
```sh
make docs
bunx serve out
```

### Nix

The flake pins the exact Zig toolchain (0.16.0) so the dev, CI, and release
builds are identical.

```sh
nix develop            # dev shell: zig 0.16.0 + make, gh, watchexec
nix build              # ReleaseFast core binary -> ./result/bin/ink
nix run . -- test/planes.k
nix build .#ink-cross  # core binaries for all six distributed platforms
```

Depend on ink from another flake:

```nix
{
  inputs.ink.url = "github:wrnrlr/ink-newjit";
  # then either:           inputs.ink.packages.<system>.default
  # or via the overlay:    nixpkgs.overlays = [ inputs.ink.overlays.default ];  # -> pkgs.ink
}
```

The Nix package is the **core** language (no native extensions). The GPU
extension is macOS-arm64 only and links system GLFW + Dawn, so it stays a
host build (`make build`). `nix develop` provides GLFW on Darwin for that.

Pushing a `v*` tag runs `.github/workflows/release.yml`, which cross-builds
every platform and publishes per-platform archives + `SHA256SUMS.txt` to a
GitHub Release.

Problems:

a:!9; a[2]:9

d: []



| now | evocative | plain |
|---|---|---|
| `worldSpawn` | **Conjure** | Spawn |
| `ecsKill`/despawn | **Banish** / Dispel | Despawn |
| `addComponent` | **Imbue** / Endow | Attach |
| `removeComponent` | **Strip** / Divest | Detach |
| `worldQuery` | **Muster** / Scry | Query |
| `worldEach` | **Survey** | Each |
| `worldQueryChanged` | **Watch** | — |
| system run | **Tick** / Step | Run |
| `ecsPropagate` | **Cascade** | — |
| `worldNew` | **Genesis** / Realm | World

# Auto reload
```sh
watchexec -r -w test/cloth.k -- ./zig-out/bin/ink -unfocus -top -monitor 1 test/cloth.k
```

```k
!10;

[[]id:!20;w:?20]
```

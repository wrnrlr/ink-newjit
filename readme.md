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
- [ALP: Adaptive Lossless Floating-Point Compression](https://github.com/cwida/ALP)

```
 M:2 2#!4
 g:(::; |:; +:; |+:; +|:; +|+:; |+|:; +|+|:)
 g@\:M
```

## Dev Enviroment
```sh
watchexec -r -e k -- ./zig-out/bin/ink demo/planes.k
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
nix run . -- demo/planes.k
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
extension is macOS-arm64 only and links system GLFW + Vulkan (MoltenVK), so it
stays a host build (`make build`). `nix develop` provides GLFW on Darwin for that.

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
watchexec -r -w demo/cloth.k -- ./zig-out/bin/ink -unfocus -top -monitor 1 demo/cloth.k
```

```k
!10;

[[]id:!20;w:?20]
```

```k
plot:{[x;y;f]
 ax:`lo`hi`tk`px{x!y@!#x}/:(x;y) /axes definitions
 $[&/^ax`px; ax[1;`px]:120;]     /default h if both w/h missing
 ax[`px]:_(|(%;*)@'/(ax`px;%/-/ax`hi`lo))^'ax`px /calc w/h
 ax[`pu]:((ax`px)-1)%-/ax`hi`lo  /compute px per unit
 u2p:{_(x`pu)*y-x`lo}; p2u:{(x`lo)+y%x`pu} /map px<>units
 cnv:(ax`px)#0; (X;Y):ax; fix:{_x+(x<0)&x>_x} /canvas
 set:{[ax;cnv;x]$[|/(x<0),x>(ax`px)-1;cnv;.[cnv;x;:;1]]}[ax]
 cnv[u2p[X]0;]:1; cnv[;u2p[Y]0]:1 /draw axes
 tk:(ax`tk)*{x+!1+y-x}'/fix@(ax`lo`hi)%\:ax`tk /axis ticks
 $[^X`tk;; cnv:set/[cnv;,/(u2p[X]tk.0),/:\:(u2p[Y]0)+3-!7]]
 $[^Y`tk;; cnv:set/[cnv;,/((u2p[X]0)+3-!7),/:\:u2p[Y]tk.1]]
 cnv:set/[cnv;x,'u2p[Y]@f'p2u[X]@x:!X`px] /plot function
 sixel@|+cnv
}
```

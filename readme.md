[Mastering Data Visualization in VegaLite](https://www.youtube.com/playlist?list=PLe9dkYfBBHFktHd5Tn2FAlADEbQ70kUSp)

### Improvements
- Per lambda scratch allocator
- I suspect — but haven't measured — that there's a meaningful tax across hot loops in `kernelVec` and similar from doing `xv.* = Impl.f(...)` style operations where each per-element step doesn't actually need refcounting, but the surrounding V manipulation still does.

Functional programming with APL2

### 3Blue1Brown Puzzles
- https://www.youtube.com/shorts/ZHXt0-_gSj4

- [ngn/k jit](https://codeberg.org/fiuzeri/k/src/commit/bac6dc52fa7ed56a4ab329b5cbb7fdafe0115814/b.c)
- [Variadic functions in Q](https://bodonferenc.github.io/2026/05/13/Variadic-Functions.html)

```
 M:2 2#!4
 g:(::; |:; +:; |+:; +|:; +|+:; |+|:; +|+|:)
 g@\:M
```

## Dev Enviroment
```
watchexec -r -e k -- ./zig-out/bin/ink test/planes.k
```

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


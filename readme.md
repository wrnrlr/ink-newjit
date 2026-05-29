[Mastering Data Visualization in VegaLite](https://www.youtube.com/playlist?list=PLe9dkYfBBHFktHd5Tn2FAlADEbQ70kUSp)

### Improvements
- Per lambda scratch allocator
- I suspect — but haven't measured — that there's a meaningful tax across hot loops in `kernelVec` and similar from doing `xv.* = Impl.f(...)` style operations where each per-element step doesn't actually need refcounting, but the surrounding V manipulation still does.


### 3Blue1Brown Puzzles
- https://www.youtube.com/shorts/ZHXt0-_gSj4

- [ngn/k jit](https://codeberg.org/fiuzeri/k/src/commit/bac6dc52fa7ed56a4ab329b5cbb7fdafe0115814/b.c)
- [Variadic functions in Q](https://bodonferenc.github.io/2026/05/13/Variadic-Functions.html)

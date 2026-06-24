/ test/ecs_deps.k — intra-stage system ordering by declared dependencies.
/ Systems are listed in arbitrary order; ecsRunDeps topo-sorts them by `after`
/ constraints and runs them in the resolved order. Headless / pure data.
/   ./zig-out/bin/ink test/ecs_deps.k

2: "lib/ecs.k"

a:: `id`px!(0 1; 1. 5.)

/ order-sensitive systems (px starts 1 / 5):
sysDouble: {[a] @[a;`px;:;2.*a`px]}    / px *= 2
sysInc:    {[a] @[a;`px;:;(a`px)+1.]}  / px += 1
sysClamp:  {[a] @[a;`px;:;9.&a`px]}    / px = min(px, 9)

/ specs (name; fn; after) — declared in a deliberately WRONG list order.
/ (one line: newlines inside (...) inject nulls; tuples separated by ;)
specs: ((`inc; sysInc; ,`double); (`clamp; sysClamp; `inc`double); (`double; sysDouble; ()))

`0 0: "declared list order: inc, clamp, double"
`0 0: "resolved dependency order:"
`0 0: $ecsDepOrder[specs]                       / expect: double inc clamp
`0 0: "result (double->inc->clamp): px 1->2->3->3, 5->10->11->9 => 3 9"
`0 0: $(ecsRunDeps[a; specs])`px

/ ── cycle: two systems each `after the other — unsatisfiable, both dropped ───────
cyc: ((`x; sysInc; ,`y); (`y; sysDouble; ,`x))
`0 0: "cycle resolved order (expect empty — both dropped):"
`0 0: $ecsDepOrder[cyc]
`0 0: "running a cycle leaves the archetype unchanged (px 1 5):"
`0 0: $(ecsRunDeps[a; cyc])`px

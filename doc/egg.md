The **egg** (e-graphs good) library is a high-performance Rust library for equality saturation, a technique used in program optimization, synthesis, and verification. Its efficiency stems from a combination of classic e-graph structures and several novel algorithmic improvements.

## 1. Core Data Structures

At its heart, **egg** manages a specialized graph that represents a congruence relation over expressions.

* **E-node (Equivalence Node):** Instead of a standard AST node where children are other nodes, an e-node is a functional operator whose children are **E-class IDs**. For example, the expression `(+ 1 2)` is represented as a `+` operator pointing to the IDs of the e-classes containing `1` and `2`.
* **E-class (Equivalence Class):** A set of e-nodes that are known to be equivalent. Any e-node in an e-class can be used interchangeably.
* **Union-Find (Disjoint Set Union):** Used to maintain the equivalence relation. When a rewrite rule determines two expressions are equal, **egg** performs a `union` operation on their respective e-classes.
* **Hashconsing (The "Memo" Table):** To maintain the **uniqueness invariant** (ensuring no two identical e-nodes exist), **egg** uses a hash map (`HashMap<ENode, Id>`). Before adding a new e-node, the library checks if an identical node already exists to avoid duplication.

## 2. The Rebuilding Algorithm

The most significant contribution of the **egg** paper is the **deferred rebuilding** technique. In traditional e-graphs, the "congruence invariant" (if, then) is maintained eagerly after every union, which is computationally expensive.

**egg** takes a lazy approach:

1. **Rule Application:** Rewrites are applied freely, which may temporarily break the congruence and uniqueness invariants.
2. **Marking "Dirty" Nodes:** Any e-class whose child has been merged into another class is marked as "dirty."
3. **Rebuild Step:** Periodically (usually once per iteration of equality saturation), the `rebuild` function is called.
* It processes all dirty e-classes.
* It re-canonicalizes e-nodes (updating child IDs to the latest Union-Find roots).
* It merges e-classes that have become congruent or redundant.
* This **amortized** approach provides a massive speedup (often 10x–100x) over eager maintenance.

## 3. E-Matching Engine

E-matching is the process of finding patterns within the e-graph. **egg** uses two primary strategies:

* **VM-based Matching:** The library compiles rewrite patterns into a small instruction set for a custom virtual machine. This VM traverses the e-graph to find matches efficiently.
* **Relational E-matching:** Recent versions and extensions of **egg** (often cited as "Relational E-matching") treat the e-graph as a database. E-matching is then solved as a **Conjunctive Query**, using **Worst-Case Optimal Join (WCOJ)** algorithms. This prevents the "combinatorial explosion" common in traditional backtracking search.

## 4. E-Class Analysis

**egg** allows users to attach arbitrary data (metadata) to e-classes through a mechanism called **Analysis**.

* **Semilattices:** Analysis data must form a join-semilattice. When two e-classes are merged, their metadata is merged using a `join` operation.
* **Propagation:** If an analysis value changes, the library automatically propagates this change up the graph (e.g., if a child's constant value is discovered, the parent's value can be computed).
* **Applications:** This is used for constant folding, type inference, and pruning branches that are provably useless.

## 5. Extraction Algorithms

Once the e-graph is "saturated" (no more rules can be applied), you must extract the "best" expression based on a cost function.

| Algorithm | Description | Best For... |
| --- | --- | --- |
| **Greedy Extractor** | A bottom-up, recursive approach that picks the cheapest e-node for each e-class. | Simple cost functions (like node count). |
| **ILP Extractor** | Formulates extraction as an **Integer Linear Programming** problem. | Complex costs with global constraints (e.g., latency vs. area). |

# Implementation

Implementing an e-graph library like **egg** in Zig is a compelling project because Zig’s focus on explicit memory management and `comptime` (compile-time code execution) allows you to build a system that is potentially even more performant and type-safe than the original Rust implementation.

To build an equivalent library, you would follow these architectural steps:

## 1. Defining the Language (The E-Node)

In Zig, you can use a **tagged union** to represent the operators of your language. By using `comptime`, you can make your e-graph generic over any user-defined language.

```zig
const Id = u32;

// Example Language definition
const MathOp = union(enum) {
    Add: [2]Id,
    Mul: [2]Id,
    Const: i32,
    Var: []const u8,
};

```

### Memory Optimization

Since e-nodes are often very small, you should avoid heap-allocating the children of every node.

* **Small-Array Optimization:** Use a fixed-size array for children if the max arity is known.
* **Data-Oriented Design:** Store e-nodes in a contiguous `std.MultiArrayList` to improve cache locality during the rebuilding phase.

---

## 2. Core Data Structures

You need three primary components to manage the equivalence relations:

1. **The Union-Find (DSU):** A simple `std.ArrayList(Id)` where each index points to its parent.
2. **The Memo Table:** A `std.AutoHashMap(ENode, Id)` for hashconsing (ensuring each unique e-node exists only once).
3. **The E-Classes:** A structure that maps an `Id` to a list of its equivalent `ENodes`.

## 3. Implementing the Rebuilding Step

The "secret sauce" of **egg** is the deferred rebuilding. In Zig, you would implement this by maintaining a "dirty" queue.

* **Worklist:** A `std.ArrayList(Id)` of e-classes that have been modified by a `union` operation.
* **The Rebuild Loop:**
1. Pop an e-class from the worklist.
2. For every "parent" e-node of that class, re-canonicalize its children using the Union-Find `find` method.
3. Check the memo table to see if the updated e-node now collides with another existing node.
4. If a collision occurs, `union` the two classes and add the new parent to the worklist.

## 4. Leveraging Zig's `comptime`

One advantage Zig has over Rust is the ability to generate matching logic at compile time without complex macros.

* **Pattern Matching:** You can pass a string pattern (like `"(+ ?a 0)"`) to a `comptime` function that parses it and generates a specialized matcher struct.
* **Generic Analysis:** Use Zig’s type system to allow users to attach metadata (like constant-folding results) to an e-class.

```zig
fn EGraph(comptime Language: type, comptime Analysis: type) type {
    return struct {
        memo: std.AutoHashMap(Language, Id),
        union_find: std.ArrayList(Id),
        classes: std.ArrayList(EClass(Language, Analysis)),
        // ... methods for add, union, and rebuild
    };
}

```

## 5. Memory Management Strategy

Unlike Rust, which relies on an ownership model, Zig gives you full control over allocations. For an e-graph, an **ArenaAllocator** is often the best choice:

1. **Iteration Lifecycle:** Use an arena for the temporary allocations during a single "saturation" iteration (like the matching VM’s state).
2. **Graph Growth:** Use a standard `PageAllocator` or `GeneralPurposeAllocator` for the e-graph itself, as it needs to persist and grow.

## 6. Challenges to Watch For

* **Hashing Tagged Unions:** Zig's `std.hash.autoHash` is excellent, but ensure your `ENode` union doesn't have "garbage" padding bits that could cause identical nodes to have different hashes. Use `@bitCast` or explicit field hashing if necessary.
* **Recursive Unions:** If your language allows for deeply nested structures (not common in e-graphs but possible), be mindful of stack depth during the `find` or `extraction` phases.

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A compact Union-Find structure for managing E-Class IDs.
pub const UnionFind = struct {
    /// parent[i] stores the parent of node i. If parent[i] == i, it's a root.
    parent: std.ArrayList(u32),
    /// rank[i] is used to keep the trees flat during unions.
    rank: std.ArrayList(u32),
    allocator: Allocator,

    pub fn init(allocator: Allocator) UnionFind {
        return .{
            .parent = std.ArrayList(u32).init(allocator),
            .rank = std.ArrayList(u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnionFind) void {
        self.parent.deinit();
        self.rank.deinit();
    }

    /// Creates a new singleton set and returns its ID.
    pub fn makeSet(self: *UnionFind) !u32 {
        const id = @as(u32, @intCast(self.parent.items.len));
        try self.parent.append(id);
        try self.rank.append(0);
        return id;
    }

    /// Finds the representative (root) of the set containing `id`.
    /// Implements Path Compression to keep lookups near O(1).
    pub fn find(self: *UnionFind, id: u32) u32 {
        var root = id;
        while (self.parent.items[root] != root) {
            // Path Halving: point node to its grandparent
            self.parent.items[root] = self.parent.items[self.parent.items[root]];
            root = self.parent.items[root];
        }
        return root;
    }

    /// Merges the sets containing `id1` and `id2`.
    /// Returns the new root ID.
    pub fn unionSets(self: *UnionFind, id1: u32, id2: u32) u32 {
        const root1 = self.find(id1);
        const root2 = self.find(id2);

        if (root1 == root2) return root1;

        // Union by Rank: Attach the shorter tree under the taller one
        if (self.rank.items[root1] < self.rank.items[root2]) {
            self.parent.items[root1] = root2;
            return root2;
        } else if (self.rank.items[root1] > self.rank.items[root2]) {
            self.parent.items[root2] = root1;
            return root1;
        } else {
            self.parent.items[root2] = root1;
            self.rank.items[root1] += 1;
            return root1;
        }
    }
};
```

# Use of k
Using an e-graph library for an array language like **k** is a match made in heaven. Array languages are built on formal algebraic properties (like those found in APL or J), which are exactly what e-graphs excel at optimizing.

In a bytecode VM, you would use the e-graph to transform high-level "tacit" code into highly efficient, fused bytecode kernels.

## 1. Compile-Time: The "Global Optimizer"

At compile time, the e-graph acts as a **Super-Optimizer**. Because **k** is so concise, a small change in code can lead to massive differences in execution strategy.

### Operator Fusion (The Big Win)

In **k**, expressions like `+/1+2*!100` (sum of 1 plus 2 times the first 100 integers) normally create several intermediate arrays. An e-graph can find the "fused" version.

* **Rewrite Rule:** `(f' g' x) => ((f . g)' x)`
* **Result:** Instead of allocating three intermediate vectors, the e-graph realizes it can generate a single loop that performs all operations in one pass over the data.

### Rank and Shape Analysis

Using the **E-Class Analysis** feature we discussed, you can propagate shapes at compile time.

* **Metadata:** Each e-class stores a "Shape Lattice" (e.g., `Unknown`, `Scalar`, `Vector(100)`).
* **Optimization:** If the e-graph proves an operation is being performed on two scalars, it can replace a heavy "Vectorized Add" bytecode with a simple "Scalar Add" instruction.

## 2. Runtime: The "Adaptive JIT"

While e-graphs are usually seen as "slow" for runtime, their additive nature makes them powerful for a VM that optimizes on the fly.

### Adaptive Specilization

If your **k** VM encounters a hot loop where the types or shapes are only known at runtime, it can:

1. **Capture the E-node:** Represent the current hot expression as an e-graph.
2. **Apply Speculative Rules:** "If this argument is a boolean vector, I can use bit-packing."
3. **Extract & JIT:** Use the **Zig** `comptime` or a library like `LLVM` to generate a machine-code kernel for that specific e-class configuration.

### In-Place Optimization (MORT)

In array languages, memory allocation is the primary bottleneck. You can use e-classes to track the "lifespan" of an array.

* If the e-graph sees that an array `A` is modified and then never used again in its original form, it can rewrite the operation to be **in-place** (`A[i] = A[i] * 2`) rather than allocating a new array.

## 3. How it looks in the VM Pipeline

| Stage | Input | E-Graph Action | Output |
| --- | --- | --- | --- |
| **Parsing** | `+/x*y` | Construct initial E-nodes. | E-Graph |
| **Saturation** | Rules | Apply identities like `a*b == b*a` or `sum(a+b) == sum(a)+sum(b)`. | Expanded E-Graph |
| **Extraction** | Cost Function | Pick the version with the fewest allocations and best SIMD potential. | Optimized AST |
| **Lowering** | Optimized AST | Translate to specialized Bytecode (e.g., `MAP_MUL_ADD_REDUCE`). | Bytecode |

## 4. Implementation Strategy in Zig

To make this work for a **k** VM in Zig:

1. **The Cost Function:** In Zig, you would define a `fn cost(node: ENode) f32` that penalizes "Alloc" nodes heavily and rewards "Fused" nodes.
2. **The Bytecode Mapping:** Each E-node variant in your Zig `union(enum)` should correspond directly to a Bytecode instruction or a sequence of them.
3. **Partial Saturation:** At runtime, you don't want to wait 100ms for the graph to saturate. You can set a "Node Limit"—stop optimizing once the e-graph reaches 1,000 nodes and just take the best version found so far.

> **Example Rule in Zig-style logic:**
> ```zig
> // Rule: x + 0 => x
> if (node == .Add and egraph.get_analysis(node.children[1]).is_constant_zero) {
>     egraph.union(node_id, node.children[0]);
> }
> 
> ```
> 
> 

# Cost function

In an array language like **k**, the goal of a cost function is to discourage "materialization"—the act of creating a temporary array in memory. We want to reward "fusion," where multiple operations are performed in a single cache-friendly loop.

In Zig, we can implement a `CostFunction` by defining a weight for each operation in our `Language` enum.

### 1. The Cost Definition

We’ll assign high costs to any operation that allocates and low costs to "fused" primitives or scalar operations.

```zig
const Cost = f32;

/// Define weights for different operations in the 'k' language
fn get_node_cost(node: MathOp) Cost {
    return switch (node) {
        // High cost: These operations usually require new memory allocation
        .Filter, .Rotate, .Reverse => 100.0,
        
        // Moderate cost: Standard array ops
        .Add, .Mul, .Div => 10.0,
        
        // Low cost: Accessing a variable or a constant
        .Var, .Const => 1.0,
        
        // Special: Fused operations are the cheapest way to do multiple things
        .FusedAddMul => 5.0, 
        
        // Metadata/Identity ops are effectively free
        .Identity => 0.0,
    };
}

```

---

### 2. The Greedy Extractor

The extraction process finds the cheapest "path" through the e-graph. Because e-graphs are recursive, we calculate the cost of an **E-Class** as:


Here is how you would implement this logic in Zig:

```zig
const Extractor = struct {
    costs: std.AutoHashMap(Id, Cost),
    best_nodes: std.AutoHashMap(Id, MathOp),

    /// Bottom-up pass to find the cheapest way to represent every E-Class
    pub fn find_best(self: *Extractor, egraph: *EGraph) !void {
        var changed = true;
        while (changed) {
            changed = false;
            
            // Iterate through every E-Class
            for (egraph.classes.items) |class| {
                var min_cost: Cost = std.math.inf(f32);
                var best_node: ?MathOp = null;

                // Find the cheapest node in this class
                for (class.nodes.items) |node| {
                    var current_cost = get_node_cost(node);
                    
                    // Add costs of children (if we know them yet)
                    for (node.children) |child_id| {
                        const child_root = egraph.union_find.find(child_id);
                        if (self.costs.get(child_root)) |c| {
                            current_cost += c;
                        } else {
                            current_cost = std.math.inf(f32);
                            break;
                        }
                    }

                    if (current_cost < min_cost) {
                        min_cost = current_cost;
                        best_node = node;
                    }
                }

                // If we found a cheaper way to represent this class, update it
                const class_id = egraph.union_find.find(class.id);
                const old_cost = self.costs.get(class_id) orelse std.math.inf(f32);
                if (min_cost < old_cost) {
                    try self.costs.put(class_id, min_cost);
                    try self.best_nodes.put(class_id, best_node.?);
                    changed = true;
                }
            }
        }
    }
};

```

---

### 3. Why this matters for the 'k' VM

In a standard **k** interpreter, `(a + b * c)` might be executed as:

1. `tmp1 = b * c` (Allocate vector)
2. `result = a + tmp1` (Allocate vector)

With the E-graph and this cost function:

1. The E-graph has an E-node for the separate `Add` and `Mul`.
2. A rewrite rule adds a `FusedAddMul` node to the same E-class.
3. The **Extractor** sees that `FusedAddMul` (Cost 5) is cheaper than `Add` + `Mul` (Cost 10 + 10).
4. The VM then emits a single specialized bytecode instruction that computes the result in one pass without the `tmp1` allocation.

### 4. Refining for Runtime: The "Fuel" Concept

Since you mentioned using this at **runtime**, you don't want the extractor to loop forever. In Zig, you can add a `fuel` parameter:

* Decrement `fuel` for every rewrite applied.
* Once `fuel == 0`, immediately run the `Extractor`.
* This guarantees that your VM stays responsive even if the optimization space is huge.

---

# Pattern Matching

E-matching is the process of finding all sub-graphs in your e-graph that match a specific pattern (like `(+ ?x 0)`).

In **egg**, and our Zig implementation, a pattern consists of **constants** (fixed operators/values) and **variables** (wildcards starting with `?`). The result of a match is a **Substitution**: a mapping of pattern variables to E-Class IDs.

---

### 1. Defining the Pattern Structure

In Zig, we can represent a pattern as a recursive data structure or a flattened array of "instructions." For simplicity, let's use a recursive enum.

```zig
const Pattern = union(enum) {
    Variable: []const u8, // e.g., "?x"
    Op: struct {
        kind: MathOpTag,  // e.g., .Add
        args: []const Pattern,
    },
    Const: i32,
};

// A mapping from "?x" -> EClassId
const Substitutions = std.StringHashMap(u32);

```

---

### 2. The Matching Engine

The matching engine explores the e-graph. When it hits a **Variable**, it binds that variable to the current E-Class. When it hits an **Op**, it checks if any E-Node in the current E-Class matches that operator.

```zig
pub fn matchPattern(
    egraph: *EGraph,
    pattern: Pattern,
    class_id: u32,
    subs: *Substitutions,
) !bool {
    const root_id = egraph.union_find.find(class_id);

    switch (pattern) {
        .Variable => |name| {
            // If the variable is already bound, it must match the same class
            if (subs.get(name)) |existing_id| {
                return existing_id == root_id;
            }
            // Otherwise, bind the variable to this class
            try subs.put(name, root_id);
            return true;
        },

        .Const => |val| {
            const class = egraph.classes.get(root_id);
            for (class.nodes.items) |node| {
                if (node == .Const and node.Const == val) return true;
            }
            return false;
        },

        .Op => |op| {
            const class = egraph.classes.get(root_id);
            // Search all nodes in this class to see if any match the operator
            for (class.nodes.items) |node| {
                if (std.meta.activeTag(node) != op.kind) continue;

                // If the operator matches, try matching the children recursively
                var match_all = true;
                var backup_subs = try subs.clone();
                defer backup_subs.deinit();

                const node_children = get_children(node); // helper to get IDs
                for (op.args, 0..) |arg_pat, i| {
                    if (!try matchPattern(egraph, arg_pat, node_children[i], subs)) {
                        match_all = false;
                        // Roll back substitutions for this branch
                        subs.* = try backup_subs.clone();
                        break;
                    }
                }
                if (match_all) return true;
            }
            return false;
        },
    }
}

```

---

### 3. Making it Efficient (The "Zig Way")

The recursive approach above is simple but slow because of the cloning and string hashing. To make this production-ready for your **k** VM:

1. **Integer IDs for Variables:** Instead of string names like `?x`, use `u32` IDs at compile-time or parse-time.
2. **The Pattern VM:** Instead of a recursive tree, "compile" your pattern into a sequence of bytecode instructions for the matcher itself.
* `CHECK_OP .Add`
* `BIND_VAR 0` (for `?x`)
* `CHECK_CHILD 1`


3. **Relational Matching:** If you have many patterns, use a **Join**-based approach. Treat your E-nodes as rows in a database table: `AddTable(ParentID, LeftID, RightID)`. Matching then becomes a SQL-like join, which can be optimized using **Worst-Case Optimal Join** algorithms.

---

### 4. Integration Example: `x + 0 => x`

This is how a rewrite rule uses the matcher in the background:

1. **Find:** Call `matchPattern` for `(+ ?x 0)` on every class in the E-graph.
2. **Check:** If a match is found, `subs` will contain `{"?x": 123}` (where 123 is the ID of some e-class).
3. **Apply:** Call `egraph.union(original_class_id, 123)`.
4. **Rebuild:** The E-graph now knows that adding 0 to that specific class is equivalent to the class itself.

### How this benefits your 'k' VM

In **k**, many identities are algebraic: `&/x` (min of x) where x is a boolean is just a "logical AND" across the array (if the array is a bytearray, otherwise this is a min). You can match the pattern `(Min ?x)` and, if the **Analysis** metadata tells you `?x` is boolean, rewrite it to a specialized `(BoolAll ?x)` bytecode which is significantly faster.

# Comptime parsing

Zig’s `comptime` is essentially a superpower for this. Instead of parsing your optimization rules every time your VM starts up, you can bake them directly into the binary as efficient data structures.

To do this, we’ll write a recursive descent parser that runs entirely at compile-time.

---

## 1. The Comptime Pattern Parser

We need a way to turn a string like `"(+ ?x 0)"` into our `Pattern` enum. In Zig, if a function's arguments are known at compile-time, the function can be executed by the compiler.

```zig
const std = @import("std");

/// A simplified Pattern for demonstration
pub const Pattern = union(enum) {
    Variable: []const u8,
    Op: struct { tag: []const u8, args: []const Pattern },
    Const: i32,
};

/// The parser: It takes a string and returns a Pattern.
/// Since it returns a recursive structure, we use a 'comptime' block.
pub fn parsePattern(comptime input: []const u8) Pattern {
    @setEvalBranchQuota(2000); // Give the compiler more room to work
    
    // Minimalistic tokenizer logic
    const trimmed = std.mem.trim(u8, input, " ");
    
    if (trimmed[0] == '(') {
        // It's an S-expression: (+ ?x 0)
        const content = trimmed[1 .. trimmed.len - 1];
        var iter = std.mem.tokenizeScalar(u8, content, ' ');
        
        const op_name = iter.next() orelse unreachable;
        
        // Count args to size the array
        var arg_count: usize = 0;
        var count_iter = std.mem.tokenizeScalar(u8, content, ' ');
        _ = count_iter.next(); // skip op
        while (count_iter.next()) |_| arg_count += 1;

        // Comptime-allocated array for children
        var args: [arg_count]Pattern = undefined;
        var i: usize = 0;
        iter = std.mem.tokenizeScalar(u8, content, ' ');
        _ = iter.next(); // skip op
        
        while (iter.next()) |arg_text| : (i += 1) {
            args[i] = parsePattern(arg_text);
        }

        return .{ .Op = .{ .tag = op_name, .args = &args } };
    } else if (trimmed[0] == '?') {
        return .{ .Variable = trimmed };
    } else {
        const val = std.fmt.parseInt(i32, trimmed, 10) catch unreachable;
        return .{ .Const = val };
    }
}

```

---

## 2. Using it in your VM

Because this is `comptime`, you can define your ruleset as a `const`. The compiler will validate the syntax and generate the tree before the code even runs.

```zig
const rules = [_]struct { name: []const u8, lhs: Pattern, rhs: Pattern }{
    .{
        .name = "add-zero",
        .lhs = parsePattern("(+ ?x 0)"),
        .rhs = parsePattern("?x"),
    },
    .{
        .name = "mul-identity",
        .lhs = parsePattern("(* ?x 1)"),
        .rhs = parsePattern("?x"),
    },
};

```

## 4. Performance Check: `comptime` vs Runtime

| Feature | Traditional Parsing | Zig `comptime` |
| --- | --- | --- |
| **Startup Time** | Slow (parsing/loading) | Instant (pre-built structs) |
| **Error Handling** | Runtime crashes/logs | Compilation errors |
| **Binary Size** | Strings + Parser code | Compact data structures |

### A Note on "The Wall"

In Zig, `comptime` has a "branch quota" (the `@setEvalBranchQuota` I used above). If you try to parse a 10,000-line optimization file at compile-time, the compiler might get grumpy. For a typical **k** VM with ~100 rules, this approach is perfectly snappy.

# Rewrite Engine

To wrap this all up, the **Rewrite Engine** (or "Runner") is the orchestrator. It performs the "Equality Saturation" loop: it searches for matches, applies them by adding new nodes and merging e-classes, and then restores invariants via rebuilding.

In Zig, we can make this very efficient by batching our modifications to avoid constant graph reconstruction.

## 1. The Rewrite Rule Structure

A rule consists of a Left-Hand Side (LHS) to search for and a Right-Hand Side (RHS) to "instantiate" (build) in the graph.

```zig
pub const Rewrite = struct {
    name: []const u8,
    lhs: Pattern,
    rhs: Pattern,

    pub fn apply(self: Rewrite, egraph: *EGraph, allocator: std.mem.Allocator) !bool {
        var changed = false;
        // 1. Search: Find all matches for the LHS
        const matches = try egraph.ematch(self.lhs, allocator);
        defer matches.deinit();

        for (matches.items) |match| {
            // match.id is the E-Class where the pattern was found
            // match.subs is the map of variables like "?x" -> eclass_id

            // 2. Instantiate: Build the RHS into the graph using the variable bindings
            const rhs_id = try egraph.instantiate(self.rhs, match.subs);

            // 3. Union: Inform the graph that LHS == RHS
            if (egraph.unionSets(match.id, rhs_id)) {
                changed = true;
            }
        }
        return changed;
    }
};

```

## 2. Instantiation: Turning Patterns into E-Nodes

When a rule matches, we need to add the RHS to the graph. If the RHS is `(?x + 0) -> ?x`, and `?x` matched E-Class `5`, we don't need to build anything; we just point to class `5`. If it's more complex, we recursively add nodes.

```zig
pub fn instantiate(self: *EGraph, pattern: Pattern, subs: Substitutions) !u32 {
    switch (pattern) {
        .Variable => |name| {
            // Return the E-Class ID that the variable matched to
            return subs.get(name) orelse return error.UnboundVariable;
        },
        .Const => |val| {
            return try self.addNode(.{ .Const = val });
        },
        .Op => |op| {
            // Recursively instantiate children first
            var child_ids: [8]u32 = undefined; // Assumes max arity of 8
            for (op.args, 0..) |arg, i| {
                child_ids[i] = try self.instantiate(arg, subs);
            }
            // Add the new operator node pointing to these children
            return try self.addNode(.{ .tag = op.tag, .children = child_ids[0..op.args.len] });
        },
    }
}

```

## 3. The Saturation Loop (The Runner)

This is where your **k** VM spends its "optimization time." It keeps applying rules until the graph stops growing (saturation) or you hit a limit.

```zig
pub fn saturate(egraph: *EGraph, rules: []const Rewrite) !void {
    var iteration: u32 = 0;
    while (iteration < 30) : (iteration += 1) {
        var changed = false;

        for (rules) |rule| {
            if (try rule.apply(egraph, egraph.allocator)) {
                changed = true;
            }
        }

        if (!changed) break; // We reached saturation!

        // Crucial: Re-establish congruence after all rules have been applied
        try egraph.rebuild();
        
        // Safety check for runtime: don't let the graph explode
        if (egraph.totalNodes() > 10000) break;
    }
}

```

## 4. Putting it together for a 'k' expression

Imagine your **k** code is `+/!10` (Sum of first 10 integers).

1. **Initial Graph:** A node for `Range(10)` pointing to a `Sum` node.
2. **Match:** A rule matches `Sum(Range(?n))` which is the formula .
3. **Instantiate:** The engine builds the math expression `(10 * (10 - 1)) / 2` into the graph.
4. **Union:** The engine says the "Sum" node is equivalent to this "Math" node.
5. **Extract:** Your cost function sees that the "Math" node has  cost while the "Sum" node has  cost.
6. **Execute:** The VM executes the constant math and returns `45` without ever creating an array or running a loop.

### Why Zig is the right choice here:

* **Manual Memory Control:** In the `apply` step, we can use a **Stack Fallback Allocator**. If a rule only has a few matches, it stays on the CPU stack. If it has thousands, it spills to the heap.
* **Data Locality:** By storing e-nodes in a simple array (as seen in our `UnionFind` and `EGraph` logic), the `rebuild()` step is extremely cache-friendly.
* **No Hidden Overhead:** Unlike a JIT written in a high-level language, your Zig-based optimizer won't trigger a GC pause while it's trying to optimize your **k** code.

# SIMD optimalization

In a data-oriented e-graph implementation, SIMD is the ultimate "cheat code" for the **E-matching** phase. Since E-matching requires scanning through many E-nodes to find specific operators, we can use Zig's `@Vector` to check multiple nodes in a single CPU cycle.

To make this work, we should use **Data-Oriented Design (DOD)**. Instead of an array of objects, we store our E-nodes in a **Struct of Arrays (SoA)** format.

## 1. Data-Oriented E-Node Storage

Instead of `ArrayList(ENode)`, we use `MultiArrayList`. This puts all the operator "tags" (e.g., `Add`, `Mul`) in one contiguous block of memory.

```zig
const ENodeTags = enum(u8) { Add, Mul, Const, Var, ... };

// In our E-Graph
tags: []u8,        // Contiguous array of E-node tags
children: [][2]u32, // Contiguous array of child IDs

```

## 2. SIMD Vectorized Search

When searching for the `.Add` operator, instead of checking one byte at a time, we can check 16 or 32 bytes at once using SIMD.

```zig
const std = @import("std");

pub fn findNodesSimd(tags: []u8, target_tag: u8) void {
    const vector_size = 32; // Use 256-bit vectors (32 bytes)
    const Vec = @Vector(vector_size, u8);
    
    // Create a vector filled with the tag we are looking for
    const target_vec: Vec = @splat(target_tag);
    
    var i: usize = 0;
    while (i + vector_size <= tags.len) : (i += vector_size) {
        // 1. Load 32 tags from memory
        const current_chunk: Vec = tags[i..][0..vector_size].*;
        
        // 2. Compare all 32 tags simultaneously
        const mask = current_chunk == target_vec;
        
        // 3. If any bit in the mask is true, we found matches!
        if (@reduce(.Or, mask)) {
            // Process individual matches in this chunk
            // (In a high-perf VM, we'd use bit manipulation on the mask here)
            for (0..vector_size) |j| {
                if (mask[j]) {
                    const node_id = i + j;
                    // Found a match at node_id!
                }
            }
        }
    }
    // ... handle remainder of the slice ...
}

```

## 3. Why this kills for 'k' and Array Languages

In **k**, your bytecode is often just a stream of primitive tags. When the E-graph is looking for opportunities to apply a rule like `(sum (range ?x))`, it needs to find every instance of `sum` in the graph.

* **Scalar:** The CPU checks `node[0]`, then `node[1]`, then `node[2]`...
* **SIMD:** The CPU asks, "In this block of 32 nodes, which ones are `sum`?" and gets a bitmask back in ~1-3 cycles.

This reduces the complexity of the "Search" phase from  to , where  is the number of nodes in your e-graph.

## 4. Advanced: SIMD for Analysis

If your **E-Class Analysis** involves checking if multiple children are constants (for constant folding), you can use SIMD to perform the check across multiple E-nodes at once:

1. Load the **LeftChildIDs** into one vector.
2. Load the **RightChildIDs** into another.
3. Load the **IsConstant** boolean flags for all those IDs using a "Gather" operation.
4. `AND` the vectors to find every node where both children are constants.

### Performance Gains

| Method | Ops per Cycle | Bandwidth |
| --- | --- | --- |
| **Naive Recursive** |  | Very Low (Pointer chasing) |
| **Linear Scalar** |  | Moderate (Cache friendly) |
| **Zig SIMD** | **16–64** | **High** (Saturation of memory bus) |

## The Ultimate "k" Optimizer

By combining **Zig's `comptime**` (to generate the rules) and **SIMD** (to execute them), you end up with an optimizer that can process thousands of equality saturations in microseconds. This is fast enough to run **inside the inner loop of a JIT**, optimizing code as it is being executed.

# Flat Instruction Buffer

In the end the graph needs to be lowered into a flat instruction buffer so it can be executede on a VM.

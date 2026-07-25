/ demo/todo.k — a todo-list editor on the tables-as-ECS UI + flexbox layout (lib/ui.k).
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/todo.k
/ Headless snapshot:    ink -snap 0.4 demo/todo.k   (writes todo-snap.png)
/
/ Each task is a row: a toggle button ([ ] / [x]) marks it done, an INLINE INPUT edits its text, and
/ an ✗ button deletes it. The bottom bar adds a new task. Click a task's text to edit it in place.
/
/ Model = ONE TABLE `todo.T` with `text`done` columns; row index = list position. Ops: add =
/ `T,rowDict`; toggle = deep in-place amend `T[`done;i]::…`; delete indexes the surviving rows;
/ #done = `+/T`done`. Adding a column (priority, due) needs no other change.
/
/ EDITING & ui.get/ui.set. The view is a PURE function rebuilt every frame, so a widget can't hold
/ its own state — an `ui.input[key;…]`'s live text lives in a framework buffer `ui.buf[key]` keyed by
/ the widget id (the imgui "storage" trick). `ui.get[key]`/`ui.set[key;s]` read/write that buffer.
/ Each frame `todo.sync` reconciles buffer↔model: a FOCUSED field commits its buffer INTO the table
/ (live edit); an unfocused one loads the table's text back into its buffer (so add/delete/toggle and
/ position shifts show up). Same pattern as demo/cells.k's formula bar.
/
/ WIDGET KEYS ARE POSITIONAL, NOT PER-TASK. Each per-row button/field needs a distinct action symbol
/ (`t<i>` toggle, `d<i>` delete, `e<i>` edit-field); the dispatcher decodes a click back to its row
/ with `?` (find). We key by ROW POSITION (`t0`,`t1`,…), NOT a monotonic task id — because symbols
/ are INTERNED FOREVER (never freed), so id-keyed symbols would leak one triple per task ever created.
/ Positional keys are reused (`t0` is always row 0), so the pool is bounded by the longest the list
/ ever gets. Delete-while-editing is safe: clicking any button defocuses, and `sync` commits the
/ focused edit at the top of the frame, before the click is dispatched.
/
/ Fully-qualified namespace (no `\d`), matching the rest of the UI stack.

2: "lib/ui.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0

/ ── palette ──────────────────────────────────────────────────────────────────
todo.DONEFG: 0.55 0.58 0.62 1.                   / muted grey for a completed task
todo.OPENFG: 0.12 0.13 0.16 1.

/ ── model: one table (text, done); `#todo.T` = row count ──────────────────────
todo.T::+`text`done!(();0#0b)

todo.addDo:{[t] todo.T,::`text`done!(t;0b); ui.set[`new; ""]}
todo.add:{[] t:ui.get`new; $[0=#t; 0; todo.addDo t]}
todo.toggle:{[i] $[i<#todo.T; todo.T[`done;i]::~todo.T[`done;i]; 0]}     / deep in-place amend
todo.remove:{[i] todo.T::todo.T[; &~(!#todo.T)=i]}                       / keep every row but i

/ ── positional widget keys (reused across tasks → bounded symbol pool) ────────
todo.ekey:{[i] `s$"e",$i}                          / edit-field key for row i
todo.togSyms:{{`s$"t",$x}'!#todo.T}                / `t0`t1… — one per current row
todo.delSyms:{{`s$"d",$x}'!#todo.T}                / `d0`d1…

/ ── inline-edit sync: reconcile each row's edit-field buffer with the table ────
todo.syncRow:{[i] k:todo.ekey i
  $[ui.isFocus k; todo.T[`text;i]:: ui.get k; ui.set[k; todo.T[`text;i]]]}
todo.sync:{{todo.syncRow x}'!#todo.T}              / call once per frame, before ui.run

/ ── action dispatch: `?` maps a clicked action symbol back to its row position ─
todo.act:{[a]
  ti: (todo.togSyms[])?a                            / row position if a toggle was clicked, else #T
  di: (todo.delSyms[])?a
  $[a~`add; todo.add[]
    ti<#todo.T; todo.toggle ti
    di<#todo.T; todo.remove di
    0]}

/ ── view ─────────────────────────────────────────────────────────────────────
todo.count:{+/todo.T`done}                         / number done
todo.rowView:{[i] done:todo.T[`done;i]
  ui.row[8.; (
    ui.button[$[done;"[x]";"[ ]"]; `s$"t",$i]
    @[ui.input[todo.ekey i; 300.; "task"]; `fg; :; $[done; todo.DONEFG; todo.OPENFG]]
    ui.button["x"; `s$"d",$i] )]}
todo.rows:{{todo.rowView x}'!#todo.T}
todo.addBar:{ui.row[8.; ( ui.input[`new; 300.; "add a task..."] ; ui.button["Add"; `add] )]}
todo.status:{ui.label[($todo.count[])," of ",($#todo.T)," done"]}
todo.view:{[]
  ui.bg[0.96 0.96 0.98 1.; ui.pad[24.; ui.col[12.;
    ((ui.label["TODO"]; todo.addBar[]; todo.status[]), todo.rows[]), (,ui.spacer[]) ]]]}

/ ── seed a couple of tasks ───────────────────────────────────────────────────
todo.addDo "buy milk"
todo.addDo "write ink docs"
todo.addDo "ship the todo demo"
todo.toggle 0

run:{[props]
  todo.sync[]                                       / reconcile edit fields ↔ table (commits last edit)
  W: ui.run[todo.view[]; props]
  {todo.act x}' ui.frame[W; props]
  ui.draw[ui.run[todo.view[]; props]; props`width; props`height]}

window.run[run; 440. 520.]

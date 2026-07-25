/ demo/todo.k — a todo-list editor on the tables-as-ECS UI + flexbox layout (lib/ui.k).
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/todo.k
/ Headless snapshot:    ink -snap 0.4 demo/todo.k   (writes todo-snap.png)
/
/ Each task is a row: a toggle button ([ ] / [x]) marks it done, an INLINE INPUT edits its text, and
/ an ✗ button deletes it. The bottom bar adds a new task. Click a task's text to edit it in place.
/
/ Model = ONE TABLE `todo.T` with `id`text`done` columns. `id` is a stable per-task key so a row's
/ edit-field survives adds/deletes (positions shift, ids don't). Ops: add = `T,rowDict`; toggle =
/ deep in-place amend `T[`done;i]::…`; delete indexes the surviving rows; #done = `+/T`done`.
/
/ EDITING & ui.get/ui.set. The view is a PURE function rebuilt every frame, so a widget can't hold
/ its own state — an `ui.input[key;…]`'s live text lives in a framework buffer `ui.buf[key]` keyed by
/ the widget id (the imgui "storage" trick). `ui.get[key]`/`ui.set[key;s]` read/write that buffer.
/ Each frame `todo.sync` reconciles buffer↔model: a FOCUSED field commits its buffer INTO the table
/ (live edit); an unfocused one loads the table's text back into its buffer (so external changes and
/ add/delete show up). Same pattern as demo/cells.k's formula bar.
/
/ Per-row buttons carry a unique action symbol (`t<id>` toggle, `d<id>` delete); the dispatcher maps
/ the clicked symbol back to its ROW POSITION with `?` (find) — no string→int parsing needed.
/ Fully-qualified namespace (no `\d`), matching the rest of the UI stack.

2: "lib/ui.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0

/ ── palette ──────────────────────────────────────────────────────────────────
todo.DONEFG: 0.55 0.58 0.62 1.                   / muted grey for a completed task
todo.OPENFG: 0.12 0.13 0.16 1.

/ ── model: one table (id, text, done); `#todo.T` = row count ──────────────────
todo.T: +`id`text`done!(0#0; (); 0#0b)
todo.seq: 0
todo.nextId:{[] n:todo.seq; todo.seq:: todo.seq+1; n}

todo.addDo:{[t] todo.T,::`id`text`done!(todo.nextId[]; t; 0b); ui.set[`new; ""]}
todo.add:{[] t:ui.get`new; $[0=#t; 0; todo.addDo t]}
todo.toggle:{[i] $[i<#todo.T; todo.T[`done;i]::~todo.T[`done;i]; 0]}     / deep in-place amend
todo.remove:{[i] todo.T::todo.T[; &~(!#todo.T)=i]}                       / keep every row but i

/ ── inline-edit sync: a per-row input keyed by the task's stable id ───────────
todo.ekey:{[id] `s$"e",$id}
todo.syncRow:{[i] id:todo.T[`id;i]; k:todo.ekey id
  $[ui.isFocus k; todo.T[`text;i]::ui.get k; ui.set[k; todo.T[`text;i]]]}
todo.sync:{[] {todo.syncRow x}'!#todo.T}          / call once per frame, before ui.run

/ ── action dispatch: symbols carry the task id; `?` finds its current row position ─
todo.togSyms:{[] {`s$"t",$x}'todo.T`id}
todo.delSyms:{[] {`s$"d",$x}'todo.T`id}
todo.act:{[a]
  ti: (todo.togSyms[])?a                          / row position if a toggle was clicked, else #T
  di: (todo.delSyms[])?a
  $[a~`add; todo.add[]
    ti<#todo.T; todo.toggle ti
    di<#todo.T; todo.remove di
    0]}

/ ── view ─────────────────────────────────────────────────────────────────────
todo.count:{[] +/todo.T`done}                     / number done
todo.rowView:{[i] id:todo.T[`id;i]; done:todo.T[`done;i]
  ui.row[8.; (
    ui.button[$[done;"[x]";"[ ]"]; `s$"t",$id]
    @[ui.input[todo.ekey id; 300.; "task"]; `fg; :; $[done; todo.DONEFG; todo.OPENFG]]
    ui.button["x"; `s$"d",$id] )]}
todo.rows:{[] {todo.rowView x}'!#todo.T}
todo.addBar:{[] ui.row[8.; ( ui.input[`new; 300.; "add a task..."] ; ui.button["Add"; `add] )]}
todo.status:{[] ui.label[($todo.count[])," of ",($#todo.T)," done"]}
todo.view:{[]
  ui.bg[0.96 0.96 0.98 1.; ui.pad[24.; ui.col[12.;
    ((ui.label["TODO"]; todo.addBar[]; todo.status[]), todo.rows[]), (,ui.spacer[]) ]]]}

/ ── seed a couple of tasks ───────────────────────────────────────────────────
todo.addDo "buy milk"
todo.addDo "write ink docs"
todo.addDo "ship the todo demo"
todo.toggle 0

run:{[props]
  todo.sync[]                                     / reconcile edit fields ↔ table (commits last edit)
  W: ui.run[todo.view[]; props]
  {todo.act x}' ui.frame[W; props]
  ui.draw[ui.run[todo.view[]; props]; props`width; props`height]}

window.run[run; 440. 520.]

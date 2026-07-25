/ demo/todo.k — a todo-list editor on the tables-as-ECS UI + flexbox layout (lib/ui.k).
/ Build GPU lib first:  zig build gpu
/ Run:                  ink demo/todo.k
/ Headless snapshot:    ink -snap 0.4 demo/todo.k   (writes todo-snap.png)
/
/ Type a task in the input and click Add. Each task renders as a row: a toggle button ([ ] / [x])
/ that marks it done, the task text (greyed when done), and an ✗ button that deletes it. Model = ONE
/ TABLE `todo.T` with `text`done` columns, row index = list position — add is `T,rowDict`, toggle is
/ a deep in-place amend `T[`done;i]::…`, delete indexes the surviving rows, and a query like `#done`
/ tasks is `+/T`done`. Adding a column (id, priority, due) needs no other change. Per-row buttons
/ carry a unique action symbol (`t<i>` toggle, `d<i>` delete); the dispatcher maps the clicked symbol
/ back to its row with `?` (find) — no string→int parsing needed.
/
/ Fully-qualified namespace (no `\d`), matching the rest of the UI stack.

2: "lib/ui.k"
ui.setFont (font.read "font/FiraCode-Regular.ttf") 0

/ ── palette ──────────────────────────────────────────────────────────────────
todo.DONEFG: 0.55 0.58 0.62 1.                   / muted grey for a completed task
todo.OPENFG: 0.12 0.13 0.16 1.

/ ── model: one table; row index = list position ──────────────────────────────
todo.T: +`text`done!(();0#0b)                    / columns: task text (C…) + done flag (bool)
todo.n:{[] #todo.T`text}                         / row count

todo.addDo:{[t] todo.T:: todo.T,`text`done!(t;0b); ui.set[`new; ""]}
todo.add:{[] t:ui.get`new; $[0=#t; 0; todo.addDo t]}
todo.toggle:{[i] $[i<todo.n[]; todo.T[`done;i]:: ~todo.T[`done;i]; 0]}   / deep in-place amend
todo.remove:{[i] todo.T:: todo.T[; &~(!todo.n[])=i]}                     / keep every row but i

/ per-row action symbols, rebuilt from the current count so the dispatcher can find a click's row.
todo.togSyms:{[] {`s$"t",$x}'!todo.n[]}
todo.delSyms:{[] {`s$"d",$x}'!todo.n[]}
todo.act:{[a]
  ti: (todo.togSyms[])?a                         / row index if a toggle was clicked, else n
  di: (todo.delSyms[])?a
  $[a~`add; todo.add[]
    ti<todo.n[]; todo.toggle ti
    di<todo.n[]; todo.remove di
    0]}

/ ── view ─────────────────────────────────────────────────────────────────────
todo.count:{[] +/todo.T`done}                    / number done
todo.rowView:{[i] done:todo.T[`done;i]; txt:todo.T[`text;i]
  ui.row[8.; (
    ui.button[$[done;"[x]";"[ ]"]; `s$"t",$i]
    ui.sized[300.;34.; ui.bg[1. 1. 1. 1.; ui.pad[6.;
      @[ui.label txt; `fg; :; $[done; todo.DONEFG; todo.OPENFG]] ]]]
    ui.button["x"; `s$"d",$i] )]}
todo.rows:{[] {todo.rowView x}'!todo.n[]}
todo.addBar:{[] ui.row[8.; ( ui.input[`new; 320.; "add a task..."] ; ui.button["Add"; `add] )]}
todo.status:{[] ui.label[($todo.count[])," of ",($todo.n[])," done"]}
todo.view:{[]
  ui.bg[0.96 0.96 0.98 1.; ui.pad[24.; ui.col[12.;
    ((ui.label["TODO"]; todo.addBar[]; todo.status[]), todo.rows[]), (,ui.spacer[]) ]]]}

/ ── seed a couple of tasks ───────────────────────────────────────────────────
todo.addDo "buy milk"
todo.addDo "write ink docs"
todo.addDo "ship the todo demo"
todo.toggle 0

run:{[props]
  W: ui.run[todo.view[]; props]
  {todo.act x}' ui.frame[W; props]
  ui.draw[ui.run[todo.view[]; props]; props`width; props`height]}

window.run[run; 440. 520.]

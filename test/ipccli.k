/ test/ipccli.k — asserts the binary IPC layer against test/ipcback.k (an echo
/ backend) and test/ipcgate.k (an async gateway).
/ Run: sh test/ipc.sh

ok:{[nm;c] `0 0: nm," ",$[c;"ok";"FAIL"]}
iserr:{`"!"~@x}   / an error value has type `! (quote the glyph symbol)

/ ── every value class survives the wire ─────────────────────────────────────
/ the backend echoes (sq;payload), so send sq=0 and read field 1 back.
e: > "127.0.0.1:5211"
rt:{[v] e 2: (0;v); (2: e) 1}

ok["atom int";    42~rt 42]
ok["atom float";  0.45~rt 0.45]
ok["atom symbol"; `hi~rt `hi]
ok["atom char";   "a"~rt "a"]
ok["int vector";  1 2 3~rt 1 2 3]
ok["char vector"; "hello"~rt "hello"]

/ a lambda travels as source and is CALLABLE on the far side
f: rt[{[a;b] a*b}]
ok["lambda sent"; 42=f[6;7]]
/ so do a derived verb and a projection
ok["derived sent";    10=(rt[+/]) 1 2 3 4]
ok["projection sent"; 13=(rt[10+]) 3]

/ dicts, tables and keyed tables travel structurally, not as text
d: `a`b!(1 2;"xy")
ok["dict";        d~rt d]
tb: ([]a:1 2;b:`x`y)        / not `t` — a global named `t` hangs, .plan/triage.md #27
ok["table";       tb~rt tb]
kt: ([i:1 2]v:`x`y)
ok["keyed table"; kt~rt kt]

/ ── runtime services ────────────────────────────────────────────────────────
ok["peer";      "127.0.0.1:5211"~`peer[e]]
ok["conns";     e in `conns[]]
ok["timer off"; 0=`timer[]]
t0: `t[]
`sleep[30]
ok["sleep";     25<(`t[]-t0)%1000]

/ a dead address is an error VALUE, not a thrown error — this is what a
/ reconnect loop tests on each tick.  (Bracket the argument: a bare `>` after a
/ name reads as the DYADIC verb.)
ok["dead port"; iserr[> "127.0.0.1:1"]]

/ a handler that fails replies with the error instead of leaving us blocked
e 2: (0;`boom)
ok["handler error"; iserr[2: e]]

< e

/ ── the async gateway: a reply that arrives out of band ─────────────────────
/ the gateway answers on a handle it parked earlier, from a DIFFERENT dispatch
/ than the one the query arrived on.  Before dyadic handlers this was
/ inexpressible: a process could only answer whoever it was mid-dispatch for.
g: > "127.0.0.1:5210"
g 2: 7
ok["deferred reply"; (`res;7)~2: g]
< g

`0 0: "done"

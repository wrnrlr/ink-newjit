/ test/ipcgate.k — gateway for the IPC test: async in both directions.
/
/ This is the shape that needs a caller's identity.  `z.pg` is DYADIC, so it is
/ handed the handle the message came in on; it parks that handle, forwards the
/ query to the backend, and returns blank — no reply yet.  When the backend
/ answers (on a different handle, dispatched by `on`) the parked handle is what
/ the result is written to.  q spells that .z.w; ink spells it "take a second
/ argument".
/
/ Bookkeeping is two parallel vectors rather than a table: `table,table` does
/ not row-concat in ink.

sqs: !0                      / outstanding sequence numbers
uhs: !0                      / the client handle each one belongs to
seq: 0

bh: > "127.0.0.1:5211"       / one long-lived connection to the backend

/ backend answered (sq;payload) — hand it to whoever asked for sq
back:{[m]
  i: *&sqs=m 0
  uh: uhs i
  sqs:: sqs _ i
  uhs:: uhs _ i
  uh 2: (`res; m 1) }
`on[bh; back]

/ a client asked something: park the handle, forward, answer later
z.pg:{[h;m]
  seq:: seq+1
  sqs:: sqs,seq
  uhs:: uhs,h
  bh 2: (seq; m) }

z.po:{[h] `0 0: "gate: peer ",($h)," in"}
z.pc:{[h] `0 0: "gate: peer ",($h)," out"}

\p 5210

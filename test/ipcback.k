/ test/ipcback.k — backend service for the IPC test.
/ Run by test/ipc.sh; see test/ipccli.k for what is asserted.
/
/ A query arrives as (sq;payload) and the answer goes back as (sq;payload) so
/ the gateway can match it to the client that is waiting.  Returning a value
/ from `pg` replies on the same handle — the plain synchronous shape.

/ `boom asks for a handler failure: the error must come BACK as a value rather
/ than leave the caller blocked on `2: h` forever.
pg:{[m] $[(m 1)~`boom; 1+`x; m]}

\p 5211

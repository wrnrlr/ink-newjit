/ server.k — start a TCP server, handle one request, reply, exit
/
/ usage:  ink test/server.k
/
/ Convention (the TEXT protocol — see test/ipcback.k for the binary one):
/   > port    listen on port, block until first client connects → handle h
/   0: h      read one newline-terminated message from h
/   h 0: msg  write newline-terminated message to h
/   < h       close handle h
/
/ `> port` with a POSITIVE port blocks here for one client and then hands the
/ script the handle.  A negative port (or `\p port`) listens without blocking and
/ dispatches through the event loop instead.

`0 0: "server: listening on port 5001"

h: > 5001                     / open server on port 5001

`0 0: "server: client connected"

msg: 0: h                     / read message from client

`0 0: "server: received: ", msg

h 0: "echo:", msg             / send echo reply

< h                           / close connection

`0 0: "server: done"

/ client.k — connect to a running server, send a message, print reply
/
/ usage:  ink test/client.k
/
/ Convention (the TEXT protocol — see test/ipccli.k for the binary one):
/   > "host:port"   connect to server → handle h  (positive integer)
/   h 0: msg        write one newline-terminated message
/   0: h            read one newline-terminated message (blocks until data arrives)
/   < h             close handle h
/
/ There is no negative-handle form: whether a send is answered is decided by the
/ REMOTE side (a `z.pg` handler replies, a `z.ps` handler does not), not by the
/ sender. See doc/reference.md "IPC".
/
/ Start the server first:  ink test/server.k

h: > "127.0.0.1:5001"         / connect to server

`0 0: "client: connected"

h 0: "hello from ink"         / send message (sync)

resp: 0: h                    / receive reply

`0 0: "client: reply: ", resp

< h                           / close connection

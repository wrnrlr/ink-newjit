/ client.k — connect to a running server, send a message, print reply
/
/ usage:  ink test/client.k
/
/ Convention:
/   > "host:port"   connect to server → handle h  (positive integer)
/   h 0: msg        synchronous write (send, no wait for reply)
/   -h 0: msg       asynchronous write (fire-and-forget, same as sync for now)
/   0: h            read one newline-terminated message (blocks until data arrives)
/   < h             close handle h
/
/ Start the server first:  ink test/ipc_server.k

h: > "127.0.0.1:5001"         / connect to server

`0 0: "client: connected"

h 0: "hello from ink"         / send message (sync)

resp: 0: h                    / receive reply

`0 0: "client: reply: ", resp

< h                           / close connection

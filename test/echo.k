/ echo.k — binary IPC echo server
/
/ usage:  ink test/echo.k
/
/ >-5005 opens port 5005 async and enters the event loop after the script.
/ h 2: lambda  attaches a per-handle callback; return value is sent back.
/ The client sends any value with `handle 2: value`; the server echoes it.

h: <`:5005
h 2: {[msg] msg}

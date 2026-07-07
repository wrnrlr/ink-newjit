/ echo.k — binary IPC echo server
/ The client sends any value with `handle 2: value`; the server echoes it.

h: <`:5005
h 2: {[msg] msg}

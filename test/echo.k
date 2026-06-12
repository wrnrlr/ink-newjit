/ echo.k — simple echo server
/ \p sets the port; the interpreter enters its event loop after the script runs.
/ pg is the sync message handler — return value is sent back as a reply.

\p 5002

h: >-

pg: {[msg] "echo: ", msg}

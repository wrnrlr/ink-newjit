/ stdio.k — echo stdin to stdout using raw byte IO (the LSP/Jupyter framing base)
/
/ usage:  printf 'hello' | ink test/stdio.k   → hello   (no trailing newline)
/
/ Conventions:
/   1: `stdin        read up to 64 KiB of available bytes; "" at EOF
/   `stdout 1: data  write raw bytes, no newline, flush
/   `stderr 1: data  same, to stderr (safe to log beside a stdout protocol)

`stderr 1: "stdio: echoing stdin\n"

/ While: read a chunk, echo it, read the next; stop when a read returns "" (EOF).
/ NB: no spaces around `/` — a space before the adverb breaks the While digram.
r: {[s]0<#s}{[s]`stdout 1: s; 1: `stdin}/(1: `stdin)

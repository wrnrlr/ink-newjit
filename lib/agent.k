/
# agent

A sketch of an agent loop: run a task until it reports done.

**Work in progress** — `ExecuteTask` has no body yet.

Pure k — loads on the first reference to any `agent.*` name.
\

done: 0b

task: "Review this code"

ExecuteTask: {~done} {[task]
  
}/

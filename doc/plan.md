# Epic: Ink Version 0.1 Release

## Extend system architecture and operating system support.
Build the `ink` binairy for Windows and Linux and suppport x86 architectures.
The JIT does not need to be ported yet can remain mac os only for now.


## Write Tutorial
Write a tutorial for the ink language in `doc/tutorial.md`.
Write so a user or a coding agent can quickly start proding ink code.
Base the ink code on what you write and test yourself via `ink` command line.
Partial reference specification for ink language: `doc/spec.md`
Should you find any issues or bugs add them to `doc/bug.md`.
Example code in `test/`, check demo using draw api `test/demo`.
See also `AGENT.md`
Tutorial should mention:
- install from source
- setup shell `rlwrap` and readline
- ink useage repl, run file
- Quick language introduction

## Add `make release` task 

## Support shapefiles

## Perform Security Review
Perform a security review of this project.
Is there memory unsafe code?

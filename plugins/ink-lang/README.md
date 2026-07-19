# ink-lang — Claude Code plugin for the Ink language

Teaches Claude to write, run, and debug [Ink](https://github.com/wrnrlr/ink-newjit)
programs from any project: core language + parsing gotchas, the standard libraries
(json, csv, http, llm, crypto, compress, zip, image, audio, font, regex, parquet,
safetensors), and the GPU compute / dye shader dialect.

## Contents

- `skills/ink/SKILL.md` — the skill: toolchain, crash course, silent-failure rules
  - `references/language.md` — condensed verb/adverb/type/IO reference
  - `references/gotchas.md` — failure modes by category (parsing, scope, numerics, …)
  - `references/libraries.md` — library APIs
  - `references/gpu.md` — graphics, compute, shader dialect

## Prerequisites

The skill drives the `ink` binary — install the runtime first:

```sh
git clone git@github.com:wrnrlr/ink-newjit.git ink && cd ink
make install        # builds and populates ~/.ink (binary, lib/, tools/)
```

Ensure `ink` is on PATH (or symlink `~/.ink/ink` into a PATH dir). Libraries
autoload from `$INK_HOME/lib` (default `~/.ink`), so the skill works from any
working directory.

## Install the plugin

From the marketplace at the repo root (works for any git host clone URL too):

```
/plugin marketplace add wrnrlr/ink-newjit
/plugin install ink-lang@ink
```

From a local checkout (development):

```
/plugin marketplace add /path/to/ink
/plugin install ink-lang@ink
```

Alternatively, skip plugins entirely and copy (or symlink) the skill into your
personal skills directory:

```sh
ln -s /path/to/ink/plugins/ink-lang/skills/ink ~/.claude/skills/ink
```

## Updating

The skill files are plain markdown — edit, then `/plugin marketplace update ink`
(or nothing at all if you used the symlink route).

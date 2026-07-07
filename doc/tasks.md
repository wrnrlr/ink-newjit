# Tasks

## Rework library and namespaces
I want to change to way the module system works with auto-loading,
namespaces, variable resolution and fully qualified names.
From now on every k file in `./lib` should declared it's own namespace with the same name as the file. So image.k becomes the namespace image.
There should be one exception for the `./lib/_.k` file it should be added to the global namespace.
Other k files loaded with `\l filename.k` should also be in a namespace `filename`.
This means the ./src/cmd/module.zig and others should change.
Make sure the bundeling keeps working. The ./tools/zed-ink extension should also update.
The lsp should also be changed to it resolved the right variables.
There is the issue of public and private variable, add a extra command to do this.
Add the `\public var1 var2` command but also keep the other syntax.
Update existing libraries in `./lib`
The public command also needs support in the zig parser and tree-sitter parser.

## Improve tooling
Fix the following in the zed-ink extension and tree-sitter-ink parser.

## Resolve group vs freq

## Early returns
Implement early returns in a lambda using `:` (like the ngn/k).

## Ink Agent Skills
Help me write skills for developing ink code based on this codebase.
Add skills for the following task profiles.
- Ink development agent: skills, tools, ebnf, idioms, code style
  - parse tool
  - bytecode tool
  - snapshot tool
- Ink native module development

## Earth Example
Make an example of a 3D rendering of the earth.

## Flip int `` +3 ``
What do do with flipping an int?
There is no implementation for the flip verb for scalars.
```
~/Code/ink ink
  +3
!type
  +3

~/Code/ink k
ngn/k, (c) 2019-2024 ngn, GNU AGPLv3. type \ for more info
 +3
,,3
```
Maybe we can use the plus together with a number as the syntax for the new natural number type. The plus works the same way as minus in the float and integers except for natural numbers we always write them beginning with a plus. ex `` +1 +2 +3 ``

## Doc tool `ink doc`

## Remove `.blank` type

## New operators for colors: cube-root `cbrt`

## Paralle each adverb
Maybe we can use the digram form of the each adverb for parallel each.
There is already stencil and window, we can add `` `ncpu f'!1000 `` to mean
that the function f should be applied to `!1000` distributed over number of cpu cores.

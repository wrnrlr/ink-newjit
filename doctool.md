# Help me implement a DocTool for ink.
It will be a standalone service that the vm or command line can use to get documentation for a
builtin operator or a public identifier in the public libraries in `lib/`

I want to get from cmd line docs for public global function in a module (any global in k file and
always start with Capital), name of operator like +, name of module for the module documentation


```
ink test/doc ReadCsv
ink test/doc +
ink test/doc csv
```

Documentation is sourced as follows.
- The comment block above a public library function,  
- The top block of comments in a k file is the module documentation. So for csv that the the first block of `lib/csv.k`.
- For the buildin should be inlined the meanings of the verb

This is be possible in k because we can parse k in k with the parse verb `parse` ex. `parse "1+1"`.

The module should also Export a Help function with a similar api.
The help method should take the symbol of the public/builtin/module name. Builtins have priority over publics

I just realize we do need a file system api, for this lets add a native extension called fs.

it should have a `FileNames "./path"` that list all the files in path dir.

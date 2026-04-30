Help me improve the performance of the JIT.
We've already implemented a JIT but it is not always faster and could use some improivement.
One thing we are missing is support for CPS.

Re-implement primitives using Continious passing style CPS for better JIT support.
The `src/primitives` dir should be refactored to better fit the JIT.
The Copy-and-Patch paper mentiones that CPS is needed to implement the JIT.

One improvement for the kernel return type error union:
We already have a error type in value struct `V` with `err`, so no need to use
the error union from zig `!V`. Most errors will be type domain or mem errors already in the union. 
That does not make it CPS yet, but it does simplify the value type of a monadic or dyadic call.

For full CPS we don't return a value but pass it along with the right control structure. Don't know the best way to do it.
The

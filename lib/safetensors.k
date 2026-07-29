/
# safetensors

Reads safetensors weight files into a dict of named tensors.

Build the extension first with `zig build safetensors`; the module then loads on the
first reference to any `safetensors.*` name.
\

\d safetensors read
so: "./zig-out/lib/libsafetensors.dylib"
read: so 2: (`ReadSafetensors; 1)   / safetensors.read "path.safetensors" → dict
\d

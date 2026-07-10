/ lib/safetensors.k — Safetensors extension
/
/ Build first:  zig build safetensors
/ Use:          safetensors.read "model.safetensors"   (auto-loads on first use)
/                 → dict: name → [dtype:`f32; shape:2 3; data:<F|I vector>]
/               plus an optional `__metadata__` key → dict of string→string
/               (reach it with  t@`s$"__metadata__"  — `_` is Drop in ink source).

\d safetensors read
so: "./zig-out/lib/libsafetensors.dylib"
read: so 2: (`ReadSafetensors; 1)   / safetensors.read "path.safetensors" → dict
\d

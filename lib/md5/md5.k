/ lib/md5/md5.k — load md5 extension
/
/ Build first:  zig build md5
/ Load with:    2: "lib/md5/md5.k"

so: "./zig-out/lib/libmd5.dylib"
md5Hash: so 2: (`md5Hash; 1)   / C → C[32] lowercase hex digest

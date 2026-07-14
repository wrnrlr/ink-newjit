/ lib/zip.k — ZIP archive module (native Zig std.zip + std.compress.flate).
/
/ Build first:  zig build zip
/ Load with:    2:"lib/zip.k"   (or reference any `zip.*` name)
/
/ Read:
/   zip.list "a.zip"          / table [name;size;csize;method;crc] of entries
/   zip.read "a.zip"          / dict name → decompressed bytes
/   zip.entry["a.zip"; "f"]   / decompressed bytes of one entry (error if absent)
/ Write:
/   zip.write["out.zip"; ("a.txt";"b.txt"); ("hello";"world")]   / → 1b
/
/ Supports store (0) and deflate (8), non-encrypted, non-zip64 archives; other
/ cases return an error `'.  Method column: 0=store, 8=deflate.  `crc`/`size` are
/ i32 (crc is bit-reinterpreted, so large values read back negative).

\d zip
  so: "./zig-out/lib/libzip.dylib"

  list:  so 2:(`ZipList;  1)   / "a.zip" → table of entry metadata
  read:  so 2:(`ZipRead;  1)   / "a.zip" → dict name→bytes
  entry: so 2:(`ZipEntry; 2)   / ["a.zip"; name] → bytes | error
  write: so 2:(`ZipWrite; 3)   / ["out.zip"; names; datas] → 1b
\d

/ test/compress.k — smoke test for the compress module (lib/compress.k).
/ Run: ./zig-out/bin/ink test/compress.k
2:"lib/compress.k"

ok:{[nm;c] `0:nm," ",$[c;"ok";"FAIL"],"\n"}
iserr:{`"!"~@x}   / an error value has type `! (quote the glyph symbol)

s:"the quick brown fox jumps over the lazy dog, the quick brown fox jumps"

/ ── round-trips through each container ──────────────────────────────────────
ok["deflate rt"; s~compress.inflate compress.deflate s]
ok["gzip rt";    s~compress.gunzip compress.gzip s]
ok["zlib rt";    s~compress.unzlib compress.zlib s]

/ compression actually shrinks a repetitive string
ok["shrinks"; (#compress.deflate s)<#s]

/ empty input round-trips to an empty char vector
ok["empty rt"; ""~compress.inflate compress.deflate ""]

/ ── checksums (known answers) ───────────────────────────────────────────────
ok["crc32 abc";   891568578=compress.crc32 "abc"]      / 0x352441C2
ok["adler32 abc"; 38600999=compress.adler32 "abc"]     / 0x024D0127

/ ── corruption is caught by the checksummed containers ─────────────────────
ok["gunzip corrupt"; iserr compress.gunzip "not a gzip stream!!"]
ok["unzlib corrupt"; iserr compress.unzlib "not a zlib stream!!"]

`0:"done\n"

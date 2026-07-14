/ test/zip.k — smoke test for the zip module (lib/zip.k).
/ Self-contained: writes an archive, then reads it back.
/ Run: ./zig-out/bin/ink test/zip.k
2:"lib/zip.k"

ok:{[nm;c] `0:nm," ",$[c;"ok";"FAIL"],"\n"}
iserr:{`"!"~@x}

path:"/tmp/inkziptest.zip"
names:("readme.txt";"data/big.txt";"empty.txt")
big:,/200#,"the quick brown fox "     / compressible payload
datas:("hello from ink";big;"")

/ ── write ───────────────────────────────────────────────────────────────────
ok["write";  zip.write[path; names; datas]]

/ ── list ────────────────────────────────────────────────────────────────────
t:zip.list path
ok["list type";  `M~@t]
ok["list count"; 3=#t]
ok["list names"; names~t`name]
ok["list sizes"; (14 4000 0)~t`size]
ok["big deflated"; 8=(t`method)@1]     / big.txt was compressed (method 8)

/ ── entry round-trips ───────────────────────────────────────────────────────
ok["entry readme"; "hello from ink"~zip.entry[path; "readme.txt"]]
ok["entry big rt"; big~zip.entry[path; "data/big.txt"]]
ok["entry empty";  ""~zip.entry[path; "empty.txt"]]
ok["entry absent"; iserr zip.entry[path; "nope.txt"]]

/ ── read → dict ─────────────────────────────────────────────────────────────
d:zip.read path
ok["read readme"; "hello from ink"~d`"readme.txt"]
ok["read big rt"; big~d`"data/big.txt"]

/ ── error handling ──────────────────────────────────────────────────────────
ok["list missing file"; iserr zip.list "/tmp/does-not-exist-xyz.zip"]

`0:"done\n"

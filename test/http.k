/ test/http.k — smoke test for the http module (lib/http.k).
/ Offline: exercises load + error-handling paths (no network, deterministic).
/ Run: ./zig-out/bin/ink test/http.k
/
/ Live example (needs network), verified manually:
/   r: http.get "https://api.github.com/repos/ziglang/zig"
/   r`status                       / 200
/   (json.parse r`body)`"name"     / "zig"
/   http.post["https://httpbin.org/post"; "{\"a\":1}"]
2:"lib/http.k"

ok:{[nm;c] `0:nm," ",$[c;"ok";"FAIL"],"\n"}
iserr:{`"!"~@x}

/ ── module loaded, wrappers present ─────────────────────────────────────────
ok["raw bound"; ~iserr http.raw]      / the FFI primitive resolved (not an error)
ok["get is fn"; `o~@http.get]

/ ── error handling (deterministic, no network) ──────────────────────────────
ok["refused";    iserr http.get "http://127.0.0.1:1/x"]   / connection refused
ok["bad url";    iserr http.get "not a url"]
ok["bad scheme"; iserr http.get "ftp://example.com/x"]
ok["bad method"; iserr http.request["WAT"; "http://127.0.0.1:1/"; (); ""]]

`0:"done\n"

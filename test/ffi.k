/ test/ffi.k — FFI integration test for the add.dylib example
/
/ Build the shared library (from project root) before running:
/   cc -shared -fPIC -undefined dynamic_lookup \
/      -o examples/add.dylib examples/add.c -I include
/
/ Run:
/   ink test/ffi.k

add: "./examples/add.dylib" 2: (`add; 2)

/ "ok   <label>" or "FAIL <label>"
chk: {[e;a;n] (("FAIL";"ok  ") e~a)," ",n}

chk[7;    add[3; 4];     "add int   + int   → 7  "]
chk[7;    add[10; -3];   "add int   + neg   → 7  "]
chk[4.0;  add[1.5; 2.5]; "add float + float → 4.0"]
chk[-10;  add[-5; -5];   "add neg   + neg   → -10"]

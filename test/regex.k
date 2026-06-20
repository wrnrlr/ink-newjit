2:"lib/regex.k"

/ ── helper ──────────────────────────────────────────────────────────────────
pass: 0
fail: 0
chkN: 0
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; {fail::fail+1; `0 0:"FAIL #",($chkN)," ",name}[]]; 0}

/ ── ReTest ──────────────────────────────────────────────────────────────────
chk["abc~abc";  ReTest[ReCompile["abc"];"abc"];  1b]
chk["abc~ab";   ReTest[ReCompile["abc"];"ab"];   0b]
chk["abc~abcd"; ReTest[ReCompile["abc"];"abcd"]; 0b]
chk["a.c~abc";  ReTest[ReCompile["a.c"];"abc"];  1b]
chk["a.c~aXc";  ReTest[ReCompile["a.c"];"aXc"];  1b]
chk["a*~empty"; ReTest[ReCompile["a*"];""];       1b]
chk["a*~aaa";   ReTest[ReCompile["a*"];"aaa"];    1b]
chk["a+~a";     ReTest[ReCompile["a+"];"a"];      1b]
chk["a+~aaa";   ReTest[ReCompile["a+"];"aaa"];    1b]
chk["a+~empty"; ReTest[ReCompile["a+"];""];       0b]
chk["a?~empty"; ReTest[ReCompile["a?"];""];       1b]
chk["a?~a";     ReTest[ReCompile["a?"];"a"];      1b]
chk["a?~aa";    ReTest[ReCompile["a?"];"aa"];     0b]
chk["a|b~a";    ReTest[ReCompile["a|b"];"a"];     1b]
chk["a|b~b";    ReTest[ReCompile["a|b"];"b"];     1b]
chk["a|b~c";    ReTest[ReCompile["a|b"];"c"];     0b]
chk["(ab)+~abab"; ReTest[ReCompile["(ab)+"];"abab"]; 1b]
chk["(ab)+~ab";   ReTest[ReCompile["(ab)+"];"ab"];   1b]
chk["(ab)+~a";    ReTest[ReCompile["(ab)+"];"a"];    0b]
chk[".*~hello";   ReTest[ReCompile[".*"];"hello"];   1b]
chk[".*~empty";   ReTest[ReCompile[".*"];""];        1b]

/ ── char classes ────────────────────────────────────────────────────────────
chk["bkd+~123";   ReTest[ReCompile["\\d+"];"123"];   1b]
chk["bkd+~abc";   ReTest[ReCompile["\\d+"];"abc"];   0b]
chk["bkw+~a1u";   ReTest[ReCompile["\\w+"];"a1u"];   1b]
chk["bks+~spc";   ReTest[ReCompile["\\s+"];" "];     1b]
chk["[a-z]+~abc"; ReTest[ReCompile["[a-z]+"];"abc"]; 1b]
chk["[a-z]+~ABC"; ReTest[ReCompile["[a-z]+"];"ABC"]; 0b]
chk["[^0-9]+~abc"; ReTest[ReCompile["[^0-9]+"];"abc"]; 1b]
chk["[^0-9]+~123"; ReTest[ReCompile["[^0-9]+"];"123"]; 0b]

/ ── anchors ─────────────────────────────────────────────────────────────────
chk["^a~a";  ReTest[ReCompile["^a"];"a"];  1b]
chk["a$~a";  ReTest[ReCompile["a$"];"a"];  1b]
chk["^a$~a"; ReTest[ReCompile["^a$"];"a"]; 1b]

/ ── ReFind ──────────────────────────────────────────────────────────────────
chk["find abc in xabcy"; ReFind[ReCompile["abc"];"xabcy"]; 1 3]
chk["find [0-9]+";       ReFind[ReCompile["[0-9]+"];"abc123def"]; 3 3]
chk["find no match";     ReFind[ReCompile["xyz"];"abc"]; !0]
chk["find at start";     ReFind[ReCompile["he"];"hello"]; 0 2]

/ ── ReAll ───────────────────────────────────────────────────────────────────
r09: ReCompile["[0-9]+"]
chk["all [0-9]+"; ReAll[r09;"a1b23c456"]; (1 1;3 2;6 3)]

/ ── ReSub ───────────────────────────────────────────────────────────────────
chk["sub o+->0";    ReSub[ReCompile["o+"];"foobar";"0"]; "f0bar"]
chk["sub no match"; ReSub[ReCompile["xyz"];"abc";"Z"]; "abc"]

/ ── ReSubAll ────────────────────────────────────────────────────────────────
chk["suball [0-9]+->N"; ReSubAll[ReCompile["[0-9]+"];"a1b23c";"N"]; "aNbNc"]

/ ── summary ─────────────────────────────────────────────────────────────────
`0 0:($pass)," passed, ",($fail)," failed"

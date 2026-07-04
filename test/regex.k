2:"lib/regex.k"

/ ── helper ──────────────────────────────────────────────────────────────────
pass: 0
fail: 0
chkN: 0
chk: {[name;got;want] chkN::chkN+1; $[got~want; pass::pass+1; {fail::fail+1; `0 0:"FAIL #",($chkN)," ",name}[]]; 0}

/ ── regex.test ───────────────────────────────────────────────────────────────
chk["abc~abc";  regex.test[regex.compile["abc"];"abc"];  1b]
chk["abc~ab";   regex.test[regex.compile["abc"];"ab"];   0b]
chk["abc~abcd"; regex.test[regex.compile["abc"];"abcd"]; 0b]
chk["a.c~abc";  regex.test[regex.compile["a.c"];"abc"];  1b]
chk["a.c~aXc";  regex.test[regex.compile["a.c"];"aXc"];  1b]
chk["a*~empty"; regex.test[regex.compile["a*"];""];       1b]
chk["a*~aaa";   regex.test[regex.compile["a*"];"aaa"];    1b]
chk["a+~a";     regex.test[regex.compile["a+"];"a"];      1b]
chk["a+~aaa";   regex.test[regex.compile["a+"];"aaa"];    1b]
chk["a+~empty"; regex.test[regex.compile["a+"];""];       0b]
chk["a?~empty"; regex.test[regex.compile["a?"];""];       1b]
chk["a?~a";     regex.test[regex.compile["a?"];"a"];      1b]
chk["a?~aa";    regex.test[regex.compile["a?"];"aa"];     0b]
chk["a|b~a";    regex.test[regex.compile["a|b"];"a"];     1b]
chk["a|b~b";    regex.test[regex.compile["a|b"];"b"];     1b]
chk["a|b~c";    regex.test[regex.compile["a|b"];"c"];     0b]
chk["(ab)+~abab"; regex.test[regex.compile["(ab)+"];"abab"]; 1b]
chk["(ab)+~ab";   regex.test[regex.compile["(ab)+"];"ab"];   1b]
chk["(ab)+~a";    regex.test[regex.compile["(ab)+"];"a"];    0b]
chk[".*~hello";   regex.test[regex.compile[".*"];"hello"];   1b]
chk[".*~empty";   regex.test[regex.compile[".*"];""];        1b]

/ ── char classes ────────────────────────────────────────────────────────────
chk["bkd+~123";   regex.test[regex.compile["\\d+"];"123"];   1b]
chk["bkd+~abc";   regex.test[regex.compile["\\d+"];"abc"];   0b]
chk["bkw+~a1u";   regex.test[regex.compile["\\w+"];"a1u"];   1b]
chk["bks+~spc";   regex.test[regex.compile["\\s+"];" "];     1b]
chk["[a-z]+~abc"; regex.test[regex.compile["[a-z]+"];"abc"]; 1b]
chk["[a-z]+~ABC"; regex.test[regex.compile["[a-z]+"];"ABC"]; 0b]
chk["[^0-9]+~abc"; regex.test[regex.compile["[^0-9]+"];"abc"]; 1b]
chk["[^0-9]+~123"; regex.test[regex.compile["[^0-9]+"];"123"]; 0b]

/ ── anchors ─────────────────────────────────────────────────────────────────
chk["^a~a";  regex.test[regex.compile["^a"];"a"];  1b]
chk["a$~a";  regex.test[regex.compile["a$"];"a"];  1b]
chk["^a$~a"; regex.test[regex.compile["^a$"];"a"]; 1b]

/ ── regex.find ───────────────────────────────────────────────────────────────
chk["find abc in xabcy"; regex.find[regex.compile["abc"];"xabcy"]; 1 3]
chk["find [0-9]+";       regex.find[regex.compile["[0-9]+"];"abc123def"]; 3 3]
chk["find no match";     regex.find[regex.compile["xyz"];"abc"]; !0]
chk["find at start";     regex.find[regex.compile["he"];"hello"]; 0 2]

/ ── regex.all ────────────────────────────────────────────────────────────────
r09: regex.compile["[0-9]+"]
chk["all [0-9]+"; regex.all[r09;"a1b23c456"]; (1 1;3 2;6 3)]

/ ── regex.sub ────────────────────────────────────────────────────────────────
chk["sub o+->0";    regex.sub[regex.compile["o+"];"foobar";"0"]; "f0bar"]
chk["sub no match"; regex.sub[regex.compile["xyz"];"abc";"Z"]; "abc"]

/ ── regex.suball ─────────────────────────────────────────────────────────────
chk["suball [0-9]+->N"; regex.suball[regex.compile["[0-9]+"];"a1b23c";"N"]; "aNbNc"]

/ ── summary ─────────────────────────────────────────────────────────────────
`0 0:($pass)," passed, ",($fail)," failed"

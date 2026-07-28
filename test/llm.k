/ test/llm.k — offline tests for the llm module (lib/llm.k).
/ Verifies the SSE delta scanner + request assembly without a network call.
/ Run: ./zig-out/bin/ink test/llm.k
/
/ Live example (needs XAI_API_KEY or ANTHROPIC_API_KEY in the environment):
/   c: llm.grok "grok-4"                 / or llm.anthropic "claude-opus-4-8"
/   llm.ask[c; "explain array languages in one line"]     / streams live
2:"lib/llm.k"
2:"lib/json.k"

ok:{[nm;c] `0:nm," ",$[c;"ok";"FAIL"],"\n"}

/ ── SSE JSON-string delta extraction ───────────────────────────────────────
al:"data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}"
xl:"data: {\"choices\":[{\"delta\":{\"content\":\"Wor\\\"ld\"}}]}"
ok["anth text";  "Hi"~llm.jstr[5_al; "text"]]
ok["xai content"; "Wor\"ld"~llm.jstr[5_xl; "content"]]
ok["escaped nl";  ("a",(,`c$10),"b")~llm.jstr["\"text\":\"a\\nb\""; "text"]]
ok["absent key";  ""~llm.jstr["{\"role\":\"x\"}"; "content"]]
ok["skip _content"; ""~llm.jstr["{\"reasoning_content\":\"z\"}"; "content"]]   / not "content"
ok["substr idx";  6=llm.idx["hello world"; "wor"]]
ok["substr miss"; -1=llm.idx["abc"; "xyz"]]

/ ── provider request assembly ──────────────────────────────────────────────
c: llm.anthropic "claude-opus-4-8"
g: llm.grok "grok-4"
ok["is anthropic"; llm.isa c]
ok["is not anthropic"; ~llm.isa g]
/ anthropic body carries model + max_tokens + stream + messages
ab: json.gen llm.body[c; ,llm.msg["user";"hi"]; 1b]
ok["anth body max"; 0<#ab]
ok["anth has max_tokens"; 0<=llm.idx[ab; "max_tokens"]]
ok["anth version hdr"; 0<=llm.idx[(","/llm.headers c); "anthropic-version"]]
/ xai (OpenAI-shaped) body has no max_tokens; bearer auth
xb: json.gen llm.body[g; ,llm.msg["user";"hi"]; 0b]
ok["xai no max_tokens"; 0>llm.idx[xb; "max_tokens"]]
ok["xai bearer hdr"; 0<=llm.idx[(","/llm.headers g); "Bearer"]]

/ ── agent: tool schema, response parsing, dispatch (offline) ────────────────
die: llm.tool["roll_die"; "roll"; llm.obj[(,`sides)!,llm.prop["integer";"n"]; ,"sides"]; {[arg] "You rolled a 4"}]
/ tool declaration serialises to valid JSON schema (object property, not array)
xt: json.gen llm.wiretools[g; ,die]
ok["tool schema object"; 0<=llm.idx[xt; "\"sides\":{\"type\":\"integer\""]]
ok["anth tool input_schema"; 0<=llm.idx[(json.gen llm.wiretools[c; ,die]); "input_schema"]]

/ parse a canned xAI tool-call response → one call with parsed args
xbody: "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"roll_die\",\"arguments\":\"{\\\"sides\\\":6}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
ext: llm.extract[g; xbody]
ok["xai extract ncalls"; 1=#ext 1]
ok["xai call name"; "roll_die"~(*ext 1) 1]
ok["xai parsed arg"; 6=((*ext 1) 2)@`sides]
ok["dispatch runs fn"; "You rolled a 4"~llm.runcall[,die; *ext 1]]
ok["xai result msgs"; 1=#llm.results[g; ,die; ext 1]]

/ parse a canned Anthropic tool_use response
abody2: "{\"content\":[{\"type\":\"text\",\"text\":\"ok\"},{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"roll_die\",\"input\":{\"sides\":6}}],\"stop_reason\":\"tool_use\"}"
aext: llm.extract[c; abody2]
ok["anth extract text"; "ok"~aext 0]
ok["anth extract call"; "roll_die"~(*aext 1) 1]
ok["anth result is user msg"; 1=#llm.results[c; ,die; aext 1]]

`0:"done\n"

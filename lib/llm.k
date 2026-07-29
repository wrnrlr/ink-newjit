/
# llm

Chat with Anthropic and xAI models, with live token streaming and tool use.

Pure k over the http + json modules (no dylib of its own).  Streaming is
folded in from the start: llm.ask prints tokens live as they arrive and
returns the full assistant text.

Setup — keys come from the environment (`env[]):

```k
ANTHROPIC_API_KEY   for llm.anthropic
XAI_API_KEY         for llm.grok
```

Quick tour:

```k
c: llm.grok "grok-4"                 / or llm.anthropic "claude-opus-4-8"
llm.ask[c; "explain array languages in one line"]     / streams, returns text
h: llm.turn[c; (); "hello"]          / multi-turn: returns updated history
llm.say[c; h; "and now in french"]   / continue the conversation
```

Message shape is provider-neutral: a list of [role;content] dicts.  Both
providers take role in `system`user`assistant.

Gotchas baked in: env/JSON keys are SYMBOLS and API field names have
underscores, so they're quoted (`"max_tokens", `"XAI_API_KEY"); SSE deltas
are scanned out of each data: line with a small JSON-string reader rather than
json.parse (which columnarises object arrays).

Pure k — loads on the first reference to any `llm.*` name.
\

\d llm
  bs: `c$92    / backslash
  qt: `c$34    / double-quote
  nl: `c$10    / newline

  / ── env + providers ───────────────────────────────────────────────────────
  env:{[name] (`env[])@`s$name}
  / NB: keep each value list on ONE line — a newline inside (...) injects a null.
  aurl: "https://api.anthropic.com/v1/messages"
  xurl: "https://api.x.ai/v1/chat/completions"
  anthropic:{[model] (`prov`url`model`key`max)!(`anthropic; llm.aurl; model; llm.env"ANTHROPIC_API_KEY"; 4096)}
  grok:{[model] (`prov`url`model`key`max)!(`xai; llm.xurl; model; llm.env"XAI_API_KEY"; 4096)}

  msg:{[r;c] (`role`content)!(r;c)}

  / ── request assembly ──────────────────────────────────────────────────────
  isa:{[cfg] (cfg@`prov)~`anthropic}   / (cfg@`prov)~… — parens: @ binds looser than ~
  body:{[cfg;msgs;strm]
    $[llm.isa cfg
     ; (`model;`"max_tokens";`stream;`messages)!(cfg@`model; cfg@`max; strm; msgs)
     ; (`model;`stream;`messages)!(cfg@`model; strm; msgs)]}
  headers:{[cfg]
    $[llm.isa cfg
     ; ("x-api-key"; cfg@`key; "anthropic-version"; "2023-06-01"; "content-type"; "application/json")
     ; ("authorization"; "Bearer ",cfg@`key; "content-type"; "application/json")]}

  / ── JSON-string helpers (SSE delta extraction) ────────────────────────────
  / index of first occurrence of pat in s, or -1.  Adverbs (not nested lambdas)
  / so nothing captures the enclosing s/pat; a helper keeps the search out of a
  / $[…] branch (bracketed statement blocks in a branch break the parser).
  idxm:{[s;pat;n;m] h:&pat~/:s@(!1+m-n)+\:!n; $[#h; *h; -1]}
  idx:{[s;pat] $[(#pat)>#s; -1; llm.idxm[s;pat;#pat;#s]]}
  / decode one escaped char (the char AFTER a backslash)
  unesc1:{[c] $[c="n"; llm.nl; c="t"; `c$9; c="r"; `c$13; c]}
  / read a JSON string body (t begins just after the opening quote), unescaping
  readstr:{[t] (({[st;c]
    $[st 0; st                                 / done
     ; st 1; (0b; 0b; (st 2),llm.unesc1 c)     / prev was backslash
     ; c=llm.bs; (0b; 1b; st 2)                / start escape
     ; c=llm.qt; (1b; 0b; st 2)                / closing quote
     ; (0b; 0b; (st 2),c)]}/[(0b;0b;"");t]) 2)}
  / value of "key":"…" in s (unescaped), or "" if absent
  jstr:{[s;key] pat:(,llm.qt),key,llm.qt,":",(,llm.qt);
    i:llm.idx[s;pat]; $[i<0; ""; llm.readstr (i+#pat)_s]}

  / ── SSE line processing (the http callback delivers one complete line) ────
  / Split across helpers so no $[…] branch holds a bracketed statement block.
  emit:{[t] $[0<#t; llm.out t; 0]}
  out:{[t] `stdout 1: t; llm.acc:: llm.acc,t; 0}
  keyfor:{$[llm.pv~`anthropic; "text"; "content"]}
  data2:{[b] $[b~"[DONE]"; 0; llm.emit llm.jstr[b; llm.keyfor[]]]}
  / one SSE line → maybe print+accumulate a delta
  dataline:{[ln] $[5>#ln; 0; ~"data:"~5#ln; 0; llm.data2 llm.trim 5_ln]}
  trim:{[s] $[(0<#s)&" "=*s; 1_s; s]}

  / ── streaming chat: messages → assistant text (printed live) ──────────────
  stream:{[cfg;msgs]
    llm.pv:: cfg@`prov; llm.acc:: "";
    r:http.stream["POST"; cfg@`url; llm.headers cfg; json.gen llm.body[cfg;msgs;1b]; {[ln] llm.dataline ln}];
    `stdout 1: (,llm.nl);
    llm.acc}

  / one-shot: prompt → streamed assistant text
  ask:{[cfg;prompt] llm.stream[cfg; ,llm.msg["user"; prompt]]}

  / multi-turn: (history; user text) → history with the user+assistant turns
  / history is a list of [role;content] message dicts ((), to start).
  turn:{[cfg;hist;text] h:hist,,llm.msg["user"; text];
    a:llm.stream[cfg; h]; h,,llm.msg["assistant"; a]}
  say: turn

  / ── Agent: buffered tool-use loop for both providers ──────────────────────
  / A tool is a dict [name;desc;params;fn]: `params` is a JSON-schema object
  / (build with llm.obj/llm.prop); `fn` is a k lambda  inputDict → result string.
  rounds: 8    / max tool-use rounds before giving up
  prop:{[typ;desc] (`type`description)!(typ;desc)}
  obj:{[props;reqd] (`type`properties`required)!("object"; props; reqd)}
  tool:{[name;desc;params;fn] (`name`desc`params`fn)!(name;desc;params;fn)}
  hask:{[d;k] |/k~/:!d}                       / is symbol k a key of dict d
  isstr:{[x] (@x)~`C}                          / a JSON string came back as C

  / provider-native tool declarations for the request
  atool:{[t] (`name;`description;`"input_schema")!(t@`name; t@`desc; t@`params)}
  xtool:{[t] (`type`function)!("function"; (`name`description`parameters)!(t@`name; t@`desc; t@`params))}
  wiretools:{[cfg;tools] $[llm.isa cfg; {[t] llm.atool t}'tools; {[t] llm.xtool t}'tools]}
  / full request body (buffered — no stream), with tools attached
  abody:{[cfg;msgs;tools]
    $[llm.isa cfg
     ; (`model;`"max_tokens";`messages;`tools)!(cfg@`model; cfg@`max; msgs; llm.wiretools[cfg;tools])
     ; (`model;`messages;`tools)!(cfg@`model; msgs; llm.wiretools[cfg;tools])]}

  / extract (text; calls; assistantMessage) from a parsed response.
  / calls is a list of (id; name; inputDict).
  atext:{[blocks] ,/{[b] $[("text")~b@`type; b@`text; ""]}'blocks}
  acalls:{[blocks] {[b] (b@`id; b@`name; b@`input)}'llm.tublocks blocks}
  tublocks:{[blocks] blocks@&{[b] ("tool_use")~b@`type}'blocks}
  aresp:{[resp] bl:resp@`content; (llm.atext bl; llm.acalls bl; (`role`content)!("assistant"; bl))}
  xmsg:{[resp] (*resp@`choices)@`message}
  xcall:{[tc] (tc@`id; (tc@`function)@`name; json.list (tc@`function)@`arguments)}
  xresp:{[resp] m:llm.xmsg resp;
    (($[llm.isstr m@`content; m@`content; ""]);
     $[llm.hask[m;`"tool_calls"]; {[t] llm.xcall t}'m@`"tool_calls"; ()]; m)}
  extract:{[cfg;body] r:json.list body; $[llm.isa cfg; llm.aresp r; llm.xresp r]}

  / run one tool call → result string
  toolnames:{[tools] {[t] t@`name}'tools}
  runcall:{[tools;call] fn:(tools@*&(call 1)~/:llm.toolnames tools)@`fn; fn call 2}
  / result messages to append after a round of calls (provider-shaped)
  aresult:{[calls;res] ,(`role`content)!("user";
    {[c;r] (`type;`"tool_use_id";`content)!("tool_result"; c 0; r)}'[calls;res])}
  xresult:{[calls;res] {[c;r] (`role;`"tool_call_id";`content)!("tool"; c 0; r)}'[calls;res]}
  results:{[cfg;tools;calls] res:llm.runcall[tools;]'calls;
    $[llm.isa cfg; llm.aresult[calls;res]; llm.xresult[calls;res]]}

  / the loop
  agent:{[cfg;tools;task] llm.aloop[cfg; tools; ,llm.msg["user"; task]; llm.rounds]}
  aloop:{[cfg;tools;msgs;n] $[n<1; "[llm.agent: max rounds reached]"; llm.astep[cfg;tools;msgs;n]]}
  astep:{[cfg;tools;msgs;n]
    r:http.request["POST"; cfg@`url; llm.headers cfg; json.gen llm.abody[cfg;msgs;tools]];
    $[~200=r@`status; "[llm.agent: HTTP ",($r@`status),"] ",r@`body; llm.adispatch[cfg;tools;msgs;n; llm.extract[cfg; r@`body]]]}
  adispatch:{[cfg;tools;msgs;n;ext] calls:ext 1;
    $[0=#calls; ext 0; llm.acontinue[cfg;tools;msgs;n;ext;calls]]}
  acontinue:{[cfg;tools;msgs;n;ext;calls]
    {[c] `stderr 1: "  . tool ",(c 1),"\n"}'calls;
    llm.aloop[cfg; tools; msgs,(,ext 2),llm.results[cfg;tools;calls]; n-1]}
\d

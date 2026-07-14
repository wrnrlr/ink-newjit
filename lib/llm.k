/ lib/llm.k — LLM chat + streaming for Anthropic and xAI (Grok).
/
/ Pure k over the http + json modules (no dylib of its own).  Streaming is
/ folded in from the start: llm.ask prints tokens live as they arrive and
/ returns the full assistant text.
/
/ Setup — keys come from the environment (`env[]):
/   ANTHROPIC_API_KEY   for llm.anthropic
/   XAI_API_KEY         for llm.grok
/
/ Quick tour:
/   c: llm.grok "grok-4"                 / or llm.anthropic "claude-opus-4-8"
/   llm.ask[c; "explain array languages in one line"]     / streams, returns text
/   h: llm.turn[c; (); "hello"]          / multi-turn: returns updated history
/   llm.say[c; h; "and now in french"]   / continue the conversation
/
/ Message shape is provider-neutral: a list of [role;content] dicts.  Both
/ providers take role in `system`user`assistant.
/
/ Gotchas baked in: env/JSON keys are SYMBOLS and API field names have
/ underscores, so they're quoted (`"max_tokens", `"XAI_API_KEY"); SSE deltas
/ are scanned out of each data: line with a small JSON-string reader rather than
/ json.parse (which columnarises object arrays).

\d llm
  bs: `c$92    / backslash
  qt: `c$34    / double-quote
  nl: `c$10    / newline

  / ── env + providers ───────────────────────────────────────────────────────
  env:{[name] (`env[])@`s$name}
  anthropic:{[model] (`prov`url`model`key`max)!(`anthropic;
    "https://api.anthropic.com/v1/messages"; model; llm.env"ANTHROPIC_API_KEY"; 4096)}
  grok:{[model] (`prov`url`model`key`max)!(`xai;
    "https://api.x.ai/v1/chat/completions"; model; llm.env"XAI_API_KEY"; 4096)}

  msg:{[r;c] (`role`content)!(r;c)}

  / ── request assembly ──────────────────────────────────────────────────────
  body:{[cfg;msgs;strm]
    $[cfg@`prov ~ `anthropic
     ; (`model;`"max_tokens";`stream;`messages)!(cfg@`model; cfg@`max; strm; msgs)
     ; (`model;`stream;`messages)!(cfg@`model; strm; msgs)]}
  headers:{[cfg]
    $[cfg@`prov ~ `anthropic
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

  / ── SSE stream processing (stateful; feeds the http callback) ─────────────
  strip:{[x] $[(0<#x)&llm.nl=*|x; -1_x; x]}
  splitnl:{[s] {[x] llm.strip x}'(0,1+&s=llm.nl)_s}
  / one SSE line → maybe emit a delta.  Split across helpers so no $[…] branch
  / holds a bracketed statement block.
  emit:{[t] $[0<#t; llm.out t; 0]}
  out:{[t] `stdout 1: t; llm.acc:: llm.acc,t; 0}
  keyfor:{$[llm.pv~`anthropic; "text"; "content"]}
  data2:{[b] $[b~"[DONE]"; 0; llm.emit llm.jstr[b; llm.keyfor[]]]}
  dataline:{[ln] $[5>#ln; 0; ~"data:"~5#ln; 0; llm.data2 llm.trim 5_ln]}
  trim:{[s] $[(0<#s)&" "=*s; 1_s; s]}
  feed:{[chunk] parts:llm.splitnl llm.sb,chunk;
    llm.sb:: *|parts;
    {[x] llm.dataline x}'(-1)_parts}

  / ── streaming chat: messages → assistant text (printed live) ──────────────
  stream:{[cfg;msgs]
    llm.pv:: cfg@`prov; llm.sb:: ""; llm.acc:: "";
    r:http.stream["POST"; cfg@`url; llm.headers cfg; json.gen llm.body[cfg;msgs;1b]; {[c] llm.feed c}];
    `stdout 1: (,llm.nl);
    llm.acc}

  / one-shot: prompt → streamed assistant text
  ask:{[cfg;prompt] llm.stream[cfg; ,llm.msg["user"; prompt]]}

  / multi-turn: (history; user text) → history with the user+assistant turns
  / history is a list of [role;content] message dicts ((), to start).
  turn:{[cfg;hist;text] h:hist,,llm.msg["user"; text];
    a:llm.stream[cfg; h]; h,,llm.msg["assistant"; a]}
  say: turn
\d

/ lib/http.k — HTTP client module (native Zig std.http.Client).
/
/ Build first:  zig build http
/ Load with:    2:"lib/http.k"   (or reference any `http.*` name)
/
/ For talking to web/JSON APIs.  https (TLS), redirects and gzip/deflate/zstd
/ response decompression are handled for you.  Every call returns a dict:
/   r`status    / i    HTTP status code (200, 404, …)
/   r`headers   / dict lowercased response header → value
/   r`body      / C    response body (decompressed)
/ or an error `' if the request could not be completed (DNS/TLS/connection).
/
/   r: http.get "https://api.github.com/repos/ziglang/zig"
/   r`status                                   / 200
/   json.parse r`body                          / decode the JSON
/   http.post["https://httpbin.org/post"; "{\"a\":1}"]
/   http.request["PUT"; url; ("authorization";tok); payload]
/
/ Headers are flat name/value pairs: ("accept";"application/json";"x-key";k).

\d http
  so: "./zig-out/lib/libhttp.dylib"
  raw: so 2:(`HttpRequest; 1)   / (method;url;headers;body) → dict | error
  / streaming: calls the callback with each response body LINE (C bytes, newline
  / stripped) as it arrives; returns dict[status;headers] (no body — it went to
  / the callback).  Line framing is done host-side, which suits SSE and keeps the
  / callback a light per-line handler (see lib/llm.k for the token-stream user).
  streamRaw: so 2:(`HttpStream; 2)   / [(method;url;headers;body); {[line]…}]

  / method, url, headers (flat C pairs), body → response dict
  request:{[m;u;h;b] http.raw (m;u;h;b)}
  / method, url, headers, body, callback → dict[status;headers] (body streamed)
  stream:{[m;u;h;b;cb] http.streamRaw[(m;u;h;b); cb]}

  get:{[u]    http.raw ("GET";    u; (); "")}
  del:{[u]    http.raw ("DELETE"; u; (); "")}
  head:{[u]   http.raw ("HEAD";   u; (); "")}
  / POST/PUT/PATCH default to a JSON content-type; override via http.request.
  jhdr: ("content-type";"application/json")
  post:{[u;b]  http.raw ("POST";  u; http.jhdr; b)}
  put:{[u;b]   http.raw ("PUT";   u; http.jhdr; b)}
  patch:{[u;b] http.raw ("PATCH"; u; http.jhdr; b)}
\d

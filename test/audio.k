/ test/audio.k — smoke test + tour of the audio module (native miniaudio ext).
/
/ Build the extension first:   zig build audio
/ Run:                          ./zig-out/bin/ink test/audio.k
/
/ Covers: synthesise → save (encode) → load-file (decode), playback control,
/ 3D spatialisation, and the poll-based recording path.  Everything is
/ fire-and-forget except recording, which you drain from a loop (here we just
/ burn a little CPU to let the mic thread fill the ring buffer).

/ ── synthesise a 0.5s 440 Hz sine (mono @ 48 kHz) ──────────────────────────────
/ NB: ink floats are written with a decimal point — no `f` suffix — and `sin` is
/ a plain keyword verb, so this is one flat elementwise expression.
rate:  48000
n:     rate div 2
t:     !n
sine:  0.3 * sin 2 * 3.14159265 * 440 * t % rate

/ ── save → load round-trip ─────────────────────────────────────────────────────
audio.save["/tmp/ink-sine.wav"; 1; rate; sine]      / write a WAV
clip: audio.decode "/tmp/ink-sine.wav"              / read it back to PCM
"decoded:"; `channels`rate`frames ! (clip`channels; clip`rate; clip`frames)
"round-trips:"; n = clip`frames

/ ── playback: a controllable voice ─────────────────────────────────────────────
audio.master 0.9                                    / master volume
h: audio.load "/tmp/ink-sine.wav"                   / decode into memory
audio.loop[h; 1]                                     / loop it
audio.pitch[h; 1.2]                                  / 20% higher
audio.start h
"playing:"; audio.playing h

/ ── 3D spatialisation (game SFX) ───────────────────────────────────────────────
g: audio.load "/tmp/ink-sine.wav"
audio.spatial[g; 1]                                  / enable 3D
audio.pos[g; 4 0 -3]                                 / world position
audio.range[g; 1 25]                                 / full within 1m, silent past 25m
audio.listener    0 0 0                              / listener at the origin,
audio.listenerDir 0 0 -1                             /   facing -Z
audio.start g
"spatialised"

/ ── recording: poll the ring buffer ────────────────────────────────────────────
/ In a real app you'd call audio.rec.read[] once per frame from your window loop
/ (lib/gpu.k window.run).  Here we spin briefly so the capture thread has time to
/ hand us some frames.
audio.rec.start[]                                    / mono @ 48 kHz
burn: +/!60000000                                    / ~waste a beat
captured: audio.rec.read[]                           / drain interleaved f32
info: audio.rec.info[]
"captured frames:"; (#captured) div info`channels
audio.save["/tmp/ink-mic.wav"; info`channels; info`rate; captured]
audio.rec.stop[]

"audio ok"

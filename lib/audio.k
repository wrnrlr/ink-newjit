/ lib/audio.k — audio module (native miniaudio extension).
/
/ Build first:  zig build audio
/ Load with:    2: "lib/audio.k"   (or reference any `audio.*` name to autoload)
/
/ Playback runs on miniaudio's own audio thread — the calls below are
/ fire-and-forget, so you never block or spin a loop to make sound.  Recording
/ is the one place you poll: call audio.rec.read[] from your game/UI loop (the
/ same place you read window events) to drain freshly captured samples.
/
/ Quick tour:
/   audio.play "boop.wav"                    / one-shot UI/SFX
/   h: audio.load "gun.wav"                  / a controllable voice
/   audio.start h                            / (re)trigger it
/   audio.music "song.mp3"                   / streamed, looping background music
/   audio.pos[h; 3 0 -2f]                    / place it in 3D; move the listener
/   audio.listener 0 0 0f                    /   with audio.listener each frame
/   audio.rec.start[]                        / start the mic
/   s: audio.rec.read[]                      / drain samples (call in your loop)
/   audio.save["take.wav"; audio.rec.channels[]; audio.rec.rate[]; s]
/   clip: audio.decode "take.wav"            / load a file to a PCM dict

\d audio play load stream music start stop unload state playing volume pitch pan loop seek pos vel dir spatial range master listener listenerDir listenerVel listenerUp decode encode save init
  / Explicitly bring the engine up (otherwise it starts on first play/load).
  init: {[] ffi.Init 0}

  / Playing state as a labelled dict: `playing`atEnd`cursor`length (PCM frames).
  state: {[h] `playing`atEnd`cursor`length ! ffi.st0 h}

  / 1b while a voice is actively producing sound.
  playing: {[h] 1=(ffi.st0 h)0}

  / Streamed, looping background music started immediately.  Returns the handle.
  music: {[path] h: ffi.stream path; ffi.loop[h;1]; start h; h}

  / Save interleaved f32 PCM (as from audio.rec.read / audio.decode`data) to WAV.
  save: {[path;channels;rate;data] ffi.encode (path; channels; rate; data)}

/ ── recording (poll audio.rec.read from your loop) ──────────────────────────
\d audio.rec open start stop info read channels rate available
  / Start the mic at mono @ 48 kHz (the common case).
  start: {[] ffi.recStart 1 48000}
  / Start the mic with an explicit channel count and sample rate.
  open:  {[channels;rate] ffi.recStart (channels; rate)}
  stop:  {[] ffi.recStop 0}
  / Labelled capture info: `channels`rate`available (available is in frames).
  info:  {[] `channels`rate`available ! ffi.recInfo 0}
  channels:  {[] (ffi.recInfo 0)0}
  rate:      {[] (ffi.recInfo 0)1}
  available: {[] (ffi.recInfo 0)2}
  / Drain all buffered frames.  Interleaved F (length = frames*channels).
  read:  {[] ffi.recRead 0}

\d audio.ffi
  so: "./zig-out/lib/libaudio.dylib"
  
  Init:        so 2:(`AudioInit;      1)
  play:        so 2:(`AudioPlay;      1)   / "path" → 1b   one-shot fire-and-forget
  load:        so 2:(`AudioLoad;      1)   / "path" → h    (decoded into memory)
  stream:      so 2:(`AudioStream;    1)   / "path" → h    (streamed from disk)
  start:       so 2:(`AudioStart;     1)   / h → 1b
  stop:        so 2:(`AudioStop;      1)   / h → 1b
  unload:      so 2:(`AudioUnload;    1)   / h → 1b
  st0:         so 2:(`AudioState;     1)   / h → (playing;atEnd;cursor;length)_I
  master:      so 2:(`AudioMaster;    1)   / v → 1b   master engine volume
  volume:      so 2:(`AudioVolume;    2)   / (h;v) → 1b
  pitch:       so 2:(`AudioPitch;     2)   / (h;p) → 1b
  pan:         so 2:(`AudioPan;       2)   / (h;-1..1) → 1b
  loop:        so 2:(`AudioLoop;      2)   / (h;on) → 1b
  seek:        so 2:(`AudioSeek;      2)   / (h;frame) → 1b
  pos:         so 2:(`AudioPos;       2)   / (h;xyz_F) → 1b
  vel:         so 2:(`AudioVel;       2)   / (h;xyz_F) → 1b
  dir:         so 2:(`AudioDir;       2)   / (h;xyz_F) → 1b
  spatial:     so 2:(`AudioSpatial;   2)   / (h;on) → 1b
  range:       so 2:(`AudioRange;     2)   / (h;(min;max)_F) → 1b
  listener:    so 2:(`AudioListener;    1) / xyz_F → 1b
  listenerDir: so 2:(`AudioListenerDir; 1) / xyz_F → 1b
  listenerVel: so 2:(`AudioListenerVel; 1) / xyz_F → 1b
  listenerUp:  so 2:(`AudioListenerUp;  1) / xyz_F → 1b
  decode:      so 2:(`AudioDecode;    1)   / "path" → `channels`rate`frames`data
  encode:      so 2:(`AudioEncode;    1)   / (path;channels;rate;data) → 1b
  recStart:    so 2:(`AudioRecStart; 1)   / (channels;rate)_I → 1b
  recStop:     so 2:(`AudioRecStop;  1)   / x → 1b
  recInfo:     so 2:(`AudioRecInfo;  1)   / x → (channels;rate;available)_I
  recRead:     so 2:(`AudioRecRead;  1)   / maxFrames → F (interleaved)

/ lib/camera.k — orbit camera for the isometric demos.
/
/ One frame of input (the `props` dict gpuRun passes the loop) folds into a
/ small camera-state dict; read the result to drive a vertex shader or a
/ CPU-side transform.  This factors the pan/zoom/rotate input handling that
/ pbr.k and sword.k used to each carry verbatim.
/
/ Controls (matching the demos):
/   WASD           — pan        (camX/camZ)
/   Scroll         — zoom       (clamped 0.3 .. 5)
/   Right-drag X   — yaw   (Y-axis rotation, cos/sin in rotCa/rotSa)
/   Right-drag Y   — tilt  (X-axis rotation, cos/sin in xCa/xSa)
/
/ Input comes from the props`events TABLE (see lib/gpu.k). gpuRun no longer
/ reports held keys/buttons, so the camera state tracks them itself: WASD keys
/ (GLFW codes 87/65/83/68) and the right mouse button (button 1) are held/released
/ by `key`/`mouse` down-events; scroll sums the frame's `scroll` amt.
/
/ Rotation is tracked as cos/sin pairs updated by a small-angle rotation each
/ drag delta (no trig per frame): for delta angle d, (c;s) ← (c·cosd − s·sind;
/ s·cosd + c·sind) with cosd ≈ 1 − d²/2, sind ≈ d.
/
/ Usage:
/   cam:: CamNew[]                       / or CamAt[...] for a preset view
/   ... inside the loop ...
/   cam:: CamUpdate[cam; props]
/   ca: cam`rotCa; sa: cam`rotSa; xca: cam`xCa; xsa: cam`xSa
/   zoom: cam`zoom; camX: cam`camX; camZ: cam`camZ

/ CamAt[rotCa;rotSa;xCa;xSa] — camera at a given yaw/tilt (cos/sin pairs),
/ no pan, zoom 1. hW/hA/hS/hD/hR track held WASD + right-button across frames.
CamAt: {[rotCa;rotSa;xCa;xSa]
  `camX`camZ`zoom`rotCa`rotSa`xCa`xSa`lastMx`lastMy`hW`hA`hS`hD`hR!(0.;0.;1.;rotCa;rotSa;xCa;xSa;0.;0.;0;0;0;0;0)}

/ CamNew[] — identity orbit (front-on, no rotation).
CamNew: {[] CamAt[1.;0.;1.;0.]}

/ Held state from key/mouse down-events: for a given code, the last matching
/ event's `down` wins; if none this frame, keep the prior value. codes are GLFW.
/ Works on an empty events table too (filtering yields a typed-empty column).
CamHeld:   {[E;kind;code;prev] d: (E`down)@&(kind=(E`kind))&(code=(E`code)); $[#d; *|d; prev]}
CamScroll: {[E] sc: (E`amt)@&`scroll=(E`kind); $[#sc; +/sc; 0.]}

/ CamUpdate[c;props] — apply one frame of events, return new state.
CamUpdate: {[c;props]
  E: props`events
  mx: props`mx; my: props`my
  / current state into locals (dict-index is only safe as a standalone term)
  camX: c`camX; camZ: c`camZ; zoom: c`zoom
  rotCa: c`rotCa; rotSa: c`rotSa; xCa: c`xCa; xSa: c`xSa
  lastMx: c`lastMx; lastMy: c`lastMy

  / Held WASD + right button, updated from this frame's down/up events
  kw: CamHeld[E;`key;87;c`hW]; ka: CamHeld[E;`key;65;c`hA]
  ks: CamHeld[E;`key;83;c`hS]; kd: CamHeld[E;`key;68;c`hD]
  rmb: CamHeld[E;`mouse;1;c`hR]
  / Zoom: sum this frame's scroll deltas (0 if none)
  scroll: CamScroll E

  / Pan (speed scales inversely with zoom) + clamped zoom
  spd: 0.05%zoom
  da: kd-ka; ws: kw-ks
  camX2: camX+(spd*(da+ws)); camZ2: camZ+(spd*(da-ws))
  zoom2: 5.0&(0.3|zoom*(1.0+(scroll*0.1)))

  / Right-drag rotates; non-drag frames leave orientation untouched
  dragging: rmb>0
  dx: $[dragging; mx-lastMx; 0.]
  dy: $[dragging; my-lastMy; 0.]
  dSa: dx*0.003; dCa: 1.0-(dSa*dSa*0.5)
  nCa: $[dragging; (rotCa*dCa)-(rotSa*dSa); rotCa]
  nSa: $[dragging; (rotSa*dCa)+(rotCa*dSa); rotSa]
  dxSa: dy*0.003; dxCa: 1.0-(dxSa*dxSa*0.5)
  nxCa: $[dragging; (xCa*dxCa)-(xSa*dxSa); xCa]
  nxSa: $[dragging; (xSa*dxCa)+(xCa*dxSa); xSa]

  `camX`camZ`zoom`rotCa`rotSa`xCa`xSa`lastMx`lastMy`hW`hA`hS`hD`hR!(camX2;camZ2;zoom2;nCa;nSa;nxCa;nxSa;mx;my;kw;ka;ks;kd;rmb)}

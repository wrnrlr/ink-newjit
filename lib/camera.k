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
/ no pan, zoom 1.
CamAt: {[rotCa;rotSa;xCa;xSa]
  `camX`camZ`zoom`rotCa`rotSa`xCa`xSa`lastMx`lastMy!(0.;0.;1.;rotCa;rotSa;xCa;xSa;0.;0.)}

/ CamNew[] — identity orbit (front-on, no rotation).
CamNew: {[] CamAt[1.;0.;1.;0.]}

/ CamUpdate[c;props] — apply one frame of WASD/scroll/right-drag, return new state.
CamUpdate: {[c;props]
  / props fields read into locals first (`dict`key OP x` parses wrong otherwise)
  kw: props`kw; ka: props`ka; ks: props`ks; kd: props`kd
  scroll: props`scroll; rmb: props`rmb; mx: props`mx; my: props`my
  / current state into locals (dict-index is only safe as a standalone term)
  camX: c`camX; camZ: c`camZ; zoom: c`zoom
  rotCa: c`rotCa; rotSa: c`rotSa; xCa: c`xCa; xSa: c`xSa
  lastMx: c`lastMx; lastMy: c`lastMy

  / Pan (speed scales inversely with zoom) + clamped zoom
  spd: 0.05%zoom
  da: kd-ka; ws: kw-ks
  camX2: camX+(spd*(da+ws)); camZ2: camZ+(spd*(da-ws))
  zoom2: 5.0&(0.3|zoom*(1.0+(scroll*0.1)))

  / Right-drag rotates; non-drag frames leave orientation untouched
  dragging: rmb>0.
  dx: $[dragging; mx-lastMx; 0.]
  dy: $[dragging; my-lastMy; 0.]
  dSa: dx*0.003; dCa: 1.0-(dSa*dSa*0.5)
  nCa: $[dragging; (rotCa*dCa)-(rotSa*dSa); rotCa]
  nSa: $[dragging; (rotSa*dCa)+(rotCa*dSa); rotSa]
  dxSa: dy*0.003; dxCa: 1.0-(dxSa*dxSa*0.5)
  nxCa: $[dragging; (xCa*dxCa)-(xSa*dxSa); xCa]
  nxSa: $[dragging; (xSa*dxCa)+(xCa*dxSa); xSa]

  `camX`camZ`zoom`rotCa`rotSa`xCa`xSa`lastMx`lastMy!(camX2;camZ2;zoom2;nCa;nSa;nxCa;nxSa;mx;my)}

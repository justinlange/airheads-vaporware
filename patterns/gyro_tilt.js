// gyro_tilt — Pixelblaze pattern that responds to phone tilt
//
// Companion pattern for the /gyro page in the Firestorm clone at
// ~/Github/hairheads/Firestorm/. The page streams these three exported
// variables at ~30 Hz to every Pixelblaze on the LAN; each unit reads
// them inside render() and shifts hue + brightness accordingly.
//
// To install on a unit:
//   1. Open the unit's web UI:  http://<unit-ip>/
//   2. Edit Pattern -> New Pattern -> name it "gyro_tilt"
//   3. Paste this whole file into the editor and save
//   4. (Optional) From Firestorm, "clone programs" out to the rest
//
// All three variables are normalized client-side, so no need to scale here:
//   tiltX in [-1, 1]   left-right tilt
//   tiltY in [-1, 1]   front-back tilt
//   tiltZ in [ 0, 1]   compass heading

export var tiltX = 0
export var tiltY = 0
export var tiltZ = 0

// time(.1) advances 0..1 over ~10 seconds. Identical across units when
// Firestorm's PixelblazeEnumerator timesync is on (it is by default), so
// the rotating hue band lines up across the group.
export function beforeRender(delta) {
  t1 = time(.1)
}

export function render(index) {
  pct = index / pixelCount

  // Hue: rolling rainbow shifted by horizontal tilt.
  h = pct + tiltX * .5 + t1

  // Brightness: a wave whose phase shifts with vertical tilt; envelope
  // gets brighter the further from compass-center (tiltZ near 0.5 = dim,
  // facing N or S = bright). Tweak the .4 / 1.2 to taste.
  v = wave(pct - tiltY * .5) * (.4 + abs(tiltZ - .5) * 1.2)

  hsv(h, 1, clamp(v, 0, 1))
}

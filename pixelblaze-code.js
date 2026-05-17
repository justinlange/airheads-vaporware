// --- UI SLIDERS ---
export var colorDiversity = 0.5
export var speed = 0.5
export var expression = 0.5
export var tailLength = 0.5

export function sliderColorDiversity(v) { colorDiversity = v }
export function sliderSpeed(v) { speed = v }
export function sliderExpression(v) { expression = v }
export function sliderTailLength(v) { tailLength = v }

// --- HARDWARE & BUFFERS ---
var loopSize = 34
var vBuf = array(pixelCount) // Stores the brightness (for fading trails)
var hBuf = array(pixelCount) // Stores the hue 

// Custom Time Accumulators
var phaseCylon = 0
var phaseChaser = 0
var globalHue = 0

// --- HELPER FUNCTION: MIRRORED DRAWING ---
function drawMirroredHead(pos, hue, brightness) {
  if (brightness <= 0) return
  
  pos = pos % loopSize
  if (pos < 0) pos += loopSize
  
  var idx1 = floor(pos)
  var idx2 = (idx1 + 1) % loopSize
  var frac = pos - idx1 
  
  // Left Loop (Indices 0 to 33)
  vBuf[idx1] = max(vBuf[idx1], brightness * (1 - frac))
  vBuf[idx2] = max(vBuf[idx2], brightness * frac)
  hBuf[idx1] = hue
  hBuf[idx2] = hue
  
  // Right Loop (Indices 34 to 67)
  var r1 = (pixelCount - 1) - idx1
  var r2 = (pixelCount - 1) - idx2
  vBuf[r1] = max(vBuf[r1], brightness * (1 - frac))
  vBuf[r2] = max(vBuf[r2], brightness * frac)
  hBuf[r1] = hue
  hBuf[r2] = hue
}

export function beforeRender(delta) {
  // ---------------------------------------------------------
  // 1. THE MASSIVE GLOBAL FADE
  // ---------------------------------------------------------
  var inverseTail = 1 - tailLength
  var decay = delta * (0.00005 + (pow(inverseTail, 3) * 0.008))
  
  for (i = 0; i < pixelCount; i++) {
    vBuf[i] -= decay
    if (vBuf[i] < 0) vBuf[i] = 0
  }

  // ---------------------------------------------------------
  // 2. ULTRA-SMOOTH TIME ACCUMULATION
  // ---------------------------------------------------------
  // Power curve for speed. 
  // At speed=0 -> 0.000002 (Glacial crawl, ~15 mins per cycle)
  // At speed=1 -> 0.002002 (Very fast, ~1 sec per cycle)
  var currentSpeed = 0.000002 + (pow(speed, 3) * 0.002)
  
  // Accumulate phases based on delta (milliseconds since last frame)
  // This guarantees silky smooth movement even at microscopic speeds
  phaseCylon  += delta * currentSpeed * 0.5
  phaseChaser += delta * currentSpeed * 1.5
  globalHue   += delta * currentSpeed * 0.1
  
  // Keep values wrapped safely between 0.0 and 1.0
  phaseCylon  -= floor(phaseCylon)
  phaseChaser -= floor(phaseChaser)
  globalHue   -= floor(globalHue)
  
  // ---------------------------------------------------------
  // 3. BLENDING PREP
  // ---------------------------------------------------------
  var cylonBright    = max(0, 1 - (expression * 2))
  var chaserBright   = max(0, 1 - abs(expression - 0.5) * 2)
  var fireworkBright = max(0, (expression * 2) - 1)

  // ---------------------------------------------------------
  // 4. MODE A: THE MIRRORED CYLON (Low Expression)
  // ---------------------------------------------------------
  if (cylonBright > 0) {
    var cylonPos = wave(phaseCylon) * (loopSize - 1)
    drawMirroredHead(cylonPos, globalHue, cylonBright)
  }

  // ---------------------------------------------------------
  // 5. MODE B: MULTI-STRIP CHASERS (Mid Expression)
  // ---------------------------------------------------------
  if (chaserBright > 0) {
    var basePos = phaseChaser * loopSize 
    var numHeads = 4 
    
    for (j = 0; j < numHeads; j++) {
      var headPos = basePos + (j * (loopSize / numHeads))
      var headHue = globalHue + (j * colorDiversity * 0.5) 
      drawMirroredHead(headPos, headHue, chaserBright)
    }
  }

  // ---------------------------------------------------------
  // 6. MODE C: SYNCHRONIZED FIREWORKS (High Expression)
  // ---------------------------------------------------------
  if (fireworkBright > 0) {
    // Probability scales with delta and speed so it fires correctly at ultra-slow speeds
    var popChance = delta * (0.00002 + pow(speed, 2) * 0.01) * fireworkBright
    
    if (random(1) < popChance) {
      var popPos = floor(random(loopSize))
      var popHue = globalHue + random(colorDiversity)
      drawMirroredHead(popPos, popHue, fireworkBright)
    }
  }
}

export function render(index) {
  var v = vBuf[index]
  var h = hBuf[index]
  
  // ---------------------------------------------------------
  // COLOR DIVERSITY -> MONOCHROME WHITE RULE
  // ---------------------------------------------------------
  var sat = clamp(colorDiversity * 10, 0, 1)
  
  // Apply a square curve to the brightness (v * v). 
  // This gamma-correction trick makes the fading tails buttery smooth.
  hsv(h, sat, v * v)
}
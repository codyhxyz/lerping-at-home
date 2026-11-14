// Shader › Track Head with Camera: the camera into MediaPipe Face Landmarker,
// and only numbers back to the app (FaceLandmarks.swift). Nothing is drawn.
// The same camera loop as hand-tracking.js: requestVideoFrameCallback, one
// frame in flight, frames as ImageBitmaps to a worker.
const post = (message) => globalThis.webkit?.messageHandlers?.face?.postMessage(message);
const video = document.getElementById('face-video');
// Every step and every failure is said out loud: a page that stalls silently
// is a head tracker that silently is not one.
const step = (message) => post({ type: 'step', message });
globalThis.addEventListener('error', (event) => fail(`page: ${event.message}`));
globalThis.addEventListener('unhandledrejection', (event) => fail(`page: ${event.reason?.message || event.reason}`));

let enabled = false;
let generation = 0;
let stream = null;
let worker = null;
let workerReady = null;
let busy = false;
let frame = 0;
let lastVideoTime = -1;

async function enable() {
  if (enabled) return;
  enabled = true;
  const startedAs = ++generation;
  step(`opening the camera (page ${document.visibilityState})`);
  try {
    const opened = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'user', width: { ideal: 640 }, height: { ideal: 480 },
               frameRate: { ideal: 30, max: 30 } },
      audio: false,
    });
    // Stopped while the camera was answering: close it, light and all.
    if (startedAs !== generation) {
      opened.getTracks().forEach((track) => track.stop());
      return;
    }
    stream = opened;
    video.srcObject = stream;
    await video.play();
    lastVideoTime = -1;
    step('camera open; loading the face model');
    const track = stream.getVideoTracks()[0];
    track.onended = () => { if (enabled) fail('Camera disconnected'); };
    await ensureWorker();
    if (startedAs !== generation) return;
    post({ type: 'started', camera: track.label || 'Camera' });
    schedule();
  } catch (error) {
    fail(error?.message || String(error));
  }
}

function disable() {
  enabled = false;
  generation += 1;
  if (frame) video.cancelVideoFrameCallback(frame);
  frame = 0;
  busy = false;
  for (const track of stream?.getTracks() || []) {
    track.onended = null;
    track.stop();
  }
  stream = null;
  video.srcObject = null;
}

function fail(message) {
  disable();
  post({ type: 'error', message });
}

function ensureWorker() {
  if (workerReady) return workerReady;
  worker = new Worker('/app/face-worker.js', { type: 'module' });
  workerReady = new Promise((resolve, reject) => {
    worker.addEventListener('message', ({ data }) => {
      if (data.type === 'ready') return resolve();
      if (data.type === 'error') {
        reject(new Error(data.message));
        return fail(data.message);
      }
      if (data.type !== 'result') return;
      busy = false;
      if (!enabled || data.generation !== generation) return;
      // How long ago the frame was captured, so the app can stamp it on its
      // own clock: the pose filter predicts across exactly this.
      post({ type: 'face', face: data.face, width: data.width, height: data.height,
             age: (performance.now() - data.captured) / 1000 });
    });
    worker.addEventListener('error', (event) => {
      const message = event.message || 'Face tracking worker failed';
      reject(new Error(message));
      fail(message);
    });
  });
  return workerReady;
}

function schedule() {
  if (!frame && enabled) frame = video.requestVideoFrameCallback(onFrame);
}

function onFrame(now, metadata) {
  frame = 0;
  if (!enabled) return;
  if (!busy && worker && video.currentTime !== lastVideoTime) {
    lastVideoTime = video.currentTime;
    busy = true;
    const startedAs = generation;
    const captured = metadata.captureTime ?? now;
    const width = video.videoWidth, height = video.videoHeight;
    createImageBitmap(video).then((bitmap) => {
      if (!enabled || startedAs !== generation) {
        bitmap.close();
        busy = false;
        return;
      }
      worker.postMessage({ type: 'frame', frame: bitmap, timestamp: now, captured, width, height,
                           generation: startedAs }, [bitmap]);
    }).catch(() => { busy = false; });
  }
  schedule();
}

globalThis.lerpFace = { enable, disable };
enable();

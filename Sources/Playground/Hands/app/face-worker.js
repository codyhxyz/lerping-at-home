// MediaPipe Face Landmarker in VIDEO mode: it follows the face from frame to
// frame rather than detecting it afresh, which is what keeps a still head
// from flickering in and out. One face; its irises, extent and yaw go back.
let landmarker = null;

initialize().catch((error) => {
  self.postMessage({ type: 'error', message: error?.message || String(error) });
});

self.addEventListener('message', ({ data }) => {
  if (data.type !== 'frame' || !landmarker) {
    data.frame?.close();
    return;
  }
  try {
    const result = landmarker.detectForVideo(data.frame, data.timestamp);
    self.postMessage({ type: 'result', generation: data.generation, captured: data.captured,
                       width: data.width, height: data.height, face: face(result) });
  } catch (error) {
    self.postMessage({ type: 'error', message: error?.message || String(error) });
  } finally {
    data.frame.close();
  }
});

// Landmarks are normalised to the frame, origin top left. 468 and 473 are the
// iris centres of the 478-point mesh (the subject's right, then left).
function face(result) {
  const points = result.faceLandmarks?.[0];
  if (!points || points.length < 478) return null;
  let minX = 1, minY = 1, maxX = 0, maxY = 0;
  for (const p of points) {
    minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
    minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
  }
  // The face's rotation, column-major: its forward axis is the third column,
  // and yaw is that axis turned about the vertical.
  const m = result.facialTransformationMatrixes?.[0]?.data;
  return {
    irises: [[points[468].x, points[468].y], [points[473].x, points[473].y]],
    box: [minX, minY, maxX, maxY],
    yaw: m ? Math.atan2(m[8], m[10]) : null,
  };
}

async function initialize() {
  const { FilesetResolver, FaceLandmarker } = await import('/vendor/mediapipe/vision_bundle.mjs');
  const vision = await FilesetResolver.forVisionTasks('/vendor/mediapipe/wasm', true);
  landmarker = await FaceLandmarker.createFromOptions(vision, {
    baseOptions: { modelAssetPath: '/models/face_landmarker.task' },
    runningMode: 'VIDEO',
    numFaces: 1,
    outputFacialTransformationMatrixes: true,
  });
  self.postMessage({ type: 'ready' });
}

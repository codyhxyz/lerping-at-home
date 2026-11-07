// Peek — something lives behind your wallpaper. Original look for
// Lerping@Home (AGPL-3.0, like the rest of this project); no code from any
// Shadertoy or other shader is included.
//
// The screen is a papered wall, and the paper sits on the glass itself, so it
// never moves. Someone has torn a hole in it. Through the hole is the cavity
// behind the wall, lit by a lantern, where a small creature lives. It holds
// the bottom of the hole with both paws and watches you.
//
// It is made for head tracking (Shader › Track Head with Camera):
// - Its eyes and head follow your eye, wherever you are in front of the screen.
// - Lean in close and it ducks below the edge of the hole. Every few seconds
//   its eyes and flattened ears come back up over the rim to check on you.
// - Lean well to one side and you can see past the edge of the hole into the
//   corners of its burrow. Its lantern hangs behind the left edge, and behind
//   the right edge it has put up a sign. Neither shows from straight on.
// Without a tracked head (the saver, snapshots, gallery stills) it is still
// alive: it blinks, twitches an ear, breathes, sways, and glances at its
// lantern, its sign, the floor or somewhere in your room before looking back
// at you.
//
// Everything is a pure function of (time, seed, parameters, viewer). The
// glances, blinks, twitches and peeks come from hashed time slots, and the
// duck is a smooth function of how near your head is, so nothing accumulates.
//
// Camera. Camera space is world space: x right, y up, z into the screen. The
// glass is the plane z = 0 and spans ±1 on the short axis (lerpUV), and the
// nominal eye sits at z = -PK_F. lerpViewerRay moves the eye but keeps each
// pixel's ray through its own spot on the glass, so the wallpaper is pinned
// and everything behind it swings. Pixels off the hole are shaded in 2D at
// their glass point; only the hole is raymarched, about an eighth of a
// landscape screen.
//
// Hiding. The duck is not a fixed drop. The creature works out where the line
// from your eye over the bottom of the rim passes at its own depth, and puts
// its head that far below it (or, when peeking, its eyes just above it). So
// it stays hidden however you lean in, and peeks the same way from anywhere.
//
// lerp-category: Scenes
// lerp-param: parallax float 0 2 = 1    "Head parallax"
// lerp-param: shy      float 0 2 = 1    "Hide sensitivity"
// lerp-param: wander   float 0 1 = 0.55 "Glances away"
// lerp-param: lamp     float 0 2 = 1    "Lantern"
// lerp-param: fur      color     = (0.40, 0.44, 0.62) "Fur"
// lerp-param: eyes     color     = (1.0, 0.74, 0.26)  "Eye glow"
// lerp-param: paper    color     = (0.07, 0.15, 0.13) "Wallpaper"
// lerp-param: motif    color     = (0.36, 0.29, 0.15) "Wallpaper motif"
//
// lerp-preset: Moth          fur=(0.84, 0.81, 0.74), eyes=(0.55, 0.95, 0.80)
// lerp-preset: Moth          paper=(0.15, 0.09, 0.15), motif=(0.40, 0.27, 0.34)
// lerp-preset: Ember         fur=(0.80, 0.40, 0.17), eyes=(0.60, 0.95, 1.0)
// lerp-preset: Ember         paper=(0.05, 0.10, 0.15), motif=(0.18, 0.30, 0.36)
// lerp-preset: "Night Shift" lamp=0.3, fur=(0.20, 0.19, 0.25), eyes=(0.75, 1.0, 0.35)

#define PK_F      1.6     // focal length: the glass spans ±1 (short axis) this far from the eye
#define PK_T      0.08    // wall thickness
#define PK_HR     0.5     // hole radius
#define PK_FLOOR -1.5
#define PK_CEIL   0.95

constant float2 PK_HC     = float2(0.0, -0.05);        // hole centre, on the glass
constant float3 PK_ROOM_C = float3(0.0, -0.275, 0.70); // the cavity: z from -0.05 to 1.45
constant float3 PK_ROOM_H = float3(1.55, 1.225, 0.75);
constant float3 PK_LAMP0  = float3(-0.88, 0.04, 0.60); // behind the left edge of the hole
constant float3 PK_SIGN   = float3(0.97, -0.10, 0.58); // behind the right edge
constant float3 PK_RLAMP  = float3(1.4, 1.8, -2.4);    // the light in your room

#define PK_M_PLASTER 1.0
#define PK_M_WOOD    2.0
#define PK_M_FUR     3.0
#define PK_M_MUZZLE  4.0
#define PK_M_NOSE    5.0
#define PK_M_EYE     6.0
#define PK_M_EARIN   7.0
#define PK_M_LID     8.0
#define PK_M_IRON    9.0
#define PK_M_GLASS  10.0
#define PK_M_SIGN   11.0

// ---------------------------------------------------------------- primitives

static inline float pkSmin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

static inline float pkBox(float3 p, float3 h) {
    float3 q = abs(p) - h;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Ellipsoid, the usual bound-corrected approximation.
static inline float pkEll(float3 p, float3 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-4);
}

static inline float pkCapsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

static inline float pkSeg2(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

// ---------------------------------------------------------------- the hole

// The torn edge, as a radius by angle. Straight down the paws have worn it
// smooth, which is also what lets them rest on a true circle.
static inline float pkHoleR(float a) {
    float fromBottom = abs(glmod(a + 1.5 * PI, TWO_PI) - PI);
    float torn = 0.030 * sin(5.0 * a + 1.3) + 0.016 * sin(9.0 * a + 4.0)
               + 0.008 * sin(17.0 * a + 0.4) + 0.004 * sin(31.0 * a + 2.2);
    return PK_HR + torn * smoothstep(0.5, 1.3, fromBottom);
}

static inline float pkHole(float2 q) {
    float2 d = q - PK_HC;
    return length(d) - pkHoleR(atan2(d.y, d.x));
}

// Where the paper stops: a ragged band of bare plaster round the hole.
static inline float pkPaperR(float a) {
    return pkHoleR(a) + 0.03 + 0.035 * (0.5 + 0.5 * sin(3.0 * a + 0.7))
         + 0.010 * sin(13.0 * a + 1.9) + 0.006 * sin(29.0 * a + 0.3);
}

// Height of the (smooth) bottom of the hole at x.
static inline float pkRimY(float x) {
    return PK_HC.y - sqrt(max(PK_HR * PK_HR - x * x, 0.0));
}

// ---------------------------------------------------------------- behaviour

struct PkState {
    float3 head, R, U, B;      // head centre and frame (the face looks along -B)
    float3 gaze;               // what the eyes are looking at
    float  lidTop, lidBot;     // lid lines, eye-local y
    float  earBack;            // 0 up, 1 flat back
    float  earL, earR;         // twitch
    float3 body, bodyR;
    float3 shoulderL, shoulderR, pawL, pawR;
    float3 shiftL, shiftR;     // how far each paw has left the rim
    float  pupil;              // pupil half-angle
    float3 lamp;
    float  lampI;
};

// Slot k's thing to look at. Most slots it watches you. When you have leant
// far enough to see one of its hidden things (`found`, by `reveal`), that is
// where its glances away go: it checks what you are looking at.
static float3 pkGlanceTarget(float k, float seed, float3 E, float wander, float3 found, float reveal) {
    // The offset is picked so the gallery still (t=6, seed 0.37) is watching you.
    float h = hash11(k * 1.37 + seed * 91.7 + 2.9);
    if (h > wander * 0.75) return E;
    float w = hash11(k * 2.91 + seed * 37.3 + 11.0);
    float3 away;
    if (w < 0.24)      away = PK_LAMP0;
    else if (w < 0.44) away = PK_SIGN + float3(0.0, 0.04, 0.0);
    else if (w < 0.56) away = float3(0.1, PK_FLOOR, 0.35);
    else {
        float2 r = hash22(float2(k * 0.77 + 5.0, seed * 13.1 + 2.0)) * 2.0 - 1.0;
        away = float3(r.x * 1.8, r.y * 0.7 + 0.1, -1.3);   // somewhere out in your room
    }
    return mix(away, found, reveal);
}

// The glance at time t: a jump from the last slot's target to this one's at a
// random moment in the slot, taking `dur` seconds (quick for eyes, slower for
// the head).
static float3 pkGlance(float t, float seed, float3 E, float wander, float3 found, float reveal, float dur) {
    const float P = 2.9;
    float k = floor(t / P);
    float f = t - k * P;
    float at = 0.3 + 1.6 * hash11(k * 3.17 + seed * 7.0);
    float s = smoothstep(at, at + dur, f);
    return mix(pkGlanceTarget(k - 1.0, seed, E, wander, found, reveal),
               pkGlanceTarget(k, seed, E, wander, found, reveal), s);
}

// Lid closure 0…1: one blink per slot, now and then a double.
static float pkBlink(float t, float seed) {
    const float P = 3.7;
    float k = floor(t / P);
    float f = t - k * P;
    float b0 = 0.4 + 2.6 * hash11(k * 5.31 + seed * 17.0);
    float c = 1.0 - smoothstep(0.0, 0.11, abs(f - b0));
    if (hash11(k * 2.7 + seed * 3.0 + 1.3) > 0.72)
        c = max(c, 1.0 - smoothstep(0.0, 0.10, abs(f - b0 - 0.3)));
    return c;
}

static PkState pkBehave(constant LerpUniforms& u, float3 Eview) {
    PkState S;
    float seed = u.seed;
    float t = u.time + seed * 97.0;

    // Where it thinks you are. Gaze follows the head at full strength even
    // when the scene's parallax is turned down, so it still watches you.
    float3 E = float3(0.0, 0.0, -PK_F) + u.viewer.xyz * (PK_F * max(u.parallax, 1.0));

    // Duck: lean nearer than the threshold and it goes down. While down it
    // comes up to peek for about two seconds in every five and a half.
    float duck = smoothstep(0.10, 0.24, u.viewer.z * u.shy);
    float pp = fract(t / 5.5 + 0.3);
    float peek = smoothstep(0.30, 0.42, pp) * (1.0 - smoothstep(0.80, 0.90, pp));

    // Attention: off-centre or close, you are what it looks at.
    float lock = clamp(smoothstep(0.06, 0.28, length(u.viewer.xyz)) * 0.85 + duck, 0.0, 1.0);
    // Leant far enough to see round the edge: lean right and you see the
    // lantern behind the left edge, lean left and the sign behind the right.
    float reveal = smoothstep(0.2, 0.4, abs(u.viewer.x)) * (1.0 - duck);
    float3 found = u.viewer.x > 0.0 ? PK_LAMP0 : PK_SIGN + float3(0.0, 0.04, 0.0);
    lock *= 1.0 - 0.7 * reveal;

    float bre = sin(t * 1.9);
    float3 head = float3(0.035 * sin(0.31 * t + seed * 6.0) + 0.015 * sin(0.83 * t),
                         -0.05 + 0.008 * bre,
                         0.47);
    head.z += 0.12 * duck;

    // The line from the eye that is drawing the frame over the rim, at the
    // head's depth: below it is hidden.
    float rim = PK_HC.y - PK_HR;
    float yLine = Eview.y + (rim - Eview.y) * (head.z - Eview.z) / max(-Eview.z, 0.05);
    float downY = mix(yLine - 0.44, yLine - 0.035, peek);
    downY = max(downY, PK_FLOOR + 0.26);
    head.y = mix(head.y, min(downY, head.y), duck);

    // Gaze.
    float3 eyesAt = pkGlance(t, seed, E, u.wander, found, reveal, 0.10);
    float3 headAt = pkGlance(t, seed, E, u.wander, found, reveal, 0.55);
    eyesAt = mix(eyesAt, E, lock);
    headAt = mix(E, mix(headAt, E, lock), 0.6);   // the head only goes part of the way
    S.gaze = eyesAt;

    float3 dir = normalize(headAt - head);
    float yaw = clamp(atan2(dir.x, -dir.z), -0.7, 0.7);
    float pitch = clamp(asin(clamp(dir.y, -1.0, 1.0)), -0.5, 0.5);
    float3 face = float3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch));
    float3 B = -face;
    float3 R = normalize(cross(float3(0.0, 1.0, 0.0), B));
    float3 U = cross(B, R);
    // A curious tilt: idle, and towards whichever side you lean.
    float roll = 0.09 * sin(0.23 * t + seed * 4.0) - 0.35 * clamp(u.viewer.x, -0.6, 0.6) * (1.0 - duck);
    float cr = cos(roll), sr = sin(roll);
    S.R = cr * R + sr * U;
    S.U = -sr * R + cr * U;
    S.B = B;
    S.head = head;

    // Lids: blinks, wide-eyed when hiding.
    float blink = pkBlink(t, seed);
    float top = mix(0.07, 0.10, duck);
    S.lidTop = mix(top, -0.025, blink);
    S.lidBot = mix(-0.085, -0.035, blink);
    S.pupil = 0.30 + 0.10 * lock + 0.05 * duck;

    // Ears: flat when hiding, and a flick of one now and then.
    S.earBack = duck;
    float ek = floor(t / 4.3);
    float ef = t - ek * 4.3;
    float eat = 0.5 + 3.0 * hash11(ek * 3.7 + seed * 5.0);
    float fe = (ef - eat) * 9.0;
    float flick = 0.4 * exp(-fe * fe);
    bool leftEar = hash11(ek * 1.9 + seed * 2.0 + 0.7) > 0.5;
    S.earL = leftEar ? flick : 0.0;
    S.earR = leftEar ? 0.0 : flick;

    // Body: from under the head down to the floor.
    float bodyTop = head.y - 0.12;
    float ry = max(0.5 * (bodyTop - PK_FLOOR), 0.14);
    S.body = float3(0.7 * head.x, bodyTop - ry, head.z + 0.13);
    S.bodyR = float3(0.30, ry, 0.27) * (1.0 + 0.022 * bre);

    // Paws on the rim, let go as soon as it starts to duck.
    float grip = 1.0 - smoothstep(0.02, 0.3, duck);
    float3 restL = float3(-0.2, pkRimY(0.2) + 0.035, PK_T + 0.055);
    float3 restR = float3( 0.2, restL.y, restL.z);
    float tuckY = max(head.y - 0.36, PK_FLOOR + 0.07);
    float3 tuckL = float3(-0.13, tuckY, head.z - 0.15);
    float3 tuckR = float3( 0.13, tuckY, head.z - 0.15);
    S.pawL = mix(tuckL, restL, grip);
    S.pawR = mix(tuckR, restR, grip);
    S.shiftL = S.pawL - restL;
    S.shiftR = S.pawR - restR;
    S.shoulderL = float3(S.body.x - 0.17, head.y - 0.33, head.z + 0.05);
    S.shoulderR = float3(S.body.x + 0.17, head.y - 0.33, head.z + 0.05);

    // The lantern sways a little on its cord and its flame breathes.
    S.lamp = PK_LAMP0 + float3(0.012 * sin(0.9 * t), 0.0, 0.008 * sin(0.7 * t + 1.0));
    float fl = 0.88 + 0.08 * sin(7.3 * t) + 0.05 * sin(13.1 * t + 1.7) + 0.04 * valueNoise(float2(t * 6.0, 3.0));
    S.lampI = u.lamp * fl;
    return S;
}

static inline float3 pkLocal(thread const PkState& S, float3 p) {
    float3 d = p - S.head;
    return float3(dot(d, S.R), dot(d, S.U), dot(d, S.B));
}

// ---------------------------------------------------------------- the creature

static float2 pkCreature(float3 p, thread const PkState& S) {
    float3 l = pkLocal(S, p);
    float3 ls = float3(abs(l.x), l.y, l.z);

    // Head, cheek fluff, body.
    float dFur = pkEll(l, float3(0.33, 0.30, 0.31));
    dFur = pkSmin(dFur, pkEll(ls - float3(0.19, -0.11, -0.10), float3(0.15, 0.12, 0.14)), 0.06);
    dFur = pkSmin(dFur, pkEll(p - S.body, S.bodyR), 0.14);

    // Arms, paws, and fingers curled over the edge of the hole.
    float dArm = min(pkCapsule(p, S.shoulderL, S.pawL, 0.05), pkCapsule(p, S.shoulderR, S.pawR, 0.05));
    float dPaw = min(pkEll(p - S.pawL, float3(0.075, 0.05, 0.065)),
                     pkEll(p - S.pawR, float3(0.075, 0.05, 0.065)));
    for (int side = 0; side < 2; side++) {
        float sx = side == 0 ? -1.0 : 1.0;
        float3 sh = side == 0 ? S.shiftL : S.shiftR;
        // Far from this paw, a sphere round its fingers is bound enough.
        float far = length(p - (side == 0 ? S.pawL : S.pawR));
        if (far > 0.25) { dPaw = min(dPaw, far - 0.16); continue; }
        for (int i = -1; i <= 1; i++) {
            float fx = sx * 0.2 + float(i) * 0.036;
            float fy = pkRimY(fx) + 0.021;
            float3 a = float3(fx, fy + 0.014, PK_T + 0.035) + sh;
            float3 b = float3(fx, fy, 0.028) + sh;
            dPaw = pkSmin(dPaw, pkCapsule(p, a, b, 0.019), 0.02);
        }
    }
    dFur = pkSmin(dFur, pkSmin(dArm, dPaw, 0.04), 0.06);

    // Ears: a lean outwards, then folded back by earBack.
    float tw = l.x > 0.0 ? S.earR : S.earL;
    float3 e = ls - float3(0.17, 0.22, 0.05);
    e.xy = rotate(e.xy, 0.38 + tw);
    e.yz = rotate(e.yz, -(0.15 + 1.15 * S.earBack));
    float dEar = pkEll(e - float3(0.0, 0.15, 0.0), float3(0.085, 0.175, 0.032));
    float dIn  = pkEll(e - float3(0.0, 0.14, -0.022), float3(0.05, 0.12, 0.016));
    dFur = pkSmin(dFur, dEar, 0.04);

    // Muzzle and nose.
    float dMz = pkEll(l - float3(0.0, -0.105, -0.245), float3(0.12, 0.08, 0.09));
    float dNose = pkEll(l - float3(0.0, -0.07, -0.335), float3(0.042, 0.028, 0.03));

    float d = pkSmin(dFur, dMz, 0.03);
    float2 res = float2(d, dMz < dFur + 0.004 ? PK_M_MUZZLE : PK_M_FUR);
    if (dIn < dEar && dIn < res.x + 0.003) res = float2(min(res.x, dIn), PK_M_EARIN);
    if (dNose < res.x) res = float2(dNose, PK_M_NOSE);

    // Eyes, and lids: a slightly larger shell kept above the upper lid line
    // and below the lower one.
    float3 ep = ls - float3(0.13, 0.04, -0.215);
    float r = length(ep);
    float dEye = r - 0.105;
    float dLid = max(r - 0.114, min(S.lidTop - ep.y, ep.y - S.lidBot));
    if (dEye < res.x) res = float2(dEye, PK_M_EYE);
    if (dLid < res.x) res = float2(dLid, PK_M_LID);
    return res;
}

// Cheap outside the creature's bounds (shadows, the props' side of the room).
static inline float pkCreatureB(float3 p, thread const PkState& S) {
    float b = length(p - (S.head + float3(0.0, -0.45, 0.0))) - 1.15;
    return b > 0.05 ? b : pkCreature(p, S).x;
}

// ---------------------------------------------------------------- props

static inline float pkLantern(float3 p, thread const PkState& S, thread float& glass) {
    float3 lp = p - S.lamp;
    glass = pkBox(lp, float3(0.045, 0.075, 0.045)) - 0.012;
    float2 q = abs(lp.xz) - 0.057;
    float dPost = length(float2(length(q), max(abs(lp.y) - 0.09, 0.0))) - 0.009;
    float dCap  = max(length(lp.xz) - 0.075, abs(lp.y - 0.10) - 0.014);
    float dTop  = max(length(lp.xz) - 0.035, abs(lp.y - 0.125) - 0.012);
    float dBase = max(length(lp.xz) - 0.080, abs(lp.y + 0.10) - 0.015);
    float dCord = pkCapsule(p, S.lamp + float3(0.0, 0.13, 0.0), float3(PK_LAMP0.x, PK_CEIL, PK_LAMP0.z), 0.006);
    return min(min(dPost, dCap), min(min(dTop, dBase), dCord));
}

// The sign's frame: normal towards the hole, right as you would read it.
static inline float3 pkSignLocal(float3 p) {
    const float3 nb = normalize(float3(-PK_SIGN.x, 0.0, -PK_F - PK_SIGN.z));
    const float3 tb = float3(-nb.z, 0.0, nb.x);
    float3 d = p - PK_SIGN;
    return float3(dot(d, tb), d.y, dot(d, nb));
}

static inline float pkSign(float3 p) {
    float3 b = pkSignLocal(p);
    float dBoard = pkBox(b, float3(0.15, 0.085, 0.012)) - 0.006;
    float3 base = float3(PK_SIGN.x, PK_FLOOR, PK_SIGN.z);
    float3 back = normalize(float3(PK_SIGN.x, 0.0, PK_F + PK_SIGN.z)) * 0.03;
    float dPost = pkCapsule(p, base + back, PK_SIGN + back - float3(0.0, 0.02, 0.0), 0.016);
    return min(dBoard, dPost);
}

// ---------------------------------------------------------------- scene

static float2 pkMap(float3 p, thread const PkState& S) {
    float2 res = float2(-pkBox(p - PK_ROOM_C, PK_ROOM_H), PK_M_WOOD);
    float dWall = max(abs(p.z - 0.5 * PK_T) - 0.5 * PK_T, -0.7 * pkHole(p.xy));
    if (dWall < res.x) res = float2(dWall, PK_M_PLASTER);
    float glass;
    float dIron = pkLantern(p, S, glass);
    if (dIron < res.x) res = float2(dIron, PK_M_IRON);
    if (glass < res.x) res = float2(glass, PK_M_GLASS);
    float dSign = pkSign(p);
    if (dSign < res.x) res = float2(dSign, PK_M_SIGN);
    float b = length(p - (S.head + float3(0.0, -0.45, 0.0))) - 1.15;
    if (b < res.x) {
        float2 c = pkCreature(p, S);
        if (c.x < res.x) res = c;
    }
    return res;
}

static float3 pkNormal(float3 p, thread const PkState& S) {
    const float2 k = float2(1.0, -1.0) * 0.0012;
    return normalize(k.xyy * pkMap(p + k.xyy, S).x + k.yyx * pkMap(p + k.yyx, S).x +
                     k.yxy * pkMap(p + k.yxy, S).x + k.xxx * pkMap(p + k.xxx, S).x);
}

// Soft shadow, cast by the creature (the room is a box; the props are small
// and up against its walls).
static float pkShadow(float3 ro, float3 rd, float maxT, thread const PkState& S) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 24; i++) {
        if (t > maxT) break;
        float h = pkCreatureB(ro + rd * t, S);
        res = min(res, 9.0 * h / t);
        if (res < 0.01) break;
        t += clamp(h, 0.015, 0.25);
    }
    return clamp(res, 0.0, 1.0);
}

static float pkAO(float3 p, float3 n, thread const PkState& S) {
    float occ = 0.0, w = 1.0;
    for (int i = 1; i <= 3; i++) {
        float h = 0.03 * float(i) + 0.02;
        occ += (h - pkMap(p + n * h, S).x) * w;
        w *= 0.6;
    }
    return clamp(1.0 - 3.0 * occ, 0.0, 1.0);
}

// ---------------------------------------------------------------- surfaces

static float3 pkWood(float3 p, float3 n) {
    float along, across;
    if (abs(n.y) > 0.5)      { along = p.z; across = p.x; }   // floor and ceiling boards run front to back
    else if (abs(n.x) > 0.5) { along = p.z; across = p.y; }
    else                     { along = p.x; across = p.y; }
    const float w = 0.17;
    float id = floor(across / w);
    float f = fract(across / w);
    float tint = hash11(id * 7.13 + 3.0 + n.x * 5.0 + n.y * 11.0);
    float seam = smoothstep(0.0, 0.05, f) * smoothstep(1.0, 0.95, f);
    float joint = fract(along / 0.9 + tint * 3.0);
    seam *= smoothstep(0.0, 0.012, joint) * smoothstep(1.0, 0.988, joint);
    float grain = valueNoise(float2(along * 3.0 + tint * 20.0, across * 60.0));
    float3 base = mix(float3(0.15, 0.085, 0.045), float3(0.24, 0.15, 0.08), tint);
    base *= 0.75 + 0.4 * grain;
    return base * mix(0.3, 1.0, seam);
}

static float3 pkPlaster(float2 q) {
    float n = valueNoise(q * 60.0) * 0.6 + valueNoise(q * 190.0) * 0.4;
    return float3(0.23, 0.205, 0.175) * (0.75 + 0.4 * n);
}

// Half-drop damask, in cell units, mirrored left to right.
static float pkDamask(float2 q, float px) {
    const float cell = 0.36;
    float2 g = q / cell;
    float col = floor(g.x);
    g.y += 0.5 * glmod(col, 2.0);
    float2 c = fract(g) - 0.5;
    c.x = abs(c.x);
    float aa = 1.2 * px / cell;

    float body = length((c - float2(0.0, 0.03)) * float2(1.0, 0.55)) - 0.075;
    float d = abs(body) - 0.011;                                         // outline of the central bud
    d = min(d, length((c - float2(0.0, 0.02)) * float2(1.0, 0.7)) - 0.03); // its heart
    d = min(d, abs(length(c - float2(0.17, -0.12)) - 0.06) - 0.009);     // scrolls
    d = min(d, length(c - float2(0.17, -0.12)) - 0.016);
    d = min(d, pkSeg2(c, float2(0.0, -0.13), float2(0.12, -0.07)) - 0.008);  // stems
    d = min(d, pkSeg2(c, float2(0.0, 0.18), float2(0.0, 0.29)) - 0.007);
    d = min(d, length(c - float2(0.0, 0.31)) - 0.022);
    float2 k = abs(c - float2(0.5, 0.5));
    d = min(d, (k.x + k.y) - 0.06);                                      // diamonds at the corners
    float2 k2 = abs(c - float2(0.5, -0.5));
    d = min(d, (k2.x + k2.y) - 0.06);
    return 1.0 - smoothstep(-aa, aa, d);
}

// The wall's face at glass point q: paper, the torn edge, bare plaster.
static float3 pkFront(float2 q, float px, float3 E, constant LerpUniforms& u) {
    float3 P = float3(q, 0.0);
    float2 dq = q - PK_HC;
    float a = atan2(dq.y, dq.x);
    float r = length(dq);
    float paperR = pkPaperR(a);

    float3 paper = u.paper.rgb * u.paper.rgb;
    float3 motif = u.motif.rgb * u.motif.rgb;
    float ink = pkDamask(q, px);
    float stripe = 0.5 + 0.5 * sin(q.x * TWO_PI / 0.09);
    float age = valueNoise(q * 2.3 + 7.0) * 0.6 + valueNoise(q * 9.0) * 0.4;
    float3 alb = paper * (0.92 + 0.10 * stripe) * (0.8 + 0.35 * age);
    alb = mix(alb, motif * (0.85 + 0.3 * age), ink * 0.9);
    // Grubby round the hole, where it has been climbing in and out.
    alb *= 1.0 - 0.35 * smoothstep(0.25, 0.0, r - paperR);

    // The torn edge: a pale line of paper core, and the plaster underneath.
    float edge = r - paperR;
    float3 plaster = pkPlaster(q) * (0.6 + 0.4 * smoothstep(0.0, 0.05, pkHole(q)));
    plaster *= 0.55 + 0.45 * smoothstep(0.0, 0.025, -edge);   // under the paper's lip
    float core = 1.0 - smoothstep(0.0, 0.006 + px, abs(edge - 0.003));
    float onPaper = smoothstep(-px, px, edge);
    alb = mix(plaster, alb, onPaper);
    alb = mix(alb, float3(0.42, 0.40, 0.35), core * 0.7);

    // Lit by the lamp in your room; the gold ink catches it as you move.
    float3 L = PK_RLAMP - P;
    float dist = length(L);
    L /= dist;
    float3 N = float3(0.0, 0.0, -1.0);
    float3 V = normalize(E - P);
    float diff = max(dot(N, L), 0.0) * 2.2 / (1.0 + 0.06 * dist * dist);
    float spec = pow(max(dot(N, normalize(L + V)), 0.0), 36.0) * ink * onPaper;
    float3 col = alb * (0.35 + diff) + motif * spec * 1.4;
    return col;
}

static float3 pkEyeColor(float3 p, float3 n, float3 rd, thread const PkState& S, constant LerpUniforms& u) {
    float side = pkLocal(S, p).x > 0.0 ? 1.0 : -1.0;
    float3 ec = S.head + side * 0.13 * S.R + 0.04 * S.U - 0.215 * S.B;
    float3 en = normalize(p - ec);
    float3 g = normalize(S.gaze - ec);
    float ang = acos(clamp(dot(en, g), -1.0, 1.0));
    float3 glow = u.eyes.rgb * u.eyes.rgb;
    float iris = 1.0 - smoothstep(0.58, 0.64, ang);
    float pupil = 1.0 - smoothstep(S.pupil - 0.03, S.pupil + 0.02, ang);
    // Rays in the iris: fibres round the pupil.
    float3 tg = normalize(cross(g, S.U));
    float3 bg = cross(g, tg);
    float fib = 0.75 + 0.25 * sin(18.0 * atan2(dot(en, bg), dot(en, tg)));
    float3 col = float3(0.035, 0.032, 0.04);
    col = mix(col, glow * (0.35 + 0.65 * smoothstep(0.62, 0.2, ang)) * fib, iris);
    col = mix(col, float3(0.0), pupil);
    // Catchlights: the room's lamp, the lantern.
    float3 refl = reflect(rd, n);
    col += 1.6 * pow(max(dot(refl, normalize(PK_RLAMP - p)), 0.0), 120.0);
    col += 0.8 * S.lampI * float3(1.0, 0.7, 0.35) * pow(max(dot(refl, normalize(S.lamp - p)), 0.0), 80.0);
    return col;
}

static float3 pkSignColor(float3 p) {
    float3 b = pkSignLocal(p);
    float3 wood = float3(0.30, 0.19, 0.10) * (0.8 + 0.3 * valueNoise(float2(b.x * 6.0, b.y * 90.0)));
    if (b.z < 0.004) return wood * 0.7;   // the post and the board's back and edges
    float2 q = b.xy;
    // "HI", painted, and a heart.
    float d = pkSeg2(q, float2(-0.105, -0.05), float2(-0.105, 0.05));
    d = min(d, pkSeg2(q, float2(-0.055, -0.05), float2(-0.055, 0.05)));
    d = min(d, pkSeg2(q, float2(-0.105, 0.0), float2(-0.055, 0.0)));
    d = min(d, pkSeg2(q, float2(-0.012, -0.05), float2(-0.012, 0.05)));
    d -= 0.0075;
    float2 h = q - float2(0.075, 0.004);
    float heart = length(float2(abs(h.x) - 0.017, h.y - 0.008)) - 0.021;
    float2 hq = rotate(h - float2(0.0, -0.008), 0.25 * PI);
    heart = min(heart, max(abs(hq.x), abs(hq.y)) - 0.021);
    float3 col = mix(wood, float3(0.80, 0.74, 0.60), 1.0 - smoothstep(0.0, 0.003, d));
    col = mix(col, float3(0.62, 0.10, 0.10), 1.0 - smoothstep(0.0, 0.003, heart));
    return col;
}

static float3 pkShade(float3 p, float3 rd, float mat, thread const PkState& S, constant LerpUniforms& u) {
    float3 n = pkNormal(p, S);
    float3 fur = u.fur.rgb * u.fur.rgb;
    float3 alb;
    float wrap = 0.0;
    if (mat == PK_M_WOOD) alb = pkWood(p, n);
    else if (mat == PK_M_PLASTER) alb = pkPlaster(p.xy + p.z);
    else if (mat == PK_M_FUR || mat == PK_M_LID) {
        float3 l = pkLocal(S, p);
        float fuzz = valueNoise(l.xy * 55.0 + l.z * 31.0);
        alb = fur * (0.82 + 0.3 * fuzz);
        // A paler bib and paws.
        float belly = smoothstep(0.1, 0.7, -dot(n, float3(0.0, 0.0, 1.0))) * smoothstep(-0.25, -0.5, l.y);
        alb = mix(alb, mix(fur, float3(0.85, 0.8, 0.72), 0.45), belly * 0.6);
        if (mat == PK_M_LID) alb *= 0.8;
        wrap = 0.45;
    }
    else if (mat == PK_M_MUZZLE) {
        float3 l = pkLocal(S, p);
        alb = mix(fur, float3(0.85, 0.80, 0.74), 0.55);
        float mouth = abs(l.y + 0.135 - 2.6 * l.x * l.x);
        float m = (1.0 - smoothstep(0.004, 0.009, mouth)) * step(abs(l.x), 0.06);
        m = max(m, (1.0 - smoothstep(0.003, 0.007, abs(l.x))) * step(-0.135, l.y) * step(l.y, -0.09));
        alb *= 1.0 - 0.75 * m;
        wrap = 0.45;
    }
    else if (mat == PK_M_NOSE) alb = float3(0.28, 0.09, 0.11);
    else if (mat == PK_M_EARIN) { alb = float3(0.42, 0.20, 0.22); wrap = 0.6; }
    else if (mat == PK_M_IRON) alb = float3(0.05, 0.045, 0.04);
    else if (mat == PK_M_SIGN) alb = pkSignColor(p);
    else alb = float3(0.0);

    if (mat == PK_M_GLASS) return float3(1.0, 0.68, 0.32) * 2.6 * S.lampI;
    if (mat == PK_M_EYE) return pkEyeColor(p, n, rd, S, u);

    float3 col = float3(0.0);
    float ao = pkAO(p, n, S);

    // The lantern.
    float3 L = S.lamp - p;
    float dist = length(L);
    L /= dist;
    float ndl = dot(n, L);
    float diff = wrap > 0.0 ? pow(clamp((ndl + wrap) / (1.0 + wrap), 0.0, 1.0), 1.5) : max(ndl, 0.0);
    float3 lampCol = float3(1.0, 0.62, 0.28) * S.lampI * 2.4 / (1.0 + 5.0 * dist * dist);
    float sh = diff > 0.0 ? pkShadow(p + n * 0.01, L, dist - 0.1, S) : 0.0;
    col += alb * lampCol * diff * sh;

    // Your room's light, through the hole only.
    float3 Lr = normalize(PK_RLAMP - p);
    float tz = -p.z / Lr.z;
    float through = 1.0 - smoothstep(-0.02, 0.02, pkHole(p.xy + Lr.xy * tz));
    float ndr = dot(n, Lr);
    float diffR = wrap > 0.0 ? pow(clamp((ndr + wrap) / (1.0 + wrap), 0.0, 1.0), 1.5) : max(ndr, 0.0);
    if (through * diffR > 0.0) {
        float shR = pkShadow(p + n * 0.01, Lr, tz, S);
        col += alb * float3(0.62, 0.70, 0.85) * 0.55 * diffR * through * shR;
    }

    // Faint bounce, warmer near the lantern.
    col += alb * (0.025 + 0.06 * S.lampI / (1.0 + 4.0 * dist * dist)) * ao;

    // Fur catches the lantern at its edges.
    if (wrap > 0.0) {
        float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
        col += fur * lampCol * rim * smoothstep(-0.3, 0.4, ndl) * 0.8;
    }
    if (mat == PK_M_NOSE) {
        float3 refl = reflect(rd, n);
        col += 0.25 * pow(max(dot(refl, Lr), 0.0), 40.0);
    }
    col *= mix(1.0, ao, 0.8);
    return col;
}

// ---------------------------------------------------------------- main

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float px = 2.0 / min(u.resolution.x, u.resolution.y);

    float3 ro = float3(0.0, 0.0, -PK_F);
    float3 rd = lerpViewerRay(u, u.parallax, uv, PK_F,
                              float3(1.0, 0.0, 0.0), float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0), ro);
    rd.z = max(rd.z, 1e-3);
    float3 E = ro;   // the eye this frame is drawn from

    // Every ray crosses the glass at its own pixel: uv. Off the hole, that is
    // the wall's face.
    float hole = pkHole(uv);
    float edge = smoothstep(-px, px, hole);
    float3 col = float3(0.0);
    if (edge > 0.0) col = pkFront(uv, px, E, u);

    if (edge < 1.0) {
        PkState S = pkBehave(u, E);
        float t0 = max(-ro.z / rd.z, 0.0);
        float t = t0;
        float mat = PK_M_WOOD;
        for (int i = 0; i < 110; i++) {
            float2 h = pkMap(ro + rd * t, S);
            mat = h.y;
            if (h.x < 0.0005 * t) break;
            t += 0.85 * h.x;
            if (t > t0 + 4.0) break;
        }
        float3 inside = pkShade(ro + rd * t, rd, mat, S, u);
        col = mix(inside, col, edge);
    }

    col = 1.0 - exp(-1.15 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}

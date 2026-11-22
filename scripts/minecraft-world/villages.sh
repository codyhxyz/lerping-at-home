#!/bin/zsh
# Lists every village the game places within a distance of the origin for a
# seed, by asking the game's own structure placement (Driver.java's
# `lerping villages`), without generating any terrain. Used to choose where
# the shared world is centred.
#
#   MINECRAFT_EULA=true scripts/minecraft-world/villages.sh JAR OUT.json [--seed SEED] [--range 6000]
#
# OUT.json is a list, nearest first, of
#   {type, x, z, distance, bbox: [x0, y0, z0, x1, y1, z1], pieces, houses,
#    zombie, templates: {template id: count}}
# where x, z is the block `locate` would print (the start chunk's corner),
# houses counts the jigsaw pieces from a village's houses pools, and zombie
# is true for the game's abandoned (zombie) variant. stdout gets one line per
# village. The server's world is scratch and is thrown away.
set -u
setopt pipefail extendedglob
die() { print -u2 -- "minecraft-world villages: $*"; exit 1 }
say() { print -u2 -- "minecraft-world villages: $*" }

(( $# >= 2 )) || die "usage: villages.sh JAR OUT.json [--seed SEED] [--range BLOCKS]"
HERE=${0:A:h}
ROOT=${HERE:h:h}
JAR=${1:A}; OUT=${2:A}; shift 2
SEED=Lerping@Home; RANGE=6000
while (( $# )); do
  case $1 in
    --seed) (( $# >= 2 )) || die "--seed needs a value"; SEED=$2; shift 2 ;;
    --range) (( $# >= 2 )) || die "--range needs a value"; RANGE=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $RANGE == <1-> ]] || die "--range must be a whole number of blocks (got $RANGE)"
[[ -n $SEED && $SEED != *[[:cntrl:]]* ]] || die "--seed must be non-empty printable text"
[[ $OUT == "$HOME/Library/Application Support/minecraft"(|/*) ]] && die "refusing to write inside the launcher's folder ($OUT)"

source "$HERE/server.zsh"

send "lerping villages -$RANGE -$RANGE $RANGE $RANGE"
await 'lerping-villages: (done|FAILED)|Exception' 1800
[[ $MATCH == *'lerping-villages: done'* ]] || fail "listing villages failed: $MATCH"
say "${MATCH##*lerping-villages: }"
FOUND=$(print -r -- "$SEG" | sed -n 's/.*lerping-village: //p')
print -r -- "$SEG" | /usr/bin/grep 'lerping-village' > "${OUT:r}.log"
server_stop
OK=1

print -r -- "$FOUND" | python3 -I -c '
import collections, json, math, re, sys
out, rng, seed_text, seed, version = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]
vs = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    f = line.split(" ", 10)
    if len(f) != 11:
        sys.exit(f"cannot read the village line: {line!r}")
    typ, cx, cz = f[0], int(f[1]), int(f[2])
    bbox = [int(v) for v in f[3:9]]
    pieces = int(f[9])
    tmpl = collections.Counter(re.findall(r"minecraft:village/[a-z0-9_/]+", f[10]))
    x, z = cx * 16, cz * 16
    d = math.hypot(x, z)
    if d > rng:
        continue
    houses = sum(n for t, n in tmpl.items() if "/houses/" in t)
    vs.append({"type": typ, "x": x, "z": z, "distance": round(d), "bbox": bbox, "pieces": pieces,
               "houses": houses, "zombie": any("/zombie/" in t for t in tmpl), "templates": dict(sorted(tmpl.items()))})
vs.sort(key=lambda v: v["distance"])
json.dump({"seed": seed, "seed_text": seed_text, "version": version, "range": rng, "villages": vs}, open(out, "w"), indent=1)
for v in vs:
    print(f"{v["type"]:28s} {v["x"]:6d} {v["z"]:6d} {v["distance"]:5d}  houses {v["houses"]:2d}  pieces {v["pieces"]:3d}" + ("  zombie" if v["zombie"] else ""))
print(f"{len(vs)} villages within {rng} blocks", file=sys.stderr)
' "$OUT" $RANGE "$SEED" $RESOLVED_SEED "$SERVER_VERSION" || die "cannot write $OUT"

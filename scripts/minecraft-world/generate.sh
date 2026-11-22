#!/bin/zsh
# Generates a real Minecraft world from a fixed seed with the game's own code:
# the dedicated server inside the installed client jar, run headless and
# offline. The same seed and game version give the same blocks on every run,
# which is what lets one shared world look identical everywhere.
#
#   MINECRAFT_EULA=true scripts/minecraft-world/generate.sh JAR OUT_SAVE_DIR \
#       [--seed SEED] [--structure minecraft:village_plains] [--at X,Z] [--radius-chunks 32]
#
# JAR           the client jar, with its version JSON beside it
#               (~/Library/Application Support/minecraft/versions/V/V.jar)
# OUT_SAVE_DIR  where the finished save folder goes (level.dat, dimensions/...).
#               Must not exist yet.
# --seed        the level seed, as typed into the game: a number is used as is,
#               any other text is hashed by the game. Default Lerping@Home.
# --structure   a structure id or #tag for `locate structure`. The square is
#               centred on the instance nearest to --at, or to block 0,0.
# --at X,Z      a block position. Alone, the square is centred on it exactly;
#               with --structure, on the structure nearest to it. Without
#               either option the square is centred on the plains village
#               nearest 0,0.
# --radius-chunks  half-size of the square, in chunks; (2R+1)^2 chunks are
#               generated to full status.
#
# The server runs in a scratch folder under build/minecraft-world/work/ (see
# server.zsh): bound only to 127.0.0.1, offline, every Mojang web host pointed
# at a closed loopback port, and ticking frozen before the first tick so the
# saved blocks are worldgen only. Driver.java beside this script wraps the
# server's Main and generates the chunks in a fixed order, which is what makes
# two runs give the same blocks (see its header).
#
# Progress goes to stderr. stdout gets exactly one line, a JSON object (also
# saved as OUT_SAVE_DIR/lerping-generate.json): the centre and how it was
# chosen, the square, the seed as the game resolved it, the game version and
# the seconds taken.
set -u
setopt pipefail extendedglob
die() { print -u2 -- "minecraft-world: $*"; exit 1 }
say() { print -u2 -- "minecraft-world: $*" }

(( $# >= 2 )) || die "usage: generate.sh JAR OUT_SAVE_DIR [--seed SEED] [--structure ID] [--at X,Z] [--radius-chunks N]"
HERE=${0:A:h}
ROOT=${HERE:h:h}
JAR=${1:A}; OUT=${2:A}; shift 2
SEED=Lerping@Home; STRUCTURE=; AT=; RADIUS=32
while (( $# )); do
  case $1 in
    --seed) (( $# >= 2 )) || die "--seed needs a value"; SEED=$2; shift 2 ;;
    --structure) (( $# >= 2 )) || die "--structure needs a value"; STRUCTURE=$2; shift 2 ;;
    --at) (( $# >= 2 )) || die "--at needs a value"; AT=$2; shift 2 ;;
    --radius-chunks) (( $# >= 2 )) || die "--radius-chunks needs a value"; RADIUS=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -z $AT && -z $STRUCTURE ]] && STRUCTURE=minecraft:village_plains
[[ $RADIUS == <0-> ]] && (( RADIUS <= 200 )) || die "--radius-chunks must be a whole number from 0 to 200 (got $RADIUS)"
[[ -z $STRUCTURE || $STRUCTURE == (\#|)[a-z0-9_.-]##:[a-z0-9_./-]## ]] || die "--structure must be a namespaced id like minecraft:village_plains (got $STRUCTURE)"
if [[ -n $AT ]]; then
  [[ $AT =~ '^(-?[0-9]+),(-?[0-9]+)$' ]] || die "--at must be X,Z in whole blocks, e.g. -928,656 (got $AT)"
  AX=$match[1]; AZ=$match[2]
else
  AX=0; AZ=0
fi
[[ -n $SEED && $SEED != *[[:cntrl:]]* ]] || die "--seed must be non-empty printable text"
[[ -e $OUT ]] && die "$OUT already exists; remove it or pick another folder"
[[ $OUT == "$HOME/Library/Application Support/minecraft"(|/*) ]] && die "refusing to write inside the launcher's folder ($OUT)"

source "$HERE/server.zsh"

if [[ -n $STRUCTURE ]]; then
  # Whatever locate answers lands before the marker; anything but a position
  # is the game's own error message.
  send "execute positioned $AX 0 $AZ run locate structure $STRUCTURE"
  mark 600
  MATCH=$(print -r -- "$SEG" | /usr/bin/grep -m1 'The nearest .* is at \[')
  [[ $MATCH =~ 'is at \[(-?[0-9]+), [^,]+, (-?[0-9]+)\] \(([0-9]+) blocks away\)' ]] ||
    fail "locate found no $STRUCTURE: $(print -r -- "$SEG" | sed '$d' | sed 's/^\[[^]]*\] \[[^]]*\]: //' | tail -3)"
  SX=$match[1]; SZ=$match[2]
  CENTRED=structure
  say "nearest $STRUCTURE to $AX,$AZ is at x=$SX z=$SZ ($match[3] blocks away); centring on it"
else
  SX=$AX; SZ=$AZ
  CENTRED=position
  say "centring on the given position x=$SX z=$SZ (no --structure, so not snapped)"
fi

# The square, in chunks. >> 4 floors negative coordinates as the game does.
(( CX = SX >> 4, CZ = SZ >> 4 ))
(( X0 = CX - RADIUS, X1 = CX + RADIUS, Z0 = CZ - RADIUS, Z1 = CZ + RADIUS ))
(( TOTAL = (2 * RADIUS + 1) ** 2 ))
say "generating chunks x $X0..$X1, z $Z0..$Z1 ($TOTAL chunks)"
[[ -t 2 ]] && EOL='\r' || EOL='\n'
send "lerping generate $X0 $Z0 $X1 $Z1"
while true; do
  await 'lerping-generate: |Exception|/ERROR\]' ${GENERATE_TIMEOUT:-1800}
  [[ $MATCH == *'lerping-generate: '(carvers|features)* ]] && { printf "minecraft-world: %s$EOL" "${MATCH##*lerping-generate: }" >&2; continue }
  [[ $MATCH == *'lerping-generate: done '* ]] && break
  fail "generation failed: $MATCH"
done
print -u2 -- "minecraft-world: ${MATCH##*lerping-generate: }"
[[ $MATCH == *"done $TOTAL full chunks"* ]] || fail "expected $TOTAL full chunks: $MATCH"

server_stop

rm -rf "$WORK/world/datapacks/lerping-still"
mkdir -p "${OUT:h}" || fail "cannot make ${OUT:h}"
mv "$WORK/world" "$OUT" || fail "cannot move the save to $OUT"
cp "$LOG" "$OUT/lerping-generate.log"
OK=1
SECONDS_TAKEN=$(( EPOCHREALTIME - T0 ))
# The result line also goes into the save as lerping-generate.json, so the
# bake can read where the structure is without parsing logs.
RESULT=$(python3 -I -c '
import json, math, sys
a = sys.argv[1:]
at = None if a[14] == "" else [int(v) for v in a[14].split(",")]
print(json.dumps({
  "structure": a[0] or None, "x": int(a[1]), "z": int(a[2]),
  "distance_from_origin": round(math.hypot(int(a[1]), int(a[2]))),
  "centred_on": a[3], "at": at,
  "chunks": {"x0": int(a[4]), "z0": int(a[5]), "x1": int(a[6]), "z1": int(a[7]), "count": int(a[8])},
  "blocks": {"x0": int(a[4]) * 16, "z0": int(a[5]) * 16, "x1": int(a[6]) * 16 + 15, "z1": int(a[7]) * 16 + 15},
  "seed": int(a[9]), "seed_text": a[10], "version": a[11], "seconds": round(float(a[12]), 1), "save": a[13]}))
' "$STRUCTURE" $SX $SZ $CENTRED $X0 $Z0 $X1 $Z1 $TOTAL $RESOLVED_SEED "$SEED" "$SERVER_VERSION" $SECONDS_TAKEN "$OUT" "$AT") || die "cannot format the result"
print -r -- "$RESULT" > "$OUT/lerping-generate.json" || die "cannot write $OUT/lerping-generate.json"
print -r -- "$RESULT"

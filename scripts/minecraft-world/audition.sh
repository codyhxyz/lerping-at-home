#!/bin/zsh
# Generates small worlds to compare candidates by eye before one is generated
# in full: either several seeds, or several places in one seed.
#
#   MINECRAFT_EULA=true scripts/minecraft-world/audition.sh JAR SEED [SEED...] \
#       [--structure minecraft:village_plains] [--radius-chunks 8]
#   MINECRAFT_EULA=true scripts/minecraft-world/audition.sh JAR --places FILE \
#       [--seed SEED] [--structure ID] [--radius-chunks 8]
#
# Seeds go to build/minecraft-world/auditions/<seed>/. Places go to
# build/minecraft-world/auditions/<seed>/<name>/, where FILE has one place per
# line, "NAME X,Z" (blank lines and # comments ignored), each generated with
# --at X,Z (snapped to the nearest --structure when one is given). In names,
# characters other than letters, digits and @._- become _. A folder that
# already exists is not generated again. Each result's JSON line from
# generate.sh is printed on stdout. One that fails is reported and the rest
# still run; the exit status is 1 if any failed.
set -u
die() { print -u2 -- "minecraft-world audition: $*"; exit 1 }
HERE=${0:A:h}
ROOT=${HERE:h:h}
(( $# >= 2 )) || die "usage: audition.sh JAR SEED [SEED...] | JAR --places FILE [--seed SEED] [--structure ID] [--radius-chunks N]"
JAR=$1; shift
SEEDS=(); PLACES=; SEED=Lerping@Home; PASS=(--radius-chunks 8)
while (( $# )); do
  case $1 in
    --structure|--radius-chunks) (( $# >= 2 )) || die "$1 needs a value"; PASS+=($1 $2); shift 2 ;;
    --places) (( $# >= 2 )) || die "--places needs a file"; PLACES=$2; shift 2 ;;
    --seed) (( $# >= 2 )) || die "--seed needs a value"; SEED=$2; shift 2 ;;
    --*) die "unknown option: $1" ;;
    *) SEEDS+=("$1"); shift ;;
  esac
done
DIR=$ROOT/build/minecraft-world/auditions
safe() { print -r -- "${1//[^A-Za-z0-9@._-]/_}" }

# One job per line: output folder, then generate.sh's arguments.
JOBS=()
if [[ -n $PLACES ]]; then
  (( ${#SEEDS} == 0 )) || die "give seeds or --places, not both"
  [[ -f $PLACES ]] || die "no places file $PLACES"
  while IFS= read -r line; do
    line=${line%%\#*}
    [[ -z ${line//[[:space:]]/} ]] && continue
    parts=(${=line})
    (( ${#parts} == 2 )) || die "places line is not \"NAME X,Z\": $line"
    JOBS+=("$DIR/$(safe $SEED)/$(safe $parts[1])"$'\t'"--seed"$'\t'"$SEED"$'\t'"--at"$'\t'"$parts[2]")
  done < "$PLACES"
else
  (( ${#SEEDS} )) || die "no seeds given"
  for seed in $SEEDS; do JOBS+=("$DIR/$(safe $seed)"$'\t'"--seed"$'\t'"$seed"); done
fi
(( ${#JOBS} )) || die "nothing to generate"

FAILED=()
for job in $JOBS; do
  args=("${(@ps:\t:)job}")
  out=$args[1]; shift args
  if [[ -e $out ]]; then
    print -u2 -- "minecraft-world audition: $out exists, not generated again"
    [[ -f $out/lerping-generate.json ]] && cat "$out/lerping-generate.json"
    continue
  fi
  print -u2 -- "minecraft-world audition: -> $out"
  "$HERE/generate.sh" "$JAR" "$out" $args $PASS || FAILED+=("${out:t}")
done
if (( ${#FAILED} )); then
  print -u2 -- "minecraft-world audition: failed for ${#FAILED} of ${#JOBS}: ${(j:, :)FAILED}"
  exit 1
fi

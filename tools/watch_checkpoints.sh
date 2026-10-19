#!/bin/zsh
# Grades each new checkpoint of a long Create ML run as it lands (export + tools/grade), so the best one can ship
# even if the run is stopped early. Usage: tools/watch_checkpoints.sh <session name, e.g. cm-darknet>
set -u
cd "$(dirname "$0")/.."
name=$1 log=runs/createml/$1.log out=runs/createml/$1-grades.txt last=0
while true; do
  it=$(grep -o "checkpoint at iteration [0-9]*" $log | tail -1 | grep -o "[0-9]*$")
  if [[ -n "$it" && $it -gt $last ]]; then
    model=models/$name-$it.mlmodel
    if build/train_createml --export runs/createml/$name $model >>$out 2>&1; then
      for merge in 0.6 0.3; do
        echo "== $name iteration $it, merge $merge ($(date +%H:%M))" >>$out
        build/grade $model --merge $merge 2>&1 | grep -E "^detector:|^tau 0.8|detector 0.8 gallery (0.78|1.01)|^boxes" >>$out
      done
    fi
    last=$it
  fi
  grep -qE "wrote|training failed" $log && [[ $last -ge $(grep -o "checkpoint at iteration [0-9]*" $log | tail -1 | grep -o "[0-9]*$") ]] && break
  sleep 120
done
echo "== done ($(date +%H:%M))" >>$out

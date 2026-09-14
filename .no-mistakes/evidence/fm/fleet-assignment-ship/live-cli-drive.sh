#!/usr/bin/env bash
# Live CLI drive of bin/fm-fleet.sh in an isolated temp fleet root. Endpoint hooks
# replace real harness launches; manager liveness uses a codex-named holder process.
W=$1; T=$(mktemp -d); export FM_FLEET_ROOT=$T/fleet; F=$W/bin/fm-fleet.sh
REG=$T/fleet/fleet.json; R() { python3 "$W/bin/fm-fleet-registry.py" "$REG" "$@"; }
PIDS=(); trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"' EXIT
lock() { mkdir -p "$1/state"; bash -c 'exec -a /opt/homebrew/bin/codex sleep 300' & PIDS+=($!); echo $! > "$1/state/.lock"; echo test:test > "$1/state/.fleet-herdr-target"; }
unlock() { kill "$(cat "$1/state/.lock")"; sleep 0.3; rm -f "$1/state/.lock"; }
sum() { shasum "$REG" | cut -c1-12; }
step() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "${*/#$W\//}"; "$@"; echo "[exit $?]"; }
HOOK=$T/hook.sh; printf '#!/usr/bin/env bash\necho "hook $3 $2" >&2\n' > "$HOOK"; chmod +x "$HOOK"
export FM_FLEET_TRANSFER_STOP_HOOK=$HOOK FM_FLEET_TRANSFER_MANAGER_START_HOOK=$HOOK FM_FLEET_TRANSFER_SECONDMATE_START_HOOK=$HOOK FM_FLEET_TRANSFER_ROLLBACK_START_HOOK=$HOOK
$F init >/dev/null
for n in 1 2 3; do $F manager register --id manager-$n --home $T/fleet/manager-$n >/dev/null; lock $T/fleet/manager-$n; done
$F owner register --secondmate harness --home $T/fleet/secondmates/harness --projects AutoDev,dotcodex --domains harness
$F owner register --secondmate racer --home $T/fleet/secondmates/racer --projects race-app --domains race

step "S1 unknown project fails closed into unassigned triage"
run $F route --project mystery --issue MIX-1
step "S2 new AutoDev issue routes to an automatically chosen manager (no manager input)"
run $F route --project AutoDev --issue MIX-2
run $F route --project dotcodex --issue MIX-3
mh=$T/fleet/manager-1; mkdir -p $mh/data $T/fleet/secondmates/harness
printf '%s\n' '# SecondMates' "- harness - S (home: $T/fleet/secondmates/harness; scope: s; projects: p; added 2026-09-13)" > $mh/data/secondmates.md
printf 'kind=secondmate\nhome=%s\nwindow=fake\n' "$T/fleet/secondmates/harness" > $mh/state/harness.meta
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$mh" > $T/fleet/secondmates/harness/.fm-secondmate-parent

step "S3 in-flight transfer: route and healthy sticky assign both report transfer-in-progress, exit 4, no registry write"
R transfer-reserve --secondmate harness --manager manager-2 --transaction live-tx; before=$(sum)
run $F route --project AutoDev --issue MIX-4
run $F assign --secondmate harness
echo "fleet.json checksum before=$before after=$(sum)"
python3 - "$REG" <<'P'
import json,sys; r=json.load(open(sys.argv[1])); r["transfers"]=[]; json.dump(r,open(sys.argv[1],"w"))
P

step "S4 transfer reserved during health collection (barrier via python3 shim): route exits 4, no assignment/triage"
SH=$T/shim; mkdir -p $SH; REAL=$(command -v python3)
cat > $SH/python3 <<S
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in "-:$T/fleet/.health."*) [ -e $SH/done ] || { : > $SH/done; "$REAL" "$W/bin/fm-fleet-registry.py" "$REG" transfer-reserve --secondmate racer --manager manager-3 --transaction race-racer >/dev/null; echo "[barrier] transfer race-racer reserved during health collection" >&2; } ;; esac
exec "$REAL" "\$@"
S
chmod +x $SH/python3
PATH=$SH:$PATH run $F route --project race-app --issue MIX-9
python3 - "$REG" <<'P'
import json,sys; r=json.load(open(sys.argv[1]))
print("racer assignments:", [a for a in r["assignments"] if a["secondmate"]=="racer"], "| race triage:", [u for u in r["unassigned"] if "race" in u["key"]])
P

step "S5 controlled failover: manager-1 dies, recover moves harness to another manager, route follows"
unlock $mh
run $F recover --secondmate harness
run $F route --project AutoDev --issue MIX-5
python3 - "$REG" <<'P'
import json,sys; r=json.load(open(sys.argv[1]))
print("active harness rows:", [(a["manager"],a["generation"]) for a in r["assignments"] if a["secondmate"]=="harness" and a.get("state")=="active"], "| in-flight transfers:", r["transfers"])
P
run $F status

#!/usr/bin/env bash
# Sichert den Terraform-State SOPS-verschluesselt ins Repo.
#
# Warum ueberhaupt: Der State liegt lokal und ist gitignored. Bei
# Festplattenverlust muesste jede Ressource einzeln importiert werden -
# machbar, aber stundenlang und fehleranfaellig. Verschluesselt im Repo ist er
# versioniert, ueberlebt die Maschine und ist trotzdem nur mit dem age-Key
# lesbar.
#
# Das ist ein Backup, kein Remote-Backend: es gibt kein Locking. Solange nur
# eine Person applyt, ist das kein Problem.
#
# Nach jedem terraform apply ausfuehren.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$REPO/terraform/terraform.tfstate"
OUT="$REPO/terraform/state-backup.sops.json"
KEY="$REPO/age.key"

[ -f "$STATE" ] || { echo "FEHLER: $STATE nicht gefunden." >&2; exit 2; }
[ -f "$KEY" ]   || { echo "FEHLER: $KEY nicht gefunden - ohne den age-Key geht nichts." >&2; exit 2; }

export SOPS_AGE_KEY_FILE="$KEY"

# SOPS gleicht seine creation_rules gegen den EINGABEpfad ab, nicht gegen den
# Ausgabepfad. Deshalb erst auf den Zielnamen kopieren und dann in-place
# verschluesseln - sonst greift die Regel fuer *.sops.json nicht.
cp "$STATE" "$OUT"
sops --encrypt --in-place "$OUT"

# Round-Trip pruefen. Ein Backup, das sich nicht zurueckholen laesst, ist
# schlimmer als keines: es erzeugt falsche Sicherheit.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sops --decrypt --input-type json --output-type json "$OUT" >"$tmp"

# Semantisch vergleichen, nicht byteweise: SOPS formatiert das JSON beim
# Entschluesseln neu (Einrueckung, Schluesselreihenfolge). Fuer Terraform ist
# das egal - es parst JSON. Ein Byte-Vergleich wuerde hier immer scheitern und
# ein korrektes Backup faelschlich verwerfen.
if ! diff -q <(jq -S . "$STATE") <(jq -S . "$tmp") >/dev/null; then
  echo "FEHLER: entschluesselter State weicht inhaltlich vom Original ab. Backup verworfen." >&2
  rm -f "$OUT"
  exit 1
fi

# Zusaetzlich das pruefen, worauf es bei einem State wirklich ankommt.
for field in serial lineage terraform_version; do
  a="$(jq -r ".$field // empty" "$STATE")"
  b="$(jq -r ".$field // empty" "$tmp")"
  if [ "$a" != "$b" ]; then
    echo "FEHLER: $field weicht ab ($a vs $b). Backup verworfen." >&2
    rm -f "$OUT"
    exit 1
  fi
done

# Gegenprobe, dass wirklich verschluesselt wurde und nicht versehentlich
# Klartext im Repo landet.
if ! grep -q 'ENC\[' "$OUT"; then
  echo "FEHLER: keine ENC[-Marker in $OUT - offenbar unverschluesselt." >&2
  rm -f "$OUT"
  exit 1
fi

echo "OK: $(basename "$OUT") geschrieben, Round-Trip identisch ($(wc -c <"$STATE" | tr -d ' ') Bytes Original)."
echo "    Nicht vergessen: committen und pushen."

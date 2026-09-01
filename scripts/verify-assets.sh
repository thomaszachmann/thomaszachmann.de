#!/usr/bin/env bash
# Prüft, dass jede lokal referenzierte Datei in den HTML-Seiten wirklich existiert.
# Erfasst HTML-Attribute (href, src) UND CSS-url(...) aus inline <style>-Blöcken —
# die self-hosted Fonts stehen nur dort und wären sonst unsichtbar.
# Externe Referenzen (http, mailto, tel, data:, Anker) werden übersprungen.
set -euo pipefail

ROOT="${1:-sites/thomaszachmann/public}"

if [ ! -d "$ROOT" ]; then
  echo "FEHLER: Verzeichnis '$ROOT' existiert nicht." >&2
  exit 2
fi

missing="$(mktemp)"
trap 'rm -f "$missing"' EXIT

html_count=0
while IFS= read -r -d '' html; do
  html_count=$((html_count + 1))
  while IFS= read -r ref; do
    case "$ref" in
      ''|'#'*|http://*|https://*|//*|data:*|mailto:*|tel:*) continue ;;
    esac
    ref="${ref%%#*}"      # Fragment abschneiden
    ref="${ref%%\?*}"     # Query abschneiden
    [ -n "$ref" ] || continue
    case "$ref" in
      /*) target="$ROOT/${ref#/}" ;;                 # wurzelrelativ
      *)  target="$(dirname "$html")/$ref" ;;        # dokumentrelativ
    esac
    # Dieselbe Reihenfolge wie try_files in der nginx.conf: $uri, $uri.html,
    # $uri/. Ohne den mittleren Schritt meldet der Pruefer endungslose Links
    # wie /buch als fehlend, obwohl buch.html ausgeliefert wird. Der Test
    # bleibt scharf: /buch besteht ihn nur, weil buch.html existiert.
    if [ ! -e "$target" ] && [ ! -e "$target.html" ] && [ ! -e "$target/index.html" ]; then
      printf '%s\t%s\n' "${html#./}" "$ref" >>"$missing"
    fi
  done < <(
    {
      # HTML-Attribute
      grep -oE '(href|src)="[^"]*"' "$html" | sed -E 's/^(href|src)="//; s/"$//'
      # CSS url(...) — auch aus inline <style>-Bloecken. Die self-hosted Fonts
      # stehen genau hier und wuerden sonst uebersehen.
      grep -oE 'url\([^)]*\)' "$html" | sed -E 's/^url\(//; s/\)$//' | tr -d "\"'"
    } | sort -u
  )
done < <(find "$ROOT" -name '*.html' -print0)

if [ -s "$missing" ]; then
  echo "Fehlende referenzierte Dateien:" >&2
  sort -u "$missing" | while IFS="$(printf '\t')" read -r f r; do
    echo "  $r   (referenziert in $f)" >&2
  done
  exit 1
fi

echo "OK: alle lokalen Referenzen in $html_count HTML-Datei(en) aufgelöst."

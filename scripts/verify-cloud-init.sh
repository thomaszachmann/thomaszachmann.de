#!/usr/bin/env bash
# Rendert cloud-init.yaml.tftpl mit Dummy-Werten und prueft das Ergebnis.
#
# Warum das noetig ist: terraform validate prueft die HCL-Syntax, aber es
# rendert templatefile() nie. Ein unescaptes Dollar-Zeichen im Template -- auch
# in einer Kommentarzeile, denn der Parser kennt keine YAML-Kommentare -- faellt
# damit erst bei terraform plan auf. Ein Einrueckungsfehler sogar erst, wenn der
# Server bootet und cloud-init die Datei stillschweigend verwirft.
#
# Braucht keine Credentials.
set -euo pipefail

TFDIR="${1:-terraform}"
TPL="cloud-init.yaml.tftpl"

[ -f "$TFDIR/$TPL" ] || { echo "FEHLER: $TFDIR/$TPL nicht gefunden." >&2; exit 2; }
[ -d "$TFDIR/.terraform" ] || { echo "FEHLER: erst 'terraform -chdir=$TFDIR init' ausfuehren." >&2; exit 2; }

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

# terraform console wertet zeilenweise aus: der Ausdruck MUSS einzeilig sein,
# sonst bricht er mit "Expected the start of an expression" ab.
EXPR="templatefile(\"$TPL\", { node_user = \"tz\", ssh_pubkey = \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test@example\", k3s_version = \"v1.36.3+k3s1\", node_name = \"tz-web-01\", tls_san = \"203.0.113.7\" })"

echo "$EXPR" | terraform -chdir="$TFDIR" console >"$rendered.raw" 2>"$rendered.err" || {
  echo "FEHLER: templatefile() konnte nicht gerendert werden:" >&2
  cat "$rendered.err" >&2
  rm -f "$rendered.raw" "$rendered.err"
  exit 1
}

# terraform console klammert mehrzeilige Strings in <<EOT ... EOT
sed '1d;$d' "$rendered.raw" >"$rendered"
rm -f "$rendered.raw" "$rendered.err"

head -1 "$rendered" | grep -q '^#cloud-config$' || {
  echo "FEHLER: erste Zeile ist nicht '#cloud-config'. cloud-init ignoriert die Datei dann komplett." >&2
  exit 1
}

# YAML-Strukturpruefung. macOS bringt Ruby mit Psych mit; PyYAML ist im
# System-Python nicht vorhanden.
ruby -ryaml -e '
  d = YAML.load_file(ARGV[0])
  fail "users fehlt"       unless d["users"] && d["users"][0]["name"] == "tz"
  fail "write_files fehlt" unless d["write_files"].size == 2
  k3s = d["runcmd"].find { |c| c.is_a?(String) && c.include?("get.k3s.io") }
  fail "k3s-Installationsbefehl fehlt" if k3s.nil?
  %w[--disable=traefik --secrets-encryption --write-kubeconfig-mode=0600
     --tls-san=203.0.113.7 --node-name=tz-web-01].each do |f|
    fail "k3s-Flag fehlt: #{f}" unless k3s.include?(f)
  end
  fail "Shell-Konstrukt $(seq ...) wurde zerstoert" unless k3s || d["runcmd"].any? { |c| c.to_s.include?("$(seq 1 60)") }
  sshd = d["write_files"].find { |w| w["path"].include?("sshd_config") }
  fail "sshd-Haertung fehlt" unless sshd["content"].include?("PasswordAuthentication no")
' "$rendered"

echo "OK: cloud-init rendert zu gueltigem YAML, alle k3s-Flags und die sshd-Haertung sind enthalten."

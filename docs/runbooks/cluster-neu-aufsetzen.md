# Cluster von Hand neu aufsetzen

Zwei Szenarien, die sich deutlich unterscheiden:

| | **A: Server neu bauen** | **B: Komplett bei Null** |
|---|---|---|
| Wann | Node kaputt, cloud-init geändert, DR-Übung | Hetzner-Projekt weg, State und age-Key verloren, Umzug |
| Primary IPs | bleiben | neu → DNS muss nachgezogen werden |
| Dauer | ~6 min | ~20 min plus DNS-Propagation |
| Getestet am | 2026-08-27, RTO 6 min | in Teilen, siehe unten |

Alle Kommandos aus dem Repo-Wurzelverzeichnis.

---

## Was du unbedingt brauchst

Ohne diese drei Dinge ist es kein Rebuild, sondern ein Neuaufbau von Hand:

1. **`age.key`** — der private age-Schlüssel. Ohne ihn sind alle
   SOPS-verschlüsselten Secrets im Repo unbrauchbar, und Flux kann
   `infra-configs` nicht entschlüsseln. **Das ist das einzige Artefakt, das
   `terraform apply` nicht wiederherstellen kann.** Gehört in den
   Passwortmanager.
2. **`.env`** mit `HCLOUD_TOKEN` und `CLOUDFLARE_API_TOKEN`. Neu erzeugbar,
   aber du brauchst Zugang zu beiden Konten.
3. **`terraform/terraform.tfvars`** — Zone-ID, Admin-IP, SSH-Key-Name. Auch neu
   schreibbar, siehe `terraform.tfvars.example`.

Der Terraform-State ist **nicht** in dieser Liste: `terraform/state-backup.sops.json`
liegt verschlüsselt im Repo und lässt sich mit `age.key` zurückholen. Und
selbst ohne ihn kommt man per `terraform import` weiter — nur langsam.

### Pre-Flight

Vor jedem Rebuild einmal durchgehen. Kostet 20 Sekunden und verhindert, dass du
mittendrin merkst, dass etwas fehlt.

```bash
ls -l age.key terraform/terraform.tfvars .env terraform/state-backup.sops.json
gh auth status
mise install && mise ls
git status --porcelain          # sollte leer sein
git fetch origin main && git status -sb   # lokal == origin/main
```

Der letzte Punkt ist wichtig: Flux zieht `origin/main`, nicht deinen lokalen
Stand. Was nicht gepusht ist, wird nicht ausgerollt.

---

# Szenario A: Server neu bauen

Die IPs bleiben, DNS wird nicht angefasst. Das ist der Weg, den die DR-Probe
gemessen hat.

## A1. Ausgangszustand festhalten

```bash
set -a; . .env; set +a
date '+%H:%M:%S'
mise exec -- terraform -chdir=terraform output -json | jq -r '.ipv4.value, .ipv6.value'
```

IP notieren. Am Ende vergleichst du sie — das ist der eigentliche Test.

## A2. Tunnel beenden und Server zerstören

```bash
pkill -f 'ssh -N .*6443'

mise exec -- terraform -chdir=terraform destroy -target=hcloud_server.web
```

Zerstört werden vier Dinge: der Server, das Firewall-Attachment und die beiden
AAAA-Records — letztere, weil sie auf `hcloud_server.web.ipv6_address`
verweisen. Die A-Records und **beide Primary IPs bleiben**.

Gegenprobe, dass der Anker gehalten hat:

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/primary_ips \
 | jq -r '.primary_ips[] | select(.name|startswith("tz-web")) | "\(.name) \(.ip) geschuetzt=\(.protection.delete)"'
```

Beide müssen mit `geschuetzt=true` auftauchen.

## A3. Neu bauen

```bash
mise exec -- terraform -chdir=terraform apply
```

**Wenn das fehlschlägt mit `error during placement (resource_unavailable)`:**
Hetzner hat gerade keine Maschine dieses Typs am Standort frei. Passierte in
der DR-Probe beim ersten Versuch. Eskalation in dieser Reihenfolge:

```bash
# 1. Einfach nochmal. Meist Minutensache.
mise exec -- terraform -chdir=terraform apply

# 2. Anderer Typ, SELBER Standort. Der IP-Anker haelt, kostet nur mehr Geld.
mise exec -- terraform -chdir=terraform apply -var="server_type=cx43"

# 3. Erst als letztes: anderer Standort. Dann sind neue Primary IPs noetig
#    und DNS muss nachgezogen werden -> effektiv Szenario B.
```

Grund: Eine Primary IP ist standortgebunden. Eine IP in `fsn1` lässt sich nicht
an einen Server in `nbg1` hängen.

Danach gegen die **API** prüfen, nicht gegen den State — der Output zeigt die
IP auch dann, wenn der Server gar nicht existiert:

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/servers \
 | jq -r '.servers[] | select(.name=="tz-web-01") | "\(.name) \(.server_type.name) \(.status) \(.public_net.ipv4.ip)"'
```

## A4. Auf cloud-init warten

Der Host-Key ist neu, der alte muss weg:

```bash
IP="$(mise exec -- terraform -chdir=terraform output -raw ipv4)"
ssh-keygen -R "$IP"

ssh -o StrictHostKeyChecking=accept-new -o ConnectionAttempts=90 tz@"$IP" \
  'sudo cloud-init status --wait; ls -l /var/lib/cloud/k3s-ready; sudo k3s kubectl get nodes'
```

`cloud-init status --wait` blockiert, bis fertig — man braucht keine
Warteschleife. Erwartet: `status: done`, die Marker-Datei existiert, Node
`Ready`. Dauerte gemessen 58 Sekunden.

Wenn `k3s-ready` fehlt, hat die Warteschleife im cloud-init (60 × 5 s)
aufgegeben:

```bash
ssh tz@"$IP" 'sudo tail -50 /var/log/cloud-init-output.log; sudo systemctl status k3s --no-pager'
```

## A5. Cluster-Zugriff

```bash
ssh tz@"$IP" 'sudo cat /etc/rancher/k3s/k3s.yaml' > kubeconfig
chmod 600 kubeconfig
```

Die kubeconfig zeigt bereits auf `127.0.0.1:6443` und passt damit zum Tunnel.
Port 6443 ist von aussen zu — das ist Absicht.

Tunnel in einem **eigenen Terminal** offen halten:

```bash
ssh -N -L 6443:127.0.0.1:6443 tz@"$IP"
```

Im Arbeitsterminal:

```bash
export KUBECONFIG="$PWD/kubeconfig"
mise exec -- kubectl get nodes
```

## A6. age-Schlüssel in den Cluster

Ohne diesen Schritt bleibt `infra-configs` für immer rot: Flux kann das
Cloudflare-Token nicht entschlüsseln, die ClusterIssuer werden nie fertig, und
es gibt kein Zertifikat.

```bash
mise exec -- kubectl create namespace flux-system
mise exec -- kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=age.key
```

Der Dateiname im Secret **muss** auf `.agekey` enden — Flux sucht genau danach.
Gegenprobe:

```bash
mise exec -- kubectl -n flux-system get secret sops-age -o jsonpath='{.data}' | jq 'keys'
```

## A7. Flux bootstrappen

```bash
export GITHUB_TOKEN="$(gh auth token)"
mise exec -- flux bootstrap github \
  --owner=thomaszachmann \
  --repository=thomaszachmann.de \
  --branch=main \
  --path=clusters/prod \
  --personal \
  --version=v2.9.4
```

Der Deploy-Key, den Flux anlegt, ist **read-only** — Default und genau richtig:
Der Cluster soll das Repo lesen, nicht schreiben. Prüfen:

```bash
gh api repos/thomaszachmann/thomaszachmann.de/keys --jq '.[] | "\(.title) read_only=\(.read_only)"'
```

Der Bootstrap committet zwei Dateien ins Repo. Danach:

```bash
git pull --rebase
```

## A8. Konvergenz abwarten

Die Kette läuft von selbst: `infra-controllers` → `infra-configs` → `apps`.

`watch` gehoert nicht zum macOS-Grundsystem, deshalb eine Schleife:

```bash
for i in $(seq 1 30); do
  echo "[$(date '+%H:%M:%S')] $(mise exec -- kubectl -n flux-system get kustomizations \
    -o json | jq -r '.items[] | "\(.metadata.name)=\(.status.conditions[]|select(.type=="Ready")|.status)"' \
    | sort | tr '\n' ' ')"
  sleep 20
done
```

**Nicht `flux reconcile` auf eine Kustomization aufrufen, die noch nicht bereit
sein kann** — der Befehl wartet auf Readiness und hängt bis zum Timeout. Nur
abfragen.

Gemessener Verlauf aus der DR-Probe:

```
+0:00  bootstrap fertig
+2:00  infra-controllers True   (Helm zieht Traefik und cert-manager)
+3:20  infra-configs True       (ClusterIssuer registrieren ACME-Konten)
+4:00  apps True                (Seite erreichbar)
+5:30  Zertifikat True
```

## A9. Zertifikat

Das Secret `thomaszachmann-tls` ist beim Rebuild weg, cert-manager stellt neu
aus. **Das verbraucht eine der fünf Let's-Encrypt-Ausstellungen pro Domain und
Woche.**

```bash
mise exec -- kubectl -n web-thomaszachmann get certificate,order,challenge
```

Bleibt es auf `False`:

```bash
mise exec -- kubectl -n web-thomaszachmann describe certificate thomaszachmann-tls | tail -20
mise exec -- kubectl -n cert-manager logs deploy/cert-manager-cert-manager --tail=100 | grep -iE 'error|fail'
```

Der wahrscheinlichste Fehler ist `DNS problem: NXDOMAIN`. Dann findet Let's
Encrypt den TXT-Record nicht. Erst prüfen, ob DNS überhaupt stimmt:

```bash
dig @a.nic.de thomaszachmann.de NS +norecurse +noall +authority
dig @edward.ns.cloudflare.com _acme-challenge.thomaszachmann.de TXT
```

Die Registry-Antwort muss Cloudflare zeigen. `NXDOMAIN` bei `_acme-challenge`
bedeutet, dass die Zone nicht bei Cloudflare liegt, wohin cert-manager
schreibt.

**Nach einem Fehlversuch geht cert-manager in einen Backoff von einer Stunde.**
Zurücksetzen, indem man die Ressource löscht — Flux legt sie neu an:

```bash
mise exec -- kubectl -n web-thomaszachmann delete certificate thomaszachmann-tls
mise exec -- flux reconcile kustomization apps --with-source
```

## A10. Abnahme

Nichts gilt, bis das grün ist.

```bash
curl -sSI https://thomaszachmann.de/ | head -1
echo | openssl s_client -connect thomaszachmann.de:443 -servername thomaszachmann.de 2>/dev/null \
  | openssl x509 -noout -issuer -dates
curl -sSI http://thomaszachmann.de/ | grep -Ei '^(HTTP|location)'
curl -sSI --resolve www.thomaszachmann.de:443:"$IP" https://www.thomaszachmann.de/ | grep -Ei '^(HTTP|location)'
curl -sSI https://thomaszachmann.de/ | grep -icE 'strict-transport|content-security|x-frame|x-content-type|referrer-policy|permissions-policy'
for p in / /impressum.html /datenschutz.html /fonts/outfit.woff2 /img/kubernetes.svg; do
  printf '%-30s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' "https://thomaszachmann.de$p")"
done
nc -z -G 5 "$IP" 6443 && echo "FEHLER: 6443 offen" || echo "ok: 6443 zu"
```

Erwartet: `HTTP/2 200`, Issuer `Let's Encrypt` **ohne** `STAGING`, `308` bei
HTTP und `www`, sechs Header, alle Pfade `200`, 6443 zu.

Das `www` läuft über `--resolve`, weil der lokale Resolver oft hinterherhinkt —
das ist kein Serverproblem.

## A11. Nacharbeit

Der State hat eine neue Server-ID:

```bash
./scripts/backup-state.sh
git add terraform/state-backup.sops.json
git commit -m "chore(infra): State-Sicherung nach Rebuild"
git push
```

---

# Szenario B: Komplett bei Null

Neues Hetzner-Projekt, kein State, keine Primary IPs. Alles wie in A, mit vier
Ergänzungen davor und einer danach.

## B1. Tokens und Zone

```bash
cat > .env <<'EOF'
HCLOUD_TOKEN=...
CLOUDFLARE_API_TOKEN=...
EOF
```

Hetzner: Console → Projekt → Security → API Tokens, **Read & Write**.

Cloudflare: My Profile → API Tokens → Create Custom Token mit
`Zone → DNS → Edit` **und** `Zone → Zone → Read`. Die zweite Berechtigung ist
nicht optional: Ohne sie kann cert-manager die Zone-ID zum DNS-Namen nicht
auflösen, obwohl es den TXT-Record setzen dürfte.

Prüfen, bevor du weitergehst:

```bash
set -a; . .env; set +a
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/servers          # 200 erwartet
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=thomaszachmann.de" \
  | jq -r 'if .success then .result[0].id else .errors end'
```

Die Zone-ID von dort in `terraform/terraform.tfvars`.

## B2. SSH-Key im Hetzner-Projekt hinterlegen

Terraform **referenziert** den Key, es legt ihn nicht an. Grund: Hetzner lehnt
doppelte Fingerprints ab, und ein von Terraform besessener Key könnte bei
`destroy` den Zugang zu anderen Servern im Projekt mitreissen.

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/ssh_keys \
 | jq -r '.ssh_keys[] | "\(.name)  \(.fingerprint)"'
```

Ist dein Key nicht dabei, einmalig über die Hetzner-Konsole hinzufügen. Den
Namen dann in `terraform/terraform.tfvars` unter `ssh_key_name` eintragen.

## B3. tfvars schreiben

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
```

Nötig: `cloudflare_zone_id`, `admin_ip_cidrs` (mit `/32`, nicht die nackte IP),
`ssh_key_name`. Die Variablen haben Validierungen, die eine verwechselte
Account-ID und eine fehlende Präfixlänge abfangen.

## B4. age-Schlüssel

Falls verloren, ist er **nicht** wiederherstellbar. Dann müssen alle
`*.sops.*`-Dateien im Repo neu verschlüsselt werden, was bedeutet: neue Secrets
beschaffen.

Neu erzeugen:

```bash
age-keygen -o age.key
chmod 600 age.key
grep 'public key' age.key
```

Öffentlichen Schlüssel in `.sops.yaml` in **beide** `creation_rules` eintragen.
Dann das Cloudflare-Token neu verschlüsseln:

```bash
export SOPS_AGE_KEY_FILE="$PWD/age.key"
cat > infrastructure/configs/cloudflare-token.sops.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: $CLOUDFLARE_API_TOKEN
EOF
sops --encrypt --in-place infrastructure/configs/cloudflare-token.sops.yaml
grep -c 'ENC\[' infrastructure/configs/cloudflare-token.sops.yaml   # > 0
```

**Nicht committen, bevor dieser Check grün ist.** Das Repo ist public; ein
einmal gepushtes Token ist auch nach einem Force-Push kompromittiert.

**Und den privaten Schlüssel sofort in den Passwortmanager.**

## B5. Terraform von Null

```bash
mise exec -- terraform -chdir=terraform init
mise exec -- terraform -chdir=terraform plan -out=tfplan
```

Erwartet: `Plan: 9 to add`. Fünf Hetzner-Ressourcen plus vier DNS-Records. Den
Plan lesen, insbesondere die Firewall-Regeln.

```bash
mise exec -- terraform -chdir=terraform apply tfplan
./scripts/backup-state.sh
```

## B6. DNS-Delegation prüfen

**Neue Primary IPs bedeuten neue A- und AAAA-Records.** Terraform setzt sie in
Cloudflare, aber wenn die Zone nicht bei Cloudflare delegiert ist, sieht sie
niemand.

Nur die Registry-Antwort zählt, nicht ein rekursiver Resolver:

```bash
dig @a.nic.de thomaszachmann.de NS +norecurse +noall +authority
```

Muss `edward.ns.cloudflare.com` und `meadow.ns.cloudflare.com` zeigen. Zeigt
sie etwas anderes, ist die Delegation beim **Registrar** zu ändern — nicht in
einer Zone. Die Domain liegt bei AWS Route 53: Route 53 → **Registered
domains** → `thomaszachmann.de` → `Actions ▾` → *Edit name servers*. Der
NS-Record *innerhalb* einer Hosted Zone ändert die Delegation **nicht**.

Vor dem Zertifikatsversuch abwarten, bis alle Resolver folgen:

```bash
for r in 1.1.1.1 8.8.8.8 9.9.9.9; do
  printf '%-8s %s\n' "$r" "$(dig +short A thomaszachmann.de @$r)"
done
```

Negativ gecachte Antworten laufen mit der TTL des alten SOA aus — beim Wechsel
von Route 53 waren das 900 Sekunden. **Erst danach das Zertifikat versuchen**,
sonst kostet es eine Ausstellung und eine Stunde Backoff.

## B7. Ab hier wie Szenario A

Weiter bei **A4** (cloud-init abwarten).

## B8. Wenn möglich: erst Staging

Bei einem Neuaufbau lohnt es, `apps/base/thomaszachmann/certificate.yaml`
zunächst auf `letsencrypt-staging` zu stellen. Die Staging-Umgebung hat viel
höhere Limits. Erst wenn dort ein Zertifikat herauskommt — der Browser warnt
dann zu Recht, die CA ist absichtlich nicht vertraut — auf `letsencrypt-prod`
umstellen:

```bash
$EDITOR apps/base/thomaszachmann/certificate.yaml     # issuerRef.name
git commit -am "feat(site): auf Produktivzertifikat umstellen" && git push
mise exec -- flux reconcile kustomization apps --with-source
mise exec -- kubectl -n web-thomaszachmann delete secret thomaszachmann-tls
```

Das Löschen des Secrets ist nötig, sonst sieht cert-manager ein gültiges
Zertifikat und stellt nichts Neues aus.

---

# Fallstricke, gesammelt

| Symptom | Ursache |
|---|---|
| `error during placement (resource_unavailable)` | Keine Kapazität am Standort. Neu versuchen, dann anderer Typ am selben Standort. Standortwechsel opfert den IP-Anker. |
| `flux reconcile` hängt fünf Minuten | Aufgerufen auf eine Kustomization, die nicht bereit werden kann. Zustand abfragen statt warten. |
| Zwei grüne Meldungen, alter Stand live | `flux reconcile` ohne `--with-source`. Digest im Repo gegen Pod-Image prüfen. |
| `infra-configs` bleibt rot | Secret `sops-age` fehlt oder Schlüssel heisst nicht `age.agekey`. |
| `DNS problem: NXDOMAIN` | Zone nicht bei Cloudflare delegiert, oder Delegation noch nicht propagiert. |
| Ingress wird nie bedient, ohne Fehler | `ingressClassName` passt nicht. Muss `traefik` sein — dafür sorgt `fullnameOverride` in den Traefik-Values. |
| `sops: no matching creation rules found` | SOPS matcht gegen den **Eingabe**pfad. Erst auf den Zielnamen kopieren, dann in-place verschlüsseln. |
| Host-Key-Warnung nach Rebuild | Erwartet. `ssh-keygen -R <ip>`. |
| `terraform version` zeigt etwas anderes als `mise.toml` | Ein Homebrew-Binary überdeckt die mise-Version. `which -a terraform`. |
| Pod `exec format error` | Ein arm64-Image auf dem amd64-Node. Lokale Builds für GHCR brauchen `--platform linux/amd64`; der CI-Runner ist schon amd64. |

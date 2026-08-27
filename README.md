# thomaszachmann.de

Website und Plattform. Ein k3s-Single-Node bei Hetzner Cloud, per Terraform
provisioniert, per Flux verwaltet. Live seit 2026-08-27.

- **Design:** [`docs/superpowers/specs/2026-08-26-hetzner-k3s-website-platform-design.md`](docs/superpowers/specs/2026-08-26-hetzner-k3s-website-platform-design.md)
- **Implementierungsplan:** [`docs/superpowers/plans/2026-08-26-hetzner-k3s-website-platform.md`](docs/superpowers/plans/2026-08-26-hetzner-k3s-website-platform.md)

## Betriebsmodell

Der Node ist Cattle, kein Pet. Es gibt bewusst keine laufende Drift-Korrektur
auf OS-Ebene — der Weg zurück zum Soll-Zustand ist der Rebuild, nicht das
Nachziehen. Der Zustand liegt vollständig im Repo; der Server hält nichts, was
nicht reproduzierbar wäre.

Die Primary IPs sind eigene Terraform-Ressourcen mit `delete_protection`. Sie
überleben einen Rebuild, deshalb muss DNS dabei nie angefasst werden.

## Toolchain

Versionsgebunden in [`mise.toml`](mise.toml), damit sie Teil des
reproduzierbaren Zustands ist und nicht Zufall der lokalen Maschine:

```bash
mise install
```

`kubectl` ist absichtlich auf die k3s-Version des Servers gepinnt. Kubernetes
unterstützt zwischen Client und apiserver nur ±1 Minor-Version; eine global
installierte ältere `kubectl` erzeugt sonst Fehlerbilder, die wie
Cluster-Probleme aussehen, aber keine sind.

Nicht über mise: `sops`, `age`, `gh`, `jq`, `docker` — per Homebrew.

**Wenn `terraform version` etwas anderes zeigt als `mise.toml` sagt:** Es liegt
ein zweites Binary unter `/opt/homebrew/bin/` und überdeckt die mise-Version.
Prüfen mit `which -a terraform`.

## Inhalt ändern

1. Datei unter `sites/thomaszachmann/public/` bearbeiten
2. Lokal prüfen: `./scripts/verify-assets.sh sites/thomaszachmann/public`
3. Committen und pushen

Alles Weitere passiert von selbst: GitHub Actions baut das Image, schreibt den
Digest nach `apps/prod/kustomization.yaml`, Flux rollt innerhalb einer Minute
aus. Gemessen von Commit bis Live: rund zwei Minuten.

Der Workflow **deployt nie selbst**. Im Cluster liegt kein Credential mit
Schreibrecht auf das Repo — der Flux-Deploy-Key ist read-only, per API
verifiziert.

## Infrastruktur aendern

```bash
cd terraform
terraform plan -out=tfplan     # lesen, bevor angewendet wird
terraform apply tfplan
../scripts/backup-state.sh     # State-Sicherung auffrischen
```

Der letzte Schritt ist nicht optional. Der State liegt lokal und ist
gitignored; bei Festplattenverlust muesste ohne Sicherung jede Ressource
einzeln importiert werden. `backup-state.sh` legt ihn SOPS-verschluesselt
unter `terraform/state-backup.sops.json` ab, prueft den Round-Trip
semantisch und verwirft das Backup, wenn es sich nicht zurueckholen laesst.

Das ist ein Backup, kein Remote-Backend: es gibt kein Locking. Solange nur
eine Person applyt, ist das kein Problem.

Wiederherstellen:

```bash
SOPS_AGE_KEY_FILE=age.key sops --decrypt terraform/state-backup.sops.json \
  > terraform/terraform.tfstate
```

## Cluster-Zugriff

Port 6443 ist von aussen geschlossen. Zugriff nur über einen SSH-Tunnel.

```bash
cd terraform
terraform output kube_tunnel_command    # in einem eigenen Terminal ausfuehren
terraform output fetch_kubeconfig_command

# im zweiten Terminal:
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
flux get kustomizations
```

## Wenn etwas kaputt ist

| Symptom | Erste Diagnose |
|---|---|
| Seite nicht erreichbar | `kubectl -n web-thomaszachmann get pods`, dann `kubectl -n traefik get svc` |
| Zertifikat abgelaufen | `kubectl -n web-thomaszachmann describe certificate thomaszachmann-tls` |
| Deploy kommt nicht an | `flux get kustomizations`, dann `flux logs --level=error` |
| Pipeline rot | `gh run view --log-failed` |

**Nicht `flux reconcile` auf eine Kustomization aufrufen, die absichtlich nicht
bereit werden kann** — der Befehl wartet auf Readiness und hängt bis zum
Timeout. Zustand stattdessen abfragen:

```bash
kubectl -n flux-system get kustomizations \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MESSAGE:.status.conditions[?(@.type=="Ready")].message'
```

## Zertifikate

Zwei ClusterIssuer: `letsencrypt-staging` und `letsencrypt-prod`. **Vor
Änderungen an den `dnsNames` auf Staging wechseln.** Let's Encrypt erlaubt fünf
Zertifikate pro Domain und Woche, und ein fehlgeschlagener Versuch schickt
cert-manager in einen Backoff von einer Stunde.

Nach einem fehlgeschlagenen Versuch lässt sich der Backoff zurücksetzen, indem
man die `Certificate`-Ressource löscht — Flux legt sie neu an, und der Zähler
beginnt bei null.

Das `Certificate` steht bewusst **nicht** im Health-Check der
`apps`-Kustomization. Seine Bereitschaft hängt an einem externen Dienst; als
Gate würde es jeden Reconcile bis zum Timeout blockieren und dabei auch andere
Änderungen aufhalten.

## Sich selbst ausgesperrt

Der häufigste Betriebsfehler: Die eigene IP hat sich geändert und die Firewall
lässt SSH nicht mehr durch. Bei einem Telekom-Anschluss passiert das nach jeder
Zwangstrennung.

Weg zurück über die Hetzner-Konsole (console.hetzner.cloud):

1. Projekt → Firewalls → `tz-web` → Rules → SSH-Regel auf die neue IP ändern.
   Wirkt sofort.
2. Danach `admin_ip_cidrs` in `terraform/terraform.tfvars` nachziehen und
   `terraform apply`, sonst setzt der nächste Apply die alte IP zurück.

Alternativ bietet die Konsole eine Web-Console direkt auf den Node, die an der
Firewall vorbeigeht.

## Bewusste Abweichungen von der Spec

| Abweichung | Grund |
|---|---|
| **Ein Cloudflare-Token statt zwei** | Vom Betreiber entschieden. Konsequenz: Das Token, mit dem Terraform DNS verwaltet, liegt entschlüsselt in einem Kubernetes-Secret. Nachziehen kostet ein neues Token und ein `sops --encrypt`, keine Codeänderung. |
| **SSH-Key wird referenziert, nicht verwaltet** | Der Key lag bereits im Hetzner-Projekt und wird von weiteren Servern benutzt. Würde Terraform ihn besitzen, könnte ein `destroy` deren Zugang mitreissen. |
| **Kein manueller Bootstrap-Push nach GHCR** | Der Actions-Runner bringt `packages: write` aus seinem `permissions`-Block mit, und GHCR erbt die öffentliche Sichtbarkeit vom Repo. Damit ist lokal kein `write:packages` nötig und das erste Image entsteht auf demselben Weg wie jedes spätere. |
| **`apps` gated auf das Deployment statt `wait: true`** | Siehe Abschnitt Zertifikate. |

## Noch offen

- **Vier `PLATZHALTER`** in `impressum.html` und `datenschutz.html`: USt-Situation,
  Berufsbezeichnung, Log-Aufbewahrungsdauer, zuständige Aufsichtsbehörde. Stehen
  live auf der Seite und sind in Deutschland abmahnfähig.
- **DR-Probe** noch nicht durchgefuehrt (siehe unten).
- **Force-Push-Schutz** ist konfiguriert, aber nicht verifiziert: der einzige
  belastbare Test waere ein echter Force-Push.

**Was NICHT durch `terraform apply` heilbar ist:** der private age-Schlüssel
(`age.key`). Ohne ihn sind die SOPS-verschlüsselten Secrets im Repo unbrauchbar.
Er gehört in den Passwortmanager, nicht nur auf diese Festplatte.

## Kosten

| Posten | €/Monat netto |
|---|---|
| CX33 (4 vCPU, 8 GB, fsn1) | 8,49 |
| Primäre IPv4 | ~0,50–0,60 |
| Cloudflare DNS, GHCR, GitHub Actions | 0,00 |
| **Summe** | **~9,05 netto, ~10,80 brutto** |

Nicht gebucht: Hetzner-Backups (20 % Aufpreis für einen zustandslosen Node) und
Load Balancer (durch k3s' ServiceLB ersetzt).

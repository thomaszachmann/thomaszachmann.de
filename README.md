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

**`flux reconcile` braucht `--with-source`, sonst luegt es.** Ohne das Flag
wendet Flux die zwischengespeicherte Git-Revision erneut an, statt neu zu
holen — und meldet Erfolg. Ein anschliessendes `kubectl rollout status` meldet
ebenfalls Erfolg, weil das *alte* Deployment ja ausgerollt ist. Man hat dann
zwei gruene Meldungen und trotzdem den alten Stand live:

```bash
flux reconcile kustomization apps --with-source     # richtig
```

Gegenprobe, die nicht luegt — laeuft das Image, das im Repo steht?

```bash
grep 'digest:' apps/prod/kustomization.yaml
kubectl -n web-thomaszachmann get pod -l app.kubernetes.io/name=thomaszachmann \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

Ohne Eingriff loest sich das ohnehin: `apps` reconciled jede Minute. Das Flag
braucht man nur, wenn man nicht warten will.

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

- **Zwei `PLATZHALTER`** in `datenschutz.html`: Log-Aufbewahrungsdauer und
  zuständige Aufsichtsbehörde. Stehen live auf der Seite.

### Umsatzsteuer im Impressum

Der Abschnitt fehlt derzeit bewusst. § 5 Abs. 1 Nr. 6 DDG verlangt die
USt-IdNr. nur **sofern vorhanden** — wer keine hat, lässt ihn weg. Das
Impressum ist damit vollständig.

Falls eine USt-IdNr. erteilt ist, in `impressum.html` vor „Redaktionell
verantwortlich" einfügen:

```html
  <h2>Umsatzsteuer-Identifikationsnummer</h2>
  <p>DE123456789</p>
```

Bei Kleinunternehmerregelung stattdessen:

```html
  <h2>Umsatzsteuer</h2>
  <p>Gemäß § 19 UStG wird keine Umsatzsteuer berechnet.</p>
```

**Die Steuernummer gehört nicht hierher** — sie ist nicht vorgeschrieben und
sollte nicht veröffentlicht werden. Nur die USt-IdNr. (Format `DE` plus neun
Ziffern) ist eine Impressumsangabe.
- **Force-Push-Schutz** ist konfiguriert, aber nicht verifiziert: der einzige
  belastbare Test waere ein echter Force-Push.

**Was NICHT durch `terraform apply` heilbar ist:** der private age-Schlüssel
(`age.key`). Ohne ihn sind die SOPS-verschlüsselten Secrets im Repo unbrauchbar.
Er gehört in den Passwortmanager, nicht nur auf diese Festplatte.

## Disaster Recovery

Am 2026-08-27 durchgefuehrt und gemessen, nicht geschaetzt.

```
16:58:59  Server zerstoert, Seite offline
16:59:22  terraform apply FEHLGESCHLAGEN (siehe unten)
17:00:27  Server neu erstellt, gleiche IP
17:01:25  cloud-init durch, k3s Ready        (58 s)
17:02:31  Flux gebootstrappt
17:04:32  Site laeuft, Seite wieder erreichbar
17:05:55  Produktivzertifikat neu ausgestellt
17:06:26  Abnahme vollstaendig gruen
```

**Gemessene RTO: rund 6 Minuten bis erreichbar, 7 Minuten bis gueltiges TLS.**
RPO null — alles steht im Repo.

Belegt: Server-ID wechselte von `163777966` auf `163785180`, also eine
physisch andere Maschine, bei unveraenderter IPv4 `2.28.5.182`. **DNS musste
nicht angefasst werden.** Genau dafuer sind die Primary IPs eigene Ressourcen
mit `delete_protection`.

### Der Ablauf

```bash
cd terraform
terraform destroy -target=hcloud_server.web
terraform apply
ssh-keygen -R "$(terraform output -raw ipv4)"       # Host-Key ist neu
eval "$(terraform output -raw fetch_kubeconfig_command)"
# Tunnel in einem eigenen Terminal: terraform output -raw kube_tunnel_command

export KUBECONFIG="$PWD/../kubeconfig"
kubectl create namespace flux-system
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=../age.key

export GITHUB_TOKEN="$(gh auth token)"
flux bootstrap github --owner=<owner> --repository=thomaszachmann.de \
  --branch=main --path=clusters/prod --personal --version=v2.9.4

../scripts/backup-state.sh    # State hat eine neue Server-ID
```

### Was die Probe an einem Risiko aufgedeckt hat

Der erste `terraform apply` scheiterte:

```
Error: error during placement (resource_unavailable)
```

Hetzner hatte in diesem Moment **keine CX33-Kapazitaet in fsn1**. Ein
Neuversuch 30 Sekunden spaeter klappte. Das ist kein Konfigurationsfehler,
sondern eine echte Abhaengigkeit: Der Rebuild setzt voraus, dass am
Zielstandort gerade eine Maschine des gewuenschten Typs frei ist.

Das trifft die IP-Anker-Konstruktion an ihrer empfindlichen Stelle. Eine
Primary IP ist **standortgebunden** — eine IP in `fsn1` laesst sich nicht an
einen Server in `nbg1` haengen. Ein Ausweichen auf einen anderen Standort
wuerde also genau die Eigenschaft aufgeben, die die schnelle
Wiederherstellung ausmacht.

Vorgehen im Ernstfall, in dieser Reihenfolge:

1. **Neu versuchen.** Kapazitaetsengpaesse sind meist Minutensache.
2. **Anderen Servertyp am selben Standort** nehmen:
   `terraform apply -var="server_type=cx43"`. Der IP-Anker haelt, es kostet
   nur mehr Geld — und man kann spaeter in Ruhe zurueckwechseln.
3. **Erst als letztes den Standort wechseln.** Dann sind neue Primary IPs
   noetig und DNS muss nachgezogen werden. Aus 6 Minuten RTO werden dann
   die DNS-TTL von 300 Sekunden plus Cache-Realitaet.

Punkt 2 ist der eigentliche Wert dieser Erkenntnis: Es gibt einen Ausweg, der
den Anker nicht opfert — aber man muss ihn kennen, bevor man ihn braucht.

## Kosten

| Posten | €/Monat netto |
|---|---|
| CX33 (4 vCPU, 8 GB, fsn1) | 8,49 |
| Primäre IPv4 | ~0,50–0,60 |
| Cloudflare DNS, GHCR, GitHub Actions | 0,00 |
| **Summe** | **~9,05 netto, ~10,80 brutto** |

Nicht gebucht: Hetzner-Backups (20 % Aufpreis für einen zustandslosen Node) und
Load Balancer (durch k3s' ServiceLB ersetzt).

# Feature deployen

Alle Kommandos aus dem Repo-Wurzelverzeichnis. `mise` liefert die richtigen
Werkzeugversionen; ohne `mise exec --` greift womöglich ein Homebrew-Binary.

Es gibt vier Sorten Änderung, und sie gehen unterschiedliche Wege:

| Was du änderst | Wer rollt aus | Dauer |
|---|---|---|
| Website-Inhalt unter `sites/` | Actions baut, Flux rollt aus | ~2 min |
| Cluster-Konfiguration unter `infrastructure/`, `apps/`, `clusters/` | nur Flux | ~1 min |
| Infrastruktur unter `terraform/` | du, per `terraform apply` | 1–3 min |
| Neue Site (z. B. Nyrvex) | alle drei zusammen | siehe unten |

---

## 1. Website-Inhalt ändern

Der häufigste Fall. Text, Bild, CSS.

```bash
# 1. bearbeiten
$EDITOR sites/thomaszachmann/public/index.html

# 2. pruefen, dass keine Referenz ins Leere zeigt
./scripts/verify-assets.sh sites/thomaszachmann/public

# 3. committen und pushen
git add sites/
git commit -m "feat(site): ..."
git push
```

Ab hier passiert alles von selbst. Beobachten, wenn du willst:

```bash
gh run watch                       # Pipeline
git pull --rebase                  # den Digest-Commit des Bots holen
export KUBECONFIG="$PWD/kubeconfig"
kubectl -n web-thomaszachmann rollout status deploy/thomaszachmann
```

**Prüfen, dass es wirklich live ist** — nicht den Meldungen glauben, den
Inhalt ansehen:

```bash
curl -s https://thomaszachmann.de/ | grep 'was du geaendert hast'
```

### Wenn Schritt 2 fehlschlägt

`verify-assets.sh` prüft jedes lokale `href`, `src` **und** jedes CSS-`url()`
gegen das Dateisystem. Die self-hosted Fonts stehen nur in einem
`@font-face`-Block — ein Prüfer, der nur Attribute liest, würde sie übersehen.

Fehlt eine Datei, bricht auch die Pipeline ab, und zwar **vor** dem Build. Das
ist Absicht: Ein fehlender Font ist kein Grund, ein Image zu bauen.

### Neue Datei hinzufügen

Neue Assets gehören unter `sites/thomaszachmann/public/`. Bilder nach `img/`,
Schriften nach `fonts/`. Beides wird vom Prüfer erfasst, sobald es referenziert
ist.

Achtung bei der Content-Security-Policy: Die Seite läuft mit
`default-src 'none'`. Externe Ressourcen — CDN-Skripte, Google Fonts, fremde
Bilder — werden vom Browser **blockiert**. Das ist gewollt. Wer etwas
einbinden will, hostet es selbst oder passt die CSP in
`infrastructure/configs/middlewares.yaml` an.

---

## 2. Cluster-Konfiguration ändern

Betrifft `infrastructure/` (Traefik, cert-manager, Issuer, Middlewares),
`apps/` (Deployment, Ingress, NetworkPolicy) und `clusters/prod/`
(Reihenfolge der Kustomizations).

Kein Image-Build nötig, Actions läuft gar nicht an.

```bash
$EDITOR apps/base/thomaszachmann/deployment.yaml

# Gegen die echten CRDs im Cluster pruefen, nicht nur YAML-Syntax
export KUBECONFIG="$PWD/kubeconfig"
mise exec -- kubectl apply --dry-run=server -k apps/base/thomaszachmann

git add apps/ && git commit -m "fix(site): ..." && git push
mise exec -- flux reconcile kustomization apps --with-source
```

**`--with-source` ist nicht optional.** Ohne das Flag wendet Flux die
zwischengespeicherte Git-Revision erneut an und meldet Erfolg. Ein
anschliessendes `rollout status` meldet ebenfalls Erfolg, weil das *alte*
Deployment ausgerollt ist. Zwei grüne Meldungen, alter Stand live.

Gegenprobe, die nicht lügt:

```bash
grep 'digest:' apps/prod/kustomization.yaml
mise exec -- kubectl -n web-thomaszachmann get pod \
  -l app.kubernetes.io/name=thomaszachmann \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

Stimmen beide überein, läuft das, was im Repo steht.

### Zustand ansehen

```bash
mise exec -- kubectl -n flux-system get kustomizations \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MESSAGE:.status.conditions[?(@.type=="Ready")].message'
```

Nicht `flux get kustomizations` in einem Skript verwenden und nicht auf einen
einzelnen Schnappschuss vertrauen: Während eines Reconcile steht kurzzeitig
`DependencyNotReady` drin, obwohl nichts kaputt ist. Zwei Messungen im Abstand
von 30 Sekunden trennen echte Fehler von Momentaufnahmen.

---

## 3. Infrastruktur ändern

Servertyp, Firewall-Regeln, DNS-Records.

```bash
set -a; . .env; set +a          # HCLOUD_TOKEN, CLOUDFLARE_API_TOKEN

$EDITOR terraform/firewall.tf

mise exec -- terraform -chdir=terraform fmt -recursive
mise exec -- terraform -chdir=terraform validate
mise exec -- tflint --chdir=terraform

mise exec -- terraform -chdir=terraform plan -out=tfplan
# LESEN. Insbesondere: hat die SSH-Regel noch ein /32?

mise exec -- terraform -chdir=terraform apply tfplan
./scripts/backup-state.sh       # nicht optional
git add terraform/ && git commit -m "feat(infra): ..." && git push
```

Wenn du das cloud-init-Template angefasst hast, zusätzlich:

```bash
./scripts/verify-cloud-init.sh terraform
```

Das rendert das Template und prüft, dass gültiges YAML herauskommt und alle
fünf k3s-Flags drin sind. `terraform validate` prüft das **nicht** — es rendert
`templatefile()` nie. Ein zu viel gesetztes Dollarzeichen fällt sonst erst beim
`plan` auf, ein Einrückungsfehler erst, wenn der Server bootet und cloud-init
die Datei stillschweigend verwirft.

**Eine Änderung an `user_data` ersetzt den Server.** Das ist gewollt: Es gibt
keinen anderen Weg, cloud-init erneut anzuwenden. Rechne mit den ~6 Minuten aus
dem DR-Runbook.

### Deine IP hat sich geändert

Nach jeder Telekom-Zwangstrennung sperrt die Firewall dich aus:

```bash
NEU="$(curl -s https://ifconfig.me)/32"
mise exec -- terraform -chdir=terraform apply \
  -target=hcloud_firewall.web -var="admin_ip_cidrs=[\"$NEU\"]"
```

Danach `admin_ip_cidrs` in `terraform/terraform.tfvars` nachziehen, sonst setzt
der nächste vollständige Apply die alte IP zurück.

Kommst du gar nicht mehr ran: Hetzner-Konsole → Firewalls → `tz-web` → Rule
ändern. Wirkt sofort und geht ohne SSH.

---

## 4. Neue Site hinzufügen (Nyrvex)

Die Struktur ist darauf vorbereitet. Vier Schritte:

**a) Inhalt und Image**

```bash
mkdir -p sites/nyrvex/public
cp sites/thomaszachmann/{Dockerfile,nginx.conf,.dockerignore} sites/nyrvex/
$EDITOR sites/nyrvex/public/index.html
./scripts/verify-assets.sh sites/nyrvex/public
```

**b) Manifeste**

```bash
mkdir -p apps/base/nyrvex
cp apps/base/thomaszachmann/*.yaml apps/base/nyrvex/
```

Dann in allen Dateien ersetzen: Namespace `web-thomaszachmann` → `web-nyrvex`,
Name `thomaszachmann` → `nyrvex`, Label
`app.kubernetes.io/name` → `nyrvex`, und in `certificate.yaml` sowie
`ingress.yaml` die Domains.

Die Middlewares in `infrastructure/configs/` gelten schon für beide — Traefik
läuft mit `allowCrossNamespace: true`, genau dafür. Nur den `www-redirect`
braucht die neue Domain als eigene Middleware, weil das Regex domainspezifisch
ist.

**c) In die Kustomization aufnehmen**

```yaml
# apps/prod/kustomization.yaml
resources:
  - ../base/thomaszachmann
  - ../base/nyrvex

images:
  - name: ghcr.io/thomaszachmann/thomaszachmann
    digest: sha256:...
  - name: ghcr.io/thomaszachmann/nyrvex
    digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
```

Der Nullen-Digest ist ein Platzhalter, den der erste Pipeline-Lauf ersetzt.

**d) DNS und Pipeline**

DNS in `terraform/dns.tf` ergänzen, dann `plan` und `apply`.

Für die Pipeline: `.github/workflows/build-site.yaml` kopieren nach
`build-nyrvex.yaml`, darin `sites/thomaszachmann` → `sites/nyrvex`, den
`concurrency.group` umbenennen und den `sed`-Ausdruck im Digest-Schritt so
anpassen, dass er nur den Nyrvex-Digest trifft — mit zwei `digest:`-Zeilen in
derselben Datei greift das jetzige `s|^(\s*digest:\s).*|` sonst beide.

Das ist der einzige Punkt, an dem die zweite Site echte Nacharbeit kostet.
Alternativ pro Site eine eigene Overlay-Datei, dann bleibt der `sed` eindeutig.

---

## Zurückrollen

Der Digest im Repo ist die Wahrheit. Also: Commit zurücknehmen.

```bash
git log --oneline -10
git revert --no-edit <commit>
git push
```

Schneller, ohne auf einen Rebuild zu warten — direkt den alten Digest
eintragen:

```bash
$EDITOR apps/prod/kustomization.yaml     # digest auf den vorherigen Wert
git commit -am "revert: zurueck auf <digest>"
git push
mise exec -- flux reconcile kustomization apps --with-source
```

Alte Digests findest du in der Commit-Historie:

```bash
git log --oneline --grep='chore(deploy)' -10
```

Alle Images bleiben in GHCR, es wird nichts gelöscht.

---

## Wenn die Pipeline rot ist

```bash
gh run list --limit 5
gh run view --log-failed
```

Häufigste Ursachen, in dieser Reihenfolge:

1. **Asset-Check schlägt an** — eine referenzierte Datei fehlt. Lokal
   nachstellen: `./scripts/verify-assets.sh sites/thomaszachmann/public`
2. **Push nach GHCR scheitert** — passiert praktisch nur, wenn jemand am
   `permissions`-Block des Workflows gedreht hat. `packages: write` muss da
   stehen.
3. **Digest-Commit scheitert** — wenn `main` irgendwann Pflicht-Reviews
   bekommt, braucht der Actions-Bot einen Bypass. Aktuell schützen nur
   `deletion` und `non_fast_forward`, die lassen ihn durch.

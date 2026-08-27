# Hetzner k3s Website-Plattform — Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `thomaszachmann.de` läuft über HTTPS auf einem k3s-Single-Node bei Hetzner, vollständig aus diesem Repository reproduzierbar, mit automatischem Rollout bei jedem Commit.

**Architecture:** Terraform provisioniert Server, Primary IPs, Firewall und Cloudflare-DNS; cloud-init installiert k3s beim ersten Boot; Flux verwaltet Traefik, cert-manager und die Site-Workloads aus dem Repo; GitHub Actions baut ausschließlich das Container-Image und schreibt dessen Digest ins Repo zurück, deployt aber nie selbst.

**Tech Stack:** Terraform (hcloud, cloudflare), cloud-init, k3s, Flux CD, Traefik v3, cert-manager, SOPS/age, GitHub Actions, nginx-unprivileged.

**Spec:** `docs/superpowers/specs/2026-08-26-hetzner-k3s-website-platform-design.md`

## Global Constraints

Alle Versionen wurden am 2026-08-26 gegen die Upstream-Quellen verifiziert. Keine `latest`-Tags, keine offenen Ranges in HelmReleases.

- Terraform: `required_version = ">= 1.9.0"`
- Provider hcloud: `hetznercloud/hcloud`, `~> 1.68` (aktuell v1.68.0)
- Provider cloudflare: `cloudflare/cloudflare`, `~> 5.24` (aktuell v5.24.0)
- k3s: `v1.36.3+k3s1` (Channel `stable` laut `https://update.k3s.io/v1-release/channels`)
- Flux CLI und Controller: `v2.9.4`
- cert-manager Chart: `v1.21.1`, CRDs über `crds.enabled: true` (**nicht** `installCRDs`, das ist ab 1.15 deprecated)
- Traefik Chart: `41.3.0`
- SOPS: `v3.13.3`, age: `v1.3.1`
- Basis-Image: `nginxinc/nginx-unprivileged:1.31.4-alpine`
- Server: `cx33`, Location `fsn1`, Image `ubuntu-24.04`
- Domain: `thomaszachmann.de` ist kanonisch, `www` bekommt 301
- Namespace der Site: `web-thomaszachmann`
- GHCR-Pfad: `ghcr.io/thomaszachmann/thomaszachmann` (Owner ist Variable/Parameter, nicht hartcodiert wo vermeidbar)
- Commit-Konvention: Conventional Commits, Betreff und Body auf Deutsch — so wie die bestehenden Commits im Repo

**Cloudflare-Provider v5 — Fallstricke, die jedes ältere Beispiel falsch macht:**
Die Ressource heißt `cloudflare_dns_record` (nicht `cloudflare_record`), das Attribut heißt `content` (nicht `value`), `ttl` ist **verpflichtend**, `name` verlangt den vollen FQDN (nicht `@`), und `hostname` sowie `allow_overwrite` existieren nicht mehr.

**Traefik-Chart 41.3.0 — verifizierte Value-Pfade:**
Redirect liegt unter `ports.web.http.redirections.entryPoint` (mit dem `http`-Zwischenschritt). Der Service-Typ liegt unter `service.spec.type` und ist bereits `LoadBalancer` per Default, muss also nicht gesetzt werden.

---

## Voraussetzungen

Vor Task 1 einmalig zu erledigen. Task 3 und 4 scheitern sonst mitten im
Apply, was der unangenehmste Zeitpunkt für einen fehlenden Account ist.

**Werkzeuge.** Die versionsgebundene Toolchain ist in `mise.toml` im Repo gepinnt und damit Teil des reproduzierbaren Zustands — nicht Zufall der lokalen Maschine:

```toml
[tools]
"aqua:fluxcd/flux2" = "2.9.4"
kubectl             = "1.36.3"
terraform           = "1.15.9"
tflint              = "0.64.0"
```

```bash
mise install          # holt genau diese Versionen
mise ls               # im Projektverzeichnis: die vier oben
```

`kubectl` ist bewusst auf `1.36.3` gepinnt, also exakt die Version des k3s-Servers. Kubernetes unterstützt zwischen Client und apiserver nur ±1 Minor-Version; eine global installierte ältere `kubectl` führt sonst zu Fehlern, die wie Cluster-Probleme aussehen, aber keine sind.

**Achtung bei Homebrew-Dubletten:** Liegt zusätzlich ein `terraform` oder `kubectl` unter `/opt/homebrew/bin/`, überdeckt es die mise-Version, sobald mise im Verzeichnis nicht aktiv ist. Prüfen mit:

```bash
which -a terraform kubectl
mise exec -- terraform version    # muss v1.15.9 zeigen
```

Nicht über mise verwaltet, aber ebenso nötig — hier reicht Homebrew:

```bash
brew install sops age gh jq
sops --version    # v3.13.x
age-keygen --version
docker version    # Docker Desktop oder colima muss laufen (Task 2 baut lokal)
```

**Accounts und Zugänge:**

| Was | Wofür | Prüfen mit |
|---|---|---|
| Hetzner-Cloud-Projekt + API-Token (Read & Write) | Task 3, 4 | `curl -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/servers` → `200` |
| Domain mit Cloudflare als Nameserver | Task 3 | `dig +short NS thomaszachmann.de` → muss `*.ns.cloudflare.com` liefern |
| Cloudflare API-Token für Terraform, Scope `Zone:DNS:Edit` | Task 3 | Cloudflare-Dashboard → API Tokens → Verify |
| Zweites Cloudflare-Token für cert-manager, gleicher Scope | Task 6 | dito |
| SSH-Key, **im Hetzner-Projekt hinterlegt** | Task 3 | Namen auflisten (siehe Task 3 Step 3); der Name kommt in `ssh_key_name` |
| GitHub-Account mit aktivierten Actions | Task 1, 9 | `gh auth status` |
| gh-Token mit Scope `write:packages` | Task 7, Step 1 | `gh auth status` — steht der Scope nicht dabei: `gh auth refresh -s write:packages` |

**Der häufigste Blocker:** Die Domain zeigt noch nicht auf Cloudflare-Nameserver.
Der Nameserver-Wechsel beim Registrar dauert bis zu 24 Stunden und lässt sich
nicht beschleunigen. Wenn `dig +short NS thomaszachmann.de` keine
Cloudflare-Nameserver zeigt, ist das **jetzt** anzustoßen — Tasks 1 und 2
laufen unabhängig davon weiter, Task 3 nicht.

---

## Dateistruktur

Jede Datei hat genau eine Zuständigkeit. Was zusammen geändert wird, liegt zusammen.

| Datei | Zuständigkeit |
|---|---|
| `scripts/verify-assets.sh` | Prüft, dass jede lokal referenzierte Datei in den HTML-Seiten existiert — inklusive CSS-`url()` aus inline `<style>`. Läuft lokal und in CI identisch. |
| `scripts/verify-cloud-init.sh` | Rendert das cloud-init-Template und prüft das Ergebnis auf gültiges YAML und Vollständigkeit der k3s-Flags. Schließt die Lücke, die `terraform validate` offen lässt. |
| `sites/thomaszachmann/public/` | Auslieferbarer Website-Inhalt. Nichts anderes. |
| `sites/thomaszachmann/Dockerfile` | Verpackt `public/` in ein nicht-privilegiertes nginx-Image. |
| `sites/thomaszachmann/nginx.conf` | Server-Block: Ports, Caching, Health-Endpoint. Keine Security-Header — die macht Traefik. |
| `terraform/providers.tf` | Provider- und Terraform-Versionen. |
| `terraform/variables.tf` | Alle Eingabeparameter mit Beschreibung und Validierung. |
| `terraform/main.tf` | SSH-Key, Primary IPs, Server. |
| `terraform/firewall.tf` | Firewall-Regeln und Attachment. Getrennt, weil es der sicherheitskritischste Teil ist und eigenständig reviewt werden soll. |
| `terraform/dns.tf` | Cloudflare-Records. |
| `terraform/cloud-init.yaml.tftpl` | Einmalige Node-Konfiguration: OS-Härtung, k3s-Install. |
| `terraform/outputs.tf` | IPs und fertig kopierbare SSH-/Tunnel-Befehle. |
| `infrastructure/controllers/` | HelmRepository + HelmRelease für Traefik und cert-manager. |
| `infrastructure/configs/` | ClusterIssuer, Traefik-Middlewares, verschlüsseltes Cloudflare-Token. |
| `apps/base/thomaszachmann/` | Wiederverwendbare Site-Manifeste, ohne Umgebungsbezug. |
| `apps/prod/` | Überlagerung mit Namespace und Image-Digest. Die einzige Datei, die CI schreibt. |
| `clusters/prod/` | Flux-Einstiegspunkt: welche Kustomizations in welcher Reihenfolge. |
| `.github/workflows/build-site.yaml` | Verify, Build, Digest-Rückschreiben. Deployt nie. |
| `README.md` | Betriebsanleitung: Rebuild, Aussperren, DR-Probe. |

---

## Task 1: Site-Struktur, fehlende Assets und der Asset-Check

Dies ist der einzige Task mit echtem Test-First-Zyklus: Wir schreiben den Prüfer, sehen ihn an den heute fehlenden Dateien scheitern, und beheben genau das.

**Files:**
- Create: `scripts/verify-assets.sh`
- Move: `index.html` → `sites/thomaszachmann/public/index.html`
- Create: `sites/thomaszachmann/public/fonts/outfit.woff2`
- Create: `sites/thomaszachmann/public/fonts/jetbrains-mono.woff2`
- Create: `sites/thomaszachmann/public/impressum.html`
- Create: `sites/thomaszachmann/public/datenschutz.html`

**Interfaces:**
- Consumes: nichts (erster Task)
- Produces: `scripts/verify-assets.sh <verzeichnis>` — Exit 0 wenn alle Referenzen auflösen, Exit 1 mit Liste der fehlenden Dateien auf stderr, Exit 2 wenn das Verzeichnis nicht existiert. Task 2 und Task 9 rufen es mit `sites/thomaszachmann/public` auf.

- [x] **Step 1: Prüfskript schreiben**

`scripts/verify-assets.sh`:

```bash
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
    [ -e "$target" ] || printf '%s\t%s\n' "${html#./}" "$ref" >>"$missing"
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
```

```bash
chmod +x scripts/verify-assets.sh
```

- [x] **Step 2: Struktur anlegen und index.html verschieben**

```bash
mkdir -p sites/thomaszachmann/public/fonts
git mv index.html sites/thomaszachmann/public/index.html
```

- [x] **Step 3: Prüfskript laufen lassen und scheitern sehen**

Run: `./scripts/verify-assets.sh sites/thomaszachmann/public`

Expected: **Exit 1**, und auf stderr genau diese vier fehlenden Referenzen:

```
  datenschutz.html   (referenziert in sites/thomaszachmann/public/index.html)
  fonts/jetbrains-mono.woff2   (referenziert in sites/thomaszachmann/public/index.html)
  fonts/outfit.woff2   (referenziert in sites/thomaszachmann/public/index.html)
  impressum.html   (referenziert in sites/thomaszachmann/public/index.html)
```

Wenn stattdessen Exit 0 kommt, findet das Skript die Referenzen nicht — dann ist der `grep`-Ausdruck kaputt, nicht die Website. Nicht weitermachen, bevor dieser Fehlschlag exakt so aussieht.

**Warum die CSS-Extraktion im Skript nicht optional ist:** Die beiden Fonts werden nicht über ein HTML-Attribut geladen, sondern über `src:url(fonts/outfit.woff2)` in einem `@font-face`-Block im inline-`<style>` (index.html:19-20). Ein Prüfer, der nur `href=` und `src=` liest, meldet hier bloß zwei statt vier fehlender Dateien — und übersieht ausgerechnet die, die den optischen Eindruck der Seite bestimmen.

- [x] **Step 4: Fonts von den offiziellen Quellen holen**

Beide Familien liegen upstream bereits als variables woff2 bereit — keine Konvertierung nötig. Beide sind OFL-1.1-lizenziert, Self-Hosting ist ausdrücklich erlaubt. Die Dateinamen werden auf die in `index.html:19-20` erwarteten umbenannt.

```bash
cd sites/thomaszachmann/public/fonts

# Outfit, variable Achse wght (~45 KB)
curl -fsSL -o outfit.woff2 \
  'https://github.com/Outfitio/Outfit-Fonts/raw/main/fonts/variable/Outfit%5Bwght%5D.woff2'

# JetBrains Mono, variable Achse wght (~114 KB)
curl -fsSL -o jetbrains-mono.woff2 \
  'https://github.com/JetBrains/JetBrainsMono/raw/master/fonts/webfonts/JetBrainsMono%5Bwght%5D.woff2'

cd -
```

Verifizieren, dass es echte woff2-Dateien sind und nicht HTML-Fehlerseiten:

```bash
file sites/thomaszachmann/public/fonts/*.woff2
ls -l sites/thomaszachmann/public/fonts/
```

Expected: beide als `Web Open Font Format (Version 2)` erkannt, Größen ~45 KB und ~114 KB. Eine Datei von wenigen KB mit `HTML` im `file`-Output bedeutet, der Pfad ist umgezogen — dann den echten Pfad über die GitHub-API suchen statt zu raten.

- [x] **Step 5: Rechtstexte als Gerüst anlegen**

Der Inhalt ist bewusst mit Platzhaltern versehen und rechtlich vom Betreiber zu verantworten. Das Gerüst übernimmt Struktur und Styling-Anmutung der Hauptseite, damit später nur Text ersetzt werden muss.

`sites/thomaszachmann/public/impressum.html`:

```html
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Impressum — Thomas Zachmann</title>
<meta name="robots" content="noindex, follow">
<style>
@font-face{font-family:'Outfit';font-style:normal;font-weight:300 600;font-display:swap;src:url(fonts/outfit.woff2) format('woff2')}
:root{--bg:#fff;--text:#0f172a;--text-2:#475569;--accent:#1d4ed8}
*,*::before,*::after{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font-family:'Outfit',system-ui,-apple-system,"Segoe UI",sans-serif;font-size:17px;font-weight:350;line-height:1.65}
main{max-width:66ch;margin:0 auto;padding:64px 28px}
h1{font-size:clamp(1.6rem,5vw,2.4rem);letter-spacing:-.025em;line-height:1.2;margin:0 0 1.5rem}
h2{font-size:1.25rem;letter-spacing:-.01em;margin:2.5rem 0 .75rem}
p{margin:0 0 1.1rem}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline;text-underline-offset:3px}
.back{display:inline-block;margin-bottom:2rem;color:var(--text-2)}
</style>
</head>
<body>
<main>
  <a class="back" href="/">&larr; Zur Startseite</a>
  <h1>Impressum</h1>

  <h2>Angaben gemäß § 5 DDG</h2>
  <p>
    PLATZHALTER Vor- und Nachname<br>
    PLATZHALTER Straße und Hausnummer<br>
    PLATZHALTER PLZ und Ort<br>
    Deutschland
  </p>

  <h2>Kontakt</h2>
  <p>
    E-Mail: <a href="mailto:thomas@zachmann.work">thomas@zachmann.work</a><br>
    Telefon: <a href="tel:+4917610365347">+49 176 10365347</a>
  </p>

  <h2>Umsatzsteuer-Identifikationsnummer</h2>
  <p>PLATZHALTER USt-IdNr. gemäß § 27a UStG — oder Hinweis auf Kleinunternehmerregelung nach § 19 UStG.</p>

  <h2>Berufsbezeichnung</h2>
  <p>PLATZHALTER Freiberufliche Tätigkeit als IT-Berater / Plattform-Architekt.</p>

  <h2>Verantwortlich für den Inhalt</h2>
  <p>PLATZHALTER Name und Adresse wie oben.</p>

  <h2>Streitschlichtung</h2>
  <p>Wir sind nicht verpflichtet und nicht bereit, an einem Streitbeilegungsverfahren vor einer Verbraucherschlichtungsstelle teilzunehmen.</p>
</main>
</body>
</html>
```

`sites/thomaszachmann/public/datenschutz.html`: dieselbe Hülle (identischer `<head>`, identischer `<style>`, identischer Zurück-Link — bitte aus der Datei oben kopieren, nicht neu erfinden), mit diesem `<main>`-Inhalt:

```html
<main>
  <a class="back" href="/">&larr; Zur Startseite</a>
  <h1>Datenschutzerklärung</h1>

  <h2>Verantwortlicher</h2>
  <p>PLATZHALTER Name und Anschrift wie im <a href="impressum.html">Impressum</a>.</p>

  <h2>Hosting</h2>
  <p>
    Diese Website wird auf einem Server der Hetzner Online GmbH, Industriestr. 25,
    91710 Gunzenhausen, Deutschland, im Rechenzentrum Falkenstein betrieben. Es
    besteht ein Auftragsverarbeitungsvertrag. Die Rechtsgrundlage ist Art. 6
    Abs. 1 lit. f DSGVO — das berechtigte Interesse an einem sicheren und
    zuverlässigen Betrieb.
  </p>

  <h2>Server-Logfiles</h2>
  <p>
    Beim Aufruf werden technisch notwendige Daten verarbeitet: gekürzte
    IP-Adresse, Zeitpunkt, angeforderte Ressource, HTTP-Statuscode,
    übertragene Datenmenge, Referrer und User-Agent. Diese Daten werden
    PLATZHALTER Aufbewahrungsdauer, z. B. 7 Tage gespeichert und dann gelöscht.
    Rechtsgrundlage ist Art. 6 Abs. 1 lit. f DSGVO.
  </p>

  <h2>Namensauflösung</h2>
  <p>
    Für die DNS-Auflösung der Domain wird Cloudflare, Inc. eingesetzt. Cloudflare
    fungiert ausschließlich als Nameserver; der Website-Aufruf selbst erfolgt
    direkt an den Server in Deutschland und wird nicht über Cloudflare geleitet.
  </p>

  <h2>Keine Cookies, kein Tracking</h2>
  <p>
    Diese Website setzt keine Cookies, bindet keine externen Schriftarten,
    Skripte, Karten oder Analysedienste ein und führt keine Reichweitenmessung
    durch. Es findet keine Profilbildung statt.
  </p>

  <h2>Kontaktaufnahme</h2>
  <p>
    Bei Kontakt per E-Mail oder Telefon werden die übermittelten Daten zur
    Bearbeitung der Anfrage verarbeitet. Rechtsgrundlage ist Art. 6 Abs. 1
    lit. b bzw. lit. f DSGVO. Die Daten werden gelöscht, sobald der Zweck
    entfällt und keine Aufbewahrungspflichten entgegenstehen.
  </p>

  <h2>Ihre Rechte</h2>
  <p>
    Sie haben das Recht auf Auskunft (Art. 15), Berichtigung (Art. 16),
    Löschung (Art. 17), Einschränkung der Verarbeitung (Art. 18),
    Datenübertragbarkeit (Art. 20) und Widerspruch (Art. 21) sowie das Recht
    auf Beschwerde bei einer Aufsichtsbehörde (Art. 77 DSGVO). Zuständig ist
    PLATZHALTER zuständige Landesdatenschutzbehörde.
  </p>
</main>
```

**Wichtig:** Alle `PLATZHALTER`-Stellen müssen vor dem Livegang durch echte Angaben ersetzt werden. Sie sind absichtlich so auffällig geschrieben, dass sie in einem Review nicht übersehen werden.

- [x] **Step 6: Prüfskript laufen lassen und grün sehen**

Run: `./scripts/verify-assets.sh sites/thomaszachmann/public`

Expected: **Exit 0**, Ausgabe `OK: alle lokalen Referenzen in 3 HTML-Datei(en) aufgelöst.`

- [x] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(site): Site-Struktur, fehlende Assets und Asset-Check

index.html liegt jetzt unter sites/thomaszachmann/public/, damit Nyrvex
spaeter als zweite Site danebenpasst. Die in index.html referenzierten,
aber nie vorhandenen Fonts sind als variable woff2 von den offiziellen
OFL-Quellen ergaenzt. Impressum und Datenschutz sind als Geruest mit
klar markierten PLATZHALTER-Stellen angelegt.

verify-assets.sh prueft jede lokale href/src-Referenz gegen das
Dateisystem und laeuft lokal wie in CI identisch."
```

- [x] **Step 8: GitHub-Repo anlegen und pushen**

Alle folgenden Tasks brauchen ein erreichbares Remote — Flux liest daraus, Actions schreibt hinein.

```bash
gh repo create thomaszachmann.de --public --source=. --remote=origin --description "Website und Plattform: Terraform, k3s, Flux auf Hetzner Cloud"
git push -u origin main
```

Verifizieren:

```bash
gh repo view --json nameWithOwner,visibility,defaultBranchRef -q '"\(.nameWithOwner) \(.visibility) \(.defaultBranchRef.name)"'
```

Expected: `<owner>/thomaszachmann.de PUBLIC main`. Den tatsächlichen Owner notieren — er ersetzt in allen folgenden Tasks `thomaszachmann`, falls er abweicht.

**Branch Protection jetzt noch nicht einschalten.** Sie würde in Task 9 den Bot-Commit blockieren. Task 10 richtet sie mit dem passenden Bypass ein.

---

## Task 2: Container-Image, lokal verifiziert

**Files:**
- Create: `sites/thomaszachmann/Dockerfile`
- Create: `sites/thomaszachmann/nginx.conf`
- Create: `sites/thomaszachmann/.dockerignore`

**Interfaces:**
- Consumes: `sites/thomaszachmann/public/` und `scripts/verify-assets.sh` aus Task 1
- Produces: Ein Image, das auf Port **8080** als UID **101** lauscht, `/healthz` mit `200 ok` beantwortet und mit `readOnlyRootFilesystem` läuft, sofern `/tmp` und `/var/cache/nginx` beschreibbar gemountet sind. Task 7 baut darauf den Deployment-securityContext auf, Task 9 den Build-Job.

- [x] **Step 1: nginx.conf schreiben**

`sites/thomaszachmann/nginx.conf` — nur der Server-Block. Security-Header setzt bewusst Traefik, damit sie an einer Stelle für alle Sites gelten:

```nginx
server {
    listen       8080;
    listen  [::]:8080;
    server_name  _;

    root   /usr/share/nginx/html;
    index  index.html;

    # Keine Versionsnummer im Server-Header
    server_tokens off;

    # Health-Endpoint für die Kubernetes-Probes, ohne das Access-Log zu fluten
    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    # Self-hosted Fonts sind unveraenderlich: aggressiv cachen.
    # Bewusst KEINE expires-Direktive daneben: die erzeugt einen eigenen
    # Cache-Control-Header, und zwei davon nebeneinander sind mehrdeutig.
    location /fonts/ {
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        try_files $uri =404;
    }

    # HTML nie cachen. Sonst sieht ein wiederkehrender Besucher nach einem
    # Deploy weiter die alte Seite, und niemand versteht warum.
    location / {
        add_header Cache-Control "no-cache" always;
        try_files $uri $uri/ =404;
    }

    gzip on;
    gzip_vary on;
    gzip_min_length 512;
    gzip_types text/plain text/css application/javascript image/svg+xml;
    # woff2 ist intern schon Brotli-komprimiert. Erneutes gzip kostet CPU
    # und bringt keine Bytes, deshalb steht font/woff2 hier nicht.
}
```

- [x] **Step 2: Dockerfile und .dockerignore schreiben**

`sites/thomaszachmann/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1

# nginx-unprivileged statt nginx: laeuft durchgehend als UID 101 und startet
# nie als root. Erst das macht runAsNonRoot + readOnlyRootFilesystem moeglich.
# Der Master-Prozess dieses Images legt seine PID unter /tmp ab, nicht /run.
FROM nginxinc/nginx-unprivileged:1.31.4-alpine

COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 public/ /usr/share/nginx/html/

EXPOSE 8080
```

`sites/thomaszachmann/.dockerignore`:

```
Dockerfile
.dockerignore
```

- [x] **Step 3: Image bauen**

```bash
docker build -t tz-site:dev sites/thomaszachmann
```

Hier bewusst **ohne** `--platform`: der lokale Test läuft nativ und damit schnell. Für den Push nach GHCR in Task 7 gilt das Gegenteil — dort muss `linux/amd64` erzwungen werden, weil der Zielknoten x86_64 ist.

Expected: Build erfolgreich. Bei `failed to solve: nginxinc/nginx-unprivileged:1.31.4-alpine: not found` ist der Tag zurückgezogen worden — dann die verfügbaren Tags prüfen (`curl -s 'https://hub.docker.com/v2/repositories/nginxinc/nginx-unprivileged/tags?page_size=100&name=alpine'`) und die nächsthöhere Patch-Version des 1.31er-Zweigs pinnen. Nicht auf `alpine` ausweichen.

- [x] **Step 4: Container starten und alle Endpunkte prüfen**

Der Test läuft bewusst mit `--read-only`, damit die Härtung aus Task 7 hier schon belegt ist und nicht erst im Cluster auffällt.

```bash
docker run -d --name tz-site-test -p 8081:8080 \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /var/cache/nginx \
  tz-site:dev
sleep 2

for path in / /index.html /impressum.html /datenschutz.html \
            /fonts/outfit.woff2 /fonts/jetbrains-mono.woff2 /healthz; do
  printf '%-32s %s\n' "$path" "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "http://localhost:8081$path")"
done
printf '%-32s %s\n' "/gibtesnicht" "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8081/gibtesnicht)"
echo "--- laeuft als ---"
docker exec tz-site-test id
```

Expected:
- alle sieben Pfade `200`
- `/fonts/*.woff2` mit Content-Type `font/woff2`
- `/gibtesnicht` → `404`
- `id` zeigt `uid=101(nginx)`, **nicht** `uid=0(root)`

Zusätzlich prüfen, dass `Cache-Control` **genau einmal** gesetzt ist — nginx sendet sonst still zwei widersprüchliche Header:

```bash
curl -sI http://localhost:8081/                     | grep -ic '^cache-control'
curl -sI http://localhost:8081/fonts/outfit.woff2   | grep -ic '^cache-control'
curl -sI http://localhost:8081/                     | grep -iE '^(cache-control|server)'
```

Expected: beide Zählungen `1`, HTML mit `no-cache`, und `Server: nginx` **ohne** Versionsnummer (`server_tokens off` wirkt).

- [x] **Step 5: Aufräumen und committen**

```bash
docker rm -f tz-site-test
git add sites/thomaszachmann/Dockerfile sites/thomaszachmann/nginx.conf sites/thomaszachmann/.dockerignore
git commit -m "feat(site): Container-Image auf Basis von nginx-unprivileged

Laeuft als UID 101 auf Port 8080 und ueberlebt readOnlyRootFilesystem,
sofern /tmp und /var/cache/nginx beschreibbar gemountet sind. Lokal mit
docker --read-only verifiziert, damit die Haertung nicht erst im Cluster
auffaellt.

nginx.conf setzt bewusst keine Security-Header: die kommen zentral von
Traefik, damit sie fuer alle Sites gelten. HTML wird nicht gecacht,
Fonts dafuer ein Jahr als immutable."
git push
```

---

## Task 3: Terraform-Code, validiert und geplant — noch kein Apply

Dieser Task erzeugt Kosten von null. Er endet mit einem gelesenen `plan`, nicht mit laufender Infrastruktur, damit ein Reviewer die Firewall vor dem ersten Byte Traffic ablehnen kann.

**Files:**
- Create: `terraform/providers.tf`, `terraform/variables.tf`, `terraform/main.tf`, `terraform/firewall.tf`, `terraform/dns.tf`, `terraform/outputs.tf`, `terraform/cloud-init.yaml.tftpl`, `terraform/terraform.tfvars.example`, `terraform/.tflint.hcl`
- Create: `scripts/verify-cloud-init.sh`
- Commit: `terraform/.terraform.lock.hcl` — der Lockfile pinnt die Provider-Hashes und gehoert ins Repo, nicht in die .gitignore

**Interfaces:**
- Consumes: nichts aus vorherigen Tasks
- Produces: Outputs `ipv4`, `ipv6`, `ssh_command`, `kube_tunnel_command`, `fetch_kubeconfig_command`. Task 4 verwendet sie. Der Node heißt `tz-web-01`, der Admin-Benutzer kommt aus `var.node_user` (Default `tz`).

- [x] **Step 1: providers.tf**

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.24"
    }
  }
}

# Beide Provider ziehen ihr Token bewusst aus der Umgebung
# (HCLOUD_TOKEN bzw. CLOUDFLARE_API_TOKEN) und nicht aus einer Variable.
# So kann kein Token versehentlich in terraform.tfvars oder im State-Diff landen.
provider "hcloud" {}

provider "cloudflare" {}
```

- [x] **Step 2: variables.tf**

```hcl
variable "domain" {
  description = "Apex-Domain der Website."
  type        = string
  default     = "thomaszachmann.de"
}

variable "cloudflare_zone_id" {
  description = "Zone-ID der Domain. Cloudflare-Dashboard, Zonenuebersicht, rechte Spalte."
  type        = string
}

variable "admin_ip_cidrs" {
  description = "CIDRs, die per SSH auf den Node duerfen. Eigene IP: curl -s https://ifconfig.me"
  type        = list(string)

  validation {
    condition     = length(var.admin_ip_cidrs) > 0
    error_message = "Mindestens ein CIDR ist noetig, sonst ist der Node nicht administrierbar."
  }

  validation {
    condition     = !contains(var.admin_ip_cidrs, "0.0.0.0/0") && !contains(var.admin_ip_cidrs, "::/0")
    error_message = "SSH fuer 0.0.0.0/0 oder ::/0 zu oeffnen hebt den Sinn der Firewall auf."
  }
}

variable "ssh_key_name" {
  description = "Name eines bereits im Hetzner-Projekt hinterlegten SSH-Keys. Wird referenziert, nicht angelegt."
  type        = string
}

variable "node_user" {
  description = "Nicht-Root-Benutzer auf dem Node."
  type        = string
  default     = "tz"
}

variable "server_type" {
  description = "Hetzner-Servertyp. cx33 = 4 vCPU, 8 GB, 80 GB NVMe."
  type        = string
  default     = "cx33"
}

variable "location" {
  description = "Hetzner-Standort."
  type        = string
  default     = "fsn1"
}

variable "os_image" {
  description = "Basis-Image des Nodes."
  type        = string
  default     = "ubuntu-24.04"
}

variable "k3s_version" {
  description = "Gepinnte k3s-Version. Channel 'stable' am 2026-08-26."
  type        = string
  default     = "v1.36.3+k3s1"
}

variable "node_name" {
  description = "Name des Servers und des Kubernetes-Nodes. Muss zu --node-name im cloud-init passen."
  type        = string
  default     = "tz-web-01"
}
```

Die Validierungsbloecke sind nicht Zierde. `admin_ip_cidrs` ohne Praefixlaenge (also `203.0.113.7` statt `203.0.113.7/32`) nimmt der Provider stillschweigend an und die Regel greift dann nicht wie erwartet; und eine Cloudflare-**Account**-ID anstelle der **Zone**-ID ist eine Verwechslung, die man sonst erst am fehlgeschlagenen Apply merkt. Beide werden deshalb hier abgefangen.

- [x] **Step 3: main.tf**

**Der SSH-Key wird referenziert, nicht angelegt.** Hetzner lehnt einen zweiten Key mit gleichem Fingerprint ab — wer den Rechner schon einmal mit diesem Projekt verbunden hat, laeuft sonst in `SSH key with the same fingerprint already exists`. Wichtiger noch: existiert der Key bereits, benutzen ihn womoeglich andere Server im selben Projekt. Wuerde Terraform ihn besitzen, koennte ein `destroy` deren Zugang mitreissen.

Vorhandene Keys auflisten:

```bash
curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  https://api.hetzner.cloud/v1/ssh_keys | jq -r '.ssh_keys[] | "\(.name)  \(.fingerprint)"'
```

Ist der eigene Key noch nicht dabei, einmalig ueber die Hetzner-Konsole oder `hcloud ssh-key create` hinterlegen — bewusst ausserhalb von Terraform.

```hcl
data "hcloud_ssh_key" "admin" {
  name = var.ssh_key_name
}

# Die Primary IPs sind bewusst eigene Ressourcen und nicht Teil des Servers.
# Sie sind der stabile Anker, auf den DNS zeigt: der Server darf jederzeit
# weggeworfen und neu gebaut werden, ohne dass sich die IP aendert.
# delete_protection verhindert, dass ein unbedachtes destroy den Anker mitnimmt.
resource "hcloud_primary_ip" "v4" {
  name              = "${var.node_name}-v4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = true

  labels = { site = "thomaszachmann" }
}

resource "hcloud_primary_ip" "v6" {
  name              = "${var.node_name}-v6"
  type              = "ipv6"
  location          = var.location
  auto_delete       = false
  delete_protection = true

  labels = { site = "thomaszachmann" }
}

resource "hcloud_server" "web" {
  name        = "tz-web-01"
  server_type = var.server_type
  image       = var.os_image
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.v4.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.v6.id
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    node_user   = var.node_user
    ssh_pubkey  = trimspace(data.hcloud_ssh_key.admin.public_key)
    k3s_version = var.k3s_version
    tls_san     = hcloud_primary_ip.v4.ip_address
  })

  labels = {
    role = "k3s-server"
    site = "thomaszachmann"
  }

  # Der hcloud-Provider ersetzt den Server, sobald sich ssh_keys aendert.
  # Da der Zugang nach dem ersten Boot ohnehin ueber cloud-init verwaltet
  # wird, waere das ein Rebuild ohne Gegenwert.
  #
  # user_data steht bewusst NICHT hier: eine geaenderte Node-Konfiguration
  # SOLL den Server ersetzen, denn das ist der einzige Weg, sie anzuwenden.
  lifecycle {
    ignore_changes = [ssh_keys]
  }
}
```

- [x] **Step 4: firewall.tf**

```hcl
# Die Firewall laeuft auf Hetzner-Ebene, ausserhalb der VM. Zwei Gruende:
# k3s schreibt eigene nftables-Regeln fuer CNI und Services, ein Host-Firewall
# darueber ist eine bekannte Fehlerquelle. Und eine Firewall, die ein
# kompromittierter Host nicht abschalten kann, ist die bessere Firewall.
#
# Sobald eine Firewall attached ist, gilt fuer eingehenden Verkehr
# Default-Deny. Was hier nicht steht, ist zu.
resource "hcloud_firewall" "web" {
  name = "tz-web"

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP, wird von Traefik permanent auf HTTPS umgeleitet"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_ip_cidrs
    description = "SSH nur von der Admin-IP"
  }

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP fuer Erreichbarkeitsdiagnose"
  }

  # Port 6443 fehlt hier absichtlich. Der kube-apiserver ist nicht aus dem
  # Internet erreichbar; Zugriff laeuft ueber ssh -L, siehe Output
  # kube_tunnel_command.
}

resource "hcloud_firewall_attachment" "web" {
  firewall_id = hcloud_firewall.web.id
  server_ids  = [hcloud_server.web.id]
}
```

- [x] **Step 5: dns.tf**

```hcl
locals {
  # Cloudflare-Provider v5 verlangt den vollen FQDN, nicht "@" fuer den Apex.
  dns_names = {
    apex = var.domain
    www  = "www.${var.domain}"
  }
}

resource "cloudflare_dns_record" "a" {
  for_each = local.dns_names

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "A"
  content = hcloud_primary_ip.v4.ip_address
  ttl     = 300

  # DNS-only: Cloudflare loest nur auf, der Traffic geht direkt an Hetzner.
  # Ein Proxy hier wuerde den Besucherverkehr ueber einen US-Anbieter leiten
  # und der DSGVO-Argumentation der Website widersprechen.
  proxied = false
  comment = "Terraform: k3s-Node ${var.location}"
}

resource "cloudflare_dns_record" "aaaa" {
  for_each = local.dns_names

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "AAAA"

  # Bewusst die Server-Adresse und nicht hcloud_primary_ip.v6.ip_address:
  # letzteres ist bei IPv6 das /64-Netz, nicht die konkrete Adresse des Hosts.
  content = hcloud_server.web.ipv6_address
  ttl     = 300
  proxied = false
  comment = "Terraform: k3s-Node ${var.location}"
}
```

- [x] **Step 6: cloud-init.yaml.tftpl**

Vorsicht beim Bearbeiten: Die Datei wird durch `templatefile` gerendert. `${...}` und `%{...}` sind Interpolationen. Literale Dollar-Klammern müssten als `$${...}` geschrieben werden — deshalb benutzen die Shell-Schnipsel unten `$(...)` und `$i`, nie `${i}`.

```yaml
#cloud-config
package_update: true
package_upgrade: true

packages:
  - unattended-upgrades
  - curl
  - ca-certificates

users:
  - name: ${node_user}
    groups: [sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - ${ssh_pubkey}

write_files:
  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    permissions: "0644"
    content: |
      PasswordAuthentication no
      PermitRootLogin prohibit-password
      KbdInteractiveAuthentication no
      X11Forwarding no

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    permissions: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

runcmd:
  - systemctl restart ssh || systemctl restart sshd

  # k3s-Installation. --disable=traefik, weil Traefik von Flux kommt: sonst
  # laege ein Teil des Cluster-Zustands in einer HelmChartConfig auf dem Node
  # und Git waere nicht mehr die ganze Wahrheit.
  # --secrets-encryption verschluesselt Secrets at rest statt sie nur zu
  # base64-kodieren.
  - |
    curl -sfL https://get.k3s.io \
      | INSTALL_K3S_VERSION="${k3s_version}" sh -s - server \
          --disable=traefik \
          --secrets-encryption \
          --write-kubeconfig-mode=0600 \
          --tls-san=${tls_san} \
          --node-name=tz-web-01

  # Bewusst begrenzt warten statt endlos: ein haengendes cloud-init ist
  # schwerer zu diagnostizieren als ein sichtbar fehlgeschlagenes.
  - |
    for i in $(seq 1 60); do
      if k3s kubectl get node --no-headers 2>/dev/null | grep -q ' Ready '; then
        touch /var/lib/cloud/k3s-ready
        break
      fi
      sleep 5
    done
```

- [x] **Step 7: outputs.tf**

```hcl
output "ipv4" {
  description = "Primary IPv4 des Nodes. Stabil ueber Server-Rebuilds hinweg."
  value       = hcloud_primary_ip.v4.ip_address
}

output "ipv6" {
  description = "IPv6-Adresse des Nodes."
  value       = hcloud_server.web.ipv6_address
}

output "ssh_command" {
  description = "SSH-Zugang zum Node."
  value       = "ssh ${var.node_user}@${hcloud_primary_ip.v4.ip_address}"
}

output "kube_tunnel_command" {
  description = "Tunnel zum kube-apiserver. In einem eigenen Terminal offen halten."
  value       = "ssh -N -L 6443:127.0.0.1:6443 ${var.node_user}@${hcloud_primary_ip.v4.ip_address}"
}

output "fetch_kubeconfig_command" {
  description = "kubeconfig holen. Sie zeigt bereits auf 127.0.0.1:6443 und passt damit zum Tunnel."
  value       = "ssh ${var.node_user}@${hcloud_primary_ip.v4.ip_address} sudo cat /etc/rancher/k3s/k3s.yaml > kubeconfig && chmod 600 kubeconfig"
}
```

- [x] **Step 8: terraform.tfvars.example**

```hcl
# Kopieren nach terraform.tfvars (gitignored) und ausfuellen.
# Tokens gehoeren NICHT hierher, sondern in die Umgebung:
#   export HCLOUD_TOKEN=...
#   export CLOUDFLARE_API_TOKEN=...   # Scope: Zone:DNS:Edit auf diese Zone

cloudflare_zone_id = "hier-die-zone-id-aus-dem-cloudflare-dashboard"

# Eigene IP ermitteln: curl -s https://ifconfig.me
admin_ip_cidrs = ["203.0.113.7/32"]

ssh_key_name = "dein-key-name"
```

- [x] **Step 9: Formatierung und Validierung**

```bash
cd terraform
terraform fmt -check -recursive || terraform fmt -recursive
terraform init
terraform validate
```

Expected: `Success! The configuration is valid.`

Zusätzlich statische Analyse. `tflint` findet Dinge, die `validate` nicht sieht — etwa einen Servertyp, den es bei Hetzner nicht gibt, oder eine Variable ohne Beschreibung:

```bash
# tflint kommt aus mise.toml (siehe Voraussetzungen), hier nur absichern:
mise exec -- tflint --version >/dev/null || mise install

cat > .tflint.hcl <<'TFLINT'
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
TFLINT

tflint --init
tflint
```

Expected: keine Findings. Meldet `tflint` etwas, ist es zu beheben und nicht zu unterdrücken.

Häufigster Fehlschlag hier: ein Attribut aus einem v4-Cloudflare-Beispiel (`value` statt `content`, fehlendes `ttl`, `name = "@"`). Die Meldung nennt die Zeile.

- [x] **Step 9b: cloud-init-Template tatsaechlich rendern**

`terraform validate` prueft HCL-Syntax, rendert `templatefile()` aber **nie**. Ein unescaptes Dollar-Zeichen im Template faellt damit erst bei `plan` auf — ein Einrueckungsfehler sogar erst, wenn der Server bootet und cloud-init die Datei stillschweigend verwirft. Beides sind teure Zeitpunkte.

Deshalb ein eigener Pruefer, `scripts/verify-cloud-init.sh`. Er rendert das Template mit Dummy-Werten, prueft dass das Ergebnis mit `#cloud-config` beginnt und gueltiges YAML ist, und stellt sicher, dass alle fuenf k3s-Flags sowie die sshd-Haertung im gerenderten Ergebnis stehen.

```bash
./scripts/verify-cloud-init.sh terraform
```

Expected: `OK: cloud-init rendert zu gueltigem YAML, alle k3s-Flags und die sshd-Haertung sind enthalten.`

**Eine Falle, die genau hier zuschlaegt:** Der Template-Parser kennt keine YAML-Kommentare. Eine Dollar-Klammer in einer Kommentarzeile — etwa in einem gut gemeinten Hinweis "nicht so schreiben: DOLLAR-Klammer-i" — wird als Interpolation gelesen und bricht mit `There is no variable named "i"` ab. Im Template darf diese Schreibweise deshalb nirgends vorkommen, auch nicht erklaerend.

Zweite Falle: `terraform console` wertet **zeilenweise** aus. Der `templatefile()`-Aufruf muss einzeilig sein, sonst kommt `Expected the start of an expression, but found the end of the file`.

- [x] **Step 10: Plan lesen — nicht anwenden**

```bash
export HCLOUD_TOKEN=...
export CLOUDFLARE_API_TOKEN=...
cp terraform.tfvars.example terraform.tfvars   # und ausfuellen
terraform plan -out=tfplan
```

Expected: **`Plan: 9 to add, 0 to change, 0 to destroy.`** — fuenf Hetzner-Ressourcen (`hcloud_primary_ip.v4`, `hcloud_primary_ip.v6`, `hcloud_server.web`, `hcloud_firewall.web`, `hcloud_firewall_attachment.web`) plus vier DNS-Records (je ein A und ein AAAA fuer Apex und `www`). Der SSH-Key zaehlt nicht mit, er ist eine Data-Source.

Den Plan durchlesen, insbesondere die Firewall-Regeln: `port = "22"` muss ein `/32` in `source_ips` haben und nicht `0.0.0.0/0`.

**Wenn im Projekt bereits andere Ressourcen liegen**, vorher auf Namenskollisionen pruefen — Terraform bricht sonst mitten im Apply ab:

```bash
for r in servers firewalls primary_ips ssh_keys; do
  echo "--- $r ---"
  curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/$r" | jq -r ".$r[].name"
done
```

Belegt sein duerfen `tz-web-01`, `tz-web`, `tz-web-01-v4` und `tz-web-01-v6` nicht.

- [x] **Step 11: Commit**

```bash
cd ..
git add terraform/ .gitignore
git commit -m "feat(infra): Terraform fuer Node, Firewall, Primary IPs und DNS

Primary IPs sind eigene Ressourcen mit delete_protection: sie sind der
stabile DNS-Anker, damit der Server als Cattle weggeworfen und neu gebaut
werden kann, ohne dass DNS nachgezogen werden muss.

Firewall laeuft auf Hetzner-Ebene statt im Gast, damit sie nicht mit den
nftables-Regeln von k3s kollidiert und ein kompromittierter Host sie nicht
abschalten kann. Port 6443 ist bewusst zu, Zugriff nur ueber ssh -L.

DNS nutzt cloudflare_dns_record (Provider v5) mit content statt value und
vollem FQDN statt @. Noch nicht applied."
git push
```

---

## Task 4: Apply und Node-Verifikation

Ab hier entstehen Kosten. Der Task endet mit einem erreichbaren, leeren Cluster.

**Files:** keine neuen — dieser Task wendet Task 3 an.

**Interfaces:**
- Consumes: alle Outputs aus Task 3
- Produces: eine lokale `kubeconfig` im Repo-Wurzelverzeichnis (gitignored), die über den SSH-Tunnel funktioniert. Tasks 5–8 setzen `KUBECONFIG` darauf.

- [ ] **Step 1: Anwenden**

```bash
cd terraform
terraform apply tfplan
```

Expected: `Apply complete! Resources: 10 added, 0 changed, 0 destroyed.` und die fünf Outputs.

- [ ] **Step 2: Warten, bis cloud-init durch ist**

Der Server antwortet auf SSH, bevor k3s läuft. Ohne Warten scheitert der nächste Schritt und man sucht den Fehler an der falschen Stelle.

```bash
SSH_TARGET="$(terraform output -raw ssh_command | sed 's/^ssh //')"
ssh -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
  'sudo cloud-init status --wait; ls -l /var/lib/cloud/k3s-ready'
```

Expected: `status: done` und die Datei `/var/lib/cloud/k3s-ready` existiert.

Wenn `k3s-ready` fehlt, ist die Warteschleife in 60 Versuchen à 5 s nicht fertig geworden. Diagnose auf dem Node:

```bash
ssh "$SSH_TARGET" 'sudo cat /var/log/cloud-init-output.log | tail -50; sudo systemctl status k3s --no-pager'
```

- [ ] **Step 3: kubeconfig holen**

```bash
cd ..
eval "$(cd terraform && terraform output -raw fetch_kubeconfig_command)"
ls -l kubeconfig
```

Expected: Datei mit Rechten `600`.

- [ ] **Step 4: Tunnel öffnen und Cluster prüfen**

Der Tunnel muss in einem **eigenen Terminal** offen bleiben — Port 6443 ist von außen zu.

```bash
# Terminal A:
cd terraform && terraform output -raw kube_tunnel_command   # ausgeben und ausfuehren

# Terminal B:
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
kubectl get pods -A
```

Expected:
- ein Node `tz-web-01` im Status `Ready`, Version `v1.36.3+k3s1`
- laufende Pods: `coredns`, `local-path-provisioner`, `metrics-server`, `svclb-*`
- **kein** `traefik`-Pod — der ist per `--disable=traefik` abgeschaltet und kommt in Task 6 aus Flux

Wenn ein Traefik-Pod auftaucht, hat das `--disable`-Flag nicht gegriffen. Dann ist die k3s-Installation zu wiederholen, nicht der Pod zu löschen — er käme wieder.

- [ ] **Step 5: Firewall von außen gegenprüfen**

Das ist der Test für die sicherheitskritischste Entscheidung des Setups.

```bash
IP="$(cd terraform && terraform output -raw ipv4)"
nc -z -w 5 "$IP" 6443 && echo "FEHLER: 6443 ist offen" || echo "OK: 6443 ist zu"
nc -z -w 5 "$IP" 22   && echo "OK: 22 von hier erreichbar" || echo "FEHLER: SSH nicht erreichbar"
```

Expected: `OK: 6443 ist zu` und `OK: 22 von hier erreichbar`.

- [ ] **Step 6: DNS-Auflösung prüfen**

```bash
dig +short thomaszachmann.de A
dig +short thomaszachmann.de AAAA
dig +short www.thomaszachmann.de A
```

Expected: die IPs aus den Terraform-Outputs. Bei leerer Antwort sind entweder die Cloudflare-Nameserver für die Domain noch nicht aktiv, oder `cloudflare_zone_id` zeigt auf die falsche Zone.

- [ ] **Step 7: Zustand festhalten**

Kein Code-Commit — aber die IPs gehören dokumentiert, weil Task 8 und 10 sie brauchen.

```bash
cd terraform && terraform output
```

State-Backup anlegen (der State liegt lokal und ist gitignored):

```bash
cp terraform/terraform.tfstate ~/Dropbox/backup/tz-terraform.tfstate.$(date +%Y%m%d)
```

---

## Task 5: SOPS, age und Flux-Bootstrap

**Files:**
- Create: `.sops.yaml`
- Create: `clusters/prod/infrastructure.yaml`
- Create: `clusters/prod/apps.yaml`
- Erzeugt durch `flux bootstrap`: `clusters/prod/flux-system/`

**Interfaces:**
- Consumes: erreichbarer Cluster aus Task 4, GitHub-Repo aus Task 1
- Produces: drei Flux-Kustomizations mit fester Reihenfolge — `infra-controllers` → `infra-configs` → `apps`. Das Cluster-Secret `sops-age` in `flux-system` entschlüsselt alles unter `infrastructure/configs/`. Tasks 6 und 7 legen Dateien in die Pfade, die diese Kustomizations lesen.

- [ ] **Step 1: age-Schlüsselpaar erzeugen**

```bash
age-keygen -o age.key
grep 'public key' age.key
```

Der öffentliche Schlüssel (`age1...`) kommt ins Repo. Der private bleibt lokal — `age.key` ist bereits in `.gitignore`.

**Sofort sichern:** Den Inhalt von `age.key` in den Passwortmanager kopieren. Er ist das einzige Artefakt dieses Setups, dessen Verlust nicht durch `terraform apply` heilbar ist — ohne ihn sind die verschlüsselten Secrets im Repo unbrauchbar.

- [ ] **Step 2: .sops.yaml anlegen**

`AGE_PUBLIC_KEY` durch den Wert aus Step 1 ersetzen.

```yaml
# Nur Werte werden verschluesselt, nie Keys. Dadurch bleiben Diffs im Repo
# lesbar: man sieht, dass sich ein Secret geaendert hat, ohne es zu sehen.
creation_rules:
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: AGE_PUBLIC_KEY
```

- [ ] **Step 3: Privaten Schlüssel als Cluster-Secret hinterlegen**

```bash
export KUBECONFIG="$PWD/kubeconfig"     # Tunnel muss offen sein
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=age.key
```

Der Dateiname im Secret **muss** auf `.agekey` enden — Flux sucht genau danach.

```bash
kubectl -n flux-system get secret sops-age -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2
```

Expected: `age.agekey`.

- [ ] **Step 4: Flux bootstrappen**

```bash
export GITHUB_TOKEN=...   # Scope: repo
flux bootstrap github \
  --owner=thomaszachmann \
  --repository=thomaszachmann.de \
  --branch=main \
  --path=clusters/prod \
  --personal \
  --version=v2.9.4
```

`--owner` gegebenenfalls durch den in Task 1 notierten echten Owner ersetzen.

Der Deploy-Key, den Flux anlegt, ist **read-only** — das ist der Default und genau das, was wir wollen: der Cluster kann nicht in das Repo schreiben. Das Schreiben erledigt in Task 9 ausschließlich GitHub Actions.

Expected: Am Ende `all components are healthy`.

- [ ] **Step 5: Bootstrap verifizieren**

```bash
flux check
kubectl -n flux-system get pods
git pull   # der Bootstrap hat nach main committet
```

Expected: `source-controller`, `kustomize-controller`, `helm-controller`, `notification-controller` laufen. Im Repo liegt neu `clusters/prod/flux-system/`.

- [ ] **Step 6: Die drei Kustomizations definieren**

Getrennte Kustomizations statt einer einzigen, weil ein ClusterIssuer die cert-manager-CRDs braucht. In einer gemeinsamen Kustomization wäre das ein Wettlauf, der beim ersten Reconcile zuverlässig scheitert und sich erst beim Retry fängt — laut, verwirrend und vermeidbar.

`clusters/prod/infrastructure.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-controllers
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 1m
  timeout: 10m
  path: ./infrastructure/controllers
  prune: true
  wait: true          # erst fertig, wenn Traefik und cert-manager wirklich laufen
  sourceRef:
    kind: GitRepository
    name: flux-system
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra-configs
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-controllers
  interval: 1h
  retryInterval: 1m
  timeout: 5m
  path: ./infrastructure/configs
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

`clusters/prod/apps.yaml`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  dependsOn:
    - name: infra-configs
  # Kurzes Intervall: das ist der Pfad, ueber den ein Deploy ankommt.
  interval: 1m
  retryInterval: 1m
  timeout: 5m
  path: ./apps/prod
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

- [ ] **Step 7: Committen und beobachten, dass Flux die Pfade noch nicht findet**

```bash
git add .sops.yaml clusters/
git commit -m "feat(flux): Bootstrap und Kustomization-Reihenfolge

infra-controllers vor infra-configs vor apps. Die Trennung existiert,
damit ein ClusterIssuer nicht gegen noch nicht installierte cert-manager
CRDs laeuft. SOPS-Entschluesselung haengt an infra-configs, weil dort das
einzige verschluesselte Secret liegt.

Der Flux-Deploy-Key ist bewusst read-only: ins Repo schreibt spaeter nur
GitHub Actions, nie der Cluster."
git push
flux reconcile source git flux-system
flux get kustomizations
```

Expected: `infra-controllers` meldet einen Fehler, weil `./infrastructure/controllers` noch nicht existiert. Das ist korrekt und wird in Task 6 behoben. `apps` bleibt wegen `dependsOn` unangetastet — genau das soll die Reihenfolge bewirken.

---

## Task 6: Traefik, cert-manager und ClusterIssuer

**Files:**
- Create: `infrastructure/controllers/kustomization.yaml`, `traefik.yaml`, `cert-manager.yaml`
- Create: `infrastructure/configs/kustomization.yaml`, `cluster-issuers.yaml`, `middlewares.yaml`, `cloudflare-token.sops.yaml`

**Interfaces:**
- Consumes: die Kustomizations aus Task 5
- Produces: IngressClass `traefik` (Default), ClusterIssuer `letsencrypt-staging` und `letsencrypt-prod`, sowie zwei Middlewares im Namespace `traefik`: `security-headers` und `www-redirect`. Task 7 referenziert sie über die Annotation `traefik.ingress.kubernetes.io/router.middlewares: traefik-security-headers@kubernetescrd,traefik-www-redirect@kubernetescrd`.

- [ ] **Step 1: Traefik-HelmRelease**

`infrastructure/controllers/traefik.yaml`. Der Values-Block ist absichtlich klein: `ingressClass.enabled`, `isDefaultClass`, `deployment.replicas: 1`, `service.spec.type: LoadBalancer` und `websecure.tls.enabled` sind im Chart 41.3.0 bereits Default und werden deshalb nicht wiederholt.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 24h
  url: https://traefik.github.io/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 1h
  targetNamespace: traefik
  install:
    createNamespace: true
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  chart:
    spec:
      chart: traefik
      version: "41.3.0"
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: flux-system
  values:
    providers:
      kubernetesCRD:
        enabled: true
        # Erlaubt der Site-Ingress im Namespace web-thomaszachmann, die
        # Middlewares im Namespace traefik zu referenzieren. Ohne das muesste
        # jede Site ihre eigenen Header-Regeln mitbringen — und sie wuerden
        # auseinanderlaufen.
        allowCrossNamespace: true
      kubernetesIngress:
        enabled: true

    ports:
      web:
        http:
          redirections:
            entryPoint:
              to: websecure
              scheme: https
              permanent: true

    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        memory: 192Mi
```

**Achtung beim Redirect-Pfad:** Der Key liegt unter `ports.web.http.redirections.entryPoint` — mit dem `http`-Zwischenschritt. Ältere Beispiele und ein Changelog-Diff im Chart-Repo zeigen ihn ohne `http`; das ist für 41.3.0 falsch und wird stillschweigend ignoriert, sodass HTTP dann einfach nicht umleitet.

- [ ] **Step 2: cert-manager-HelmRelease**

`infrastructure/controllers/cert-manager.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: jetstack
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.jetstack.io
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
  namespace: flux-system
spec:
  interval: 1h
  targetNamespace: cert-manager
  install:
    createNamespace: true
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  chart:
    spec:
      chart: cert-manager
      version: "v1.21.1"
      sourceRef:
        kind: HelmRepository
        name: jetstack
        namespace: flux-system
  values:
    crds:
      # crds.enabled, NICHT installCRDs — das ist seit 1.15 deprecated und
      # wird stillschweigend ignoriert, worauf die CRDs schlicht fehlen.
      enabled: true
      # Verhindert, dass ein Uninstall die CRDs und damit alle Certificates
      # mitnimmt.
      keep: true

    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 128Mi
```

`infrastructure/controllers/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - traefik.yaml
  - cert-manager.yaml
```

- [ ] **Step 3: Controller ausrollen und prüfen**

```bash
git add infrastructure/controllers
git commit -m "feat(infra): Traefik und cert-manager als HelmRelease"
git push
flux reconcile kustomization infra-controllers --with-source
```

```bash
flux get helmreleases -A
kubectl -n traefik get pods,svc
kubectl -n cert-manager get pods
kubectl get ingressclass
```

Expected:
- beide HelmReleases `Ready: True`
- Service `traefik` vom Typ `LoadBalancer` mit der Node-IP als `EXTERNAL-IP` (das liefert k3s' ServiceLB)
- IngressClass `traefik` mit `is-default-class: true`

Der Redirect lässt sich sofort prüfen, noch bevor eine Site existiert:

```bash
IP="$(cd terraform && terraform output -raw ipv4)"
curl -sI "http://$IP/" | head -3
```

Expected: `HTTP/1.1 308 Permanent Redirect` mit `Location: https://...`. Kommt stattdessen `404`, ist der Redirect-Value-Pfad falsch geschrieben — siehe Warnung in Step 1.

- [ ] **Step 4: Cloudflare-Token für cert-manager verschlüsselt ablegen**

Ein **zweites**, eigenes Token anlegen — nicht das aus Terraform wiederverwenden. Cloudflare-Dashboard → My Profile → API Tokens → Create Token → Custom, Permission `Zone / DNS / Edit`, Zone Resources auf genau diese Zone begrenzt. So hat ein kompromittierter Cluster nicht das Token, mit dem Terraform arbeitet.

`infrastructure/configs/cloudflare-token.sops.yaml` zunächst im Klartext schreiben:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: HIER-DAS-ZWEITE-CLOUDFLARE-TOKEN
```

Sofort verschlüsseln:

```bash
sops --encrypt --in-place infrastructure/configs/cloudflare-token.sops.yaml
grep -c 'ENC\[' infrastructure/configs/cloudflare-token.sops.yaml
head -8 infrastructure/configs/cloudflare-token.sops.yaml
```

Expected: mindestens ein `ENC[`-Treffer, und `api-token` ist unlesbar, während `apiVersion`, `kind` und `metadata` im Klartext bleiben.

**Nicht committen, bevor dieser Check grün ist.** Das Repo ist public — ein einmal gepushtes Klartext-Token ist kompromittiert, auch nach einem Force-Push.

- [ ] **Step 5: ClusterIssuer**

`infrastructure/configs/cluster-issuers.yaml`. `E-MAIL-ADRESSE` durch die echte ACME-Kontaktadresse ersetzen.

```yaml
# Zwei Issuer mit Absicht. Let's Encrypt erlaubt fuenf Zertifikate pro Domain
# und Woche; beim Einrichten ist das schneller aufgebraucht als man denkt.
# Erst gegen Staging verifizieren, dann in Task 8 auf Prod umstellen.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: E-MAIL-ADRESSE
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: E-MAIL-ADRESSE
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      # DNS-01 statt HTTP-01: die Validierung haengt damit nicht an der
      # Erreichbarkeit von Port 80, und Wildcards waeren moeglich, falls
      # spaeter *.lab.thomaszachmann.de fuer Demo-Workloads gebraucht wird.
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

- [ ] **Step 6: Middlewares**

`infrastructure/configs/middlewares.yaml`. Zentral im Traefik-Namespace, damit Nyrvex später dieselben Regeln bekommt, ohne sie zu duplizieren.

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: traefik
spec:
  headers:
    frameDeny: true
    contentTypeNosniff: true
    referrerPolicy: "strict-origin-when-cross-origin"
    stsSeconds: 31536000
    stsIncludeSubdomains: true
    forceSTSHeader: true
    # Die Seite laedt keinerlei externe Ressourcen: Fonts sind self-hosted,
    # das Favicon ist eine data:-URI. Deshalb kann default-src 'none' sein.
    # 'unsafe-inline' ist noetig, weil CSS und ein Script inline in der
    # index.html stehen. Das Auslagern in externe Dateien wuerde das
    # entfernen — es ist als Folgearbeit notiert und aendert Website-Inhalt,
    # gehoert also nicht in diesen Plan.
    contentSecurityPolicy: >-
      default-src 'none';
      img-src 'self' data:;
      style-src 'self' 'unsafe-inline';
      script-src 'self' 'unsafe-inline';
      font-src 'self';
      base-uri 'none';
      form-action 'none';
      frame-ancestors 'none'
    permissionsPolicy: "geolocation=(), microphone=(), camera=()"
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: www-redirect
  namespace: traefik
spec:
  # Kanonisch ist die Apex-Domain — passend zu og:url in der index.html.
  redirectRegex:
    regex: "^https://www\\.thomaszachmann\\.de/(.*)"
    replacement: "https://thomaszachmann.de/${1}"
    permanent: true
```

`infrastructure/configs/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cloudflare-token.sops.yaml
  - cluster-issuers.yaml
  - middlewares.yaml
```

- [ ] **Step 7: Ausrollen und Issuer-Bereitschaft prüfen**

```bash
git add infrastructure/configs
git commit -m "feat(infra): ClusterIssuer mit DNS-01 und zentrale Middlewares

Zwei Issuer, damit gegen Staging verifiziert werden kann, bevor das
Rate-Limit von Lets Encrypt beansprucht wird. Das Cloudflare-Token ist
ein zweites, eigenes Token mit Scope Zone:DNS:Edit und liegt SOPS-
verschluesselt im Repo — ein kompromittierter Cluster hat damit nicht
das Terraform-Token."
git push
flux reconcile kustomization infra-configs --with-source
```

```bash
kubectl get clusterissuer
kubectl -n cert-manager get secret cloudflare-api-token
```

Expected: beide ClusterIssuer mit `READY: True`. Ist einer `False`, zeigt `kubectl describe clusterissuer letsencrypt-staging` den Grund — fast immer ein Token mit zu engem Scope oder ein Tippfehler im Secret-Namen.

Prüfen, dass die Entschlüsselung wirklich stattgefunden hat und nicht der Chiffretext im Cluster liegt:

```bash
kubectl -n cert-manager get secret cloudflare-api-token -o jsonpath='{.data.api-token}' | base64 -d | head -c 8; echo
```

Expected: die ersten Zeichen des echten Tokens, nicht `ENC[`.

---

## Task 7: Die Site — mit Staging-Zertifikat

**Files:**
- Create: `apps/base/thomaszachmann/{kustomization,namespace,deployment,service,ingress,certificate,networkpolicy}.yaml`
- Create: `apps/prod/kustomization.yaml`

**Interfaces:**
- Consumes: IngressClass, ClusterIssuer und Middlewares aus Task 6; das Image aus Task 2
- Produces: Deployment `thomaszachmann` im Namespace `web-thomaszachmann` mit Label `app.kubernetes.io/name: thomaszachmann`. Der Image-Digest steht ausschließlich in `apps/prod/kustomization.yaml` unter `images[0].digest` — das ist die einzige Zeile, die Task 9 automatisiert schreibt.

- [ ] **Step 1: Image einmalig manuell bauen und pushen**

Henne-Ei: Das Deployment braucht einen Digest, bevor die Pipeline existiert. Also einmal von Hand.

**`--platform linux/amd64` ist hier nicht optional.** Ein Apple-Silicon-Mac baut standardmäßig `linux/arm64`; der CX33 ist x86_64. Ohne das Flag landet ein arm64-Image in GHCR, und der Pod stirbt mit `exec format error` — ausgerechnet beim allerersten Deploy, wo man die Ursache am wenigsten vermutet. (Der spätere CI-Build in Task 9 braucht das Flag nicht: `ubuntu-latest` ist bereits amd64.)

```bash
OWNER=thomaszachmann     # ggf. den echten Owner aus Task 1
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$OWNER" --password-stdin

docker build --platform linux/amd64 \
  -t "ghcr.io/$OWNER/thomaszachmann:bootstrap" sites/thomaszachmann
docker push "ghcr.io/$OWNER/thomaszachmann:bootstrap"

DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "ghcr.io/$OWNER/thomaszachmann:bootstrap" | cut -d@ -f2)"
echo "$DIGEST"
```

Expected: eine Zeile `sha256:...`. Diesen Wert in Step 7 einsetzen.

Vor dem Weitermachen die Architektur gegenprüfen — das kostet zwei Sekunden und spart eine halbe Stunde Fehlersuche:

```bash
docker image inspect "ghcr.io/$OWNER/thomaszachmann:bootstrap" --format '{{.Os}}/{{.Architecture}}'
```

Expected: `linux/amd64`. Steht dort `linux/arm64`, wurde das Flag vergessen.

Das Package anschließend im GitHub-UI auf **public** stellen (Repo → Packages → thomaszachmann → Package settings → Change visibility). Dadurch braucht der Cluster kein Pull-Secret — für eine öffentliche Website wäre eines Sicherheitstheater.

- [ ] **Step 2: Namespace und NetworkPolicy**

`apps/base/thomaszachmann/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: web-thomaszachmann
  labels:
    kubernetes.io/metadata.name: web-thomaszachmann
```

`apps/base/thomaszachmann/networkpolicy.yaml`:

```yaml
# Default-Deny in beide Richtungen. k3s setzt NetworkPolicies mit seinem
# eingebauten Controller durch — das hier ist keine Dekoration.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: web-thomaszachmann
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-traefik-ingress-and-dns
  namespace: web-thomaszachmann
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: thomaszachmann
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - port: 8080
          protocol: TCP
  egress:
    # Ein statischer Webserver braucht eigentlich gar kein Egress. DNS bleibt
    # offen, damit Diagnose im Fehlerfall ueberhaupt moeglich ist.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

- [ ] **Step 3: Deployment**

`apps/base/thomaszachmann/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thomaszachmann
  namespace: web-thomaszachmann
  labels:
    app.kubernetes.io/name: thomaszachmann
spec:
  # Zwei Replicas auf einem Node: nicht fuer Ausfallsicherheit, sondern damit
  # ein Rollout ohne Luecke durchlaeuft.
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: thomaszachmann
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: thomaszachmann
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          # Wird von apps/prod/kustomization.yaml auf einen Digest gepinnt.
          image: ghcr.io/thomaszachmann/thomaszachmann
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              # Bewusst kein CPU-Limit: es wuerde nur throtteln, ohne dass es
              # auf diesem Node etwas zu schuetzen gaebe.
              memory: 64Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 20
          volumeMounts:
            # Notwendig wegen readOnlyRootFilesystem: nginx-unprivileged legt
            # seine PID und temporaere Bodies unter /tmp ab.
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/nginx
      volumes:
        - name: tmp
          emptyDir: {}
        - name: cache
          emptyDir: {}
```

- [ ] **Step 4: Service**

`apps/base/thomaszachmann/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: thomaszachmann
  namespace: web-thomaszachmann
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: thomaszachmann
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
```

- [ ] **Step 5: Certificate — zunächst gegen Staging**

`apps/base/thomaszachmann/certificate.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: thomaszachmann-tls
  namespace: web-thomaszachmann
spec:
  secretName: thomaszachmann-tls
  issuerRef:
    kind: ClusterIssuer
    # Task 8 stellt das auf letsencrypt-prod um. Vorher nicht aendern:
    # das Rate-Limit von fuenf Zertifikaten pro Domain und Woche ist echt.
    name: letsencrypt-staging
  commonName: thomaszachmann.de
  dnsNames:
    - thomaszachmann.de
    - www.thomaszachmann.de
```

- [ ] **Step 6: Ingress**

`apps/base/thomaszachmann/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: thomaszachmann
  namespace: web-thomaszachmann
  annotations:
    # Namespace-Prefix und @kubernetescrd sind Pflicht. Funktioniert nur,
    # weil Traefik mit allowCrossNamespace: true laeuft (Task 6).
    traefik.ingress.kubernetes.io/router.middlewares: >-
      traefik-security-headers@kubernetescrd,traefik-www-redirect@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - thomaszachmann.de
        - www.thomaszachmann.de
      secretName: thomaszachmann-tls
  rules:
    - host: thomaszachmann.de
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: thomaszachmann
                port:
                  name: http
    - host: www.thomaszachmann.de
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: thomaszachmann
                port:
                  name: http
```

- [ ] **Step 7: Kustomizations**

`apps/base/thomaszachmann/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - networkpolicy.yaml
  - deployment.yaml
  - service.yaml
  - certificate.yaml
  - ingress.yaml
```

`apps/prod/kustomization.yaml` — `sha256:...` durch den Digest aus Step 1 ersetzen:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../base/thomaszachmann

# Diesen Digest schreibt ab Task 9 ausschliesslich GitHub Actions.
# Digest statt Tag, weil ein Tag verschiebbar ist: so steht im Repo exakt
# das, was laeuft.
images:
  - name: ghcr.io/thomaszachmann/thomaszachmann
    digest: sha256:HIER-DEN-DIGEST-AUS-STEP-1
```

- [ ] **Step 8: Ausrollen**

```bash
git add apps/
git commit -m "feat(site): thomaszachmann.de als Deployment, Service, Ingress

Laeuft als UID 101 mit readOnlyRootFilesystem, gedroppten Capabilities
und RuntimeDefault-seccomp. Default-Deny NetworkPolicy laesst nur Traefik
auf Port 8080 und DNS hinaus.

Zertifikat zunaechst gegen den Staging-Issuer, damit das Rate-Limit von
Lets Encrypt beim Einrichten nicht verbraucht wird."
git push
flux reconcile kustomization apps --with-source
```

- [ ] **Step 9: Rollout prüfen**

```bash
kubectl -n web-thomaszachmann get pods,svc,ingress,certificate
kubectl -n web-thomaszachmann describe certificate thomaszachmann-tls | tail -20
```

Expected:
- zwei Pods `Running`, `READY 1/1`
- Certificate `READY: True` (die DNS-01-Challenge dauert typischerweise 1–3 Minuten)

Bleibt das Certificate auf `False`, zeigt der Weg dorthin den Grund:

```bash
kubectl -n web-thomaszachmann get certificaterequest,order,challenge
kubectl -n web-thomaszachmann describe challenge
```

- [ ] **Step 10: Härtung im laufenden Pod belegen**

```bash
POD="$(kubectl -n web-thomaszachmann get pod -l app.kubernetes.io/name=thomaszachmann -o name | head -1)"
kubectl -n web-thomaszachmann exec "$POD" -- id
kubectl -n web-thomaszachmann exec "$POD" -- sh -c 'touch /probe 2>&1 || echo "OK: Root-FS ist read-only"'
```

Expected: `uid=101`, und der Schreibversuch scheitert mit `Read-only file system`.

Rechte des Service-Accounts prüfen — ein statischer Webserver braucht keine:

```bash
kubectl -n web-thomaszachmann auth can-i --list \
  --as=system:serviceaccount:web-thomaszachmann:default | head -20
```

Expected: nur `selfsubjectreviews` und `selfsubjectrulesreviews`. Taucht dort `secrets` oder `pods` auf, hängt ein RBAC-Binding, das nicht hierher gehört.

- [ ] **Step 10b: NetworkPolicy mit Test-Pods belegen**

Eine NetworkPolicy, die man nicht getestet hat, ist eine Vermutung. Der erste Test kommt aus einem **fremden** Namespace und muss scheitern:

```bash
SVC_IP="$(kubectl -n web-thomaszachmann get svc thomaszachmann -o jsonpath='{.spec.clusterIP}')"
echo "Service-IP: $SVC_IP"

kubectl -n default run netpol-probe --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 --command -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$SVC_IP/healthz" \
  || echo "OK: Zugriff aus fremdem Namespace blockiert"
```

Expected: **kein** `200`, sondern ein Abbruch nach 5 Sekunden. Kommt `200`, greift die Default-Deny-Policy nicht — dann prüfen, ob die Policies wirklich im Namespace `web-thomaszachmann` liegen (`kubectl -n web-thomaszachmann get networkpolicy`).

Gegenprobe aus dem erlaubten Namespace — hier **muss** es klappen, sonst ist die Policy zu streng und Traefik käme auch nicht durch:

```bash
kubectl -n traefik run netpol-probe-allowed --rm -i --restart=Never \
  --image=curlimages/curl:8.11.1 --command -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$SVC_IP/healthz"
```

Expected: `200`. Erst beide Proben zusammen belegen etwas: die eine, dass geblockt wird, die andere, dass nicht alles geblockt wird.

- [ ] **Step 11: HTTPS von außen — mit erwarteter Zertifikatswarnung**

```bash
curl -sSIk https://thomaszachmann.de/ | head -1
curl -sSI  https://thomaszachmann.de/ 2>&1 | head -3
```

Expected: mit `-k` ein `HTTP/2 200`; **ohne** `-k` ein Zertifikatsfehler, weil `(STAGING) Let's Encrypt` keine öffentlich vertraute CA ist. Genau das soll hier so sein — es beweist, dass die DNS-01-Kette funktioniert, ohne das Prod-Kontingent anzufassen.

```bash
echo | openssl s_client -connect thomaszachmann.de:443 -servername thomaszachmann.de 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

Expected: Issuer enthält `STAGING`.

---

## Task 8: Umstellung auf das Produktivzertifikat

**Files:**
- Modify: `apps/base/thomaszachmann/certificate.yaml` (`issuerRef.name`)

**Interfaces:**
- Consumes: funktionierende Staging-Ausstellung aus Task 7
- Produces: öffentlich vertrautes Zertifikat im Secret `thomaszachmann-tls`. Task 10 prüft es in der DR-Probe erneut.

- [ ] **Step 1: Issuer umstellen**

In `apps/base/thomaszachmann/certificate.yaml` genau eine Zeile ändern:

```yaml
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-prod
```

Den Kommentar über `issuerRef` auf den neuen Stand bringen:

```yaml
    # Produktivzertifikat. Vor Aenderungen an den dnsNames wieder auf
    # letsencrypt-staging wechseln — fuenf Ausstellungen pro Domain und Woche.
```

- [ ] **Step 2: Committen und altes Secret entfernen**

Das Secret muss weg, sonst sieht cert-manager ein gültiges Zertifikat und stellt nichts Neues aus.

```bash
git add apps/base/thomaszachmann/certificate.yaml
git commit -m "feat(site): auf Lets-Encrypt-Produktivzertifikat umstellen

Staging-Ausstellung hat funktioniert, damit ist die DNS-01-Kette ueber
die Cloudflare-API belegt. Erst jetzt wird das Prod-Kontingent angefasst."
git push
flux reconcile kustomization apps --with-source
kubectl -n web-thomaszachmann delete secret thomaszachmann-tls
```

- [ ] **Step 3: Neuausstellung abwarten**

```bash
kubectl -n web-thomaszachmann get certificate -w
```

Expected: `READY: True` innerhalb weniger Minuten. Mit Strg-C beenden.

- [ ] **Step 4: Die vollständige Abnahme von außen**

Das ist der Test, der belegt, dass Ziel 1 der Spec erreicht ist.

```bash
echo "--- 1. Zertifikat oeffentlich vertraut (ohne -k) ---"
curl -sSI https://thomaszachmann.de/ | head -1

echo "--- 2. Aussteller und Laufzeit ---"
echo | openssl s_client -connect thomaszachmann.de:443 -servername thomaszachmann.de 2>/dev/null \
  | openssl x509 -noout -issuer -dates

echo "--- 3. HTTP leitet permanent um ---"
curl -sSI http://thomaszachmann.de/ | grep -Ei '^(HTTP|location)'

echo "--- 4. www leitet auf den Apex um ---"
curl -sSI https://www.thomaszachmann.de/ | grep -Ei '^(HTTP|location)'

echo "--- 5. Security-Header ---"
curl -sSI https://thomaszachmann.de/ | grep -Ei 'strict-transport|content-security|x-frame|x-content-type|referrer-policy|permissions-policy'

echo "--- 6. Alle Seiten und Assets ---"
for p in / /impressum.html /datenschutz.html /fonts/outfit.woff2 /fonts/jetbrains-mono.woff2; do
  printf '%-32s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' "https://thomaszachmann.de$p")"
done

echo "--- 7. Ueber IPv6 erreichbar ---"
curl -s -6 -o /dev/null -w '%{http_code}\n' https://thomaszachmann.de/ || echo "(kein IPv6 auf diesem Client — dann von einem anderen Netz pruefen)"
```

Expected:
1. `HTTP/2 200` ohne Zertifikatsfehler
2. Issuer `Let's Encrypt` **ohne** `STAGING`, Laufzeit ~90 Tage
3. `308` mit `location: https://thomaszachmann.de/`
4. `308` mit `location: https://thomaszachmann.de/`
5. alle sechs Header vorhanden
6. alle fünf Pfade `200`
7. `200`

Fehlen die Header in Punkt 5, greift die Middleware-Annotation nicht — dann `kubectl -n web-thomaszachmann describe ingress thomaszachmann` prüfen und den Namespace-Prefix `traefik-` in der Annotation kontrollieren.

- [ ] **Step 5: Im Browser gegenprüfen**

Die Seite in einem echten Browser öffnen. Zu prüfen: Schloss-Symbol ohne Warnung, und — das ist der Grund, warum dieser Schritt nicht durch `curl` ersetzbar ist — dass die Schrift wirklich Outfit ist und nicht der System-Fallback. Wenn die Seite nach Helvetica aussieht, wurden in Task 1 HTML-Fehlerseiten statt woff2-Dateien heruntergeladen.

---

## Task 9: Die Pipeline

**Files:**
- Create: `.github/workflows/build-site.yaml`

**Interfaces:**
- Consumes: `scripts/verify-assets.sh` (Task 1), `sites/thomaszachmann/Dockerfile` (Task 2), `apps/prod/kustomization.yaml` (Task 7)
- Produces: Bei jedem Push auf `main`, der `sites/thomaszachmann/**` berührt, ein neues Image in GHCR und einen Bot-Commit, der `images[0].digest` aktualisiert. Der Workflow spricht **nie** mit dem Cluster.

- [ ] **Step 1: Workflow schreiben**

`.github/workflows/build-site.yaml`:

```yaml
name: build-site

on:
  push:
    branches: [main]
    paths:
      - 'sites/thomaszachmann/**'
      - 'scripts/verify-assets.sh'
      - '.github/workflows/build-site.yaml'
  workflow_dispatch:

# Zwei gleichzeitige Laeufe wuerden sich beim Digest-Rueckschreiben
# gegenseitig ueberholen. Nicht abbrechen, sondern anstellen.
concurrency:
  group: build-site
  cancel-in-progress: false

permissions:
  contents: write    # fuer den Digest-Commit
  packages: write    # fuer den Push nach GHCR
  # Bewusst keine weiteren Rechte. Dieser Workflow deployt nicht — das macht
  # Flux, und Flux liest das Repo mit einem read-only Deploy-Key.

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Repo auschecken
        uses: actions/checkout@v5

      # Der erste Schritt ist der Test, nicht der Build: ein fehlender Font
      # soll die Pipeline stoppen, bevor irgendetwas gebaut oder gepusht wird.
      - name: Referenzierte Assets pruefen
        run: ./scripts/verify-assets.sh sites/thomaszachmann/public

      # GHCR akzeptiert nur kleingeschriebene Pfade. Ein Owner mit
      # Grossbuchstaben laesst den Push sonst mit einer irrefuehrenden
      # Fehlermeldung scheitern.
      - name: Owner kleinschreiben
        id: owner
        run: echo "lc=${GITHUB_REPOSITORY_OWNER,,}" >> "$GITHUB_OUTPUT"

      - name: Buildx einrichten
        uses: docker/setup-buildx-action@v3

      - name: An GHCR anmelden
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Image bauen und pushen
        id: build
        uses: docker/build-push-action@v6
        with:
          context: sites/thomaszachmann
          push: true
          tags: ghcr.io/${{ steps.owner.outputs.lc }}/thomaszachmann:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Digest ins Repo zurueckschreiben
        env:
          DIGEST: ${{ steps.build.outputs.digest }}
        run: |
          set -euo pipefail

          if [ -z "${DIGEST}" ]; then
            echo "Kein Digest vom Build-Schritt erhalten." >&2
            exit 1
          fi

          sed -i -E "s|^([[:space:]]*digest:[[:space:]]).*|\1${DIGEST}|" \
            apps/prod/kustomization.yaml

          echo "--- neue Zeile ---"
          grep -n 'digest:' apps/prod/kustomization.yaml

          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add apps/prod/kustomization.yaml

          if git diff --cached --quiet; then
            echo "Digest unveraendert — nichts zu committen."
            exit 0
          fi

          # [skip ci] ist Guertel und Hosenträger: der paths-Filter oben wuerde
          # diesen Commit ohnehin nicht triggern, weil er nur apps/ beruehrt.
          git commit -m "chore(deploy): thomaszachmann auf ${DIGEST} [skip ci]"
          git push
```

**Wenn der GitHub-Owner nicht `thomaszachmann` ist:** In `apps/prod/kustomization.yaml` muss `images[0].name` denselben kleingeschriebenen Owner tragen wie der Tag im Workflow, sonst greift die Kustomize-Ersetzung ins Leere und das Deployment zieht weiter das Bootstrap-Image. Beide Stellen jetzt abgleichen.

- [ ] **Step 2: Workflow committen und ersten Lauf beobachten**

```bash
git add .github/workflows/build-site.yaml
git commit -m "feat(ci): Image bauen und Digest ins Repo zurueckschreiben

Actions baut und schreibt, deployt aber nie. Damit muss im Cluster kein
Credential liegen, das nach GitHub schreiben darf — Flux liest read-only.

Der Asset-Check laeuft als erster Schritt: ein fehlender Font stoppt die
Pipeline, bevor ueberhaupt gebaut wird."
git push
gh run watch
```

Expected: Der Push berührt `.github/workflows/**` und triggert damit sich selbst. Alle Schritte grün, am Ende ein Bot-Commit auf `main`.

- [ ] **Step 3: Prüfen, dass der Digest wirklich angekommen ist**

```bash
git pull
grep -A2 'images:' apps/prod/kustomization.yaml
```

Expected: ein `digest: sha256:...`, der sich vom Bootstrap-Digest aus Task 7 unterscheidet.

- [ ] **Step 4: Der Ende-zu-Ende-Test**

Das ist der Test für Ziel 3 der Spec: ein Commit führt ohne manuellen Eingriff zum Rollout.

```bash
# Eine sichtbare, aber harmlose Aenderung.
# Bewusst kein sed: BSD-sed auf macOS interpretiert \n im Replacement als
# literales "n" und wuerde die Datei still beschaedigen.
ANCHOR='<meta name="theme-color" content="#ffffff">'
PROBE='<meta name="deploy-probe" content="1">'
F=sites/thomaszachmann/public/index.html

grep -qF "$ANCHOR" "$F" || { echo "Anker nicht gefunden" >&2; exit 1; }
awk -v a="$ANCHOR" -v pr="$PROBE" '{print} index($0,a){print pr}' "$F" > "$F.new"
mv "$F.new" "$F"
grep -c 'deploy-probe' "$F"

git add sites/thomaszachmann/public/index.html
git commit -m "test(site): Deploy-Probe"
git push

gh run watch                      # Pipeline abwarten
git pull                          # Bot-Commit holen
flux reconcile kustomization apps # nicht bis zum Intervall warten
kubectl -n web-thomaszachmann rollout status deploy/thomaszachmann
```

Dann von außen prüfen, dass die Änderung wirklich ausgeliefert wird:

```bash
curl -s https://thomaszachmann.de/ | grep -c 'deploy-probe'
```

Expected: `1`.

- [ ] **Step 5: Probe zurücknehmen**

Den Probe-Commit gezielt suchen statt über `HEAD~1` zu zählen — zwischen ihm und `HEAD` liegt der Bot-Commit, und dessen Position ist nicht garantiert:

```bash
PROBE="$(git log --format='%H %s' -20 | grep -m1 'test(site): Deploy-Probe' | cut -d' ' -f1)"
test -n "$PROBE" || { echo "Probe-Commit nicht gefunden" >&2; exit 1; }

git revert --no-edit "$PROBE"
git push
gh run watch
git pull
flux reconcile kustomization apps
kubectl -n web-thomaszachmann rollout status deploy/thomaszachmann
curl -s https://thomaszachmann.de/ | grep -c 'deploy-probe' || echo "0 — Probe entfernt"
```

Expected: `0`.

---

## Task 10: Betriebsanleitung, Branch Protection und DR-Probe

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: alles Vorherige
- Produces: nichts, was spätere Tasks brauchen. Dies ist der Abschluss.

- [ ] **Step 1: README schreiben**

`README.md`:

````markdown
# thomaszachmann.de

Website und Plattform. Ein k3s-Single-Node bei Hetzner Cloud, per Terraform
provisioniert, per Flux verwaltet.

- **Design:** `docs/superpowers/specs/2026-08-26-hetzner-k3s-website-platform-design.md`
- **Plan:** `docs/superpowers/plans/2026-08-26-hetzner-k3s-website-platform.md`

## Betriebsmodell

Der Node ist Cattle, kein Pet. Es gibt keine laufende Drift-Korrektur auf
OS-Ebene — der Weg zurueck zum Soll-Zustand ist der Rebuild, nicht das
Nachziehen. Der Zustand liegt vollstaendig im Repo; der Server haelt nichts,
was nicht reproduzierbar waere.

Die Primary IPs sind eigene Terraform-Ressourcen mit `delete_protection`.
Sie ueberleben einen Rebuild, deshalb muss DNS dabei nie angefasst werden.

## Inhalt aendern

1. Datei unter `sites/thomaszachmann/public/` bearbeiten
2. Lokal pruefen: `./scripts/verify-assets.sh sites/thomaszachmann/public`
3. Committen und pushen

Alles Weitere passiert von selbst: Actions baut das Image, schreibt den
Digest nach `apps/prod/kustomization.yaml`, Flux rollt innerhalb einer
Minute aus.

## Cluster-Zugriff

Port 6443 ist von aussen geschlossen. Zugriff nur ueber einen SSH-Tunnel.

```bash
cd terraform
terraform output kube_tunnel_command    # in einem eigenen Terminal ausfuehren

# in einem zweiten Terminal:
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

## Sich selbst ausgesperrt

Der haeufigste Betriebsfehler: Die eigene IP hat sich geaendert und die
Firewall laesst SSH nicht mehr durch.

Weg zurueck ueber die Hetzner-Konsole (console.hetzner.cloud):

1. Projekt → Firewalls → `tz-web` → Rules → die SSH-Regel auf die neue IP
   aendern. Wirkt sofort.
2. Danach `admin_ip_cidrs` in `terraform.tfvars` nachziehen und
   `terraform apply`, sonst setzt der naechste Apply die alte IP zurueck.

Alternativ bietet die Konsole eine Web-Console direkt auf den Node, die an
der Firewall vorbeigeht.

## Disaster Recovery

Siehe `docs/superpowers/plans/…` Task 10, Step 4. Kurzfassung: Server
zerstoeren, `terraform apply`, Flux erneut bootstrappen. Rund zehn Minuten.

**Was NICHT durch `terraform apply` heilbar ist:** der private age-Schluessel.
Ohne ihn sind die SOPS-verschluesselten Secrets im Repo unbrauchbar. Er
gehoert in den Passwortmanager, nicht nur auf diese Festplatte.

## Kosten

Rund 9 EUR netto im Monat: CX33 fuer 8,49 EUR plus etwa 0,55 EUR fuer die
primaere IPv4. Cloudflare DNS, GHCR und GitHub Actions sind bei einem
oeffentlichen Repo kostenlos.
````

- [ ] **Step 2: README committen**

```bash
git add README.md
git commit -m "docs: Betriebsanleitung

Deckt die drei Faelle ab, die im Betrieb wirklich vorkommen: Inhalt
aendern, Cluster-Zugriff ueber den Tunnel, und sich selbst per Firewall
ausgesperrt haben."
git push
```

- [ ] **Step 3: Branch Protection einrichten — mit Bypass für den Bot**

Reihenfolge ist wichtig: erst jetzt, nachdem Task 9 nachweislich läuft.

Ein Ruleset mit Pflicht-Review würde den Bot-Commit aus Task 9 blockieren und die Pipeline dauerhaft rot färben. Der Bot braucht deshalb einen Bypass.

Im GitHub-UI: Repo → Settings → Rules → Rulesets → New branch ruleset

- Target: `main`
- Rules: „Require a pull request before merging" und „Block force pushes"
- **Bypass list:** Eintrag hinzufügen für die GitHub-Actions-Integration (bzw. „Repository admin", falls die Actions-App dort nicht auswählbar ist)

Danach verifizieren, dass der Bot noch schreiben darf — nicht annehmen:

```bash
# Eine Site-Datei wirklich aendern. touch allein erzeugt keinen Commit,
# weil Git Inhalte vergleicht und nicht Zeitstempel.
printf '%s' '<!-- bypass-probe -->' >> sites/thomaszachmann/public/index.html
git commit -am "test(site): Bypass-Probe"
git push
gh run watch
```

Expected: Der Lauf endet grün, inklusive des Digest-Commits. Scheitert der Push-Schritt mit `protected branch hook declined`, fehlt der Bypass — dann das Ruleset korrigieren, nicht die Pipeline umbauen.

Anschließend die Probe zurücknehmen:

```bash
git revert --no-edit HEAD
git push
```

**Alternative:** Für ein Solo-Repo ist Branch Protection vor allem ein Schutz vor der eigenen Unachtsamkeit. Wenn der Bypass-Aufwand in keinem Verhältnis steht, ist es eine legitime Entscheidung, sie wegzulassen — dann diesen Step überspringen und im README vermerken, dass `main` ungeschützt ist.

- [ ] **Step 4: DR-Probe — der Test für Ziel 2 der Spec**

Ohne diesen Schritt ist „reproduzierbar" eine Behauptung.

**Vorher lesen:** Beim Rebuild ist das Secret `thomaszachmann-tls` weg und cert-manager stellt neu aus. Das verbraucht **eine** der fünf Let's-Encrypt-Ausstellungen pro Domain und Woche. Die Probe also nicht direkt nach mehreren Zertifikatsexperimenten laufen lassen.

```bash
# --- 1. IP festhalten, um sie danach zu vergleichen ---
cd terraform
IP_VORHER="$(terraform output -raw ipv4)"
IP6_VORHER="$(terraform output -raw ipv6)"
echo "vorher: $IP_VORHER / $IP6_VORHER"

# --- 2. Nur den Server zerstoeren, nicht die IPs ---
terraform destroy -target=hcloud_server.web
```

Expected: `Destroy complete! Resources: 1 destroyed.` Die Primary IPs bleiben — `delete_protection` würde ihre Löschung ohnehin verweigern.

```bash
# --- 3. Neu bauen ---
terraform apply

IP_NACHHER="$(terraform output -raw ipv4)"
[ "$IP_VORHER" = "$IP_NACHHER" ] && echo "OK: IP unveraendert" || echo "FEHLER: IP hat sich geaendert"
```

`OK: IP unveraendert` ist das eigentliche Ergebnis dieser Probe — es belegt, dass DNS beim Rebuild nicht angefasst werden muss.

```bash
# --- 4. Auf cloud-init warten ---
SSH_TARGET="$(terraform output -raw ssh_command | sed 's/^ssh //')"
ssh-keygen -R "$IP_NACHHER"     # der Host-Key ist neu
ssh -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
  'sudo cloud-init status --wait; ls -l /var/lib/cloud/k3s-ready'

# --- 5. kubeconfig neu holen, Tunnel oeffnen ---
cd ..
eval "$(cd terraform && terraform output -raw fetch_kubeconfig_command)"
# Tunnel in einem eigenen Terminal:  terraform output -raw kube_tunnel_command
export KUBECONFIG="$PWD/kubeconfig"

# --- 6. age-Schluessel und Flux wiederherstellen ---
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=age.key

export GITHUB_TOKEN=...
flux bootstrap github \
  --owner=thomaszachmann \
  --repository=thomaszachmann.de \
  --branch=main \
  --path=clusters/prod \
  --personal \
  --version=v2.9.4

# --- 7. Warten, bis alles wieder steht ---
flux get kustomizations --watch
```

Expected: `infra-controllers`, `infra-configs` und `apps` alle `Ready: True`.

```bash
# --- 8. Abnahme von aussen wiederholen ---
curl -sSI https://thomaszachmann.de/ | head -1
echo | openssl s_client -connect thomaszachmann.de:443 -servername thomaszachmann.de 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

Expected: `HTTP/2 200`, Issuer `Let's Encrypt` ohne `STAGING`.

Die benötigte Zeit stoppen und im README unter „Disaster Recovery" als
tatsächliche RTO eintragen — statt der geschätzten zehn Minuten aus der Spec.

- [ ] **Step 5: Ergebnis der Probe dokumentieren und committen**

```bash
git add README.md
git commit -m "docs: gemessene RTO aus der DR-Probe eintragen

Rebuild wurde durchgefuehrt: Server zerstoert, terraform apply, Flux neu
gebootstrappt. Die Primary IPs blieben unveraendert, DNS musste nicht
angefasst werden."
git push
```

- [ ] **Step 6: Offene Punkte übergeben**

Nicht Teil dieses Plans, aber jetzt fällig und dem Betreiber zu melden:

1. **Die `PLATZHALTER`-Stellen in `impressum.html` und `datenschutz.html` ersetzen.** In Deutschland nach § 5 DDG pflichtig und abmahnfähig. Die Seite ist bis dahin live, aber rechtlich unvollständig.
2. **Den privaten age-Schlüssel im Passwortmanager sichern**, falls in Task 5 noch nicht geschehen.
3. **Terraform-State sichern** — er liegt lokal und ist gitignored.

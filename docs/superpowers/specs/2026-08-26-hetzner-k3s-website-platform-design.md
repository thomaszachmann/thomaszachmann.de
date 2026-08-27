# Design: Website-Plattform auf Hetzner Cloud mit k3s und Flux

- **Datum:** 2026-08-26
- **Status:** Entwurf zur Review
- **Betrifft:** thomaszachmann.de (jetzt), Nyrvex-Firmenseite (später)

## 1. Kontext

Die Website besteht heute aus einer einzelnen, vollständig self-contained
`index.html` (555 Zeilen, CSS und ein Script inline, Favicon als Data-URI).
Es gibt keinen Build-Schritt und kein Hosting. Sie soll auf einem eigenen
k3s-Cluster bei Hetzner Cloud laufen, per Terraform provisioniert und per
GitOps deployt.

Referenzierte, aber noch nicht existierende Dateien:
`fonts/outfit.woff2`, `fonts/jetbrains-mono.woff2` (index.html:19-20),
`impressum.html`, `datenschutz.html` (Footer-Links).

## 2. Ziele und Nicht-Ziele

**Ziele**

1. `thomaszachmann.de` ist über HTTPS erreichbar, mit gültigem Zertifikat und
   automatischer Erneuerung.
2. Die gesamte Infrastruktur ist aus dem Repository reproduzierbar. Ein
   Totalverlust des Servers ist durch `terraform apply` plus `flux bootstrap`
   heilbar, ohne manuelle Klickarbeit und ohne DNS-Änderung.
3. Ein Commit auf `main` führt ohne manuellen Eingriff zum Rollout.
4. Eine zweite Site (Nyrvex) ist ohne strukturellen Umbau hinzufügbar.
5. Der Cluster taugt als Referenz für Plattform-Beratung und als Lab für
   eigene Experimente.

**Nicht-Ziele**

- Hochverfügbarkeit. Bewusst ein einzelner Node.
- Autoscaling, Multi-Region, CDN.
- Monitoring-Stack. Kommt später als Lab-Workload, nicht in diesem Scope.
- Inhaltliche Änderungen an der Website über das Nötigste hinaus.
- Rechtsverbindliche Formulierung von Impressum und Datenschutzerklärung.

## 3. Entscheidungen und Begründungen

### 3.1 Ein Node, Typ CX33

CX33: 4 vCPU (x86), 8 GB RAM, 80 GB NVMe, 8,49 €/Monat, Standort fsn1.
Basis-Image: `ubuntu-24.04` (LTS, Support bis 2029). Gewählt gegen Debian 13,
weil die k3s-Dokumentation und die meisten Fehlerberichte sich auf Ubuntu-LTS
beziehen — bei einem Node, der selten angefasst wird, zählt die Auffindbarkeit
von Antworten mehr als ein paar MB weniger Grundsystem.

Bemerkenswert: Die ARM-Reihe (CAX21, gleiche Specs) kostet nach den
Preisanpassungen 2026 mit 10,49 €/Monat mehr als x86. Der frühere
ARM-Preisvorteil ist weg, also x86 — das erspart uns zusätzlich
Multi-Arch-Images.

Ein Node statt drei, weil zwei statische Seiten die Komplexität von embedded
etcd, Load Balancer und Bootstrap-Reihenfolge nicht rechtfertigen. Die
freien Ressourcen gehen in Lab-Workloads statt in Redundanz.

### 3.2 Die IP wird getrennt vom Server verwaltet

`hcloud_primary_ip` für IPv4 und IPv6 als eigene Ressourcen mit
`delete_protection = true`, an den Server attached.

Ohne diesen Split bekommt der Server bei jedem Rebuild eine neue IP. Damit
wäre er kein Cattle mehr, sondern ein Pet, an dem DNS und TTL-Wartezeiten
hängen. Die Trennung macht Ziel 2 überhaupt erst erreichbar.

### 3.3 Firewall auf Hetzner-Ebene, nicht im Gast

`hcloud_firewall`, kein ufw oder nftables innerhalb der VM.

Zwei Gründe. Erstens schreibt k3s eigene iptables/nftables-Regeln für CNI
und Services; ein Host-Firewall-Werkzeug darüber ist eine bekannte
Fehlerquelle. Zweitens kann ein kompromittierter Host eine Firewall, die
außerhalb von ihm läuft, nicht abschalten.

Regeln:

| Port | Quelle | Zweck |
|---|---|---|
| 80/tcp | 0.0.0.0/0, ::/0 | HTTP, wird auf HTTPS umgeleitet |
| 443/tcp | 0.0.0.0/0, ::/0 | HTTPS |
| 22/tcp | `admin_ip_cidrs` (Variable) | SSH |
| 6443/tcp | — geschlossen — | kube-apiserver |

Der kube-apiserver ist nicht aus dem Internet erreichbar. Zugriff läuft über
`ssh -L 6443:127.0.0.1:6443`. Terraform gibt den fertigen Befehl aus.

Wenn sich die Admin-IP ändert und man sich aussperrt, ist die Hetzner-Konsole
der Weg zurück: Firewall-Regel dort anpassen oder die Firewall temporär vom
Server lösen. Das steht so im README, weil es der wahrscheinlichste
Betriebsfehler ist.

### 3.4 cloud-init statt Ansible

Die Node-Konfiguration passiert einmalig beim ersten Boot per cloud-init,
gerendert von Terraform aus `cloud-init.yaml.tftpl`. Kein Ansible.

Begründung: Die k3s-Installation ist ein Skript-Aufruf mit Flags. Alles
danach — Ingress, cert-manager, Apps — macht Flux. Für Ansible bliebe nur
OS-Hardening, das cloud-init genauso erledigt. Ein zweites
Config-Management-Werkzeug für diesen Rest wäre Abstraktion ohne Gegenwert.

Konsequenz, die man akzeptieren muss: Es gibt keine laufende Drift-Korrektur
auf OS-Ebene. Der Weg zurück zum Soll-Zustand ist der Rebuild, nicht das
Nachziehen. Das ist bei einem zustandslosen Node vertretbar und wird im
README als Betriebsmodell dokumentiert.

Inhalt des cloud-init:

- SSH: `PasswordAuthentication no`, `PermitRootLogin prohibit-password`
- `unattended-upgrades` aktiviert
- Nicht-Root-Benutzer mit dem Terraform-verwalteten SSH-Key
- k3s-Installation, Version über `INSTALL_K3S_VERSION` gepinnt

### 3.5 k3s-Flags

| Flag | Begründung |
|---|---|
| `--disable=traefik` | Traefik kommt per Flux, siehe 3.6 |
| `--secrets-encryption` | Secrets verschlüsselt at rest statt nur base64 |
| `--write-kubeconfig-mode=0600` | kubeconfig nicht world-readable |
| `--tls-san=<primary_ipv4>` | Zertifikat des apiserver gilt für die IP |
| `--node-name=<fest>` | Node-Name unabhängig vom Hostname |

Aktiv bleiben: ServiceLB (klipper), local-path-provisioner, metrics-server.
ServiceLB gibt LoadBalancer-Services die Node-IP und ersetzt damit den
Hetzner Load Balancer (~6 €/Monat gespart). Die anderen zwei braucht das Lab.

### 3.6 Traefik aus Flux, nicht aus k3s

Der gebündelte Traefik wird deaktiviert und stattdessen per HelmRelease von
Flux installiert.

Grund: Der gebündelte Traefik wird über eine `HelmChartConfig` auf dem Node
konfiguriert, seine Version hängt an der k3s-Version. Damit läge ein Teil des
Cluster-Zustands außerhalb des Git-Repos. Wenn Git die Wahrheit sein soll,
muss es die ganze Wahrheit sein — sonst hat man ein GitOps-Setup, das an
genau einer Stelle lügt.

### 3.7 TLS per DNS-01 über Cloudflare

cert-manager per HelmRelease, zwei ClusterIssuer (`letsencrypt-staging` und
`letsencrypt-prod`), beide mit DNS-01-Solver über die Cloudflare-API.

DNS-01 statt HTTP-01, weil die Validierung dann nicht von der
Erreichbarkeit auf Port 80 abhängt und Wildcards möglich wären, falls später
`*.lab.thomaszachmann.de` für Demo-Workloads gebraucht wird.

Der Staging-Issuer ist keine Zierde: Let's Encrypt erlaubt fünf
Zertifikate pro Domain und Woche. Beim Einrichten ist das schnell
aufgebraucht. Erst gegen Staging verifizieren, dann auf Prod umstellen.

Zertifikate zunächst pro Site mit Apex und `www`, kein Wildcard (YAGNI).

### 3.8 Cloudflare als DNS-only

Records: A und AAAA für `thomaszachmann.de` und `www`, per
`cloudflare_dns_record` in Terraform. Proxy aus ("graue Wolke").

Achtung, das ist eine Korrektur gegenüber dem, was man aus älteren
Beispielen kennt: Der Cloudflare-Provider hat in v5 über 40 Ressourcen
umbenannt, `cloudflare_record` heißt jetzt `cloudflare_dns_record`. Dabei
haben sich auch Attribute geändert — `content` statt `value`, `ttl` ist
verpflichtend, und `name` verlangt den vollen FQDN statt `@` für den Apex.
Wir starten auf v5, also gibt es keine Migration, aber jedes v4-Beispiel aus
dem Netz ist für uns falsch.

Kanonisch ist die Apex-Domain, `www` bekommt einen 301-Redirect in Traefik.
Das deckt sich mit `og:url` in index.html:12.

Kein Cloudflare-Proxy, weil dann der Besucher-Traffic über einen
US-Anbieter liefe. Die Website argumentiert prominent mit europäischen
Clouds und DSGVO; ein Proxy davor wäre ein Widerspruch, den ein
aufmerksamer Interessent findet.

### 3.9 Delivery: Actions baut, Flux rollt aus

GitHub Actions baut das Container-Image und pusht es nach GHCR. Danach
schreibt Actions den Image-**Digest** in `apps/prod/kustomization.yaml` und
committet. Flux liest das Repo und rollt aus.

Gegenüber Flux Image Automation gewählt, weil im Cluster kein Credential
liegen muss, das nach GitHub schreiben darf. Flux braucht nur Lesezugriff.
Die Deploy-Historie ist als Commit-Verlauf lesbar. Image Automation lässt
sich später ohne Redesign nachrüsten, falls das Feature demonstriert werden
soll.

Digest statt Tag, weil ein Tag verschiebbar ist und ein Digest nicht. Was im
Repo steht, ist dann exakt das, was läuft.

## 4. Architektur

```
Besucher
   │  DNS: Cloudflare (nur Auflösung, kein Proxy)
   ▼
Hetzner Cloud Firewall  ── 80/443 offen, 22 nur Admin-IP, 6443 zu
   ▼
Primary IP (v4+v6, delete_protection)
   ▼
CX33, fsn1 ─ k3s single node
   ├── Traefik (HelmRelease)  ← TLS-Terminierung, Redirects, Header
   ├── cert-manager (HelmRelease) ─── DNS-01 ──► Cloudflare API
   ├── flux-system ───── liest ──► GitHub Repo (read-only Deploy Key)
   └── Namespace web-thomaszachmann
         └── Deployment nginx-unprivileged + Site-Inhalt
```

Deploy-Fluss:

```
Commit auf main (sites/thomaszachmann/**)
   ▼ GitHub Actions
   1. verify   — referenzierte lokale Assets existieren?
   2. build    — Image → ghcr.io/<owner>/thomaszachmann@sha256:…
   3. update   — Digest in apps/prod/kustomization.yaml, Commit [skip ci]
   ▼ Flux (Reconcile-Intervall 1 min)
   kubectl apply → Rolling Update
```

## 5. Repository-Struktur

```
terraform/
  providers.tf         hcloud + cloudflare, Versionen gepinnt
  variables.tf         admin_ip_cidrs, domain, github_owner, ssh_key, k3s_version
  main.tf              primary_ip, ssh_key, server
  firewall.tf          hcloud_firewall + attachment
  dns.tf               cloudflare_dns_record (A, AAAA für apex und www)
  cloud-init.yaml.tftpl
  outputs.tf           ip, ssh_tunnel_cmd, kubeconfig_hint
  terraform.tfvars.example
.sops.yaml              Verschlüsselungsregeln (nur Werte, nie Keys)
.gitignore
sites/
  thomaszachmann/
    Dockerfile
    nginx.conf
    public/            index.html, fonts/, impressum.html, datenschutz.html
scripts/
  verify-assets.sh     prüft lokale href/src gegen das Dateisystem
clusters/prod/
  flux-system/         von flux bootstrap erzeugt
  infrastructure.yaml  Kustomization → infrastructure/
  apps.yaml            Kustomization → apps/prod, dependsOn: infrastructure
infrastructure/
  controllers/         HelmRepository + HelmRelease: traefik, cert-manager
  configs/             ClusterIssuer, Traefik-Middlewares, SOPS-Secret
apps/
  base/thomaszachmann/ namespace, deployment, service, ingress,
                       certificate, networkpolicy
  prod/                kustomization.yaml ← Image-Digest
.github/workflows/
  build-site.yaml
```

Zwei Flux-Kustomizations mit `dependsOn`: `infrastructure` vor `apps`, damit
kein Ingress auf eine noch nicht existierende IngressClass zeigt.

`index.html` wird per `git mv` nach `sites/thomaszachmann/public/`
verschoben — als eigener Commit, damit der Umbau im Verlauf sichtbar bleibt.

## 6. Site-Workload

Basis-Image: `nginxinc/nginx-unprivileged:alpine`, nicht `nginx`. Das
Standard-Image startet als Root und dropt Rechte danach; das unprivileged
läuft durchgehend als UID 101. Erst das erlaubt einen securityContext, der
sonst nicht funktioniert:

- `runAsNonRoot: true`
- `readOnlyRootFilesystem: true`, mit emptyDir für `/tmp` und
  `/var/cache/nginx`
- `allowPrivilegeEscalation: false`
- `capabilities: { drop: [ALL] }`
- `seccompProfile: { type: RuntimeDefault }`

Dazu pro Site-Namespace eine default-deny NetworkPolicy, die nur Ingress vom
Traefik-Namespace erlaubt und Egress auf DNS beschränkt.

Für einen statischen HTML-Server ist das mehr Härtung als nötig. Es ist
bewusst so: der Cluster ist Referenz für Plattform-Beratung, und ein Pod,
der vorführt, wovon der Betreiber lebt, ist mehr wert als einer, der
`nginx:latest` als Root fährt.

Jede Site bekommt eine eigene Namespace (`web-thomaszachmann`, später
`web-nyrvex`) statt zwei Deployments in einer. Das kostet nichts und liefert
eine echte Isolationsgrenze für NetworkPolicies sowie einen Ort, an dem
Nyrvex später eigenes RBAC bekommen kann.

Traefik-Middleware-Kette pro Site: HTTP→HTTPS-Redirect, HSTS,
`X-Content-Type-Options: nosniff`, `Referrer-Policy`, CSP.

Zur CSP: Die Seite lädt keine externen Ressourcen (Fonts self-hosted,
Favicon als Data-URI), also kann die Policy streng sein. Weil CSS und ein
Script aber inline in der `index.html` stehen, braucht `style-src` und
`script-src` zunächst `'unsafe-inline'`. Das Auslagern der Inline-Blöcke in
externe Dateien — womit `'unsafe-inline'` entfiele — ist als Folgearbeit
notiert und nicht Teil dieses Scopes, weil es die Struktur des
Website-Inhalts verändert.

## 7. Secrets

**SOPS mit age.** Öffentlicher age-Key im Repo, privater Key als Secret
`sops-age` im Cluster, Flux-Kustomization entschlüsselt beim Apply
(`decryption.provider: sops`). `.sops.yaml` verschlüsselt nur Werte, nie
Keys, damit Diffs lesbar bleiben.

Zu verschlüsseln ist praktisch nur der Cloudflare-API-Token für cert-manager.

**Kein GHCR-Pull-Secret.** Das Image-Package wird public. Es enthält eine
öffentliche Website; ein Credential dafür zu verwalten wäre
Sicherheitstheater.

**Zwei getrennte Cloudflare-Tokens**, jeweils scoped auf `Zone:DNS:Edit` plus
`Zone:Zone:Read` für genau diese Zone: eines für Terraform, eines für
cert-manager. So hat ein kompromittierter Cluster nicht das Token, mit dem
Terraform arbeitet.

`Zone:Zone:Read` ist bei cert-manager nicht optional — ohne die Berechtigung
kann es die Zone-ID zum DNS-Namen nicht auflösen und die Challenge scheitert,
obwohl das Setzen des TXT-Records erlaubt wäre.

> **Abweichung, umgesetzt am 2026-08-27:** Es wird vorerst *ein* Token für
> beides verwendet. Der Betreiber hat das bewusst entschieden. Konsequenz: Das
> Token, mit dem Terraform DNS-Records verwaltet, liegt entschlüsselt in einem
> Kubernetes-Secret und ist für jeden lesbar, der `get secrets` im Namespace
> `cert-manager` darf. Die Trennung lässt sich jederzeit nachziehen — es ist
> ein neues Token und ein erneutes `sops --encrypt`, ohne Codeänderung.

**Terraform-Credentials** kommen aus Umgebungsvariablen (`HCLOUD_TOKEN`,
`CLOUDFLARE_API_TOKEN`), nie aus `.tfvars`. `.tfvars` ist gitignored,
`.tfvars.example` ist eingecheckt.

**Terraform-State** bleibt lokal, gitignored, mit sops-verschlüsseltem
Backup. Kein Remote-Backend, weil Hetzner Object Storage mit ~6 €/Monat mehr
als die Hälfte des Serverpreises für eine State-Datei kosten würde und
Terraform Cloud US-gehostet ist.

**Der private age-Key gehört in den Passwortmanager.** Er ist das einzige
Artefakt in diesem Setup, dessen Verlust nicht durch `terraform apply`
heilbar ist.

Das Repo ist public. Das ist tragbar, weil keine Klartext-Credentials darin
liegen — aber es macht die SOPS-Disziplin zur harten Anforderung, nicht zur
Empfehlung.

## 8. Versionierung

Alle Versionen werden gepinnt, keine `latest`-Tags, kein
`version: "*"` in HelmReleases. Betrifft: k3s, Flux, Traefik-Chart,
cert-manager-Chart, hcloud- und cloudflare-Provider, Basis-Image.

Die konkreten Versionsnummern werden im Implementierungsplan gegen die
Upstream-Quellen verifiziert und dort festgeschrieben, nicht hier aus dem
Gedächtnis behauptet.

## 9. Verifikation

Die Reihenfolge ist bewusst so, dass jede Stufe erst grün sein muss, bevor
die nächste Kosten oder Rate-Limits verursacht.

1. `terraform fmt -check`, `terraform validate`, `tflint`
2. `terraform plan` gelesen, bevor `apply`
3. Nach `apply`: SSH-Zugang, `k3s` läuft, `kubectl get nodes` über den
   SSH-Tunnel
4. `verify-assets.sh` lokal gegen `sites/thomaszachmann/public/` — muss
   grün sein, bevor gebaut wird
5. Container lokal gestartet, Seite und alle Assets liefern 200
6. Flux: `flux check`, `flux get kustomizations` alle Ready
7. Zertifikat gegen **Staging** ausgestellt, Kette geprüft, erst dann auf
   Prod-Issuer umgestellt
8. HTTPS von außen: Statuscode, Zertifikat, Security-Header,
   `www`-Redirect, IPv6
9. Pod-Härtung: `kubectl auth can-i`, securityContext im laufenden Pod
   geprüft, NetworkPolicy durch einen Test-Pod verifiziert
10. Ende-zu-Ende: Trivialer Commit auf `main`, Rollout ohne Eingriff
    beobachtet
11. DR-Probe: `terraform destroy` des Servers (nicht der IP), `apply`,
    `flux bootstrap`, Seite wieder erreichbar. IP unverändert.

Schritt 11 ist der einzige, der Ziel 2 wirklich belegt. Ohne ihn ist
Reproduzierbarkeit eine Behauptung.

## 10. Kosten

| Posten | €/Monat netto |
|---|---|
| CX33 (4 vCPU, 8 GB, fsn1) | 8,49 |
| Primäre IPv4 | ~0,50–0,60 |
| Cloudflare DNS | 0,00 |
| GHCR (public package) | 0,00 |
| GitHub Actions (public repo) | 0,00 |
| **Summe** | **~9,05 netto, ~10,80 brutto** |

Der exakte IPv4-Preis wird beim Apply gegen die Hetzner-Rechnung verifiziert.
Nicht gebucht: Hetzner-Backups (20 % Aufpreis für einen zustandslosen Node)
und Load Balancer (durch ServiceLB ersetzt).

## 11. Risiken

| Risiko | Bewertung |
|---|---|
| Single Node, kein HA | Node weg = Seite weg bis zum Eingriff. RTO ~10 min manuell. Bewusst für den Preis akzeptiert. Für eine Akquise-Seite die relevanteste offene Frage. |
| Hetzner-Preise | 2026 dreimal erhöht. 8,49 € ist kein stabiler Wert. |
| Branch Protection blockiert den Bot-Commit | Tritt sicher auf, sobald Protection auf `main` aktiviert wird. Lösung: Bypass für den Actions-Bot. Vorab dokumentiert statt später debuggt. |
| Let's-Encrypt-Rate-Limit | Durch Staging-First-Vorgehen entschärft. |
| Aussperren durch geänderte Admin-IP | Hetzner-Konsole als Rückweg, im README dokumentiert. |
| Impressum und Datenschutz fehlen | In Deutschland nach § 5 DDG pflichtig und abmahnfähig. Gerüst wird gebaut, Inhalt liegt beim Betreiber. |
| age-Key-Verlust | Nicht durch Terraform heilbar. Backup im Passwortmanager ist Pflicht, nicht Kür. |

## 12. Parameter, die beim Apply gesetzt werden müssen

| Parameter | Anmerkung |
|---|---|
| `github_owner` | Annahme: `thomaszachmann` (aus dem Footer-Link der Website). Bestimmt die GHCR-Pfade. |
| `admin_ip_cidrs` | Aktuelle Admin-IP für die SSH-Regel |
| `domain` | `thomaszachmann.de` |
| `cloudflare_zone_id` | Aus dem Cloudflare-Dashboard |
| `HCLOUD_TOKEN` | Umgebungsvariable |
| `CLOUDFLARE_API_TOKEN` | Umgebungsvariable, Zone:DNS:Edit |
| `ssh_key_name` | Name eines **bereits im Hetzner-Projekt hinterlegten** SSH-Keys. Terraform referenziert ihn per Data-Source statt ihn anzulegen: Hetzner lehnt doppelte Fingerprints ab, und ein von Terraform besessener Key koennte bei `destroy` den Zugang zu anderen Servern im selben Projekt mitreissen. |
| `k3s_version` | Gepinnte k3s-Version, im Implementierungsplan festgelegt |
| `letsencrypt_email` | Kontaktadresse für die ACME-Registrierung |
| age-Keypair | Einmalig lokal erzeugt; Public in `.sops.yaml`, Private in den Passwortmanager und als Cluster-Secret |

## 13. Folgearbeiten, ausdrücklich nicht in diesem Scope

- Nyrvex als zweite Site. Die Struktur ist darauf vorbereitet; der Schritt
  ist `sites/nyrvex/` plus `apps/base/nyrvex/` plus ein zweiter
  Workflow-Trigger.
- Monitoring (Prometheus, Grafana) als Lab-Workload.
- Inline-CSS und -Script aus `index.html` auslagern, um `'unsafe-inline'`
  aus der CSP zu entfernen.
- Flux Image Automation, falls das Feature demonstriert werden soll.
- Cosign-Signaturen für die Images plus Verifikation im Cluster.

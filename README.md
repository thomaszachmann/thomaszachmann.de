# thomaszachmann.de

Website and platform. A single-node k3s cluster on Hetzner Cloud, provisioned
with Terraform, managed with Flux. Live since 2026-08-27.

**Runbooks — start here:**

- [Deploying a feature](docs/runbooks/feature-deployen.md) — change content,
  change cluster configuration, change infrastructure, add a new site,
  roll back
- [Rebuilding the cluster](docs/runbooks/cluster-neu-aufsetzen.md) — rebuild the
  server (~6 min) or start completely from scratch, all commands

**Background:**

- [Design](docs/superpowers/specs/2026-08-26-hetzner-k3s-website-platform-design.md) — which decisions were made and why
- [Implementation plan](docs/superpowers/plans/2026-08-26-hetzner-k3s-website-platform.md) — how it was built

## Operating model

The node is cattle, not a pet. There is deliberately no ongoing drift correction
at the OS level — the way back to the desired state is a rebuild, not patching
things up. The state lives entirely in the repo; the server holds nothing that
could not be reproduced.

The primary IPs are separate Terraform resources with `delete_protection`. They
survive a rebuild, so DNS never has to be touched.

## Toolchain

Version-pinned in [`mise.toml`](mise.toml), so it is part of the
reproducible state rather than an accident of the local machine:

```bash
mise install
```

`kubectl` is deliberately pinned to the server's k3s version. Kubernetes
only supports a skew of ±1 minor version between client and apiserver; an older,
globally installed `kubectl` otherwise produces symptoms that look like
cluster problems but aren't.

Not managed by mise: `sops`, `age`, `gh`, `jq`, `docker` — installed via Homebrew.

**If `terraform version` shows something different from `mise.toml`:** there is
a second binary under `/opt/homebrew/bin/` shadowing the mise version.
Check with `which -a terraform`.

## Changing content

1. Edit the file under `sites/thomaszachmann/public/`
2. Check locally: `./scripts/verify-assets.sh sites/thomaszachmann/public`
3. Commit and push

Everything else happens automatically: GitHub Actions builds the image, writes the
digest to `apps/prod/kustomization.yaml`, and Flux rolls it out within a minute.
Measured from commit to live: about two minutes.

The workflow **never deploys by itself**. There is no credential in the cluster with
write access to the repo — the Flux deploy key is read-only, verified via the
API.

## Changing infrastructure

```bash
cd terraform
terraform plan -out=tfplan     # read before applying
terraform apply tfplan
../scripts/backup-state.sh     # refresh the state backup
```

The last step is not optional. The state is local and
gitignored; if the disk were lost without a backup, every resource would have to be
imported one by one. `backup-state.sh` stores it SOPS-encrypted
under `terraform/state-backup.sops.json`, checks the round trip
semantically and discards the backup if it cannot be restored.

This is a backup, not a remote backend: there is no locking. As long as only
one person runs apply, that's not a problem.

Restore:

```bash
SOPS_AGE_KEY_FILE=age.key sops --decrypt terraform/state-backup.sops.json \
  > terraform/terraform.tfstate
```

## Cluster access

Port 6443 is closed from the outside. Access only via an SSH tunnel.

```bash
cd terraform
terraform output kube_tunnel_command    # run in a separate terminal
terraform output fetch_kubeconfig_command

# in the second terminal:
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
flux get kustomizations
```

## When something is broken

| Symptom | First diagnosis |
|---|---|
| Site not reachable | `kubectl -n web-thomaszachmann get pods`, then `kubectl -n traefik get svc` |
| Certificate expired | `kubectl -n web-thomaszachmann describe certificate thomaszachmann-tls` |
| Deploy doesn't arrive | `flux get kustomizations`, then `flux logs --level=error` |
| Pipeline red | `gh run view --log-failed` |

**`flux reconcile` needs `--with-source`, otherwise it lies.** Without the flag,
Flux re-applies the cached Git revision instead of fetching again
— and reports success. A subsequent `kubectl rollout status` also reports
success, because the *old* Deployment has indeed been rolled out. You then have
two green messages and still the old state live:

```bash
flux reconcile kustomization apps --with-source     # correct
```

A cross-check that doesn't lie — is the image from the repo actually running?

```bash
grep 'digest:' apps/prod/kustomization.yaml
kubectl -n web-thomaszachmann get pod -l app.kubernetes.io/name=thomaszachmann \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

Without intervention it resolves itself anyway: `apps` reconciles every minute. You
only need the flag if you don't want to wait.

**Don't call `flux reconcile` on a Kustomization that intentionally cannot
become ready** — the command waits for readiness and hangs until the
timeout. Query the state instead:

```bash
kubectl -n flux-system get kustomizations \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MESSAGE:.status.conditions[?(@.type=="Ready")].message'
```

## Certificates

Two ClusterIssuers: `letsencrypt-staging` and `letsencrypt-prod`. **Switch to
staging before changing the `dnsNames`.** Let's Encrypt allows five
certificates per domain per week, and a failed attempt sends
cert-manager into a one-hour backoff.

After a failed attempt, the backoff can be reset by deleting the
`Certificate` resource — Flux recreates it and the counter
starts at zero.

The `Certificate` is deliberately **not** part of the health check of the
`apps` Kustomization. Its readiness depends on an external service; as a
gate it would block every reconcile until the timeout and hold up other
changes too.

## Locked yourself out

The most common operational mistake: your own IP has changed and the firewall
no longer lets SSH through. With a Telekom connection this happens after every
forced disconnect.

The way back is via the Hetzner Console (console.hetzner.cloud):

1. Project → Firewalls → `tz-web` → Rules → change the SSH rule to the new IP.
   Takes effect immediately.
2. Then update `admin_ip_cidrs` in `terraform/terraform.tfvars` and run
   `terraform apply`, otherwise the next apply resets the old IP.

Alternatively, the console offers a web console directly on the node that bypasses the
firewall.

## Deliberate deviations from the spec

| Deviation | Reason |
|---|---|
| **One Cloudflare token instead of two** | Decided by the operator. Consequence: the token Terraform uses to manage DNS is stored decrypted in a Kubernetes secret. Fixing this later costs a new token and a `sops --encrypt`, no code change. |
| **SSH key is referenced, not managed** | The key already existed in the Hetzner project and is used by other servers. If Terraform owned it, a `destroy` could take their access down with it. |
| **No manual bootstrap push to GHCR** | The Actions runner gets `packages: write` from its `permissions` block, and GHCR inherits public visibility from the repo. So no `write:packages` is needed locally and the first image is created the same way as every later one. |
| **`apps` gated on the Deployment instead of `wait: true`** | See the Certificates section. |

## Still open

- **Two `PLATZHALTER` (placeholders)** in `datenschutz.html`: log retention period and
  the responsible supervisory authority. They are visible on the live page.

### VAT in the legal notice (Impressum)

The section is currently intentionally missing. § 5 (1) No. 6 DDG requires the
VAT ID only **if one exists** — if you don't have one, you leave it out. The
legal notice is therefore complete.

If a VAT ID has been issued, insert it in `impressum.html` before the heading
"Redaktionell verantwortlich":

```html
  <h2>Umsatzsteuer-Identifikationsnummer</h2>
  <p>DE123456789</p>
```

Under the small-business rule, use this instead:

```html
  <h2>Umsatzsteuer</h2>
  <p>Gemäß § 19 UStG wird keine Umsatzsteuer berechnet.</p>
```

**The tax number does not belong here** — it is not required and
should not be published. Only the VAT ID (format `DE` plus nine
digits) is a legal-notice item.
- **Force-push protection** is configured but not verified: the only
  reliable test would be an actual force push.

**What `terraform apply` CANNOT fix:** the private age key
(`age.key`). Without it, the SOPS-encrypted secrets in the repo are useless.
It belongs in the password manager, not only on this disk.

## Disaster recovery

Performed and measured on 2026-08-27, not estimated.

```
16:58:59  server destroyed, site offline
16:59:22  terraform apply FAILED (see below)
17:00:27  server recreated, same IP
17:01:25  cloud-init done, k3s Ready         (58 s)
17:02:31  Flux bootstrapped
17:04:32  site running, page reachable again
17:05:55  production certificate reissued
17:06:26  acceptance checks fully green
```

**Measured RTO: about 6 minutes until reachable, 7 minutes until valid TLS.**
RPO zero — everything is in the repo.

Evidence: the server ID changed from `163777966` to `163785180`, i.e. a
physically different machine, with the IPv4 `2.28.5.182` unchanged. **DNS did
not have to be touched.** That is exactly why the primary IPs are separate resources
with `delete_protection`.

### The procedure

```bash
cd terraform
terraform destroy -target=hcloud_server.web
terraform apply
ssh-keygen -R "$(terraform output -raw ipv4)"       # host key is new
eval "$(terraform output -raw fetch_kubeconfig_command)"
# tunnel in a separate terminal: terraform output -raw kube_tunnel_command

export KUBECONFIG="$PWD/../kubeconfig"
kubectl create namespace flux-system
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=../age.key

export GITHUB_TOKEN="$(gh auth token)"
flux bootstrap github --owner=<owner> --repository=thomaszachmann.de \
  --branch=main --path=clusters/prod --personal --version=v2.9.4

../scripts/backup-state.sh    # state has a new server ID
```

### A risk the drill uncovered

The first `terraform apply` failed:

```
Error: error during placement (resource_unavailable)
```

At that moment Hetzner had **no CX33 capacity in fsn1**. A
retry 30 seconds later worked. This is not a configuration error
but a real dependency: the rebuild assumes that a machine of the requested type
is available at the target location right then.

This hits the IP-anchor design at its sensitive spot. A
primary IP is **bound to a location** — an IP in `fsn1` cannot be attached to
a server in `nbg1`. Falling back to another location
would therefore give up exactly the property that makes the fast
recovery possible.

What to do in an emergency, in this order:

1. **Retry.** Capacity shortages usually last minutes.
2. **Use a different server type at the same location:**
   `terraform apply -var="server_type=cx43"`. The IP anchor holds, it only costs
   more money — and you can switch back later at your leisure.
3. **Change the location only as a last resort.** Then new primary IPs are
   needed and DNS has to be updated. The 6-minute RTO then becomes
   the DNS TTL of 300 seconds plus caching reality.

Point 2 is the real value of this finding: there is a way out that
doesn't sacrifice the anchor — but you have to know it before you need it.

## Costs

| Item | €/month net |
|---|---|
| CX33 (4 vCPU, 8 GB, fsn1) | 8.49 |
| Primary IPv4 | ~0.50–0.60 |
| Cloudflare DNS, GHCR, GitHub Actions | 0.00 |
| **Total** | **~9.05 net, ~10.80 gross** |

Not booked: Hetzner backups (20 % surcharge for a stateless node) and
load balancer (replaced by k3s' ServiceLB).

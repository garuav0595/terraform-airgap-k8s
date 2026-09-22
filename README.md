# terraform-airgap-k8s

Terraform + shell-script project that bootstraps a highly-available
Kubernetes cluster, via `kubeadm`, on **pre-existing RHEL 9 hosts
inside an air-gapped network**. No cloud provider, no registry, no
Helm. Built by Gaurav Khatri.

## Why this looks the way it does

Every design decision here follows from the environment, not from
"best practice" in the abstract:

| Constraint | Consequence |
|---|---|
| No internet on the nodes | Everything ships as an offline bundle; `imagePullPolicy: IfNotPresent` everywhere |
| A site HTTP(S) proxy exists but is unreliable for bootstrap | Proxy support is opt-in and never load-bearing |
| Nodes already exist (bare metal / vSphere) | Terraform only configures hosts over SSH -- providers are `null`, `random`, `local`, `external` only |
| RHEL 9, x86_64 | RPMs are dependency-resolved against an EL9 userspace |
| The API is fronted by a VIP | Either this project owns it (haproxy+keepalived) or an external LB does |
| The bundle is usually built on Apple Silicon | Every image pull forces `--platform linux/amd64` |

## The two-machine workflow

This is not a single `terraform apply` from scratch. It's two
machines, two trust zones:

```
 ┌─────────────────────────┐        physically carry the        ┌──────────────────────────┐
 │   BUILD MACHINE          │        bundle across the air       │   TERRAFORM HOST          │
 │   (has internet)         │ ───── gap (USB, artifact store) ─▶ │   (reaches the nodes'     │
 │                            │                                   │    management network)    │
 │  bundle/prepare-bundle.sh │                                   │  terraform apply           │
 │  bundle/prepare-rpms.sh   │                                   │   -> packs bundle/         │
 │    -> bundle/images/*.tar │                                   │   -> SCPs to every node    │
 │    -> bundle/rpms/*.rpm   │                                   │   -> runs kubeadm over SSH │
 │    -> bundle/manifests/   │                                   │                             │
 └─────────────────────────┘                                   └──────────────────────────┘
```

The Terraform host itself does **not** need internet -- it only needs
SSH reachability to the nodes and a populated `bundle/` directory.

### 1. Build the bundle (on a machine WITH internet)

```bash
# Pull + save every container image, forced to linux/amd64
# (requirement #5 -- this matters even more if you're on Apple Silicon).
KUBERNETES_VERSION=1.33.0 CALICO_VERSION=v3.29.3 \
  ./bundle/prepare-bundle.sh --engine docker
```

```bash
# Download every RPM, fully dependency-resolved.
# Default mode re-execs itself inside a linux/amd64 EL9 container
# (Rocky Linux) -- this is the path most Mac users want:
./bundle/prepare-rpms.sh
# On an actual subscribed RHEL 9 box with internet, prefer:
./bundle/prepare-rpms.sh --mode host
```

Rocky/Alma base packages carry different vendor build tags than
RHEL's, but in practice the target RHEL 9 nodes already have those
base packages at an equal-or-newer version, so `dnf` on the node
skips them as already-satisfied and only installs what's genuinely
missing (containerd, kubelet, kubeadm, kubectl, haproxy, keepalived,
and their k8s-specific deps). **If a node ever reports a conflicting
base package** during `scripts/10-install-packages.sh`, that node's
base packages have drifted from RHEL defaults -- re-run
`prepare-rpms.sh --mode host` on a real subscribed RHEL 9 box.

### 2. Carry `bundle/` across the air gap

`bundle/images/`, `bundle/rpms/`, and `bundle/manifests/` are
git-ignored (multi-GB payload -- see `.gitignore`). Copy the whole
`bundle/` directory onto the Terraform host by whatever means your
site allows (USB drive, approved file transfer, artifact repository
mirror). The git repo itself -- `.tf` files, `scripts/`, `templates/`
-- travels normally, e.g. by cloning inside the air-gapped network if
you also mirror git internally, or by copying the repo alongside the
bundle.

### 3. Apply, inside the air-gapped network

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars         # real node IPs, real VIP
terraform init
terraform plan                    # will fail loudly on confirm_bootstrap -- read the full target list it prints
# set confirm_bootstrap = "yes-bootstrap-new-cluster" once you've verified the target list
terraform apply
```

## Prerequisites on the nodes

- RHEL 9, x86_64, already installed and network-reachable from the
  Terraform host over SSH.
- An SSH user (default `sarvadmin`) that already exists on every node
  with **passwordless sudo**. Terraform cannot create this user or
  configure sudoers on a host it has no other way to reach.
- A **free** VIP address -- not assigned to any node's NIC. `keepalived`
  assigns it at runtime; if it collided with a real node IP, that node
  ends up double-addressed. Enforced by a `lifecycle.precondition`.
- **Odd** master count, for etcd quorum. Also enforced at plan time.
- Enough local disk for the bundle plus normal container image
  growth -- remember, images are never garbage-collected here
  (`imageGCHighThresholdPercent: 100`), so disk sizing has to account
  for the full image set living on every node permanently.

## `manage_vip`: who owns the VIP?

| | `manage_vip = true` | `manage_vip = false` |
|---|---|---|
| Who runs haproxy/keepalived | This project, on `proxy_nodes` (or the masters if `proxy_nodes = []`) | Nobody -- an external LB (F5, hardware VIP, network team's own haproxy pair) already fronts the VIP |
| Phase 4 | Installs + configures haproxy/keepalived | No-op (0 instances) |
| What you must get right | `api_vip` is free, `apiserver_bind_port != api_vip_port` if colocated on masters (the two-port rule) | The external LB must TCP health-check `apiserver_bind_port` on every master, and forward to `api_vip:api_vip_port` |
| `proxy_nodes` | `[]` to colocate on masters, or a dedicated list | Ignored |

### The two-port rule

`kube-apiserver` binds `0.0.0.0:<port>`. If haproxy is colocated on
the same host (`manage_vip = true` and `proxy_nodes = []`), it also
wants `0.0.0.0:api_vip_port` for the client-facing side -- there is no
free address left on that port on that host. So in that specific
layout, `apiserver_bind_port` (default `6444`) must differ from
`api_vip_port` (default `6443`). Traffic path:

```
client -> VIP:6443 (haproxy) -> master:6444 (kube-apiserver)
```

This is checked by a `lifecycle.precondition` on the phase-0 guard
resource **at plan time**, not discovered mid-bootstrap when
kube-apiserver fails to bind.

## The `confirm_bootstrap` interlock

`terraform apply` refuses to do anything unless
`confirm_bootstrap = "yes-bootstrap-new-cluster"` **exactly**. The
failure message lists every master and worker IP about to be
bootstrapped, so a wrong tfvars file is obvious before you retype the
string.

**Never point this at a live cluster's node list.** This project's
only job is *initialising* a cluster (`kubeadm init` / `kubeadm
join`); nothing about it is safe to re-run against a cluster that's
already serving production traffic. If you need to re-verify a live
cluster's health, run `scripts/99-verify.sh` by hand over SSH instead
of `terraform apply`.

## Air-gap firewall ports

Sites that keep `firewalld` running (the defaults here disable it,
since the network boundary is normally handled upstream on an
internal air-gapped segment) need at least:

| Port(s) | Protocol | Purpose |
|---|---|---|
| 6443 | TCP | API via VIP (`api_vip_port`) |
| 6444 | TCP | API on each master directly (`apiserver_bind_port`) |
| 2379-2380 | TCP | etcd client/peer |
| 10250 | TCP | kubelet API |
| 10256 | TCP | kube-proxy health |
| 30000-32767 | TCP | NodePort range |
| -- | VRRP (IP proto 112) | keepalived, between VIP-fronting nodes |
| -- | IPIP (IP proto 4) | Calico, when `calico_encapsulation = "ipip"` |
| 4789 | UDP | Calico VXLAN, when `calico_encapsulation = "vxlan"` (use this if your fabric blocks IP proto 4) |

## Adding a node later, with no internet

The bundle stays staged at `remote_stage_dir` (default
`/opt/k8s-airgap`) on every node that's already been provisioned --
nothing about it is cleaned up after bootstrap. To add a node:

1. Add the new node's `{name, ip}` to `masters` or `workers` in
   `terraform.tfvars`.
2. `terraform apply` again. Phases 0-3 run for every node (existing
   nodes' scripts are all idempotent no-ops, per requirement #11);
   the new node gets the tarball uploaded, prepped, and its images
   loaded, exactly like the first run.
3. Phase 5b's CNI apply and phase 7's addons apply also just
   converge (`kubectl apply`) -- nothing is disturbed on nodes already
   running.
4. The join token was set to never expire (`ttl: "0s"` in
   `kubeadm-init.yaml.tftpl`) specifically so this works without
   regenerating anything -- the same token and CA hash Terraform
   already has in state are reused.

No internet is required at any point in this flow -- the bundle
that's already on disk (or re-uploaded from the same local `bundle/`
directory on the Terraform host) is all that's needed.

## Troubleshooting

**`exec format error` in a container's logs.** The bundle was built
for the wrong architecture -- almost always an Apple Silicon build
machine where `bundle/prepare-bundle.sh` was run without Docker
Desktop/podman machine actually emulating `linux/amd64`. Re-run
`prepare-bundle.sh` and confirm `docker inspect <image> --format
'{{.Architecture}}'` says `amd64` before repacking.

**A node is stuck `NotReady`.** Almost always CNI. Check:
```bash
kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
kubectl describe node <node>
```
If `calico-node` never got scheduled or is crash-looping, check that
`scripts/00-node-prep.sh`'s NetworkManager drop-in
(`/etc/NetworkManager/conf.d/k8s-unmanaged.conf`) is present --
without it, NetworkManager fights Calico for the `cali*`/`tunl*`
interfaces (requirement #13).

**The VIP doesn't answer.** On each VIP-fronting node:
```bash
ip -4 -o addr show                       # is the VIP actually assigned anywhere?
systemctl status haproxy keepalived      # both running?
journalctl -u keepalived -n 50           # VRRP election / priority changes
```
Remember `nopreempt` is set -- once a BACKUP takes the VIP, it keeps
it even after a higher-priority node comes back. That's intentional
(avoids VIP ping-pong), not a bug.

**`ErrImageNeverPull` on a pod.** `bundle/prepare-bundle.sh` missed an
image/tag. Cross-check what's actually loaded against what the pod
wants:
```bash
ctr -n k8s.io images ls | grep <image-name>
kubectl describe pod <pod> | grep Image:
```
Add the missing `ref` to `CORE_IMAGES`/`CALICO_IMAGES`/`INGRESS_IMAGES`
in `bundle/prepare-bundle.sh`, rebuild the bundle, and re-run
`terraform apply` (phase 3 re-imports; it's idempotent per-tarball).

## Repository layout

```
.
├── README.md
├── .gitignore
├── versions.tf                  # terraform >= 1.5, providers: null, random, local, external
├── variables.tf                 # all inputs, documented, with validation blocks
├── locals.tf                    # node sets, derived config, rendered artefacts
├── main.tf                      # the 9 phases, null_resource per phase
├── outputs.tf                   # endpoint, node lists, next-steps runbook
├── terraform.tfvars.example     # documented reference topology (never auto-loaded)
├── bundle/
│   ├── prepare-bundle.sh        # RUN WITH INTERNET: pull+save images, fetch manifests
│   └── prepare-rpms.sh          # RUN WITH INTERNET: dnf download --resolve into rpms/
├── scripts/
│   ├── pack-bundle.sh           # runs on TF host: validate bundle, pack one tarball
│   ├── 00-node-prep.sh          # hostname, hosts, swap, selinux, firewalld, modules, sysctl
│   ├── 10-install-packages.sh   # offline RPM install (containerd + kubeadm/kubelet/kubectl)
│   ├── 20-load-images.sh        # ctr -n k8s.io images import (every tarball)
│   ├── 30-proxy-setup.sh        # haproxy + keepalived, substitute real NIC name
│   ├── 40-init-first-master.sh  # kubeadm init (idempotent)
│   ├── 50-join.sh               # kubeadm join, control-plane or worker (idempotent)
│   ├── 55-cni.sh                # Calico, BEFORE any other node joins
│   ├── 60-addons.sh             # ingress-nginx, StorageClass, node role labels
│   ├── 99-verify.sh             # health report; non-zero exit fails the apply
│   ├── fetch-join-info.sh       # TF external data source -> {"ca_cert_hash": "..."}
│   └── wait-cp-ready.sh         # gate: block until N control-plane nodes are Ready
├── templates/
│   ├── kubeadm-init.yaml.tftpl
│   ├── kubeadm-join.yaml.tftpl
│   ├── haproxy.cfg.tftpl
│   ├── keepalived.conf.tftpl
│   ├── check_apiserver.sh.tftpl
│   └── ingress-nginx-daemonset.yaml.tftpl
└── manifests/
    └── local-storage-sc.yaml
```

## Apply phases

| # | Name | What | Parallelism |
|---|---|---|---|
| 0 | guard | Refuse to apply unless `confirm_bootstrap` is set; validate topology | -- |
| 1 | bundle | Verify bundle completeness locally, pack ONE tarball | -- |
| 2 | upload | SCP the tarball to every node (skippable via `skip_upload`) | parallel |
| 3 | prep | RHEL prep -> offline RPM install -> preload images | parallel |
| 4 | vip | haproxy + keepalived (only when `manage_vip = true`) | parallel |
| 5 | init | `kubeadm init` on the first master | -- |
| 5b | cni | Calico -- before any other node joins | -- |
| 6a | join (control-plane) | Additional masters, **serially** (gated by `wait-cp-ready.sh`) | serial |
| 6b | join (workers) | Workers, in parallel, after all masters | parallel |
| 7 | addons | ingress-nginx, StorageClass, node role labels | -- |
| 8 | verify | Health report; **fails the apply** if the cluster is wrong | -- |

## Non-obvious requirements this project actually implements

Short pointer list -- see the referenced files' comments for the full
reasoning:

1. **Two-port rule** -- `main.tf` (`null_resource.guard` precondition), `variables.tf` (`apiserver_bind_port`)
2. **Serialised control-plane joins** -- `scripts/wait-cp-ready.sh`, `main.tf` (`null_resource.join_masters`)
3. **CNI before joins** -- `scripts/55-cni.sh` runs in its own phase (5b), strictly before phase 6
4. **Images never pulled/evicted** -- `scripts/20-load-images.sh` (the `k8s.io` namespace), `templates/kubeadm-init.yaml.tftpl` (`imageGC*ThresholdPercent`)
5. **Right architecture** -- `bundle/prepare-bundle.sh` (`--platform linux/amd64` on every pull)
6. **RPM resolution against EL9** -- `bundle/prepare-rpms.sh` (`--mode host` / `--mode container`)
7. **keepalived unicast** -- `templates/keepalived.conf.tftpl`
8. **NIC names substituted at apply time** -- `scripts/30-proxy-setup.sh`, `templates/keepalived.conf.tftpl` (`INTERFACE_PLACEHOLDER`)
9. **VIP must be free / odd masters / unique IPs+names** -- `main.tf` (`null_resource.guard` preconditions)
10. **Only the CA hash is read back** -- `scripts/fetch-join-info.sh`, `data.external.join_info` in `main.tf`
11. **Every remote script is idempotent** -- see the header comment of each script under `scripts/`
12. **Safety interlock** -- `variables.tf` (`confirm_bootstrap`), `main.tf` (`null_resource.guard`)
13. **NetworkManager leaves CNI interfaces alone** -- `scripts/00-node-prep.sh`
14. **`.gitignore` excludes the payload and credentials** -- `.gitignore`

## Optional egress proxy

Off by default (`http_proxy_url = ""`). When set:

- `scripts/00-node-prep.sh` writes `/etc/environment`, a containerd
  systemd drop-in, and `/etc/dnf/dnf.conf`'s `proxy=` line.
- `NO_PROXY` is computed automatically in `locals.tf`
  (`no_proxy_auto`) and always includes `localhost`, `127.0.0.1`, the
  pod subnet, the service subnet, the API VIP, every node IP and
  name, and `.svc`/`.cluster.local` -- getting this wrong sends
  in-cluster traffic through the proxy and breaks the cluster in ways
  that are painful to debug.
- With both URLs left empty, the entire bootstrap completes with
  **zero egress** -- no phase depends on the proxy being reachable.

## What was intentionally simplified

Being upfront, for a reviewer: this project implements every phase
and requirement in the build spec, but a few real-world edges were
simplified rather than fully engineered, given this is a portfolio
piece rather than a production-hardened tool:

- `scripts/55-cni.sh` patches the upstream Calico manifest with
  `sed`/`python3` text substitution rather than driving it through
  the Tigera operator's CRDs -- simpler, but less flexible if you
  need per-pool BGP peering later.
- `scripts/99-verify.sh`'s etcd member check execs into the etcd pod
  rather than using a dedicated etcdctl binary on the host; fine for
  a health gate, not a replacement for a real etcd backup/restore
  runbook.
- RPM version pinning in `bundle/prepare-rpms.sh` assumes package
  names as published on `pkgs.k8s.io`; if an upstream repo layout
  changes, that script's `dnf download` arguments need updating.

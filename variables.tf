############################################################
# variables.tf
#
# Cross-variable checks (odd master count vs. VIP collisions,
# the two-port rule, unique IPs/names, etc.) are enforced as
# lifecycle.preconditions on the phase-0 "guard" null_resource
# in main.tf, NOT here. As of Terraform 1.5, a `validation`
# block may only reference the variable it is attached to, so
# anything that needs to compare two variables against each
# other has to live where both are in scope — a resource.
############################################################

# ------------------------------------------------------------------
# Safety interlock (requirement #12)
# ------------------------------------------------------------------
variable "confirm_bootstrap" {
  type = string
  description = <<-EOT
    Hard interlock against running this against the wrong environment.
    Must be set to the exact literal string "yes-bootstrap-new-cluster".

    This project's job is to INITIALISE a cluster (kubeadm init /
    kubeadm join). There is nothing about kubeadm that makes it safe
    to re-point at a cluster that is already serving traffic — a
    stray `terraform apply` with the wrong tfvars file could just as
    easily be aimed at a live prod cluster's node list as a fresh
    one. Typing this string is a deliberate, hard-to-fat-finger act,
    the same idea as typing a bucket name before `terraform destroy`.

    NEVER point this at a live cluster's node list "just to re-run
    verify" — use scripts/99-verify.sh by hand over SSH instead.
  EOT

  validation {
    condition     = var.confirm_bootstrap == "yes-bootstrap-new-cluster"
    error_message = "confirm_bootstrap must be exactly \"yes-bootstrap-new-cluster\". This is a deliberate interlock -- see variables.tf."
  }
}

# ------------------------------------------------------------------
# SSH access to the pre-existing hosts
# ------------------------------------------------------------------
variable "ssh_user" {
  type        = string
  default     = "sarvadmin"
  description = <<-EOT
    User Terraform SSHes in as to configure every node. Must already
    exist on every host with passwordless sudo (NOPASSWD: ALL, or at
    minimum the specific commands these scripts run) -- Terraform
    does not, and cannot, create this user or provision sudoers on
    an air-gapped host it has no other way to reach.
  EOT
}

variable "ssh_private_key_path" {
  type        = string
  default     = ""
  description = <<-EOT
    Path to a private key file for SSH auth. Leave "" to fall back to
    ssh-agent (the connection block omits `private_key` in that
    case). Never put key *contents* in a variable -- that would land
    the key in the state file.
  EOT
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port on every node (masters, workers, and dedicated proxy nodes alike)."
}

variable "ssh_agent" {
  type        = bool
  default     = true
  description = "Whether provisioner SSH connections should use the local ssh-agent. Set false if you only ever authenticate with ssh_private_key_path."
}

# ------------------------------------------------------------------
# Topology -- the nodes already exist, we only describe them
# ------------------------------------------------------------------
variable "masters" {
  type = list(object({
    name = string
    ip   = string
  }))
  description = <<-EOT
    Control-plane nodes. Count MUST be odd (etcd quorum survives
    floor(N/2) failures; an even count buys no extra tolerance over
    N-1 and adds a split-brain risk). Enforced by lifecycle
    .precondition on the phase-0 guard resource, not here, because
    the check also needs to report the member list on failure.
    First element in list order is used as the etcd/kubeadm-init
    node ("first master") -- order matters.
  EOT
}

variable "workers" {
  type = list(object({
    name = string
    ip   = string
  }))
  default     = []
  description = "Worker nodes. May be empty for a control-plane-only cluster (ingress-nginx and other workloads then run on tainted masters)."
}

variable "proxy_nodes" {
  type = list(object({
    name = string
    ip   = string
  }))
  default     = []
  description = <<-EOT
    Optional dedicated nodes to run haproxy+keepalived on, instead of
    colocating them on the control-plane nodes. Leave empty to
    colocate on the masters (the common case for a small cluster).
    When non-empty, apiserver_bind_port and api_vip_port may safely
    be equal, since haproxy is no longer sharing a network namespace
    with kube-apiserver -- see the two-port rule (requirement #1).
  EOT
}

# ------------------------------------------------------------------
# API VIP / load-balancing (requirement #1, #7, #8, #9)
# ------------------------------------------------------------------
variable "manage_vip" {
  type        = bool
  default     = true
  description = <<-EOT
    true  -> this project owns the VIP: it installs haproxy +
             keepalived on the masters (or proxy_nodes) and manages
             VRRP failover itself.
    false -> an external network load balancer (F5, a hardware VIP,
             an upstream haproxy pair the network team already runs)
             already fronts api_vip:api_vip_port and health-checks
             each master on apiserver_bind_port. This project then
             does none of the haproxy/keepalived work (phase 4 is a
             no-op) and just points kubeadm at the externally-owned
             VIP.
    See the README's manage_vip decision table.
  EOT
}

variable "api_vip" {
  type        = string
  description = <<-EOT
    The floating IP that fronts the API server (kube-apiserver via
    haproxy, or an external LB's VIP). MUST NOT be any node's own
    IP -- keepalived assigns it to a NIC at runtime, so if it
    collided with a real node IP that node would end up double-
    addressed. Enforced by lifecycle.precondition in main.tf.
  EOT
}

variable "api_vip_port" {
  type        = number
  default     = 6443
  description = "Port clients (kubectl, kubelets, kube-proxy) talk to the VIP on. Standard kube-apiserver port; kept at 6443 so kubeconfigs look normal."
}

variable "apiserver_bind_port" {
  type        = number
  default     = 6444
  description = <<-EOT
    Port kube-apiserver itself actually listens on, on each master.

    THE TWO-PORT RULE (requirement #1): kube-apiserver binds
    0.0.0.0:<port>. If haproxy is colocated on the same host (i.e.
    proxy_nodes is empty) it ALSO wants to bind 0.0.0.0:api_vip_port
    to accept client traffic before load-balancing it back to the
    local apiserver -- there is no free address left on that port.
    So when manage_vip=true and proxy_nodes=[], apiserver_bind_port
    must differ from api_vip_port. Traffic path in that layout:

        client -> VIP:6443 (haproxy) -> 127.0.0.1 or master:6444 (apiserver)

    When proxy_nodes is non-empty, or manage_vip=false, haproxy (or
    the external LB) lives on a different host from kube-apiserver,
    so this restriction doesn't apply and apiserver_bind_port may
    equal api_vip_port (e.g. plain 6443 throughout) if you prefer.
    Checked with a lifecycle.precondition at plan time -- see
    main.tf phase 0.
  EOT
}

# ------------------------------------------------------------------
# Cluster networking
# ------------------------------------------------------------------
variable "pod_subnet" {
  type        = string
  default     = "10.244.0.0/16"
  description = "Pod CIDR. Must match what's baked into calico's IPPool at apply time (see templates rendered from calico_encapsulation)."
}

variable "service_subnet" {
  type        = string
  default     = "10.96.0.0/12"
  description = "ClusterIP service CIDR."
}

variable "dns_domain" {
  type        = string
  default     = "cluster.local"
  description = "Cluster DNS domain suffix used by CoreDNS and every kubelet."
}

variable "kube_proxy_mode" {
  type        = string
  default     = "iptables"
  description = "kube-proxy mode. \"iptables\" is the safe default; \"ipvs\" needs ipvsadm + kernel modules, which 00-node-prep.sh loads either way so both work."
  validation {
    condition     = contains(["iptables", "ipvs"], var.kube_proxy_mode)
    error_message = "kube_proxy_mode must be \"iptables\" or \"ipvs\"."
  }
}

variable "calico_encapsulation" {
  type        = string
  default     = "ipip"
  description = <<-EOT
    "ipip"  -> IPPool encapsulation Always, IP protocol 4. Simple,
               but some enterprise firewalls / cloud fabrics filter
               IP protocol 4 outright.
    "vxlan" -> UDP/4789 instead. Pick this on networks that are
               known to block non-TCP/UDP IP protocols.
    Drives both the rendered Calico manifest and the README firewall
    port table.
  EOT
  validation {
    condition     = contains(["ipip", "vxlan"], var.calico_encapsulation)
    error_message = "calico_encapsulation must be \"ipip\" or \"vxlan\"."
  }
}

# ------------------------------------------------------------------
# Pinned component versions (defaults per the build spec)
# ------------------------------------------------------------------
variable "kubernetes_version" {
  type        = string
  default     = "1.33.0"
  description = "kubeadm/kubelet/kubectl version. Must match the RPM release the bundle was built for and the image tags preloaded into containerd."
}

variable "kubernetes_rpm_release" {
  type        = string
  default     = "150500.1.1"
  description = "RPM package release suffix for the pinned kubernetes_version, as published in the EL9 kubernetes yum repo (pkgs.k8s.io)."
}

variable "containerd_version" {
  type    = string
  default = "2.2.2"
}

variable "calico_version" {
  type        = string
  default     = "v3.29.3"
  description = "Tigera Calico version. blockSize 26 and IPPool encapsulation are set in the rendered manifest, driven by calico_encapsulation."
}

variable "ingress_nginx_version" {
  type    = string
  default = "v1.12.2"
}

variable "ingress_nginx_certgen_version" {
  type        = string
  default     = "v1.5.3"
  description = "ingress-nginx admission webhook cert-gen/patch image tag."
}

variable "coredns_version" {
  type    = string
  default = "v1.12.0"
}

variable "etcd_version" {
  type    = string
  default = "3.5.21-0"
}

variable "pause_image_version" {
  type        = string
  default     = "3.10.1"
  description = "Primary pause image tag. prepare-bundle.sh also fetches pause:3.10 (untagged patch) since some older manifests/kubelet defaults still reference it -- see requirement #5."
}

# ------------------------------------------------------------------
# Bundle / staging
# ------------------------------------------------------------------
variable "remote_stage_dir" {
  type        = string
  default     = "/opt/k8s-airgap"
  description = "Directory on every node the bundle is unpacked into and scripts are staged/run from. Also where a later `add a node` re-run finds the bundle already sitting, with no internet required (see README)."
}

variable "skip_upload" {
  type        = bool
  default     = false
  description = "Skip phase 2 (SCP of the packed bundle tarball) entirely -- for re-applies where every node already has an identical bundle staged at remote_stage_dir, so we don't push multiple GB over the wire again."
}

# ------------------------------------------------------------------
# Add-ons
# ------------------------------------------------------------------
variable "enable_ingress_nginx" {
  type    = bool
  default = true
}

variable "ingress_http_nodeport" {
  type        = number
  default     = 30408
  description = "hostNetwork port ingress-nginx listens on for HTTP (non-standard, high, to avoid clashing with other host services on control-plane nodes)."
}

variable "ingress_https_nodeport" {
  type    = number
  default = 32521
}

variable "enable_local_storage" {
  type        = bool
  default     = true
  description = "Install the local-storage no-provisioner StorageClass (manifests/local-storage-sc.yaml)."
}

# ------------------------------------------------------------------
# Optional egress proxy (NEW capability -- opt-in, off by default)
# ------------------------------------------------------------------
variable "http_proxy_url" {
  type        = string
  default     = ""
  description = <<-EOT
    HTTP proxy URL (e.g. "http://proxy.example.internal:3128"), reachable
    on a VIP at this site. OPT-IN. Left at "", the entire bootstrap
    completes with ZERO egress -- no phase may ever hard-depend on
    the proxy being reachable, because it is explicitly called out
    as unreliable for node bootstrap. See README and 00-node-prep.sh.
  EOT
}

variable "https_proxy_url" {
  type        = string
  default     = ""
  description = "HTTPS proxy URL. Usually identical to http_proxy_url; kept separate because some sites terminate them on different VIPs/ports."
}

variable "no_proxy_extra" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Extra hostnames/CIDRs to append to NO_PROXY, on top of the ones
    this project always adds automatically (localhost, 127.0.0.1,
    pod_subnet, service_subnet, api_vip, every node IP and name,
    .svc, .cluster.local -- see locals.tf). Getting the automatic
    set wrong sends in-cluster traffic through the proxy and breaks
    the cluster in ways that are painful to debug, so it is computed,
    not left to the operator to remember.
  EOT
}

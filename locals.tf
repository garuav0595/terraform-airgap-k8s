############################################################
# locals.tf
#
# All the "derive it once, correctly, in one place" logic lives
# here so main.tf reads as a sequence of phases rather than a
# pile of inline for-expressions repeated per resource.
############################################################

locals {
  # ------------------------------------------------------------
  # Node identity maps, keyed by name (Terraform for_each needs
  # a stable string key, not a list index -- list indices shift
  # if someone reorders tfvars and that would make Terraform
  # think it needs to destroy/recreate provisioner state for an
  # unrelated node).
  # ------------------------------------------------------------
  master_nodes     = { for m in var.masters : m.name => merge(m, { role = "master" }) }
  worker_nodes     = { for w in var.workers : w.name => merge(w, { role = "worker" }) }
  proxy_only_nodes = { for p in var.proxy_nodes : p.name => merge(p, { role = "proxy" }) }

  all_nodes = merge(local.master_nodes, local.worker_nodes, local.proxy_only_nodes)
  all_ips   = [for n in local.all_nodes : n.ip]
  all_names = [for n in local.all_nodes : n.name]

  # Human-readable target list embedded in the guard's error message
  # (requirement #12: the confirm_bootstrap failure must show every
  # master/worker IP about to be touched, so a mistyped tfvars file
  # is obvious before anyone re-types the confirm string).
  guard_target_summary = join(", ", [
    for n in concat(
      [for m in var.masters : merge(m, { role = "master" })],
      [for w in var.workers : merge(w, { role = "worker" })]
    ) : "${n.role}:${n.name}(${n.ip})"
  ])

  # ------------------------------------------------------------
  # Control-plane join order (requirement #2: serialise CP joins)
  #
  # var.masters[0] runs kubeadm init. Every other master gets a
  # 0-based join_index among "the others" -- join_index N must
  # observe N+1 Ready control-plane nodes (itself not counted yet)
  # before it is allowed to run `kubeadm join --control-plane`.
  # join_index 0 -> waits for 1 (just the first master).
  # join_index 1 -> waits for 2 (first master + the first "other").
  # ------------------------------------------------------------
  first_master   = var.masters[0]
  other_masters  = length(var.masters) > 1 ? slice(var.masters, 1, length(var.masters)) : []
  other_masters_indexed = {
    for idx, m in local.other_masters : m.name => merge(m, {
      join_index    = idx
      expect_ready  = idx + 1
    })
  }

  # ------------------------------------------------------------
  # VIP fronting nodes: dedicated proxy_nodes if given, else the
  # masters themselves are colocated with haproxy+keepalived.
  # Priorities descend 150, 140, 130... (requirement #7): first
  # in list order is VRRP MASTER, everyone else BACKUP, with
  # nopreempt so a flapping "highest priority" node doesn't cause
  # VIP ping-pong once a BACKUP has taken over.
  # ------------------------------------------------------------
  vip_nodes_list = length(var.proxy_nodes) > 0 ? var.proxy_nodes : var.masters

  vip_nodes_indexed = {
    for idx, n in local.vip_nodes_list : n.name => merge(n, {
      index    = idx
      state    = idx == 0 ? "MASTER" : "BACKUP"
      priority = 150 - (idx * 10)
      # unicast, never multicast (requirement #7) -- every switch
      # fabric we've hit in the field drops 224.0.0.18 across VLANs.
      unicast_src_ip = n.ip
      unicast_peers  = [for p in local.vip_nodes_list : p.ip if p.ip != n.ip]
    })
  }

  # true only when haproxy/keepalived are colocated with kube-apiserver
  # on the master nodes -- this is exactly the condition the two-port
  # rule precondition (main.tf phase 0) checks.
  vip_colocated_with_masters = var.manage_vip && length(var.proxy_nodes) == 0

  # ------------------------------------------------------------
  # NO_PROXY -- computed, never left to the operator to hand-type.
  # Must cover everything cluster-internal or the proxy swallows
  # pod<->pod, kubelet<->apiserver, and health-check traffic in
  # ways that are miserable to debug (spec is explicit about this).
  # ------------------------------------------------------------
  no_proxy_auto = concat(
    ["localhost", "127.0.0.1", var.pod_subnet, var.service_subnet, var.api_vip],
    local.all_ips,
    local.all_names,
    [".svc", ".${var.dns_domain}", "kubernetes", "kubernetes.default"]
  )
  no_proxy_list = distinct(concat(local.no_proxy_auto, var.no_proxy_extra))
  no_proxy_csv  = join(",", local.no_proxy_list)

  # Whether the optional proxy is in play at all. With both URLs
  # empty, 00-node-prep.sh is passed --http-proxy "" --https-proxy ""
  # and writes nothing proxy-related -- zero egress, as required.
  proxy_enabled = var.http_proxy_url != "" || var.https_proxy_url != ""

  # ------------------------------------------------------------
  # Bundle staging paths (Terraform host side)
  # ------------------------------------------------------------
  bundle_dir            = "${path.module}/bundle"
  bundle_tarball_name    = "k8s-airgap-bundle.tar.gz"
  bundle_tarball_local   = "${path.module}/.artifacts/${local.bundle_tarball_name}"
  bundle_version_marker  = "${local.bundle_dir}/.bundle-version"
  remote_tarball_path    = "${var.remote_stage_dir}/${local.bundle_tarball_name}"

  # Re-pack trigger: hash of pack-bundle.sh's own version marker file,
  # written after a successful pack. Missing on a fresh checkout (the
  # bundle/ payload is gitignored) so we fall back to a constant --
  # phase 1 then always runs once, and pack-bundle.sh's own content
  # hash check makes re-running it a cheap no-op if nothing changed.
  bundle_trigger = try(filesha1(local.bundle_version_marker), "unbuilt")

  # ------------------------------------------------------------
  # /etc/hosts entries -- air-gapped sites usually have no
  # node-FQDN DNS at all, so every node needs every other node's
  # name resolvable locally (masters, workers, AND proxy_nodes).
  # ------------------------------------------------------------
  hosts_entries = [for n in local.all_nodes : "${n.ip} ${n.name}"]
  hosts_file_body = join("\n", local.hosts_entries)

  # SSH private key contents, only read from disk when a path was
  # given -- otherwise provisioner connection blocks omit the
  # private_key argument entirely and fall back to ssh-agent.
  ssh_private_key_content = var.ssh_private_key_path != "" ? file(var.ssh_private_key_path) : null

  # kube-apiserver certSANs: the VIP (however clients actually reach
  # the cluster) plus every master's own IP/name (so `kubectl` still
  # works if pointed directly at a master, bypassing the VIP, e.g.
  # for break-glass access while haproxy/keepalived are down).
  cert_sans = distinct(concat(
    ["127.0.0.1", "localhost", var.api_vip],
    [for m in var.masters : m.ip],
    [for m in var.masters : m.name],
  ))

  remote_scripts_dir = "${var.remote_stage_dir}/scripts"

  # kubeadm token, assembled from two random_string resources
  # (main.tf) rather than one, so each half can use the exact
  # alphabet kubeadm's `^[a-z0-9]{6}\.[a-z0-9]{16}$` token regex
  # requires without fighting random_string's separator options.
  kubeadm_token = "${random_string.token_id.result}.${random_string.token_secret.result}"

  # ------------------------------------------------------------
  # Rendered artefacts. Centralised here (rather than inline in
  # main.tf's provisioner blocks) so what gets written to each node
  # is reviewable in one place, independent of *when* in the apply
  # graph it gets uploaded.
  # ------------------------------------------------------------
  rendered_kubeadm_init_yaml = templatefile("${path.module}/templates/kubeadm-init.yaml.tftpl", {
    node_name            = local.first_master.name
    advertise_ip          = local.first_master.ip
    token                  = local.kubeadm_token
    kubernetes_version     = var.kubernetes_version
    api_vip                = var.api_vip
    api_vip_port           = var.api_vip_port
    apiserver_bind_port    = var.apiserver_bind_port
    pod_subnet             = var.pod_subnet
    service_subnet         = var.service_subnet
    dns_domain             = var.dns_domain
    etcd_version            = var.etcd_version
    kube_proxy_mode         = var.kube_proxy_mode
    cert_sans               = local.cert_sans
  })

  # One join config per additional master (control-plane join).
  rendered_kubeadm_join_yaml_masters = {
    for name, m in local.other_masters_indexed : name => templatefile("${path.module}/templates/kubeadm-join.yaml.tftpl", {
      node_name           = m.name
      advertise_ip         = m.ip
      token                 = local.kubeadm_token
      ca_cert_hash          = data.external.join_info.result.ca_cert_hash
      api_vip               = var.api_vip
      api_vip_port          = var.api_vip_port
      apiserver_bind_port   = var.apiserver_bind_port
      is_control_plane      = true
      certificate_key       = random_id.certificate_key.hex
    })
  }

  # One join config per worker (plain join, no controlPlane stanza).
  rendered_kubeadm_join_yaml_workers = {
    for name, w in local.worker_nodes : name => templatefile("${path.module}/templates/kubeadm-join.yaml.tftpl", {
      node_name           = w.name
      advertise_ip         = w.ip
      token                 = local.kubeadm_token
      ca_cert_hash          = data.external.join_info.result.ca_cert_hash
      api_vip               = var.api_vip
      api_vip_port          = var.api_vip_port
      apiserver_bind_port   = var.apiserver_bind_port
      is_control_plane      = false
      certificate_key       = "" # unused when is_control_plane=false, but templatefile still requires it defined
    })
  }

  # One haproxy.cfg / keepalived.conf pair per VIP-fronting node --
  # identical backend list (always ALL masters), but per-node
  # priority/state/unicast peers (requirement #7).
  rendered_haproxy_cfg = {
    for name, n in local.vip_nodes_indexed : name => templatefile("${path.module}/templates/haproxy.cfg.tftpl", {
      api_vip_port         = var.api_vip_port
      apiserver_bind_port   = var.apiserver_bind_port
      masters                = var.masters
    })
  }

  rendered_keepalived_conf = {
    for name, n in local.vip_nodes_indexed : name => templatefile("${path.module}/templates/keepalived.conf.tftpl", {
      node_name         = n.name
      state               = n.state
      priority             = n.priority
      unicast_src_ip       = n.unicast_src_ip
      unicast_peers        = n.unicast_peers
      auth_pass             = random_string.vrrp_auth_pass.result
      api_vip               = var.api_vip
    })
  }

  rendered_check_apiserver_sh = templatefile("${path.module}/templates/check_apiserver.sh.tftpl", {
    api_vip_port = var.api_vip_port
  })

  rendered_ingress_nginx_manifest = templatefile("${path.module}/templates/ingress-nginx-daemonset.yaml.tftpl", {
    ingress_nginx_version          = var.ingress_nginx_version
    ingress_nginx_certgen_version  = var.ingress_nginx_certgen_version
    ingress_http_nodeport           = var.ingress_http_nodeport
    ingress_https_nodeport          = var.ingress_https_nodeport
  })
}

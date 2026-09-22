############################################################
# main.tf
#
# Nine apply phases, each a null_resource (or, for phase 5b's CA-hash
# read-back, a data "external"), wired together with explicit
# depends_on so the graph reads top-to-bottom the same way the
# cluster actually comes up. See README.md for the full phase table.
############################################################

# ------------------------------------------------------------
# Secrets generated once, locally, in Terraform (requirement #10) --
# so nothing about cluster join has to be scraped from provisioner
# stdout or parsed out of a remote file. The ONE value that genuinely
# cannot exist before kubeadm init has run -- the CA hash -- is
# fetched via data.external.join_info below, and it is a PUBLIC value
# (see scripts/fetch-join-info.sh's header comment).
# ------------------------------------------------------------
resource "random_string" "token_id" {
  length  = 6
  upper   = false
  special = false
  # kubeadm bootstrap token format: ^[a-z0-9]{6}\.[a-z0-9]{16}$
}

resource "random_string" "token_secret" {
  length  = 16
  upper   = false
  special = false
}

resource "random_id" "certificate_key" {
  # 32 bytes -> 64 hex chars, exactly what `kubeadm init --upload-certs
  # --certificate-key` / JoinConfiguration.controlPlane.certificateKey
  # require.
  byte_length = 32
}

resource "random_string" "vrrp_auth_pass" {
  length  = 8 # keepalived's PASS auth type silently truncates beyond 8
  special = false
}

# ------------------------------------------------------------
# Phase 0 -- guard
#
# Refuses to apply unless confirm_bootstrap is set, and validates the
# topology at plan time. Every cross-variable check that Terraform
# 1.5's `validation` blocks cannot express (they may only reference
# their own variable) lives here as a lifecycle.precondition instead.
# ------------------------------------------------------------
resource "null_resource" "guard" {
  triggers = {
    confirm_bootstrap = var.confirm_bootstrap
  }

  lifecycle {
    precondition {
      condition     = var.confirm_bootstrap == "yes-bootstrap-new-cluster"
      error_message = <<-EOT
        Refusing to apply: confirm_bootstrap is not set to the exact
        interlock string. This apply would bootstrap a NEW cluster on:
        ${local.guard_target_summary}
        Set confirm_bootstrap = "yes-bootstrap-new-cluster" only if that
        is really what you want, and NEVER point this at a live cluster's
        node list.
      EOT
    }

    # etcd quorum survives floor(N/2) member failures -- an even
    # master count buys no extra tolerance over N-1 and adds a
    # split-brain risk during network partitions.
    precondition {
      condition     = length(var.masters) % 2 == 1
      error_message = "masters count must be odd for etcd quorum (got ${length(var.masters)}: ${join(", ", [for m in var.masters : m.name])})."
    }

    precondition {
      condition     = length(distinct(local.all_ips)) == length(local.all_ips)
      error_message = "Duplicate IP address across masters/workers/proxy_nodes -- every node IP must be unique."
    }

    precondition {
      condition     = length(distinct(local.all_names)) == length(local.all_names)
      error_message = "Duplicate node name across masters/workers/proxy_nodes -- every node name must be unique."
    }

    # keepalived assigns the VIP to a NIC at runtime -- it cannot be
    # one of the nodes' own IPs, or that node ends up double-addressed
    # (requirement #9).
    precondition {
      condition     = !contains(local.all_ips, var.api_vip)
      error_message = "api_vip (${var.api_vip}) collides with a node's own IP. The VIP must be a free address."
    }

    # THE TWO-PORT RULE (requirement #1): kube-apiserver binds
    # 0.0.0.0:apiserver_bind_port. If haproxy is colocated on the
    # same host (manage_vip=true, proxy_nodes=[]) it also wants
    # 0.0.0.0:api_vip_port -- there is no free address left on that
    # port if the two are equal.
    precondition {
      condition     = !(local.vip_colocated_with_masters && var.apiserver_bind_port == var.api_vip_port)
      error_message = "Two-port rule violated: manage_vip=true with proxy_nodes=[] colocates haproxy with kube-apiserver, so apiserver_bind_port (${var.apiserver_bind_port}) must differ from api_vip_port (${var.api_vip_port})."
    }
  }
}

# ------------------------------------------------------------
# Phase 1 -- bundle
#
# Validates bundle/ completeness and packs ONE tarball, on the
# Terraform host. See scripts/pack-bundle.sh for why: catching a
# missing image HERE (on the machine with internet) is infinitely
# cheaper than discovering it mid-join on node 4 of 5.
# ------------------------------------------------------------
resource "null_resource" "pack_bundle" {
  depends_on = [null_resource.guard]

  triggers = {
    bundle_trigger = local.bundle_trigger
  }

  provisioner "local-exec" {
    command = "bash '${path.module}/scripts/pack-bundle.sh' --bundle-dir '${local.bundle_dir}' --out '${local.bundle_tarball_local}'"
  }
}

# ------------------------------------------------------------
# Phase 2 -- upload
#
# SCPs the packed tarball + the scripts/ directory to every node.
# Skippable via skip_upload for a re-apply where every node already
# has an identical bundle staged (saves pushing multi-GB over the
# wire again for, say, a config-only re-run).
# ------------------------------------------------------------
resource "null_resource" "upload" {
  for_each = var.skip_upload ? {} : local.all_nodes

  depends_on = [null_resource.pack_bundle]

  triggers = {
    bundle_trigger = local.bundle_trigger
    node_ip        = each.value.ip
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p ${var.remote_stage_dir}",
      "sudo chown ${var.ssh_user}:${var.ssh_user} ${var.remote_stage_dir}",
    ]
  }

  provisioner "file" {
    source      = local.bundle_tarball_local
    destination = local.remote_tarball_path
  }

  # Scripts are uploaded separately from the (gitignored, multi-GB)
  # bundle payload -- they're small, versioned in git, and change far
  # more often than images/RPMs do.
  provisioner "file" {
    source      = "${path.module}/scripts"
    destination = var.remote_stage_dir
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x ${local.remote_scripts_dir}/*.sh",
      "tar -C ${var.remote_stage_dir} -xzf ${local.remote_tarball_path}",
    ]
  }
}

# ------------------------------------------------------------
# Phase 3 -- prep
#
# RHEL prep -> offline RPM install -> preload images, on every node.
# One phase per the build spec, modelled as one null_resource running
# all three scripts in sequence (each script is independently
# idempotent, per requirement #11).
# ------------------------------------------------------------
resource "null_resource" "node_prep" {
  for_each = local.all_nodes

  depends_on = [null_resource.upload]

  triggers = {
    bundle_trigger      = local.bundle_trigger
    kubernetes_version   = var.kubernetes_version
    containerd_version   = var.containerd_version
    pause_image_version  = var.pause_image_version
    http_proxy_url       = var.http_proxy_url
    https_proxy_url      = var.https_proxy_url
    no_proxy_csv         = local.no_proxy_csv
    node_ip              = each.value.ip
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.hosts_file_body
    destination = "${var.remote_stage_dir}/hosts.snippet"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash ${local.remote_scripts_dir}/00-node-prep.sh --node-name ${each.value.name} --hosts-file ${var.remote_stage_dir}/hosts.snippet --http-proxy '${var.http_proxy_url}' --https-proxy '${var.https_proxy_url}' --no-proxy '${local.no_proxy_csv}'",
      "sudo bash ${local.remote_scripts_dir}/10-install-packages.sh --stage-dir ${var.remote_stage_dir} --kube-version ${var.kubernetes_version} --containerd-version ${var.containerd_version} --pause-version ${var.pause_image_version}",
      "sudo bash ${local.remote_scripts_dir}/20-load-images.sh --stage-dir ${var.remote_stage_dir}",
    ]
  }
}

# ------------------------------------------------------------
# Phase 4 -- vip (only when manage_vip = true)
#
# haproxy + keepalived on the VIP-fronting nodes (masters, unless
# proxy_nodes was given). A no-op phase entirely when manage_vip =
# false -- an external LB already owns the VIP in that case.
# ------------------------------------------------------------
resource "null_resource" "vip" {
  for_each = var.manage_vip ? local.vip_nodes_indexed : {}

  depends_on = [null_resource.node_prep]

  triggers = {
    config_hash = sha1("${local.rendered_haproxy_cfg[each.key]}${local.rendered_keepalived_conf[each.key]}")
    node_ip     = each.value.ip
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.rendered_haproxy_cfg[each.key]
    destination = "${var.remote_stage_dir}/haproxy.cfg"
  }

  provisioner "file" {
    content     = local.rendered_keepalived_conf[each.key]
    destination = "${var.remote_stage_dir}/keepalived.conf"
  }

  provisioner "file" {
    content     = local.rendered_check_apiserver_sh
    destination = "${var.remote_stage_dir}/check_apiserver.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash ${local.remote_scripts_dir}/30-proxy-setup.sh --stage-dir ${var.remote_stage_dir} --node-ip ${each.value.ip}",
    ]
  }
}

# ------------------------------------------------------------
# Phase 5 -- init (first master only)
# ------------------------------------------------------------
resource "null_resource" "init_first_master" {
  # Depends on phase 4 only when it actually ran (manage_vip=true);
  # otherwise falls straight back to phase 3. `null_resource.vip` has
  # 0 instances when manage_vip=false, so this depends_on is always
  # valid -- it just resolves to "wait for nothing" in that case.
  depends_on = [null_resource.vip, null_resource.node_prep]

  triggers = {
    node_ip = local.first_master.ip
    token   = local.kubeadm_token
  }

  connection {
    type        = "ssh"
    host        = local.first_master.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.rendered_kubeadm_init_yaml
    destination = "${var.remote_stage_dir}/kubeadm-init.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash ${local.remote_scripts_dir}/40-init-first-master.sh --stage-dir ${var.remote_stage_dir} --certificate-key ${random_id.certificate_key.hex}",
    ]
  }
}

# ------------------------------------------------------------
# Phase 5b -- cni (Calico, BEFORE any other node joins)
#
# Requirement #3: a node with no CNI never leaves NotReady, and the
# join gate (wait-cp-ready.sh) and 99-verify.sh both key off `Ready`.
# ------------------------------------------------------------
resource "null_resource" "cni" {
  depends_on = [null_resource.init_first_master]

  triggers = {
    calico_version        = var.calico_version
    calico_encapsulation  = var.calico_encapsulation
    pod_subnet             = var.pod_subnet
  }

  connection {
    type        = "ssh"
    host        = local.first_master.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash ${local.remote_scripts_dir}/55-cni.sh --stage-dir ${var.remote_stage_dir} --pod-subnet ${var.pod_subnet} --encapsulation ${var.calico_encapsulation} --block-size 26",
    ]
  }
}

# ------------------------------------------------------------
# Read back the CA public-key hash (requirement #10) -- the one
# thing that cannot exist before kubeadm init has run. Runs over SSH
# from the TERRAFORM HOST; no cluster credential leaves the first
# master (see scripts/fetch-join-info.sh).
# ------------------------------------------------------------
data "external" "join_info" {
  depends_on = [null_resource.cni]

  program = ["bash", "${path.module}/scripts/fetch-join-info.sh"]
  query = {
    host     = local.first_master.ip
    user     = var.ssh_user
    ssh_key  = var.ssh_private_key_path
    ssh_port = tostring(var.ssh_port)
  }
}

# ------------------------------------------------------------
# Phase 6a -- join, additional control-plane nodes, SERIALLY
#
# Requirement #2: for_each is inherently parallel, so each additional
# master's own local-exec (wait-cp-ready.sh, run on the TERRAFORM
# HOST) blocks until join_index+1 control-plane nodes are already
# Ready, before its remote-exec (50-join.sh) is allowed to run. That
# turns Terraform's parallel graph execution into an effectively
# serial join sequence without needing `-parallelism=1` for the whole
# apply.
# ------------------------------------------------------------
resource "null_resource" "join_masters" {
  for_each = local.other_masters_indexed

  depends_on = [data.external.join_info]

  triggers = {
    token       = local.kubeadm_token
    join_index  = each.value.join_index
    node_ip     = each.value.ip
  }

  provisioner "local-exec" {
    command = "bash '${path.module}/scripts/wait-cp-ready.sh' --host '${local.first_master.ip}' --user '${var.ssh_user}' --ssh-key '${var.ssh_private_key_path}' --ssh-port '${var.ssh_port}' --expect '${each.value.expect_ready}' --timeout 900"
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.rendered_kubeadm_join_yaml_masters[each.key]
    destination = "${var.remote_stage_dir}/kubeadm-join.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash ${local.remote_scripts_dir}/50-join.sh --stage-dir ${var.remote_stage_dir}",
    ]
  }
}

# ------------------------------------------------------------
# Phase 6b -- join, workers, in parallel
#
# Waits for ALL control-plane nodes to have joined first (safe
# default: workers scheduling before the control plane is fully HA
# just means more disruption if a master join fails partway through).
# Workers themselves join in parallel -- no serialisation hazard,
# they never touch etcd membership.
# ------------------------------------------------------------
resource "null_resource" "join_workers" {
  for_each = local.worker_nodes

  depends_on = [null_resource.join_masters]

  triggers = {
    token   = local.kubeadm_token
    node_ip = each.value.ip
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.rendered_kubeadm_join_yaml_workers[each.key]
    destination = "${var.remote_stage_dir}/kubeadm-join.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash ${local.remote_scripts_dir}/50-join.sh --stage-dir ${var.remote_stage_dir}",
    ]
  }
}

# ------------------------------------------------------------
# Phase 7 -- addons
# ------------------------------------------------------------
resource "null_resource" "addons" {
  depends_on = [null_resource.join_masters, null_resource.join_workers]

  triggers = {
    enable_ingress_nginx  = var.enable_ingress_nginx
    enable_local_storage  = var.enable_local_storage
    ingress_nginx_version = var.ingress_nginx_version
  }

  connection {
    type        = "ssh"
    host        = local.first_master.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "file" {
    content     = local.rendered_ingress_nginx_manifest
    destination = "${var.remote_stage_dir}/ingress-nginx-daemonset.yaml"
  }

  provisioner "file" {
    source      = "${path.module}/manifests/local-storage-sc.yaml"
    destination = "${var.remote_stage_dir}/local-storage-sc.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash ${local.remote_scripts_dir}/60-addons.sh --stage-dir ${var.remote_stage_dir} --enable-ingress ${var.enable_ingress_nginx} --enable-storage ${var.enable_local_storage}",
    ]
  }
}

# ------------------------------------------------------------
# Phase 8 -- verify
#
# Health report; a non-zero exit here fails `terraform apply` itself
# (a remote-exec provisioner failure propagates as a resource error).
# triggers = timestamp() deliberately, so verify re-runs on every
# apply as a genuine health gate, not just on the first bootstrap.
# ------------------------------------------------------------
resource "null_resource" "verify" {
  depends_on = [null_resource.addons]

  triggers = {
    run_id = timestamp()
  }

  connection {
    type        = "ssh"
    host        = local.first_master.ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = local.ssh_private_key_content
    agent       = var.ssh_agent
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo bash ${local.remote_scripts_dir}/99-verify.sh --expect-nodes ${length(local.all_nodes) - length(var.proxy_nodes)} --api-vip '${var.api_vip}' --api-vip-port '${var.api_vip_port}' --manage-vip '${var.manage_vip}'",
    ]
  }
}

############################################################
# outputs.tf
############################################################

output "api_endpoint" {
  description = "Cluster API endpoint clients should point kubeconfigs at."
  value       = "https://${var.api_vip}:${var.api_vip_port}"
}

output "first_master" {
  description = "The master kubeadm init ran on -- has /root/.kube/config and the source of truth admin.conf."
  value       = local.first_master
}

output "masters" {
  description = "All control-plane nodes."
  value       = var.masters
}

output "workers" {
  description = "All worker nodes."
  value       = var.workers
}

output "vip_nodes" {
  description = "Nodes running haproxy + keepalived (empty list if manage_vip = false)."
  value       = var.manage_vip ? local.vip_nodes_list : []
}

output "kubeadm_join_command_hint" {
  description = <<-EOT
    Not a literal command to run -- Terraform already joined every
    node listed in tfvars via scripts/50-join.sh. This is here purely
    as a reference for manually diagnosing a join, using the same
    token/hash this apply generated.
  EOT
  value = "kubeadm join ${var.api_vip}:${var.api_vip_port} --token ${local.kubeadm_token} --discovery-token-ca-cert-hash sha256:${try(data.external.join_info.result.ca_cert_hash, "<run apply first>")}"
  sensitive = false # the token/hash are only useful from inside the air-gapped network and the hash is public (requirement #10); still, see the README's note on treating a working bootstrap token as sensitive-ish operationally.
}

output "next_steps" {
  description = "Runbook: what to do right after a successful apply."
  value       = <<-EOT
    Cluster bootstrap complete.

    1. Fetch the admin kubeconfig (never committed -- it's cluster-admin):
         scp ${var.ssh_user}@${local.first_master.ip}:/etc/kubernetes/admin.conf ./kubeconfig-${local.first_master.name}
         export KUBECONFIG=$(pwd)/kubeconfig-${local.first_master.name}
         kubectl get nodes -o wide

    2. Confirm the VIP answers from OUTSIDE the cluster network too:
         curl -k https://${var.api_vip}:${var.api_vip_port}/healthz

    3. Re-running `terraform apply` is safe: every phase is idempotent
       (requirement #11) and re-verifies cluster health (phase 8) on
       every run.

    4. To add a node later with no internet available, see the
       README's "Adding a node later" section -- the bundle already
       staged at ${var.remote_stage_dir} on existing nodes is reused,
       and only the NEW node needs the upload phase to run again.
  EOT
}

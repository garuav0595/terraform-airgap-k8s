############################################################
# versions.tf
#
# No cloud provider on purpose: the nodes already exist (bare
# metal / vSphere VMs handed to us by the platform team). This
# project only *configures* them over SSH, so the provider set
# is deliberately small:
#   - null      : the workhorse, one null_resource per apply phase
#   - random    : bootstrap token + certificate-key generated
#                 locally so kubeadm never has to be re-parsed
#                 for secrets (see locals.tf and requirement #10
#                 in the README)
#   - local     : render/write files to the Terraform host
#                 (rendered kubeadm/haproxy/keepalived configs,
#                 the packed bundle tarball)
#   - external  : the ONE piece of cluster state we cannot know
#                 until kubeadm init has actually run — the CA
#                 public-key hash — is read back via a script,
#                 not parsed out of provisioner stdout.
############################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
  }
}

resource "kubectl_manifest" "cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  yaml_body = templatefile("${path.module}/argocd-applications/cert-manager.yaml", {})

  depends_on = [
    helm_release.argocd,
  ]
}

# Resources became optional (count); keep existing state addresses
moved {
  from = kubectl_manifest.cert_manager
  to   = kubectl_manifest.cert_manager[0]
}

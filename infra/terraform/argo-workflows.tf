locals {
  argo_workflows_values = yamldecode(templatefile("${path.module}/helm-values/argo-workflows.yaml", {
  }))
}

resource "kubectl_manifest" "argo_workflows" {
  count = var.enable_argo_workflows ? 1 : 0

  yaml_body = templatefile("${path.module}/argocd-applications/argo-workflows.yaml", {
    user_values_yaml = indent(10, yamlencode(local.argo_workflows_values))
  })

  depends_on = [
    helm_release.argocd,
  ]
}

# Resources became optional (count); keep existing state addresses
moved {
  from = kubectl_manifest.argo_workflows
  to   = kubectl_manifest.argo_workflows[0]
}

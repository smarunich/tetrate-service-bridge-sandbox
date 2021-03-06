provider "helm" {
  kubernetes {
    host                   = var.k8s_host
    cluster_ca_certificate = base64decode(var.k8s_cluster_ca_certificate)
    token                  = var.k8s_client_token
  }
}

provider "kubectl" {
  host                   = var.k8s_host
  cluster_ca_certificate = base64decode(var.k8s_cluster_ca_certificate)
  token                  = var.k8s_client_token
  load_config_file       = false
}

provider "kubernetes" {
  host                   = var.k8s_host
  cluster_ca_certificate = base64decode(var.k8s_cluster_ca_certificate)
  token                  = var.k8s_client_token
}

resource "time_sleep" "warmup_90_seconds" {
  create_duration = "90s"
}

data "kubectl_path_documents" "manifests_certs" {
  pattern = "${path.module}/manifests/cert-manager/certs.yaml.tmpl"
  vars = {
    tsb_fqdn = var.tsb_fqdn
  }
}

resource "kubectl_manifest" "manifests_certs" {
  count     = length(data.kubectl_path_documents.manifests_certs.documents)
  yaml_body = element(data.kubectl_path_documents.manifests_certs.documents, count.index)
}

resource "kubernetes_namespace" "tsb" {
  metadata {
    name = "tsb"
  }
  lifecycle {
    ignore_changes = [metadata]
  }
}
data "kubernetes_secret" "selfsigned_ca" {
  metadata {
    name      = "selfsigned-ca"
    namespace = "cert-manager"
  }
  depends_on = [time_sleep.warmup_90_seconds]
}

data "kubernetes_secret" "tsb_server_cert" {
  metadata {
    name      = "tsb-server-cert"
    namespace = "cert-manager"
  }
  depends_on = [time_sleep.warmup_90_seconds]
}

data "kubernetes_secret" "istiod_cacerts" {
  metadata {
    name      = "istiod-cacerts"
    namespace = "cert-manager"
  }
  depends_on = [time_sleep.warmup_90_seconds]
}
data "kubernetes_secret" "es_password" {
  metadata {
    name      = "tsb-es-elastic-user"
    namespace = "elastic-system"
  }
}

data "kubernetes_secret" "es_cacert" {
  metadata {
    name      = "tsb-es-http-ca-internal"
    namespace = "elastic-system"
  }
}


data "kubernetes_service" "es" {
  metadata {
    name      = "tsb-es-http"
    namespace = "elastic-system"
  }
}

resource "helm_release" "managementplane" {
  name       = "managementplane"
  repository = var.tsb_helm_repository
  chart      = "managementplane"
  version    = var.tsb_helm_version
  namespace  = "tsb"
  timeout    = 900

  values = [templatefile("${path.module}/manifests/tsb/managementplane-values.yaml.tmpl", {
    #tsb
    tsb_version  = var.tsb_version
    registry     = var.registry
    tsb_password = var.tsb_password
    tsb_org      = var.tsb_org
    tsb_fqdn     = var.tsb_fqdn
    #eck
    es_host     = data.kubernetes_service.es.status[0].load_balancer[0].ingress[0].ip
    es_username = "elastic"
    es_password = data.kubernetes_secret.es_password.data["elastic"]
    # demo db profile
    db_username = "tsb"
    db_password = "tsb-postgres-password"
    # demo ldap profile
    ldap_binddn       = "cn=admin,dc=tetrate,dc=io"
    ldap_bindpassword = "admin"
  })]
  set {
    name  = "secrets.tsb.cert"
    value = data.kubernetes_secret.tsb_server_cert.data["tls.crt"]
  }
  set {
    name  = "secrets.tsb.key"
    value = data.kubernetes_secret.tsb_server_cert.data["tls.key"]
  }

  set {
    name  = "secrets.xcp.rootca"
    value = data.kubernetes_secret.selfsigned_ca.data["tls.crt"]
  }
  set {
    name  = "secrets.xcp.rootcakey"
    value = data.kubernetes_secret.selfsigned_ca.data["tls.key"]
  }

  set {
    name  = "secrets.elasticsearch.cacert"
    value = data.kubernetes_secret.es_cacert.data["tls.crt"]

  }

}

resource "time_sleep" "wait_180_seconds" {
  depends_on      = [helm_release.managementplane]
  create_duration = "180s"
}

data "kubernetes_service" "tsb" {
  metadata {
    name      = "envoy"
    namespace = "tsb"
  }
  depends_on = [time_sleep.wait_180_seconds]
}

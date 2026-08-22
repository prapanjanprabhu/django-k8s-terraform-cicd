resource "kubernetes_persistent_volume_claim" "mysql" {
  metadata {
    name      = "mysql-pvc"
    namespace = kubernetes_namespace.wrapzy.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.mysql_storage_class
    volume_mode        = "Filesystem"

    resources {
      requests = {
        storage = var.mysql_storage_size
      }
    }
  }

 
  lifecycle {
    ignore_changes = [spec[0].resources[0].limits]
  }
}

resource "kubernetes_deployment" "mysql" {
  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace.wrapzy.metadata[0].name
    labels    = { app = "mysql" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "mysql" }
    }

    template {
      metadata {
        labels = { app = "mysql" }
      }

      spec {
        container {
          name  = "mysql"
          image = var.mysql_image

          port {
            container_port = 3306
          }

          # Order matches mysql-deployment.yaml; `env` is an ordered list, so a
          # set here would sort alphabetically and churn on every plan.
          dynamic "env" {
            for_each = [
              "MYSQL_ROOT_PASSWORD",
              "MYSQL_DATABASE",
              "MYSQL_USER",
              "MYSQL_PASSWORD",
            ]

            content {
              name = env.value

              value_from {
                secret_key_ref {
                  name = kubernetes_secret.mysql.metadata[0].name
                  key  = env.value
                }
              }
            }
          }

          volume_mount {
            name       = "mysql-storage"
            mount_path = "/var/lib/mysql"
          }
        }

        volume {
          name = "mysql-storage"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mysql.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mysql" {
  metadata {
    name      = "mysql-service"
    namespace = kubernetes_namespace.wrapzy.metadata[0].name
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "mysql" }

    port {
      port        = 3306
      target_port = 3306
    }
  }
}

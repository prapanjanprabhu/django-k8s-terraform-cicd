locals {

  django_env = [
    { name = "DJANGO_SECRET_KEY", value = null, secret = "DJANGO_SECRET_KEY" },
    { name = "DB_NAME", value = var.mysql_database, secret = null },
    { name = "DB_USER", value = var.mysql_user, secret = null },
    { name = "DB_PASSWORD", value = var.mysql_password, secret = null },
    { name = "DB_HOST", value = kubernetes_service.mysql.metadata[0].name, secret = null },
    { name = "DB_PORT", value = "3306", secret = null },
    { name = "DJANGO_DEBUG", value = "False", secret = null },
    { name = "DJANGO_ALLOWED_HOSTS", value = "*", secret = null },
    { name = "ADMIN_USERNAME", value = null, secret = "ADMIN_USERNAME" },
    { name = "ADMIN_PASSWORD", value = null, secret = "ADMIN_PASSWORD" },
  ]
}

resource "kubernetes_deployment" "django" {
  metadata {
    name      = "django"
    namespace = kubernetes_namespace.wrapzy.metadata[0].name
    labels    = { app = "django" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "django" }
    }

    template {
      metadata {
        labels = { app = "django" }
      }

      spec {
        container {
          name              = "django"
          image             = var.django_image
          image_pull_policy = "Always"

          command = ["sh", "-c"]
          args    = ["python manage.py migrate && python manage.py runserver 0.0.0.0:8000"]

          port {
            container_port = 8000
          }

          dynamic "env" {
            for_each = local.django_env

            content {
              name  = env.value.name
              value = env.value.value

              dynamic "value_from" {
                for_each = env.value.secret == null ? [] : [env.value.secret]

                content {
                  secret_key_ref {
                    name = kubernetes_secret.django.metadata[0].name
                    key  = value_from.value
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_deployment.mysql]
}

resource "kubernetes_service" "django" {
  metadata {
    name      = "django-service"
    namespace = kubernetes_namespace.wrapzy.metadata[0].name
  }

  spec {
    type     = "NodePort"
    selector = { app = "django" }

    port {
      port        = 8000
      target_port = 8000
      node_port   = var.django_node_port
    }
  }
}

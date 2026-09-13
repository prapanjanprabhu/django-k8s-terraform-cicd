#!/usr/bin/env bash
set -Eeuo pipefail
: "${IMAGE:?Set IMAGE to the published image tag}"
: "${KUBE_CONTEXT:=minikube}"
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null; then
    PYTHON_BIN=python3
  elif command -v python >/dev/null; then
    PYTHON_BIN=python
  else
    echo "python3 or python is required for deployment" >&2
    exit 1
  fi
fi
k() { kubectl --context "$KUBE_CONTEXT" --request-timeout=30s "$@"; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "Checking Kubernetes cluster access"
k cluster-info >/dev/null
log "Applying namespace"
k apply -f k8s/namespace.yaml
# Real secrets are provisioned once outside the repository. Never apply examples.
for secret in django-secret mysql-secret; do
  log "Checking Kubernetes secret: $secret"
  k -n wrapzy get secret "$secret" -o json | "$PYTHON_BIN" -c '
import json, sys, base64
s = json.load(sys.stdin)
required = {
 "django-secret": ["DJANGO_SECRET_KEY", "ADMIN_USERNAME", "ADMIN_PASSWORD"],
 "mysql-secret": ["MYSQL_ROOT_PASSWORD", "MYSQL_DATABASE", "MYSQL_USER", "MYSQL_PASSWORD"],
}[s["metadata"]["name"]]
for key in required:
    value = base64.b64decode(s.get("data", {}).get(key, "")).decode()
    if not value.strip() or value.startswith("REPLACE_"):
        sys.exit("Missing or placeholder secret key: " + key)
'
done
log "Applying MySQL resources"
k apply -f k8s/mysql-pvc.yaml -f k8s/mysql-service.yaml -f k8s/mysql-deployment.yaml
log "Waiting for MySQL rollout"
k -n wrapzy rollout status deployment/mysql --timeout=120s

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Run migrations once per release, before starting the two application replicas.
sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" > "$work/migration.yaml" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  generateName: django-migrate-
  namespace: wrapzy
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 120
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: django
          image: IMAGE_PLACEHOLDER
          imagePullPolicy: Always
          command: ["python", "manage.py", "migrate", "--noinput"]
          env:
            - name: DJANGO_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: django-secret
                  key: DJANGO_SECRET_KEY
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: MYSQL_DATABASE
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: MYSQL_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-secret
                  key: MYSQL_PASSWORD
            - name: DB_HOST
              value: "mysql-service"
            - name: DB_PORT
              value: "3306"
            - name: DJANGO_DEBUG
              value: "False"
            - name: DJANGO_ALLOWED_HOSTS
              value: "*"
            - name: ADMIN_USERNAME
              valueFrom:
                secretKeyRef:
                  name: django-secret
                  key: ADMIN_USERNAME
            - name: ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: django-secret
                  key: ADMIN_PASSWORD
YAML
log "Running migration job"
job=$(k create -f "$work/migration.yaml" -o name)
if ! k -n wrapzy wait --for=condition=complete "$job" --timeout=150s; then
  echo "Migration failed; application deployment was not updated."
  k -n wrapzy logs "$job" --tail=100 || true
  exit 1
fi

previous=$(k -n wrapzy get deployment django --ignore-not-found -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
log "Applying Django service and deployment"
k apply -f k8s/django-service.yaml
k apply -f k8s/django-deployment.yaml
log "Updating Django image to $IMAGE"
k -n wrapzy set image deployment/django "django=$IMAGE"
log "Waiting for Django rollout"
if ! k -n wrapzy rollout status deployment/django --timeout=180s; then
  k -n wrapzy get pods -l app=django -o wide || true
  if [[ -n "$previous" ]]; then
    echo "Release failed; restoring deployment revision $previous."
    k -n wrapzy rollout undo deployment/django --to-revision="$previous"
    k -n wrapzy rollout status deployment/django --timeout=120s
  else
    echo "First deployment failed; no previous revision exists to restore."
  fi
  exit 1
fi

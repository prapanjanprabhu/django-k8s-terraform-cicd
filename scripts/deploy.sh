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

k cluster-info >/dev/null
k apply -f k8s/namespace.yaml
# Real secrets are provisioned once outside the repository. Never apply examples.
for secret in django-secret mysql-secret; do
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
k apply -f k8s/mysql-pvc.yaml -f k8s/mysql-service.yaml -f k8s/mysql-deployment.yaml
k -n wrapzy rollout status deployment/mysql --timeout=300s

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
k set image -f k8s/django-deployment.yaml "django=$IMAGE" --local -o json > "$work/deployment.json"

# Run migrations once per release, before starting the two application replicas.
"$PYTHON_BIN" -c '
import json, sys
deployment = json.load(sys.stdin)
pod = deployment["spec"]["template"]["spec"]
pod["restartPolicy"] = "Never"
container = pod["containers"][0]
for key in ("startupProbe", "livenessProbe", "readinessProbe"):
    container.pop(key, None)
container["command"] = ["python", "manage.py", "migrate", "--noinput"]
container.pop("args", None)
print(json.dumps({"apiVersion": "batch/v1", "kind": "Job",
 "metadata": {"generateName": "django-migrate-", "namespace": "wrapzy"},
 "spec": {"backoffLimit": 0, "activeDeadlineSeconds": 300,
          "ttlSecondsAfterFinished": 3600, "template": {"spec": pod}}}))
' < "$work/deployment.json" > "$work/migration.json"
job=$(k create -f "$work/migration.json" -o name)
if ! k -n wrapzy wait --for=condition=complete "$job" --timeout=330s; then
  echo "Migration failed; application deployment was not updated."
  k -n wrapzy logs "$job" --tail=100 || true
  exit 1
fi

previous=$(k -n wrapzy get deployment django --ignore-not-found -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
if [[ -n "$previous" ]]; then
  # Only use a fully rolled-out deployment as the rollback target.
  k -n wrapzy rollout status deployment/django --timeout=60s
fi
k apply -f k8s/django-service.yaml
k apply -f "$work/deployment.json"
if ! k -n wrapzy rollout status deployment/django --timeout=330s; then
  k -n wrapzy get pods -l app=django -o wide || true
  if [[ -n "$previous" ]]; then
    echo "Release failed; restoring deployment revision $previous."
    k -n wrapzy rollout undo deployment/django --to-revision="$previous"
    k -n wrapzy rollout status deployment/django --timeout=330s
  else
    echo "First deployment failed; no previous revision exists to restore."
  fi
  exit 1
fi

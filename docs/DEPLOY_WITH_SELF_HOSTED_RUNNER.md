# Deploying a Customer Release with Self-Hosted Runner

This guide captures the working steps we used to:
- Create a tenant-specific `values.customer.yaml`
- Deploy the chart
- Install `actions-runner-controller` (ARC) in-cluster with webhooks disabled
- Register a runner and point the GitHub Actions workflow at it

## 1) Create customer values
1. Copy the template: `cp erpnext/values.new-tenant.example.yaml erpnext/values.<customer>.yaml`
2. Replace placeholders:
   - `TENANT_NAMESPACE` → customer namespace (e.g., `ciclo`)
   - `TENANT_DOMAIN` → external domain (e.g., `greenllama.tech`)
   - Update storageClasses if they differ from `longhorn-crypto-rwm`, `longhorn-crypto-mariadb-rwo`, `directpv-min-io`
   - Set `jobs.createSite.siteName` to `<namespace>.<domain>`
3. Ensure ClusterSecretStores/Issuers match your cluster names and Vault secrets exist (`secret/data/<namespace>/minio-creds`).

## 2) Deploy the chart (self-hosted runner not required for this step)
```bash
helm upgrade --install <release> ./erpnext \
  -n <namespace> --create-namespace \
  -f erpnext/values.<customer>.yaml \
  --set image.repository=ghcr.io/green-llama/glerp-image \
  --set image.tag=<tag>
```

## 3) Prepare GitHub auth for ARC
- Create a GitHub App for `green-llama/helm-glerp`, note:
  - App ID
  - Installation ID (from the URL `/installations/<id>`)
  - Private key (full PEM)
- Optionally disable GitHub webhooks for the App (ARC can poll).
- create under /tmp the pem file:
```
cat > /tmp/github-app.private-key.pem <<'EOF'
-----BEGIN RSA PRIVATE KEY-----
................pem content
-----END RSA PRIVATE KEY-----
EOF
```
- Create a Kubernetes secret with these fields (example):
```bash
kubectl -n actions-runner-system create secret generic controller-manager \
  --from-literal=github_app_id=<APP_ID> \
  --from-literal=github_app_installation_id=<INSTALLATION_ID> \
  --from-literal=github_config_url=https://github.com/greenllama/helm-glerp \
  --from-file=github_app_private_key=/path/to/github-app.private-key.pem
```

## 4) Install actions-runner-controller (webhooks disabled)
Use your secret, disable admission webhooks, and skip cert-manager:
```bash
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
helm repo update

cat > /tmp/arc-values.yaml <<'EOF'
admissionWebhooks:
  enabled: false
certManagerEnabled: false
authSecret:
  create: false
  name: controller-manager
githubConfigUrl: https://github.com/greenllama/helm-glerp
githubApp:
  id: <APP_ID>
  installationId: <INSTALLATION_ID>
# privateKey omitted because we use the precreated secret
EOF

helm upgrade --install actions-runner-controller actions-runner-controller/actions-runner-controller \
  -n actions-runner-system --create-namespace \
  -f /tmp/arc-values.yaml
```
If webhooks were previously enabled and you see webhook errors, delete stale webhook configurations:
```bash
kubectl delete mutatingwebhookconfiguration actions-runner-controller-mutating-webhook-configuration 2>/dev/null || true
kubectl delete validatingwebhookconfiguration actions-runner-controller-validating-webhook-configuration 2>/dev/null || true
```

## 5) Create a RunnerDeployment
Apply a runner that targets the repo and uses a label:
```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: helm-glerp-runner
  namespace: actions-runner-system
spec:
  replicas: 1
  template:
    spec:
      repository: green-llama/helm-glerp
      labels: ["self-hosted","helm-glerp"]
```
Apply: `kubectl apply -f runnerdeployment.yaml`

## 6) Point GitHub Actions to the self-hosted runner
- In `.github/workflows/deploy_image.yml`, set:
  ```yaml
  runs-on: [self-hosted, helm-glerp]
  ```
- Re-run the workflow. The runner pod should register and pick up the job from inside the cluster (no kubeconfig secret needed).

## 7) Troubleshooting
- Secret issues: `kubectl get secret controller-manager -o jsonpath="{.data.github_app_private_key}" | base64 -d` should show the full PEM.
- Webhook errors: ensure `admissionWebhooks.enabled=false` and delete existing webhook configurations.
- Runner registration: check controller logs `kubectl -n actions-runner-system logs deploy/actions-runner-controller --tail=50` for “Registered a new runner.”

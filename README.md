# Contents

### Glerp Helm Chart

Helm Chart to deploy a *frappe-bench*-like environment on Kubernetes. 


### Glerp Helm Chart 

1. This resource use the glerp-helm forked repo
2. Go inside erpnext directory and change Chart.yaml to update the version anytime you re-package the helmchart
3. Create your Helm package with: 
   helm package erpnext/ -d .helm-repo
4. Create your index with helm repo index .helm-repo   --url https://green-llama.github.io/helm-glerp
5. change from main to gh-pages branch then:
   git merge main
6. Copy the content of .helm-repo to the helm-glerp:  cp .helm-repo/* .
7. Sync changes to the gh-pages branch that is used to serve as a webpage and allows to download the helmchart

## Vault setup for GitHub Actions (AppRole)

Run these once in a Vault shell (inside the Vault pod is fine). If you only have the admin password, first log in with userpass to get a token:

```bash
export VAULT_ADDR=http://127.0.0.1:8200   # or your URL
vault login -method=userpass username=admin password='<ADMIN_PASSWORD>'
export VAULT_TOKEN=<token_from_login>
```

Then create the AppRole:

```bash
vault auth enable approle 2>/dev/null || true

ROLE=glerp-github-runner
POLICY=glerp-policy   # adjust to the policy you want attached

vault write auth/approle/role/$ROLE \
  policies=$POLICY \
  token_ttl=24h \
  token_max_ttl=72h

# Get IDs for GitHub secrets
vault read  -field=role_id  auth/approle/role/$ROLE/role-id
vault write -force -field=secret_id auth/approle/role/$ROLE/secret-id
```

Take the outputs and create GitHub Actions secrets:
- `VAULT_ROLE_ID` – value from `role_id`
- `VAULT_SECRET_ID` – value from `secret_id`
- `VAULT_ADDR` – your Vault URL (e.g., `https://vault.example.com:8200`)
- `VAULT_K8S_MOUNT` (optional) – defaults to `kubernetes`
- `VAULT_SHARED_GHCR_PATH` (optional) – defaults to `secret/data/shared/ghcr-creds`

To let the workflow pull GHCR images via Vault/External Secrets, also add:
- `DOCKERCONFIGJSON_B64` – base64 of a `config.json` containing your GHCR credentials:
  ```bash
  cat > /tmp/config.json <<'EOF'
  {
    "auths": {
      "ghcr.io": {
        "username": "YOUR_GHCR_USERNAME",
        "password": "YOUR_GHCR_PAT",
        "auth": "$(echo -n YOUR_GHCR_USERNAME:YOUR_GHCR_PAT | base64 -w0)"
      }
    }
  }
  EOF
  base64 -w0 /tmp/config.json
  ```

- `KUBECONFIG_B64` – base64 of the kubeconfig the runner should use:
  ```bash
  base64 -w0 ~/.kube/config
  ```

With these secrets set, rerun the `deploy_image` workflow; it will log into Vault via AppRole, create the per-tenant policy/role, and pull GHCR images via External Secrets.

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


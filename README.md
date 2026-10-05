# Table of Contents
1. [Secret Encryption Setup](#secret-encryption-setup)
2. [Bootstrap Flux](#bootstrap-flux)
3. [On-premises deployment](#on-premises-deployment)
	  - [Setting up Wireguard on both on the cloud virtual machine and on the on-premises machine](#wireguard-vpn).
	  - [Setting up Nginx on the cloud virtual machine](#nginx-on-the-cloud-virtual-machine).
	  - [Adding host entries on the on-premises machine](#on-premises-host-entries).
	  - [Setting up a kubernetes cluster on the on-premises machine](#kubernetes-on-premises).
4. [Docker Desktop local cluster](#docker-desktop-local-cluster)
5. [Artifactory](#artifactory)
	  - [Generating join and master keys](#generating-join-and-master-keys)
6. [Pipelines](#pipelines)
7. [Kubernetes Dashboard](#kubernetes-dashboard)
8. [FluxCD UI](#fluxcd-ui)
9. [Deleting pipeline runs](#deleting-pipeline-runs)
10. [Removing unused Docker resources](#removing-unused-docker-resources)
11. [Tekton](#tekton)
12. [Logging in to GitHub Container Registry](#logging-in-to-github-container-registry)
13. [Installing the Let's Encrypt certificate](#installing-the-lets-encrypt-certificate)
14. [Scripts](#scripts)

## Secret Encryption Setup
Before bootstrapping or running `run.sh`, you need to prepare your encryption keys and environment.

```bash
# Set the environment to avoid key collisions if multiple clusters (local, int, prod) are managed.
ENVIRONMENT=local
SOPS_AGE_DIR="${HOME}/.nguiland/${ENVIRONMENT}/sops/age"
mkdir -p "${SOPS_AGE_DIR}"
KEYS_FILE="${SOPS_AGE_DIR}/keys.txt"
age-keygen -o "$KEYS_FILE" # Generate an age key pair
chmod 600 "$KEYS_FILE"     # Restrict permissions to the current user
# Set the environment variable for the current session.
# To make this persistent, add the line below to your ~/.bashrc or ~/.zshrc
export SOPS_AGE_KEY_FILE="${KEYS_FILE}"
```

## On-premises deployment
Deploying on-premises requires setting up a Wireguard VPN, setting up a reverse proxy, adding host entries, and setting up a Kubernetes cluster as describe in each of the below subsections.
### Wireguard VPN
Set up a Wireguard VPN. There is a good procedure on https://docs.vultr.com/how-to-install-wireguard-vpn-on-debian-12.
Sample configuration files for the Wireguard client and server are given in the `on-premises/wireguard` directory.
### Nginx on the cloud virtual machine
Install nginx on the cloud virtual machine. An example configuration file is given in on-premises/nginx/nguiland.org. Note how traffic to port 80 (http) is redirected to port 443 (https) in the example file. Also note that in the example file, 10.0.0.2 is assumed to be the Wireguard client IP address.
### On-premises host entries
On the on-premises machine, the below entries should be added to the /etc/hosts file:
```
127.0.0.1 artifactory-jcr.${ENVIRONMENT}
127.0.0.1 keycloak.${ENVIRONMENT}
127.0.0.1 artifactory-oss.${ENVIRONMENT}
127.0.0.1 angular-frontend.ostock
127.0.0.1 gateway-service.ostock
```
### Kubernetes on-premises
1. Clone the git@github.com:biya-bi/nguiland-ops-deploy.git repository on the on-premises machine.
2. At the root of the directory that was just cloned, run `./scripts/run.sh int <branch_name>`, replacing `<branch_name>` with the actual branch name. Note that we have specified the **int** cluster in the later command. Deployment on-premises requires that the cluster name in the command be **int**.
3. After running `./scripts/run.sh int <branch_name>` on the server, do the following:
	1. Use kubectl to expose services. The Wireguard client IP address should be used in port forwarding. For example, `kubectl port-forward svc/artifactory-jcr 9001:8082 -n infra --address=10.0.0.2`
	2. Test artifactory-jcr and artifactory-oss port forwarding using the curl command. If the port forwarding loses connection to the pod after running the curl, restart the pods using a command similar to `kubectl rollout restart deployment <deployment_name> -n infra`, then test the curl again. If the curl now succeeds, stop kubectl port forwarding command for the given service and run step 1 again for the service in question.
## Docker Desktop local cluster

This setup was verified with Docker Desktop 4.93.0 using its kind-based Kubernetes cluster. It assumes the node is named `desktop-control-plane`, runs in a Docker container, and uses containerd with registry configuration under `/etc/containerd/certs.d`. A different Docker Desktop or Kubernetes provider version may use a different node layout or registry configuration and should be verified separately; providers other than Docker Desktop need their own setup rather than this helper.

The local cluster uses `host.docker.internal:80` for Artifactory image pulls. Docker Desktop routes containerd pulls through its internal registry mirror, so `scripts/docker-desktop.sh` installs a host-specific containerd route on the `desktop-control-plane` node. `scripts/deploy.sh local local` applies this automatically; run the helper after Docker Desktop recreates the Kubernetes node:

```bash
./scripts/docker-desktop.sh
```

The node-level setting is lost when Docker Desktop recreates the cluster.

`NGUILAND_LOCAL_CLUSTER_PROVIDER` selects the provider for the `local` environment. It defaults to `docker_desktop`, which enables the setup above. Set it to another provider name to skip the Docker Desktop-specific setup; that provider still needs its own registry configuration. This setting is only used for the `local` environment, so provider-specific setup is never run for `dev`, `int`, or `prod`. `scripts/cluster-provider.sh` centralizes provider configuration and dispatches to the selected provider's setup.

## Artifactory
### Generating join and master keys
Join and Master keys can be generated with the below command:
```
openssl rand -hex 32
```

## Pipelines
The pipeline directory contains manifests that can be used to manually launch pipelines. This can be done using commands of the form `kubectl apply -f <manifest_path>`. Note that most pipeline runs have an environment parameter which may have to be changed (or commented out) to match on the environment on which the deployment is made.
Ideally the pipelines should be run in the below order:
```
kubectl create -f kubernetes/pipelines/infra/docker/build.yaml
kubectl create -f kubernetes/pipelines/infra/maven/dependencies.yaml
kubectl create -f kubernetes/pipelines/infra/maven/ms-parent.yaml
kubectl create -f kubernetes/pipelines/infra/maven/io-utils.yaml
kubectl create -f kubernetes/pipelines/infra/maven/web-oauth2.yaml
kubectl create -f kubernetes/pipelines/infra/maven/orm.yaml
kubectl create -f kubernetes/pipelines/infra/maven/dto.yaml
kubectl create -f kubernetes/pipelines/infra/maven/rest.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/dto.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/orm.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/cross-cutting-concerns.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/ms-parent.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/config-service.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/eureka-service.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/gateway-service.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/license-service.yaml
kubectl create -f kubernetes/pipelines/ostock/maven/organization-service.yaml
kubectl create -f kubernetes/pipelines/ostock/node/angular-frontend.yaml
```
Pipelinerun logs can be viewed using the below command:
```
tkn pipelinerun logs -n infra -f
```
## Kubernetes Dashboard
If a Kubernetes Dashboard is required, the below commands may be useful: 
```
# Install the Kubernetes Dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
# Create the Kubernetes admin user
kubectl apply -f kubernetes/dashboards/kubernetes-dashboard-admin-user.yaml
# Create the Kubernetes admin user token
kubectl -n kubernetes-dashboard create token admin-user
# Expose the kubernetes-dashboard service
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443
```
## FluxCD UI
If a FluxCD UI is required, Capacitor can be considered. The below command may be useful:
```
# Install Capacitor
kubectl apply -f kubernetes/dashboards/capacitor.yaml
# Expose the capacitor service
kubectl -n flux-system port-forward svc/capacitor 9000
```
## Deleting pipeline runs
The below commands can be used in deleting pipeline runs:
```
# Delete non-running pipeline runs
tkn pipelinerun ls -n infra --no-headers=true -o json | jq -r '.items[] | select(.status.conditions[].reason!="Running") | .metadata.name' | awk '{print $1}' | xargs tkn pipelinerun -n infra delete --force
# Delete each node-helm pipeline run whose name starts with node-helm-run
tkn pipelinerun list -n infra --no-headers=true | awk '/node-helm-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force
# Delete each node-helm pipeline run whose name starts with maven-helm-run
tkn pipelinerun list -n infra --no-headers=true | awk '/maven-helm-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force
# Delete each node-helm pipeline run whose name starts with maven-lib-run
tkn pipelinerun list -n infra --no-headers=true | awk '/maven-lib-run/{print $1}' | xargs tkn pipelinerun -n infra delete --force
```
## Removing unused Docker resources
The below commands may be used to remove used Docker resources. As is the case with any clean up activities, prune should be used with extreme care. In fact, it should ideally be used on development environments. For example, prune may delete a database volume if it is not currently attached to a running container.
```
# Remove all containers
docker rm -f $(docker ps -a -q)
# Remove all images
docker rmi -f $(docker images -a -q)
# Remove all resources (unused containers, volumes, and networks in addition to images)
docker system prune -a -f
```
## Tekton
The below commands may be helpful in working with Tekton
```
# Get Tekton pipeline services
kubectl get svc -n tekton-pipelines
```
## Logging in to GitHub Container Registry
```
# This assumes a GitHub Personal Access Token with necessary rights is contained within the GITHUB_PERSONAL_ACCESS_TOKEN environment variable.
echo $GITHUB_PERSONAL_ACCESS_TOKEN | docker login ghcr.io -u <GITHUB_USERNAME> --password-stdin
```
## Installing the Let's Encrypt certificate
Be it manual or automatic, any script about certificates should be run on an instance through which applications are accessed. In our case,
this is the [Cloud virtual machine](#nginx-on-the-cloud-virtual-machine) on which Nginx is setup.
### Manual Approach
The below command can be used to install the Let's Encrypt certificate. The command will prompt deploying a DNS TXT record under the name _acme-challenge.nguiland.org with a given value.
```
sudo certbot certonly --server https://acme-v02.api.letsencrypt.org/directory --manual --preferred-challenges dns -d *.nguiland.org
```
### Automatic Approach
Since Let's Encrypt certificates expire after three months, it is better to have a way of auto-renewing them before they expire. This
will ensure that services are not interrupted due to expired certificates. The `certificates/namecheap/auto_renew.sh` script is a working
example of a script that can be ran once to enable Let's Encrypt certificates for a domain hosted by **namecheap.com**. That script assumes
a **namecheap** user account on which API access is enabled. Click [here](https://github.com/acmesh-official/acme.sh) to get more information about the script:

## Scripts
The `scripts/` directory contains utility scripts to automate deployment and maintenance tasks.

### deploy.sh
The main orchestrator for deployments. It handles Helm release suspensions, infrastructure updates, and triggers OCI pipelines.
- **Usage**: `./scripts/deploy.sh <environment> <namespace>`

### port-forward.sh
Manages background port-forwarding for core services like Keycloak and Artifactory. Includes a watchdog mechanism to ensure connectivity is maintained.
- **Key Variables**:
    - `NGUILAND_ENABLE_PORT_FORWARD`: Set to `true` or `false` to explicitly control behavior.
    - `NGUILAND_PORT_FORWARD_ADDRESS`: The bind address (defaults to `localhost`).

#### Persistence (Linux Systemd)
To ensure the port-forwarding watchdog restarts automatically after a system reboot, install the provided systemd service:

Run the installation script:
```bash
./scripts/install.sh
```

### teardown.sh
A safe, interactive script to completely remove the Flux system, associated CRDs, and namespaces from a cluster.
- **Safety**: Requires explicit `[y/N]` confirmation before proceeding.

### run.sh
The main entry point for cluster initialization and deployment. It automates SOPS secret creation, bootstraps the Flux system, and invokes `deploy.sh` to orchestrate the infrastructure.

### logger.sh
A centralized logging utility providing standardized, color-coded output (`DEBUG`, `INFO`, `WARN`, `ERROR`) for all scripts in the repository.

### Utility Scripts
- `helm.sh`: Manages HelmRelease suspension and resumption logic.
- `pipelines.sh`: Handles interactions with Tekton pipelines.
- `wait-k8s-resource.sh`: Helper functions for monitoring Kubernetes resource readiness.

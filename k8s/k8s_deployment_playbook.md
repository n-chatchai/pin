# Playbook: k3s Cluster Setup & Pin Backend Deployment (.env Workflow)

Follow this step-by-step guide to configure your VPS, install k3s, load environment variables using a `.env` file, set up persistent storage, transfer keys, and establish GitHub Actions CI/CD pipelines.

---

## Step 1: VPS Setup & k3s Installation

Log in to your VPS terminal as `root` or a user with `sudo` privileges.

### 1.1 Run the Installation Script
Execute the custom installation script included in your workspace:
```bash
sudo ./k8s/install_k3s.sh
```

### 1.2 Granting kubectl Access to Non-Root Users (การตั้งค่าสิทธิ์ให้ User ทั่วไปรัน kubectl)
The installation script automatically configures `kubectl` access for the user invoking `sudo`. 

If you want to grant `kubectl` access to **additional non-root users** (e.g., a custom CI/CD deployment user `deployer`), simply pass their usernames as arguments when running the installation script:
```bash
sudo ./k8s/install_k3s.sh deployer
```
*(You can pass multiple usernames separated by spaces, e.g., `sudo ./k8s/install_k3s.sh deployer devuser`).*

Alternatively, to configure access manually for any user in the future:
```bash
# 1. Create the .kube directory in the target user's home (replace 'target_user' with the actual username)
mkdir -p /home/target_user/.kube

# 2. Copy the k3s config file
sudo cp /etc/rancher/k3s/k3s.yaml /home/target_user/.kube/config

# 3. Change ownership of the config directory to the target user
sudo chown -R target_user:target_user /home/target_user/.kube

# 4. Set secure read/write permissions (only owner can read/write)
chmod 600 /home/target_user/.kube/config

# 5. Add KUBECONFIG environment variable to their bash profile
echo "export KUBECONFIG=\$HOME/.kube/config" >> /home/target_user/.bashrc
```

### 1.3 Verify the Cluster Status
Ensure that the node is active and in a `Ready` state:
```bash
kubectl get nodes
```
Verify that the `pin` namespace has been created successfully:
```bash
kubectl get ns
```

---

## Step 2: Configure Environment Variables using `.env`

Instead of writing individual configuration values inside Kubernetes manifests, we gather everything inside a single `.env` file and import it directly.

### 2.1 Create a `.env` file on your VPS
Create `/opt/pin/.env` (or any path you prefer) and populate it with the following keys:

```env
# Server settings
PIN_PROXY_HOST=0.0.0.0
PIN_PROXY_PORT=8088
PIN_DB=/data/pin.db
# Logging (Kubernetes will capture standard output natively)

# App Config & Integrations
PIN_HOMESERVER=http://matrix.pin.svc.cluster.local:8008
PIN_ADMIN_GOOGLE_REDIRECT_URI=https://pin-admin.tokens2.io/admin/auth/google/callback
# Used for initial DB seeding only (once seeded, manage via admin web):
PIN_ADMIN_OWNERS=chatchai@tokens2.io
PIN_FREE_MODEL=gemini-flash-lite-latest
PIN_EMBED_MODEL=gemini-embedding-001
PIN_EMBED_DIM=256

# Credentials & API Keys
GEMINI_API_KEY=YOUR_GEMINI_API_KEY
PIN_ADMIN_SECRET=YOUR_RANDOM_JWT_SIGNING_SECRET_KEY
GOOGLE_CLIENT_ID=YOUR_GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET=YOUR_GOOGLE_CLIENT_SECRET
GMAIL_USER=chatchai@tokens2.io
GMAIL_APP_PASSWORD=YOUR_GMAIL_APP_PASSWORD

# APNs / FCM Push Configuration (Optional)
APNS_KEY_ID=YOUR_APNS_KEY_ID
APNS_TEAM_ID=YOUR_APNS_TEAM_ID
APNS_TOPIC=io.tokens2.pin
APNS_KEY_PATH=/data/apns_key.p8
FCM_SA_PATH=/data/fcm_sa.json
```

### 2.2 Upload the `.env` file as a Kubernetes Secret
Run this command in the directory where your `.env` file resides on the VPS. It automatically parses the file and maps the variables into the `pin-secrets` Secret:

> [!NOTE]
> **Root/sudo is NOT required** to run `kubectl` commands. Since Step 1 configured the kubeconfig permissions, any regular user on the VPS can run this command.

```bash
kubectl create secret generic pin-secrets -n pin --from-env-file=.env
```
*(To update variables in the future, delete the secret with `kubectl delete secret pin-secrets -n pin` and re-run the creation command with your updated `.env` file).*

---

## Step 3: Initialize Kubernetes Manifests

Apply the persistent storage volume, cluster service, Traefik ingress routing, and daily backup CronJob.

### 3.1 Apply Manifests
From your VPS directory containing the `k8s/` folder:
```bash
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/backup-cronjob.yaml
```

### 3.2 Verify Resource Status
Confirm that all resources are active:
```bash
kubectl get pvc,svc,ingress,cronjob -n pin
```

---

## Step 4: Transfer APNs Key & FCM Credentials

To support background push notifications, transfer your Apple Push (`.p8`) and Firebase service account (`.json`) keys to the persistent storage directory `/data`.

### 4.1 Copy files from your local machine to the VPS
```bash
scp apns_key.p8 user@vps_ip:/tmp/
scp fcm_sa.json user@vps_ip:/tmp/
```

### 4.2 Move files into the Persistent Volume folder
On k3s, local storage volumes are located under `/var/lib/rancher/k3s/storage/` on the VPS host:
```bash
# Locate the actual host volume directory
VOLUME_PATH=$(sudo find /var/lib/rancher/k3s/storage/ -name "*pin-backend-pvc*")

# Move the keys to the volume root
sudo mv /tmp/apns_key.p8 "$VOLUME_PATH/apns_key.p8"
sudo mv /tmp/fcm_sa.json "$VOLUME_PATH/fcm_sa.json"

# Adjust file ownership (ensure the container user has access)
sudo chmod 600 "$VOLUME_PATH/apns_key.p8" "$VOLUME_PATH/fcm_sa.json"
```

---

## Step 5: Configure GitHub Actions CI/CD Secrets

To enable automated pipelines when you push commits to GitHub, you need to store SSH auth credentials on your repository.

1. Go to your repository on GitHub.
2. Select **Settings > Secrets and variables > Actions > New repository secret**.
3. Add the following secrets:

| Secret Name | Value |
| :--- | :--- |
| `VPS_SSH_HOST` | The IP Address or Domain of your VPS |
| `VPS_SSH_USER` | The user name to connect (e.g. `root` or your SSH username) |
| `VPS_SSH_KEY` | The SSH Private Key (typically `id_rsa`) matching the VPS authorized keys |
| `VPS_SSH_PORT` | (Optional) Your SSH port if not `22` |

---

## Step 6: Deploy the Backend

Push the code to your repository:
```bash
git add .
git commit -m "feat: Rust backend migration, k3s setup, and CI/CD pipelines"
git push origin main
```
This triggers the CI pipeline (`ci.yml`) to compile and lint, followed by the CD pipeline (`deploy.yml`) to build the container, push it to GitHub Container Registry, SSH into your VPS, pull the image, and trigger a rollout restart on k3s.

---

## Step 7: Operation & Backups

### 7.1 Verify Deployment
Ensure the pods are running successfully:
```bash
kubectl get pods -n pin
```
View the logs of your backend server:
```bash
kubectl logs -f deployment/pin-backend -n pin
```

### 7.2 Manual Backup
Execute a manual online backup anytime:
```bash
kubectl exec -it deployment/pin-backend -n pin -- sqlite3 /data/pin-admin.db ".backup '/data/pin-admin-manual.db'"
```

### 7.3 Restore Database
Restore from a previous backup:
```bash
# Copy the backup file to the container
kubectl cp ./pin-admin-manual.db pin/<pod-name>:/data/pin-admin.db -n pin

# Restart deployment to reload
kubectl rollout restart deployment/pin-backend -n pin
```

---

## Step 8: VPS Migration Guide (การย้าย VPS)

If you need to migrate the system to a new VPS in the future, follow this process:

### 8.1 Initialize New VPS
Connect to the new VPS and run the installation script:
```bash
sudo ./k8s/install_k3s.sh
```
Create the namespace and PVC to initialize storage:
```bash
kubectl apply -f k8s/pvc.yaml -n pin
```

### 8.2 Copy DB & Secrets (Host-to-Host Migration)
Find the local storage volume path on the **new VPS**:
```bash
NEW_VOLUME_PATH=$(sudo find /var/lib/rancher/k3s/storage/ -name "*pin-backend-pvc*")
```
Find the local storage volume path on the **old VPS**:
```bash
OLD_VOLUME_PATH=$(sudo find /var/lib/rancher/k3s/storage/ -name "*pin-backend-pvc*")
```
Rsync all database files, schedule configurations, and push keys from the **old VPS** volume path directly to the **new VPS** volume path:
```bash
sudo rsync -avz $OLD_VOLUME_PATH/ root@NEW_VPS_IP:$NEW_VOLUME_PATH/
```

### 8.3 Recreate Config Secret
Place your `.env` file on the new VPS and re-create the environment secret:
```bash
kubectl create secret generic pin-secrets -n pin --from-env-file=.env
```

### 8.4 Deploy Services
Apply the remaining manifests on the new VPS:
```bash
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/backup-cronjob.yaml
kubectl apply -f k8s/deployment.yaml
```

### 8.5 Update DNS and GitHub Secrets
1. Update DNS A-records of `pin.tokens2.io` and `pin-admin.tokens2.io` to point to the new VPS IP.
2. Update the `VPS_SSH_HOST` and `VPS_SSH_KEY` secrets in GitHub settings to route future CI/CD deployments to the new VPS.

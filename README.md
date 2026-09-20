# Infrastructure Service – Local Setup (Windows)

This repository contains Kubernetes and Helm configuration for the **DevOps Booking Platform**. It is intended for **local development** using **Minikube**.

---

## Prerequisites

> **Note:** All instructions below are for **Windows**

### 1. Docker Desktop

**Install Docker Desktop:**
https://www.docker.com/products/docker-desktop/

**Verify installation:**
```bash
docker --version
```

Docker Desktop must be running before starting Minikube.

### 2. kubectl

**Install kubectl:**
```bash
winget install Kubernetes.kubectl
```

**Verify:**
```bash
kubectl version --client
```

### 3. Minikube

**Install Minikube:**
```bash
winget install -e --id Kubernetes.minikube
```

**Verify in new cmd:**
```bash
minikube version
```

### 4. Helm

**Install Helm:**
```bash
winget install Helm.Helm
```

**Verify in new cmd:**
```bash
helm version
```

> If `helm` or `minikube` is not recognized, restart the terminal or the computer.

### 5. Terraform (for the planned Azure deployment)

Terraform will manage Azure infrastructure. It is not required for local Minikube setup.

**Install Terraform:**
```powershell
winget install --exact --id Hashicorp.Terraform
```

**Verify in a new terminal:**
```powershell
terraform version
```

**Initialize the Azure configuration (from `infrastructure-service`):**
```powershell
terraform -chdir=infra/azure init
```

This downloads the Azure provider; it does not create Azure resources. Keep the generated `.terraform.lock.hcl` in Git so subsequent runs use the same provider version.

---

## Start Local Kubernetes Cluster

**Start Minikube:**
```bash
minikube start
```

**Verify cluster status:**
```bash
kubectl get nodes
```

---

## Create Namespace

**Create the booking namespace:**
```bash
kubectl create namespace booking
```

**If it already exists:**
```bash
kubectl get namespaces
```

---

## Infrastructure Components

This Helm chart deploys the following components:

### Microservices
- **user-service** - User authentication and management
- **reservation-service** - Booking reservations
- **accommodation-service** - Accommodation management
- **rating-service** - Ratings and reviews
- **search-service** - Search functionality
- **notification-service** - Notifications
- **frontend** - Angular application

### Databases & Storage
- **SQL Server** - Relational database for microservices
- **MongoDB** - NoSQL database for search service
- **Redis** - In-memory cache for visitor tracking and session management

### Infrastructure Services
- **RabbitMQ** - Message broker for event-driven communication
- **Seq** - Centralized logging
- **Jaeger** - Distributed tracing
- **Prometheus** - Metrics collection and monitoring
- **Grafana** - Metrics visualization and dashboards

---

## Secrets Configuration (Required)

A secrets file is required to run the system locally.

### 1. Create `values.secrets.yaml` in infrastructure-service\booking-platform

> This file must **not** be committed to Git. Add it to `.gitignore`.

**Example `values.secrets.yaml`:**
```yaml
secrets:
  sqlserver:
    saPassword: "Your_Strong_Password123!"
  
  rabbitmq:
    user: "guest"
    pass: "guest"
  
  mongo:
    rootPassword: "rootpass"
  
  connStrings:
    user: "Server=devops-sql,1433;Database=UserServiceDb;User Id=sa;Password=Your_Strong_Password123!;TrustServerCertificate=True"
    reservation: "Server=devops-sql,1433;Database=ReservationServiceDb;User Id=sa;Password=Your_Strong_Password123!;TrustServerCertificate=True"
    accommodation: "Server=devops-sql,1433;Database=AccommodationServiceDb;User Id=sa;Password=Your_Strong_Password123!;TrustServerCertificate=True"
    rating: "Server=devops-sql,1433;Database=RatingServiceDb;User Id=sa;Password=Your_Strong_Password123!;TrustServerCertificate=True"
    notification: "Server=devops-sql,1433;Database=NotificationServiceDb;User Id=sa;Password=Your_Strong_Password123!;TrustServerCertificate=True"
  
  mongoConn:
    search: "mongodb://root:rootpass@mongo:27017/admin"
```

---

## Helm Deployment

### Optional: local deployment script

From `infrastructure-service`, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Deploy-Local.ps1
```

The script checks prerequisites, starts Minikube (2 CPUs, 8000 MiB), enables ingress, applies the chart, restarts the seven application deployments to pull the current `develop` images, and waits for Kubernetes rollouts. Wait for CI to finish publishing before running it. SQL/Mongo and other infrastructure are not explicitly restarted. It uses the existing `values.secrets.yaml` and saves timings, pod/image and PVC information under `Devops/_local-results`. It does not reset databases. Browser access stays as described below. Kubernetes readiness does not replace the manual business tests.

### First Time Installation

**Only for a fresh installation (removes existing local database PVCs):**
```bash
helm uninstall booking -n booking
```

**Install the application:**
```bash
helm install booking . -n booking -f values.yaml -f values.secrets.yaml
```

### Upgrade Existing Installation
```bash
helm upgrade booking . -n booking -f values.yaml -f values.secrets.yaml
```

**Only on the first upgrade from SQL `emptyDir` to PVC:** SQL starts empty. Once SQL is running, restart these services so their startup migrations create the databases:

```bash
kubectl rollout restart deployment user-service accommodation-service reservation-service rating-service notification-service -n booking
```

---

## Verify Deployment

**Check pod status:**
```bash
kubectl get pods -n booking
```

> All pods should be in `Running` state (or `Completed` for init jobs).

---

## Local Host Configuration

### Edit Hosts File

1. Open **Notepad as Administrator**
2. Open the file: `C:\Windows\System32\drivers\etc\hosts`
3. Add the following entries:
```
127.0.0.1 booking.local
127.0.0.1 kubernetes.docker.internal
127.0.0.1 seq.booking.local
127.0.0.1 jaeger.booking.local
127.0.0.1 prometheus.booking.local
127.0.0.1 grafana.booking.local
```

4. Save the file

---

5. Run the following command in Admin Powershell:
```
minikube tunnel
```
## Accessing the Application

### With Ingress

- **Frontend:** http://booking.local
- **Seq:** http://seq.booking.local
- **Jaeger:** http://jaeger.booking.local
- **Prometheus:** http://prometheus.booking.local
- **Grafana:** http://grafana.booking.local (login: admin/admin)

### Without Ingress

Use `kubectl port-forward` to access frontend and services individually.

---

## Troubleshooting

### `helm` or `minikube` not found

**Solution:** Restart terminal or system.

### Pod in `CrashLoopBackOff`

**Check logs:**
```bash
kubectl logs <pod-name> -n booking
```

### Minikube fails to start

**Solution:** Ensure Docker Desktop is running.

---

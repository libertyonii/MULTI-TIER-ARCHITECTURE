# Azure Multi-Tier Architecture

A 3-tier Azure deployment with NSG-enforced network segmentation.

## Architecture

```
Internet
   │  HTTP/HTTPS (80/443)
   ▼
┌─────────────────────────────────┐
│  WEBSB  10.0.1.0/24            │  ← Public-facing VM (web-vm)
│  WEBNSG: allow 80/443/22       │
│  WEBNSG: block outbound to DB  │
└───────────────┬─────────────────┘
                │ TCP 8080/443/22
                ▼
┌─────────────────────────────────┐
│  APPSB  10.0.2.0/24            │  ← Private VM (app-vm, no public IP)
│  APPNSG: allow only from Web   │
│  APPNSG: deny Internet & DB    │
└───────────────┬─────────────────┘
                │ TCP 3306/5432/1433/22
                ▼
┌─────────────────────────────────┐
│  DBSB   10.0.3.0/24            │  ← Private VM (db-vm, no public IP)
│  DBNSG: allow only from App    │
│  DBNSG: deny Web & Internet    │
└─────────────────────────────────┘
```

## Deployment details

| Setting          | Value                  |
|------------------|------------------------|
| Resource group   | Multi-tier-archi       |
| Location         | South Africa North     |
| VNet             | multivnet (10.0.0.0/16)|
| VM size          | Standard_B2s           |
| OS               | Ubuntu 22.04 LTS       |
| Admin user       | libo                   |

## Files

| File                    | Purpose                                      |
|-------------------------|----------------------------------------------|
| `deploy.sh`             | Full deployment — VNet, subnets, NSGs, VMs   |
| `nsg-config.sh`         | Re-apply NSG rules only (safe to re-run)     |
| `verify-connectivity.sh`| Ping tests to confirm NSG rules work         |
| `teardown.sh`           | Delete all resources                         |
| `deploy.yml`            | GitHub Actions CI/CD pipeline                |

## NSG rule matrix

| Source   | Destination | Ports          | Action |
|----------|-------------|----------------|--------|
| Internet | Web         | 80, 443        | ALLOW  |
| Internet | Web         | 22             | ALLOW  |
| Web      | App         | 8080, 443, 22  | ALLOW  |
| Web      | DB          | any            | DENY   |
| App      | DB          | 3306, 5432, 22 | ALLOW  |
| Internet | App         | any            | DENY   |
| Internet | DB          | any            | DENY   |
| DB       | App         | any            | DENY   |

## Quick start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_ORG/azure-multitier.git
cd azure-multitier
chmod +x *.sh
```

### 2. Deploy everything

```bash
./deploy.sh
```

This creates the resource group, VNet, subnets, NSGs, and all three VMs in sequence.

### 3. Verify NSG rules

```bash
./verify-connectivity.sh
```

Expected results:
- Web → App ping: PASS
- Web → DB ping:  FAIL (blocked)
- App → DB ping:  PASS
- DB → App ping:  FAIL (blocked)

### 4. Manual SSH access

```bash
# Into Web VM
ssh libo@<WEB_PUBLIC_IP>

# Into App VM (jump through Web)
ssh -J libo@<WEB_PUBLIC_IP> libo@<APP_PRIVATE_IP>

# Into DB VM (double jump)
ssh -J libo@<WEB_PUBLIC_IP>,libo@<APP_PRIVATE_IP> libo@<DB_PRIVATE_IP>
```

### 5. Re-apply NSG rules only

```bash
./nsg-config.sh
```

### 6. Teardown

```bash
./teardown.sh
```

## GitHub Actions setup

Add these secrets to your GitHub repository (Settings → Secrets → Actions):

| Secret               | Description                        |
|----------------------|------------------------------------|
| `AZURE_CLIENT_ID`    | Service principal client ID        |
| `AZURE_TENANT_ID`    | Azure tenant ID                    |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID           |
| `VM_SSH_PUBLIC_KEY`  | Contents of ~/.ssh/id_rsa.pub      |
| `VM_SSH_PRIVATE_KEY` | Contents of ~/.ssh/id_rsa          |

The pipeline runs automatically on every push to `main` that touches `deploy.sh`, `nsg-config.sh`, or the workflow file. You can also trigger any action manually from the Actions tab.

## Cost estimate (South Africa North)

| Resource              | Monthly cost |
|-----------------------|-------------|
| 3 × Standard_B2s VMs | ~$90        |
| 3 × Standard SSD disks| ~$5        |
| 1 × Standard public IP| ~$4        |
| VNet / NSGs           | Free        |
| **Total**             | **~$99/month** |

Deallocate VMs when not in use to stop compute charges:
```bash
az vm deallocate -g Multi-tier-archi --ids $(az vm list -g Multi-tier-archi -q)
```

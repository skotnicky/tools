# OCP-to-TCW Script

This repository contains a single Bash script, **`ott.sh`**, which automates:

1. **Sourcing OpenStack and Taikun credentials** from a **single** config file (e.g., `credentials.env`).  
2. **Creating or verifying** an OpenStack **project** and **user** (with forced password reset if the user exists).  
3. **Setting quotas** on the project (with values specified in `credentials.env`, or defaults if not set).  
4. **Creating** an **application credential** for the user by impersonating them.  
5. **Optionally creating** a **Taikun** organization if requested.
6. **Creating** a **Taikun** **cloud credential** referencing the newly generated application credential.

This approach lets you keep **all** relevant credentials (OpenStack, Taikun) and quota values in **one** environment file – no manual `source` of a keystonerc or separate configs.

---

## Prerequisites

1. **OpenStack CLI** installed and configured locally (`openstack` command).  
2. **Taikun CLI** installed and configured (`taikun` command).  
3. A single **environment file** (e.g., `ott.conf`) which exports:

   - **OpenStack** env vars (e.g. `OS_USERNAME`, `OS_PASSWORD`, `OS_PROJECT_NAME`, `OS_AUTH_URL`, etc.).  
   - **Taikun** env vars (e.g. `TAIKUN_AUTH_MODE`, `TAIKUN_ACCESS_KEY`, `TAIKUN_SECRET_KEY`, `TAIKUN_API_HOST`).  
   - **Optional** `QUOTA_*` variables for adjusting quotas (e.g. `QUOTA_CORES`, `QUOTA_RAM`, etc.). Defaults are used if omitted.

---

## Usage

1. **Create/Edit** `ott.conf` (or any file you want), for example:

   ```bash
   # Taikun credentials
   export TAIKUN_AUTH_MODE="token"
   export TAIKUN_ACCESS_KEY="my-taikun-access-key"
   export TAIKUN_SECRET_KEY="my-taikun-secret-key"
   export TAIKUN_API_HOST="api.taikun.cloud"

   # OpenStack credentials
   export OS_USERNAME="admin"
   export OS_PASSWORD="admin-secret"
   export OS_PROJECT_NAME="admin"
   export OS_USER_DOMAIN_NAME="Default"
   export OS_PROJECT_DOMAIN_NAME="Default"
   export OS_AUTH_URL="https://openstack.example.com:5000/v3"
   export OS_REGION_NAME="RegionOne"

   # Optional Quota overrides
   export QUOTA_CORES="200"
   export QUOTA_RAM="1024000"
   # etc.
   ```

## Run it

```bash
  ./ott.sh \
  --config-file credentials.env \
  -p my-project \
  -u my-user \
  -a my-app-cred \
  -n my-taikun-cred \
  --org-name myorg \
  --org-full-name "My Org FullName" \
  --org-email "myorg@example.com" \
```

- `-p <PROJECT_NAME>`: The OpenStack project to create or verify (e.g. `"my-project"`).  
   - `-u <USER_NAME>`: The OpenStack user to create or verify.  
   - `-a <APP_CRED_NAME>`: Name of the application credential for the user.  
   - `-n <TAIKUN_CRED_NAME>`: Name of the Taikun cloud credential.  
   - **Creating a new org**:  
     - Use `--org-name <SHORT_NAME>` and `--org-full-name <FULL_NAME>`.  
     - Add any optional fields like `--org-email`, `--org-address`, etc.  
   - **Using an existing org**:  
     - Pass `--org-id <ID>` if you already have an org and don’t want to create a new one.  
     - If both `--org-id` and `--org-name` are given, the newly created org will override the ID.

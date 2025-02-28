# OCP-to-TCW Script

A Bash script that automates:

1. **Creating or verifying** an OpenStack project and user (with forced password reset if the user exists).
2. **Assigning roles** (`member` and `load-balancer_member`) to the user.
3. **Setting default quotas** on the project.
4. **Creating** (or verifying) an **OpenStack application credential** by impersonating the user.
5. **Creating** a **Taikun** Cloud Credential referencing that application credential, using the `taikun` CLI.

## Why?

- Some OpenStack deployments or older CLIs do not allow creating an application credential for another user using admin commands. Instead, you must impersonate that user. This script force-resets the user’s password (if existing) so it can impersonate them and create the application credential.
- It also wraps up the Taikun `cloud-credential openstack add` command, passing the newly generated app credential ID/secret as the “username” and “password.”

## Features

- **No manual sourcing** of keystonerc needed. The script parses a keystonerc file containing admin credentials (`OS_USERNAME`, `OS_PASSWORD`, `OS_PROJECT_NAME`, etc.).
- **Creates** or **verifies**:
  - OpenStack Project
  - OpenStack User
  - Application Credential (ID + secret)
- **Assigns** roles: `member`, `load-balancer_member`
- **Sets** default quotas (customize the `quota set` commands in the script if needed).
- **Creates** a Taikun credential by calling `taikun cloud-credential openstack add`.

## Requirements

1. **OpenStack CLI** (`openstack`) installed locally with the ability to run admin commands.  
2. **`taikun` CLI** installed and configured:
   - Run `taikun config set-token <YOUR_TAIKUN_TOKEN>` or set up your config so `taikun` commands can authenticate.
3. A **keystonerc** file containing:
   - `OS_USERNAME` (admin user)
   - `OS_PASSWORD`
   - `OS_PROJECT_NAME`
   - `OS_USER_DOMAIN_NAME`
   - `OS_PROJECT_DOMAIN_NAME`
   - `OS_AUTH_URL`
   - `OS_REGION_NAME`
4. **Bash** (4.0+ recommended), **openssl** (for generating random passwords).
5. Script name: `ocp-to-tcw.sh` (or whatever you rename it to).

## Installation

1. Clone or download this repository (or place the script and README in your desired location).
2. Make the script executable:
   ```bash
   chmod +x ocp-to-tcw.sh

## Usage

./ocp-to-tcw.sh \
  -k <KEYSTONERC_FILE> \
  -p <PROJECT_NAME> \
  -u <USER_NAME> \
  -a <APP_CRED_NAME> \
  -n <TAIKUN_CRED_NAME> \
  [options]

## Example

./ocp-to-tcw.sh \
  -k /home/adam/keystonerc_admin \
  -p dev-project \
  -u dev-user \
  -a dev-app-cred \
  -n dev-taikun-cred \
  -c Europe \
  --public-network external \
  --org-id 42 \
  --skip-tls


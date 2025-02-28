#!/usr/bin/env bash
#
# ocp-to-tcw.sh - Create/verify an OpenStack project, user, roles, quotas, and application credential,
#                 then create a Taikun cloud credential using the taikun CLI. 
#
# Implements "Option 2": we parse all admin OS_* variables from a keystonerc file
# and pass them explicitly to 'openstack' commands. No manual sourcing is required.
#
# Required keystonerc variables:
#   OS_USERNAME
#   OS_PASSWORD
#   OS_PROJECT_NAME
#   OS_USER_DOMAIN_NAME
#   OS_PROJECT_DOMAIN_NAME
#   OS_AUTH_URL
#   OS_REGION_NAME
#
# The script also uses the parsed OS_AUTH_URL, OS_USER_DOMAIN_NAME, and OS_PROJECT_DOMAIN_NAME
# for impersonating the newly created user to generate an application credential.
#
# Usage:
#   ./ocp-to-tcw.sh \
#       -k <KEYSTONERC_FILE> \
#       -p <PROJECT_NAME> \
#       -u <USER_NAME> \
#       -a <APP_CRED_NAME> \
#       -n <TAIKUN_CRED_NAME> \
#       [-c <CONTINENT>] \
#       [--public-network <NET>] \
#       [--org-id <ID>] \
#       [--skip-tls] \
#       [--availability-zone <AZ>] \
#       [--volume-type <TYPE>] \
#       [--import-network]
#
# Example:
#   ./ocp-to-tcw.sh \
#       -k /home/adam/keystonerc_admin \
#       -p dev-project \
#       -u dev-user \
#       -a dev-app-cred \
#       -n dev-taikun-cred \
#       -c Europe \
#       --public-network external \
#       --org-id 42 \
#       --skip-tls
#
# Behavior:
#   1) Parse the keystonerc for admin variables (OS_USERNAME, OS_PASSWORD, etc.).
#   2) Create (or verify) the project, user (force reset if exists).
#   3) Assign roles (member, load-balancer_member), set quotas.
#   4) Impersonate the user (with known password) to create an app cred.
#   5) Use 'taikun cloud-credential openstack add' to register the new credential in Taikun
#      with applicationCredEnabled, passing the app cred ID as '--username' and secret as '--password'.
#
# SECURITY NOTE:
#   - The script prints the user password and the app cred secret to stdout if newly created.
#   - In production, handle logs carefully.
#

set -euo pipefail

###################################
# Print usage instructions
###################################
usage() {
  cat <<EOF
Usage:
  $0 -k <KEYSTONERC_FILE> -p <PROJECT_NAME> -u <USER_NAME> -a <APP_CRED_NAME> -n <TAIKUN_CRED_NAME> [options]

Required:
  -k <KEYSTONERC_FILE>   Path to an admin keystonerc file containing OS_* variables:
                         OS_USERNAME, OS_PASSWORD, OS_PROJECT_NAME,
                         OS_USER_DOMAIN_NAME, OS_PROJECT_DOMAIN_NAME,
                         OS_AUTH_URL, OS_REGION_NAME
  -p <PROJECT_NAME>      OpenStack project to create/manage
  -u <USER_NAME>         OpenStack user to create/manage
  -a <APP_CRED_NAME>     Name of the OpenStack application credential
  -n <TAIKUN_CRED_NAME>  Name of the Taikun cloud credential

Optional:
  -c <CONTINENT>         Continent for Taikun (eu, us, as...), default "Europe"
      --public-network <NET>  Public network for Taikun, default "public"
      --org-id <ID>           Taikun organization ID, default 0
      --skip-tls              If provided, pass '--skip-tls' to Taikun
      --availability-zone <AZ> Provide an AZ to Taikun
      --volume-type <TYPE>     Provide a volume type to Taikun
      --import-network         Pass '--import-network' to Taikun
  -h, --help             Show this help message
EOF
}

###################################
# Parse command-line arguments
###################################
KEYSTONERC_FILE=""
PROJECT_NAME=""
USER_NAME=""
APP_CRED_NAME=""
TAIKUN_CRED_NAME=""
CONTINENT="Europe"
PUBLIC_NETWORK="public"
ORG_ID=0
SKIP_TLS_FLAG=false
AVAILABILITY_ZONE=""
VOLUME_TYPE=""
IMPORT_NETWORK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -k)
      KEYSTONERC_FILE="$2"
      shift 2
      ;;
    -p)
      PROJECT_NAME="$2"
      shift 2
      ;;
    -u)
      USER_NAME="$2"
      shift 2
      ;;
    -a)
      APP_CRED_NAME="$2"
      shift 2
      ;;
    -n)
      TAIKUN_CRED_NAME="$2"
      shift 2
      ;;
    -c)
      CONTINENT="$2"
      shift 2
      ;;
    --public-network)
      PUBLIC_NETWORK="$2"
      shift 2
      ;;
    --org-id)
      ORG_ID="$2"
      shift 2
      ;;
    --skip-tls)
      SKIP_TLS_FLAG=true
      shift
      ;;
    --availability-zone)
      AVAILABILITY_ZONE="$2"
      shift 2
      ;;
    --volume-type)
      VOLUME_TYPE="$2"
      shift 2
      ;;
    --import-network)
      IMPORT_NETWORK=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

# Validate required
if [[ -z "$KEYSTONERC_FILE" || -z "$PROJECT_NAME" || -z "$USER_NAME" || -z "$APP_CRED_NAME" || -z "$TAIKUN_CRED_NAME" ]]; then
  echo "[ERROR] Missing required arguments."
  usage
  exit 1
fi
if [[ ! -f "$KEYSTONERC_FILE" ]]; then
  echo "[ERROR] keystonerc file '$KEYSTONERC_FILE' not found."
  exit 1
fi

###################################
# Parse the admin keystonerc for OS_* vars
###################################
declare OS_USERNAME_ADMIN=""
declare OS_PASSWORD_ADMIN=""
declare OS_PROJECT_NAME_ADMIN=""
declare OS_USER_DOMAIN_NAME_ADMIN=""
declare OS_PROJECT_DOMAIN_NAME_ADMIN=""
declare OS_AUTH_URL_ADMIN=""
declare OS_REGION_NAME_ADMIN=""

while IFS= read -r line; do
  # Lines usually look like: export OS_USERNAME=admin
  if [[ "$line" =~ ^export[[:space:]]+OS_([A-Z_]+)=(.*)$ ]]; then
    var="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    # Remove possible quotes
    val="${val#\"}"
    val="${val%\"}"
    val="${val#\'}"
    val="${val%\'}"

    case "$var" in
      USERNAME)            OS_USERNAME_ADMIN="$val" ;;
      PASSWORD)            OS_PASSWORD_ADMIN="$val" ;;
      PROJECT_NAME)        OS_PROJECT_NAME_ADMIN="$val" ;;
      USER_DOMAIN_NAME)    OS_USER_DOMAIN_NAME_ADMIN="$val" ;;
      PROJECT_DOMAIN_NAME) OS_PROJECT_DOMAIN_NAME_ADMIN="$val" ;;
      AUTH_URL)            OS_AUTH_URL_ADMIN="$val" ;;
      REGION_NAME)         OS_REGION_NAME_ADMIN="$val" ;;
      # if you need OS_CACERT or others, parse them similarly
    esac
  fi
done < "$KEYSTONERC_FILE"

# Check all are present
REQUIRED_ADMIN_VARS=(
  "OS_USERNAME_ADMIN"
  "OS_PASSWORD_ADMIN"
  "OS_PROJECT_NAME_ADMIN"
  "OS_USER_DOMAIN_NAME_ADMIN"
  "OS_PROJECT_DOMAIN_NAME_ADMIN"
  "OS_AUTH_URL_ADMIN"
  "OS_REGION_NAME_ADMIN"
)
for rv in "${REQUIRED_ADMIN_VARS[@]}"; do
  if [[ -z "${!rv}" ]]; then
    echo "[ERROR] Missing $rv in keystonerc file '$KEYSTONERC_FILE'."
    exit 1
  fi
done

echo "[INFO] Parsed admin credentials from keystonerc:"
echo "       OS_USERNAME_ADMIN=$OS_USERNAME_ADMIN"
echo "       OS_PROJECT_NAME_ADMIN=$OS_PROJECT_NAME_ADMIN"
echo "       OS_AUTH_URL_ADMIN=$OS_AUTH_URL_ADMIN"
echo "       OS_REGION_NAME_ADMIN=$OS_REGION_NAME_ADMIN"
# Do not print OS_PASSWORD_ADMIN in logs if you want to keep it hidden

###################################
# Helper: run openstack as admin
###################################
admin_os_cmd() {
  openstack \
    --os-username "$OS_USERNAME_ADMIN" \
    --os-password "$OS_PASSWORD_ADMIN" \
    --os-project-name "$OS_PROJECT_NAME_ADMIN" \
    --os-user-domain-name "$OS_USER_DOMAIN_NAME_ADMIN" \
    --os-project-domain-name "$OS_PROJECT_DOMAIN_NAME_ADMIN" \
    --os-auth-url "$OS_AUTH_URL_ADMIN" \
    --os-region-name "$OS_REGION_NAME_ADMIN" \
    "$@"
}

###################################
# Generate random password
###################################
generate_password() {
  openssl rand -base64 16 2>/dev/null || echo "ChangeMe123!"
}

###################################
# 1. Create or verify project
###################################
if admin_os_cmd project show "$PROJECT_NAME" &>/dev/null; then
  echo "[INFO] Project '$PROJECT_NAME' already exists."
else
  echo "[INFO] Creating project '$PROJECT_NAME'..."
  admin_os_cmd project create "$PROJECT_NAME"
fi

###################################
# 2. Create or verify user (force reset)
###################################
USER_PASS="$(generate_password)"

if admin_os_cmd user show "$USER_NAME" &>/dev/null; then
  echo "[INFO] User '$USER_NAME' already exists. Resetting password..."
  admin_os_cmd user set --password "$USER_PASS" "$USER_NAME"
else
  echo "[INFO] Creating user '$USER_NAME' with password: $USER_PASS"
  admin_os_cmd user create \
    --project "$PROJECT_NAME" \
    --password "$USER_PASS" \
    "$USER_NAME"
fi
echo "[INFO] Final password for user '$USER_NAME': $USER_PASS"

###################################
# 3. Assign roles (member, load-balancer_member)
###################################
REQUIRED_ROLES=("member" "load-balancer_member")
for role in "${REQUIRED_ROLES[@]}"; do
  if admin_os_cmd role assignment list --project "$PROJECT_NAME" --user "$USER_NAME" --names | grep -qw "$role"; then
    echo "[INFO] User '$USER_NAME' already has role '$role' in project '$PROJECT_NAME'."
  else
    echo "[INFO] Assigning role '$role' to user '$USER_NAME' in project '$PROJECT_NAME'..."
    admin_os_cmd role add --project "$PROJECT_NAME" --user "$USER_NAME" "$role"
  fi
done

###################################
# 4. Set default quotas
###################################
echo "[INFO] Setting compute quotas on project '$PROJECT_NAME'..."
admin_os_cmd quota set \
  --cores 100 \
  --ram 512000 \
  --instances 50 \
  --server-groups 1000 \
  --server-group-members 1000 \
  "$PROJECT_NAME"

echo "[INFO] Setting volume quotas on project '$PROJECT_NAME'..."
admin_os_cmd quota set \
  --volumes 200 \
  --snapshots 200 \
  --gigabytes 10000 \
  "$PROJECT_NAME"

echo "[INFO] Setting network quotas on project '$PROJECT_NAME'..."
admin_os_cmd quota set \
  --networks 100 \
  --subnets 100 \
  --ports 500 \
  --routers 20 \
  --floating-ips 20 \
  --secgroups 100 \
  --secgroup-rules 1000 \
  "$PROJECT_NAME"

###################################
# 5. Create application credential (impersonate)
###################################
# We must parse domain & auth URL again for impersonation. 
# We'll reuse OS_USER_DOMAIN_NAME_ADMIN, OS_PROJECT_DOMAIN_NAME_ADMIN, OS_AUTH_URL_ADMIN
# because typically the new user is in the same domain (Default).
# If your domain for the new user is different, you'd adjust below.

# Check if the app cred already exists
if openstack \
  --os-username "$USER_NAME" \
  --os-password "$USER_PASS" \
  --os-auth-url "$OS_AUTH_URL_ADMIN" \
  --os-project-name "$PROJECT_NAME" \
  --os-user-domain-name "$OS_USER_DOMAIN_NAME_ADMIN" \
  --os-project-domain-name "$OS_PROJECT_DOMAIN_NAME_ADMIN" \
  application credential list -f value -c Name \
  | grep -qw "$APP_CRED_NAME"; then
  echo "[ERROR] Application credential '$APP_CRED_NAME' already exists for user '$USER_NAME'."
  echo "        We can't retrieve the existing secret. Delete it or pick a new name."
  exit 1
fi

echo "[INFO] Creating application credential '$APP_CRED_NAME' by impersonating '$USER_NAME'..."
APP_CRED_OUTPUT=$(
  openstack \
    --os-username "$USER_NAME" \
    --os-password "$USER_PASS" \
    --os-auth-url "$OS_AUTH_URL_ADMIN" \
    --os-project-name "$PROJECT_NAME" \
    --os-user-domain-name "$OS_USER_DOMAIN_NAME_ADMIN" \
    --os-project-domain-name "$OS_PROJECT_DOMAIN_NAME_ADMIN" \
    application credential create "$APP_CRED_NAME" \
      --description "App cred for user '$USER_NAME' in project '$PROJECT_NAME'" \
      --role member \
      --role load-balancer_member \
      -f value -c id -c secret
)

APP_CRED_ID=$(echo "$APP_CRED_OUTPUT" | sed -n '1p')
APP_CRED_SECRET=$(echo "$APP_CRED_OUTPUT" | sed -n '2p')

echo "[INFO] Created app cred ID: $APP_CRED_ID"
echo "[INFO] Created app cred SECRET: $APP_CRED_SECRET"

###################################
# 6. Create the Taikun cloud credential
###################################
echo "[INFO] Creating Taikun OpenStack cloud credential: '$TAIKUN_CRED_NAME'"

TAIKUN_CMD=(
  taikun
  cloud-credential
  openstack
  add
  "$TAIKUN_CRED_NAME"
  --url "$OS_AUTH_URL_ADMIN"
  --domain "$OS_USER_DOMAIN_NAME_ADMIN"
  --region "$OS_REGION_NAME_ADMIN"
  --username "$USER_NAME"
  --password "$USER_PASS"
  --public-network "$PUBLIC_NETWORK"
  --continent "$CONTINENT"
  --project "$PROJECT_NAME"
  -o "$ORG_ID"
)

if [ "$SKIP_TLS_FLAG" = true ]; then
  TAIKUN_CMD+=( "--skip-tls" )
fi
if [ -n "$AVAILABILITY_ZONE" ]; then
  TAIKUN_CMD+=( "--availability-zone" "$AVAILABILITY_ZONE" )
fi
if [ -n "$VOLUME_TYPE" ]; then
  TAIKUN_CMD+=( "--volume-type" "$VOLUME_TYPE" )
fi
if [ "$IMPORT_NETWORK" = true ]; then
  TAIKUN_CMD+=( "--import-network" )
fi

echo "[DEBUG] Running taikun command: ${TAIKUN_CMD[*]}"
TAIKUN_CRED_ID=$("${TAIKUN_CMD[@]}" -I)

echo "[INFO] Created Taikun cloud credential with ID=$TAIKUN_CRED_ID"
echo "[INFO] Done!"

echo "----------------------------------------------------"
echo "[INFO] Summary:"
echo "  OpenStack user: $USER_NAME"
echo "    Password: $USER_PASS"
echo "  App Cred: $APP_CRED_NAME"
echo "    ID: $APP_CRED_ID"
echo "    SECRET: $APP_CRED_SECRET"
echo "  Taikun Credential: $TAIKUN_CRED_NAME (ID=$TAIKUN_CRED_ID)"
echo "----------------------------------------------------"

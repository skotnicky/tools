#!/usr/bin/env bash
#
# ocp-to-tcw.sh - A single script that:
#   1) Sources a config file (credentials.env) for OpenStack + Taikun + Quotas.
#   2) Optionally creates a Taikun organization (if --org-name is given).
#   3) Creates an OpenStack project/user (force resets user password).
#   4) Sets quotas from the config file (or defaults if not set).
#   5) Creates an application credential for that user.
#   6) Creates a Taikun cloud credential referencing that app credential.
#
# Usage:
#   ./ocp-to-tcw.sh --config-file credentials.env \
#     -p <PROJECT_NAME> -u <USER_NAME> -a <APP_CRED_NAME> -n <TAIKUN_CRED_NAME> \
#     [--org-name <ORG_NAME> --org-full-name <FULL_NAME> ...] \
#     [--continent eu] [--public-network public] [--skip-tls] ...
#
# See the usage() function for more details.

set -euo pipefail

#######################################
# Print usage
#######################################
usage() {
  cat <<EOF
Usage:
  $0 --config-file <FILE> -p <PROJECT_NAME> -u <USER_NAME> -a <APP_CRED_NAME> -n <TAIKUN_CRED_NAME> [options]

Required:
  --config-file <FILE>   Path to an env file that exports OS_* and TAIKUN_* vars, plus optional QUOTA_* vars
  -p <PROJECT_NAME>      OpenStack project to create/manage
  -u <USER_NAME>         OpenStack user to create/manage
  -a <APP_CRED_NAME>     OpenStack application credential name
  -n <TAIKUN_CRED_NAME>  Name of the Taikun cloud credential

Optional: Taikun Org creation
  --org-name <ORG_NAME>        Create an organization in Taikun with this short name
  --org-full-name <FULL_NAME>  Full name for the org (required if --org-name is set)
  --org-email <EMAIL>          Email for the org
  --org-billing-email <EMAIL>  Billing email
  --org-address <ADDR>         Address
  --org-city <CITY>            City
  --org-country <COUNTRY>      Country
  --org-phone <PHONE>          Phone
  --org-vat-number <VAT>       VAT number
  --org-discount-rate <RATE>   Discount rate (default 100)

Optional: Taikun Cloud Credential
  --org-id <ID>                If you already have an org, specify its ID for the cloud credential
  --continent <CONTINENT>      e.g. eu, us, as. Defaults to "Europe"
  --public-network <NET>       Defaults to "public"
  --skip-tls                   Pass '--skip-tls' to taikun
  --availability-zone <AZ>     Provide AZ to taikun
  --volume-type <TYPE>         Provide volume type to taikun
  --import-network             Pass '--import-network' to taikun

Other:
  -h, --help                   Show this help
EOF
}

#######################################
# Default values
#######################################
CONFIG_FILE=""
PROJECT_NAME=""
USER_NAME=""
APP_CRED_NAME=""
TAIKUN_CRED_NAME=""
CONTINENT="Europe"
PUBLIC_NETWORK="public"
SKIP_TLS_FLAG=false
AVAILABILITY_ZONE=""
VOLUME_TYPE=""
IMPORT_NETWORK=false
ORG_ID=0  # If an org is newly created, we override this. Otherwise, user can set it.

# Org creation
ORG_NAME=""
ORG_FULL_NAME=""
ORG_EMAIL=""
ORG_BILLING_EMAIL=""
ORG_ADDRESS=""
ORG_CITY=""
ORG_COUNTRY=""
ORG_PHONE=""
ORG_VAT_NUMBER=""
ORG_DISCOUNT_RATE="100"

#######################################
# Parse arguments
#######################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-file)
      CONFIG_FILE="$2"
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
    --continent)
      CONTINENT="$2"
      shift 2
      ;;
    --public-network)
      PUBLIC_NETWORK="$2"
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
    --org-id)
      ORG_ID="$2"
      shift 2
      ;;
    --org-name)
      ORG_NAME="$2"
      shift 2
      ;;
    --org-full-name)
      ORG_FULL_NAME="$2"
      shift 2
      ;;
    --org-email)
      ORG_EMAIL="$2"
      shift 2
      ;;
    --org-billing-email)
      ORG_BILLING_EMAIL="$2"
      shift 2
      ;;
    --org-address)
      ORG_ADDRESS="$2"
      shift 2
      ;;
    --org-city)
      ORG_CITY="$2"
      shift 2
      ;;
    --org-country)
      ORG_COUNTRY="$2"
      shift 2
      ;;
    --org-phone)
      ORG_PHONE="$2"
      shift 2
      ;;
    --org-vat-number)
      ORG_VAT_NUMBER="$2"
      shift 2
      ;;
    --org-discount-rate)
      ORG_DISCOUNT_RATE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

# Validate required
if [[ -z "$CONFIG_FILE" || -z "$PROJECT_NAME" || -z "$USER_NAME" || -z "$APP_CRED_NAME" || -z "$TAIKUN_CRED_NAME" ]]; then
  echo "[ERROR] Missing required arguments."
  usage
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[ERROR] config file '$CONFIG_FILE' not found."
  exit 1
fi

#######################################
# 1) Source the config file
#######################################
echo "[INFO] Sourcing config file: $CONFIG_FILE"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# We expect:
#   OS_USERNAME, OS_PASSWORD, OS_PROJECT_NAME, OS_USER_DOMAIN_NAME, OS_PROJECT_DOMAIN_NAME, OS_AUTH_URL, OS_REGION_NAME
#   TAIKUN_AUTH_MODE, TAIKUN_ACCESS_KEY, TAIKUN_SECRET_KEY, TAIKUN_API_HOST, etc.
#   QUOTA_* variables (optional).

#######################################
# 2) Quota defaults if not set
#######################################
: "${QUOTA_CORES:=100}"
: "${QUOTA_RAM:=512000}"
: "${QUOTA_INSTANCES:=50}"
: "${QUOTA_SERVER_GROUPS:=1000}"
: "${QUOTA_SERVER_GROUP_MEMBERS:=1000}"
: "${QUOTA_VOLUMES:=200}"
: "${QUOTA_SNAPSHOTS:=200}"
: "${QUOTA_GIGABYTES:=10000}"
: "${QUOTA_NETWORKS:=100}"
: "${QUOTA_SUBNETS:=100}"
: "${QUOTA_PORTS:=500}"
: "${QUOTA_ROUTERS:=20}"
: "${QUOTA_FLOATING_IPS:=20}"
: "${QUOTA_SECGROUPS:=100}"
: "${QUOTA_SECGROUP_RULES:=1000}"

#######################################
# 3) (Optional) create Taikun org
#######################################
TAIKUN_ORG_ID="$ORG_ID"

if [[ -n "$ORG_NAME" ]]; then
  if [[ -z "$ORG_FULL_NAME" ]]; then
    echo "[ERROR] --org-name requires --org-full-name"
    exit 1
  fi
  echo "[INFO] Creating Taikun org '$ORG_NAME' with full name '$ORG_FULL_NAME'..."

  ORG_CMD=( taikun organization add "$ORG_NAME" -f "$ORG_FULL_NAME" -d "$ORG_DISCOUNT_RATE" )
  [[ -n "$ORG_EMAIL" ]] && ORG_CMD+=( -e "$ORG_EMAIL" )
  [[ -n "$ORG_BILLING_EMAIL" ]] && ORG_CMD+=( --billing-email "$ORG_BILLING_EMAIL" )
  [[ -n "$ORG_ADDRESS" ]] && ORG_CMD+=( -a "$ORG_ADDRESS" )
  [[ -n "$ORG_CITY" ]] && ORG_CMD+=( --city "$ORG_CITY" )
  [[ -n "$ORG_COUNTRY" ]] && ORG_CMD+=( --country "$ORG_COUNTRY" )
  [[ -n "$ORG_PHONE" ]] && ORG_CMD+=( -p "$ORG_PHONE" )
  [[ -n "$ORG_VAT_NUMBER" ]] && ORG_CMD+=( --vat-number "$ORG_VAT_NUMBER" )

  # get newly created org ID
  TAIKUN_ORG_ID=$("${ORG_CMD[@]}" -I)
  echo "[INFO] Created org with ID=$TAIKUN_ORG_ID"
fi

#######################################
# 4) Create or verify OpenStack project/user
#######################################
# We rely on OS_* environment variables for the openstack CLI

echo "[INFO] Checking project '$PROJECT_NAME'..."
if openstack project show "$PROJECT_NAME" &>/dev/null; then
  echo "[INFO] Project '$PROJECT_NAME' exists."
else
  echo "[INFO] Creating project '$PROJECT_NAME'..."
  openstack project create "$PROJECT_NAME"
fi

# Force reset or create user
USER_PASS=$(openssl rand -base64 16 2>/dev/null || echo "ChangeMe123!")
if openstack user show "$USER_NAME" &>/dev/null; then
  echo "[INFO] User '$USER_NAME' exists. Resetting password..."
  openstack user set --password "$USER_PASS" "$USER_NAME"
else
  echo "[INFO] Creating user '$USER_NAME' with password: $USER_PASS"
  openstack user create --project "$PROJECT_NAME" --password "$USER_PASS" "$USER_NAME"
fi

echo "[INFO] User '$USER_NAME' => password=$USER_PASS"

# Roles
ROLES=( "member" "load-balancer_member" )
for r in "${ROLES[@]}"; do
  if openstack role assignment list --project "$PROJECT_NAME" --user "$USER_NAME" --names | grep -qw "$r"; then
    echo "[INFO] '$USER_NAME' already has role '$r' in '$PROJECT_NAME'."
  else
    echo "[INFO] Assigning role '$r' to '$USER_NAME' in '$PROJECT_NAME'..."
    openstack role add --project "$PROJECT_NAME" --user "$USER_NAME" "$r"
  fi
done

#######################################
# 5) Set quotas using QUOTA_* env
#######################################
echo "[INFO] Setting compute quotas on project '$PROJECT_NAME'..."
openstack quota set \
  --cores "$QUOTA_CORES" \
  --ram "$QUOTA_RAM" \
  --instances "$QUOTA_INSTANCES" \
  --server-groups "$QUOTA_SERVER_GROUPS" \
  --server-group-members "$QUOTA_SERVER_GROUP_MEMBERS" \
  "$PROJECT_NAME"

echo "[INFO] Setting volume quotas on project '$PROJECT_NAME'..."
openstack quota set \
  --volumes "$QUOTA_VOLUMES" \
  --snapshots "$QUOTA_SNAPSHOTS" \
  --gigabytes "$QUOTA_GIGABYTES" \
  "$PROJECT_NAME"

echo "[INFO] Setting network quotas on project '$PROJECT_NAME'..."
openstack quota set \
  --networks "$QUOTA_NETWORKS" \
  --subnets "$QUOTA_SUBNETS" \
  --ports "$QUOTA_PORTS" \
  --routers "$QUOTA_ROUTERS" \
  --floating-ips "$QUOTA_FLOATING_IPS" \
  --secgroups "$QUOTA_SECGROUPS" \
  --secgroup-rules "$QUOTA_SECGROUP_RULES" \
  "$PROJECT_NAME"

#######################################
# 6) Create application credential (impersonate user)
#######################################
if openstack --os-username "$USER_NAME" --os-password "$USER_PASS" \
  --os-project-name "$PROJECT_NAME" \
  application credential list -f value -c Name | grep -qw "$APP_CRED_NAME"; then
  echo "[ERROR] App cred '$APP_CRED_NAME' already exists. Can't retrieve secret!"
  exit 1
fi

echo "[INFO] Creating app cred '$APP_CRED_NAME' by impersonating user '$USER_NAME'..."
APP_CRED_OUT=$(
  openstack \
    --os-username "$USER_NAME" \
    --os-password "$USER_PASS" \
    --os-project-name "$PROJECT_NAME" \
    application credential create "$APP_CRED_NAME" \
      --role member \
      --role load-balancer_member \
      -f value -c id -c secret
)

APP_CRED_ID=$(echo "$APP_CRED_OUT" | sed -n '1p')
APP_CRED_SECRET=$(echo "$APP_CRED_OUT" | sed -n '2p')

echo "[INFO] Created app cred: ID=$APP_CRED_ID, SECRET=$APP_CRED_SECRET"

#######################################
# 7) Create Taikun cloud credential
#######################################
echo "[INFO] Creating Taikun cloud credential '$TAIKUN_CRED_NAME'..."

TAIKUN_CLOUD_CMD=(
  taikun cloud-credential openstack add
  "$TAIKUN_CRED_NAME"
  --url "$OS_AUTH_URL"
  --domain "$OS_USER_DOMAIN_NAME"
  --region "$OS_REGION_NAME"
  --username "$USER_NAME"
  --password "$USER_PASS"
  --public-network "$PUBLIC_NETWORK"
  --continent "$CONTINENT"
  --project "$PROJECT_NAME"
  -o "$TAIKUN_ORG_ID"
)
[[ "$SKIP_TLS_FLAG" == true ]] && TAIKUN_CLOUD_CMD+=( --skip-tls )
[[ -n "$AVAILABILITY_ZONE" ]] && TAIKUN_CLOUD_CMD+=( --availability-zone "$AVAILABILITY_ZONE" )
[[ -n "$VOLUME_TYPE" ]] && TAIKUN_CLOUD_CMD+=( --volume-type "$VOLUME_TYPE" )
[[ "$IMPORT_NETWORK" == true ]] && TAIKUN_CLOUD_CMD+=( --import-network )

echo "[DEBUG] Running taikun: ${TAIKUN_CLOUD_CMD[*]}"
TAIKUN_CRED_ID=$("${TAIKUN_CLOUD_CMD[@]}" -I)

echo "[INFO] Created Taikun cloud credential ID=$TAIKUN_CRED_ID"

#######################################
# Done
#######################################
echo "[INFO] Done!"
echo "========================================================"
echo "[INFO] Summary:"
if [[ -n "$ORG_NAME" ]]; then
  echo "  Created/used org with ID=$TAIKUN_ORG_ID, name=$ORG_NAME"
fi
echo "  OpenStack user='$USER_NAME' => password=$USER_PASS"
echo "  App cred '$APP_CRED_NAME' => ID=$APP_CRED_ID, SECRET=$APP_CRED_SECRET"
echo "  Taikun cred '$TAIKUN_CRED_NAME' => ID=$TAIKUN_CRED_ID"
echo "  Quotas: cores=$QUOTA_CORES ram=$QUOTA_RAM etc. (see config env for all)"
echo "========================================================"

#!/bin/bash
set -e

# --- Configuration & Validation ---
THING_NAME="$1"
AWS_REGION="$2"
ACTION="$3"

LOG_DIR="aws-resources-log"
LOG_FILE="${LOG_DIR}/$(date +%Y-%m-%d-%H-%M-%S-%3N).txt"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "--- Script started at $(date) ---"

if [ -z "$THING_NAME" ] || [ -z "$AWS_REGION" ]; then
  echo "Usage: $0 <thing-name> <aws-region> [-r | -rf | --check]"
  exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
S3_BUCKET="greengrass-certs-qts"
THING_GROUP_NAME="my-greengrass-group"
POLICY_NAME="GreengrassV2IoTThingPolicy"
ROLE_NAME="GreengrassV2TokenExchangeRole"
ROLE_ALIAS_NAME="GreengrassV2TokenExchangeRoleAlias"

# --- Helper Function to remove a single thing ---
function remove_thing() {
  local thing_name_to_remove="$1"
  echo "--- Deleting Thing and its certificates: $thing_name_to_remove ---"

  echo "Deleting Greengrass Core Device '$thing_name_to_remove'..."
  aws greengrassv2 delete-core-device --core-device-thing-name "$thing_name_to_remove" >/dev/null 2>&1 || true

  CERT_ARNS=$(aws iot list-thing-principals --thing-name "$thing_name_to_remove" --query "principals[]" --output text 2>/dev/null || true)
  if [ -n "$CERT_ARNS" ]; then
    for CERT_ARN in $CERT_ARNS; do
      echo "Detaching policy from certificate $CERT_ARN..."
      aws iot detach-policy --policy-name "$POLICY_NAME" --target "$CERT_ARN" || true
      
      echo "Detaching thing from certificate $CERT_ARN..."
      aws iot detach-thing-principal --thing-name "$thing_name_to_remove" --principal "$CERT_ARN" || true

      echo "Deleting certificate $CERT_ARN..."
      CERT_ID=$(basename "$CERT_ARN")
      aws iot update-certificate --certificate-id "$CERT_ID" --new-status INACTIVE || true
      aws iot delete-certificate --certificate-id "$CERT_ID" || true
    done
  fi

  echo "Removing thing '$thing_name_to_remove' from group '$THING_GROUP_NAME'..."
  aws iot remove-thing-from-thing-group --thing-group-name "$THING_GROUP_NAME" --thing-name "$thing_name_to_remove" || true

  echo "Deleting thing '$thing_name_to_remove'..."
  aws iot delete-thing --thing-name "$thing_name_to_remove" || true
  
  if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    echo "Removing certificates from S3 for '$thing_name_to_remove'..."
    aws s3 rm "s3://${S3_BUCKET}/${thing_name_to_remove}/" --recursive || true
  fi
}

# --- Check & Heal Function (--check) ---
function check_and_heal() {
  echo "--- Starting Health Check for Thing: $THING_NAME ---"
  local needs_recreation=false

  # 1. Check if Greengrass container is running
  echo "1. Checking Docker container status..."
  if [ ! "$(docker ps -q -f name=greengrass)" ]; then
    if [ "$(docker ps -aq -f status=exited -f name=greengrass)" ]; then
        echo "   Container exists but is stopped. Attempting to start..."
        docker start greengrass || needs_recreation=true
    else
        echo "   Container not found. A full recreation is needed."
        needs_recreation=true
    fi
  else
    echo "   ✅ Greengrass container is running."
  fi

  # 2. Check for attached certificates in AWS IoT
  echo "2. Checking for attached certificates..."
  CERT_ARNS=$(aws iot list-thing-principals --thing-name "$THING_NAME" --query "principals[]" --output text 2>/dev/null || true)
  if [ -z "$CERT_ARNS" ]; then
    echo "   No certificates attached to Thing '$THING_NAME'. A full recreation is needed."
    needs_recreation=true
  else
    echo "   ✅ Thing has certificates attached."
  fi
  
  # 3. Check for recent Greengrass logs
  echo "3. Checking for recent Greengrass logs..."
  if [ -f "logs/greengrass.log" ]; then
    # Check if log has been modified in the last 5 minutes
    if [ "$(find logs/greengrass.log -mmin -5)" ]; then
        echo "   ✅ Log file is recent and updating."
    else
        echo "   Log file exists but is not updating. Restarting container..."
        docker restart greengrass || needs_recreation=true
    fi
  else
    echo "   Log file not found. A full recreation is needed."
    needs_recreation=true
  fi

  if [ "$needs_recreation" = true ] ; then
    echo "--- 🚨 Health check failed. Recreating resources... ---"
    remove_thing "$THING_NAME"
    create_resources
  else
    echo "--- ✅ Health check passed successfully! ---"
  fi
}

# --- Force Removal (-rf) ---
if [ "$ACTION" == "-rf" ]; then
  echo "--- Starting force removal of ALL Greengrass resources ---"
  
  echo "Stopping and removing Docker containers, images, and volumes..."
  if [ -f "docker-compose.yml" ]; then
    docker-compose down --rmi all -v || true
  fi

  echo "Finding and deleting all things in group '$THING_GROUP_NAME'..."
  THINGS_IN_GROUP=$(aws iot list-things-in-thing-group --thing-group-name "$THING_GROUP_NAME" --query "things[]" --output text 2>/dev/null || true)
  if [ -n "$THINGS_IN_GROUP" ]; then
      for THING in $THINGS_IN_GROUP; do
          remove_thing "$THING"
      done
  fi
  # Also try to remove the thing passed as argument, in case it's not in the group
  echo "Attempting to remove thing specified in argument: $THING_NAME"
  remove_thing "$THING_NAME"

  echo "--- Deleting shared resources ---"

  echo "Detaching policy '$POLICY_NAME' from any remaining targets..."
  TARGETS=$(aws iot list-targets-for-policy --policy-name "$POLICY_NAME" --query targets --output text 2>/dev/null || true)
  if [ -n "$TARGETS" ]; then
    for TARGET in $TARGETS; do
      echo "Detaching policy from $TARGET"
      aws iot detach-policy --policy-name "$POLICY_NAME" --target "$TARGET" || true
    done
  fi

  echo "Deleting Thing Group '$THING_GROUP_NAME'..."
  aws iot delete-thing-group --thing-group-name "$THING_GROUP_NAME" || true

  echo "Deleting Role Alias '$ROLE_ALIAS_NAME'..."
  aws iot delete-role-alias --role-alias "$ROLE_ALIAS_NAME" || true

  # The IoT Policy must be deleted before the IAM role that might reference it via the trust policy.
  echo "Deleting IoT Policy '$POLICY_NAME'..."
  aws iot delete-policy --policy-name "$POLICY_NAME" >/dev/null 2>&1 || true

  echo "Deleting IAM Role '$ROLE_NAME'..."
  # List and detach all policies attached to the role
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null || true)
  if [ -n "$ATTACHED_POLICIES" ]; then
      echo "Detaching the following policies: $ATTACHED_POLICIES"
      for POLICY_ARN in $ATTACHED_POLICIES; do
          aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
      done
      echo "Waiting for policies to detach..."
      sleep 10
  fi

  aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true

  echo "Emptying and deleting S3 bucket '$S3_BUCKET'..."
  if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
      aws s3 rm "s3://${S3_BUCKET}/" --recursive || true
      aws s3 rb "s3://${S3_BUCKET}/" --force || true
  fi

  echo "Cleaning up local project files..."
  rm -rf certs config deployments logs .env

  echo "--- ✅ Force removal complete! ---"
  exit 0
fi

# --- Standard Removal (-r) ---
if [ "$ACTION" == "-r" ]; then
  echo "--- Starting standard removal for Thing: $THING_NAME ---"
  
  remove_thing "$THING_NAME"

  echo "Stopping and removing Docker containers, images, and volumes..."
  if [ -f "docker-compose.yml" ]; then
    docker-compose down --rmi all -v || true
  fi
  
  echo "Cleaning up local directories and files..."
  rm -rf certs config deployments logs .env

  echo "--- ✅ Standard removal complete! ---"
  echo "Note: Shared resources (IAM roles, policies, S3 bucket) were not deleted."
  exit 0
fi

# --- Resource Creation Function ---
function create_resources() {
  echo "--- Starting Greengrass Setup for Thing: $THING_NAME in region $AWS_REGION ---"

  mkdir -p certs config deployments logs

  echo "--- Checking/Creating S3 bucket: $S3_BUCKET ---"
  if ! aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    aws s3 mb "s3://${S3_BUCKET}" --region "$AWS_REGION"
  fi

  if ! aws iot get-policy --policy-name "$POLICY_NAME" >/dev/null 2>&1; then
    aws iot create-policy --policy-name "$POLICY_NAME" --policy-document file://greengrass-policy.json
  fi

  if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://greengrass-role-trust.json
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSGreengrassResourceAccessRolePolicy
  fi

  if ! aws iot describe-role-alias --role-alias "$ROLE_ALIAS_NAME" >/dev/null 2>&1; then
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    aws iot create-role-alias --role-alias "$ROLE_ALIAS_NAME" --role-arn "$ROLE_ARN"
  fi

  if ! aws iot describe-thing-group --thing-group-name "$THING_GROUP_NAME" >/dev/null 2>&1; then
    aws iot create-thing-group --thing-group-name "$THING_GROUP_NAME"
  fi

  if ! aws iot describe-thing --thing-name "$THING_NAME" >/dev/null 2>&1; then
    aws iot create-thing --thing-name "$THING_NAME"
  fi

  S3_CERT_PATH="s3://${S3_BUCKET}/${THING_NAME}/"
  if aws s3 ls "${S3_CERT_PATH}device.pem.crt" >/dev/null 2>&1; then
    aws s3 cp "${S3_CERT_PATH}" ./certs/ --recursive
  else
    CERT_OUTPUT=$(aws iot create-keys-and-certificate --set-as-active --public-key-outfile "certs/public.pem.key" --private-key-outfile "certs/private.pem.key" --certificate-pem-outfile "certs/device.pem.crt")
    CERT_ARN=$(echo "$CERT_OUTPUT" | jq -r .certificateArn)
    aws iot attach-policy --policy-name "$POLICY_NAME" --target "$CERT_ARN"
    aws iot attach-thing-principal --thing-name "$THING_NAME" --principal "$CERT_ARN"
    aws s3 cp ./certs/ "${S3_CERT_PATH}" --recursive
  fi

  aws iot add-thing-to-thing-group --thing-group-name "$THING_GROUP_NAME" --thing-name "$THING_NAME"

  S3_ROOT_CA_PATH="s3://${S3_BUCKET}/AmazonRootCA1.pem"
  if ! aws s3 ls "${S3_ROOT_CA_PATH}" >/dev/null 2>&1; then
    echo "--- Downloading Amazon Root CA and uploading to S3 ---"
    curl -o certs/AmazonRootCA1.pem https://www.amazontrust.com/repository/AmazonRootCA1.pem
    aws s3 cp certs/AmazonRootCA1.pem "${S3_ROOT_CA_PATH}"
  else
    echo "--- Amazon Root CA found in S3, downloading ---"
    aws s3 cp "${S3_ROOT_CA_PATH}" certs/AmazonRootCA1.pem
  fi

  IOT_DATA_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text)
  IOT_CRED_ENDPOINT=$(aws iot describe-endpoint --endpoint-type iot:CredentialProvider --query endpointAddress --output text)

  cat > config/config.yaml <<EOF
---
system:
  awsRegion: "${AWS_REGION}"
  certificateFilePath: "/greengrass/v2/certs/device.pem.crt"
  privateKeyPath: "/greengrass/v2/certs/private.pem.key"
  rootCaPath: "/greengrass/v2/certs/AmazonRootCA1.pem"
  thingName: "${THING_NAME}"
services:
  aws.greengrass.Nucleus:
    componentType: "NUCLEUS"
    version: "2.5.5"
    configuration:
      awsRegion: "${AWS_REGION}"
      iotDataEndpoint: "${IOT_DATA_ENDPOINT}"
      iotCredEndpoint: "${IOT_CRED_ENDPOINT}"
      iotRoleAlias: "${ROLE_ALIAS_NAME}"
EOF

  cat > .env <<EOF
AWS_REGION=${AWS_REGION}
THING_NAME=${THING_NAME}
THING_GROUP_NAME=${THING_GROUP_NAME}
EOF

  echo "--- ✅ Setup complete! Starting Greengrass container... ---"
  docker-compose up -d

  cat << EOF

--- Summary of Created/Configured Resources ---

**AWS S3**
- S3 Bucket: ${S3_BUCKET}

**AWS IoT**
- IoT Thing: ${THING_NAME}
- IoT Policy: ${POLICY_NAME}
- IoT Thing Group: ${THING_GROUP_NAME}
- IoT Role Alias: ${ROLE_ALIAS_NAME}
- Certificates Path: s3://${S3_BUCKET}/${THING_NAME}/

**AWS IAM**
- IAM Role: ${ROLE_NAME}

EOF

  echo
  check_and_heal
}

# --- Main Execution Logic ---
if [ "$ACTION" == "--check" ]; then
  check_and_heal
else
  create_resources
fi

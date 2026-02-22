# AWS Greengrass V2 Docker Environment

This project provides a fully automated solution for provisioning, configuring, and managing an AWS Greengrass V2 Core device running in a local Docker container. The primary goal is to create a consistent and repeatable development environment with a single command.

## Prerequisites

Before you begin, ensure you have the following installed and configured:

- **AWS CLI**: Authenticated with an AWS account that has sufficient permissions to create the required resources (IAM roles, IoT Things, S3 buckets, etc.).
- **Docker**: Docker Desktop or Docker Engine must be running.
- **`jq`**: A command-line JSON processor. Install it with `brew install jq` (macOS) or `sudo apt-get install jq` (Debian/Ubuntu).

## Quick Start: Create & Run Greengrass

To create a new Greengrass core device and start the container, run the main script with a unique name for your device and your desired AWS region.

```bash
./greengrass-resources.sh <thing-name> <aws-region>
```

**Example:**
```bash
./greengrass-resources.sh gg-qts-mqtt-bridge us-east-1
```

This single command will:
1.  Create an S3 bucket (`greengrass-certs-qts`) to store certificates if it doesn't already exist.
2.  Provision all required shared AWS resources (IAM Role, IoT Policy, etc.) if they don't exist.
3.  Create a new IoT Thing with the specified name.
4.  Generate a new certificate, attach it to the Thing and Policy, and store it in the S3 bucket for statefulness.
5.  Generate the necessary local configuration files (`config/config.yaml`, `.env`).
6.  Build the local Docker image using the provided `Dockerfile`.
7.  Start the Greengrass Docker container in detached mode (`docker-compose up -d`).
8.  Automatically run a health check to verify that the container is running, certificates are attached, and logs are being generated.

## Managing Resources

The script includes flags for easy cleanup and resource management.

### Health Check (`--check`)

You can manually trigger a health check at any time to validate the status of your Greengrass environment.

```bash
./greengrass-resources.sh <thing-name> <aws-region> --check
```

The check will verify:
- Docker container status.
- Certificate attachment in AWS IoT.
- Recent log activity.

If any check fails, the script will attempt to heal the environment, which may involve restarting the container or performing a full recreation of the resources.

### Standard Removal (`-r`)

This removes all resources **specific to a single Thing** without affecting shared resources.

```bash
./greengrass-resources.sh <thing-name> <aws-region> -r
```

This process will:
- Delete the Greengrass Core Device and the corresponding IoT Thing from AWS.
- Detach and delete all associated IoT certificates.
- Remove the certificates from the S3 bucket.
- Stop and remove the Docker container, image, and volumes.
- Delete local generated files and directories (`certs`, `config`, `logs`, `.env`).

### Force Removal (`-rf`)

This is a **destructive, global cleanup**. It removes **all** resources created by the script, including those shared between different Things.

```bash
./greengrass-resources.sh <thing-name> <aws-region> -rf
```

This will delete:
- All items from the standard removal.
- The shared IAM Role (`GreengrassV2TokenExchangeRole`).
- The shared IoT Policy (`GreengrassV2IoTThingPolicy`).
- The IoT Thing Group (`my-greengrass-group`).
- The shared Role Alias (`GreengrassV2TokenExchangeRoleAlias`).
- The entire S3 bucket (`greengrass-certs-qts`) and all its contents.

**Note**: This command does **not** delete the project's source files like `Dockerfile` or `greengrass-resources.sh`.

## Logging

All output from the script (both creation and deletion) is logged to a timestamped file in the `aws-resources-log` directory.

- **Log Rotation**: The script automatically manages log files, keeping only the four most recent logs and deleting older ones to save space.
- **Beautified Output**: The logs are formatted with clear section headers and spacing for improved readability.

## How It Works: State and Idempotency

- **S3 for State**: The script uses an S3 bucket as a single source of truth for device certificates. On startup, it checks S3 for existing certificates for a given Thing name. If found, it downloads them; otherwise, it creates new ones and uploads them. This makes the setup portable and stateful.
- **Idempotency**: All AWS resource creation commands are idempotent. The script checks for the existence of a resource before creating it, preventing errors on subsequent runs. Likewise, the removal commands are designed to succeed even if a resource has already been deleted.

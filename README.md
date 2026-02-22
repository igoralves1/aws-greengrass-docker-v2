# AWS Greengrass Docker Setup

This guide provides a step-by-step setup for running AWS Greengrass in a Docker container on a macOS host machine.

## Prerequisites

- Docker and Docker Compose installed on your macOS machine.
- An AWS account with access to IoT Core and Greengrass.
- AWS CLI installed and configured with your credentials.

## Setup Instructions

1. **Run the Setup Script:**

   The `greengrass-resources.sh` script automates the entire setup process. It creates the necessary AWS resources, manages certificates, and generates the required configuration files.

   To run the script, provide the desired Thing name and AWS region as arguments:

   ```bash
   chmod +x greengrass-resources.sh
   ./greengrass-resources.sh gg-qts-mqtt-bridge us-east-1
   ```

   The script will perform the following actions:
   - Create an S3 bucket to store your Greengrass certificates.
   - Create the IoT Thing, IAM roles, policies, and thing group.
   - Generate new certificates if they don't exist in the S3 bucket, or download them if they do.
   - Create the `config.yaml` file with the necessary Greengrass configuration.
   - Create a `.env` file for Docker Compose.

2. **Build and Run the Docker Container:**

   Once the setup script is complete, you can start the Greengrass container using Docker Compose:

   ```bash
   docker-compose up
   ```

   Docker Compose will use the official Greengrass image from Amazon and mount the generated configuration files and certificates into the container.

3. **Verify the Installation:**

   You can check the logs to ensure Greengrass is running correctly:

   ```bash
   docker-compose logs -f greengrass
   ```

   You should see messages indicating that Greengrass has started successfully and is connected to AWS IoT.

## Next Steps

With Greengrass running in a Docker container, you can now deploy components to your core device and start building your IoT applications. You can create and manage deployments from the AWS Greengrass console.

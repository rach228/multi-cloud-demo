#!/bin/bash

# Enable necessary Google Cloud services
gcloud services enable \
compute.googleapis.com \
cloudresourcemanager.googleapis.com \
dns.googleapis.com \
iamcredentials.googleapis.com \
iam.googleapis.com \
serviceusage.googleapis.com \
cloudapis.googleapis.com \
servicemanagement.googleapis.com \
storage.googleapis.com \
storage-component.googleapis.com

# Create a service account
export SERVICE_ACCOUNT_NAME="resiliency-demo"
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
    --description="Service account for demo" \
    --display-name="Resiliency Demo"

# Set up environment variables for project ID and service account email
export PROJECT_ID=$(gcloud config get-value project)
export SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Add roles to the service account
declare -a roles=("roles/compute.admin" "roles/iam.roleAdmin" "roles/iam.securityAdmin" "roles/iam.serviceAccountAdmin" "roles/iam.serviceAccountKeyAdmin" "roles/iam.serviceAccountUser" "roles/storage.admin" "roles/dns.admin" "roles/compute.loadBalancerAdmin")

for role in "${roles[@]}"; do
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
        --role="$role"
done

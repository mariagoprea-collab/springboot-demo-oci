# Spring Boot Demo on OCI
This repository contains a **Spring Boot demo application** showcasing a production-style deployment on **Oracle Cloud Infrastructure (OCI)** using **GitHub Actions**, **OCIR**, **OCI Container Instances**, **OCI Load Balancer**, and a **PostgreSQL database in OCI**.

The project demonstrates a real-world **CI/CD pipeline** with **zero-downtime (blue/green) deployments**.

---

## Overview

The application is packaged as a **Docker container** and deployed to **OCI Container Instances**.
Traffic is routed through an **OCI Load Balancer**, while persistent data is stored in a **PostgreSQL database** on OCI.

The entire **build and deployment process is automated** using **GitHub Actions**.

---

## High-Level Architecture

```
Client
  |
  v
OCI Load Balancer
  |
  v
OCI Container Instance (Spring Boot + Docker)
  |
  v
PostgreSQL Database (OCI)
```

---

## Components

* **Spring Boot** – REST backend
* **Docker** – Containerization
* **GitHub Actions** – CI/CD automation
* **OCI Container Registry (OCIR)** – Image storage
* **OCI Container Instances** – Runtime environment
* **OCI Load Balancer** – Traffic routing & health checks

---

## Features

* Spring Boot REST application
* Dockerized deployment
* PostgreSQL integration
* Fully automated **CI/CD with GitHub Actions**
* **Blue/green deployment strategy**
* **Zero-downtime releases**
* OCI-native services

---

## CI/CD – GitHub Actions

The CI/CD pipeline is defined in:
`.github/workflows/build-deploy-oci.yml`

### GitHub Secrets Setup

* **OCI_CLI_USER** – OCID of the user calling the API
* **OCI_CLI_TENANCY** – OCID of your tenancy
* **OCI_CLI_FINGERPRINT** – Fingerprint of the public key added to the user
* **OCI_CLI_KEY_CONTENT** – Private key content in PEM format
* **OCI_CLI_REGION** – OCI region (e.g., `us-ashburn-1`)
* **OCI_AUTH_TOKEN** – Auth token for OCIR
* **OCI_COMPARTMENT_OCID** – Compartment OCID
Database credentials are stored securely using **GitHub Secrets**.

### Workflow Triggers

* Push to **main** branch
* Manual trigger (`workflow_dispatch`)

Concurrency ensures only **one deployment per branch** runs at a time.

### Image Tagging Strategy

* **Immutable tag:** `<region>.ocir.io/<namespace>/<repo>:<GITHUB_SHA>`
* **Mutable tag:** `latest`

The immutable image reference is passed to the deploy job.

---

## Blue/Green Deployment Flow

1. Create new **Container Instance**
2. Wait for the container to be running
3. Register new backend in **OCI Load Balancer**
4. Wait for LB health checks to pass
5. (Optional) Grace period
6. Deregister old backends
7. Delete old **Container Instances**

This ensures **zero downtime** during deployments.

---

## Container Instance Configuration

Configured via **environment variables** in GitHub Actions:

* **SHAPE:** `CI.Standard.E4.Flex`
* **SHAPE_OCPUS:** 1
* **SHAPE_MEMORY_GB:** 2
* **SUBNET_ID:** `<private subnet OCID>`

Each deployment creates a new container instance using the Docker image from **OCIR**.

---

## Load Balancer Integration

When Load Balancer variables are configured, the pipeline automatically:

* Registers the new container IP as a backend
* Waits until the backend becomes **HEALTHY**
* Deregisters old backends
* Cleans up old container instances


---

## Security & Secrets Management

* **OCI credentials** – GitHub Secrets
* **Database credentials** – GitHub Secrets
* Non-sensitive configuration – GitHub Variables
* **OCI authentication** – API key-based auth
* **No secrets are committed** to the repository

---

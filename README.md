\#  Automated Deployment Bash Script — HNG DevOps Stage 1



\##  Overview

This project contains a \*\*POSIX-compliant Bash script (`deploy.sh`)\*\* that automates the setup, deployment, and configuration of a Dockerized application on a remote Linux server.



It is designed for the \*\*HNG DevOps Internship Stage 1\*\* task and simulates a real-world DevOps workflow involving automation, Docker, Nginx, and CI/CD.



---



\## Task Objective

Develop a single executable Bash script that:

\- Collects deployment parameters from user input.

\- Clones a GitHub repository using a Personal Access Token (PAT).

\- Connects to a remote Linux server via SSH.

\- Installs and configures Docker, Docker Compose, and Nginx.

\- Builds and deploys a containerized application.

\- Configures Nginx as a reverse proxy to the container.

\- Validates deployment, logs activities, and handles errors gracefully.



---



\##  Features

\- Interactive user input and validation  

\- Remote SSH connection and environment preparation  

\- Automated Docker and Nginx installation  

\- Deployment of Dockerized applications  

\- Nginx reverse proxy setup (HTTP → Container port)  

\- Comprehensive logging and error handling  

\- Idempotent (safe to rerun without breaking existing setup)



---



\##  Prerequisites

Before running the script, ensure you have:

\- A \*\*remote Linux server\*\* (e.g., Ubuntu 22.04 LTS) with SSH access  

\- \*\*Docker\*\* and \*\*Docker Compose\*\* (script installs them if missing)  

\- \*\*Git\*\* installed locally  

\- A \*\*GitHub Personal Access Token (PAT)\*\* with `repo` scope  

\- Your \*\*SSH key\*\* added to both GitHub and the remote server  



---



\## Usage



1\. \*\*Clone this repository\*\*

&nbsp;  ```bash

&nbsp;  git clone https://github.com/tobitokuye-creator/hng-stage1.git

&nbsp;  cd hng-stage1




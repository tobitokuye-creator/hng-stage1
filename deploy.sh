#!/bin/bash

################################################################################
# Production-Grade Dockerized Application Deployment Script
# Version: 1.0.0
# Description: Automates setup, deployment, and configuration of Dockerized
#              applications on remote Linux servers with Nginx reverse proxy
################################################################################

set -euo pipefail
IFS=$'\n\t'

################################################################################
# GLOBAL VARIABLES AND CONFIGURATION
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"
PROJECT_DIR=""
CLEANUP_MODE=false

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# UTILITY FUNCTIONS
################################################################################

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE}"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

# Trap handler for unexpected errors
trap_handler() {
    local exit_code=$?
    local line_number=$1
    log_error "Script failed at line ${line_number} with exit code ${exit_code}"
    exit "${exit_code}"
}

trap 'trap_handler ${LINENO}' ERR

################################################################################
# PARAMETER COLLECTION AND VALIDATION
################################################################################

collect_parameters() {
    log_info "=== Collecting Deployment Parameters Active! ==="

    # Git Repository URL
    read -p "Enter Git Repository URL: " GIT_REPO_URL
    if [[ ! "${GIT_REPO_URL}" =~ ^https?:// ]]; then
        error_exit "Invalid Git repository URL format" 10
    fi

    # Personal Access Token
    read -sp "Enter Personal Access Token (PAT): " GIT_PAT
    echo ""
    if [[ -z "${GIT_PAT}" ]]; then
        error_exit "Personal Access Token cannot be empty" 11
    fi

    # Branch name
    read -p "Enter branch name (default: main): " GIT_BRANCH
    GIT_BRANCH="${GIT_BRANCH:-main}"

    # SSH Username
    read -p "Enter remote server SSH username: " SSH_USER
    if [[ -z "${SSH_USER}" ]]; then
        error_exit "SSH username cannot be empty" 12
    fi

    # Server IP
    read -p "Enter remote server IP address: " SERVER_IP
    if ! validate_ip "${SERVER_IP}"; then
        error_exit "Invalid IP address format" 13
    fi

    # SSH Key Path
    read -p "Enter SSH private key path (default: ~/.ssh/id_rsa): " SSH_KEY_PATH
    SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"

    # Auto-generate SSH key if it doesn't exist
    if [[ ! -f "${SSH_KEY_PATH}" ]]; then
        log_warning "SSH key not found at ${SSH_KEY_PATH}"
        read -p "Would you like to generate a new SSH key pair? (y/n): " generate_key

        if [[ "${generate_key}" =~ ^[Yy]$ ]]; then
            log_info "Generating new SSH key pair..."
            ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH}" -N "" -C "deployment-key-$(date +%Y%m%d)"

            if [[ $? -eq 0 ]]; then
                log_success "SSH key pair generated successfully"
                log_info "Public key location: ${SSH_KEY_PATH}.pub"
                log_info ""
                log_warning "IMPORTANT: You need to add this public key to your server!"
                log_info "Public key content:"
                echo "----------------------------------------"
                cat "${SSH_KEY_PATH}.pub"
                echo "----------------------------------------"
                log_info ""
                read -p "Press Enter after you've added the public key to your server..."
            else
                error_exit "Failed to generate SSH key pair" 14
            fi
        else
            error_exit "SSH key file not found: ${SSH_KEY_PATH}" 14
        fi
    fi

    # Application Port
    read -p "Enter application internal port (e.g., 3000): " APP_PORT
    if ! [[ "${APP_PORT}" =~ ^[0-9]+$ ]] || [ "${APP_PORT}" -lt 1 ] || [ "${APP_PORT}" -gt 65535 ]; then
        error_exit "Invalid port number. Must be between 1 and 65535" 15
    fi

    # Application Name (derived from repo)
    APP_NAME=$(basename "${GIT_REPO_URL}" .git)

    log_success "Parameters collected successfully"
    log_info "Repository: ${GIT_REPO_URL}"
    log_info "Branch: ${GIT_BRANCH}"
    log_info "Target Server: ${SSH_USER}@${SERVER_IP}"
    log_info "Application Port: ${APP_PORT}"
    log_info "Application Name: ${APP_NAME}"
}

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

################################################################################
# REPOSITORY MANAGEMENT
################################################################################

clone_repository() {
    log_info "=== Cloning Repository ==="

    local repo_name=$(basename "${GIT_REPO_URL}" .git)
    PROJECT_DIR="${SCRIPT_DIR}/${repo_name}"

    # Create authenticated URL
    local auth_url=$(echo "${GIT_REPO_URL}" | sed "s|https://|https://${GIT_PAT}@|")

    if [[ -d "${PROJECT_DIR}" ]]; then
        log_warning "Repository directory already exists. Pulling latest changes..."
        cd "${PROJECT_DIR}" || error_exit "Failed to navigate to ${PROJECT_DIR}" 20

        git remote set-url origin "${auth_url}" || error_exit "Failed to update remote URL" 21
        git fetch origin || error_exit "Failed to fetch from origin" 22
        git checkout "${GIT_BRANCH}" || error_exit "Failed to checkout branch ${GIT_BRANCH}" 23
        git pull origin "${GIT_BRANCH}" || error_exit "Failed to pull latest changes" 24

        log_success "Repository updated successfully"
    else
        log_info "Cloning repository..."
        git clone -b "${GIT_BRANCH}" "${auth_url}" "${PROJECT_DIR}" || error_exit "Failed to clone repository" 25
        cd "${PROJECT_DIR}" || error_exit "Failed to navigate to ${PROJECT_DIR}" 26

        log_success "Repository cloned successfully"
    fi

    # Verify Docker files exist
    if [[ ! -f "Dockerfile" ]] && [[ ! -f "docker-compose.yml" ]] && [[ ! -f "docker-compose.yaml" ]]; then
        error_exit "No Dockerfile or docker-compose.yml found in repository" 27
    fi

    log_success "Docker configuration files verified"
}

################################################################################
# SSH CONNECTION AND VALIDATION
################################################################################

validate_ssh_connection() {
    log_info "=== Validating SSH Connection ==="

    # Test SSH connection
    if ssh -i "${SSH_KEY_PATH}" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" "echo 'SSH connection successful'" &>/dev/null; then
        log_success "SSH connection validated successfully"
    else
        error_exit "Failed to establish SSH connection to ${SSH_USER}@${SERVER_IP}" 30
    fi

    # Test network connectivity
    if ping -c 3 "${SERVER_IP}" &>/dev/null; then
        log_success "Server is reachable via ping"
    else
        log_warning "Server did not respond to ping (may be configured to ignore ICMP)"
    fi
}

################################################################################
# REMOTE ENVIRONMENT PREPARATION
################################################################################

prepare_remote_environment() {
    log_info "=== Preparing Remote Environment ==="

    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" bash <<'ENDSSH'
        set -euo pipefail

        echo "[REMOTE] Updating system packages..."
        sudo apt-get update -y || { echo "[REMOTE ERROR] Failed to update packages"; exit 40; }

        echo "[REMOTE] Installing prerequisites..."
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release || exit 41

        # Install Docker if not present
        if ! command -v docker &> /dev/null; then
            echo "[REMOTE] Installing Docker..."
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update -y
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io || exit 42
        else
            echo "[REMOTE] Docker already installed"
        fi

        # Install Docker Compose if not present
        if ! command -v docker-compose &> /dev/null; then
            echo "[REMOTE] Installing Docker Compose..."
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose || exit 43
        else
            echo "[REMOTE] Docker Compose already installed"
        fi

        # Install Nginx if not present
        if ! command -v nginx &> /dev/null; then
            echo "[REMOTE] Installing Nginx..."
            sudo apt-get install -y nginx || exit 44
        else
            echo "[REMOTE] Nginx already installed"
        fi

        # Add user to docker group
        if ! groups | grep -q docker; then
            echo "[REMOTE] Adding user to docker group..."
            sudo usermod -aG docker $USER || exit 45
        fi

        # Enable and start services
        echo "[REMOTE] Enabling and starting services..."
        sudo systemctl enable docker || exit 46
        sudo systemctl start docker || exit 47
        sudo systemctl enable nginx || exit 48
        sudo systemctl start nginx || exit 49

        # Verify installations
        echo "[REMOTE] Verifying installations..."
        docker --version || exit 50
        docker-compose --version || exit 51
        nginx -v || exit 52

        echo "[REMOTE] Remote environment prepared successfully"
ENDSSH

    if [[ $? -eq 0 ]]; then
        log_success "Remote environment prepared successfully"
    else
        error_exit "Failed to prepare remote environment" 53
    fi
}

################################################################################
# APPLICATION DEPLOYMENT
################################################################################

deploy_application() {
    log_info "=== Deploying Dockerized Application ==="

    # Transfer project files to remote server
    log_info "Transferring project files to remote server..."
    local remote_path="/home/${SSH_USER}/${APP_NAME}"

    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" "mkdir -p ${remote_path}" || error_exit "Failed to create remote directory" 60

    rsync -avz --delete -e "ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no" \
        "${PROJECT_DIR}/" "${SSH_USER}@${SERVER_IP}:${remote_path}/" || error_exit "Failed to transfer files" 61

    log_success "Files transferred successfully"

    # Build and run Docker containers
    log_info "Building and starting Docker containers..."

    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" bash <<ENDSSH
        set -euo pipefail
        cd ${remote_path}

        echo "[REMOTE] Stopping and removing old containers..."
        docker-compose down 2>/dev/null || docker stop ${APP_NAME} 2>/dev/null || true
        docker rm ${APP_NAME} 2>/dev/null || true

        if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
            echo "[REMOTE] Using docker-compose..."
            docker-compose up -d --build || exit 62
        elif [[ -f "Dockerfile" ]]; then
            echo "[REMOTE] Building Docker image..."
            docker build -t ${APP_NAME}:latest . || exit 63

            echo "[REMOTE] Running Docker container..."
            docker run -d --name ${APP_NAME} -p ${APP_PORT}:${APP_PORT} --restart unless-stopped ${APP_NAME}:latest || exit 64
        else
            echo "[REMOTE ERROR] No Docker configuration found"
            exit 65
        fi

        echo "[REMOTE] Waiting for container to be healthy..."
        sleep 5

        # Validate container is running
        if docker ps | grep -q ${APP_NAME}; then
            echo "[REMOTE] Container is running"
            docker ps | grep ${APP_NAME}
        else
            echo "[REMOTE ERROR] Container failed to start"
            docker logs ${APP_NAME} || true
            exit 66
        fi
ENDSSH

    if [[ $? -eq 0 ]]; then
        log_success "Application deployed successfully"
    else
        error_exit "Failed to deploy application" 67
    fi
}

################################################################################
# NGINX CONFIGURATION
################################################################################

configure_nginx() {
    log_info "=== Configuring Nginx Reverse Proxy ==="

    local nginx_config="/etc/nginx/sites-available/${APP_NAME}"
    local domain_or_ip="${SERVER_IP}"

    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" bash <<ENDSSH
        set -euo pipefail

        echo "[REMOTE] Creating Nginx configuration..."
        sudo tee ${nginx_config} > /dev/null <<'NGINXCONF'
server {
    listen 80;
    server_name ${domain_or_ip};

    location / {
        proxy_pass http://localhost:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF

        # Replace variables in config
        sudo sed -i "s/\${domain_or_ip}/${domain_or_ip}/g" ${nginx_config}
        sudo sed -i "s/\${APP_PORT}/${APP_PORT}/g" ${nginx_config}

        echo "[REMOTE] Enabling site..."
        sudo ln -sf ${nginx_config} /etc/nginx/sites-enabled/${APP_NAME}

        # Remove default site if exists
        sudo rm -f /etc/nginx/sites-enabled/default

        echo "[REMOTE] Testing Nginx configuration..."
        sudo nginx -t || exit 70

        echo "[REMOTE] Reloading Nginx..."
        sudo systemctl reload nginx || exit 71

        echo "[REMOTE] Nginx configured successfully"
ENDSSH

    if [[ $? -eq 0 ]]; then
        log_success "Nginx configured successfully"
    else
        error_exit "Failed to configure Nginx" 72
    fi
}

################################################################################
# DEPLOYMENT VALIDATION
################################################################################

validate_deployment() {
    log_info "=== Validating Deployment ==="

    # Validate Docker service
    log_info "Checking Docker service..."
    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "sudo systemctl is-active docker" &>/dev/null || error_exit "Docker service is not running" 80
    log_success "Docker service is running"

    # Validate container
    log_info "Checking container status..."
    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "docker ps | grep ${APP_NAME}" &>/dev/null || error_exit "Container is not running" 81
    log_success "Container is healthy and running"

    # Validate Nginx
    log_info "Checking Nginx service..."
    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "sudo systemctl is-active nginx" &>/dev/null || error_exit "Nginx service is not running" 82
    log_success "Nginx service is running"

    # Test endpoint from remote server
    log_info "Testing application endpoint from remote server..."
    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" \
        "curl -f -s -o /dev/null http://localhost:${APP_PORT} || curl -f -s -o /dev/null http://localhost" || \
        log_warning "Application endpoint test failed (app may not have a root endpoint)"

    # Test via Nginx proxy
    log_info "Testing Nginx reverse proxy..."
    if curl -f -s -o /dev/null "http://${SERVER_IP}"; then
        log_success "Nginx reverse proxy is working correctly"
    else
        log_warning "Could not verify Nginx proxy (check firewall rules)"
    fi

    log_success "Deployment validation completed"
}

################################################################################
# CLEANUP FUNCTION
################################################################################

cleanup_deployment() {
    log_info "=== Cleaning Up Deployment ==="

    ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no "${SSH_USER}@${SERVER_IP}" bash <<ENDSSH
        set -euo pipefail

        echo "[REMOTE] Stopping and removing containers..."
        cd /home/${SSH_USER}/${APP_NAME} 2>/dev/null && docker-compose down 2>/dev/null || true
        docker stop ${APP_NAME} 2>/dev/null || true
        docker rm ${APP_NAME} 2>/dev/null || true

        echo "[REMOTE] Removing Docker images..."
        docker rmi ${APP_NAME}:latest 2>/dev/null || true

        echo "[REMOTE] Removing Nginx configuration..."
        sudo rm -f /etc/nginx/sites-enabled/${APP_NAME}
        sudo rm -f /etc/nginx/sites-available/${APP_NAME}
        sudo systemctl reload nginx

        echo "[REMOTE] Removing project files..."
        rm -rf /home/${SSH_USER}/${APP_NAME}

        echo "[REMOTE] Cleanup completed"
ENDSSH

    log_success "Cleanup completed successfully"
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    log_info "================================"
    log_info "Docker Deployment Script Started"
    log_info "Timestamp: $(date)"
    log_info "Log File: ${LOG_FILE}"
    log_info "================================"
    echo ""

    # Check for cleanup flag
    if [[ "${1:-}" == "--cleanup" ]]; then
        CLEANUP_MODE=true
        log_info "Running in CLEANUP mode"
        collect_parameters
        cleanup_deployment
        log_success "Script completed successfully"
        exit 0
    fi

    # Normal deployment flow
    collect_parameters
    echo ""

    clone_repository
    echo ""

    validate_ssh_connection
    echo ""

    prepare_remote_environment
    echo ""

    deploy_application
    echo ""

    configure_nginx
    echo ""

    validate_deployment
    echo ""

    log_success "================================"
    log_success "Deployment Completed Successfully!"
    log_success "================================"
    log_info "Application URL: http://${SERVER_IP}"
    log_info "Application Name: ${APP_NAME}"
    log_info "Container Port: ${APP_PORT}"
    log_info "Log File: ${LOG_FILE}"
    log_info ""
    log_info "To clean up this deployment, run:"
    log_info "  ./deploy.sh --cleanup"
}

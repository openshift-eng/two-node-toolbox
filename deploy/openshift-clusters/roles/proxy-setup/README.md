# Proxy Setup Role

This role configures proxy access for OpenShift clusters by setting up a squid proxy container and creating environment configuration for cluster access.

## Description

The proxy-setup role handles proxy configuration for OpenShift clusters by:

1. Fetching cluster credentials (kubeconfig and kubeadmin-password)
2. Creating proxy environment configuration files
3. Installing and configuring proxy infrastructure (firewalld, podman, squid)
4. Setting up firewall rules for proxy access
5. Starting squid proxy container for cluster connectivity

This role enables easy access to OpenShift clusters deployed in restricted network environments by providing HTTP/HTTPS proxy functionality.

## Requirements

- Remote host with deployed OpenShift cluster
- sudo access for installing packages and configuring firewall
- Podman container runtime
- Network connectivity between proxy host and cluster

## Role Variables

### Required Variables

- `kubeconfig_path`: Path to cluster kubeconfig file on remote host
- `kubeadmin_password_path`: Path to cluster admin password file on remote host

### Optional Variables

- `proxy_port`: Port for proxy service (default: 8213)
- `proxy_user`: Default user for squid configuration (default: ec2-user)

## Usage

This role is typically used after cluster deployment:

```yaml
- name: Setup proxy access
  include_role:
    name: proxy-setup
  vars:
    kubeconfig_path: "{{ cluster_kubeconfig_path }}"
    kubeadmin_password_path: "{{ cluster_admin_password_path }}"
```

## Files Created

- `./kubeconfig`: Local copy of cluster kubeconfig
- `./kubeadmin-password`: Local copy of cluster admin password
- `./proxy.env`: Environment file with proxy configuration

## Generated Environment

The `proxy.env` file includes:
- HTTP/HTTPS proxy configuration
- KUBECONFIG path setup
- Kubernetes authentication proxy settings
- NO_PROXY exclusions for essential services

## Task Structure

- `main.yml`: Orchestrates all proxy setup tasks
- `credentials.yml`: Fetches cluster credentials
- `environment.yml`: Creates proxy environment configuration
- `infrastructure.yml`: Installs and configures proxy infrastructure
- `container.yml`: Manages squid proxy container

## Notes

- **Security**: Proxy runs on port 8213 and is configured for cluster access only
- **Firewall**: Automatically configures firewall rules for proxy access
- **Persistence**: Proxy container has restart policy for reliability 
# Cloud Security Lab

End to end threat detection, incident response, and automated remediation across AWS and Kubernetes. This project mirrors a production security operations workflow, covering the full attack and defense lifecycle using real tooling, MITRE ATT&CK mapped kill chains, and measurable detection and response outcomes.

![Architecture Diagram](docs/architecture-diagram.svg)

## Project Outcomes

- Deployed 62 Terraform resources across 7 modules, covering threat surfaces, detection, SIEM, and automated remediation
- Executed a full MITRE ATT&CK mapped kill chain: credential compromise to privilege escalation (1,039 to 15,319 permissions) to S3 data exfiltration to lateral movement via STS role assumption
- Detected 100% of runtime attack scenarios (shell injection, credential theft, container escape, crypto miner simulation) using Falco on K3s
- Enforced preventive controls via OPA Gatekeeper, blocking privileged containers, host namespace access, and root execution across all non system namespaces
- Correlated CloudTrail, VPC Flow Logs, and GuardDuty findings in OpenSearch dashboards for real time kill chain visualization

## Architecture

### AWS Threat Surface and Detection

The AWS layer consists of intentionally vulnerable infrastructure deployed via Terraform, paired with a full detection and response pipeline.

**Threat Surface Modules:**
The `threat-surface-vpc` module provisions a VPC with a public subnet, permissive security group, and VPC Flow Logs forwarded to CloudWatch. The `threat-surface-ec2` module deploys an instance in the permissive subnet. The `threat-surface-s3` module creates a sensitive data bucket with customer PII staged under a `confidential/` prefix. The `threat-surface-iam` module provisions an overprivileged IAM user with 1,039 permissions and a pivot role with a trust policy allowing the compromised user to assume it.

**Detection Module:**
CloudTrail captures all API activity with logs delivered to both S3 and CloudWatch Logs. A CloudWatch metric filter monitors for IAM configuration changes, triggering an alarm on unauthorized modifications.

**SIEM Module:**
An OpenSearch domain ingests CloudTrail logs and VPC Flow Logs via CloudWatch Logs subscription filters. Five visualizations and a kill chain correlation dashboard provide real time visibility into attacker activity.

**Remediation Module:**
EventBridge rules monitor GuardDuty findings for IAM related threats. A Lambda function (`disable_iam_keys`) automatically disables compromised access keys when triggered. Additional rules monitor for EC2 and security group related findings.

### Kubernetes Runtime Security

The Kubernetes layer runs on a K3s cluster (k3d) with Falco for runtime threat detection and OPA Gatekeeper for policy enforcement.

**Falco:**
Deployed as a DaemonSet with the `modern_ebpf` driver and Falcosidekick for alert forwarding. Four custom detection rules cover shell spawning, sensitive file reads, unauthorized process execution, and container escape via mount, all tagged with MITRE ATT&CK technique IDs.

**OPA Gatekeeper:**
Three constraint templates enforce preventive controls: deny privileged containers (`K8sDenyPrivileged`), deny host namespace access (`K8sDenyHostNamespace`), and deny containers running as root (`K8sDenyRunAsRoot`). System namespaces (`kube-system`, `gatekeeper-system`, `falco`) are excluded.

## Kill Chain: MITRE ATT&CK Mapping

| Phase | Tactic | Technique | Action | Result |
|-------|--------|-----------|--------|--------|
| Initial Access | TA0001 | T1078.004 Valid Accounts: Cloud | Obtained leaked IAM credentials | Active access key for compromised user |
| Discovery | TA0007 | T1580, T1087.004 | Enumerated permissions, users, roles via Pacu | 1,039 permissions, 27 roles, pivot role identified |
| Privilege Escalation | TA0004 | T1098.003 Additional Cloud Roles | Pacu attached AdministratorAccess policy | Escalated to 15,319 permissions |
| Exfiltration | TA0010 | T1530 Data from Cloud Storage | Accessed S3 sensitive data bucket | Exfiltrated customer PII (names, SSNs, emails) |
| Lateral Movement | TA0008 | T1550.001 Application Access Token | Assumed pivot role via sts:AssumeRole | Obtained temporary credentials under new identity |

Full kill chain documentation with evidence: [docs/kill-chain-documentation.md](docs/kill-chain-documentation.md)

## Runtime Attack Scenarios (Kubernetes)

| Attack | Falco Rule Triggered | Priority | MITRE Tag |
|--------|---------------------|----------|-----------|
| Shell spawn in container | Terminal Shell in Container | WARNING | mitre_execution |
| Read /etc/shadow, /etc/passwd | Read Sensitive File in Container | WARNING | mitre_credential_access |
| Unauthorized binary execution | Unauthorized Process in Container | NOTICE | mitre_execution |
| Binary drop via apt/curl | Drop and execute new binary in container | WARNING | mitre_execution |
| Container escape via host mount | Container Escape via Mount | CRITICAL | mitre_privilege_escalation |
| Reverse shell attempt | Terminal Shell in Container | WARNING | mitre_execution |
| Service account token theft | Read Sensitive File in Container | WARNING | mitre_credential_access |

## Gatekeeper Policy Enforcement

| Constraint | What It Blocks | Test Result |
|------------|---------------|-------------|
| K8sDenyPrivileged | Containers with `privileged: true` | Denied |
| K8sDenyHostNamespace | Pods with hostNetwork, hostPID, or hostIPC | Denied |
| K8sDenyRunAsRoot | Containers without `runAsNonRoot: true` | Denied |

Compliant pods (non privileged, non root) are admitted normally.

## Tech Stack

| Category | Tools |
|----------|-------|
| Infrastructure as Code | Terraform (7 modules, 62 resources) |
| Cloud Provider | AWS (IAM, EC2, S3, VPC, CloudTrail, GuardDuty, CloudWatch, Lambda, EventBridge, OpenSearch) |
| Kubernetes | K3s (k3d), Helm |
| Runtime Security | Falco (modern_ebpf driver), Falcosidekick |
| Policy Enforcement | OPA Gatekeeper (Rego) |
| Offensive Security | Pacu (AWS exploitation framework), ScoutSuite (cloud security auditing) |
| SIEM | OpenSearch with CloudTrail and VPC Flow Log ingestion |
| Framework | MITRE ATT&CK Cloud Matrix |

## Project Structure

```
cloud-security-lab/
  docs/
    kill-chain-documentation.md
    architecture-diagram.svg
  k8s/
    falco/
      install.sh
      values.yaml
    gatekeeper/
      install.sh
      constraint-templates.yaml
      constraints.yaml
      test-privileged-pod.yaml
  terraform/
    main.tf
    variables.tf
    outputs.tf
    providers.tf
    backend.tf
    terraform.tfvars
    modules/
      threat-surface-vpc/
      threat-surface-ec2/
      threat-surface-s3/
      threat-surface-iam/
      detection/
      siem/
      remediation/
```

## Deployment

**Prerequisites:** AWS CLI configured, Terraform installed, Helm installed, Docker running (for k3d)

**AWS Infrastructure:**
```bash
cd terraform
terraform init
terraform plan
terraform apply
```

**Kubernetes (Falco and Gatekeeper):**
```bash
# Create local K3s cluster
k3d cluster create cloud-security-lab --agents 1

# Install Falco
cd k8s/falco && bash install.sh

# Install Gatekeeper
cd k8s/gatekeeper && bash install.sh
kubectl apply -f constraint-templates.yaml
kubectl apply -f constraints.yaml
```

**Offensive Testing:**
```bash
# Install Pacu
pip3 install pacu

# Run ScoutSuite
scout aws --no-browser
```

## Teardown

```bash
# Kubernetes
k3d cluster delete cloud-security-lab

# AWS
cd terraform && terraform destroy
```

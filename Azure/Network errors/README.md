# Information on the lecture

This lecture was performed in Göteborg on the 24/10/2025.

# Azure Network Troubleshooting Demo

This PowerShell script (`network-error-demo.ps1`) creates a demo Azure environment with intentional network misconfigurations for educational purposes. The script deploys a hub-and-spoke network architecture with Azure Firewall, Application Gateway, and various network components—all with specific errors that can be used to teach troubleshooting techniques.

## Architecture Overview

The script deploys:

- **Hub VNet** (10.0.0.0/16) with Azure Firewall and Bastion
- **Spoke VNet** (10.1.0.0/16) with Application Gateway and 2 test VMs
- **VNet Peering** between hub and spoke
- **Network Security Groups** with security rules
- **Route Tables** for traffic routing
- **Test Virtual Machines** for connectivity testing

## Intentional Errors for Troubleshooting

### Error 1: NSG Blocking HTTP Traffic

**Location**: Lines ~148-157 in the script
**Issue**: The NSG rule `AllowHTTP` is configured with `--access Deny` instead of `Allow`, blocking HTTP traffic on port 80

```powershell
# INCORRECT (in script)
--access Deny `
```

**Important Note**: The Application Gateway health probe ports (65200-65535) are correctly set to `Allow` in the script because Azure deployment will fail if these ports are blocked. The primary intentional error is the blocking of HTTP port 80 traffic.

**Symptoms**:

- HTTP 502 Bad Gateway errors when accessing the Application Gateway
- HTTP connectivity blocked on port 80
- Web traffic cannot reach backend servers

### Error 2: Application Gateway Backend Pool Misconfiguration

**Location**: Lines ~190-200 in the script
**Issue**: Backend pool points to unreachable IP addresses (10.1.5.10, 10.1.5.11) instead of the actual VM IP

```powershell
# INCORRECT (in script)
--servers 10.1.5.10 10.1.5.11
```

**Symptoms**:

- No response from Application Gateway
- Backend health shows "Unhealthy"
- Connection timeouts

### Error 3: Route Table Next-Hop Misconfiguration

**Location**: Lines ~310-315 in the script
**Issue**: Route points to wrong next-hop IP (10.0.1.99) instead of Azure Firewall's private IP (10.0.1.4)

```powershell
# INCORRECT (in script)
--next-hop-ip-address 10.0.1.99
```

**Symptoms**:

- VMs in management subnet cannot reach internet
- Asymmetric routing issues
- Connectivity failures through firewall

## Deployment Instructions

### Prerequisites

- Azure CLI installed and configured
- PowerShell 5.1 or PowerShell Core
- Contributor access to Azure subscription

### Script Features

The script includes a **live timer function** (`Write-StepWithTimer`) that provides real-time feedback during deployment:

- Shows elapsed time for each deployment stage
- Displays a running timer (mm:ss format) while resources are being created
- Provides completion time for each stage
- Helps track deployment progress and estimate remaining time

### Deploy the Demo Environment

```powershell
# Clone the repository
git clone <your-repo-url>
cd "lectures/Azure/Network errors"

# Run the deployment script
./network-error-demo.ps1 -RG "rg-network-demo" -Location "swedencentral"
```

**Deployment time**: Approximately 15-60 minutes (this varies based on Azure Firewall and Azure Bastion deployment times)

## Testing the Errors

### Test 1: Application Gateway Connectivity

```bash
# Get the Application Gateway public IP
$appgwIP = az network public-ip show -g rg-network-demo -n pip-appgw --query ipAddress -o tsv

# Test HTTP connectivity (should fail due to NSG rule)
curl http://$appgwIP

# Expected result: Connection timeout or 502 error
```

### Test 2: Backend Health Check

```bash
# Check Application Gateway backend health
az network application-gateway show-backend-health -g rg-network-demo -n appgw-demo

# Expected result: All backends showing as "Unhealthy"
```

### Test 3: Route Table Verification

```bash
# Check effective routes on management VM
az network nic show-effective-route-table -g rg-network-demo --name vm-mgmtVMNic

# Expected result: Route to 0.0.0.0/0 pointing to wrong next-hop (10.0.1.99)
```

### Test 4: NSG Effective Rules

```bash
# Check NSG rules affecting Application Gateway subnet
az network nsg show -g rg-network-demo -n nsg-appgw --query "securityRules[?direction=='Inbound'].[name,access,destinationPortRange,priority]" -o table

# Expected result: HTTP rule (port 80) showing "Deny" access while health probe ports (65200-65535) show "Allow"
```

## Fixing the Errors

### Fix 1: Correct NSG Rule for HTTP Traffic

```bash
# Delete the blocking HTTP rule
az network nsg rule delete -g rg-network-demo --nsg-name nsg-appgw -n AllowHTTP

# Create the correct HTTP rule to allow traffic
az network nsg rule create \
  -g rg-network-demo \
  --nsg-name nsg-appgw \
  -n AllowHTTP \
  --priority 200 \
  --source-address-prefixes '*' \
  --destination-port-ranges 80 \
  --access Allow \
  --protocol Tcp
```

**Note**: The Application Gateway health probe rule (`AllowGatewayManager`) is already correctly configured with `Allow` access in the script, as blocking these ports would prevent successful deployment.

### Fix 2: Update Application Gateway Backend Pool

```bash
# Get the actual web server VM IP
$vmWebIP = az vm show -g rg-network-demo -n vm-webserver -d --query privateIps -o tsv

# Update backend pool with correct IP
az network application-gateway address-pool update \
  -g rg-network-demo \
  --gateway-name appgw-demo \
  -n appGatewayBackendPool \
  --servers $vmWebIP
```

### Fix 3: Correct Route Table Next-Hop

```bash
# Get the Azure Firewall private IP
$fwPrivateIP = az network firewall show -g rg-network-demo -n azfw-hub --query 'ipConfigurations[0].privateIPAddress' -o tsv

# Update route with correct next-hop
az network route-table route update \
  -g rg-network-demo \
  --route-table-name rt-spoke-to-hub \
  -n route-all-to-firewall \
  --next-hop-ip-address $fwPrivateIP
```

## Verification After Fixes

### Verify Fix 1: Health Probes

```bash
# Check backend health (should now show healthy)
az network application-gateway show-backend-health -g rg-network-demo -n appgw-demo
```

### Verify Fix 2: Application Gateway Connectivity

```bash
# Test HTTP connectivity (should now work)
curl http://$appgwIP

# Expected result: HTML response from the web server
```

### Verify Fix 3: Internet Connectivity

```bash
# Connect to management VM via Bastion and test internet connectivity
# From within the VM:
curl http://www.microsoft.com
```

## Educational Objectives

This demo helps students learn:

1. **Network Security Group Troubleshooting**

   - Understanding NSG rule evaluation
   - Identifying blocked traffic patterns
   - Using effective security rules

2. **Application Gateway Diagnostics**

   - Backend health monitoring
   - Health probe configuration
   - Backend pool management

3. **Route Table Configuration**

   - Next-hop IP validation
   - Effective route analysis
   - Traffic flow troubleshooting

4. **Azure Networking Best Practices**
   - Hub-and-spoke architecture
   - Network segmentation
   - Security rule design

## Cleanup

To remove all resources created by this demo:

```bash
# Delete the entire resource group
az group delete -n rg-network-demo --yes --no-wait
```

## Additional Resources

- [Azure Application Gateway troubleshooting](https://docs.microsoft.com/en-us/azure/application-gateway/application-gateway-troubleshooting-502)
- [Network Security Group troubleshooting](https://docs.microsoft.com/en-us/azure/virtual-network/diagnose-network-traffic-filtering-problem)
- [Azure Firewall troubleshooting](https://docs.microsoft.com/en-us/azure/firewall/firewall-faq)
- [Route table troubleshooting](https://docs.microsoft.com/en-us/azure/virtual-network/diagnose-network-routing-problem)

## Important Notes

- This script creates resources that incur Azure costs
- Always clean up resources after the demo
- The intentional errors are clearly marked in the script comments
- This environment is for educational purposes only - not for production use

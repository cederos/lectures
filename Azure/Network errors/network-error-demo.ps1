# azure-devops-demo-deploy.ps1
# Azure DevOps Infrastructure Demo - Hub and Spoke with Intentional Misconfigurations
#
# PURPOSE: This script creates a demo environment for Azure DevOps lectures with
# intentional misconfigurations that can be used as teaching points for troubleshooting.
#
# FEATURES:
# - Modern Azure Firewall with Firewall Policy (Premium tier)
# - Hub-and-spoke network architecture
# - Application Gateway with backend pools
# - Network Security Groups with intentional misconfigurations
#
# INTENTIONAL ERRORS FOR DEMO:
# ERROR 1: NSG rule blocking Application Gateway health probes (line ~85)
# ERROR 2: Application Gateway backend pool with wrong IP addresses (line ~195)
# ERROR 3: Missing/incorrect route table configuration (line ~280)
#
# Deploy time: ~12-15 minutes
# Cleanup: Use the cleanup section at the bottom

param(
    [string]$RG = 'rg-devops-demo',
    [string]$Location = 'swedencentral',
    [string]$Environment = 'demo'
)

# Color coding for output
function Write-Step([string]$Message, [string]$Color = 'Green') {
    Write-Host " * $Message" -ForegroundColor $Color
}

function Write-StepWithTimer([string]$Message, [scriptblock]$Action) {
    $start = Get-Date
    Write-Host " * $Message" -ForegroundColor Green

    # Start the action in background
    $job = Start-Job -ScriptBlock $Action

    # Show live timer while job runs
    do {
        $elapsed = (Get-Date) - $start
        $timeStr = $elapsed.ToString('mm\:ss')
        Write-Host "`r Running: $timeStr" -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    } while ($job.State -eq 'Running')

    # Get job results
    $result = Receive-Job $job
    Remove-Job $job

    $final = (Get-Date) - $start
    Write-Host "`n Completed in: $($final.ToString('mm\:ss'))" -ForegroundColor Magenta

    return $result
}

Write-Host 'Starting Azure DevOps Demo Infrastructure Deployment' -ForegroundColor Cyan
Write-Host "Resource Group: $RG" -ForegroundColor White
Write-Host "Location: $Location" -ForegroundColor White

# =============================================================================
# STAGE 1-4: RESOURCE GROUP AND NETWORKING FOUNDATION
# =============================================================================

Write-StepWithTimer 'Stage 1: Creating Resource Group' {
    az group create -n $using:RG -l $using:Location --tags "Environment=$using:Environment" 'Purpose=DevOpsDemo' | Out-Null
}

Write-StepWithTimer 'Stage 2: Creating Hub VNet with Subnets' {
    # Hub VNet: 10.0.0.0/16
    az network vnet create `
        -g $using:RG `
        -n vnet-hub `
        --address-prefix 10.0.0.0/16 `
        --subnet-name AzureFirewallSubnet `
        --subnet-prefix 10.0.1.0/24 `
        --tags "Environment=$using:Environment" | Out-Null

    # Add Bastion subnet to hub
    az network vnet subnet create `
        -g $using:RG `
        --vnet-name vnet-hub `
        -n AzureBastionSubnet `
        --zone 1 `
        --address-prefixes 10.0.2.0/27 | Out-Null
}

Write-StepWithTimer 'Stage 3: Creating Spoke VNet with Application Subnets' {
    # Spoke VNet: 10.1.0.0/16
    az network vnet create `
        -g $using:RG `
        -n vnet-spoke `
        --address-prefix 10.1.0.0/16 `
        --subnet-name snet-appgw `
        --subnet-prefix 10.1.1.0/24 `
        --tags "Environment=$using:Environment" | Out-Null

    # Add application subnet
    az network vnet subnet create `
        -g $using:RG `
        --vnet-name vnet-spoke `
        -n snet-app `
        --address-prefixes 10.1.2.0/24 | Out-Null

    # Add management subnet (for VMs, testing)
    az network vnet subnet create `
        -g $using:RG `
        --vnet-name vnet-spoke `
        -n snet-mgmt `
        --address-prefixes 10.1.3.0/24 | Out-Null
}

Write-StepWithTimer 'Stage 4: Creating VNet Peering (Hub <-> Spoke)' {
    $subId = az account show --query id -o tsv
    az network vnet peering create `
        -g $using:RG `
        -n hub-to-spoke `
        --vnet-name vnet-hub `
        --remote-vnet "/subscriptions/$subId/resourceGroups/$using:RG/providers/Microsoft.Network/virtualNetworks/vnet-spoke" `
        --allow-vnet-access | Out-Null

    az network vnet peering create `
        -g $using:RG `
        -n spoke-to-hub `
        --vnet-name vnet-spoke `
        --remote-vnet "/subscriptions/$subId/resourceGroups/$using:RG/providers/Microsoft.Network/virtualNetworks/vnet-hub" `
        --allow-vnet-access | Out-Null
}

# =============================================================================
# STAGE 5-6: NETWORK SECURITY GROUPS (WITH INTENTIONAL ERRORS)
# =============================================================================

# Application Gateway NSG - WITH INTENTIONAL ERROR FOR DEMO

Write-StepWithTimer 'Stage 5: Creating NSGs with Security Rules' {
    az network nsg create -g $using:RG -n nsg-appgw --tags "Environment=$using:Environment" | Out-Null

    # CORRECT rule for Application Gateway management
    az network nsg rule create `
        -g $using:RG `
        --nsg-name nsg-appgw `
        -n AllowGatewayManager `
        --priority 100 `
        --source-address-prefixes 'GatewayManager' `
        --destination-port-ranges 65200-65535 `
        --access Allow `
        --protocol Tcp | Out-Null

    # INTENTIONAL ERROR 1: Block HTTP traffic that should be allowed
    az network nsg rule create `
        -g $using:RG `
        --nsg-name nsg-appgw `
        -n AllowHTTP `
        --priority 200 `
        --source-address-prefixes '*' `
        --destination-port-ranges 80 `
        --access Deny `
        --protocol Tcp | Out-Null
    Write-Host "`n INTENTIONAL DEMO ERROR: Blocking HTTP traffic on port 80 - this will break web access!" -ForegroundColor Yellow

    # Allow HTTPS (this one is correct)
    az network nsg rule create `
        -g $using:RG `
        --nsg-name nsg-appgw `
        -n AllowHTTPS `
        --priority 300 `
        --source-address-prefixes '*' `
        --destination-port-ranges 443 `
        --access Allow `
        --protocol Tcp | Out-Null

    # Application subnet NSG
    az network nsg create -g $using:RG -n nsg-app --tags "Environment=$using:Environment" | Out-Null
    az network nsg rule create `
        -g $using:RG `
        --nsg-name nsg-app `
        -n AllowAppGateway `
        --priority 100 `
        --source-address-prefixes '10.1.1.0/24' `
        --destination-port-ranges 80 443 `
        --access Allow `
        --protocol Tcp | Out-Null

    # Management subnet NSG
    az network nsg create -g $using:RG -n nsg-mgmt --tags "Environment=$using:Environment" | Out-Null
    az network nsg rule create `
        -g $using:RG `
        --nsg-name nsg-mgmt `
        -n AllowBastion `
        --priority 100 `
        --source-address-prefixes '10.0.2.0/27' `
        --destination-port-ranges 22 3389 `
        --access Allow `
        --protocol Tcp | Out-Null
}

Write-StepWithTimer 'Stage 6: Associating NSGs to Subnets' {
    az network vnet subnet update -g $using:RG --vnet-name vnet-spoke -n snet-appgw --network-security-group nsg-appgw | Out-Null
    az network vnet subnet update -g $using:RG --vnet-name vnet-spoke -n snet-app --network-security-group nsg-app | Out-Null
    az network vnet subnet update -g $using:RG --vnet-name vnet-spoke -n snet-mgmt --network-security-group nsg-mgmt | Out-Null
}

# =============================================================================
# STAGE 7-8: APPLICATION GATEWAY (WITH INTENTIONAL MISCONFIGURATION)
# =============================================================================

Write-StepWithTimer 'Stage 7: Creating Public IP for Application Gateway' {
    az network public-ip create `
        -g $using:RG `
        -n pip-appgw `
        --sku Standard `
        --allocation-method Static `
        --zone 1 `
        --tags "Environment=$using:Environment" | Out-Null
}

# INTENTIONAL ERROR 2: We'll place AppGW in the wrong subnet later for demo purposes

Write-StepWithTimer 'Stage 8: Creating Application Gateway' {
    az network application-gateway create `
        -g $using:RG `
        -n appgw-demo `
        --vnet-name vnet-spoke `
        --subnet snet-appgw `
        --public-ip-address pip-appgw `
        --sku Standard_v2 `
        --capacity 2 `
        --http-settings-port 80 `
        --http-settings-protocol Http `
        --frontend-port 80 `
        --priority 100 `
        --tags "Environment=$using:Environment" | Out-Null
    Write-Host "`n Application Gateway will be configured with wrong backend settings" -ForegroundColor Yellow

    # INTENTIONAL ERROR 3: Add a backend pool pointing to wrong IP range
    az network application-gateway address-pool update `
        -g $using:RG `
        --gateway-name appgw-demo `
        -n appGatewayBackendPool `
        --servers 10.1.5.10 10.1.5.11 | Out-Null
    Write-Host "`n Update backend pool with unreachable IP addresses!" -ForegroundColor Yellow
}

# =============================================================================
# STAGE 9-10: AZURE FIREWALL POLICY AND FIREWALL
# =============================================================================

Write-StepWithTimer 'Stage 9: Creating Azure Firewall Policy' {
    az network firewall policy create `
        -g $using:RG `
        -n azfw-policy `
        --sku Premium `
        --threat-intel-mode Alert `
        --tags "Environment=$using:Environment" | Out-Null
}

Write-StepWithTimer 'Stage 9a: Creating Application Rule Collection Group' {
    az network firewall policy rule-collection-group create `
        -g $using:RG `
        --policy-name azfw-policy `
        -n app-rules `
        --priority 200 | Out-Null
}

Write-StepWithTimer 'Stage 9b: Creating Application Rules for Web Traffic' {
    az network firewall policy rule-collection-group collection add-filter-collection `
        -g $using:RG `
        --policy-name azfw-policy `
        --rule-collection-group-name app-rules `
        --name AllowWebTraffic `
        --collection-priority 300 `
        --action Allow `
        --rule-name AllowHTTPSToWeb `
        --rule-type ApplicationRule `
        --source-addresses '10.1.0.0/16' `
        --protocols 'Http=80' 'Https=443' `
        --target-fqdns '*.microsoft.com' '*.azure.com' '*.ubuntu.com' 'security.ubuntu.com' 'archive.ubuntu.com' | Out-Null
}

Write-StepWithTimer 'Stage 9c: Creating Network Rule Collection for Management' {
    az network firewall policy rule-collection-group collection add-filter-collection `
        -g $using:RG `
        --policy-name azfw-policy `
        --rule-collection-group-name app-rules `
        --name AllowManagement `
        --collection-priority 200 `
        --action Allow `
        --rule-name AllowDNS `
        --rule-type NetworkRule `
        --source-addresses '10.1.0.0/16' `
        --ip-protocols UDP `
        --destination-addresses '168.63.129.16' '8.8.8.8' '1.1.1.1' `
        --destination-ports 53 | Out-Null
}

Write-StepWithTimer 'Stage 9d: Creating Azure Firewall with Policy' {
    az network public-ip create `
        -g $using:RG `
        -n pip-firewall `
        --sku Standard `
        --zone 1 `
        --tags "Environment=$using:Environment" | Out-Null

    az network firewall create `
        -g $using:RG `
        -n azfw-hub `
        --sku AZFW_VNet `
        --tier Premium `
        --vnet-name vnet-hub `
        --conf-name azfw-ipconfig `
        --public-ip pip-firewall `
        --firewall-policy azfw-policy `
        --tags "Environment=$using:Environment" | Out-Null
}

Write-StepWithTimer 'Stage 10: Creating Bastion Host' {
    az network public-ip create `
        -g $using:RG `
        -n pip-bastion `
        --sku Standard `
        --tags "Environment=$using:Environment" | Out-Null

    az network bastion create `
        -g $using:RG `
        -n bastion-hub `
        --vnet-name vnet-hub `
        --public-ip-address pip-bastion `
        --sku Basic `
        --tags "Environment=$using:Environment" | Out-Null
}

# =============================================================================
# STAGE 11: ROUTE TABLES (WITH INTENTIONAL ERROR)
# =============================================================================

# INTENTIONAL ERROR 3: Create route pointing to wrong next-hop IP

Write-StepWithTimer 'Stage 11: Creating Route Tables' {
    az network route-table create -g $using:RG -n rt-spoke-to-hub --tags "Environment=$using:Environment" | Out-Null

    az network route-table route create `
        -g $using:RG `
        --route-table-name rt-spoke-to-hub `
        -n route-all-to-firewall `
        --address-prefix 0.0.0.0/0 `
        --next-hop-type VirtualAppliance `
        --next-hop-ip-address 10.0.1.99 | Out-Null  # Wrong IP! Should be 10.0.1.4
    Write-Host "`n Creating route with incorrect next-hop IP address!" -ForegroundColor Yellow

    # Associate route table to management subnet (this will cause connectivity issues)
    az network vnet subnet update `
        -g $using:RG `
        --vnet-name vnet-spoke `
        -n snet-mgmt `
        --route-table rt-spoke-to-hub | Out-Null
}

# =============================================================================
# STAGE 12: TEST VIRTUAL MACHINES
# =============================================================================

Write-StepWithTimer 'Stage 12: Creating Test Virtual Machines' {
    # Create a simple web server for testing
    az vm create `
        -g $using:RG `
        -n vm-webserver `
        --image Ubuntu2204 `
        --vnet-name vnet-spoke `
        --subnet snet-app `
        --admin-username azureuser `
        --generate-ssh-keys `
        --custom-data cloud-init.txt `
        --tags "Environment=$using:Environment" | Out-Null

    # Create management VM
    az vm create `
        -g $using:RG `
        -n vm-mgmt `
        --image Ubuntu2204 `
        --vnet-name vnet-spoke `
        --subnet snet-mgmt `
        --admin-username azureuser `
        --generate-ssh-keys `
        --tags "Environment=$using:Environment" | Out-Null
}

# =============================================================================
# STAGE 7: OUTPUT INFORMATION FOR DEMO
# =============================================================================

Write-Host "`n DEPLOYMENT COMPLETE - Demo Environment Ready!" -ForegroundColor Green

Write-Host "`n RESOURCE INFORMATION FOR DEMO:" -ForegroundColor Cyan

# Get Application Gateway Public IP details
$appgwPIPInfo = az network public-ip show -n pip-appgw --resource-group $rg --query ipAddress -o tsv
Write-Host "Application Gateway Public IP: $($appgwPIPInfo)" -ForegroundColor White

# Get Firewall details
$fwPrivateIP = az network firewall show -g $RG -n azfw-hub --query 'ipConfigurations[0].privateIPAddress' -o tsv
Write-Host "Azure Firewall Private IP: $fwPrivateIP" -ForegroundColor White

# Get VM details
$vmWebIP = az vm show -g $RG -n vm-webserver -d --query privateIps -o tsv
$vmMgmtIP = az vm show -g $RG -n vm-mgmt -d --query privateIps -o tsv
Write-Host "Web Server VM IP: $vmWebIP" -ForegroundColor White
Write-Host "Management VM IP: $vmMgmtIP" -ForegroundColor White

Write-Host "`n INTENTIONAL ERRORS FOR TROUBLESHOOTING DEMO:" -ForegroundColor Red
Write-Host "1. NSG 'nsg-appgw' has rule 'BlockHTTP-DEMO-ERROR' blocking port 80" -ForegroundColor Yellow
Write-Host "2. Application Gateway default backend pool 'appGatewayBackendPool' is empty (wrong pool 'backend-pool-wrong' has bad IPs)" -ForegroundColor Yellow
Write-Host "3. Route table 'rt-spoke-to-hub' has incorrect next-hop IP (10.0.1.99 instead of $fwPrivateIP)" -ForegroundColor Yellow

Write-Host "`n TESTING COMMANDS FOR DEMO:" -ForegroundColor Cyan
Write-Host '# Test Application Gateway connectivity:' -ForegroundColor Gray
Write-Host "curl http://$($appgwInfo.ip)" -ForegroundColor White
Write-Host "`n# Check NSG effective rules:" -ForegroundColor Gray
Write-Host "az network nic list-effective-nsg -g $RG --name vm-webserverVMNic" -ForegroundColor White
Write-Host "`n# Check route table:" -ForegroundColor Gray
Write-Host "az network nic show-effective-route-table -g $RG --name vm-mgmtVMNic" -ForegroundColor White

Write-Host "`n FIXES FOR DEMO (reveal during troubleshooting):" -ForegroundColor Green
Write-Host '1. Delete blocking NSG rule:' -ForegroundColor Gray
Write-Host "   az network nsg rule delete -g $RG --nsg-name nsg-appgw -n BlockHTTP-DEMO-ERROR" -ForegroundColor White
Write-Host "`n2. Add VM to correct Application Gateway backend pool:" -ForegroundColor Gray
Write-Host "   az network application-gateway address-pool update -g $RG --gateway-name appgw-demo -n appGatewayBackendPool --servers $vmWebIP" -ForegroundColor White
Write-Host "`n3. Fix route table next-hop:" -ForegroundColor Gray
Write-Host "   az network route-table route update -g $RG --route-table-name rt-spoke-to-hub -n route-to-internet --next-hop-ip-address $fwPrivateIP" -ForegroundColor White

Write-Host "`n CLEANUP COMMAND:" -ForegroundColor Red
Write-Host "az group delete -n $RG --yes --no-wait" -ForegroundColor White

Write-Host "`n Demo environment is ready for Azure DevOps troubleshooting session!" -ForegroundColor Green

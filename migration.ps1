# Load JSON configuration from file
$config = Get-Content -Raw -Path "./keyconfig.json" | ConvertFrom-Json

# Loop through each environment entry
foreach ($env in $config) {

    Write-Host "`n=== Logging in using Service Principal from JSON ==="

    # Extract SP info
    $sp = $env.ServicePrincipal

    # Convert secret to secure string
    $pw = ConvertTo-SecureString $sp.Secret -AsPlainText -Force

    # Build PSCredential object (AppId = username)
    $cred = New-Object System.Management.Automation.PSCredential($sp.AppId, $pw)

    # Login using classic parameters (compatible with GitHub Actions Az module)
    Connect-AzAccount `
        -ServicePrincipal `
        -Tenant $sp.Tenant `
        -Credential $cred `
        -ErrorAction Stop

    if (-not (Get-AzContext)) {
        Write-Error "Azure login failed. Stopping script."
        exit 1
    }

    Write-Host "✔ Azure login successful using SP $($sp.AppId)"

    # -------------------------------------------
    # MIGRATION STARTS
    # -------------------------------------------

    $spObjectId = "b2288382-af60-408b-9389-22ea420a94d9"

    # Switch to Source Subscription
    Write-Host "`nSwitching to Source Subscription: $($env.Source.SubscriptionId)"
    Set-AzContext -Subscription $env.Source.SubscriptionId

    # Switch to Target Subscription
    Write-Host "`nSwitching to Target Subscription: $($env.Target.SubscriptionId)"
    Set-AzContext -Subscription $env.Target.SubscriptionId
    $tenantId = (Get-AzContext).Tenant.Id

    # ----------------------
    # Ensure Target Resource Group exists
    # ----------------------
    Write-Host "`nChecking target Resource Group: $($env.Target.ResourceGroup)"
    $rg = Get-AzResourceGroup -Name $env.Target.ResourceGroup -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Host "Creating Resource Group: $($env.Target.ResourceGroup)"
        $rg = New-AzResourceGroup -Name $env.Target.ResourceGroup -Location $env.Target.Location
    } else {
        Write-Host "Resource Group already exists: $($env.Target.ResourceGroup)"
    }

    # ----------------------
    # Ensure Target Key Vault exists
    # ----------------------
    Write-Host "`nChecking target Key Vault: $($env.Target.KeyVaultName)"
    try {
        $targetVault = Get-AzKeyVault -VaultName $env.Target.KeyVaultName -ErrorAction Stop
        Write-Host "Key Vault already exists: $($env.Target.KeyVaultName)"
    }
    catch {
        Write-Host "Creating target Key Vault: $($env.Target.KeyVaultName)"
        $targetVault = New-AzKeyVault -Name $env.Target.KeyVaultName -ResourceGroupName $env.Target.ResourceGroup -Location $env.Target.Location -Sku $env.Target.Sku
    }

    # Grant access to the specified object ID
    Write-Host "Setting access policy for Object ID: $spObjectId"
    Set-AzKeyVaultAccessPolicy -VaultName $env.Target.KeyVaultName -ObjectId $spObjectId `
        -PermissionsToSecrets get,list,set,delete `
        -PermissionsToKeys get,list,create,delete `
        -PermissionsToCertificates get,list,create,delete

    # Merge tags
    $existingTags = $targetVault.Tags
    if (-not $existingTags) { $existingTags = @{} }

    $mergedTags = @{}
    foreach ($key in $existingTags.Keys) { $mergedTags[$key] = $existingTags[$key] }
    foreach ($key in $env.Tags.Keys) { $mergedTags[$key] = $env.Tags[$key] }

    Set-AzResource -ResourceId $targetVault.ResourceId -Tag $mergedTags -Force
    Write-Host "Tags applied to $($env.Target.KeyVaultName)"

    # ----------------------
    # Copy Secrets
    # ----------------------
    Write-Host "`nCopying Secrets from $($env.Source.KeyVaultName) to $($env.Target.KeyVaultName)"
    try {
        $secrets = Get-AzKeyVaultSecret -VaultName $env.Source.KeyVaultName -ErrorAction Stop
        foreach ($s in $secrets) {
            $secretValue = (Get-AzKeyVaultSecret -VaultName $env.Source.KeyVaultName -Name $s.Name).SecretValueText
            Set-AzKeyVaultSecret -VaultName $env.Target.KeyVaultName -Name $s.Name -SecretValue (ConvertTo-SecureString $secretValue -AsPlainText -Force)
        }
        Write-Host "Secrets copied successfully."
    }
    catch {
        Write-Warning "Could not copy secrets: $_"
    }

    # ----------------------
    # Copy Keys
    # ----------------------
    Write-Host "`nCopying Keys..."
    try {
        $keys = Get-AzKeyVaultKey -VaultName $env.Source.KeyVaultName -ErrorAction Stop
        foreach ($k in $keys) {
            Write-Host "Key $($k.Name) exists -> Manual copy may be required."
        }
    }
    catch {
        Write-Warning "Could not copy keys: $_"
    }

    # ----------------------
    # Copy Certificates
    # ----------------------
    Write-Host "`nCopying Certificates..."
    try {
        $certs = Get-AzKeyVaultCertificate -VaultName $env.Source.KeyVaultName -ErrorAction Stop
        foreach ($c in $certs) {
            Write-Host "Certificate $($c.Name) exists -> Manual copy may be required."
        }
    }
    catch {
        Write-Warning "Could not copy certificates: $_"
    }

    # ----------------------
    # Copy VNet/Subnet
    # ----------------------
    if ($env.VNet -and $env.Subnet) {
        try {
            # Get source VNet in source subscription
            Set-AzContext -Subscription $env.Source.SubscriptionId
            $sourceVnet = Get-AzVirtualNetwork -Name $env.VNet -ResourceGroupName $env.Source.ResourceGroup
            $sourceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $env.Subnet -VirtualNetwork $sourceVnet

            # Create VNet in target subscription
            Set-AzContext -Subscription $env.Target.SubscriptionId
            $targetVnet = New-AzVirtualNetwork -Name $sourceVnet.Name -ResourceGroupName $env.Target.ResourceGroup `
                -Location $sourceVnet.Location -AddressPrefix $sourceVnet.AddressSpace.AddressPrefixes[0]

            Add-AzVirtualNetworkSubnetConfig -Name $sourceSubnet.Name -AddressPrefix $sourceSubnet.AddressPrefix -VirtualNetwork $targetVnet
            $targetVnet | Set-AzVirtualNetwork

            Write-Host "VNet/Subnet copied successfully."
        }
        catch {
            Write-Warning "Could not copy VNet/Subnet: $_"
        }
    }

    Write-Host "`n=== Migration Completed for Key Vault: $($env.Target.KeyVaultName) ==="
}





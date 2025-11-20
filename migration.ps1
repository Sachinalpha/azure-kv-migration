# Load JSON configuration from file
$config = Get-Content -Raw -Path "./keyconfig.json" | ConvertFrom-Json

# Specify the Object ID to grant access
$spObjectId = "b2288382-af60-408b-9389-22ea420a94d9"

foreach ($env in $config) {

    ##############################################################
    # 1. LOGIN TO AZURE USING SP FROM JSON
    ##############################################################
    
    Write-Host "`nLogging in using Service Principal from JSON..."
    $sp = $env.ServicePrincipal

    $pw = ConvertTo-SecureString $sp.Secret -AsPlainText -Force

    Connect-AzAccount `
        -ServicePrincipal `
        -Tenant $sp.Tenant `
        -ApplicationId $sp.AppId `
        -Password $pw -ErrorAction Stop

    # Verify login
    if (-not (Get-AzContext)) {
        Write-Error "Azure login failed. Stopping script."
        exit 1
    }

    Write-Host "Azure login successful!"

    ##############################################################
    # 2. SWITCH SUBSCRIPTIONS
    ##############################################################

    Write-Host "`nSwitching to Source Subscription: $($env.Source.SubscriptionId)"
    Set-AzContext -Subscription $env.Source.SubscriptionId -ErrorAction Stop

    Write-Host "`nSwitching to Target Subscription: $($env.Target.SubscriptionId)"
    Set-AzContext -Subscription $env.Target.SubscriptionId -ErrorAction Stop
    $tenantId = (Get-AzContext).Tenant.Id

    ##############################################################
    # 3. RESOURCE GROUP CREATION
    ##############################################################

    Write-Host "`nChecking target Resource Group: $($env.Target.ResourceGroup)"
    $rg = Get-AzResourceGroup -Name $env.Target.ResourceGroup -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Host "Creating Resource Group: $($env.Target.ResourceGroup)"
        $rg = New-AzResourceGroup -Name $env.Target.ResourceGroup -Location $env.Target.Location
    }
    else {
        Write-Host "Resource Group already exists: $($env.Target.ResourceGroup)"
    }

    ##############################################################
    # 4. CREATE OR GET TARGET KEYVAULT
    ##############################################################

    $kvParams = @{
        Name              = $env.Target.KeyVaultName
        ResourceGroupName = $env.Target.ResourceGroup
        Location          = $env.Target.Location
        Sku               = $env.Target.Sku
    }

    Write-Host "`nCreating target Key Vault: $($env.Target.KeyVaultName)"
    try {
        $targetVault = New-AzKeyVault @kvParams -ErrorAction Stop
    }
    catch {
        Write-Warning "Key Vault may already exist: $_"
        $targetVault = Get-AzKeyVault -VaultName $env.Target.KeyVaultName -ErrorAction Stop
    }

    ##############################################################
    # 5. SET ACCESS POLICY
    ##############################################################

    Write-Host "Setting access policy for Object ID: $spObjectId"
    Set-AzKeyVaultAccessPolicy -VaultName $env.Target.KeyVaultName -ObjectId $spObjectId `
        -PermissionsToSecrets get,list,set,delete `
        -PermissionsToKeys get,list,create,delete `
        -PermissionsToCertificates get,list,create,delete

    ##############################################################
    # 6. MERGE TAGS
    ##############################################################

    $existingTags = $targetVault.Tags
    if (-not $existingTags) { $existingTags = @{} }

    $mergedTags = @{ }
    foreach ($key in $existingTags.Keys) { $mergedTags[$key] = $existingTags[$key] }
    foreach ($key in $env.Tags.Keys) { $mergedTags[$key] = $env.Tags[$key] }

    Set-AzResource -ResourceId $targetVault.ResourceId -Tag $mergedTags -Force
    Write-Host "Tags applied to $($env.Target.KeyVaultName)"

    ##############################################################
    # 7. COPY SECRETS
    ##############################################################

    Write-Host "`nCopying Secrets from $($env.Source.KeyVaultName) to $($env.Target.KeyVaultName)"
    try {
        # Switch to source subscription to read secrets
        Set-AzContext -Subscription $env.Source.SubscriptionId

        $secrets = Get-AzKeyVaultSecret -VaultName $env.Source.KeyVaultName -ErrorAction Stop

        foreach ($s in $secrets) {
            $secretValue = (Get-AzKeyVaultSecret -VaultName $env.Source.KeyVaultName -Name $s.Name).SecretValueText
            
            # Switch back to target subscription for writing
            Set-AzContext -Subscription $env.Target.SubscriptionId

            Set-AzKeyVaultSecret -VaultName $env.Target.KeyVaultName `
                -Name $s.Name `
                -SecretValue (ConvertTo-SecureString $secretValue -AsPlainText -Force)
        }
        Write-Host "Secrets copied successfully."
    }
    catch {
        Write-Warning "Could not copy secrets: $_"
    }

    ##############################################################
    # 8. CHECK KEYS
    ##############################################################

    Write-Host "`nCopying Keys from $($env.Source.KeyVaultName) to $($env.Target.KeyVaultName)"
    try {
        Set-AzContext -Subscription $env.Source.SubscriptionId
        $keys = Get-AzKeyVaultKey -VaultName $env.Source.KeyVaultName -ErrorAction Stop

        foreach ($k in $keys) {
            Write-Host "Key $($k.Name) exists. Manual copy may be required."
        }
    }
    catch {
        Write-Warning "Could not copy keys: $_"
    }

    ##############################################################
    # 9. CHECK CERTIFICATES
    ##############################################################

    Write-Host "`nCopying Certificates from $($env.Source.KeyVaultName) to $($env.Target.KeyVaultName)"
    try {
        Set-AzContext -Subscription $env.Source.SubscriptionId
        $certs = Get-AzKeyVaultCertificate -VaultName $env.Source.KeyVaultName -ErrorAction Stop

        foreach ($c in $certs) {
            Write-Host "Certificate $($c.Name) exists. Manual copy may be required."
        }
    }
    catch {
        Write-Warning "Could not copy certificates: $_"
    }

    ##############################################################
    # 10. COPY VNET + SUBNET
    ##############################################################

    if ($env.VNet -and $env.Subnet) {
        try {
            Set-AzContext -Subscription $env.Source.SubscriptionId
            $sourceVnet = Get-AzVirtualNetwork -Name $env.VNet -ResourceGroupName $env.Source.ResourceGroup
            $sourceSubnet = Get-AzVirtualNetworkSubnetConfig -Name $env.Subnet -VirtualNetwork $sourceVnet

            Set-AzContext -Subscription $env.Target.SubscriptionId
            $targetVnet = New-AzVirtualNetwork -Name $sourceVnet.Name `
                        -ResourceGroupName $env.Target.ResourceGroup `
                        -Location $sourceVnet.Location `
                        -AddressPrefix $sourceVnet.AddressSpace.AddressPrefixes[0]

            Add-AzVirtualNetworkSubnetConfig -Name $sourceSubnet.Name `
                -AddressPrefix $sourceSubnet.AddressPrefix `
                -VirtualNetwork $targetVnet

            $targetVnet | Set-AzVirtualNetwork

            Write-Host "VNet/Subnet copied successfully: $($sourceVnet.Name)/$($sourceSubnet.Name)"
        }
        catch {
            Write-Warning "Could not copy VNet/Subnet: $_"
        }
    }

    ##############################################################
    Write-Host "`nCopy completed for Key Vault: $($env.Target.KeyVaultName)"
    ##############################################################
}



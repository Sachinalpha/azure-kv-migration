# Load JSON configuration
$config = Get-Content -Raw -Path "./keyconfig.json" | ConvertFrom-Json

foreach ($env in $config) {

    Write-Host "`nSwitching to Source Subscription: $($env.Source.SubscriptionId)"
    Set-AzContext -Subscription $env.Source.SubscriptionId

    Write-Host "`nSwitching to Target Subscription: $($env.Target.SubscriptionId)"
    Set-AzContext -Subscription $env.Target.SubscriptionId
    $tenantId = (Get-AzContext).Tenant.Id

    # Prepare Key Vault parameters
    $kvParams = @{
        Name                = $env.Target.KeyVaultName
        ResourceGroupName   = $env.Target.ResourceGroup
        Location            = $env.Target.Location
        Sku                 = $env.Target.Sku
        EnableSoftDelete    = $true
        EnablePurgeProtection = $false
    }

    Write-Host "`nCreating target Key Vault: $($env.Target.KeyVaultName)"
    try {
        $targetVault = New-AzKeyVault @kvParams -ErrorAction Stop
    }
    catch {
        Write-Warning "Key Vault may already exist: $_"
        $targetVault = Get-AzKeyVault -VaultName $env.Target.KeyVaultName -ErrorAction Stop
    }

    # Merge tags
    $existingTags = $targetVault.Tags
    if (-not $existingTags) { $existingTags = @{} }
    $mergedTags = @{}
    foreach ($key in $existingTags.Keys) { $mergedTags[$key] = $existingTags[$key] }
    foreach ($key in $env.Tags.Keys) { $mergedTags[$key] = $env.Tags[$key] }

    # Apply merged tags
    Set-AzResource -ResourceId $targetVault.ResourceId -Tag $mergedTags -Force
    Write-Host "Tags applied to $($env.Target.KeyVaultName)"

    # Set access policies (example for your account)
    $currentObjectId = (Get-AzADUser -UserPrincipalName "sachin.madalagi@dxc.com").Id
    Set-AzKeyVaultAccessPolicy -VaultName $env.Target.KeyVaultName `
                               -ObjectId $currentObjectId `
                               -PermissionsToSecrets get,list,set `
                               -PermissionsToKeys get,list,create `
                               -PermissionsToCertificates get,list,import,delete

    # Copy Secrets
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

    # Copy Keys
    Write-Host "`nCopying Keys from $($env.Source.KeyVaultName) to $($env.Target.KeyVaultName)"
    try {
        $keys = Get-AzKeyVaultKey -VaultName $env.Source.KeyVaultName -ErrorAction Stop
        foreach ($k in $keys) {
            Write-Host "Key $($k.Name) exists. Manual copy may be required if not allowed by policy."
        }
    }
    catch {
        Write-Warning "Could not copy keys: $_"
    }

    # Copy Certificates
    Write-Host "`nCopying Certificates from $($env.Source.KeyVaultName) to $($env.Target.KeyVaultName)"
    try {
        $certs = Get-AzKeyVaultCertificate -VaultName $env.Source.KeyVaultName -ErrorAction Stop
        foreach ($c in $certs) {
            Write-Host "Certificate $($c.Name) exists. Manual copy may be required if not allowed by policy."
        }
    }
    catch {
        Write-Warning "Could not copy certificates: $_"
    }

    # Handle VNet/Subnet if defined
    if ($env.VNet -and $env.Subnet) {
        try {
            $vnet = Get-AzVirtualNetwork -Name $env.VNet -ResourceGroupName $env.Target.ResourceGroup
            $subnet = Get-AzVirtualNetworkSubnetConfig -Name $env.Subnet -VirtualNetwork $vnet
            Write-Host "VNet/Subnet found: $($env.VNet)/$($env.Subnet)"
        }
        catch {
            Write-Warning "VNet/Subnet not found: $_"
        }
    }
    else {
        Write-Warning "VNet/Subnet info missing in JSON."
    }

    Write-Host "`nCopy completed for Key Vault: $($env.Target.KeyVaultName)"
}

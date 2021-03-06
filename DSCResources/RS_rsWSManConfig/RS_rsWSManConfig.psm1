function Get-TargetResource
{
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][String]$Name,
        [Parameter(Mandatory)][String]$CertThumbprint,
        [Parameter(Mandatory)][String]$Username,
        [Parameter(Mandatory)][String]$Ensure
    )
    @{
        Name = $Name
        CertThumbprint = $CertThumbprint
        Username = $Username
        Ensure = $Ensure
    }
}

function Set-TargetResource
{
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][String]$Name,
        [Parameter(Mandatory)][String]$CertThumbprint,
        [Parameter(Mandatory)][String]$Username,
        [Parameter(Mandatory)][String]$Ensure
    )
    $cert = (Get-ChildItem Cert:\LocalMachine\My\ | ? Thumbprint -eq $CertThumbprint)
    if (!$cert)
    {
        Throw "No Cert Exists with the given Certificate Thumbprint"
    }
    if ( $cert.EnhancedKeyUsageList.FriendlyName -notcontains "Server Authentication" -and $cert.EnhancedKeyUsageList.FriendlyName -notcontains "Client Authentication")
    {
        Throw "Incorrect Cert: Needs Certificate with Server and Client Authentication"
    }
    $Listeners = (Get-ChildItem WSMan:\localhost\Listener | ? Keys -eq "Transport=HTTPS").Name
    foreach ( $listener in $Listeners )
    {
        if( (Get-ChildItem WSMan:\localhost\Listener\$listener | ? Name -eq "CertificateThumbprint").value -eq $cert.Thumbprint)
        {
            $currentListener = $listener
        }
    }
    if( !$currentListener -or ($Listeners.count -gt 0) )
    {
        $Listeners | % { Remove-Item WSMan:\localhost\Listener\$_ -Force -Recurse }
    }
    $clientCertificates = (Get-ChildItem WSMan:\localhost\ClientCertificate).Name
    foreach ( $clientCertificate in $clientCertificates )
    {
        if ( ((Get-ChildItem WSMan:\localhost\ClientCertificate\$clientCertificate).Value -contains $Username) -and ((Get-ChildItem WSMan:\localhost\ClientCertificate\$clientCertificate).Value -contains $CertThumbprint) ) 
        {
            $currentcert = $clientCertificate
        }
    }
    if( $Ensure -eq "Present" )
    {
        # Create a WinRM Listener for HTTPS bound to a SSL Cert
        if ( !$currentListener )
        {
            try{
                New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet @{Address="*";Transport="https"} -ValueSet @{Hostname=$($cert.Subject.Replace('CN=',''));CertificateThumbprint=$cert.Thumbprint}
            }
            catch
            {
                Throw $_.Exception.Message
            }
        }
        # Set WinRM Certificate Auth to $True
        Set-Item WSMan:\localhost\Service\Auth\Certificate -Value "true"
        # Creating a Certificate Admin user to bind to SSL Certificate
        Add-Type -Assembly System.Web 
        $randompassword = [Web.Security.Membership]::GeneratePassword(14,2)
        if( (gwmi Win32_UserAccount -Filter "LocalAccount='$True'").Name -notcontains $Username )
        {
            net user $Username /add $randompassword
            net localgroup administrators $Username /add
        }
        else
        {
            net user $Username $randompassword
        }
        $clientCerts = (Get-ChildItem WSMan:\localhost\ClientCertificate).Name
        foreach ( $clientcert in $clientCerts )
        {
            if ( (Get-ChildItem "WSMan:\localhost\ClientCertificate\$clientCert").value -contains $Username )
            {
                Remove-Item "WSMan:\localhost\ClientCertificate\$clientcert" -Force -Recurse
            }
        }
        $password = ConvertTo-SecureString $randompassword -AsPlainText –Force
        $adminuser = New-Object System.Management.Automation.PSCredential $Username,$password
        if( !$currentcert )
        {
            try {
                New-Item -Path WSMan:\localhost\ClientCertificate -URI * -Subject $($cert.Subject.Replace('CN=','')) -Issuer $cert.Thumbprint -Credential $adminuser -force
            }
            catch
            {
                Throw $_.Exception.Message
            }
        }
    }
    else # if $Ensure -eq 'Absent'
    {
        if( $currentListener )
        {
            Remove-Item WSMan:\localhost\Listener\$currentListener -Force -Recurse
        }
        if( $currentcert )
        {
            Remove-Item WSMan:\localhost\ClientCertificate\$currentcert -Force -Recurse
        }
        if( (gwmi Win32_UserAccount -Filter "LocalAccount='$True'").Name -contains $Username )
        {
            net user $Username /delete
        }
    }
}

function Test-TargetResource
{
    param (
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][String]$Name,
        [Parameter(Mandatory)][String]$CertThumbprint,
        [Parameter(Mandatory)][String]$Username,
        [Parameter(Mandatory)][String]$Ensure
    )
    $testresult = $true
    $cert = (Get-ChildItem Cert:\LocalMachine\My\ | ? Thumbprint -eq $CertThumbprint)
    if (!$cert)
    {
        Throw "No Cert Exists with the given Certificate Thumbprint"
    }
    if ( $cert.EnhancedKeyUsageList.FriendlyName -notcontains "Server Authentication" -and $cert.EnhancedKeyUsageList.FriendlyName -notcontains "Client Authentication")
    {
        Throw "Incorrect Cert: Needs Certificate with Server and Client Authentication"
    }
    $Listeners = (Get-ChildItem WSMan:\localhost\Listener | ? Keys -eq "Transport=HTTPS").Name
    foreach ( $listener in $Listeners )
    {
        if( (Get-ChildItem WSMan:\localhost\Listener\$listener | ? Name -eq "CertificateThumbprint").value -eq $cert.Thumbprint)
        {
            $currentListener = $listener
        }
    }
    if( !$currentListener )
    {
        $testresult = $false
    }
    $clientCertificates = (Get-ChildItem WSMan:\localhost\ClientCertificate).Name
    foreach ( $clientCertificate in $clientCertificates )
    {
        if ( ((Get-ChildItem WSMan:\localhost\ClientCertificate\$clientCertificate).Value -contains $Username) -and ((Get-ChildItem WSMan:\localhost\ClientCertificate\$clientCertificate).Value -contains $CertThumbprint) ) 
        {
            $currentcert = $clientCertificate
        }
    }
    if( $Ensure -eq "Present" )
    {
        if ( !$currentListener )
        {
            $testresult = $false
        }
        if( (gwmi Win32_UserAccount -Filter "LocalAccount='$True'").Name -notcontains $Username )
        {
            $testresult = $false
        }
        else
        {
            $LocalAccount = Get-WmiObject -class "Win32_UserAccount" -namespace "root\CIMV2" -filter "LocalAccount = True" | ? Name -eq $Username
            $user = [adsi]"WinNT://$env:COMPUTERNAME/$($LocalAccount.Name),user"
            $passexpiry = (Get-Date).AddSeconds($user.MaxPasswordAge.Value - $user.PasswordAge.Value)
            if( (Get-Date) -gt $passexpiry.AddHours(-12) )
            {
                $testresult = $false
            }
        }
        if( !$currentcert )
        {
            $testresult = $false
        }
    }
    else # if $Ensure -eq 'Absent'
    {
        if( $currentListener ){ $testresult = $false }
        if( $currentcert ) { $testresult = $false }
        if( (gwmi Win32_UserAccount -Filter "LocalAccount='$True'").Name -contains $Username ){ $testresult = $false }
    }
    return $testresult
}
Export-ModuleMember -Function *-TargetResource
function Build-Solution
{
    Write-Host "Building Relay projects"

    dotnet restore

    # $? Returns True or False value indicating whether previous command ended with an error.
    # This is used to throw an error that will cause the AppVeyor process to fail as expected.
    if (-not $?)
    {
        throw "Package restore failed."
    }

    dotnet build src/Microsoft.Azure.Relay/project.json

    if (-not $?)
    {
        throw "Microsoft.Azure.Relay build failed."
    }

    dotnet build test/Microsoft.Azure.Relay.UnitTests/project.json

    if (-not $?)
    {
        throw "Microsoft.Azure.Relay.UnitTests build failed."
    }
    else
    {
        Write-Host "Building complete."   
    }
}

function Deploy-AzureResources
{
    if ([bool]$env:ClientSecret `
        -and [bool]$env:TenantId `
        -and [bool]$env:AppId `
        -and [bool]$env:APPVEYOR_BUILD_NUMBER)
    {
        Write-Host "Creating Azure resources"

        $ErrorActionPreference = 'Stop'
        Enable-AzureDataCollection -WarningAction SilentlyContinue | Out-Null
        $BuildVersion = ($env:APPVEYOR_BUILD_NUMBER).Replace(".", "")
    
        $env:ResourceGroupName = "relay-dotnet-av-$BuildVersion-rg"
        $NamespaceName = "relay-dotnet-av-$BuildVersion-ns"
        $Location = 'westus'

        $Password = ConvertTo-SecureString -AsPlainText -Force $env:ClientSecret
        $Credentials = New-Object `
            -TypeName System.Management.Automation.PSCredential `
            -ArgumentList $env:AppId, $Password

        # https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-authenticate-service-principal
        Add-AzureRmAccount -Credential $Credentials -ServicePrincipal -TenantId $env:TenantId | Out-Null
 
        $ResourceGroup = New-AzureRmResourceGroup -Name $env:ResourceGroupName -Location $Location -Force -WarningAction SilentlyContinue
        Write-Host ("Resource group name: " + $ResourceGroup.ResourceGroupName)

        $ArmParameters = @{
            namespaceName = $NamespaceName;
        }

        $TemplatePath = "$((Get-Location).path)\templates\azuredeploy.json"
    
        $settings = New-AzureRmResourceGroupDeployment `
           -ResourceGroupName $env:ResourceGroupName `
           -TemplateFile $TemplatePath `
           -TemplateParameterObject $ArmParameters `
           -Force `
           -WarningAction SilentlyContinue

        Write-Host "Relay namespace: $NamespaceName"
        
        $ConnectionString = $settings.Outputs.Get_Item("namespaceConnectionString").Value
        [Environment]::SetEnvironmentVariable('azure-relay-dotnet/connectionstring', $ConnectionString)

        Write-Host "Completed creating Azure resources"
    }
    else
    {
        Write-Host "No environment variables present. Skipping Azure deployment."
    }

    # Useful for debugging ARM deployments
    # Get-AzureRmLog -CorrelationId "GUID" -DetailedOutput
}

function Run-UnitTests
{
    if ([bool][Environment]::GetEnvironmentVariable('azure-relay-dotnet/connectionstring'))
    {
        Write-Host "Running unit tests."

        Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile nuget.exe
        & .\nuget.exe install opencover -version 4.6.519
        $openCoverConsole = $ENV:APPVEYOR_BUILD_FOLDER + '\OpenCover.4.6.519\tools\OpenCover.Console.exe'
        $coverageFile = $ENV:APPVEYOR_BUILD_FOLDER + '\coverage.xml'
        $target = '-target:C:\Program Files\dotnet\dotnet.exe'
        $testProject = $ENV:APPVEYOR_BUILD_FOLDER + '\test\Microsoft.Azure.Relay.UnitTests\project.json'
        $targetArgs = '-targetargs: test ' + $testProject + ' -f netcoreapp1.0'
        $filter = '-filter:+[Microsoft.Azure.Relay*]* -[Microsoft.Azure.Relay.UnitTests]*'
        $output = '-output:' + $coverageFile

        & $openCoverConsole $target $targetArgs $filter $output '-register:user' '-oldStyle'

        if (-not $?)
        {
            throw "Unit tests failed."
        }

        $ENV:PATH = 'C:\\Python34;C:\\Python34\\Scripts;' + $ENV:PATH
        python -m pip install --upgrade pip
        pip install git+git://github.com/codecov/codecov-python.git
        codecov -f $coverageFile -t $ENV:CodeCov -X gcov

        & dotnet test $testProject -f net451
    }
    else
    {
        Write-Host "Connection string environment variable not present. Skipping unit tests."
    }
}

function Delete-AzureResources
{
    if ([bool]$env:ClientSecret -and [bool]$env:AppId)
    {
        Write-Host "Deleting Azure resources"

        $ErrorActionPreference = 'Stop'
    
        $Password = ConvertTo-SecureString -AsPlainText -Force $env:ClientSecret
        $Credentials = New-Object `
            -TypeName System.Management.Automation.PSCredential `
            -ArgumentList $env:AppId, $Password

        Remove-AzureRmResourceGroup -Name $env:ResourceGroupName -WarningAction SilentlyContinue -Force | Out-Null

        Write-Host "Completed deleting Azure resources"
    }
    else
    {
        Write-Host "No environment variables present. Skipping Azure resource deletion"
    }
}
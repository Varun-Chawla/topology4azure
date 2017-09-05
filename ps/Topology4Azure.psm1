Write-Verbose "Loading Neo4j .NET driver"
Add-Type -Path $('lib\net452\Neo4j.Driver.dll')

Function Connect-Topology4Azure
{
<#
    .SYNOPSIS

        connects to Azure account for making Azure PowerShell calls and creates 
        a .NET Bolt connection to a Neo4j database for Neo4j Cypher Queries.

        Required Dependencies: Neo4j.Driver.dll

    .DESCRIPTION

        Allows Powershell to get connect to Azure account and the specified NEO4j 
        database via the Neo4j .NET driver functions in PowerShell. 
      
    .PARAMETER Neo4jUser

        The User Name for the Neo4j connection.

    .PARAMETER Neo4jPassword

        The Password in string format for the Neo4j connection.

    .PARAMETER Neo4jServerAddress

        The URL and Port for the Neo4j connection using Bolt protocol.

    .EXAMPLE

        Connect-Topology4Azure -SusbscriptionId 6242edd8-f42d-4f0e-90c4-bdc354762708 -Neo4jUser neo4j -Neo4jPassword Password -Neo4jServerAddress bolt://127.0.0.1:7687

#>
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [String]
        $SusbscriptionId,

        [Parameter(Position = 1, Mandatory = $True)]
        [String]
        $Neo4jUser,

        [Parameter(Position = 2, Mandatory = $True)]
        [String]
        $Neo4jPassword,

        [Parameter(Position = 3, Mandatory = $True)]
        [String]
        $Neo4jServerAddress
    )
    
    try
    {
        Write-Output "Connecting to Azure subscription: $SusbscriptionId"
        Select-AzureRmSubscription -SubscriptionId $SusbscriptionId -ErrorAction Stop
    }
    catch
    {
        if ($_ -like '*Login-AzureRmAccount to login*')
        {
            Login-AzureRmAccount -ErrorAction Stop
            Select-AzureRmSubscription -SubscriptionId $subscription -ErrorAction Stop
        }
        else
        {
            throw
        }
    }

    Write-Output "Connecting to Neo4j server: $Neo4jServerAddress"

    Write-Verbose "Creating Auth Token for: $Neo4jUser"
    $authToken = [Neo4j.Driver.V1.AuthTokens]::Basic($Neo4jUser, $Neo4jPassword)

    Write-Verbose "Creating .NET Graph Database Driver."
    $Script:Neo4jDriver = [Neo4j.Driver.V1.GraphDatabase]::Driver($Neo4jServerAddress, $authToken)

    Write-Output "Connected!"
}


Function Add-Topology4ResourceGroup
{
<#
    .SYNOPSIS

        Import Azure Network Watcher topology for a resource group.

    .DESCRIPTION

        Imports the Azure Network Watcher topology for the specified resource group.
      
    .PARAMETER NetworkWatcherLocation

        Azure region for the network watcher resource which needs to be used to get the topology.
      
    .PARAMETER ResourceGroupName

        The name of the resource group for which the topology needs to be imported.

    .EXAMPLE

#>
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [String]
        $NetworkWatcherLocation,

        [Parameter(Position = 1, Mandatory = $True)]
        [String]
        $ResourceGroupName
    )

    if ($Script:Neo4jDriver -eq $null)
    {
        throw "Use Connect-Topology4Azure to connect to Azure and Neo4j"
    }
    
    Write-Output "Getting Network Watcher for location: $NetworkWatcherLocation"
    $networkWatcher = Get-AzureRmNetworkWatcher | where Location -eq $NetworkWatcherLocation
    if ($networkWatcher -eq $null)
    {
        throw "Network Watcher not found in location: $NetworkWatcherLocation"
    }

    Write-Output "Getting topology for resource group: $ResourceGroupName"
    $topology =
        Get-AzureRmNetworkWatcherTopology `
            -NetworkWatcher $networkWatcher `
            -TargetResourceGroupName $ResourceGroupName `
            -ErrorAction Stop

    Write-Output "Adding nodes to Neo4j Graph Database"
    foreach ($resource in $topology.Resources)
    {
        $match = $resource.Id -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/(?<provider>.*)/(?<resourceType>.*)/(?<resourceName>.*)"
    
        $query = "MERGE (:$($Matches['resourceType']) { Name: '$($resource.Name)', Id: '$($resource.Id)' })"
        
        $session = $Script:Neo4jDriver.Session()
        $result = $session.Run($query)
    }
    
    Write-Output "Adding relatinships to Neo4j Graph Database"
    foreach ($resource in $topology.Resources)
    {
        $match = $resource.Id -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/(?<provider>.*)/(?<resourceType>.*)/(?<resourceName>.*)"
        $resourceType = $Matches['resourceType']

        foreach ($association in $resource.Associations)
        {
            $match = $association.ResourceId -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/(?<provider>.*)/(?<resourceType>.*)/(?<resourceName>.*)"

            $query = "MATCH (src:$resourceType { Id: '$($resource.Id)' }), (dst: $($Matches['resourceType']) { Id: '$($association.ResourceId)' }) MERGE (src)-[:$($association.AssociationType)]->(dst)"
            
            $session = $Script:Neo4jDriver.Session()
            $result = $session.Run($query)
        }
    }
}


Function Add-Topology4ConnectivityCheck
{
<#
    .SYNOPSIS

        Import Azure Network Watcher topology for a connectivity check api result.

    .DESCRIPTION

        Imports the Azure Network Watcher topology for the specified connectivity
        check result json.
      
    .PARAMETER ConnectivityCheckJson

        Json string which represets the output of the connectivity check api.

    .EXAMPLE

#>
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [String]
        $ConnectivityCheckJson
    )

    if ($Script:Neo4jDriver -eq $null)
    {
        throw "Use Connect-Topology4Azure to connect to Azure and Neo4j"
    }

    $conn = ConvertFrom-Json $ConnectivityCheckJson
    $hops = @{}
    
    Write-Output "Adding nodes to Neo4j Graph Database"
    foreach ($hop in $conn.hops)
    {
        if ($hop.resourceId -eq 'Internet')
        {
            $resourceType = $hop.resourceId
            $resourceName = $hop.resourceId
            $resourceId = $hop.resourceId
            $hops[$hop.Id] = $resourceId
        }
        elseif ($hop.resourceId -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/Microsoft.Network/networkInterfaces/(?<nicName>.*)/ipConfigurations/.*" -eq $true)
        {
            $resourceType = 'networkInterfaces'
            $resourceName = $($Matches['nicName'])
            $resourceId = "/subscriptions/$($Matches['subscription'])/resourceGroups/$($Matches['resourceGroup'])/providers/Microsoft.Network/networkInterfaces/$($Matches['nicName'])"
            $hops[$hop.Id] = $resourceId
        }
        elseif ($hop.resourceId -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/Microsoft.Network/virtualNetworkGateways/(?<gwName>.*)" -eq $true)
        {
            $resourceType = 'virtualNetworkGateways'
            $resourceName = $($Matches['gwName'])
            $resourceId = "/subscriptions/$($Matches['subscription'])/resourceGroups/$($Matches['resourceGroup'])/providers/Microsoft.Network/virtualNetworkGateways/$($Matches['gwName'])"
            $hops[$hop.Id] = $resourceId
        }
        else
        {
            throw "Unrecognized resource identifier for hop: $($hop.resourceId)"
        }
    
        $query = "MERGE (:$resourceType { Name: '$resourceName', Id: '$resourceId' })"

        $session = $Script:Neo4jDriver.Session()
        $result = $session.Run($query)
    }
    
    Write-Output "Adding relationships to Neo4j Graph Database"
    foreach ($hop in $conn.hops)
    {
        if ($hop.resourceId -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/Microsoft.Network/networkInterfaces/(?<nicName>.*)/ipConfigurations/.*" -eq $true)
        {
            $srcResourceType = 'networkInterfaces'
        }
        elseif ($hop.resourceId -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/Microsoft.Network/virtualNetworkGateways/.*" -eq $true)
        {
            $srcResourceType = 'virtualNetworkGateways'
        }
        else
        {
            continue
        }

        foreach ($nextHop in $hop.nextHopIds)
        {
            if ($hops[$nextHop] -eq 'Internet')
            {
                $dstResourceType = 'Internet'
            }
            elseif ($hops[$nextHop] -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/Microsoft.Network/networkInterfaces/.*" -eq $true)
            {
                $dstResourceType = 'networkInterfaces'
            }
            elseif ($hops[$nextHop] -match "/subscriptions/(?<subscription>.*)/resourceGroups/(?<resourceGroup>.*)/providers/Microsoft.Network/virtualNetworkGateways/.*" -eq $true)
            {
                $dstResourceType = 'virtualNetworkGateways'
            }
            else
            {
                throw "Unrecognized resource identifier for destination hop $($hops[$nextHop])"
            }

            $query = "MATCH (src:$srcResourceType { Id: '$($hops[$hop.Id])' }), (dst:$dstResourceType { Id: '$($hops[$nextHop])' }) MERGE (src)-[:ConnectedTo]->(dst)"

            $session = $Script:Neo4jDriver.Session()
            $result = $session.Run($query)
        }
    }
}

Export-ModuleMember Connect-Topology4Azure
Export-ModuleMember Add-Topology4ResourceGroup
Export-ModuleMember Add-Topology4ConnectivityCheck
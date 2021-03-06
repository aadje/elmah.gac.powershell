<# Usage:
Add-AssemblyToGac
Invoke-Sql -ServerInstance '.\sqlserver2012' -Database 'sharepointauthentication' -Script .\Elmah.SqlServer.sql
Set-ElmahSprocPermission -ServerInstance '.\sqlserver2012' -Database 'sharepointauthentication' -User 'NT AUTHORITY\IUSR'
Update-ConfigWithElmah -Roles 'Beheerder,employee' -ConnectionStringName 'sharepointauthentication' -Path C:\inetpub\wwwroot\wss\VirtualDirectories\18982\web.config
#>

function Add-AssemblyToGac{
	param(
		[Parameter(Mandatory=$false, Position=0, ValueFromPipeline=$true)]
		[String]
		$Path = '.\Elmah.dll' 
    )

    if ( $null -eq ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.FullName -eq "System.EnterpriseServices, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a" }) ) {
        [System.Reflection.Assembly]::Load("System.EnterpriseServices, Version=2.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a") | Out-Null
    }
    
    $publish = New-Object System.EnterpriseServices.Internal.Publish
    
    if ( -not (Test-Path $Path -type Leaf) ) {throw "The assembly '$Path' does not exist."}
    
    $fullPath = Convert-Path (Resolve-Path $Path)

    if ( [System.Reflection.Assembly]::LoadFile($fullPath).GetName().GetPublicKey().Length -eq 0 ) {
        throw "The assembly '$assembly' must be strongly signed."
    }
    Write-Output "Installing: $fullPath"
    $publish.GacInstall($fullPath)
}

function Update-ConfigWithElmah{
	param(
		[String] $Path = '.\web.config',
		[String] $Roles = 'admin',
		[String] $ConnectionStringName,
        [String] $StrongName = 'Elmah, Version=1.2.14706.0, Culture=neutral, PublicKeyToken=6aeba1615bd48855'
    )
   
    $xml = [xml](Get-Content $Path)
    $xml.Save("$(Resolve-Path $Path)_$([DateTime]::Now.ToString("yyyyMMdd-HHmm")).bak")
   
    $sectionGroup = $xml.CreateElement("sectionGroup")
    $sectionGroup.SetAttribute('name', 'elmah')
    $sectionGroup.InnerXML = 
@"
         
        <section name="security" requirePermission="false" type="Elmah.SecuritySectionHandler, $StrongName" />
        <section name="errorLog" requirePermission="false" type="Elmah.ErrorLogSectionHandler, $StrongName" />
        <section name="errorMail" requirePermission="false" type="Elmah.ErrorMailSectionHandler, $StrongName" />
        <section name="errorFilter" requirePermission="false" type="Elmah.ErrorFilterSectionHandler, $StrongName" />
    
"@
    $xml.Configuration.ConfigSections.AppendChild($sectionGroup) | Out-Null

    if($xml.Configuration.'system.webServer'.validation -ne $null){
        $xml.Configuration.'system.webServer'.validation.validateIntegratedModeConfiguration = 'false'
    } else{
        $validation = $xml.CreateElement("validation")
        $validation.SetAttribute('validateIntegratedModeConfiguration', 'false')
        $xml.Configuration.'system.webServer'.AppendChild($validation) | Out-Null
    }

    $ErrorLog = $xml.CreateElement("add")
    $ErrorLog.SetAttribute('name', 'ErrorLog')
    $ErrorLog.SetAttribute('type', "Elmah.ErrorLogModule, $StrongName")    
    $ErrorLog.SetAttribute('preCondition', 'managedHandler')    
    $xml.Configuration.'system.webServer'.modules.InsertBefore($ErrorLog, $xml.Configuration.'system.webServer'.modules.FirstChild) | Out-Null

    $ErrorMail = $xml.CreateElement("add")
    $ErrorMail.SetAttribute('name', 'ErrorMail')
    $ErrorMail.SetAttribute('type', "Elmah.ErrorMailModule, $StrongName")    
    $ErrorMail.SetAttribute('preCondition', 'managedHandler')    
    $xml.Configuration.'system.webServer'.modules.InsertBefore($ErrorMail, $xml.Configuration.'system.webServer'.modules.FirstChild) | Out-Null

    $ErrorFilter = $xml.CreateElement("add")
    $ErrorFilter.SetAttribute('name', 'ErrorFilter')
    $ErrorFilter.SetAttribute('type', "Elmah.ErrorFilterModule, $StrongName")    
    $ErrorFilter.SetAttribute('preCondition', 'managedHandler')    
    $xml.Configuration.'system.webServer'.modules.InsertBefore($ErrorFilter, $xml.Configuration.'system.webServer'.modules.FirstChild) | Out-Null
    
    $handler = $xml.CreateElement("add")
    $handler.SetAttribute('name', 'Elmah')
    $handler.SetAttribute('path', 'elmah.axd')
    $handler.SetAttribute('verb', 'POST,GET,HEAD')
    $handler.SetAttribute('type', "Elmah.ErrorLogPageFactory, $StrongName")    
    $handler.SetAttribute('preCondition', 'managedHandler')    
    $xml.Configuration.'system.webServer'.handlers.InsertBefore($handler, $xml.Configuration.'system.webServer'.handlers.FirstChild) | Out-Null

    if($ConnectionStringName){
        $SqlErrorLog = $xml.CreateElement("errorLog")
        $SqlErrorLog.SetAttribute('type', "Elmah.SqlErrorLog, $StrongName")
        $SqlErrorLog.SetAttribute('connectionStringName', $ConnectionStringName)
    }else{
        $SqlErrorLog = [string] "<!-- <errorLog type=`"Elmah.SqlErrorLog, $StrongName`" connectionStringName=`"`" /> -->"
    }

    $elmah = $xml.CreateElement("elmah")
    $elmah.InnerXML = @"

        <security allowRemoteAccess="yes" />
        $($SqlErrorLog.OuterXml)
    <!--    <errorMail from="elmah@montfoort-it.nl" 
            subject="Server error in web application" 
            to="support@montfoort-it.nl" 
            smtpServer="test.gemserver.nl" async="true" /> -->

"@
    $xml.Configuration.InsertBefore($elmah, $xml.Configuration.'system.web') | Out-Null

    $security = $xml.CreateElement("location")
    $security.SetAttribute('path', 'elmah.axd') 
    $security.InnerXML = @"
    
        <system.web>
          <authorization>
            <allow roles="$Roles" />
            <deny users="*" />
          </authorization>
        </system.web>

"@
    $xml.Configuration.InsertAfter($security, $xml.Configuration.'system.web') | Out-Null

    $xml.Save((Resolve-Path $Path))
}

function Set-ElmahSprocPermission{
	param(
        [Parameter(Position=0, Mandatory=$false)] [String] $ServerInstance = '.',
        [Parameter(Position=1, Mandatory=$true)]  [String] $Database,
		[Parameter(Position=2, Mandatory=$false)] [String] $User = 'NT AUTHORITY\NETWORK SERVICE'
    )
    
    $query = 
@"
    use [$Database]
    GRANT EXECUTE ON [dbo].[ELMAH_GetErrorsXml] TO [$User]
    GRANT EXECUTE ON [dbo].[ELMAH_GetErrorXml] TO [$User]
    GRANT EXECUTE ON [dbo].[ELMAH_LogError] TO [$User]
"@
    Invoke-Sql -ServerInstance $ServerInstance -Database $Database -Script $query -Verbose 
}

function Invoke-Sql {
[CmdletBinding()]
Param(
    [Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, Mandatory=$true, Position=0)]    
    [String]$Script,
	[String]$ServerInstance = ".",
    [String]$Database = "SharepointAuthentication"
)
	if ($Script.EndsWith(".sql")){
		$Sql = [IO.File]::ReadAllText((Resolve-Path $Script))
	} else {
		$Sql = $Script
	}

	$connection = New-object System.Data.SqlClient.SqlConnection("Data Source=$ServerInstance;Initial Catalog=$Database;Integrated Security=True" )
	$connection.Open() | Out-Null	
	$connection.Add_InfoMessage([System.Data.SqlClient.SqlInfoMessageEventHandler]{
		Write-Host $_
	})

	$Sql -split "(?m)^GO" | %{    
        if (-not [String]::IsNullOrEmpty($_)) { 
    		$cmd = $connection.CreateCommand()
    		$cmd.CommandTimeout = 30
    		$cmd.CommandText = $_
    		$cmd.ExecuteNonQuery() | Out-Null
    		$cmd.Dispose()
        }
	}
	$connection.Dispose()
}
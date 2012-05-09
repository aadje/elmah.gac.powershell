<# Usage:
Add-AssemblyToGac
Update-ConfigWithElmah -Roles 'administrator,employee' -ConnectionStringName 'sharepointauthentication'
Invoke-Sqlcmd2 -ServerInstance '.\Sqlserver2012' -Database 'Mydatabase'
Set-ElmahSprocPermission -ServerInstance '.\Sqlserver2012' -Database 'Mydatabase' -User 'NT AUTHORITY\NETWORK SERVICE'
#>

Invoke-Sqlcmd2 -ServerInstance '.\Sqlserver2012' -Database 'Umbraco1' -InputFile (Resolve-Path .\Elmah.SqlServer.sql) -Verbose 

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
		[String] $ConnectionStringName
    )
   
    $xml = [xml](Get-Content $Path)
    $xml.Save("$(Resolve-Path $Path)_$([DateTime]::Now.ToString("yyyyMMdd-HHmm")).bak")
   
    $sectionGroup = $xml.CreateElement("sectionGroup")
    $sectionGroup.SetAttribute('name', 'elmah')
    $sectionGroup.InnerXML = 
@"
          
        <section name="security" requirePermission="false" type="Elmah.SecuritySectionHandler, Elmah" />
        <section name="errorLog" requirePermission="false" type="Elmah.ErrorLogSectionHandler, Elmah" />
        <section name="errorMail" requirePermission="false" type="Elmah.ErrorMailSectionHandler, Elmah" />
        <section name="errorFilter" requirePermission="false" type="Elmah.ErrorFilterSectionHandler, Elmah" />
    
"@
    $xml.Configuration.ConfigSections.AppendChild($sectionGroup) | Out-Null

    $ErrorLog = $xml.CreateElement("add")
    $ErrorLog.SetAttribute('name', 'ErrorLog')
    $ErrorLog.SetAttribute('type', 'Elmah.ErrorLogModule, Elmah')    
    $ErrorLog.SetAttribute('preCondition', 'managedHandler')    
    $xml.Configuration.'system.webServer'.modules.InsertBefore($ErrorLog, $xml.Configuration.'system.webServer'.modules.FirstChild) | Out-Null

    $ErrorMail = $xml.CreateElement("add")
    $ErrorMail.SetAttribute('name', 'ErrorMail')
    $ErrorMail.SetAttribute('type', 'Elmah.ErrorMailModule, Elmah')    
    $ErrorMail.SetAttribute('preCondition', 'managedHandler')    
    $xml.Configuration.'system.webServer'.modules.InsertBefore($ErrorMail, $xml.Configuration.'system.webServer'.modules.FirstChild) | Out-Null

    $ErrorFilter = $xml.CreateElement("add")
    $ErrorFilter.SetAttribute('name', 'ErrorFilter')
    $ErrorFilter.SetAttribute('type', 'Elmah.ErrorFilterModule, Elmah')    
    $ErrorFilter.SetAttribute('preCondition', 'managedHandler')    
    $xml.Configuration.'system.webServer'.modules.InsertBefore($ErrorFilter, $xml.Configuration.'system.webServer'.modules.FirstChild) | Out-Null
    
    $handler = $xml.CreateElement("add")
    $handler.SetAttribute('name', 'Elmah')
    $handler.SetAttribute('path', 'elmah.axd')
    $handler.SetAttribute('verb', 'POST,GET,HEAD')
    $handler.SetAttribute('type', 'Elmah.ErrorLogPageFactory, Elmah')    
    $handler.SetAttribute('preCondition', 'managedHandler')    
    $xml.Configuration.'system.webServer'.handlers.InsertBefore($handler, $xml.Configuration.'system.webServer'.handlers.FirstChild) | Out-Null

    if($ConnectionStringName){
        $SqlErrorLog = $xml.CreateElement("errorLog")
        $SqlErrorLog.SetAttribute('type', 'Elmah.SqlErrorLog, Elmah')
        $SqlErrorLog.SetAttribute('connectionStringName', $ConnectionStringName)
    }else{
        $SqlErrorLog = [string] "<!-- <errorLog type=`"Elmah.SqlErrorLog, Elmah`" connectionStringName=`"`" /> -->"
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
    Invoke-Sqlcmd2 -ServerInstance $ServerInstance -Query $query -Verbose 
}


<# 
.SYNOPSIS 
Runs a T-SQL script. 
.DESCRIPTION 
Runs a T-SQL script. Invoke-Sqlcmd2 only returns message output, such as the output of PRINT statements when -verbose parameter is specified 
.INPUTS 
None 
    You cannot pipe objects to Invoke-Sqlcmd2 
.OUTPUTS 
   System.Data.DataTable 
.EXAMPLE 
Invoke-Sqlcmd2 -ServerInstance "MyComputer\MyInstance" -Query "SELECT login_time AS 'StartTime' FROM sysprocesses WHERE spid = 1" 
This example connects to a named instance of the Database Engine on a computer and runs a basic T-SQL query. 
StartTime 
----------- 
2010-08-12 21:21:03.593 
.EXAMPLE 
Invoke-Sqlcmd2 -ServerInstance "MyComputer\MyInstance" -InputFile "C:\MyFolder\tsqlscript.sql" | Out-File -filePath "C:\MyFolder\tsqlscript.rpt" 
This example reads a file containing T-SQL statements, runs the file, and writes the output to another file. 
.EXAMPLE 
Invoke-Sqlcmd2  -ServerInstance "MyComputer\MyInstance" -Query "PRINT 'hello world'" -Verbose 
This example uses the PowerShell -Verbose parameter to return the message output of the PRINT command. 
VERBOSE: hello world 
.NOTES 
Version History 
v1.0   - Chad Miller - Initial release 
v1.1   - Chad Miller - Fixed Issue with connection closing 
v1.2   - Chad Miller - Added inputfile, SQL auth support, connectiontimeout and output message handling. Updated help documentation 
v1.3   - Chad Miller - Added As parameter to control DataSet, DataTable or array of DataRow Output type 
#> 
function Invoke-Sqlcmd2 
{ 
    [CmdletBinding()] 
    param( 
    [Parameter(Position=0, Mandatory=$true)] [string]$ServerInstance, 
    [Parameter(Position=1, Mandatory=$false)] [string]$Database, 
    [Parameter(Position=2, Mandatory=$false)] [string]$Query, 
    [Parameter(Position=3, Mandatory=$false)] [string]$Username, 
    [Parameter(Position=4, Mandatory=$false)] [string]$Password, 
    [Parameter(Position=5, Mandatory=$false)] [Int32]$QueryTimeout=600, 
    [Parameter(Position=6, Mandatory=$false)] [Int32]$ConnectionTimeout=15, 
    [Parameter(Position=7, Mandatory=$false)] [ValidateScript({test-path $_})] [string]$InputFile, 
    [Parameter(Position=8, Mandatory=$false)] [ValidateSet("DataSet", "DataTable", "DataRow")] [string]$As="DataRow" 
    ) 
 
    if ($InputFile) 
    { 
        $filePath = $(resolve-path $InputFile).path 
        $Query =  [System.IO.File]::ReadAllText("$filePath") 
    } 
 
    $conn=new-object System.Data.SqlClient.SQLConnection 
      
    if ($Username) 
    { $ConnectionString = "Server={0};Database={1};User ID={2};Password={3};Trusted_Connection=False;Connect Timeout={4}" -f $ServerInstance,$Database,$Username,$Password,$ConnectionTimeout } 
    else 
    { $ConnectionString = "Server={0};Database={1};Integrated Security=True;Connect Timeout={2}" -f $ServerInstance,$Database,$ConnectionTimeout } 
 
    $conn.ConnectionString=$ConnectionString 
     
    #Following EventHandler is used for PRINT and RAISERROR T-SQL statements. Executed when -Verbose parameter specified by caller 
    if ($PSBoundParameters.Verbose) 
    { 
        $conn.FireInfoMessageEventOnUserErrors=$true 
        $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {Write-Verbose "$($_)"} 
        $conn.add_InfoMessage($handler) 
    } 
     
    $conn.Open() 
    $cmd=new-object system.Data.SqlClient.SqlCommand($Query,$conn) 
    $cmd.CommandTimeout=$QueryTimeout 
    $ds=New-Object system.Data.DataSet 
    $da=New-Object system.Data.SqlClient.SqlDataAdapter($cmd) 
    [void]$da.fill($ds) 
    $conn.Close() 
    switch ($As) 
    { 
        'DataSet'   { Write-Output ($ds) } 
        'DataTable' { Write-Output ($ds.Tables) } 
        'DataRow'   { Write-Output ($ds.Tables[0]) } 
    } 
 
} #Invoke-Sqlcmd2


Set-Alias -Name elmah -Value Update-ConfigWithElmah

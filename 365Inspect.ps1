<#
  .SYNOPSIS
  Performs Office 365 security assessment.

  .DESCRIPTION
  Automate the security assessment of Microsoft Office 365 environments.

  .PARAMETER OrgName
  The name of the core organization or "company" of your O365 instance, which will be inspected.

  .PARAMETER OutPath
  The path to a folder where the report generated by 365Inspect will be placed.

  .PARAMETER Auth
  Switch that should be one of the literal values "MFA", "CMDLINE", or "ALREADY_AUTHED".

  .PARAMETER Username
  Username of O365 account.

  .PARAMETER Password
  Password of O365 account.

  .INPUTS
  None. You cannot pipe objects to 365Inspect.ps1.

  .OUTPUTS
  None. 365Inspect.ps1 does not generate any output.

  .EXAMPLE
  PS> .\365Inspect.ps1
#>


param (
	[Parameter(Mandatory = $true,
		HelpMessage = 'Organization name')]
	[string] $OrgName,
	[Parameter(Mandatory = $true,
		HelpMessage = 'Output path for report')]
	[string] $OutPath,
	[Parameter(Mandatory = $true,
		HelpMessage = 'Auth type')]
	[ValidateSet('ALREADY_AUTHED', 'CMDLINE', 'MFA',
		IgnoreCase = $false)]
	[string] $Auth,
	$Username,
	$Password,
	[string[]] $SelectedInspectors = @()
)

$org_name = $OrgName
$out_path = $OutPath
$selected_inspectors = $SelectedInspectors


Function Connect-Services{
    # Log into every service prior to the analysis.
    If ($auth -EQ "MFA") {
        Connect-MsolService
        Connect-AzureAD
        Connect-ExchangeOnline -ShowBanner:$false
        Connect-SPOService -Url "https://$org_name-admin.sharepoint.com"
	Connect-MgGraph -Scopes "AuditLog.Read.All","Policy.Read.All","Directory.Read.All","IdentityProvider.Read.All","Organization.Read.All","Securityevents.Read.All","ThreatIndicators.Read.All","SecurityActions.Read.All","User.Read.All","UserAuthenticationMethod.Read.All","MailboxSettings.Read"
    }

    If ($auth -EQ "CMDLINE") {
        If ($null -eq $password) {
            Write-Output "Please pass the username parameter if using the CMDLINE auth option."
            return
        }
        
        If ($null -eq $username) {
            Write-Output "Please pass the password parameter if using the CMDLINE auth option."
            return
        }
        
        $password = ConvertTo-SecureString -String $password -AsPlainText -Force
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $username, $password
        
        Connect-MsolService -Credential $credential
        Connect-AzureAD -Credential $credential | Out-Null
        Connect-ExchangeOnline -Credential $credential -ShowBanner:$false
        Connect-SPOService -Url "https://$org_name-admin.sharepoint.com" -Credential $credential
    }
}

Function Colorize($ForeGroundColor){
    $color = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.ForegroundColor = $ForeGroundColor
  
    if ($args){
      Write-Output $args
    }
  
    $Host.UI.RawUI.ForegroundColor = $color
  }

#Function to chnage color of text on errors for specific messages
Function Confirm-Close{
    Read-Host "Press Enter to Exit"
    Exit
}

Function Confirm-InstalledModules{
    #Check for required Modules and prompt for install if missing
    $modules = @("MSOnline","AzureAD","AzureADPreview","ExchangeOnlineManagement","Microsoft.Online.Sharepoint.PowerShell","Microsoft.Graph")
    $count = 0
    $installed = Get-InstalledModule | Select-Object Name

    foreach ($module in $modules){
        if ($installed.Name -notcontains $module){
            $message = Write-Output "`n$module is not installed."
            $message1 = Write-Output "The module may be installed by running 'Install-Module $module -Force -Scope CurrentUser -Confirm:$false' in an elevated PowerShell window."
            Colorize Red ($message)
            Colorize Yellow ($message1)
            $install = Read-Host -Prompt "Would you like to attempt installation now? (Y|N)"
            If ($install -eq 'y') {
                Install-Module $module -Scope CurrentUser -Force -Confirm:$false
                $count ++
            }
        }
        Else {
            Write-Output "$module is installed."
            $count ++
        }
    }

    If ($count -lt 5){
        Write-Output ""
        Write-Output ""
        $message = Write-Output "Dependency checks failed. Please install all missing modules before running this script."
        Colorize Red ($message)
        Confirm-Close
    }
    Else {
        Connect-Services
    }

}


#Start Script
Confirm-InstalledModules


# Get a list of every available detection module by parsing the PowerShell
# scripts present in the .\inspectors folder. 
$inspectors = (Get-ChildItem .\inspectors\ | Where-Object -FilterScript { $_.Name -Match ".ps1" }).Name | ForEach-Object { ($_ -split ".ps1")[0] }

If ($selected_inspectors -AND $selected_inspectors.Count) {
	"The following O365 inspectors were selected for use: $selected_inspectors"
}
Else {
	"Using all O365 inspectors."
	$selected_inspectors = $inspectors
}

New-Item -ItemType Directory -Force -Path $out_path | Out-Null

# Maintain a list of all findings, beginning with an empty list.
$findings = @()

# For every inspector the user wanted to run...
ForEach ($selected_inspector in $selected_inspectors) {
	# ...if the user selected a valid inspector...
	If ($inspectors.Contains($selected_inspector)) {
		Write-Output "Invoking Inspector: $selected_inspector"
		
		# Get the static data (finding description, remediation etc.) associated with that inspector module.
		$finding = Get-Content .\inspectors\$selected_inspector.json | Out-String | ConvertFrom-Json
		
		# Invoke the actual inspector module and store the resulting list of insecure objects.
		$finding.AffectedObjects = Invoke-Expression ".\inspectors\$selected_inspector.ps1"
		
		# Add the finding to the list of all findings.
		$findings += $finding
	}
}

# Function that retrieves templating information from 
function Parse-Template {
	$template = (Get-Content ".\365InspectDefaultTemplate.html") -join "`n"
	$template -match '\<!--BEGIN_FINDING_LONG_REPEATER-->([\s\S]*)\<!--END_FINDING_LONG_REPEATER-->'
	$findings_long_template = $matches[1]
	
	$template -match '\<!--BEGIN_FINDING_SHORT_REPEATER-->([\s\S]*)\<!--END_FINDING_SHORT_REPEATER-->'
	$findings_short_template = $matches[1]
	
	$template -match '\<!--BEGIN_AFFECTED_OBJECTS_REPEATER-->([\s\S]*)\<!--END_AFFECTED_OBJECTS_REPEATER-->'
	$affected_objects_template = $matches[1]
	
	$template -match '\<!--BEGIN_REFERENCES_REPEATER-->([\s\S]*)\<!--END_REFERENCES_REPEATER-->'
	$references_template = $matches[1]
	
	$template -match '\<!--BEGIN_EXECSUM_TEMPLATE-->([\s\S]*)\<!--END_EXECSUM_TEMPLATE-->'
	$execsum_template = $matches[1]
	
	return @{
		FindingShortTemplate    = $findings_short_template;
		FindingLongTemplate     = $findings_long_template;
		AffectedObjectsTemplate = $affected_objects_template;
		ReportTemplate          = $template;
		ReferencesTemplate      = $references_template;
		ExecsumTemplate         = $execsum_template
	}
}

$templates = Parse-Template

# Maintain a running list of each finding, represented as HTML
$short_findings_html = '' 
$long_findings_html = ''

$findings_count = 0

$sortedFindings = $findings | Sort-Object {Switch -Regex ($_.Severity){'Critical' {1}	'High' {2}	'Medium' {3}	'Low' {4}	'Informational' {5}}}

ForEach ($finding in $sortedFindings) {
	# If the result from the inspector was not $null,
	# it identified a real finding that we must process.
	If ($null -NE $finding.AffectedObjects) {
		# Increment total count of findings
		$findings_count += 1
		
		# Keep an HTML variable representing the current finding as HTML
		$short_finding_html = $templates.FindingShortTemplate
		$long_finding_html = $templates.FindingLongTemplate
		
		# Insert finding name and number into template HTML
		$short_finding_html = $short_finding_html.Replace("{{FINDING_NAME}}", $finding.FindingName)
		$short_finding_html = $short_finding_html.Replace("{{FINDING_NUMBER}}", $findings_count.ToString())
		$long_finding_html = $long_finding_html.Replace("{{FINDING_NAME}}", $finding.FindingName)
		$long_finding_html = $long_finding_html.Replace("{{FINDING_NUMBER}}", $findings_count.ToString())
		
		# Finding Severity
		$long_finding_html = $long_finding_html.Replace("{{SEVERITY}}", $finding.Severity)
		
		# Finding description
		$long_finding_html = $long_finding_html.Replace("{{DESCRIPTION}}", $finding.Description)
		
		# Finding Remediation
		If ($finding.Remediation.length -GT 300) {
			$short_finding_text = "Complete remediation advice is provided in the body of the report. Clicking the link to the left will take you there."
		}
		Else {
			$short_finding_text = $finding.Remediation
		}
		
		$short_finding_html = $short_finding_html.Replace("{{REMEDIATION}}", $short_finding_text)
		$long_finding_html = $long_finding_html.Replace("{{REMEDIATION}}", $finding.Remediation)
		
		# Affected Objects
		If ($finding.AffectedObjects.Count -GT 15) {
			$condensed = "<a href='{name}'>{count} Affected Objects Identified<a/>."
			$condensed = $condensed.Replace("{count}", $finding.AffectedObjects.Count.ToString())
			$condensed = $condensed.Replace("{name}", $finding.FindingName)
			$affected_object_html = $templates.AffectedObjectsTemplate.Replace("{{AFFECTED_OBJECT}}", $condensed)
			$fname = $finding.FindingName
			$finding.AffectedObjects | Out-File -FilePath $out_path\$fname
		}
		Else {
			$affected_object_html = ''
			ForEach ($affected_object in $finding.AffectedObjects) {
				$affected_object_html += $templates.AffectedObjectsTemplate.Replace("{{AFFECTED_OBJECT}}", $affected_object)
			}
		}
		
		$long_finding_html = $long_finding_html.Replace($templates.AffectedObjectsTemplate, $affected_object_html)
		
		# References
		$reference_html = ''
		ForEach ($reference in $finding.References) {
			$this_reference = $templates.ReferencesTemplate.Replace("{{REFERENCE_URL}}", $reference.Url)
			$this_reference = $this_reference.Replace("{{REFERENCE_TEXT}}", $reference.Text)
			$reference_html += $this_reference
		}
		
		$long_finding_html = $long_finding_html.Replace($templates.ReferencesTemplate, $reference_html)
		
		# Add the completed short and long findings to the running list of findings (in HTML)
		$short_findings_html += $short_finding_html
		$long_findings_html += $long_finding_html
	}
}

# Insert command line execution information. This is coupled kinda badly, as is the Affected Objects html.
$flags = "<b>Prepared for organization:</b><br/>" + $org_name + "<br/><br/>"
$flags = $flags + "<b>Stats</b>:<br/> <b>" + $findings_count + "</b> out of <b>" + $inspectors.Count + "</b> executed inspector modules identified possible opportunities for improvement.<br/><br/>"  
$flags = $flags + "<b>Inspector Modules Executed</b>:<br/>" + [String]::Join("<br/>", $selected_inspectors)

$output = $templates.ReportTemplate.Replace($templates.FindingShortTemplate, $short_findings_html)
$output = $output.Replace($templates.FindingLongTemplate, $long_findings_html)
$output = $output.Replace($templates.ExecsumTemplate, $templates.ExecsumTemplate.Replace("{{CMDLINEFLAGS}}", $flags))

$output | Out-File -FilePath $out_path\Report_$(Get-Date -Format "yyyy-MM-dd_hh-mm-ss").html

return

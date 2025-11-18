<#
SharePoint / Graph Dokumentbibliotheks-Analyse mit ROT-Klassifizierung

Voraussetzungen:
 1. Microsoft.Graph PowerShell SDK installiert (Install-Module Microsoft.Graph -Scope CurrentUser)
 2. Anmeldung erfolgt direkt über dieses Skript (interaktiv oder App-Only, siehe unten)

Authentifizierungsoptionen:
 - Interaktiv: Benutzer meldet sich mit den Scopes Files.Read.All, Sites.Read.All, User.Read.All an.
 - App-Only via Client Secret: Azure AD App mit Application Permissions Files.Read.All und Sites.Read.All.
 - App-Only via Zertifikat: Wie oben, aber Authentifizierung über ein Zertifikat (Thumbprint).

App-Registrierung (für App-Only & SharePoint REST):
 1. Azure AD > App-Registrierungen > Neue Registrierung (Single Tenant empfehlenswert).
 2. API-Berechtigungen:
    - Microsoft Graph > Application > Files.Read.All, Sites.Read.All (+ optional Delegated Varianten für die interaktive Anmeldung).
    - SharePoint > Application > Sites.Selected oder Sites.FullControl.All – notwendig, damit dieselbe App auch SharePoint REST konsumieren kann.
 3. Admin-Consent erteilen.
 4. Geheimnis (Client Secret) erstellen oder Zertifikat hochladen (Thumbprint notieren).
 5. Bei Sites.Selected die Site-Zugriffe via SharePoint Admin Center oder `Grant-PnPAzureADAppSitePermission` vergeben.
 6. Für SharePoint REST denselben App-Principal verwenden und Token gegen `https://{tenant}.sharepoint.com/.default` anfordern.

Funktionen:
 - Rekursives Einlesen aller DriveItems einer Dokumentbibliothek (Ordner & Dateien)
 - Paging über @odata.nextLink
 - Throttling (429) & Transient Error Retry
 - Selektive Felder via $select zur Performanceoptimierung
 - ROT-Analyse (Trivial <50KB, Obsolete >2 Jahre, Redundant gleiche Namen oder gleiche Größe)
 - Export als CSV / JSON

Beispiel:
  pwsh -File .\sharepointexperiance.ps1 -SiteId '7df6bce3-a4ad-4f38-a71e-a5a9194bbcc9' -DriveId 'b!47z2fa2kOE-nHqWpGUu8yVsbnC4KYSFDnwdNPUJEe0bQ97qAaQH6RZtvaLyfoK1h' -ExportCsv -ExportJson -Verbose

Hinweis: Für sehr große Bibliotheken PageSize ggf. reduzieren (Standard 200) um Memory zu schonen.
#>

$script:MainParameterNames = @(
	'SiteId',
	'DriveId',
	'PageSize',
	'OutputDir',
	'ExportCsv',
	'ExportJson',
	'IncludeSystem',
	'MaxRetry',
	'AuthMode',
	'ClientId',
	'TenantId',
	'ClientSecret',
	'DryRun',
	'CertificateThumbprint'
)

function Convert-ArgsToMainParameters {
	param([string[]]$Arguments)
	$validNames = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
	foreach ($name in $script:MainParameterNames) { $validNames[$name] = $true }
	$result = @{}
	for ($index = 0; $index -lt $Arguments.Count; $index++) {
		$token = $Arguments[$index]
		if ($token -notmatch '^-') { continue }
		if ($token -match '^-{1,2}(?<name>[^:]+)(:(?<value>.*))?$') {
			$name = $matches['name']
			if (-not $validNames.ContainsKey($name)) { continue }
			$value = $matches['value']
			if (-not $value -and ($index + 1) -lt $Arguments.Count -and $Arguments[$index + 1] -notmatch '^-') {
				$index++
				$value = $Arguments[$index]
			}
			if (-not $value) { $value = $true }
			if ($value -is [string]) {
				switch -Regex ($value) {
					'^(?i:true)$'  { $value = $true; break }
					'^(?i:false)$' { $value = $false; break }
				}
			}
			$result[$name] = $value
		}
	}
	return $result
}

function Invoke-GraphWithRetry {
	param(
		[string]$Method = 'GET',
		[string]$Uri,
		[int]$Attempt = 0
	)
	$delayBase = 2
	# If a raw Graph access token is present, use Invoke-RestMethod with Authorization header
	$maxRetryLocal = if ($script:MaxRetry) { $script:MaxRetry } else { 6 }
	try {
		if ($script:GraphAccessToken -or $script:ForceRest) {
			# If ForceRest requested and no token present, attempt to get a token (if AppSecret variables available)
			if ($script:ForceRest -and -not $script:GraphAccessToken -and $script:ClientId -and $script:TenantId -and $script:ClientSecret) {
				try { $script:GraphAccessToken = Get-GraphAccessTokenCached -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret } catch { }
			}
			if ($script:GraphAccessToken) {
				$headers = @{ Authorization = "Bearer $($script:GraphAccessToken)"; Accept = 'application/json' }
				return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ErrorAction Stop
			}
			# if no token, fall through to Invoke-MgGraphRequest
		}
		
		else {
			return Invoke-MgGraphRequest -Method $Method -Uri $Uri -ErrorAction Stop
		}
		else {
			return Invoke-MgGraphRequest -Method $Method -Uri $Uri -ErrorAction Stop
		}
	}
	catch {
		# Try to extract HTTP status for retry logic
		$resp = $null
		$status = $null
		try { $resp = $_.Exception.Response; $status = $resp.StatusCode } catch {}
		if ($status -and ($status -eq 429 -or $status -ge 500)) {
			if ($Attempt -ge $maxRetryLocal) { throw }
			$retryAfter = $null
			try { $retryAfter = $resp.Headers['Retry-After'] } catch {}
			if (-not $retryAfter) { $retryAfter = [math]::Pow($delayBase,$Attempt+1) }
			Write-Warning "Throttling/Server Fehler ($status). Warte $retryAfter Sekunden und versuche erneut..."
			Start-Sleep -Seconds $retryAfter
			return Invoke-GraphWithRetry -Method $Method -Uri $Uri -Attempt ($Attempt+1)
		}
		# Refresh token on 401 when using token-based REST calls
		if ($status -and $status -eq 401 -and $script:GraphAccessToken) {
			Write-Verbose "401 erhalten. Versuche, Access Token zu erneuern und erneut.";
			try {
				# require client creds to refresh
				if ($script:TenantId -and $script:ClientId -and $script:ClientSecret) {
					$script:GraphAccessToken = Get-GraphAccessTokenCached -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret -ForceRefresh
					return Invoke-GraphWithRetry -Method $Method -Uri $Uri -Attempt ($Attempt+1)
				}
			}
			catch {
				Write-Verbose ('Token-Refresh fehlgeschlagen: ' + $_.Exception.Message)
			}
		}
		throw
	}
}

function Get-DriveRootChildren {
	param([string]$DriveId,[int]$PageSize)
	$select = 'id,name,size,createdDateTime,lastModifiedDateTime,createdBy,lastModifiedBy,parentReference,file,folder'
	$base = "https://graph.microsoft.com/v1.0/drives/$DriveId/root/children?`$select=$select&`$top=$PageSize"
	Get-PagedItems -InitialUrl $base
}

function Get-DriveItemChildren {
	param([string]$DriveId,[string]$ItemId,[int]$PageSize)
	$select = 'id,name,size,createdDateTime,lastModifiedDateTime,createdBy,lastModifiedBy,parentReference,file,folder'
	$base = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/children?`$select=$select&`$top=$PageSize"
	Get-PagedItems -InitialUrl $base
}

function Get-PagedItems {
	param([string]$InitialUrl)
	$url = $InitialUrl
	while ($url) {
		if ($script:DryRun) {
			# In DryRun mode, no paging - return empty
			return @()
		}
		$json = Invoke-GraphWithRetry -Uri $url
		if ($json.value) { $json.value }
		$url = $json.'@odata.nextLink'
	}
}

# Sensitivity label reader (beta endpoint)
# Uses Microsoft Graph beta to read the `sensitivityLabel` facet on a DriveItem:
# GET /beta/drives/{driveId}/items/{itemId}?$select=sensitivityLabel
# Note: this is a Beta endpoint. In production you may prefer the informationProtection route
# or validate stability of beta features. Required permissions: Files.Read.All, Sites.Read.All.
function Get-SensitivityLabel {
	param(
		[string]$SiteId,
		[string]$DriveId,
		[string]$ItemId
	)
	if ($script:DryRun) {
		# Provide deterministic mock label data for DryRun tests (optional)
		if ($ItemId -eq '2') { return @{ id = 'lbl-confidential'; name = 'Confidential' } }
		return $null
	}

	# Determine base API (v1.0 or beta) depending on UseBeta flag
	$api = if ($script:UseBeta) { 'beta' } else { 'v1.0' }

	# First try the listItem.fields (where SharePoint stores ComplianceTag/Sensitivity info)
	# Try both drives-based and sites-based listItem endpoints (tenants vary)
	$listUris = @(
		"https://graph.microsoft.com/$api/drives/$DriveId/items/$ItemId/listItem?`$expand=fields",
		"https://graph.microsoft.com/$api/sites/$SiteId/drives/$DriveId/items/$ItemId/listItem?`$expand=fields"
	)
	foreach ($listUri in $listUris) {
		try {
			$li = Invoke-GraphWithRetry -Method GET -Uri $listUri
			if ($li -and $li.fields) {
				$fields = $li.fields
				# Look for several possible field names tenants may use to store label/tag information
				$labelName = $null
				$labelId = $null
				foreach ($prop in $fields.PSObject.Properties) {
					$pn = $prop.Name
					$pv = $prop.Value
					if (-not $pv) { continue }
					# common name patterns
					if ($pn -match '(?i)ComplianceTagId|SensitivityLabelId|_ComplianceTagId') {
						if (-not $labelId) { $labelId = $pv }
						continue
					}
					if ($pn -match '(?i)ComplianceTag|SensitivityLabel|_ComplianceTag|_SensitivityLabel|DisplayName|_DisplayName') {
						if (-not $labelName) { $labelName = $pv }
						continue
					}
					# fallback: any property name containing 'label' or 'compliance' might be relevant
					if ($pn -match '(?i)label|compliance') {
						if (-not $labelName) { $labelName = $pv }
					}
				}
				if ($labelName -or $labelId) { return @{ id = $labelId; name = $labelName } }
			}
		}
		catch {
			# ignore errors here and try next endpoint
			Write-Verbose ('ListItem fields read failed for item ' + $ItemId + ' on ' + $listUri + ': ' + $_.Exception.Message)
		}
	}

	# Fallback: select sensitivityLabel property directly on the drive item
	$uri = "https://graph.microsoft.com/$api/drives/$DriveId/items/$ItemId?`$select=sensitivityLabel"
	try {
		$resp = Invoke-GraphWithRetry -Method GET -Uri $uri
		if ($null -ne $resp -and $resp.sensitivityLabel) {
			$lbl = $resp.sensitivityLabel
			$id = $lbl.id
			$name = $lbl.name
			if (-not $name) { $name = $lbl.label }
			if (-not $name) { $name = $lbl.displayName }
			if (-not $name) { $name = $lbl.title }
			return @{ id = $id; name = $name }
		}
		return $null
	}
	catch {
		# If no label exists or 404/403, just return $null. Log other errors as verbose.
		try {
			$status = $_.Exception.Response.StatusCode
			if ($status -eq 404 -or $status -eq 403) { return $null }
		} catch {}
		Write-Verbose ('Fehler beim Auslesen des Sensitivity Labels für Item ' + $ItemId + ': ' + $_.Exception.Message)
		return $null
	}
}

# Enrich items with sensitivity labels using a ThreadJob worker pool for compatibility
function Enrich-ItemsWithLabelsParallel {
	param(
		[System.Collections.Generic.List[object]]$Items,
		[string]$SiteId,
		[string]$DriveId
	)
	if ($script:DryRun) { return }
	$files = $Items | Where-Object { -not $_.isFolder }
	if (-not $files -or $files.Count -eq 0) { return }

	$throttle = if ($script:Parallelism -and $script:Parallelism -gt 0) { $script:Parallelism } else { 1 }
	$delayMs = if ($script:RequestDelayMs) { $script:RequestDelayMs } else { 0 }

	# Try to obtain a Graph access token for REST calls. If not available, fall back to serial calls
	$token = $null
	if ($script:GraphAccessToken) { $token = $script:GraphAccessToken }
	else {
		try {
			if ($script:TenantId -and $script:ClientId -and $script:ClientSecret) {
				$token = Get-GraphAccessTokenCached -TenantId $script:TenantId -ClientId $script:ClientId -ClientSecret $script:ClientSecret
			}
		} catch {}
	}

	if (-not $token) {
		Write-Verbose "Kein Access Token fuer parallele REST-Calls verfuegbar; verwende serielle Enrichment-Methode."
		foreach ($f in $files) {
			try {
				$lbl = Get-SensitivityLabel -SiteId $SiteId -DriveId $DriveId -ItemId $f.id
				if ($lbl) { $f.sensitivityLabelId = $lbl.id; $f.sensitivityLabelName = $lbl.name }
			} catch { Write-Verbose "Label enrich failed for $($f.id): $_" }
			if ($delayMs -gt 0) { Start-Sleep -Milliseconds (Get-Random -Minimum 0 -Maximum $delayMs) }
		}
		return
	}

	if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
		Write-Verbose "Start-ThreadJob nicht verfuegbar; fallback auf serielle Verarbeitung."
		foreach ($f in $files) {
			try {
				$lbl = Get-SensitivityLabel -SiteId $SiteId -DriveId $DriveId -ItemId $f.id
				if ($lbl) { $f.sensitivityLabelId = $lbl.id; $f.sensitivityLabelName = $lbl.name }
			} catch { Write-Verbose "Label enrich failed for $($f.id): $_" }
			if ($delayMs -gt 0) { Start-Sleep -Milliseconds (Get-Random -Minimum 0 -Maximum $delayMs) }
		}
		return
	}

	$api = if ($script:UseBeta) { 'beta' } else { 'v1.0' }
	$jobs = @()
	foreach ($f in $files) {
		# throttle: wait until running jobs are below limit
		while ((@($jobs | Where-Object { $_.State -eq 'Running' }).Count) -ge $throttle) {
			Start-Sleep -Milliseconds 200
			# prune finished jobs from list (ensure result is always an array)
			$jobs = @($jobs | Where-Object { $_.State -eq 'Running' })
		}

		$args = @($f.id, $SiteId, $DriveId, $token, $delayMs, $api)
		$job = Start-ThreadJob -ArgumentList $args -ScriptBlock {
			param($fid, $site, $drive, $tok, $delay, $api)
			try {
				if ($delay -gt 0) { Start-Sleep -Milliseconds (Get-Random -Minimum 0 -Maximum $delay) }
				$headers = @{ Authorization = "Bearer $tok"; Accept = 'application/json' }
				$listUri = "https://graph.microsoft.com/$api/sites/$site/drives/$drive/items/$fid/listItem?`$expand=fields"
				try {
					$li = Invoke-RestMethod -Method GET -Uri $listUri -Headers $headers -ErrorAction Stop
					if ($li -and $li.fields) {
						$fields = $li.fields
						$labelName = $null; $labelId = $null
						if ($fields.PSObject.Properties.Name -contains 'ComplianceTag') { $labelName = $fields.ComplianceTag }
						if ($fields.PSObject.Properties.Name -contains 'ComplianceTagId') { $labelId = $fields.ComplianceTagId }
						if (-not $labelName -and $fields.PSObject.Properties.Name -contains 'SensitivityLabel') { $labelName = $fields.SensitivityLabel }
						if (-not $labelId -and $fields.PSObject.Properties.Name -contains 'SensitivityLabelId') { $labelId = $fields.SensitivityLabelId }
						if ($labelName -or $labelId) { return @{ id = $fid; labelId = $labelId; labelName = $labelName } }
					}
				} catch {
					# fallthrough to driveItem select
				}

				$uri = "https://graph.microsoft.com/$api/drives/$drive/items/$fid?`$select=sensitivityLabel"
				try {
					$resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
					if ($null -ne $resp -and $resp.sensitivityLabel) {
						$lbl = $resp.sensitivityLabel
						$id = $lbl.id
						$name = $lbl.name
						if (-not $name) { $name = $lbl.label }
						if (-not $name) { $name = $lbl.displayName }
						if (-not $name) { $name = $lbl.title }
						return @{ id = $fid; labelId = $id; labelName = $name }
					}
				} catch {}
				return @{ id = $fid; labelId = $null; labelName = $null }
			}
			catch {
				return @{ id = $fid; labelId = $null; labelName = $null; error = $_.Exception.Message }
			}
		}
		$jobs += ,$job
	}

	if ($jobs.Count -gt 0) {
		Wait-Job -Job $jobs | Out-Null
		$results = Receive-Job -Job $jobs -ErrorAction SilentlyContinue
		foreach ($r in $results) {
			if (-not $r -or -not $r.id) { continue }
			$item = $Items | Where-Object { $_.id -eq $r.id }
			if ($item) {
				if ($r.labelId) { $item.sensitivityLabelId = $r.labelId }
				if ($r.labelName) { $item.sensitivityLabelName = $r.labelName }
			}
		}
		# cleanup
		Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
	}
}


function Get-MockDriveItems {
	# Return a small set of mock items (folders + files) for local testing
	$now = Get-Date
	$items = @()
	$items += [PSCustomObject]@{ id='1'; name='FolderA'; parentReference=@{path='/drive/root:'}; folder=@{}; file=$null; size=0; createdDateTime=$now.AddYears(-3); lastModifiedDateTime=$now.AddMonths(-6); createdBy=@{user=@{displayName='Alice'}}; lastModifiedBy=@{user=@{displayName='Bob'}} }
	$items += [PSCustomObject]@{ id='2'; name='doc1.pdf'; parentReference=@{path='/drive/root:/FolderA'}; folder=$null; file=@{}; size=120000; createdDateTime=$now.AddYears(-1); lastModifiedDateTime=$now.AddMonths(-2); createdBy=@{user=@{displayName='Alice'}}; lastModifiedBy=@{user=@{displayName='Carol'}} }
	$items += [PSCustomObject]@{ id='3'; name='small.txt'; parentReference=@{path='/drive/root:/FolderA'}; folder=$null; file=@{}; size=1024; createdDateTime=$now.AddYears(-5); lastModifiedDateTime=$now.AddYears(-3); createdBy=@{user=@{displayName='Dave'}}; lastModifiedBy=@{user=@{displayName='Eve'}} }
	$items += [PSCustomObject]@{ id='4'; name='FolderB'; parentReference=@{path='/drive/root:'}; folder=@{}; file=$null; size=0; createdDateTime=$now.AddYears(-4); lastModifiedDateTime=$now.AddYears(-2); createdBy=@{user=@{displayName='Frank'}}; lastModifiedBy=@{user=@{displayName='Grace'}} }
	$items += [PSCustomObject]@{ id='5'; name='duplicate.docx'; parentReference=@{path='/drive/root:/FolderB'}; folder=$null; file=@{}; size=2048; createdDateTime=$now.AddMonths(-1); lastModifiedDateTime=$now.AddDays(-10); createdBy=@{user=@{displayName='Heidi'}}; lastModifiedBy=@{user=@{displayName='Ivan'}} }
	$items += [PSCustomObject]@{ id='6'; name='duplicate.docx'; parentReference=@{path='/drive/root:/FolderA'}; folder=$null; file=@{hashes=@{quickXorHash='DRYRUN_QUICKXOR_6'}}; size=2048; createdDateTime=$now.AddMonths(-2); lastModifiedDateTime=$now.AddDays(-20); createdBy=@{user=@{displayName='Judy'}}; lastModifiedBy=@{user=@{displayName='Mallory'}} }
	return $items
}

function Build-Path {
	param($item)
	# parentReference.path hat Format /drive/root:/FolderA/FolderB
	$parentPath = $item.parentReference.path
	if ($parentPath) {
		$trim = $parentPath -replace '^/drive/root:',''
		if ($trim -eq '') { return "\" + $item.name }
		return $trim.TrimEnd('/') + '/' + $item.name
	}
	return $item.name
}

function Collect-DriveItemsRecursive {
	param([string]$SiteId,[string]$DriveId,[int]$PageSize)
	$all = [System.Collections.Generic.List[object]]::new()
	Write-Verbose "Lese Root Children..."
	if ($script:DryRun) {
		$mock = Get-MockDriveItems
		foreach ($child in $mock) { Process-Item -Item $child -SiteId $SiteId -DriveId $DriveId -Accumulator $all -PageSize $PageSize }
		return $all
	}


	$rootChildren = Get-DriveRootChildren -DriveId $DriveId -PageSize $PageSize
	foreach ($child in $rootChildren) {
		Process-Item -Item $child -SiteId $SiteId -DriveId $DriveId -Accumulator $all -PageSize $PageSize
	}
	return $all
}

function Process-Item {
	param($Item,[string]$SiteId,[string]$DriveId,$Accumulator,[int]$PageSize)
	$path = Build-Path $Item
	$isFolder = ($null -ne $Item.folder)
	$obj = [PSCustomObject]@{
		id = $Item.id
		name = $Item.name
		path = $path
		size = if ($isFolder) { 0 } else { [int64]($Item.size) }
		isFolder = $isFolder
		quickXorHash = $null
		createdDateTime = [datetime]$Item.createdDateTime
		lastModifiedDateTime = [datetime]$Item.lastModifiedDateTime
		createdBy = $Item.createdBy.user.displayName
		lastModifiedBy = $Item.lastModifiedBy.user.displayName
		trivial = $false
		obsolete = $false
		redundantNameGroup = $null
		redundantSizeGroup = $null
		sensitivityLabelId = $null
		sensitivityLabelName = $null
	}
	# Try to capture QuickXorHash if present on the item
	try {
		if (-not $isFolder) {
			if ($Item.PSObject.Properties.Name -contains 'file' -and $Item.file -and $Item.file.hashes -and $Item.file.hashes.quickXorHash) {
				$obj.quickXorHash = $Item.file.hashes.quickXorHash
			}
			elseif (-not $script:DryRun) {
				# fallback: request the item with file facet to get hashes
				$uri = "https://graph.microsoft.com/" + (if ($script:UseBeta) { 'beta' } else { 'v1.0' }) + "/drives/$DriveId/items/$($Item.id)?`$select=file"
				try {
					$resp = Invoke-GraphWithRetry -Method GET -Uri $uri
					if ($resp -and $resp.file -and $resp.file.hashes -and $resp.file.hashes.quickXorHash) {
						$obj.quickXorHash = $resp.file.hashes.quickXorHash
					}
				} catch { Write-Verbose "Could not fetch file.hashes for $($Item.id): $_" }
			}
		}
	} catch { }
	# Try to read sensitivity label (via listItem.fields or beta sensitivityLabel); errors should not stop processing
	try {
		$label = Get-SensitivityLabel -SiteId $SiteId -DriveId $DriveId -ItemId $Item.id
		if ($label) {
			$obj.sensitivityLabelId = $label.id
			$obj.sensitivityLabelName = $label.name
		}
	}
	catch {
		Write-Verbose "Warnung: Sensitivity-Label für Item $($Item.id) konnte nicht gelesen werden: $_"
	}
	$Accumulator.Add($obj)
	if ($isFolder) {
		Write-Verbose "â†’ Ordner: $($Item.name) â†’ lese Kinder"
		$children = Get-DriveItemChildren -DriveId $DriveId -ItemId $Item.id -PageSize $PageSize
		foreach ($c in $children) { Process-Item -Item $c -SiteId $SiteId -DriveId $DriveId -Accumulator $Accumulator -PageSize $PageSize }
	}
}

function Connect-GraphContext {
	param(
		[ValidateSet('Interactive','AppSecret','AppCertificate')][string]$AuthMode,
		[string]$ClientId,
		[string]$TenantId,
		[string]$ClientSecret,
		[string]$CertificateThumbprint
	)
	if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
		Write-Error "Microsoft Graph PowerShell SDK nicht geladen. Bitte Install-Module Microsoft.Graph und dann Connect-MgGraph ausführen."; exit 1
	}

	$requiredScopes = @('Files.Read.All','Sites.Read.All','User.Read.All',"SensitivityLabels.Read.All")
	try { $ctx = Get-MgContext } catch { $ctx = $null }
	if ($ctx) {
		if ($AuthMode -eq 'Interactive' -and $ctx.AuthType -eq 'Delegated') { return $ctx }
		if ($AuthMode -ne 'Interactive' -and $ctx.AuthType -eq 'AppOnly') { return $ctx }
	}

	switch ($AuthMode) {
		'Interactive' {
			Write-Host "Starte interaktive Graph-Anmeldung..." -ForegroundColor Cyan
			Connect-MgGraph -Scopes $requiredScopes -NoWelcome | Out-Null
		}
			'AppSecret' {
				if (-not $ClientId -or -not $TenantId -or -not $ClientSecret) {
					throw "Für AuthMode AppSecret sind ClientId, TenantId und ClientSecret erforderlich."
				}
				Write-Host "Starte App-Only Anmeldung (Client Secret) via access token..." -ForegroundColor Cyan
				# Use client_credentials to fetch an access token and set it for REST calls
				$token = Get-AccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -Scope 'https://graph.microsoft.com/.default'
				if (-not $token) { throw "Access token konnte nicht bezogen werden." }
				# Normalize token value: Get-AccessToken may return the full response object; store the raw access_token string
				if ($token -is [string]) { $script:GraphAccessToken = $token } else { $script:GraphAccessToken = $token.access_token }
				Write-Verbose "App-Only Token gesetzt; REST-Requests nutzen nun dieses Token."
			}
		'AppCertificate' {
			if (-not $ClientId -or -not $TenantId -or -not $CertificateThumbprint) {
				throw "Für AuthMode AppCertificate sind ClientId, TenantId und CertificateThumbprint erforderlich."
			}
			Write-Host "Starte App-Only Anmeldung (Zertifikat)..." -ForegroundColor Cyan
			Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -CertificateThumbprint $CertificateThumbprint -NoWelcome | Out-Null
		}
	}

	try { return Get-MgContext } catch { throw "Anmeldung bei Microsoft Graph fehlgeschlagen: $_" }
}

# Get an OAuth2 access token using client_credentials (v2 endpoint)
# Returns the raw access_token string. Scope defaults to Graph '.default' scope.
# Usage: Get-AccessToken -TenantId '<tid>' -ClientId '<cid>' -ClientSecret '<secret>' -Scope 'https://graph.microsoft.com/.default'
function Get-AccessToken {
	param(
		[Parameter(Mandatory=$true)][string]$TenantId,
		[Parameter(Mandatory=$true)][string]$ClientId,
		[Parameter(Mandatory=$true)][string]$ClientSecret,
		[string]$Scope = 'https://graph.microsoft.com/.default'
	)
	if ($script:DryRun) {
		Write-Verbose "DryRun: returning mock access token for scope $Scope"
		return 'DRYRUN_ACCESS_TOKEN'
	}
	$tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
	$body = @{
		client_id = $ClientId
		scope = $Scope
		client_secret = $ClientSecret
		grant_type = 'client_credentials'
	}
	try {
		$resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
		# return full response (contains access_token and expires_in)
		return $resp
	}
	catch {
		Write-Verbose ('Fehler beim Abrufen des Access Tokens: ' + $_.Exception.Message)
		throw
	}
}

# Cached Graph access token helper
function Get-GraphAccessTokenCached {
	param(
		[Parameter(Mandatory=$true)][string]$TenantId,
		[Parameter(Mandatory=$true)][string]$ClientId,
		[Parameter(Mandatory=$true)][string]$ClientSecret,
		[string]$Scope = 'https://graph.microsoft.com/.default',
		[switch]$ForceRefresh
	)
	if ($script:DryRun) { Write-Verbose "DryRun: returning mock access token (cached)"; return 'DRYRUN_ACCESS_TOKEN' }

	if (-not $script:GraphTokenCache) { $script:GraphTokenCache = @{} }
	$cacheKey = "$TenantId|$ClientId|$Scope"
	if (-not $ForceRefresh -and $script:GraphTokenCache.ContainsKey($cacheKey)) {
		$entry = $script:GraphTokenCache[$cacheKey]
		if ($entry.expiresAt -and (Get-Date) -lt $entry.expiresAt.AddSeconds(-60)) {
			return $entry.token
		}
	}

	$resp = Get-AccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -Scope $Scope
	if (-not $resp -or -not $resp.access_token) { throw "Token konnte nicht bezogen werden." }
	$token = $resp.access_token
	$expiresIn = 0
	try { $expiresIn = [int]$resp.expires_in } catch {}
	$expiresAt = if ($expiresIn -gt 0) { (Get-Date).AddSeconds($expiresIn) } else { (Get-Date).AddMinutes(55) }
	$script:GraphTokenCache[$cacheKey] = @{ token = $token; expiresAt = $expiresAt }
	return $token
}

# Get an access token suitable for SharePoint REST calls against a specific host
# Example: Get-SPRestAPIToken -TenantId '<tid>' -ClientId '<cid>' -ClientSecret '<secret>' -SharePointHost 'contoso.sharepoint.com'
function Get-SPRestAPIToken {
	param(
		[Parameter(Mandatory=$true)][string]$TenantId,
		[Parameter(Mandatory=$true)][string]$ClientId,
		[Parameter(Mandatory=$true)][string]$ClientSecret,
		[Parameter(Mandatory=$true)][string]$SharePointHost
	)
	if ($script:DryRun) {
		Write-Verbose "DryRun: returning mock SP token for host $SharePointHost"
		return 'DRYRUN_SP_TOKEN'
	}

	# Normalize host (allow passing 'contoso' or 'contoso.sharepoint.com')
	if ($SharePointHost -notmatch '\.') { $host = "$SharePointHost.sharepoint.com" } else { $host = $SharePointHost }
	$scope = "https://$host/.default"
	return Get-AccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -Scope $scope
}

function main {
	param(
		[Parameter(Mandatory=$true)][string]$SiteId,
		[Parameter(Mandatory=$true)][string]$DriveId,
		[int]$PageSize = 200,
		[string]$OutputDir = "./output",
		[switch]$ExportCsv,
		[switch]$ExportJson,
		[switch]$IncludeSystem,
		[int]$MaxRetry = 6,
		[ValidateSet('Interactive','AppSecret','AppCertificate')][string]$AuthMode = 'Interactive',
		[string]$ClientId,
		[string]$TenantId,
		[string]$ClientSecret,
		[switch]$ForceRest,
		[switch]$UseBeta,
		[switch]$OnlyListItems,
		[int]$Parallelism = 1,
		[int]$RequestDelayMs = 0,
		[switch]$DryRun,
		[string]$CertificateThumbprint
	)
	if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
		Write-Error "Microsoft Graph PowerShell SDK nicht geladen. Bitte Install-Module Microsoft.Graph und dann Connect-MgGraph ausfÃ¼hren."; exit 1
	}
	# Respect DryRun: skip any Graph authentication when DryRun is requested
	$script:DryRun = $DryRun.IsPresent
	# Script-level flags
	$script:ForceRest = $ForceRest.IsPresent
	$script:UseBeta = if ($UseBeta.IsPresent) { $true } else { $false }
	$script:OnlyListItems = $OnlyListItems.IsPresent
	$script:Parallelism = $Parallelism
	$script:RequestDelayMs = $RequestDelayMs
	if ($script:DryRun) {
		Write-Host "DryRun-Modus aktiv - Graph-Authentifizierung wird übersprungen." -ForegroundColor Yellow
		$ctx = $null
	}
	else {
		# Ensure authentication (Interactive or App-Only)
		try { $ctx = Get-MgContext } catch { $ctx = $null }
		if (-not $ctx) {
			Write-Host "Keine bestehende Graph-Session gefunden. Versuche Anmeldung mittels AuthMode=$AuthMode" -ForegroundColor Yellow
			try {
				Connect-GraphContext -AuthMode $AuthMode -ClientId $ClientId -TenantId $TenantId -ClientSecret $ClientSecret 
				# If Connect-GraphContext performed a Connect-MgGraph, Get-MgContext will return a context; if it only set a token, continue with token-based calls
				try { $ctx = Get-MgContext } catch { $ctx = $null }
			}
			catch {
				Write-Error "Anmeldung bei Microsoft Graph fehlgeschlagen: $_"; exit 1
			}
		}
	}

	# set script-level MaxRetry so helper functions can access it
	$script:MaxRetry = $MaxRetry
	$script:DryRun = $DryRun.IsPresent

	Write-Host "Starte SharePoint Drive Analyse..." -ForegroundColor Cyan
	Write-Host "SiteId: $SiteId"; Write-Host "DriveId: $DriveId"; Write-Host "PageSize: $PageSize"

	if (!(Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

	$script:Now = Get-Date
	$script:ObsoleteThreshold = $Now.AddYears(-2)
	$script:TrivialSizeBytes = 50KB

	Write-Host "Sammle DriveItems (rekursiv)..." -ForegroundColor Yellow
	$items = Collect-DriveItemsRecursive -SiteId $SiteId -DriveId $DriveId -PageSize $PageSize
	Write-Host "Anzahl Elemente gesamt: $($items.Count)" -ForegroundColor Green

	# As a compatibility-safe step, attempt a synchronous pass to populate sensitivity labels
	# (covers environments where parallel enrichment may be constrained)
	if (-not $script:DryRun) {
		Write-Verbose "Führe synchronen Label-Abgleich für alle Dateien durch..."
		foreach ($it in $items) {
			if ($it.isFolder) { continue }
			try {
				$lbl = Get-SensitivityLabel -SiteId $SiteId -DriveId $DriveId -ItemId $it.id
				if ($lbl) { $it.sensitivityLabelId = $lbl.id; $it.sensitivityLabelName = $lbl.name }
			} catch {
				Write-Verbose "Synchrones Label-Lesen für $($it.id) fehlgeschlagen: $_"
			}
		}
	}

	# ROT Klassifizierung vorbereiten
	Write-Host "Berechne ROT-Klassifizierung..." -ForegroundColor Yellow
	# Enrich items with sensitivity labels (parallel if requested)
	if (-not $script:DryRun) {
		Write-Verbose "Ergänze Sensitivity Labels (parallelism=$($script:Parallelism))"
		Enrich-ItemsWithLabelsParallel -Items $items -SiteId $SiteId -DriveId $DriveId
	}
	$twoYears = $ObsoleteThreshold
	$nameGroups = $items | Where-Object { -not $_.isFolder } | Group-Object name | Where-Object { $_.Count -gt 1 }
	$sizeGroups = $items | Where-Object { -not $_.isFolder -and $_.size -gt 0 } | Group-Object size | Where-Object { $_.Count -gt 1 }

	$nameGroupIndex = @{}
	foreach ($g in $nameGroups) { foreach ($i in $g.Group) { $nameGroupIndex[$i.id] = $g.Name } }
	$sizeGroupIndex = @{}
	foreach ($g in $sizeGroups) { foreach ($i in $g.Group) { $sizeGroupIndex[$i.id] = $g.Name } }

	foreach ($item in $items) {
		if (-not $item.isFolder) {
			if ($item.size -lt $TrivialSizeBytes) { $item.trivial = $true }
			if ($item.lastModifiedDateTime -lt $twoYears) { $item.obsolete = $true }
			if ($nameGroupIndex.ContainsKey($item.id)) { $item.redundantNameGroup = $nameGroupIndex[$item.id] }
			if ($sizeGroupIndex.ContainsKey($item.id)) { $item.redundantSizeGroup = $sizeGroupIndex[$item.id] }
		}
	}

	$stats = [PSCustomObject]@{
		total = $items.Count
		folders = ($items | Where-Object isFolder).Count
		files = ($items | Where-Object { -not $_.isFolder }).Count
		trivialFiles = ($items | Where-Object { $_.trivial }).Count
		obsoleteFiles = ($items | Where-Object { $_.obsolete }).Count
		redundantNameFiles = ($items | Where-Object { $_.redundantNameGroup }).Count
		redundantSizeFiles = ($items | Where-Object { $_.redundantSizeGroup }).Count
	}

	Write-Host "--- Zusammenfassung ---" -ForegroundColor Cyan
	$stats | Format-List

	if ($ExportCsv) {
		$csvPath = Join-Path $OutputDir 'drive_analysis.csv'
		$items | Export-Csv -NoTypeInformation -Delimiter ';' -Encoding UTF8 -Path $csvPath
		Write-Host "CSV exportiert: $csvPath" -ForegroundColor Green
	}
	if ($ExportJson) {
		$jsonPath = Join-Path $OutputDir 'drive_analysis.json'
		$items | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8
		Write-Host "JSON exportiert: $jsonPath" -ForegroundColor Green
	}

	Write-Host "Fertig." -ForegroundColor Cyan
}

$argumentHash = Convert-ArgsToMainParameters -Arguments $args

$SiteId= "7df6bce3-a4ad-4f38-a71e-a5a9194bbcc9"
$DriveId= "b!47z2fa2kOE-nHqWpGUu8yVsbnC4KYSFDnwdNPUJEe0bcXpVu_FG2SJXMRn1vb2k0"
$TenantId= "dba912b0-8fba-4882-95f0-02e9da476781"
$ClientId= "990bc8ba-4cdb-4152-ac6c-740793084968"
$ClientSecret= "ZkX8Q~c6pu-T35jtVa_RAO8rc3g6DHBlbAwxtbJR"
$ExportJson= $true
$ExportCsv= $true
$authMode= "AppSecret"

# Build parameter variables — prefer variables already defined in the session, otherwise fall back to CLI args
$paramNames = @('SiteId','DriveId','PageSize','OutputDir','ExportCsv','ExportJson','IncludeSystem','MaxRetry','AuthMode','ClientId','TenantId','ClientSecret','CertificateThumbprint','DryRun','ForceRest','UseBeta','OnlyListItems','Parallelism','RequestDelayMs')
$callParams = @{}
foreach ($p in $paramNames) {
	$existing = Get-Variable -Name $p -Scope Script -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
	if ($null -ne $existing) {
		$callParams[$p] = $existing
		continue
	}
	if ($argumentHash.ContainsKey($p)) { $callParams[$p] = $argumentHash[$p]; continue }
	# defaults for a few parameters
	switch ($p) {
		'PageSize' { $callParams[$p] = 200 }
		'OutputDir' { $callParams[$p] = './output' }
		'ExportCsv' { $callParams[$p] = $false }
		'ExportJson' { $callParams[$p] = $false }
		'IncludeSystem' { $callParams[$p] = $false }
		'MaxRetry' { $callParams[$p] = 6 }
		'AuthMode' { $callParams[$p] = 'Interactive' }
		default { $callParams[$p] = $null }
	}
}

# Convert Export flags to switch semantics
if ($callParams['ExportCsv'] -eq $true) { $callParams['ExportCsv'] = $true } else { $callParams['ExportCsv'] = $false }
if ($callParams['ExportJson'] -eq $true) { $callParams['ExportJson'] = $true } else { $callParams['ExportJson'] = $false }

Write-Verbose "Aufruf-Parameter: $($callParams | Out-String)"

# Call main with the assembled parameters using splatting
main @callParams




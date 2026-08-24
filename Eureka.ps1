param(
    [string]$Id,

    [string]$Jour = "J-0",

    [string]$Edition,

    [string]$Indexes,

    [string]$Liste,

    [switch]$KeepImages,

    [switch]$SetupCredentials,

    [string]$CredentialPath = (Join-Path $env:APPDATA "Eureka\varennes-credential.xml"),

    $Session
)

$ErrorActionPreference = "Stop"

function Save-VarennesCredential {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    Write-Host "Entrez une seule fois vos identifiants de la bibliotheque de Varennes."
    $credential = Get-Credential -Message "Bibliotheque de Varennes"

    if (-not $credential) {
        throw "Aucun identifiant n'a ete fourni."
    }

    $credential | Export-Clixml -Path $Path

    Write-Host ""
    Write-Host "Identifiants enregistres de facon chiffree pour cet utilisateur Windows :"
    Write-Host $Path
    Write-Host ""
    Write-Host "Les prochaines executions n'auront plus besoin d'interaction."
}

function New-EurekaSessionFromVarennes {
    param(
        [Parameter(Mandatory = $true)]
        [PSCredential]$Credential
    )

    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    $authBody = @{
        username  = $Credential.UserName
        password  = $Credential.GetNetworkCredential().Password
        birthdate = ""
        locale    = "en"
        pin       = $null
        v3Token   = ""
    } | ConvertTo-Json -Compress

    Write-Host "Connexion a la bibliotheque de Varennes..."

    try {
        $auth = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri "https://biblio.ville.varennes.qc.ca/in/rest/api/authenticate" `
            -Method POST `
            -ContentType "application/json; charset=utf-8" `
            -Headers @{
                "Accept"  = "application/json, text/plain, */*"
                "Referer" = "https://biblio.ville.varennes.qc.ca/account"
            } `
            -Body $authBody `
            -WebSession $webSession
    }
    catch {
        throw "Echec de l'authentification Varennes : $($_.Exception.Message)"
    }

    if ($auth.StatusCode -ne 200) {
        throw "Authentification Varennes refusee (HTTP $($auth.StatusCode))."
    }

    try {
        $null = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri "https://biblio.ville.varennes.qc.ca/in/connect.xhtml" `
            -Headers @{
                "Referer" = "https://biblio.ville.varennes.qc.ca/account"
            } `
            -WebSession $webSession

        $profile = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri "https://biblio.ville.varennes.qc.ca/in/rest/api/profile?locale=en" `
            -Headers @{
                "Accept"  = "application/json, text/plain, */*"
                "Referer" = "https://biblio.ville.varennes.qc.ca/account"
            } `
            -WebSession $webSession
    }
    catch {
        throw "La session Varennes n'a pas pu etre validee. Verifiez les identifiants enregistres. Detail : $($_.Exception.Message)"
    }

    if ($profile.StatusCode -ne 200) {
        throw "La session Varennes n'est pas authentifiee (HTTP $($profile.StatusCode))."
    }

    Write-Host "Connexion a Eureka..."

    try {
        $eureka = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri "https://nouveau.eureka.cc/access/httpref/default.aspx?un=varennesAU_1" `
            -Headers @{
                "Accept"  = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
                "Referer" = "https://biblio.ville.varennes.qc.ca/"
            } `
            -WebSession $webSession `
            -MaximumRedirection 10
    }
    catch {
        throw "Impossible d'ouvrir la session Eureka : $($_.Exception.Message)"
    }

    if ($eureka.StatusCode -ne 200) {
        throw "Eureka n'a pas retourne une page valide (HTTP $($eureka.StatusCode))."
    }

    try {
        $test = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri "https://nouveau.eureka.cc/Search/SyncIsAplim" `
            -Headers @{
                "Accept"  = "application/json, text/plain, */*"
                "Referer" = "https://nouveau.eureka.cc/"
            } `
            -WebSession $webSession
    }
    catch {
        throw "La session Eureka n'a pas pu etre validee : $($_.Exception.Message)"
    }

    if ($test.StatusCode -ne 200 -or $test.Content -notmatch '"isAplim"') {
        throw "La verification de la session Eureka a echoue."
    }

    Write-Host "Session Eureka active."
    Write-Host ""

    return $webSession
}

function Convert-JourToDate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Jour
    )

    $value = $Jour.Trim().ToUpperInvariant()

    if ($value -eq "J") {
        $offset = 0
    }
    elseif ($value -match '^J([+-]\d+)$') {
        $offset = [int]$Matches[1]
    }
    else {
        throw "Jour invalide '$Jour'. Utilisez par exemple J-0, J-1, J-2 ou J+1."
    }

    return (Get-Date).Date.AddDays($offset)
}

function New-EurekaDocName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Jour
    )

    $cleanId = $Id.Trim()
    if ([string]::IsNullOrWhiteSpace($cleanId)) {
        throw "L'identifiant du document est vide."
    }

    $date = Convert-JourToDate -Jour $Jour
    $dateText = $date.ToString("yyyyMMdd")

    return "pdf$([char]0x00B7)$dateText$([char]0x00B7)$cleanId"
}

function Get-WebExceptionBody {
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )

    try {
        $response = $ErrorRecord.Exception.Response
        if (-not $response) {
            return $null
        }

        $stream = $response.GetResponseStream()
        if (-not $stream) {
            return $null
        }

        $reader = New-Object System.IO.StreamReader($stream)
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Test-EndOfDocumentError {
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )

    $body = Get-WebExceptionBody -ErrorRecord $ErrorRecord

    if ([string]::IsNullOrWhiteSpace($body)) {
        return $false
    }

    return (
        $body -match '"success"\s*:\s*false' -and
        $body -match 'Une erreur inattendue est survenue'
    )
}


function Convert-Indexes {
    param(
        [string]$IndexesText
    )

    if ([string]::IsNullOrWhiteSpace($IndexesText)) {
        return $null
    }

    $value = $IndexesText.Trim()

    if ($value.StartsWith("[") -and $value.EndsWith("]")) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "La liste Indexes est vide."
    }

    # Accepte des virgules ou des points-virgules.
    # Les valeurs restent des chaines afin de preserver 001, 002, etc.
    $parts = $value -split '\s*[,;]\s*'
    $result = @()

    foreach ($part in $parts) {
        $token = $part.Trim()

        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        if ($token -match '[\\/:*?"<>|]') {
            throw "Index invalide '$token'."
        }

        $result += $token
    }

    if ($result.Count -eq 0) {
        throw "La liste Indexes ne contient aucun index valide."
    }

    return ,$result
}

function Ensure-Pillow {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if (-not $py) {
        throw @"
Python Launcher ('py') est introuvable.

Installe Python, puis Pillow avec :
    py -m pip install pillow
"@
    }

    & py -c "import PIL" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Pillow n'est pas installe. Installation..."
        & py -m pip install pillow
        if ($LASTEXITCODE -ne 0) {
            throw "Impossible d'installer Pillow."
        }
    }
}

function Download-EurekaDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Jour,

        [Parameter(Mandatory = $true)]
        [string]$Edition,

        [string[]]$Indexes,

        [Parameter(Mandatory = $true)]
        $Session,

        [switch]$KeepImages
    )

    $date = Convert-JourToDate -Jour $Jour
    $dateText = $date.ToString("yyyyMMdd")

    $cleanEdition = $Edition.Trim()
    if ([string]::IsNullOrWhiteSpace($cleanEdition)) {
        $cleanEdition = "_SansEdition"
    }

    $safeEdition = $cleanEdition -replace '[\\/:*?"<>|]', '_'
    $safeJour = $Jour.Trim().ToUpperInvariant() -replace '[\\/:*?"<>|]', '_'

    # Tous les PDF d'une execution vont dans le repertoire de la date du jour.
    $runDateText = (Get-Date).ToString("yyyyMMdd")
    $outputFolder = Join-Path $env:USERPROFILE "Downloads\Eureka\$runDateText"

    # Nom final lisible, par exemple : Ouest France quimper J-1.pdf
    $pdfName = "$safeEdition $safeJour.pdf"
    $pdfPath = Join-Path $outputFolder $pdfName

    # Repertoire temporaire unique pour les PNG de ce document.
    $safeId = $Id.Trim() -replace '[\\/:*?"<>|]', '_'
    $folder = Join-Path $outputFolder ("_work_" + $safeEdition + "_" + $safeJour + "_" + $safeId)

    # Si le PDF existe deja dans le repertoire du jour, ne rien telecharger.
    if (Test-Path -LiteralPath $pdfPath -PathType Leaf) {
        Write-Host "============================================================"
        Write-Host "Document : $Id"
        Write-Host "Edition  : $cleanEdition"
        Write-Host "Jour     : $Jour"
        Write-Host "Date doc : $dateText"
        Write-Host "PDF deja present : $pdfPath"
        Write-Host "Telechargement ignore."
        Write-Host "============================================================"
        Write-Host ""

        return [PSCustomObject]@{
            Id      = $Id
            Edition = $cleanEdition
            Jour    = $Jour
            Date    = $dateText
            Pages   = $null
            PdfPath = $pdfPath
            Success = $true
            Skipped = $true
        }
    }

    New-Item -ItemType Directory -Force -Path $outputFolder | Out-Null
    New-Item -ItemType Directory -Force -Path $folder | Out-Null

    Get-ChildItem `
        -Path $folder `
        -Filter "page-*.png" `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $headersList = @{
        "accept" = "text/html, */*; q=0.01"
        "referer" = "https://nouveau.eureka.cc/"
        "x-requested-with" = "XMLHttpRequest"
    }

    $headersImage = @{
        "accept" = "*/*"
        "origin" = "https://nouveau.eureka.cc"
        "referer" = "https://nouveau.eureka.cc/"
        "x-requested-with" = "XMLHttpRequest"
    }

    Write-Host "============================================================"
    Write-Host "Document : $Id"
    Write-Host "Edition  : $cleanEdition"
    Write-Host "Jour     : $Jour"
    Write-Host "Date doc : $dateText"

    if ($Indexes -and $Indexes.Count -gt 0) {
        $docName = New-EurekaDocName -Id $Id -Jour $Jour
        Write-Host "Mode     : prefixe + indexes explicites"
        Write-Host "Prefixe  : $docName"
        Write-Host ("Indexes  : " + ($Indexes -join ", "))
    }
    else {
        Write-Host "Mode     : ID complet de la premiere page"
        Write-Host "Premiere : $(New-EurekaDocName -Id $Id -Jour $Jour)"
    }

    Write-Host "Sortie   : $outputFolder"
    Write-Host "============================================================"
    Write-Host ""

    $maxPages = 1000
    $downloadedPages = 0

    if ($Indexes -and $Indexes.Count -gt 0) {
        # Mode 1 : Id est un prefixe, Indexes contient tous les suffixes exacts.
        $docName = New-EurekaDocName -Id $Id -Jour $Jour
        $position = 0

        foreach ($pageIndex in $Indexes) {
            $position++

            $pageDocName = "$docName$pageIndex"
            $encodedDocName = [System.Uri]::EscapeDataString($pageDocName)

            Write-Host ("[{0}/{1}] Index {2}..." -f $position, $Indexes.Count, $pageIndex)

            $imageListUrl = "https://nouveau.eureka.cc/Pdf/ImageList?docName=$encodedDocName"

            try {
                $listResponse = Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri $imageListUrl `
                    -WebSession $Session `
                    -Headers $headersList `
                    -ContentType "application/json; charset=utf-8"
            }
            catch {
                throw "Impossible de recuperer l'index $pageIndex pour $Id : $($_.Exception.Message)"
            }

            if (
                $listResponse.Content -match "Login\?ErrorCode" -or
                $listResponse.BaseResponse.ResponseUri.AbsoluteUri -match "/Login"
            ) {
                throw "La session Eureka a expire ou n'est plus authentifiee."
            }

            $cache = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $imageUrl = "https://nouveau.eureka.cc/Pdf/ImageBytes?imageIndex=0&id=$encodedDocName&cache=$cache&source=%2FPdf%3Fsection%3Dmobile"

            try {
                $response = Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri $imageUrl `
                    -Method POST `
                    -WebSession $Session `
                    -Headers $headersImage `
                    -ContentType "application/json; charset=utf-8"
            }
            catch {
                throw "Impossible de telecharger l'index $pageIndex pour $Id : $($_.Exception.Message)"
            }

            if ($response.Content -match "Login\?ErrorCode") {
                throw "La session Eureka a expire pendant le telechargement."
            }

            $base64 = $response.Content.Trim().Trim('"')

            try {
                $bytes = [Convert]::FromBase64String($base64)
            }
            catch {
                throw "L'index $pageIndex de $Id n'a pas retourne une image Base64 valide."
            }

            if (
                $bytes.Length -lt 8 -or
                $bytes[0] -ne 0x89 -or
                $bytes[1] -ne 0x50 -or
                $bytes[2] -ne 0x4E -or
                $bytes[3] -ne 0x47
            ) {
                throw "L'index $pageIndex de $Id ne semble pas etre un PNG standard."
            }

            # Le nom du PNG utilise la position dans la liste pour conserver
            # exactement l'ordre demande dans le PDF final.
            $pngPath = Join-Path $folder ("page-{0:D3}.png" -f $position)
            [System.IO.File]::WriteAllBytes($pngPath, $bytes)

            $downloadedPages++
        }
    }
    else {
        # Mode 2 : Id contient l'identifiant COMPLET de la premiere page.
        # Exemples :
        #   OP_P·1
        #   MSJ_P·svie_001
        #
        # Le suffixe numerique final est incremente en preservant sa largeur.
        $cleanId = $Id.Trim()

        if ($cleanId -notmatch '^(.*?)(\d+)$') {
            throw "Sans Indexes, Id doit etre l'identifiant complet de la premiere page et se terminer par un numero (ex: OP_P·1 ou MSJ_P·svie_001)."
        }

        $idPrefix = $Matches[1]
        $firstIndexText = $Matches[2]
        $indexWidth = $firstIndexText.Length
        $firstIndex = [int]$firstIndexText

        $pageNumber = $firstIndex
        $position = 0

        while ($true) {
            if ($position -ge $maxPages) {
                throw "Plus de $maxPages pages ont ete detectees pour $Id. Arret de securite."
            }

            $position++
            $indexText = $pageNumber.ToString(("D{0}" -f $indexWidth))
            $pageId = "$idPrefix$indexText"
            $pageDocName = New-EurekaDocName -Id $pageId -Jour $Jour
            $encodedDocName = [System.Uri]::EscapeDataString($pageDocName)

            Write-Host ("[{0}] {1}..." -f $position, $pageId)

            $imageListUrl = "https://nouveau.eureka.cc/Pdf/ImageList?docName=$encodedDocName"

            try {
                $listResponse = Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri $imageListUrl `
                    -WebSession $Session `
                    -Headers $headersList `
                    -ContentType "application/json; charset=utf-8"
            }
            catch {
                if ($position -gt 1 -and (Test-EndOfDocumentError -ErrorRecord $_)) {
                    Write-Host ""
                    Write-Host "Fin du document detectee."
                    break
                }

                throw "Impossible de recuperer '$pageId' pour $Id : $($_.Exception.Message)"
            }

            if (
                $listResponse.Content -match "Login\?ErrorCode" -or
                $listResponse.BaseResponse.ResponseUri.AbsoluteUri -match "/Login"
            ) {
                throw "La session Eureka a expire ou n'est plus authentifiee."
            }

            $cache = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $imageUrl = "https://nouveau.eureka.cc/Pdf/ImageBytes?imageIndex=0&id=$encodedDocName&cache=$cache&source=%2FPdf%3Fsection%3Dmobile"

            try {
                $response = Invoke-WebRequest `
                    -UseBasicParsing `
                    -Uri $imageUrl `
                    -Method POST `
                    -WebSession $Session `
                    -Headers $headersImage `
                    -ContentType "application/json; charset=utf-8"
            }
            catch {
                if ($position -gt 1) {
                    $statusCode = $null

                    try {
                        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                            $statusCode = [int]$_.Exception.Response.StatusCode
                        }
                    }
                    catch {
                        $statusCode = $null
                    }

                    if (
                        $statusCode -eq 500 -or
                        (Test-EndOfDocumentError -ErrorRecord $_)
                    ) {
                        Write-Host ""
                        Write-Host "Fin du document detectee a '$pageId'."
                        break
                    }
                }

                throw "Impossible de telecharger '$pageId' pour $Id : $($_.Exception.Message)"
            }

            if ($response.Content -match "Login\?ErrorCode") {
                throw "La session Eureka a expire pendant le telechargement."
            }

            $base64 = $response.Content.Trim().Trim('"')

            try {
                $bytes = [Convert]::FromBase64String($base64)
            }
            catch {
                throw "'$pageId' n'a pas retourne une image Base64 valide."
            }

            if (
                $bytes.Length -lt 8 -or
                $bytes[0] -ne 0x89 -or
                $bytes[1] -ne 0x50 -or
                $bytes[2] -ne 0x4E -or
                $bytes[3] -ne 0x47
            ) {
                throw "'$pageId' ne semble pas etre un PNG standard."
            }

            $pngPath = Join-Path $folder ("page-{0:D3}.png" -f $position)
            [System.IO.File]::WriteAllBytes($pngPath, $bytes)

            $downloadedPages++
            $pageNumber++
        }
    }

    $pages = $downloadedPages

    if ($pages -lt 1) {
        throw "Aucune page n'a pu etre telechargee pour $Id."
    }

    Write-Host ""
    Write-Host ("Nombre de pages detecte : {0}" -f $pages)
    Write-Host "Assemblage du PDF..."

    $pythonScript = Join-Path $env:TEMP ("eureka_assemble_{0}.py" -f [Guid]::NewGuid().ToString("N"))

    $pythonCode = @"
from PIL import Image
from pathlib import Path

folder = Path(r'''$folder''')
pdf_path = Path(r'''$pdfPath''')

files = sorted(folder.glob("page-*.png"))
if not files:
    raise SystemExit("Aucune image PNG trouvee.")

images = [Image.open(f).convert("RGB") for f in files]

try:
    images[0].save(
        pdf_path,
        "PDF",
        save_all=True,
        append_images=images[1:]
    )
finally:
    for img in images:
        img.close()
"@

    try {
        [System.IO.File]::WriteAllText(
            $pythonScript,
            $pythonCode,
            [System.Text.Encoding]::UTF8
        )

        & py $pythonScript
        $pythonExitCode = $LASTEXITCODE
    }
    finally {
        Remove-Item $pythonScript -Force -ErrorAction SilentlyContinue
    }

    if ($pythonExitCode -ne 0 -or -not (Test-Path $pdfPath)) {
        throw "L'assemblage PDF a echoue pour $Id."
    }

    if (-not $KeepImages) {
        Get-ChildItem -Path $folder -Filter "page-*.png" |
            Remove-Item -Force

        Remove-Item -Path $folder -Force -Recurse -ErrorAction SilentlyContinue
    }

    Write-Host "Termine : $pdfPath"
    Write-Host ""

    return [PSCustomObject]@{
        Id      = $Id
        Edition = $cleanEdition
        Jour    = $Jour
        Date    = $dateText
        Pages   = $pages
        PdfPath = $pdfPath
        Success = $true
        Skipped = $false
    }
}

if ($SetupCredentials) {
    Save-VarennesCredential -Path $CredentialPath
    return
}

if ([string]::IsNullOrWhiteSpace($Id) -and [string]::IsNullOrWhiteSpace($Liste)) {
    throw @"
Fournissez soit un document unique :
    .\Eureka.ps1 -Id "MSJ_P$([char]0x00B7)svie_001" -Jour "J-1" -Edition "Magazine"

ou avec indexes explicites :
    .\Eureka.ps1 -Id "OP_P$([char]0x00B7)" -Jour "J-1" -Edition "Journal de Montreal" -Indexes "[1,43,65,78]"

soit un fichier CSV :
    .\Eureka_batch.ps1 -Liste ".\documents.csv"
"@
}

if (-not [string]::IsNullOrWhiteSpace($Id) -and -not [string]::IsNullOrWhiteSpace($Liste)) {
    throw "Utilisez soit -Id/-Jour, soit -Liste, mais pas les deux en meme temps."
}

if (-not $Session) {
    if (-not (Test-Path $CredentialPath)) {
        throw @"
Aucun fichier d'identifiants n'a ete trouve :
$CredentialPath

Effectuez une seule fois :
    .\Eureka_batch.ps1 -SetupCredentials
"@
    }

    try {
        $credential = Import-Clixml -Path $CredentialPath
    }
    catch {
        throw "Impossible de lire les identifiants chiffres. Ils doivent avoir ete crees par le meme utilisateur Windows sur cette machine."
    }

    if ($credential -isnot [PSCredential]) {
        throw "Le fichier d'identifiants est invalide. Relancez .\Eureka_batch.ps1 -SetupCredentials pour le recreer."
    }

    $Session = New-EurekaSessionFromVarennes -Credential $credential
}

Ensure-Pillow

$documents = @()

if (-not [string]::IsNullOrWhiteSpace($Liste)) {
    if (-not (Test-Path $Liste)) {
        throw "Le fichier de liste n'existe pas : $Liste"
    }

    try {
        $rows = Import-Csv -Path $Liste
    }
    catch {
        throw "Impossible de lire le fichier CSV '$Liste' : $($_.Exception.Message)"
    }

    foreach ($row in $rows) {
        $rowId = [string]$row.Id
        $rowJour = [string]$row.Jour
        $rowEdition = [string]$row.Edition
        $rowIndexes = [string]$row.Indexes

        if ([string]::IsNullOrWhiteSpace($rowId)) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($rowJour)) {
            $rowJour = "J-0"
        }

        if ([string]::IsNullOrWhiteSpace($rowEdition)) {
            $rowEdition = "_SansEdition"
        }

        $parsedIndexes = Convert-Indexes -IndexesText $rowIndexes

        $documents += [PSCustomObject]@{
            Id      = $rowId.Trim()
            Jour    = $rowJour.Trim()
            Edition = $rowEdition.Trim()
            Indexes = $parsedIndexes
        }
    }

    if ($documents.Count -eq 0) {
        throw "Le fichier CSV ne contient aucun document valide. Colonnes attendues : Id,Jour,Edition,Indexes. Sans Indexes, Id doit etre complet (premiere page)."
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($Edition)) {
        $Edition = "_SansEdition"
    }

    $documents += [PSCustomObject]@{
        Id      = $Id.Trim()
        Jour    = $Jour.Trim()
        Edition = $Edition.Trim()
        Indexes = (Convert-Indexes -IndexesText $Indexes)
    }
}

$results = @()

foreach ($document in $documents) {
    try {
        $result = Download-EurekaDocument `
            -Id $document.Id `
            -Jour $document.Jour `
            -Edition $document.Edition `
            -Indexes $document.Indexes `
            -Session $Session `
            -KeepImages:$KeepImages

        $results += $result
    }
    catch {
        Write-Warning "Echec pour $($document.Edition) / $($document.Id) $($document.Jour) : $($_.Exception.Message)"

        $results += [PSCustomObject]@{
            Id      = $document.Id
            Edition = $document.Edition
            Jour    = $document.Jour
            Date    = $null
            Pages   = 0
            PdfPath = $null
            Success = $false
            Skipped = $false
        }
    }
}

Write-Host ""
Write-Host "================ RESUME ================"

$results | Format-Table Edition, Id, Jour, Date, Pages, Success, Skipped, PdfPath -AutoSize

$successPdfs = @($results | Where-Object { $_.Success -and -not $_.Skipped -and $_.PdfPath })

if ($successPdfs.Count -eq 1) {
    Start-Process $successPdfs[0].PdfPath
}
elseif ($successPdfs.Count -gt 1) {
    $runDateText = (Get-Date).ToString("yyyyMMdd")
    $outputFolder = "C:\work\PERSO\eureka\journaux\$runDateText"
    Start-Process $outputFolder
}

if (@($results | Where-Object { -not $_.Success }).Count -gt 0) {
    exit 1
}

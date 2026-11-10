$ErrorActionPreference = 'Stop'
$marker = -join ([char[]]@(0x76AE, 0x80A4, 0x5ECA))
$newTitle = -join ([char[]]@(67, 111, 100, 101, 120, 32, 0x76AE, 0x80A4, 0x5ECA, 32, 183, 32, 68, 114, 101, 97, 109, 83, 107, 105, 110))
$legacyTitle = -join ([char[]]@(25105, 30340, 32, 67, 111, 100, 101, 120, 32, 30382, 32932, 32, 183, 32, 68, 114, 101, 97, 109, 83, 107, 105, 110))
$newPage = [IO.File]::ReadAllText('D:\Dirty_work\codex-skin-audit\source\app\index.html', [Text.Encoding]::UTF8)
if ($newPage -notmatch '<title>(.*?)</title>') { throw 'new page title missing' }
$newPageTitle = $Matches[1]
$legacyPage = [IO.File]::ReadAllText('D:\CodexSkin\app\index.html', [Text.Encoding]::UTF8)
if ($legacyPage -notmatch '<title>(.*?)</title>') { throw 'installed page title missing' }
$legacyPageTitle = $Matches[1]
Write-Output ('marker_codes=' + ((@($marker.ToCharArray()) | ForEach-Object { [int]$_ }) -join ','))
Write-Output ('new_title_matches_new_page=' + ($newPageTitle -ceq $newTitle))
Write-Output ('new_title_matches_legacy_page=' + ($legacyPageTitle -ceq $newTitle))
Write-Output ('legacy_title_matches_legacy_page=' + ($legacyPageTitle -ceq $legacyTitle))
Write-Output ('legacy_title_matches_new_page=' + ($newPageTitle -ceq $legacyTitle))
Write-Output ('new_page_title=' + $newPageTitle)
Write-Output ('legacy_page_title=' + $legacyPageTitle)

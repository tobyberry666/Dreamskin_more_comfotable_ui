const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../launcher.ps1'), 'utf8');
test('existing gallery is activated only after helper readiness is ensured', () => {
  const body = source.slice(source.indexOf('  Ensure-DreamSkinTray'));
  assert.ok(body.indexOf('if (-not (Test-HelperHealth))') < body.indexOf('$existing = @(Get-GalleryWindows)'), 'dead helper must recover before existing-window return');
});
test('launcher uses same-origin HTTP page and checks helper version', () => {
  assert.ok(source.includes("pageUrl = 'http://127.0.0.1:'"));
  assert.match(source, /version -eq 2/);
});
test('launcher prefers independent system Node before engine runtime fallback', () => {
  const resolver = source.slice(source.indexOf('function Resolve-NodePath'), source.indexOf('function Resolve-BrowserPath'));
  assert.ok(resolver.indexOf('Get-Command node.exe') < resolver.indexOf('$candidates ='));
});
test('launcher retires the legacy file page before opening the HTTP page', () => {
  assert.match(source, /function Get-LegacyGalleryWindows/);
  assert.match(source, /\$GalleryTitleMarker = -join \(\[char\[\]\]@\(0x76AE, 0x80A4, 0x5ECA\)\)/, 'title marker must be code points: PS 5.1 reads BOM-free scripts as ANSI');
  assert.ok(!/[\u4e00-\u9fff]/.test(source), 'launcher source must stay ASCII for Windows PowerShell 5.1');
  assert.ok(source.indexOf('Get-LegacyGalleryWindows') < source.indexOf('$existing = @(Get-GalleryWindows)'), 'legacy window must be closed before the new window check');
  assert.ok(source.indexOf('$existing = @(Get-GalleryWindows)') < source.indexOf("pageUrl = 'http://127.0.0.1:'"));
});
test('window recognition requires exact title and verified browser/profile identity', () => {
  assert.match(source, /function Test-GalleryWindow/);
  assert.match(source, /function Test-BrowserExecutable/);
  assert.match(source, /-cne \$ExpectedTitle/, 'title must match exactly, not by substring');
  assert.match(source, /function Get-CommandLineOptionValues/, 'profile/app tokens must be parsed, not substring matched');
  assert.match(source, /function Normalize-PathIn/, 'profile/app values must be normalized and compared exactly');
  const newGetter = source.slice(source.indexOf('function Get-GalleryWindows'), source.indexOf('function Get-LegacyGalleryWindows'));
  assert.match(newGetter, /Test-GalleryWindow \$window \$NewWindowTitle \$AppUrl/);
  const legacyGetter = source.slice(source.indexOf('function Get-LegacyGalleryWindows'), source.indexOf('function Show-AppWindow'));
  assert.match(legacyGetter, /Test-GalleryWindow \$window \$LegacyWindowTitle \$LegacyUrl/);
});
test('launcher has no unmanaged default-profile fallback window', () => {
  assert.ok(!/default profile/i.test(source), 'no default-profile fallback path');
  assert.ok(!source.includes("Start-Process -FilePath ('http://127.0.0.1:' + $HelperPort"), 'no unmanaged default-browser open');
  assert.match(source, /refusing to open an unmanaged fallback window/, 'must fail clearly instead of opening an unverifiable window');
});

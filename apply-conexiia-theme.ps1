# apply-conexiia-theme.ps1
# Substitui classes Tailwind hardcoded pelo tema Conexiia no SpellWoot
# Execute na raiz do projeto: .\apply-conexiia-theme.ps1

$targetDirs = @(
  "app/javascript/dashboard",
  "app/javascript/shared",
  "app/javascript/widget"
)

$extensions = @("*.vue", "*.js", "*.jsx")

# Mapeamento: classe antiga -> classe nova
# Ordem importa — mais específico primeiro
$replacements = [ordered]@{
  # Backgrounds brancos/claros -> surface Conexiia
  'bg-white'                    = 'bg-[#12030a]'
  'bg-gray-50'                  = 'bg-[#0c0206]'
  'bg-gray-100'                 = 'bg-[#12030a]'
  'bg-gray-200'                 = 'bg-[#1e0714]'
  'bg-slate-50'                 = 'bg-[#0c0206]'
  'bg-slate-100'                = 'bg-[#12030a]'
  'bg-slate-200'                = 'bg-[#1e0714]'
  'bg-slate-800'                = 'bg-[#1e0714]'
  'bg-slate-900'                = 'bg-[#12030a]'

  # Borders
  'border-gray-100'             = 'border-[#2b0c1e]'
  'border-gray-200'             = 'border-[#2b0c1e]'
  'border-gray-300'             = 'border-[#3e1428]'
  'border-slate-100'            = 'border-[#2b0c1e]'
  'border-slate-200'            = 'border-[#2b0c1e]'
  'border-slate-300'            = 'border-[#3e1428]'
  'border-white'                = 'border-[#2b0c1e]'

  # Textos claros -> text Conexiia
  'text-gray-900'               = 'text-[#fcfafb]'
  'text-gray-800'               = 'text-[#fcfafb]'
  'text-gray-700'               = 'text-[#fcfafb]'
  'text-gray-600'               = 'text-[#a096a8]'
  'text-gray-500'               = 'text-[#a096a8]'
  'text-gray-400'               = 'text-[#75646d]'
  'text-slate-900'              = 'text-[#fcfafb]'
  'text-slate-800'              = 'text-[#fcfafb]'
  'text-slate-700'              = 'text-[#fcfafb]'
  'text-slate-600'              = 'text-[#a096a8]'
  'text-slate-500'              = 'text-[#a096a8]'
  'text-slate-400'              = 'text-[#75646d]'
  'text-black'                  = 'text-[#fcfafb]'

  # Hover backgrounds
  'hover:bg-gray-50'            = 'hover:bg-[#1e0714]'
  'hover:bg-gray-100'           = 'hover:bg-[#1e0714]'
  'hover:bg-slate-50'           = 'hover:bg-[#1e0714]'
  'hover:bg-slate-100'          = 'hover:bg-[#1e0714]'
  'hover:bg-white'              = 'hover:bg-[#240a17]'

  # Dark mode overrides que conflitam
  'dark:bg-slate-800'           = 'dark:bg-[#1e0714]'
  'dark:bg-slate-900'           = 'dark:bg-[#12030a]'
  'dark:bg-gray-800'            = 'dark:bg-[#1e0714]'
  'dark:bg-gray-900'            = 'dark:bg-[#12030a]'
  'dark:border-slate-700'       = 'dark:border-[#2b0c1e]'
  'dark:border-gray-700'        = 'dark:border-[#2b0c1e]'
  'dark:text-slate-200'         = 'dark:text-[#fcfafb]'
  'dark:text-gray-200'          = 'dark:text-[#fcfafb]'
  'dark:text-slate-400'         = 'dark:text-[#a096a8]'
  'dark:text-gray-400'          = 'dark:text-[#a096a8]'
}

$totalFiles = 0
$totalChanges = 0
$changedFiles = @()

foreach ($dir in $targetDirs) {
  if (-not (Test-Path $dir)) { continue }
  
  foreach ($ext in $extensions) {
    $files = Get-ChildItem -Path $dir -Recurse -Include $ext -File
    
    foreach ($file in $files) {
      $content = [System.IO.File]::ReadAllText($file.FullName)
      $original = $content
      $fileChanges = 0
      
      foreach ($old in $replacements.Keys) {
        $new = $replacements[$old]
        $count = ([regex]::Matches($content, [regex]::Escape($old))).Count
        if ($count -gt 0) {
          $content = $content.Replace($old, $new)
          $fileChanges += $count
        }
      }
      
      if ($fileChanges -gt 0) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($file.FullName, $content, $utf8NoBom)
        $totalChanges += $fileChanges
        $totalFiles++
        $changedFiles += "$($file.FullName) ($fileChanges substituições)"
      }
    }
  }
}

Write-Host "`n✅ CONCLUÍDO" -ForegroundColor Green
Write-Host "Arquivos modificados: $totalFiles"
Write-Host "Total de substituições: $totalChanges"
Write-Host "`nArquivos alterados:"
foreach ($f in $changedFiles) {
  Write-Host "  → $f" -ForegroundColor Cyan
}

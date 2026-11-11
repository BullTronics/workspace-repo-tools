Set-Location $PSScriptRoot

# Clear Flutter's stale chrome-device cache
if (Test-Path .dart_tool\chrome-device) {
    Remove-Item -Recurse -Force .dart_tool\chrome-device
}

$defaultSlug = (Split-Path -Leaf $PSScriptRoot).ToLower() -replace '[^a-z0-9._-]', '-'
$appSlug = $defaultSlug
$webPort = 3000
$customUserDataDir = $null
$extraArgs = @()

$envFile = Join-Path $PSScriptRoot ".env"
$hasEnvFile = Test-Path $envFile

if ($hasEnvFile) {
    Get-Content $envFile -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            if ($line -match '^export\s+(.+)$') { $line = $Matches[1].Trim() }
            $parts = $line.Split("=", 2)
            $k = $parts[0].Trim()
            $v = $parts[1].Trim().Trim('"').Trim("'")
            if ($k -eq "APP_SLUG" -and $v) { $appSlug = ($v.ToLower() -replace '[^a-z0-9._-]', '-') }
            if ($k -eq "PORT" -and $v) { $webPort = [int]$v }
            if ($k -eq "CHROME_USER_DATA_DIR" -and $v) { $customUserDataDir = $v }
            if ($k -eq "FLUTTER_EXTRA_ARGS" -and $v) {
                $extraArgs += $v.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
            }
        }
    }
}

# Persistent Chrome launcher proxy so custom --user-data-dir takes precedence on Windows
function Ensure-ChromeLauncher {
    param([string]$Slug)
    $launcherDir = Join-Path $env:TEMP "$Slug-runners"
    if (-not (Test-Path $launcherDir)) {
        New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
    }
    $launcherExe = Join-Path $launcherDir "chrome-launcher.exe"
    if (-not (Test-Path $launcherExe)) {
        $cs = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

class ChromeLauncher {
    static string FindChrome() {
        string[] candidates = new string[] {
            @"C:\Program Files\Google\Chrome\Application\chrome.exe",
            @"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Google\Chrome\Application\chrome.exe")
        };
        foreach (var c in candidates) {
            if (File.Exists(c)) return c;
        }
        return "chrome.exe";
    }

    static string EscapeArg(string arg) {
        if (string.IsNullOrEmpty(arg)) return "\"\"";
        if (!arg.Contains(" ") && !arg.Contains("\t") && !arg.Contains("\"")) return arg;
        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        for (int i = 0; i < arg.Length; i++) {
            int backslashes = 0;
            while (i < arg.Length && arg[i] == '\\') { backslashes++; i++; }
            if (i == arg.Length) { sb.Append('\\', backslashes * 2); break; }
            else if (arg[i] == '"') { sb.Append('\\', backslashes * 2 + 1); sb.Append('"'); }
            else { sb.Append('\\', backslashes); sb.Append(arg[i]); }
        }
        sb.Append('"');
        return sb.ToString();
    }

    static int Main(string[] args) {
        string chromePath = FindChrome();
        if (args.Length == 1 && (args[0] == "--version" || args[0] == "-v")) {
            try { Console.WriteLine("Google Chrome " + FileVersionInfo.GetVersionInfo(chromePath).ProductVersion); }
            catch { Console.WriteLine("Google Chrome"); }
            return 0;
        }
        string preferredUserDataDir = null;
        for (int i = args.Length - 1; i >= 0; i--) {
            if (args[i].StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)) {
                preferredUserDataDir = args[i];
                break;
            }
        }
        List<string> finalArgs = new List<string>();
        bool added = false;
        foreach (string arg in args) {
            if (arg.StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)) {
                if (!added) { finalArgs.Add(preferredUserDataDir ?? arg); added = true; }
            } else {
                finalArgs.Add(arg);
            }
        }
        StringBuilder cmdLine = new StringBuilder();
        for (int i = 0; i < finalArgs.Count; i++) {
            if (i > 0) cmdLine.Append(" ");
            cmdLine.Append(EscapeArg(finalArgs[i]));
        }
        ProcessStartInfo psi = new ProcessStartInfo { FileName = chromePath, Arguments = cmdLine.ToString(), UseShellExecute = false };
        Process proc = Process.Start(psi);
        if (proc == null) return 1;
        proc.WaitForExit();
        return proc.ExitCode;
    }
}
"@
        Add-Type -TypeDefinition $cs -OutputAssembly $launcherExe -OutputType ConsoleApplication
    }
    return $launcherExe
}

$env:CHROME_EXECUTABLE = Ensure-ChromeLauncher -Slug $appSlug

$userDataDir = if ($customUserDataDir) { $customUserDataDir } else { Join-Path $env:TEMP "$appSlug-chrome-data" }
$runArgs = @("run", "-d", "chrome", "--web-port", "$webPort", "--web-browser-flag=--user-data-dir=$userDataDir")
if ($hasEnvFile) {
    $runArgs += "--dart-define-from-file=.env"
}
$runArgs += $extraArgs

Write-Host "Launching Flutter Web on port $webPort..." -ForegroundColor Green
& flutter @runArgs


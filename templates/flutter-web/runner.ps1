# Modular runner for repo_type: flutter-web
function Ensure-TemplateFlutterChromeLauncher {
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
        foreach (var c in candidates) { if (File.Exists(c)) return c; }
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
        string preferred = null;
        for (int i = args.Length - 1; i >= 0; i--) {
            if (args[i].StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)) { preferred = args[i]; break; }
        }
        List<string> finalArgs = new List<string>();
        bool added = false;
        foreach (string arg in args) {
            if (arg.StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)) {
                if (!added) { finalArgs.Add(preferred ?? arg); added = true; }
            } else { finalArgs.Add(arg); }
        }
        StringBuilder cmdLine = new StringBuilder();
        for (int i = 0; i < finalArgs.Count; i++) {
            if (i > 0) cmdLine.Append(" ");
            cmdLine.Append(EscapeArg(finalArgs[i]));
        }
        Process proc = Process.Start(new ProcessStartInfo { FileName = chromePath, Arguments = cmdLine.ToString(), UseShellExecute = false });
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

function Invoke-TemplateFlutterWeb {
    if (Test-Path ".dart_tool\chrome-device") {
        Remove-Item -Recurse -Force ".dart_tool\chrome-device"
    }
    $defaultSlug = (Split-Path -Leaf (Get-Location).Path).ToLower() -replace '[^a-z0-9._-]', '-'
    $appSlug = if ($env:APP_SLUG) { ($env:APP_SLUG.ToLower() -replace '[^a-z0-9._-]', '-') } else { $defaultSlug }
    $webPort = if ($env:PORT) { $env:PORT } else { "3000" }
    $userDataDir = if ($env:CHROME_USER_DATA_DIR) { $env:CHROME_USER_DATA_DIR } else { Join-Path $env:TEMP "$appSlug-chrome-data" }

    $env:CHROME_EXECUTABLE = Ensure-TemplateFlutterChromeLauncher -Slug $appSlug

    $runArgs = @("run", "-d", "chrome", "--web-port", "$webPort", "--web-browser-flag=--user-data-dir=$userDataDir")
    if (Test-Path ".env") { $runArgs += "--dart-define-from-file=.env" }
    if ($env:FLUTTER_EXTRA_ARGS) {
        $runArgs += $env:FLUTTER_EXTRA_ARGS.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    }
    & flutter @runArgs
}


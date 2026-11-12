# Modular runner for repo_type: flutter-web
ensure_template_flutter_chrome_launcher() {
    local slug="$1"
    if [[ "${IS_WINDOWS_BASH:-0}" -ne 1 ]] || ! command -v powershell.exe >/dev/null 2>&1; then
        return 0
    fi

    local launcher_exe
    launcher_exe=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -Command - "$slug" <<'PSEOF'
$Slug = if ($args[0]) { $args[0] } else { "app" }
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
        string envUserData = Environment.GetEnvironmentVariable("CHROME_USER_DATA_DIR");
        string preferred = null;
        if (!string.IsNullOrEmpty(envUserData)) {
            preferred = envUserData.StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)
                ? envUserData
                : "--user-data-dir=" + envUserData;
        } else {
            for (int i = args.Length - 1; i >= 0; i--) {
                if (args[i].StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)) { preferred = args[i]; break; }
            }
        }
        List<string> finalArgs = new List<string>();
        bool added = false;
        foreach (string arg in args) {
            if (arg.StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)) {
                if (!added) { finalArgs.Add(preferred ?? arg); added = true; }
            } else { finalArgs.Add(arg); }
        }
        if (!added && !string.IsNullOrEmpty(preferred)) {
            finalArgs.Add(preferred);
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
[Console]::Out.Write($launcherExe)
PSEOF
    )
    launcher_exe=$(echo "$launcher_exe" | tr -d '\r\n')
    if [[ -n "$launcher_exe" ]]; then
        export CHROME_EXECUTABLE="$launcher_exe"
    fi
}

run_template_flutter_web() {
    rm -rf .dart_tool/chrome-device

    local default_slug
    default_slug=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
    local app_slug="${APP_SLUG:-$default_slug}"
    local web_port="${PORT:-3000}"
    local chrome_data
    if [[ -n "${CHROME_USER_DATA_DIR:-}" ]]; then
        chrome_data="$CHROME_USER_DATA_DIR"
        if [[ "${IS_WINDOWS_BASH:-0}" -eq 1 ]] && command -v cygpath >/dev/null 2>&1; then
            chrome_data=$(cygpath -w "$chrome_data")
        fi
    elif [[ "${IS_WINDOWS_BASH:-0}" -eq 1 ]]; then
        local win_temp
        if command -v powershell.exe >/dev/null 2>&1; then
            win_temp=$(powershell.exe -NoProfile -Command '[System.IO.Path]::GetTempPath()' 2>/dev/null | tr -d '\r\n')
        fi
        [[ -z "$win_temp" ]] && win_temp="${TEMP:-$TMP}"
        win_temp="${win_temp%\\}"
        chrome_data="${win_temp}\\${app_slug}-chrome-data"
    else
        chrome_data="/tmp/${app_slug}-chrome-data"
    fi

    if [[ "${IS_WINDOWS_BASH:-0}" -eq 1 ]]; then
        ensure_template_flutter_chrome_launcher "$app_slug"
        export CHROME_USER_DATA_DIR="$chrome_data"
    fi

    local cmd_args=(-d chrome --web-port "$web_port" --web-browser-flag="--user-data-dir=$chrome_data")
    if [[ -f .env ]]; then
        cmd_args+=(--dart-define-from-file=.env)
    fi

    if [[ -n "${FLUTTER_EXTRA_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        local extra=($FLUTTER_EXTRA_ARGS)
        cmd_args+=("${extra[@]}")
    fi

    flutter run "${cmd_args[@]}"
}

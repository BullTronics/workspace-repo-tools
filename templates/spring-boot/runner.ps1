# Modular runner for repo_type: spring-boot
function Invoke-TemplateSpringBoot {
    $jvmArgs = if ($env:JVM_ARGS) { $env:JVM_ARGS } else { "-Duser.timezone=UTC" }
    if ($env:JAR_FILE -and (Test-Path $env:JAR_FILE)) {
        $jvmArgList = @($jvmArgs.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries))
        & java @jvmArgList -jar $env:JAR_FILE
    } elseif (Test-Path ".\mvnw.cmd") {
        $argProp = "-Dspring-boot.run.jvmArguments=`"$jvmArgs`""
        & cmd.exe /c "mvnw.cmd spring-boot:run $argProp"
    } else {
        $argProp = "-Dspring-boot.run.jvmArguments=`"$jvmArgs`""
        & cmd.exe /c "mvn spring-boot:run $argProp"
    }
}


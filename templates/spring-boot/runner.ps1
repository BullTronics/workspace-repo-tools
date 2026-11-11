# Modular runner for repo_type: spring-boot
function Invoke-TemplateSpringBoot {
    $jvmArgs = if ($env:JVM_ARGS) { $env:JVM_ARGS } else { "-Duser.timezone=UTC" }
    if ($env:JAR_FILE -and (Test-Path $env:JAR_FILE)) {
        & java $jvmArgs -jar $env:JAR_FILE
    } elseif (Test-Path ".\mvnw.cmd") {
        & .\mvnw.cmd spring-boot:run "-Dspring-boot.run.jvmArguments=$jvmArgs"
    } else {
        & mvn spring-boot:run "-Dspring-boot.run.jvmArguments=$jvmArgs"
    }
}


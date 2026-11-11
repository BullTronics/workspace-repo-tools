# Modular runner for repo_type: spring-boot
run_template_spring_boot() {
    local jvm_args="${JVM_ARGS:--Duser.timezone=UTC}"
    if [[ -n "${JAR_FILE:-}" && -f "${JAR_FILE}" ]]; then
        java "$jvm_args" -jar "$JAR_FILE"
    elif [[ -x "./mvnw" ]]; then
        ./mvnw spring-boot:run "-Dspring-boot.run.jvmArguments=$jvm_args"
    elif [[ -f "./mvnw" ]]; then
        bash ./mvnw spring-boot:run "-Dspring-boot.run.jvmArguments=$jvm_args"
    else
        mvn spring-boot:run "-Dspring-boot.run.jvmArguments=$jvm_args"
    fi
}


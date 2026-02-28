shell_source(name="build-script", source="build.sh")
shell_source(name="datacore", source="datacore.sh")
files(name="services", sources=["*.service", "*.conf"])
file(name="db-script", source="provision_application_db.sql")

run_shell_command(
    name="build",
    command="CHROOT={chroot} bash ./build.sh",
    execution_dependencies=["//:common", ":build-script", ":datacore", ":db-script", ":services"],
)

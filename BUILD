shell_source(name="common", source="common.sh")
shell_source(name="metadata-script", source="update-metadata.sh")

run_shell_command(
    name="update-metadata",
    command="bash ./update-metadata.sh",
    execution_dependencies=[":metadata-script"],
)

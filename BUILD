shell_source(name="common", source="common.sh")

package_shell_command(
    name="debian13-root",
    command="source common.sh && buildCommonRoot",
    tools=["source", "sudo", "mkdir", "mountpoint"],
    execution_dependencies=[":common"],
    timeout=120,
    output_files=["debian13-root.tar.gz"],
)

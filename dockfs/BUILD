shell_source(name="build-script", source="build.sh")

shell_command(
    name="debian-13-amd64-qcow2",
    command=(
        "wget https://cloud.debian.org/images/cloud/trixie/20260129-2372/debian-13-generic-amd64-20260129-2372.qcow2 "
        "-O debian-13-generic-amd64.qcow2"
    ),
    tools=["wget"],
    output_files=["./debian-13-generic-amd64.qcow2"],
    log_output=True,
)

run_shell_command(
    name="build",
    command="CHROOT={chroot} bash ./build.sh",
    execution_dependencies=[
        ":build-script",
        ":debian-13-amd64-qcow2",
    ],
)

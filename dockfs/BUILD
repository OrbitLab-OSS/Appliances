shell_source(name="build-script", source="build.sh")
shell_sources(name="dockfs-scripts", sources=["dockfs-*.sh"])
files(name="systemd", sources=["*.service", "*.rules"])

shell_command(
    name="debian-13-amd64-qcow2",
    command=(
        "wget https://cloud.debian.org/images/cloud/trixie/20260129-2372/debian-13-generic-amd64-20260129-2372.qcow2 "
        "-O debian-13-generic-amd64.qcow2"
    ),
    tools=["wget"],
    output_files=["./debian-13-generic-amd64.qcow2"],
)

package_shell_command(
    name="appliance",
    command="bash ./build.sh",
    tools=[
        "bash",
        "sudo",
        "mkdir",
        "mountpoint",
        "sleep",
        "mv",
        "modprobe",
        "qemu-nbd",
        "lsblk",
        "blockdev",
        "udevadm",
        "ls"
    ],
    execution_dependencies=[
        ":build-script",
        ":dockfs-scripts",
        ":systemd",
        ":debian-13-amd64-qcow2",
    ],
    extra_env_vars=["VERSION"],
    timeout=360,
    output_path="${target_name_normalized}${file_suffix}",
    output_files=["orbitlab-dockfs-amd64-*.qcow2"],
)

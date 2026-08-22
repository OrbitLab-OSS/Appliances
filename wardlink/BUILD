shell_source(name="build-script", source="build.sh")

shell_sources(name="wardlink-scripts", sources=["wardlink*.sh"])

files(name="systemd", sources=["*.service", "*.network", "*.conf"])

package_shell_command(
    name="appliance",
    command="bash ./build.sh",
    tools=[
        "bash",
        "sudo",
        "mkdir",
        "mountpoint",
        "mount",
        "umount",
        "cp",
        "rm",
        "install",
        "tar",
        "chroot",
        "awk",
        "grep",
        "tee",
    ],
    execution_dependencies=[
        "//:common",
        "//:debian13-root",
        ":build-script",
        ":wardlink-scripts",
        ":systemd",
    ],
    extra_env_vars=["VERSION"],
    timeout=90,
    output_path="${target_name_normalized}${file_suffix}",
    output_files=["orbitlab-wardlink-*.tar.gz"],
)

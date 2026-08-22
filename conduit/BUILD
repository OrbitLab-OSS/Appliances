shell_source(name="download-script", source="download.sh")

shell_source(name="build-script", source="build.sh")

shell_sources(name="conduit-scripts", sources=["conduit*.sh"])

files(name="systemd", sources=["*.service", "*.network", "*.conf"])

shell_command(
    name="traefik",
    command="bash ./download.sh",
    tools=["bash", "curl", "mkdir", "tar", "gzip", "mv", "rm", "sha256sum"],
    execution_dependencies=[":download-script"],
    output_files=["traefik"],
)

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
        ":traefik",
        ":conduit-scripts",
        ":systemd",
    ],
    extra_env_vars=["VERSION"],
    timeout=90,
    output_path="${target_name_normalized}${file_suffix}",
    output_files=["orbitlab-conduit-*.tar.gz"],
)

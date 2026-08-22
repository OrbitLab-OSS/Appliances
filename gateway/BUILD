files(name="systemd", sources=["*.service", "*.conf", "*.preset"])

shell_source(name="build-script", source="build.sh")

shell_source(name="relay", source="relay.sh")

shell_source(name="gateway-init", source="gateway-init.sh")

package_shell_command(
    name="appliance",
    command="bash ./build.sh",
    tools=["bash", "sudo", "mkdir", "mountpoint"],
    execution_dependencies=[
        "//:common",
        "//:debian13-root",
        ":build-script",
        "coredns:coredns",
        ":relay",
        ":systemd",
        ":gateway-init",
    ],
    extra_env_vars=["VERSION"],
    timeout=60,
    output_path="${target_name_normalized}${file_suffix}",
    output_files=["orbitlab-gateway-*.tar.gz"],
)

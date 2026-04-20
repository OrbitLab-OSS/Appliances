files(name="systemd", sources=["*.service", "*.conf", "*.preset"])
shell_source(name="build-script", source="build.sh")
shell_source(name="dhcp-to-hosts", source="dhcp-to-hosts.sh")
shell_source(name="gateway-init", source="gateway-init.sh")

run_shell_command(
    name="build",
    command="CHROOT={chroot} bash ./build.sh",
    execution_dependencies=[
        "//:common",
        ":build-script",
        "coredns:coredns",
        ":dhcp-to-hosts",
        ":systemd",
        ":gateway-init",
    ],
)

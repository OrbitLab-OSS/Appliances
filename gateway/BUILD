files(name="systemd", sources=["*.service", "*.conf", "*.preset"])
shell_source(name="build-script", source="build.sh")
shell_source(name="download-coredns", source="coredns.sh")
shell_source(name="dhcp-to-hosts", source="dhcp-to-hosts.sh")
shell_source(name="sgwtool", source="sgwtool.sh")

shell_command(
    name="coredns",
    command="bash ./coredns.sh",
    tools=["bash", "wget", "tar", "gzip"],
    execution_dependencies=[":download-coredns"],
    output_files=["./coredns"],
    log_output=True,
)

run_shell_command(
    name="build",
    command="CHROOT={chroot} bash ./build.sh",
    execution_dependencies=[
        "//:common",
        ":build-script",
        ":coredns",
        ":dhcp-to-hosts",
        ":systemd",
        ":sgwtool",
    ],
)

files(name="systemd", sources=["*.service"])
shell_source(name="build-script", source="build.sh")
shell_source(name="download-coredns", source="coredns.sh")
shell_source(name="obd-tool", source="obd-tool.sh")

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
    execution_dependencies=["//:common", ":build-script", ":obd-tool", ":coredns", ":systemd"],
)

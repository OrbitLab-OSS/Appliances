shell_source(name="download-script", source="download.sh")
shell_source(name="build-script", source="build.sh")
shell_source(name="etcd-mgr", source="etcd-mgr.sh")
file(name="bootstrapper", source="etcd-bootstrap.service")

shell_command(
    name="etcd",
    command="bash ./download.sh",
    tools=["bash", "curl", "mkdir", "tar", "gzip", "mv", "rm"],
    execution_dependencies=[":download-script"],
    output_files=["etcd", "etcdctl", "etcdutl"],
    log_output=True,
)

run_shell_command(
    name="build",
    command="CHROOT={chroot} bash ./build.sh",
    execution_dependencies=["//:common", ":build-script", ":etcd", ":etcd-mgr", ":bootstrapper"],
)

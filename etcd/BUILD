shell_source(name="download-script", source="download.sh")

shell_source(name="build-script", source="build.sh")

shell_sources(name="etcd-scripts", sources=["etcd-*.sh"])

files(name="systemd", sources=["*.service"])

shell_command(
    name="etcd",
    command="bash ./download.sh",
    tools=["bash", "curl", "mkdir", "tar", "gzip", "mv", "rm"],
    execution_dependencies=[":download-script"],
    output_files=["etcd", "etcdctl", "etcdutl"],
)

package_shell_command(
    name="appliance",
    command="bash ./build.sh",
    tools=["bash", "sudo", "mkdir", "mountpoint"],
    execution_dependencies=[
        "//:common",
        "//:debian13-root",
        ":build-script",
        ":etcd",
        ":etcd-scripts",
        ":systemd",
    ],
    extra_env_vars=["VERSION"],
    timeout=60,
    output_path="${target_name_normalized}${file_suffix}",
    output_files=["orbitlab-etcd-*.tar.gz"],
)

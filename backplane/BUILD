files(name="systemd", sources=["*.service"])

shell_source(name="build-script", source="build.sh")

shell_source(name="backplane-init", source="backplane-init.sh")

python_sources(name="src")

python_requirement(
    name="requirements",
    requirements=[
        "redis==7.4.0",
        "starlette==0.40.0",
        "uvicorn"
    ],
)

pex_binary(
    name="orbital-relay",
    entry_point="backplane.orbital_relay:main",
    dependencies=[":requirements", ":src"],
    interpreter_constraints=[">=3.13"]
)

package_shell_command(
    name="appliance",
    command="bash ./build.sh",
    tools=["bash", "sudo", "mkdir", "mountpoint"],
    execution_dependencies=[
        "//:common",
        "//:debian13-root",
        "coredns:coredns",
        ":orbital-relay",
        ":build-script",
        ":backplane-init",
        ":systemd",
    ],
    extra_env_vars=["VERSION"],
    timeout=60,
    output_path="${target_name_normalized}${file_suffix}",
    output_files=["orbitlab-backplane-*.tar.gz"],
)

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
    entry_point="relay.orbital_relay:main",
    dependencies=[":requirements", ":src"],
    interpreter_constraints=[">=3.13"]
)

run_shell_command(
    name="build",
    command="CHROOT={chroot} bash ./build.sh",
    execution_dependencies=["//:common", "coredns:coredns", ":orbital-relay", ":build-script", ":backplane-init", ":systemd"],
)

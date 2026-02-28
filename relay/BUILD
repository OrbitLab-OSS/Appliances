python_requirement(
    name="requirements",
    requirements=[
        "httpx==0.28.1",
        "starlette==0.40.0",
    ],
)

python_sources(name="src")

pex_binary(
    name="orbital-relay",
    entry_point="orbital_relay:main",
    dependencies=[":requirements"],
    interpreter_constraints=[">=3.13"]
)

files(name="systemd", sources=["*.service"])

run_shell_command(
    name="build",
    command="CHROOT={chroot} bash ./build.sh",
    execution_dependencies=[
        "//:common",
        ":orbital-relay",
        ":systemd",
    ],
)

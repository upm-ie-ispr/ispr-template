import argparse
import json
from pathlib import Path
import shutil
import subprocess
from typing import Optional
import warnings

import vitis
from proto.build_pb2 import BuildResponse

TEMPLATE_DIR = Path(__file__).resolve().parent / 'assets' / 'vitis'
MAILBOX_CORE_FILES = ('mailbox.c', 'mailbox.h')
MAILBOX_USER_FILES = ('mailbox_user.c', 'mailbox_user.h')
MAILBOX_GENERATED_ENTRIES = {
    'build', 'Debug', 'Release', 'export', '.cache', 'compile_commands.json',
    'vitis-comp.json',
}


def check_build_status(name: str, status: int) -> None:
    if status != BuildResponse.SUCCESS:
        raise RuntimeError(f"Vitis build failed for '{name}' (status: {status})")


def apply_patch(target: Path, patch_file: Path, patch_command: str) -> None:
    for dry_run in (True, False):
        command = [patch_command, '--batch', '--forward', '--fuzz=0']
        if dry_run:
            command.append('--dry-run')
        command.append(str(target))
        with patch_file.open('rb') as patch:
            subprocess.run(command, stdin=patch, check=True)


def configure_mailbox(app, config: Path, mailbox_name: str) -> None:
    mailbox_dir = f'${{CMAKE_SOURCE_DIR}}/../../{mailbox_name}'
    app.set_app_config(key='USER_INCLUDE_DIRECTORIES', values=[mailbox_dir])
    app.set_app_config(key='USER_LINK_LIBRARIES', values=[mailbox_name])
    app.set_app_config(key='USER_LINK_DIRECTORIES', values=[f'{mailbox_dir}/build'])

    # The generated -l option does not make the app relink when the archive changes.
    with config.open('a') as f:
        f.write(f"""
if(NOT TARGET _vitis_mailbox_link_dependency)
    add_library(_vitis_mailbox_link_dependency INTERFACE)
    set_property(TARGET _vitis_mailbox_link_dependency PROPERTY INTERFACE_LINK_DEPENDS
        "{mailbox_dir}/build/lib{mailbox_name}.a")
    link_libraries(_vitis_mailbox_link_dependency)
endif()
""")


def restore_mailbox_files(backup: Path, destination: Path) -> None:
    def ignore_generated(directory, names):
        ignored = {'compile_commands.json'}
        if Path(directory) == backup:
            ignored.update(MAILBOX_GENERATED_ENTRIES)
        return ignored.intersection(names)

    shutil.copytree(backup, destination, dirs_exist_ok=True, symlinks=True, ignore=ignore_generated)


def previous_mailbox_bsp(backup: Path, workspace: Path) -> Optional[Path]:
    metadata = backup / 'vitis-comp.json'
    if metadata.is_file():
        component = json.loads(metadata.read_text())
        platform = component.get('platform')
        domain = component.get('domainRealName') or component.get('domain')
        if (isinstance(platform, str) and platform and Path(platform).name == platform
                and isinstance(domain, str) and domain and Path(domain).name == domain):
            return (workspace / platform / 'export' / platform / 'sw' / domain / 'include').resolve()
    warnings.warn(f'Cannot determine the previous mailbox BSP from {metadata}; '
                  'preserving its include paths and adding the current BSP', RuntimeWarning)
    return None


def resolve_cmake_directory(value: str, source_dir: Path) -> Optional[Path]:
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
    for variable in ('${CMAKE_SOURCE_DIR}', '${CMAKE_CURRENT_SOURCE_DIR}'):
        value = value.replace(variable, str(source_dir))
    if '$' in value:
        return None
    return (source_dir / value).resolve()


def update_mailbox_bsp(mailbox, backup: Path, workspace: Path, mailbox_name: str, bsp_include: Path) -> None:
    previous_bsp = previous_mailbox_bsp(backup, workspace)
    current_bsp = bsp_include.resolve()
    source_dir = workspace / mailbox_name / 'src'
    old_directories = list(mailbox.get_app_config(key='USER_INCLUDE_DIRECTORIES'))
    directories = []
    current_present = False
    for directory in old_directories:
        resolved = resolve_cmake_directory(directory, source_dir)
        if resolved == current_bsp:
            current_present = True
        elif previous_bsp is not None and resolved == previous_bsp:
            directory = str(bsp_include)
            current_present = True
        directories.append(directory)
    if not current_present:
        directories.append(str(bsp_include))
    if directories != old_directories:
        mailbox.set_app_config(key='USER_INCLUDE_DIRECTORIES', values=directories)


def configure_mailbox_sources(mailbox, directory: Path, restore_settings: bool) -> None:
    for key, filenames in (
        ('USER_COMPILE_SOURCES', ('mailbox.c', 'mailbox_user.c')),
        ('USER_HEADER_SOURCES', ('mailbox.h', 'mailbox_user.h')),
    ):
        existing = list(mailbox.get_app_config(key=key)) if restore_settings else []
        values = existing.copy()
        resolved = {resolve_cmake_directory(value, directory / 'src') for value in existing}
        for filename in filenames:
            if (directory / filename).resolve() not in resolved:
                values.append(f'../{filename}')
        if not restore_settings or values != existing:
            mailbox.set_app_config(key=key, values=values)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', required=True)
    parser.add_argument('--hw-design', required=True, help='XSA path')
    parser.add_argument('--os', default='standalone')
    parser.add_argument('--cpus', nargs='+', required=True, help='One or two CPU names, one domain and one app per CPU')
    parser.add_argument('--app-prefix', required=True, help='Apps are named <prefix>-cpu<N>')
    parser.add_argument('--workspace', default='workspace')
    parser.add_argument('--template', default='hello_world')
    parser.add_argument('--mailbox', action='store_true', help='Create and link the mailbox library (two CPUs only)')
    parser.add_argument('--mailbox-backup', type=Path, help='Restore a mailbox component before building it')
    args = parser.parse_args()

    if len(args.cpus) > 2:
        parser.error('At most two CPUs are supported by the mailbox and linker templates')

    multicore = len(args.cpus) > 1
    mailbox_backup = args.mailbox_backup.resolve() if args.mailbox_backup is not None else None
    use_mailbox = args.mailbox or mailbox_backup is not None
    if use_mailbox and not multicore:
        parser.error('Mailbox support requires two CPUs')
    if mailbox_backup is not None:
        if not mailbox_backup.is_dir():
            parser.error(f'Mailbox backup is not a directory: {mailbox_backup}')

    patch_command = shutil.which('patch') if multicore else None
    if multicore:
        if patch_command is None:
            parser.error("Multi-core generation requires the 'patch' command")
        templates = ['cpu0_lscript.ld.patch', 'cpu1_lscript.ld.patch']
        if use_mailbox:
            templates.extend((*MAILBOX_CORE_FILES, *MAILBOX_USER_FILES))
        for filename in templates:
            if not (TEMPLATE_DIR / filename).is_file():
                parser.error(f'Missing Vitis template: {TEMPLATE_DIR / filename}')

    workspace = Path(args.workspace).resolve()
    client = vitis.create_client()
    client.set_workspace(path=str(workspace))

    # Create platform and domains.
    platform = client.create_platform_component(name=args.platform, hw_design=args.hw_design, no_boot_bsp=True)
    domains = []
    for cpu in args.cpus:
        domain_name = f'{args.os}_{cpu}'
        platform.add_domain(cpu=cpu, os=args.os, name=domain_name)
        domains.append(domain_name)
    check_build_status(args.platform, platform.build())

    xpfm = str(workspace / args.platform / 'export' / args.platform / f'{args.platform}.xpfm')
    if use_mailbox:
        mailbox_name = f'{args.app_prefix}-mailbox'
        mailbox = client.create_library_component(name=mailbox_name, platform=xpfm, domain=domains[0])
        bsp_include = workspace / args.platform / 'export' / args.platform / 'sw' / domains[0] / 'include'
        mailbox_dir = workspace / mailbox_name
        if mailbox_backup is not None:
            restore_mailbox_files(mailbox_backup, mailbox_dir)
        files: list[str] = list(MAILBOX_CORE_FILES)
        files.extend(filename for filename in MAILBOX_USER_FILES if not (mailbox_dir / filename).is_file())
        mailbox.import_files(from_loc=str(TEMPLATE_DIR), files=files)
        restore_settings = mailbox_backup is not None and (mailbox_backup / 'src' / 'UserConfig.cmake').is_file()
        configure_mailbox_sources(mailbox, mailbox_dir, restore_settings)
        if mailbox_backup is not None and restore_settings:
            update_mailbox_bsp(mailbox, mailbox_backup, workspace, mailbox_name, bsp_include)
        else:
            mailbox.set_app_config(key='USER_INCLUDE_DIRECTORIES', values=[str(bsp_include)])
        check_build_status(mailbox_name, mailbox.build())

    for i, domain_name in enumerate(domains):
        app_name = f'{args.app_prefix}-cpu{i}'
        app = client.create_app_component(name=app_name, platform=xpfm, domain=domain_name, template=args.template)
        if multicore and patch_command is not None:
            src = workspace / app_name / 'src'
            apply_patch(src / 'lscript.ld', TEMPLATE_DIR / f'cpu{i}_lscript.ld.patch', patch_command)
            if use_mailbox:
                configure_mailbox(app, src / 'UserConfig.cmake', mailbox_name)
        check_build_status(app_name, app.build())

    if multicore:
        # System project so both apps can run simultaneously.
        sys_proj = client.create_sys_project(name=args.app_prefix, platform=xpfm)
        for i in range(len(domains)):
            sys_proj.add_component(name=f'{args.app_prefix}-cpu{i}')


if __name__ == '__main__':
    main()

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, call, patch


ROOT = Path(__file__).resolve().parents[2]
TEMPLATES = ROOT / 'assets' / 'vitis'
USER_CONFIG = '''cmake_minimum_required(VERSION 3.16)
enable_language(C ASM CXX)
set(USER_INCLUDE_DIRECTORIES
)
set(USER_LINK_LIBRARIES
)
set(USER_LINK_DIRECTORIES
)
'''
LSCRIPT = '''MEMORY
{
	ps7_ddr_0_memory_0 : ORIGIN = 0x100000, LENGTH = 0x1ff00000
	ps7_qspi_linear_0_memory_0 : ORIGIN = 0xfc000000, LENGTH = 0x1000000
	ps7_ram_0_memory_0 : ORIGIN = 0x0, LENGTH = 0x30000
	ps7_ram_1_memory_1 : ORIGIN = 0xffff0000, LENGTH = 0xfe00
}
'''
DDR_ORIGIN = {'0': '0x00100000', '1': '0x10000000'}

vitis = types.ModuleType('vitis')
build_pb2 = types.ModuleType('proto.build_pb2')
setattr(build_pb2, 'BuildResponse', types.SimpleNamespace(SUCCESS=0))
spec = importlib.util.spec_from_file_location('vitis_builder', ROOT / 'vitis_builder.py')
assert spec is not None and spec.loader is not None
builder = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'vitis': vitis, 'proto.build_pb2': build_pb2}):
    spec.loader.exec_module(builder)


class VitisBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name) / 'workspace with spaces'
        self.events = []
        self.apps = {}
        self.platform = Mock()
        self.platform.build.return_value = 0
        self.mailbox = Mock()
        self.mailbox.build.side_effect = self.build_mailbox
        self.client = Mock()
        self.client.create_platform_component.return_value = self.platform
        self.client.create_library_component.side_effect = self.create_mailbox
        self.client.create_app_component.side_effect = self.create_app
        self.client.set_workspace.side_effect = lambda path: Path(path).mkdir(parents=True)
        self.client.create_sys_project.return_value = Mock()
        self.addCleanup(patch.stopall)
        patch.object(builder.vitis, 'create_client', Mock(return_value=self.client), create=True).start()
        self.config = USER_CONFIG
        self.lscript = LSCRIPT
        self.mailbox_sources = TEMPLATES
        self.mailbox_config = {
            'USER_COMPILE_SOURCES': ['"../mailbox.c"', '"../mailbox_user.c"'],
            'USER_HEADER_SOURCES': ['"../mailbox.h"', '"../mailbox_user.h"'],
        }
        self.mailbox.get_app_config.side_effect = lambda key: self.mailbox_config[key]

    def create_mailbox(self, **kwargs):
        self.mailbox_name = kwargs['name']
        directory = self.workspace / self.mailbox_name
        (directory / 'src').mkdir(parents=True)
        (directory / 'src/UserConfig.cmake').write_text('fresh configuration\n')
        (directory / 'vitis-comp.json').write_text('fresh component metadata\n')
        self.mailbox.import_files.side_effect = lambda from_loc, files: [
            shutil.copyfile(Path(from_loc) / filename, directory / filename)
            for filename in files
        ]
        return self.mailbox

    def build_mailbox(self):
        directory = self.workspace / self.mailbox_name
        for filename in ('mailbox.c', 'mailbox.h', 'mailbox_user.c', 'mailbox_user.h'):
            source = self.mailbox_sources / filename if filename.startswith('mailbox_user') else TEMPLATES / filename
            if not source.is_file():
                source = TEMPLATES / filename
            self.assertEqual((directory / filename).read_bytes(), source.read_bytes())
        build = directory / 'build'
        build.mkdir()
        (build / f'lib{self.mailbox_name}.a').touch()
        self.events.append(self.mailbox_name)
        return 0

    def create_app(self, **kwargs):
        name = kwargs['name']
        src = self.workspace / name / 'src'
        src.mkdir(parents=True)
        (src / 'UserConfig.cmake').write_text(self.config)
        (src / 'lscript.ld').write_text(self.lscript)
        app = Mock()
        app.build.side_effect = lambda: self.build_app(name)
        self.apps[name] = app
        return app

    def build_app(self, name):
        src = self.workspace / name / 'src'
        if self.multicore:
            index = name.rsplit('-cpu', 1)[1]
            self.assertEqual((src / 'lscript.ld').read_text(), LSCRIPT.replace(
                'ORIGIN = 0x100000, LENGTH = 0x1ff00000',
                f'ORIGIN = {DDR_ORIGIN[index]}, LENGTH = 0x0ff00000').replace(
                'LENGTH = 0xfe00\n}', 'LENGTH = 0xfe00\n'
                '\tps7_ddr_0_shared : ORIGIN = 0x1ff00000, LENGTH = 0x00100000\n}'))
        else:
            self.assertEqual((src / 'lscript.ld').read_text(), LSCRIPT)
        if self.use_mailbox:
            mailbox = '${CMAKE_SOURCE_DIR}/../../lab-test-mailbox'
            self.assertEqual(self.apps[name].set_app_config.call_args_list, [
                call(key='USER_INCLUDE_DIRECTORIES', values=[mailbox]),
                call(key='USER_LINK_LIBRARIES', values=['lab-test-mailbox']),
                call(key='USER_LINK_DIRECTORIES', values=[f'{mailbox}/build']),
            ])
            config = (src / 'UserConfig.cmake').read_text()
            self.assertTrue(config.startswith(USER_CONFIG))
            self.assertIn('PROPERTY INTERFACE_LINK_DEPENDS\n'
                          f'        "{mailbox}/build/liblab-test-mailbox.a")', config)
            self.assertIn('link_libraries(_vitis_mailbox_link_dependency)', config)
            self.assertEqual(self.events[0], 'lab-test-mailbox')
        else:
            self.assertEqual((src / 'UserConfig.cmake').read_text(), USER_CONFIG)
            self.apps[name].set_app_config.assert_not_called()
        self.events.append(name)
        return 0

    def run_builder(self, cpus, mailbox_backup=None, mailbox=False):
        self.multicore = len(cpus) > 1
        self.use_mailbox = mailbox or mailbox_backup is not None
        arguments = ['vitis_builder.py', '--platform', 'custom_platform',
                     '--hw-design', 'design.xsa', '--app-prefix', 'lab-test',
                     '--workspace', str(self.workspace), '--cpus', *cpus]
        if mailbox_backup is not None:
            arguments.extend(['--mailbox-backup', str(mailbox_backup)])
        if mailbox:
            arguments.append('--mailbox')
        with patch.object(sys, 'argv', arguments):
            builder.main()

    def test_vitis_assets_use_relocated_directory(self):
        self.assertEqual(builder.TEMPLATE_DIR, ROOT / 'assets' / 'vitis')
        for filename in ('cpu0_lscript.ld.patch', 'cpu1_lscript.ld.patch',
                         'UserConfig.cmake.patch', 'mailbox.c', 'mailbox.h',
                         'mailbox_user.c', 'mailbox_user.h'):
            with self.subTest(filename=filename):
                self.assertTrue((builder.TEMPLATE_DIR / filename).is_file())

    def test_single_core_retains_configuration_and_skips_library_and_system(self):
        with patch.object(builder, 'TEMPLATE_DIR', self.workspace / 'missing-templates'):
            self.run_builder(['ps7_cortexa9_0'])
        self.client.create_library_component.assert_not_called()
        self.client.create_sys_project.assert_not_called()
        self.assertEqual(self.events, ['lab-test-cpu0'])

    def test_multicore_builds_mailbox_before_configured_apps_and_creates_system(self):
        self.run_builder(['ps7_cortexa9_0', 'ps7_cortexa9_1'], mailbox=True)
        xpfm = str(self.workspace / 'custom_platform/export/custom_platform/custom_platform.xpfm')
        self.client.create_library_component.assert_called_once_with(
            name='lab-test-mailbox', platform=xpfm, domain='standalone_ps7_cortexa9_0')
        self.mailbox.set_app_config.assert_any_call(
            key='USER_COMPILE_SOURCES', values=['../mailbox.c', '../mailbox_user.c'])
        self.mailbox.set_app_config.assert_any_call(
            key='USER_HEADER_SOURCES', values=['../mailbox.h', '../mailbox_user.h'])
        include = self.workspace / 'custom_platform/export/custom_platform/sw/standalone_ps7_cortexa9_0/include'
        self.mailbox.set_app_config.assert_any_call(key='USER_INCLUDE_DIRECTORIES', values=[str(include)])
        self.assertEqual(self.events, ['lab-test-mailbox', 'lab-test-cpu0', 'lab-test-cpu1'])
        self.client.create_sys_project.assert_called_once_with(name='lab-test', platform=xpfm)
        system = self.client.create_sys_project.return_value
        self.assertEqual([call.kwargs['name'] for call in system.add_component.call_args_list],
                         ['lab-test-cpu0', 'lab-test-cpu1'])

    def test_multicore_without_mailbox_still_patches_linkers_and_creates_system(self):
        with tempfile.TemporaryDirectory() as directory:
            templates = Path(directory)
            for filename in ('cpu0_lscript.ld.patch', 'cpu1_lscript.ld.patch'):
                shutil.copyfile(TEMPLATES / filename, templates / filename)
            with patch.object(builder, 'TEMPLATE_DIR', templates):
                self.run_builder(['cpu0', 'cpu1'])
        self.client.create_library_component.assert_not_called()
        self.assertEqual(self.events, ['lab-test-cpu0', 'lab-test-cpu1'])
        self.client.create_sys_project.assert_called_once()
        system = self.client.create_sys_project.return_value
        self.assertEqual([entry.kwargs['name'] for entry in system.add_component.call_args_list],
                         ['lab-test-cpu0', 'lab-test-cpu1'])

    def test_explicit_mailbox_is_rejected_for_single_core(self):
        with self.assertRaises(SystemExit):
            self.run_builder(['cpu0'], mailbox=True)
        builder.vitis.create_client.assert_not_called()

    def test_existing_mailbox_sources_and_settings_are_restored_before_build(self):
        backup = Path(self.temporary.name) / 'mailbox backup'
        (backup / 'src').mkdir(parents=True)
        (backup / 'extra').mkdir()
        (backup / 'build').mkdir()
        (backup / 'mailbox.c').write_text('custom mailbox implementation\n')
        (backup / 'mailbox.h').write_text('custom mailbox header\n')
        (backup / 'mailbox_user.c').write_text('custom user implementation\n')
        (backup / 'mailbox_user.h').write_text('custom user header\n')
        (backup / 'extra/helper.c').write_text('custom additional source\n')
        (backup / 'src/UserConfig.cmake').write_text('custom build settings\n')
        (backup / 'src/CMakeLists.txt').write_text('custom build rules\n')
        (backup / 'vitis-comp.json').write_text(json.dumps({
            'platform': 'old_platform', 'domainRealName': 'standalone_cpu0'}))
        (backup / 'build/old-object.o').write_text('stale build output\n')
        (backup / 'compile_commands.json').write_text('stale compilation database\n')
        self.mailbox_sources = backup
        self.mailbox_config['USER_INCLUDE_DIRECTORIES'] = [
            '"../../old_platform/export/old_platform/sw/standalone_cpu0/include"',
            '"../extra"',
        ]

        self.run_builder(['cpu0', 'cpu1'], mailbox_backup=backup)

        directory = self.workspace / 'lab-test-mailbox'
        self.assertEqual((directory / 'extra/helper.c').read_text(), 'custom additional source\n')
        self.assertEqual((directory / 'src/UserConfig.cmake').read_text(), 'custom build settings\n')
        self.assertEqual((directory / 'src/CMakeLists.txt').read_text(), 'custom build rules\n')
        self.assertEqual((directory / 'vitis-comp.json').read_text(), 'fresh component metadata\n')
        self.assertFalse((directory / 'build/old-object.o').exists())
        self.assertFalse((directory / 'compile_commands.json').exists())
        self.mailbox.import_files.assert_called_once_with(
            from_loc=str(TEMPLATES), files=['mailbox.c', 'mailbox.h'])
        bsp_include = self.workspace / 'custom_platform/export/custom_platform/sw/standalone_cpu0/include'
        self.mailbox.set_app_config.assert_called_once_with(
            key='USER_INCLUDE_DIRECTORIES', values=[str(bsp_include), '"../extra"'])
        self.assertEqual(self.events, ['lab-test-mailbox', 'lab-test-cpu0', 'lab-test-cpu1'])

    def test_mailbox_backup_without_configuration_uses_default_settings(self):
        backup = Path(self.temporary.name) / 'mailbox backup'
        backup.mkdir()
        for filename in ('mailbox.c', 'mailbox.h'):
            (backup / filename).write_text(f'custom {filename}\n')
        self.mailbox_sources = backup

        self.run_builder(['cpu0', 'cpu1'], mailbox_backup=backup)

        self.mailbox.set_app_config.assert_any_call(
            key='USER_COMPILE_SOURCES', values=['../mailbox.c', '../mailbox_user.c'])
        self.mailbox.set_app_config.assert_any_call(
            key='USER_HEADER_SOURCES', values=['../mailbox.h', '../mailbox_user.h'])

    def test_existing_current_bsp_include_is_not_duplicated(self):
        backup = Path(self.temporary.name) / 'mailbox backup'
        (backup / 'src').mkdir(parents=True)
        for filename in ('mailbox.c', 'mailbox.h'):
            (backup / filename).write_text(f'custom {filename}\n')
        (backup / 'src/UserConfig.cmake').write_text('custom build settings\n')
        (backup / 'vitis-comp.json').write_text(json.dumps({
            'platform': 'custom_platform', 'domainRealName': 'standalone_cpu0'}))
        self.mailbox_sources = backup
        self.mailbox_config['USER_INCLUDE_DIRECTORIES'] = [
            '"${CMAKE_SOURCE_DIR}/../../custom_platform/export/custom_platform/sw/standalone_cpu0/include"',
            '"../extra"',
        ]

        self.run_builder(['cpu0', 'cpu1'], mailbox_backup=backup)

        self.mailbox.set_app_config.assert_not_called()

    def test_missing_component_metadata_preserves_custom_include_paths(self):
        backup = Path(self.temporary.name) / 'mailbox backup'
        (backup / 'src').mkdir(parents=True)
        for filename in ('mailbox.c', 'mailbox.h'):
            (backup / filename).write_text(f'custom {filename}\n')
        (backup / 'src/UserConfig.cmake').write_text('custom build settings\n')
        self.mailbox_sources = backup
        self.mailbox_config['USER_INCLUDE_DIRECTORIES'] = ['"../custom"']

        with self.assertWarnsRegex(RuntimeWarning, 'Cannot determine the previous mailbox BSP'):
            self.run_builder(['cpu0', 'cpu1'], mailbox_backup=backup)

        bsp_include = self.workspace / 'custom_platform/export/custom_platform/sw/standalone_cpu0/include'
        self.mailbox.set_app_config.assert_called_once_with(
            key='USER_INCLUDE_DIRECTORIES', values=['"../custom"', str(bsp_include)])

    def test_existing_source_lists_gain_user_files_without_losing_custom_sources(self):
        directory = self.workspace / 'lab-test-mailbox'
        self.mailbox_config['USER_COMPILE_SOURCES'] = ['"../mailbox.c"', '"../extra/helper.c"']
        self.mailbox_config['USER_HEADER_SOURCES'] = [
            '"${CMAKE_SOURCE_DIR}/../mailbox.h"', '"../extra/helper.h"']

        builder.configure_mailbox_sources(self.mailbox, directory, restore_settings=True)

        self.assertEqual(self.mailbox.set_app_config.call_args_list, [
            call(key='USER_COMPILE_SOURCES',
                 values=['"../mailbox.c"', '"../extra/helper.c"', '../mailbox_user.c']),
            call(key='USER_HEADER_SOURCES',
                 values=['"${CMAKE_SOURCE_DIR}/../mailbox.h"', '"../extra/helper.h"', '../mailbox_user.h']),
        ])

    def test_each_mailbox_template_is_required_before_workspace_creation(self):
        for missing in ('mailbox.c', 'mailbox.h', 'mailbox_user.c', 'mailbox_user.h'):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                templates = Path(directory)
                for source in TEMPLATES.iterdir():
                    if source.name != missing:
                        shutil.copyfile(source, templates / source.name)
                with patch.object(builder, 'TEMPLATE_DIR', templates):
                    with self.assertRaises(SystemExit):
                        self.run_builder(['cpu0', 'cpu1'], mailbox=True)
                builder.vitis.create_client.assert_not_called()

    def test_invalid_mailbox_backup_is_rejected_before_workspace_creation(self):
        backup = Path(self.temporary.name) / 'missing mailbox'
        with self.assertRaises(SystemExit):
            self.run_builder(['cpu0', 'cpu1'], mailbox_backup=backup)
        builder.vitis.create_client.assert_not_called()

    def test_legacy_mailbox_backup_gets_missing_user_templates(self):
        backup = Path(self.temporary.name) / 'incomplete mailbox'
        backup.mkdir()
        (backup / 'mailbox.c').write_text('custom implementation\n')
        self.mailbox_sources = backup
        self.run_builder(['cpu0', 'cpu1'], mailbox_backup=backup)
        self.mailbox.import_files.assert_called_once_with(
            from_loc=str(TEMPLATES),
            files=['mailbox.c', 'mailbox.h', 'mailbox_user.c', 'mailbox_user.h'])

    def test_mailbox_backup_is_rejected_for_single_core(self):
        backup = Path(self.temporary.name) / 'mailbox backup'
        backup.mkdir()
        with self.assertRaises(SystemExit):
            self.run_builder(['cpu0'], mailbox_backup=backup)
        builder.vitis.create_client.assert_not_called()

    def test_more_than_two_cpus_rejected_before_workspace_creation(self):
        with self.assertRaises(SystemExit) as error:
            self.run_builder(['cpu0', 'cpu1', 'cpu2'])
        self.assertEqual(error.exception.code, 2)
        builder.vitis.create_client.assert_not_called()

    def test_missing_template_rejected_before_workspace_creation(self):
        with patch.object(builder, 'TEMPLATE_DIR', self.workspace / 'missing-templates'):
            with self.assertRaises(SystemExit):
                self.run_builder(['cpu0', 'cpu1'])
        builder.vitis.create_client.assert_not_called()

    def test_missing_patch_command_rejected_only_for_multicore(self):
        with patch.object(builder.shutil, 'which', return_value=None):
            with self.assertRaises(SystemExit):
                self.run_builder(['cpu0', 'cpu1'])
        builder.vitis.create_client.assert_not_called()
        with patch.object(builder.shutil, 'which', return_value=None):
            self.run_builder(['cpu0'])

    def test_linker_patch_failure_leaves_script_unmodified_and_does_not_build(self):
        self.lscript = LSCRIPT.replace('0x1ff00000', '0x3ff00000')
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_builder(['cpu0', 'cpu1'])
        self.assertEqual((self.workspace / 'lab-test-cpu0/src/lscript.ld').read_text(), self.lscript)
        self.apps['lab-test-cpu0'].build.assert_not_called()
        self.apps['lab-test-cpu0'].set_app_config.assert_not_called()
        self.client.create_sys_project.assert_not_called()

    def test_platform_failure_stops_generation(self):
        self.platform.build.return_value = 1
        with self.assertRaisesRegex(RuntimeError, 'custom_platform'):
            self.run_builder(['cpu0'])
        self.client.create_app_component.assert_not_called()

    def test_mailbox_failure_stops_application_generation(self):
        self.mailbox.build.side_effect = None
        self.mailbox.build.return_value = 1
        with self.assertRaisesRegex(RuntimeError, 'lab-test-mailbox'):
            self.run_builder(['cpu0', 'cpu1'], mailbox=True)
        self.client.create_app_component.assert_not_called()
        self.client.create_sys_project.assert_not_called()

    def test_application_failure_stops_system_creation(self):
        with patch.object(self, 'build_app', return_value=1):
            with self.assertRaisesRegex(RuntimeError, 'lab-test-cpu0'):
                self.run_builder(['cpu0', 'cpu1'])
        self.client.create_sys_project.assert_not_called()


class MakeRestoreTests(unittest.TestCase):
    def test_more_than_two_cpus_rejected_before_workspace_cleanup(self):
        result = subprocess.run(
            ['make', '--no-print-directory', '-n', '-C', str(ROOT / 'tutorials/lab1/sw'),
             'app', 'CPU_NAMES=cpu0 cpu1 cpu2'],
            check=True, capture_output=True, text=True)
        guard = re.search(r'if \[ "3" -gt 2 \]; then \\\n.*?\nfi', result.stdout, re.DOTALL)
        self.assertIsNotNone(guard)
        assert guard is not None
        self.assertLess(guard.start(), result.stdout.index('rm -rf .tmp_backup'))
        self.assertLess(guard.start(), result.stdout.index('rm -rf "workspace"'))
        result = subprocess.run(['sh', '-c', guard.group()], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('At most two CPUs', result.stdout)

    def test_restoration_keeps_multicore_templates_but_restores_singlecore_config(self):
        for cpus in (['ps7_cortexa9_0'], ['ps7_cortexa9_0', 'ps7_cortexa9_1']):
            with self.subTest(cpus=cpus), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(
                    ['make', '--no-print-directory', '-n', '-C', str(ROOT / 'tutorials/lab1/sw'),
                     'app', f'CPU_NAMES={" ".join(cpus)}'],
                    check=True, capture_output=True, text=True)
                loops = re.findall(r'for app in [^\n]+; do \\\n.*?\ndone', result.stdout, re.DOTALL)
                self.assertEqual(len(loops), 2)
                workspace = Path(directory)
                for index in range(len(cpus)):
                    app = f'lab1-cpu{index}'
                    fresh = workspace / 'workspace' / app / 'src'
                    backup = workspace / '.tmp_backup' / app / 'src'
                    fresh.mkdir(parents=True)
                    backup.mkdir(parents=True)
                    for filename in ('UserConfig.cmake', 'lscript.ld'):
                        (fresh / filename).write_text('new template')
                        (backup / filename).write_text('old configuration')
                    (backup / 'helloworld.c').write_text('user application')
                    (backup / '.custom-settings').write_text('hidden user file')
                subprocess.run(['sh', '-c', loops[1]], cwd=workspace, check=True, capture_output=True)
                for index in range(len(cpus)):
                    src = workspace / 'workspace' / f'lab1-cpu{index}' / 'src'
                    backup = workspace / '.tmp_backup' / f'lab1-cpu{index}' / 'src'
                    for filename in ('UserConfig.cmake', 'lscript.ld'):
                        self.assertEqual((src / filename).read_text(),
                                         'new template' if len(cpus) > 1 else 'old configuration')
                        self.assertEqual((backup / filename).read_text(), 'old configuration')
                    self.assertEqual((src / 'helloworld.c').read_text(), 'user application')
                    self.assertEqual((src / '.custom-settings').read_text(), 'hidden user file')


FAKE_VITIS = '''#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('-s')
parser.add_argument('--platform')
parser.add_argument('--hw-design')
parser.add_argument('--os')
parser.add_argument('--cpus', nargs='+')
parser.add_argument('--app-prefix')
parser.add_argument('--workspace')
parser.add_argument('--mailbox', action='store_true')
parser.add_argument('--mailbox-backup')
args = parser.parse_args()
if os.environ.get('FAKE_VITIS_FAIL'):
    raise SystemExit(13)
workspace = Path(args.workspace)
workspace.mkdir(parents=True)
if args.mailbox or args.mailbox_backup:
    mailbox = workspace / f'{args.app_prefix}-mailbox'
    if args.mailbox_backup:
        shutil.copytree(args.mailbox_backup, mailbox,
                        ignore=shutil.ignore_patterns('build', '.cache', 'compile_commands.json',
                                                      'vitis-comp.json'))
    else:
        (mailbox / 'src').mkdir(parents=True)
        (mailbox / 'src/UserConfig.cmake').write_text('template settings')
    (mailbox / 'mailbox.c').write_text('template implementation')
    (mailbox / 'mailbox.h').write_text('template header')
    for filename in ('mailbox_user.c', 'mailbox_user.h'):
        if not (mailbox / filename).is_file():
            (mailbox / filename).write_text('template ' + filename)
    (mailbox / 'vitis-comp.json').write_text('new component metadata')
    (mailbox / 'build').mkdir()
    (mailbox / 'build' / f'lib{args.app_prefix}-mailbox.a').write_text(
        (mailbox / 'mailbox.c').read_text() + (mailbox / 'mailbox_user.c').read_text())
for index, cpu in enumerate(args.cpus):
    app = workspace / f'{args.app_prefix}-cpu{index}'
    (app / 'src').mkdir(parents=True)
    (app / 'src/UserConfig.cmake').write_text('new application configuration')
    (app / 'src/lscript.ld').write_text('new linker script')
    (app / 'src/helloworld.c').write_text('new application source')
    (app / '_ide').mkdir()
    (app / '_ide/launch.json').write_text('new launch config')
if len(args.cpus) > 1:
    (workspace / args.app_prefix / '_ide').mkdir(parents=True)
'''


class MakeAppMailboxTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.sw = root / 'tutorials/lab1/sw'
        self.sw.mkdir(parents=True)
        hardware = self.sw.parent / 'hw'
        hardware.mkdir()
        (hardware / 'lab1.xsa').touch()
        (self.sw / 'Makefile').write_text(f'include {ROOT / "vivado.mk"}\n')
        self.vitis = root / 'fake-vitis'
        self.vitis.write_text(FAKE_VITIS)
        self.vitis.chmod(0o755)
        self.workspace = self.sw / 'workspace with spaces'

    def run_make(self, cpus='cpu0 cpu1', env=None, mailbox=0):
        return subprocess.run(
            ['make', '--no-print-directory', '-C', str(self.sw), 'app',
             f'VITIS={self.vitis}', f'CPU_NAMES={cpus}', f'MAILBOX={mailbox}',
             'WORKSPACE_NAME=workspace with spaces'],
            capture_output=True, text=True, env=env)

    def create_mailbox(self):
        mailbox = self.workspace / 'lab1-mailbox'
        (mailbox / 'src').mkdir(parents=True)
        (mailbox / 'extra').mkdir()
        (mailbox / 'build').mkdir()
        (mailbox / '.cache').mkdir()
        (mailbox / 'mailbox.c').write_text('custom implementation')
        (mailbox / 'mailbox.h').write_text('custom header')
        (mailbox / 'mailbox_user.c').write_text('custom user implementation')
        (mailbox / 'mailbox_user.h').write_text('custom user header')
        (mailbox / 'extra/helper.c').write_text('custom extra source')
        (mailbox / 'src/UserConfig.cmake').write_text('custom build settings')
        (mailbox / '.editorconfig').write_text('custom editor settings')
        (mailbox / 'vitis-comp.json').write_text('old component metadata')
        (mailbox / 'build/stale.o').write_text('old object')
        (mailbox / '.cache/stale').write_text('old cache')
        (mailbox / 'compile_commands.json').write_text('old commands')
        return mailbox

    def test_existing_mailbox_and_application_sources_survive_regeneration(self):
        mailbox = self.create_mailbox()
        app = self.workspace / 'lab1-cpu0'
        (app / 'src').mkdir(parents=True)
        (app / '_ide').mkdir()
        (app / 'src/helloworld.c').write_text('existing application source')
        (app / 'src/UserConfig.cmake').write_text('old application configuration')
        (app / 'src/lscript.ld').write_text('old linker script')
        (app / '_ide/launch.json').write_text('existing launch config')

        result = self.run_make()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((mailbox / 'mailbox.c').read_text(), 'template implementation')
        self.assertEqual((mailbox / 'mailbox.h').read_text(), 'template header')
        self.assertEqual((mailbox / 'mailbox_user.c').read_text(), 'custom user implementation')
        self.assertEqual((mailbox / 'mailbox_user.h').read_text(), 'custom user header')
        self.assertEqual((mailbox / 'extra/helper.c').read_text(), 'custom extra source')
        self.assertEqual((mailbox / 'src/UserConfig.cmake').read_text(), 'custom build settings')
        self.assertEqual((mailbox / '.editorconfig').read_text(), 'custom editor settings')
        self.assertEqual((mailbox / 'vitis-comp.json').read_text(), 'new component metadata')
        self.assertEqual((mailbox / 'build/liblab1-mailbox.a').read_text(),
                         'template implementationcustom user implementation')
        self.assertFalse((mailbox / 'build/stale.o').exists())
        self.assertFalse((mailbox / '.cache/stale').exists())
        self.assertFalse((mailbox / 'compile_commands.json').exists())
        self.assertEqual((app / 'src/helloworld.c').read_text(), 'existing application source')
        self.assertEqual((app / 'src/UserConfig.cmake').read_text(), 'new application configuration')
        self.assertEqual((app / 'src/lscript.ld').read_text(), 'new linker script')
        self.assertEqual((app / '_ide/launch.json').read_text(), 'existing launch config')
        self.assertFalse((self.sw / '.tmp_backup').exists())

    def test_fresh_multicore_workspace_uses_template_mailbox(self):
        result = self.run_make(mailbox=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.workspace / 'lab1-mailbox/mailbox.c').read_text(),
                         'template implementation')
        for filename in ('mailbox_user.c', 'mailbox_user.h'):
            self.assertEqual((self.workspace / 'lab1-mailbox' / filename).read_text(),
                             f'template {filename}')

    def test_fresh_multicore_workspace_has_no_mailbox_by_default(self):
        result = self.run_make()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.workspace / 'lab1-mailbox').exists())
        self.assertTrue((self.workspace / 'lab1/_ide').is_dir())
        for index in (0, 1):
            self.assertTrue((self.workspace / f'lab1-cpu{index}/src/lscript.ld').is_file())

    def test_single_core_with_explicit_mailbox_stops_before_cleanup(self):
        self.workspace.mkdir()
        marker = self.workspace / 'user-file'
        marker.write_text('preserve')
        result = self.run_make(cpus='cpu0', mailbox=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Mailbox support requires two CPUs', result.stdout)
        self.assertEqual(marker.read_text(), 'preserve')
        self.assertFalse((self.sw / '.tmp_backup').exists())

    def test_invalid_mailbox_setting_stops_before_cleanup(self):
        self.workspace.mkdir()
        marker = self.workspace / 'user-file'
        marker.write_text('preserve')
        result = self.run_make(mailbox='yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MAILBOX must be 0 or 1', result.stdout)
        self.assertEqual(marker.read_text(), 'preserve')

    def test_single_core_with_existing_mailbox_stops_before_cleanup(self):
        mailbox = self.create_mailbox()
        result = self.run_make(cpus='cpu0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Single-core generation would remove the existing mailbox', result.stdout)
        self.assertEqual((mailbox / 'mailbox.c').read_text(), 'custom implementation')
        self.assertFalse((self.sw / '.tmp_backup').exists())

    def test_single_core_without_mailbox_still_succeeds(self):
        result = self.run_make(cpus='cpu0')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.workspace / 'lab1-cpu0/src/helloworld.c').is_file())
        self.assertFalse((self.workspace / 'lab1-mailbox').exists())

    def test_empty_cpu_list_stops_before_cleanup(self):
        mailbox = self.create_mailbox()
        result = self.run_make(cpus='')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('At least one CPU is required', result.stdout)
        self.assertEqual((mailbox / 'mailbox.c').read_text(), 'custom implementation')
        self.assertFalse((self.sw / '.tmp_backup').exists())

    def test_non_directory_mailbox_path_stops_before_cleanup(self):
        self.workspace.mkdir()
        mailbox = self.workspace / 'lab1-mailbox'
        mailbox.write_text('existing user file')
        result = self.run_make()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('mailbox path is not a directory', result.stdout)
        self.assertEqual(mailbox.read_text(), 'existing user file')
        self.assertFalse((self.sw / '.tmp_backup').exists())

    def test_failed_build_keeps_backup_and_retry_does_not_destroy_it(self):
        self.create_mailbox()
        env = os.environ.copy()
        env['FAKE_VITIS_FAIL'] = '1'

        result = self.run_make(env=env)
        backup = self.sw / '.tmp_backup/lab1-mailbox/mailbox.c'
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(backup.read_text(), 'custom implementation')
        self.assertFalse((backup.parent / 'build').exists())
        self.assertFalse((backup.parent / '.cache').exists())
        self.assertFalse((backup.parent / 'compile_commands.json').exists())
        self.assertTrue((backup.parent / 'vitis-comp.json').is_file())

        result = self.run_make()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('existing .tmp_backup', result.stdout)
        self.assertEqual(backup.read_text(), 'custom implementation')

    def test_failed_mailbox_backup_keeps_original_workspace(self):
        mailbox = self.create_mailbox()
        bin_dir = Path(self.temporary.name) / 'bin'
        bin_dir.mkdir()
        failing_cp = bin_dir / 'cp'
        failing_cp.write_text('#!/bin/sh\necho "simulated copy failure" >&2\nexit 1\n')
        failing_cp.chmod(0o755)
        env = os.environ.copy()
        env['PATH'] = f'{bin_dir}{os.pathsep}{env["PATH"]}'

        result = self.run_make(env=env)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('simulated copy failure', result.stderr)
        self.assertEqual((mailbox / 'mailbox.c').read_text(), 'custom implementation')


if __name__ == '__main__':
    unittest.main()

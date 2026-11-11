# Template repository for ISPR

## Vitis workspace generation

[vitis_builder.py](vitis_builder.py) creates one application per CPU, named
`<prefix>-cpu<N>`. With one CPU it creates neither a mailbox library nor a
system project, and retains the template's application configuration.

With two CPUs it always creates the `<prefix>` system project containing both
applications. Mailbox support is optional: pass `--mailbox` to create and link
`<prefix>-mailbox` on the first CPU's domain, or `--mailbox-backup <directory>`
to restore and link an existing mailbox. Neither is enabled by default.
Before building each application, it applies the corresponding
`cpu<N>_lscript.ld.patch` from [assets/vitis](assets/vitis)
to the generated `lscript.ld`, which only changes its `MEMORY` block. These
patches are applied even without a mailbox to avoid overlapping CPU memory.
When mailbox support is enabled, it configures the mailbox through the Vitis `set_app_config` API:
`USER_INCLUDE_DIRECTORIES`,
`USER_LINK_LIBRARIES` and `USER_LINK_DIRECTORIES`, with paths of the form
`${CMAKE_SOURCE_DIR}/../../<prefix>-mailbox` so the workspace stays relocatable.
Because the generated `-l` option does not track the archive, the builder also
appends a short block to `UserConfig.cmake` declaring the archive as a link
dependency, so rebuilding the mailbox relinks the applications. The mailbox
files are imported from that same directory into the library component's root:
`mailbox.c` and `mailbox.h` are the fixed implementation; `mailbox_user.c` and
`mailbox_user.h` are intended for user customization. Both `.c` files are built
into the library, and both headers are included in its header sources.

Run through the Vitis scripting environment, for example from a lab's `sw`
directory:

```sh
vitis -s ../../../vitis_builder.py \
    --platform system_wrapper --hw-design ../hw/lab1.xsa \
    --cpus ps7_cortexa9_0 ps7_cortexa9_1 --app-prefix lab1 --workspace workspace \
    --mailbox
```

For the Make workflow, use `make app MAILBOX=1` to add a new mailbox.
`make app` (or `MAILBOX=0`) does not add one to a fresh workspace, but if
`<prefix>-mailbox` already exists, it is automatically preserved, rebuilt and
linked regardless of `MAILBOX`. Mailbox support requires two CPUs.

The multi-core templates target the two Zynq Cortex-A9 cores and reserve the
last 1 MiB of DDR for the mailbox. More than two CPUs are rejected.
Multi-core generation requires the `patch` command; a linker patch that does
not apply cleanly stops generation before that application is configured or
built.

`make app` backs up an existing `<prefix>-mailbox` component and restores its
user source files and build settings before rebuilding the library. It always
refreshes `mailbox.c` and `mailbox.h` from assets, preserves existing
`mailbox_user.c` and `mailbox_user.h`, and supplies missing user files from the
templates. Existing source/header lists are extended to include all four files
without dropping additional sources. It regenerates
component metadata and build output, and updates the platform BSP include path
while retaining other include paths. Files outside the mailbox component are
not included in its backup; save any such files under the workspace separately.
Without an existing mailbox, the templates are used only when `MAILBOX=1`.

Existing application sources are restored after their initial build; rebuild
the applications to use those restored sources. For multi-core applications,
`make app` retains the new linker scripts and mailbox configuration rather
than restoring old copies. Single-core application configurations are
restored as before.

Single-core generation stops if a mailbox component already exists, so it
cannot be deleted accidentally. Back it up and remove it from the workspace
before switching to one CPU. If generation fails, `.tmp_backup` is retained
for recovery; move or recover it before running `make app` again.

When invoking the builder directly, `--mailbox-backup <directory>` restores a
previous mailbox for a multi-core workspace, with the same core refresh and
user-file preservation behavior. If that directory has no `src/UserConfig.cmake`,
the default library settings are used.

Run the builder regression tests without a running Vitis server:

```sh
python3 -B -m unittest discover -s assets/tests -v
```

The reference Zynq testbench is in [assets/tests/zynq_tb.v](assets/tests/zynq_tb.v).

## Mailbox configuration patch

The [Vitis UserConfig patch](assets/vitis/UserConfig.cmake.patch) adds the
mailbox include directory, library name, and library search directory to an
application component. It derives the library name from the application
directory: `<prefix>-cpu<N>` uses the sibling `<prefix>-mailbox` component.
The mailbox component must provide `mailbox.h` in its root and produce
`build/lib<prefix>-mailbox.a` for a compatible target. Build the library before
building the applications. With Ninja or Makefile generators, the patch also
tracks the archive as a link dependency, so rebuilding it causes the
applications to relink.

From the repository root, apply the patch to each newly generated application
configuration that needs the library. For example, for an unconfigured
`lab1-cpu1`:

```sh
config="tutorials/lab1/sw/workspace/lab1-cpu1/src/UserConfig.cmake"
patch --batch --forward --fuzz=0 --dry-run "$config" < assets/vitis/UserConfig.cmake.patch &&
    patch --batch --forward --fuzz=0 "$config" < assets/vitis/UserConfig.cmake.patch
```

The patch expects the generated configuration format and the three
corresponding settings to be empty. If they already contain values, merge the
changes manually instead of overwriting them. The dry run also prevents
applying the patch twice. The Vitis 2025.1
application `CMakeLists.txt` generated in this workspace does not handle
multiple `USER_LINK_DIRECTORIES` entries correctly; projects with existing
library search paths need their linker configuration adjusted separately.

The builder does not use this patch; it applies the equivalent settings through
the Vitis API. The patch is kept for adding the mailbox to an existing
application by hand. Applying it does not create or build the mailbox component.

"""# Public API for Jest rules
"""

load("@aspect_bazel_lib//lib:write_source_files.bzl", _write_source_files = "write_source_files")
load("@aspect_bazel_lib//lib:utils.bzl", "default_timeout", "to_label")
load("@aspect_bazel_lib//lib:output_files.bzl", _output_files = "output_files")
load("@aspect_rules_js//js:defs.bzl", _js_run_binary = "js_run_binary")
load("@aspect_rules_js//js:libs.bzl", "js_binary_lib")
load("//jest/private:jest_test.bzl", "lib")

_jest_test = rule(
    attrs = lib.attrs,
    implementation = lib.implementation,
    test = True,
    toolchains = js_binary_lib.toolchains,
)

# binary rule used for snapshot updates
_jest_binary = rule(
    attrs = lib.attrs,
    implementation = lib.implementation,
    executable = True,
    toolchains = js_binary_lib.toolchains,
)

REFERENCE_SNAPSHOT_SUFFIX = "-out"
REFERENCE_SNAPSHOT_DIRECTORY = "out"

REFERENCE_BUILD_TARGET_SUFFIX = "_ref_snapshots"
UPDATE_SNAPSHOTS_TARGET_SUFFIX = "_update_snapshots"

def _jest_from_repository(jest_rule, jest_repository, **kwargs):
    jest_rule(
        enable_runfiles = select({
            "@aspect_rules_js//js/private:enable_runfiles": True,
            "//conditions:default": False,
        }),
        entry_point = "@{}//:jest_entrypoint".format(jest_repository),
        bazel_sequencer = "@{}//:bazel_sequencer".format(jest_repository),
        bazel_snapshot_reporter = "@{}//:bazel_snapshot_reporter".format(jest_repository),
        bazel_snapshot_resolver = "@{}//:bazel_snapshot_resolver".format(jest_repository),
        data = kwargs.pop("data", []) + [
            "@{}//:node_modules/@jest/test-sequencer".format(jest_repository),
            "@{}//:node_modules/jest-cli".format(jest_repository),
            "@{}//:node_modules/jest-junit".format(jest_repository),
            "@{}//:node_modules/jest-snapshot".format(jest_repository),
        ],
        jest_repository = jest_repository,
        testonly = True,
        **kwargs
    )

def jest_test(
        name,
        config = None,
        data = [],
        snapshots = False,
        run_in_band = True,
        colors = True,
        auto_configure_reporters = True,
        auto_configure_test_sequencer = True,
        snapshots_ext = ".snap",
        quiet_snapshot_updates = False,
        jest_repository = "jest",
        tags = [],
        timeout = None,
        size = None,
        **kwargs):
    """jest_test rule

    Supports Bazel sharding. See https://docs.bazel.build/versions/main/test-encyclopedia.html#test-sharding.

    Supports updating snapshots with `bazel run {name}_update_snapshots` if `snapshots` are specified.

    Args:
        name: A unique name for this target.

        config: "Optional Jest config file. See https://jestjs.io/docs/configuration.

            Supported config file types are ".js", ".cjs", ".mjs", ".json" which come from https://jestjs.io/docs/configuration
            minus TypeScript since we this rule extends from the configuration. TypeScript jest configs should be transpiled
            before being passed to jest_test with [rules_ts](https://github.com/aspect-build/rules_ts).

        data: Runtime dependencies of the Jest test.

            This should include all test files, configuration files & files under test.

        snapshots: If True, a `{name}_update_snapshots` binary target is generated that will update all existing `__snapshots__`
            directories when `bazel run`. This is the equivalent to running `jest -u` or `jest --updateSnapshot` outside of Bazel,
            except that new `__snapshots__` will not automatically be created on update. To bootstrap a new `__snapshots__` directory,
            you can create an empty one and then run the `{name}_update_snapshots` target to populate it.

            If the name of the snapshot directory is not the default `__snapshots__` because of a custom snapshot resolver,
            you can specify customize the snapshot directories with a `glob` or a static list. For example,

            ```
            jest_test(
                name = "test",
                config = "jest.config.js",
                data = [
                    "greetings/greetings.js",
                    "greetings/greetings.test.js",
                    "link/link.js",
                    "link/link.test.js",
                ],
                snapshots = glob(["**/__snaps__"], exclude_directories = 0),
            )
            ```

            or with a static list,

            ```
                snapshots = [
                    "greetings/__greetings_snaps__",
                    "link/__link_snaps__",
                ]
            ```

            Snapshots directories must not contain any files except for snapshots. There must also be no BUILD files in
            the snapshots directories since they must be part of the same Bazel package that the `jest_test` target is in.

            If snapshots are _not_ configured to output to a directory that contains only snapshots, you may alternately
            set `snapshots` to a list of snapshot files expected to be generated by this `jest_test` target.
            These must be source files and all snapshots that are generated must be explicitly listed. You may use a
            `glob` such as `glob(["**/*.snap"])` to generate this list, in which case all snapshots must already be on
            disk so they are discovered by `glob`.

        run_in_band: When True, the `--runInBand` argument is passed to the Jest CLI so that all tests are run serially
            in the current process, rather than creating a worker pool of child processes that run tests. See
            https://jestjs.io/docs/cli#--runinband for more info.

            This is the desired default behavior under Bazel since Bazel expect each test process to use up one CPU core.
            To parallelize a single jest_test across many cores, use `shard_count` instead which is supported by `jest_test`.
            See https://docs.bazel.build/versions/main/test-encyclopedia.html#test-sharding.

        colors: When True, the `--colors` argument is passed to the Jest CLI. See https://jestjs.io/docs/cli#--colors.

        auto_configure_reporters: Let jest_test configure reporters for Bazel test and xml test logs.

            The `default` reporter is used for the standard test log and `jest-junit` is used for the xml log.
            These reporters are appended to the list of reporters from the user Jest `config` only if they are
            not already set.

            The `JEST_JUNIT_OUTPUT_FILE` environment variable is always set to where Bazel expects a test runner
            to write its xml test log so that if `jest-junit` is configured in the user Jest `config` it will output
            the junit xml file where Bazel expects by default.

        auto_configure_test_sequencer: Let jest_test configure a custom test sequencer for Bazel test that support Bazel sharding.

            Any custom testSequencer value in a user Jest `config` will be overridden.

            See https://jestjs.io/docs/configuration#testsequencer-string for more information on Jest testSequencer config option.

        snapshots_ext: The expected extensions for snapshot files. Defaults to `.snap`, the Jest default.

        quiet_snapshot_updates: When True, snapshot update stdout & stderr is hidden when the snapshot update is successful.

            On a snapshot update failure, its stdout & stderr will always be shown.

        jest_repository: Name of the repository created with jest_repositories().

        tags: standard Bazel attribute, passed through to generated targets.

        timeout: standard attribute for tests. Defaults to "short" if both timeout and size are unspecified.

        size: standard attribute for tests

        **kwargs: Additional named parameters passed to both `js_test` and `js_binary`.
            See https://github.com/aspect-build/rules_js/blob/main/docs/js_binary.md
    """
    snapshot_data = []
    snapshot_files = []

    snapshot_directories = []
    if snapshots == True:
        snapshots = native.glob(["**/__snapshots__"], exclude_directories = 0)

    if type(snapshots) == "string":
        snapshot_directories = [to_label(snapshots)]
        snapshot_data = native.glob(["{}/**".format(snapshots)])
    elif type(snapshots) == "list":
        for snapshot in snapshots:
            snapshot_label = to_label(snapshot)
            if snapshot_label.package != native.package_name():
                msg = "Expected jest_test '{target}' snapshots to be in test target package '{jest_test_package}' but got '{snapshot_label}' in package '{snapshot_package}'".format(
                    jest_test_package = native.package_name(),
                    snapshot_label = snapshot_label,
                    snapshot_package = snapshot_label.package,
                    target = to_label(name),
                )
                fail(msg)
            if snapshot_label.name.endswith(snapshots_ext):
                snapshot_files.append(snapshot_label)
                snapshot_data.append(snapshot_label)
            else:
                snapshot_directories.append(snapshot_label)
                snapshot_data.extend(native.glob(["{}/**".format(snapshot)]))

    elif snapshots != False and snapshots != None:
        msg = "snapshots expected to be a boolean, string or list but got {}".format(snapshots)
        fail(msg)

    if snapshot_files and snapshot_directories:
        msg = "Expected jest_test '{target}' snapshots to be labels to all snapshot files (ending with '{snapshots_ext}') or all snapshot directories but got a mix of the two".format(
            snapshots_ext = snapshots_ext,
            target = to_label(name),
        )

    # This is the primary {name} jest_test test target
    _jest_from_repository(
        jest_rule = _jest_test,
        jest_repository = jest_repository,
        name = name,
        config = config,
        data = data + snapshot_data,
        run_in_band = run_in_band,
        colors = colors,
        auto_configure_reporters = auto_configure_reporters,
        auto_configure_test_sequencer = auto_configure_test_sequencer,
        tags = tags,
        size = size,
        timeout = default_timeout(size, timeout),
        **kwargs
    )

    update_snapshots_mode = None
    if snapshot_files:
        update_snapshots_mode = "files"
    elif snapshot_directories:
        update_snapshots_mode = "directory"

    if update_snapshots_mode:
        gen_snapshots_bin = "{}_ref_snapshots_bin".format(name)

        # This is the generated reference snapshot generator binary target that is used as the
        # `tool` in the `js_run_binary` target below to output the reference snapshots.
        _jest_from_repository(
            jest_rule = _jest_binary,
            jest_repository = jest_repository,
            name = gen_snapshots_bin,
            config = config,
            run_in_band = run_in_band,
            colors = colors,
            auto_configure_reporters = auto_configure_reporters,
            auto_configure_test_sequencer = auto_configure_test_sequencer,
            update_snapshots_mode = update_snapshots_mode,
            tags = tags + ["manual"],  # tagged manual so it is not built unless the {name}_update_snapshot target is run
            **kwargs
        )

        _jest_update_snapshots(
            name = name,
            config = config,
            data = data,
            tags = tags + ["manual"],  # tagged manual so it is not built unless run
            snapshot_directories = snapshot_directories,
            snapshot_files = snapshot_files,
            gen_snapshots_bin = gen_snapshots_bin,
            quiet_snapshot_updates = quiet_snapshot_updates,
        )

def _jest_update_snapshots(
        name,
        config,
        data,
        tags,
        snapshot_directories,
        snapshot_files,
        gen_snapshots_bin,
        quiet_snapshot_updates):
    update_snapshots_files = {}
    if snapshot_directories:
        # This js_run_binary outputs the reference snapshots directory used by the
        # write_source_files updater target below. Reference snapshots have a
        # REFERENCE_SNAPSHOT_SUFFIX suffix so the write_source_files is able to specify both the
        # source file snapshots and the reference snapshots by label.
        ref_snapshots_target = "{}{}".format(name, REFERENCE_BUILD_TARGET_SUFFIX)
        _js_run_binary(
            name = ref_snapshots_target,
            srcs = data + ([config] if config else []),
            out_dirs = ["{}/{}".format(d.name, REFERENCE_SNAPSHOT_DIRECTORY) for d in snapshot_directories],
            tool = gen_snapshots_bin,
            silent_on_success = quiet_snapshot_updates,
            testonly = True,
            # Tagged manual so it is not built unless the {name}_update_snapshot target is run
            tags = tags + ["manual"],
        )
        if len(snapshot_directories) == 1:
            # The case of a single directory output is simple
            update_snapshots_files[snapshot_directories[0].name] = ref_snapshots_target
        else:
            # The case of many directory outputs is more complicated since output directories
            # have no pre-declared labels; we must use an output_group target to get at the
            # individual output directories
            for i, d in enumerate(snapshot_directories):
                output_files_target = "{}_outdir_{}".format(name, i)
                output_path = "/".join([s for s in [d.package, d.name, REFERENCE_SNAPSHOT_DIRECTORY] if s])
                _output_files(
                    name = output_files_target,
                    target = ref_snapshots_target,
                    paths = [output_path],
                    testonly = True,
                    # Tagged manual so it is not built unless the {name}_update_snapshot target is run
                    tags = tags + ["manual"],
                )
                update_snapshots_files[snapshot_directories[i].name] = output_files_target
    else:
        snapshot_outs = []
        for snapshot in snapshot_files:
            snapshot_out = "{}{}".format(snapshot, REFERENCE_SNAPSHOT_SUFFIX)
            snapshot_outs.append(snapshot_out)
            update_snapshots_files[snapshot] = snapshot_out

        # This js_run_binary outputs the reference snapshots files used by the write_source_files
        # updater target below. Reference snapshots have a REFERENCE_SNAPSHOT_SUFFIX suffix so the
        # write_source_files is able to specify both the source file snapshots and the reference
        # snapshots by label.
        _js_run_binary(
            name = "{}{}".format(name, REFERENCE_BUILD_TARGET_SUFFIX),
            srcs = data + ([config] if config else []),
            outs = snapshot_outs,
            tool = gen_snapshots_bin,
            silent_on_success = quiet_snapshot_updates,
            testonly = True,
            # Tagged manual so it is not built unless the {name}_update_snapshot target is run
            tags = tags + ["manual"],
        )

    # The snapshot update binary target: {name}_update_snapshots
    _write_source_files(
        name = "{}{}".format(name, UPDATE_SNAPSHOTS_TARGET_SUFFIX),
        files = update_snapshots_files,
        # Jest will already fail if the snapshot is out-of-date so just use write_source_files
        # for the update script
        diff_test = False,
        testonly = True,
        # Tagged manual so it is not built unless run
        tags = tags + ["manual"],
        # Always public visibility so that it can be used downstream in an aggregate write_source_files target
        visibility = ["//visibility:public"],
    )

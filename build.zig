const std = @import("std");

const contrib_sources: []const []const u8 = &.{
    "src/contrib/graphbuilder.cpp",
    "src/contrib/graphbuilderadapter.cpp",
};

const yaml_cpp_sources: []const []const u8 = &.{
    "src/binary.cpp",
    "src/convert.cpp",
    "src/depthguard.cpp",
    "src/directives.cpp",
    "src/emit.cpp",
    "src/emitfromevents.cpp",
    "src/emitter.cpp",
    "src/emitterstate.cpp",
    "src/emitterutils.cpp",
    "src/exceptions.cpp",
    "src/exp.cpp",
    "src/fptostring.cpp",
    "src/memory.cpp",
    "src/node.cpp",
    "src/node_data.cpp",
    "src/nodebuilder.cpp",
    "src/nodeevents.cpp",
    "src/null.cpp",
    "src/ostream_wrapper.cpp",
    "src/parse.cpp",
    "src/parser.cpp",
    "src/regex_yaml.cpp",
    "src/scanner.cpp",
    "src/scanscalar.cpp",
    "src/scantag.cpp",
    "src/scantoken.cpp",
    "src/simplekey.cpp",
    "src/singledocparser.cpp",
    "src/stream.cpp",
    "src/tag.cpp",
};

const BuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    lto: ?std.zig.LtoMode,
    linkage: std.builtin.LinkMode,
    flags: []const []const u8,
};

fn get_flags(cpp_version: []const u8, alloc: std.mem.Allocator) !std.ArrayList([]const u8) {
    var cxx_flags: std.ArrayList([]const u8) = .empty;
    errdefer cxx_flags.deinit(alloc);

    const version_flag = try std.mem.join(alloc, "", &.{ "-std=c++", cpp_version });
    try cxx_flags.append(alloc, version_flag);

    try cxx_flags.appendSlice(alloc, &.{
        "-Wall",
        "-Wextra",
        "-Wshadow",
        "-Weffc++",
        "-pedantic",
    });

    return cxx_flags;
}

fn get_options(b: *std.Build) !BuildOptions {
    const cpp_version = b.option([]const u8, "cpp_version", "C++ version") orelse "23";
    const strip = b.option(bool, "strip", "Enable debug symbol stripping") orelse false;
    const lto = b.option(std.zig.LtoMode, "lto", "Lto mode to use for the library.");
    const linkage = b.option(std.builtin.LinkMode, "linkage", "shared or static linking") orelse .static;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var flags = try get_flags(cpp_version, b.allocator);
    errdefer flags.deinit(b.allocator);

    return .{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .lto = lto,
        .linkage = linkage,
        .flags = flags.items,
    };
}

pub fn build(b: *std.Build) !void {
    const build_contrib = b.option(bool, "contrib", "Enable yaml-cpp contrib in library") orelse true;

    const options = try get_options(b);

    const lib = try build_lib(b, options);

    if (build_contrib) {
        lib.addCSourceFiles(.{
            .files = contrib_sources,
            .flags = options.flags,
        });
    } else {
        lib.root_module.addCMacro("YAML_CPP_NO_CONTRIB", "");
    }

    try build_tests(lib, b, options);
    try build_tools(lib, b, options);
}

fn build_lib(b: *std.Build, options: BuildOptions) !*std.Build.Step.Compile {
    const root = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .link_libcpp = true,
        .strip = options.strip,
    });

    const lib = b.addLibrary(.{
        .linkage = options.linkage,
        .name = "yaml-cpp",
        .root_module = root,
    });
    lib.lto = options.lto;

    if (options.linkage == .static) {
        lib.root_module.addCMacro("YAML_CPP_STATIC_DEFINE", "");
    }

    lib.addCSourceFiles(.{
        .files = yaml_cpp_sources,
        .flags = options.flags,
    });

    lib.addIncludePath(b.path("include"));
    lib.addIncludePath(b.path("src"));

    lib.installHeadersDirectory(b.path("include"), "", .{});

    b.installArtifact(lib);
    return lib;
}

fn build_tests(lib: *std.Build.Step.Compile, b: *std.Build, options: BuildOptions) !void {
    const tests = b.option(bool, "tests", "Build and run yaml-cpp tests") orelse false;

    if (!tests) {
        return;
    }

    const sources: []const []const u8 = &.{
        "test/main.cpp",
        "test/binary_test.cpp",
        "test/node/node_test.cpp",
        "test/fptostring_test.cpp",
        "test/ostream_wrapper_test.cpp",
        "test/integration/emitter_test.cpp",
        "test/integration/encoding_test.cpp",
        "test/integration/error_messages_test.cpp",
        "test/integration/gen_emitter_test.cpp",
        "test/integration/handler_spec_test.cpp",
        "test/integration/handler_test.cpp",
        "test/integration/load_node_test.cpp",
        "test/integration/node_spec_test.cpp",
    };

    const googletest_dep = b.lazyDependency("googletest", .{
        .target = options.target,
        .optimize = options.optimize,
    });

    if (googletest_dep) |googletest| {
        const root = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
            .link_libcpp = true,
            .strip = options.strip,
        });

        const test_exe = b.addExecutable(.{
            .name = "yaml-cpp-tests",
            .root_module = root,
        });
        test_exe.lto = options.lto;

        root.addCSourceFiles(.{ .files = sources, .flags = options.flags });

        test_exe.addIncludePath(b.path("test"));

        if (options.linkage == .static) {
            test_exe.root_module.addCMacro("YAML_CPP_STATIC_DEFINE", "");
        }

        test_exe.linkLibrary(lib);

        const gtest = googletest.artifact("gtest");
        gtest.lto = options.lto;
        gtest.root_module.strip = options.strip;

        const gmock = googletest.artifact("gmock");
        gmock.lto = options.lto;
        gmock.root_module.strip = options.strip;

        test_exe.linkLibrary(gtest);
        test_exe.linkLibrary(gmock);

        const test_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run yaml-cpp tests");
        test_step.dependOn(&test_run.step);
    }
}

fn build_tools(lib: *std.Build.Step.Compile, b: *std.Build, options: BuildOptions) !void {
    const tools = b.option(bool, "tools", "Build the yaml-cpp tools") orelse false;

    if (!tools) {
        return;
    }

    try build_tool("parse", &.{"util/parse.cpp"}, lib, b, options);
    try build_tool("read", &.{"util/read.cpp"}, lib, b, options);
}

fn build_tool(name: []const u8, sources: []const []const u8, lib: *std.Build.Step.Compile, b: *std.Build, options: BuildOptions) !void {
    const root = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip,
        .link_libcpp = true,
    });

    const tool = b.addExecutable(.{
        .name = name,
        .root_module = root,
    });

    if (options.linkage == .static) {
        tool.root_module.addCMacro("YAML_CPP_STATIC_DEFINE", "");
    }

    tool.addCSourceFiles(.{ .files = sources, .flags = options.flags });

    root.linkLibrary(lib);

    b.installArtifact(tool);
}

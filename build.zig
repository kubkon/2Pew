// XXX: baking todo
// - inline switch in zon instead of for loop on indices?
// - move build code into engine?
// - does deleting stuff update the build properly?
// - says installing while running...
// - separate build scripts for seaparate sub projects, too confusing otherwise
// - is the output less confusing if we rename extensions or can there be collisions one way or the other?
// - wait cross target should just be this target for the bake step right?
// - don't include the . in extension args, make it automatic, so you can't leave it off
// - creating bake steps is very verbose...
// - force verificaiton of all zon at bake time?
// - get embedding working again (need to be able to import zon first)
// - auto create the id files, rename to id, possibly just have id in them?
// - report good errors on zon stuff (test error handling api in practice!)
// - make sure only stuff that needs to is getting rebuilt...
// - allow asset groups for purposes of choosing random versions of things? e.g. an artist can
// add a file to a group via a config file or folder structure, and it shows up in game without the
// game needing to modify internal arrays of things. may also be useful for things like animations?
// - asset packs for loading groups of assets together? (and verifying they exist?) if we make some of
// this dynamic instead of static we may want the missing asset fallbacks again?
// - what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
// it can change whether they need to be persistent
// - make sure we can do e.g. zig build bake to just bake, add stdout so we can see what's happening even if clear after each line
// - files seemingly never get DELETED from zig-out, is that expected..? seems like it could get us into
// trouble.
// - cache the index in source control as well in something readable (.zon or .json) and use
// it as input when available to verify that assets weren't missing and such?
// - catch duplicate ids and such here?
const std = @import("std");
const BakeAssets = @import("src/bake/BakeAssets.zig");
const BakeAsset = BakeAssets.BakeAsset;
const Allocator = std.mem.Allocator;
const FileSource = std.Build.FileSource;
const zon = @import("zon").zon;

const Sprite = struct {
    const Tint = union(enum) {
        none,
        luminosity,
        mask: []const u8,
    };

    diffuse: []const u8,
    degrees: f32 = 0.0,
    tint: Tint = .none,
};

fn addSpriteZon(exe: *std.Build.Step.Compile, paths: BakeAsset.Paths) !BakeAsset.Baked {
    // Read the sprite definition
    const sprite = b: {
        var zon_source = try exe.step.owner.build_root.handle.readFileAllocOptions(
            exe.step.owner.allocator,
            paths.data,
            1024,
            null,
            @alignOf(u8),
            0,
        );
        defer exe.step.owner.allocator.free(zon_source);

        break :b try zon.parseFromSlice(Sprite, exe.step.owner.allocator, zon_source, .{});
    };
    defer zon.parseFree(exe.step.owner.allocator, sprite);

    // Create the process and pass in the input path
    const process = b: {
        var diffuse_path = try std.fs.path.join(exe.step.owner.allocator, &.{
            std.fs.path.dirname(paths.data).?,
            sprite.diffuse,
        });
        break :b try BakeAsset.addRunArtifactWithInput(exe, diffuse_path);
    };

    // Tint
    switch (sprite.tint) {
        .mask => |path_rel| {
            var mask_path = try std.fs.path.join(exe.step.owner.allocator, &.{
                std.fs.path.dirname(paths.data).?,
                path_rel,
            });
            const write_step = exe.step.owner.addWriteFiles();
            var mask_cached = write_step.addCopyFile(
                FileSource.relative(mask_path),
                mask_path,
            );
            process.addFileSourceArg(mask_cached);
        },
        .none => process.addArg("none"),
        .luminosity => process.addArg("luminosity"),
    }

    // Rotation
    {
        var degrees = try std.fmt.allocPrint(exe.step.owner.allocator, "{}", .{sprite.degrees});
        defer exe.step.owner.allocator.free(degrees);
        process.addArg(degrees);
    }

    // Output
    const install_path = try std.fmt.allocPrint(
        exe.step.owner.allocator,
        "{s}.sprite",
        .{paths.install},
    );
    const file_source = process.addOutputFileArg(install_path);

    return .{
        .file_source = file_source,
        .install_path = install_path,
    };
}

fn addSpritePng(exe: *std.Build.Step.Compile, paths: BakeAsset.Paths) !BakeAsset.Baked {
    const process = try BakeAsset.addRunArtifactWithInput(exe, paths.data);
    process.addArg("none"); // Tint
    process.addArg("0"); // Degrees
    const install_path = try std.fmt.allocPrint(
        exe.step.owner.allocator,
        "{s}.sprite",
        .{paths.install},
    );
    const file_source = process.addOutputFileArg(install_path);

    return .{
        .file_source = file_source,
        .install_path = install_path,
    };
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const zon_module = b.dependency("zon", .{ .target = target, .optimize = .ReleaseFast }).module("zon");

    const pew_exe = b.addExecutable(.{
        .name = "pew",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/game/src/game.zig" },
        .target = target,
        .optimize = optimize,
    });

    var engine = b.createModule(.{
        .source_file = .{ .path = "src/engine/engine.zig" },
    });
    pew_exe.addModule("engine", engine);
    pew_exe.addModule("zon", zon_module);

    const use_llvm = b.option(bool, "use-llvm", "use zig's llvm backend");
    pew_exe.use_llvm = use_llvm;
    pew_exe.use_lld = use_llvm;

    // https://github.com/MasonRemaley/2Pew/issues/2
    pew_exe.want_lto = false;

    if (target.isNativeOs() and target.getOsTag() == .linux) {
        // The SDL package doesn't work for Linux yet, so we rely on system
        // packages for now.
        pew_exe.linkSystemLibrary("SDL2");
        pew_exe.linkLibC();
    } else {
        const zig_sdl = b.dependency("zig_sdl", .{
            .target = target,
            .optimize = .ReleaseFast,
        });
        pew_exe.linkLibrary(zig_sdl.artifact("SDL2"));
    }

    pew_exe.override_dest_dir = .prefix;
    b.installArtifact(pew_exe);

    // This *creates* a RunStep in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(pew_exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const data_path = "src/game/data";

    // Bake sprites
    const bake_sprite_exe = b: {
        const exe = b.addExecutable(.{
            .name = "bake-sprite",
            .root_source_file = .{ .path = "src/game/bake/bake_sprite.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addCSourceFile("src/game/bake/stb_image.c", &.{"-std=c99"});
        exe.addIncludePath("src/game/bake");
        exe.linkLibC();
        break :b exe;
    };

    var bake_sprites = BakeAssets.create(b);
    defer bake_sprites.deinit();

    try bake_sprites.addAssets(.{
        .path = data_path,
        .extension = ".sprite.png",
        .storage = .install,
        .bake_step = BakeAsset.create(bake_sprite_exe, addSpritePng),
    });

    try bake_sprites.addAssets(.{
        .path = data_path,
        .extension = ".sprite.zon",
        .storage = .install,
        .bake_step = BakeAsset.create(bake_sprite_exe, addSpriteZon),
    });
    pew_exe.addModule("sprite_descriptors", try bake_sprites.createModule());

    // Bake animations
    var bake_animations = BakeAssets.create(b);
    defer bake_animations.deinit();
    try bake_animations.addAssets(.{
        .path = data_path,
        .extension = ".anim.zon",
        .storage = .install,
    });
    pew_exe.addModule("animation_descriptors", try bake_animations.createModule());

    // Creates a step for unit testing.
    const game_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/game/src/game.zig" },
        .target = target,
        .optimize = optimize,
    });
    const engine_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/engine/engine.zig" },
        .target = target,
        .optimize = optimize,
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = .{ .path = "src/bench.zig" },
        .target = target,
        .optimize = optimize,
    });
    bench_exe.override_dest_dir = .prefix;
    const bench_step = b.step("bench", "Run benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    const run_game_tests = b.addRunArtifact(game_tests);
    const run_engine_tests = b.addRunArtifact(engine_tests);
    test_step.dependOn(&run_game_tests.step);
    test_step.dependOn(&run_engine_tests.step);
}

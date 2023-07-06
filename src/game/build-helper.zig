const std = @import("std");
const bake = @import("../engine/src/engine.zig").bake;
const Baker = bake.Baker;
const BakeStep = bake.BakeStep;
const Build = std.Build;
const FileSource = Build.FileSource;
const Step = Build.Step;
const CompileStep = Build.CompileStep;
const zon = @import("zon").zon;
const engine = @import("../engine/build-helper.zig");

pub const Options = struct {
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    test_step: *Step,
    bench_step: *Step,
    use_llvm: ?bool,
};

const install_root = "pew";

pub fn build(b: *Build, options: Options) !void {
    const pew_exe = try buildExe(b, options);
    try bakeAssets(b, options, pew_exe);
}

fn buildExe(b: *Build, options: Options) !*Step.Compile {
    // Build the game
    const pew_exe = b.addExecutable(.{
        .name = "pew",
        .root_source_file = .{ .path = "src/game/src/game.zig" },
        .target = options.target,
        .optimize = options.optimize,
    });

    // Configure the build
    {
        pew_exe.use_llvm = options.use_llvm;
        pew_exe.use_lld = options.use_llvm;

        // https://github.com/MasonRemaley/2Pew/issues/2
        pew_exe.want_lto = false;
    }

    // Build the dependencies
    {
        pew_exe.addModule("engine", try engine.build(b, .{
            .target = options.target,
            .optimize = options.optimize,
            .test_step = options.test_step,
            .bench_step = options.bench_step,
        }));

        pew_exe.addModule("zon", b.dependency("zon", .{
            .target = options.target,
            .optimize = .ReleaseFast,
        }).module("zon"));

        if (options.target.isNativeOs() and options.target.getOsTag() == .linux) {
            // The SDL package doesn't work for Linux yet, so we rely on system
            // packages for now.
            pew_exe.linkSystemLibrary("SDL2");
            pew_exe.linkLibC();
        } else {
            const zig_sdl = b.dependency("zig_sdl", .{
                .target = options.target,
                .optimize = .ReleaseFast,
            });
            pew_exe.linkLibrary(zig_sdl.artifact("SDL2"));
        }
    }

    // Install the game
    {
        var install_artifact = b.addInstallArtifact(pew_exe);
        install_artifact.dest_dir = .{ .custom = install_root };
        install_artifact.pdb_dir = install_artifact.dest_dir;
        b.getInstallStep().dependOn(&install_artifact.step);
    }

    // Set up run step
    {
        const run_cmd = b.addRunArtifact(pew_exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // Set up test step
    {
        const game_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/game/src/game.zig" },
            .target = options.target,
            .optimize = options.optimize,
        });
        const run_game_tests = b.addRunArtifact(game_tests);
        options.test_step.dependOn(&run_game_tests.step);
    }

    return pew_exe;
}

fn bakeAssets(b: *Build, options: Options, pew_exe: *CompileStep) !void {
    var baker = try Baker.create(b, .{
        .data_path = "src/game/data",
        .install_root = install_root,
        .install_prefix = "data",
    });
    defer baker.prune();

    // Bake sprites
    {
        var bake_sprites = baker.addAssetType();
        defer bake_sprites.deinit();

        const bake_sprite_exe = b: {
            const exe = b.addExecutable(.{
                .name = "bake-sprite",
                .root_source_file = .{ .path = "src/game/bake/bake_sprite.zig" },
                .target = options.target,
                .optimize = options.optimize,
            });
            exe.addCSourceFile("src/game/bake/stb_image.c", &.{"-std=c99"});
            exe.addIncludePath("src/game/bake");
            exe.linkLibC();
            break :b exe;
        };

        try bake_sprites.addBatch(.{
            .extension = ".sprite.png",
            .storage = .install,
            .bake_step = BakeStep.create(bake_sprite_exe, addSpritePng),
        });

        try bake_sprites.addBatch(.{
            .extension = ".sprite.zon",
            .storage = .install,
            .bake_step = BakeStep.create(bake_sprite_exe, addSpriteZon),
        });

        const sprites_module = try bake_sprites.createModule("sprite_descriptors.zig");
        pew_exe.addModule("sprite_descriptors", sprites_module);
    }

    // Bake animations
    {
        var bake_animations = baker.addAssetType();
        defer bake_animations.deinit();
        try bake_animations.addBatch(.{
            .extension = ".anim.zon",
            .storage = .install,
        });
        const animation_module = try bake_animations.createModule("animation_descriptors.zig");
        pew_exe.addModule("animation_descriptors", animation_module);
    }
}

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

fn addSpriteZon(exe: *Step.Compile, paths: BakeStep.Paths) !BakeStep.Baked {
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
        break :b try BakeStep.addRunArtifactWithInput(exe, diffuse_path);
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

fn addSpritePng(exe: *Step.Compile, paths: BakeStep.Paths) !BakeStep.Baked {
    const process = try BakeStep.addRunArtifactWithInput(exe, paths.data);
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

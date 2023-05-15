const std = @import("std");
const math = std.math;

pub const descriptors = &.{
    .{
        .id = "ship/ranger/thrusters",
        .asset = @import("../data/animations/ship/ranger_thrusters.zig").descriptor.asset,
    },
    .{
        .id = "ship/militia/thrusters",
        .asset = @import("../data/animations/ship/militia_thrusters.zig").descriptor.asset,
    },
    .{
        .id = "explosion",
        .asset = @import("../data/animations/explosion.zig").descriptor.asset,
    },
    .{
        .id = "ship/triangle/thrusters",
        .asset = @import("../data/animations/ship/triangle_thrusters.zig").descriptor.asset,
    },
    .{
        .id = "ship/kevin/thrusters",
        .asset = @import("../data/animations/ship/kevin_thrusters.zig").descriptor.asset,
    },
    .{
        .id = "ship/wendy/thrusters/left",
        .asset = @import("../data/animations/ship/wendy/thrusters_left.zig").descriptor.asset,
    },
    .{
        .id = "ship/wendy/thrusters/right",
        .asset = @import("../data/animations/ship/wendy/thrusters_right.zig").descriptor.asset,
    },
    .{
        .id = "ship/wendy/thrusters/top",
        .asset = @import("../data/animations/ship/wendy/thrusters_top.zig").descriptor.asset,
    },
    .{
        .id = "ship/wendy/thrusters/bottom",
        .asset = @import("../data/animations/ship/wendy/thrusters_bottom.zig").descriptor.asset,
    },
};

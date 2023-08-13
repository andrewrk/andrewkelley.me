const std = @import("std");

pub fn build(b: *std.Build) void {
    const compile_exe = b.addExecutable(.{
        .name = "compile",
        .root_source_file = .{ .path = "src/main.zig" },
    });
    const run_cmd = b.addRunArtifact(compile_exe);
    b.getInstallStep().dependOn(&run_cmd.step);
}

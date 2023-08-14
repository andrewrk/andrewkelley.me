const std = @import("std");

pub fn build(b: *std.Build) void {
    const compile_exe = b.addExecutable(.{
        .name = "compile",
        .root_source_file = .{ .path = "src/main.zig" },
    });
    const run_cmd = b.addRunArtifact(compile_exe);
    b.getInstallStep().dependOn(&run_cmd.step);

    const s3cmd = b.addSystemCommand(&.{
        "s3cmd",
        "sync",
        "-P",
        "--no-preserve",
        "--no-mime-magic",
        "--add-header=Cache-Control: max-age=0, must-revalidate",
        "www/",
        "s3://andrewkelley.me/",
    });
    s3cmd.step.dependOn(&run_cmd.step);

    b.step("deploy", "Publish the website").dependOn(&s3cmd.step);
}

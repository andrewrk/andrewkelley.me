const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const compile_exe = b.addExecutable("compile", "src/main.zig");
    const run_cmd = compile_exe.run();
    b.getInstallStep().dependOn(&run_cmd.step);
}

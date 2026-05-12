const std = @import("std");
const sphtud_build = @import("sphtud");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const sphtud_dep = b.dependency("sphtud", .{
        .with_gl = false,
        .with_glfw = false,
        .unique = "sphaudio",
    });
    const sphtud = sphtud_dep.module("sphtud");

    const pw_bindings_tc = b.addTranslateC(.{
        .root_source_file = b.path("bindings/pipewire.h"),
        .target = target,
        .optimize = opt,
    });
    pw_bindings_tc.linkSystemLibrary("libpipewire-0.3", .{});

    // Intentionally bypass TranslateC.createModule(). We DO NOT want to link
    // libpipewire, so we want to completely break that dependency chain
    //
    // Just give us the bindings, cause that's all we really want
    const pw_bindings = b.createModule(.{
        .root_source_file = pw_bindings_tc.getOutput(),
    });

    const dyn_pw = sphtud_build.mkStrongDyn(b, sphtud_dep, pw_bindings, "bindings/dpw.txt");
    const dyn_spa = sphtud_build.mkStrongDyn(b, sphtud_dep, pw_bindings, "bindings/spa.txt");

    const sphaudio = b.addModule("sphaudio", .{
        .root_source_file = b.path("src/sphaudio.zig"),
    });
    sphaudio.addImport("dyn_pw", dyn_pw);
    sphaudio.addImport("dyn_spa", dyn_spa);

    sphaudio.addImport("sphtud", sphtud);
    sphaudio.addImport("pw_bindings", pw_bindings);
    sphaudio.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/example/main.zig"),
            .target = target,
            .optimize = opt,
        }),
    });
    exe.root_module.addImport("sphaudio", sphaudio);
    exe.root_module.addImport("sphtud", sphtud);

    b.installArtifact(exe);
}

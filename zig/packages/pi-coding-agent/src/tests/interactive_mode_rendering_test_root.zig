const rendering_modules = @import("coding_agent").interactive_mode_rendering_test_modules;

test {
    _ = rendering_modules.active_operation_rendering;
    _ = rendering_modules.rendering;
    _ = rendering_modules.extension_ui_bridge;
    _ = rendering_modules.prompt_rendering;
}

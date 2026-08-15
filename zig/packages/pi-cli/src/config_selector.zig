const package_config_selector = @import("coding_agent").package_config_selector;

pub const ConfigKind = package_config_selector.ConfigKind;
pub const ConfigSelectorEntry = package_config_selector.ConfigSelectorEntry;
pub const ConfigSelectorState = package_config_selector.ConfigSelectorState;
pub const ConfigSelectorRunOptions = package_config_selector.ConfigSelectorRunOptions;
pub const loadSelectorState = package_config_selector.loadSelectorState;
pub const saveSelectorState = package_config_selector.saveSelectorState;
pub const selectConfig = package_config_selector.runConfigSelector;
pub const runConfigSelector = package_config_selector.runConfigSelector;

test "config selector cli module re-exports package selector" {
    _ = ConfigSelectorState;
    _ = selectConfig;
}
